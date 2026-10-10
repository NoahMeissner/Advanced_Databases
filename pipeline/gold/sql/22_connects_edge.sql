-- gold.connects_edge - the routing table the website searches.
--
-- The same CONNECTS relationships that are in gold.graph_edge and in Neo4j,
-- but as a typed, indexed relational table with ONE TRAVEL-TIME COLUMN PER
-- BAND. Two reasons it exists:
--
--  1. SPEED. The 20-minute reach has to be seeded from every stop within
--     walking distance, not just the nearest one. In Neo4j that means one
--     Dijkstra per seed: 3.1 s for 28 seeds, and 3.5 s with the Cypher
--     batched into a single UNWIND, because the cost is the 28 full graph
--     traversals, not the round-trips. The same answer from a bounded
--     multi-source recursive CTE over this table takes 0.03 s.
--  2. TIME OF DAY. Switching band becomes switching column.
--
-- Neo4j still holds the graph for Cypher and GDS; this is a projection of the
-- same edges, and connects_edge_matches_graph asserts the two cannot drift.
--
-- NULL in a band column means NO SERVICE IN THAT BAND, and that is where the
-- time-of-day effect comes from: 3,743 edges run only at peak and 5,542 only
-- off-peak, so changing band changes which edges exist at all, not just how
-- fast they are (band travel times differ by only ~6% on average).
--
-- A band column is never NULL merely because every timing was a whole-minute
-- 0 s artefact: if trips run, the edge gets the distance estimate instead, so
-- "no service" stays distinguishable from "unmeasurable".

CREATE TABLE IF NOT EXISTS gold.connects_edge (
    from_stop_id      integer       NOT NULL REFERENCES silver.bus_stop,
    to_stop_id        integer       NOT NULL REFERENCES silver.bus_stop,
    travel_time_s     numeric(10,2) NOT NULL,   -- band-independent default
    peak_s            numeric(10,2),            -- NULL = no peak service
    offpeak_s         numeric(10,2),            -- NULL = no offpeak service
    straight_line_m   numeric(12,2),
    n_routes          integer       NOT NULL,
    route_short_names text[]        NOT NULL DEFAULT '{}',
    loaded_at         timestamptz   NOT NULL DEFAULT now(),

    CONSTRAINT connects_edge_pkey PRIMARY KEY (from_stop_id, to_stop_id),
    CONSTRAINT connects_edge_weight_check CHECK (travel_time_s > 0),
    CONSTRAINT connects_edge_peak_check CHECK (peak_s IS NULL OR peak_s > 0),
    CONSTRAINT connects_edge_offpeak_check CHECK (offpeak_s IS NULL OR offpeak_s > 0)
);

-- The recursive search joins on from_stop_id and reads the rest, so an INCLUDE
-- index keeps the whole traversal index-only.
CREATE INDEX IF NOT EXISTS connects_edge_from_idx
    ON gold.connects_edge (from_stop_id)
    INCLUDE (to_stop_id, travel_time_s, peak_s, offpeak_s);

DELETE FROM gold.connects_edge;

INSERT INTO gold.connects_edge
    (from_stop_id, to_stop_id, travel_time_s, peak_s, offpeak_s,
     straight_line_m, n_routes, route_short_names)
WITH timed AS (
    SELECT e.from_stop_id, e.to_stop_id, e.route_short_name, e.straight_line_m,
           t.time_band, t.avg_travel_time_s, t.n_trips, t.flag_zero_timepoint
      FROM silver.bus_edge e
      JOIN silver.bus_edge_travel_time t USING (edge_key)
), collapsed AS (
    SELECT from_stop_id, to_stop_id,
           min(straight_line_m) AS straight_line_m,
           count(DISTINCT route_short_name)::integer AS n_routes,
           coalesce(array_agg(DISTINCT route_short_name)
                    FILTER (WHERE route_short_name IS NOT NULL), '{}') AS routes,
           -- does the band run here at all?
           bool_or(time_band = 'peak')    AS has_peak,
           bool_or(time_band = 'offpeak') AS has_offpeak,
           -- fastest real timing per band, ignoring the 0 s timepoint artefacts
           min(avg_travel_time_s) FILTER (
               WHERE time_band = 'peak' AND NOT flag_zero_timepoint)    AS best_peak,
           min(avg_travel_time_s) FILTER (
               WHERE time_band = 'offpeak' AND NOT flag_zero_timepoint) AS best_offpeak,
           (sum(avg_travel_time_s * n_trips) FILTER (WHERE time_band = 'peak')
            / nullif(sum(n_trips) FILTER (WHERE time_band = 'peak'), 0))    AS avg_peak,
           (sum(avg_travel_time_s * n_trips) FILTER (WHERE time_band = 'offpeak')
            / nullif(sum(n_trips) FILTER (WHERE time_band = 'offpeak'), 0)) AS avg_offpeak
      FROM timed
     GROUP BY from_stop_id, to_stop_id
), weighted AS (
    SELECT *,
           -- 20 km/h, the same urban-bus fallback gold.graph_edge uses
           greatest(straight_line_m / 5.56, 1.0) AS distance_estimate
      FROM collapsed
)
SELECT from_stop_id, to_stop_id,
       round(greatest(coalesce(nullif(best_peak, 0), nullif(avg_peak, 0),
                               nullif(best_offpeak, 0), nullif(avg_offpeak, 0),
                               distance_estimate), 1.0), 2),
       CASE WHEN has_peak
            THEN round(greatest(coalesce(nullif(best_peak, 0), nullif(avg_peak, 0),
                                         distance_estimate), 1.0), 2) END,
       CASE WHEN has_offpeak
            THEN round(greatest(coalesce(nullif(best_offpeak, 0), nullif(avg_offpeak, 0),
                                         distance_estimate), 1.0), 2) END,
       straight_line_m, n_routes, routes
  FROM weighted;
