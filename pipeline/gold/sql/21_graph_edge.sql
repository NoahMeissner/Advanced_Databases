-- gold.graph_edge - every relationship of the one graph.
--
-- The two stop-to-stop types answer different questions, so both exist:
--
--   ROUTE_SEGMENT  one per route+direction between two stops (47,047). Faithful
--                  to GTFS: up to 21 routes run between the same pair of stops
--                  and each has its own timings. Use it for "which routes link
--                  these two stops".
--   CONNECTS       one per stop pair (28,340), carrying the fastest and the
--                  trip-weighted average time. Use it for routing: a shortest
--                  path over parallel edges would otherwise have to deduplicate
--                  them itself.
--
-- best_peak_s EXCLUDES edges flagged flag_zero_timepoint. GTFS timepoints are
-- whole minutes, so adjacent stops often share a timestamp and the source
-- reports 0 s. Taking a plain min() would hand Dijkstra free hops and produce
-- confidently wrong journey times.
--
-- travel_time_s is the ROUTING WEIGHT and is never NULL and never <= 0. Two
-- distinct failure modes have to be handled, and both are silent:
--
--   NULL  4,699 pairs have no usable peak figure. A missing property projects
--         into GDS as NaN, which propagates along the path: Dijkstra then
--         reports NaN for the cost and picks a distorted route.
--   ZERO  2,577 pairs average out to 0 s, because the trip-weighted averages
--         include the whole-minute 0 s segments. A 0-weight edge is a free hop.
--
-- So the chain skips zeros as well as NULLs, and ends in a distance-based
-- estimate at 20 km/h (a plausible urban bus speed) for the pairs where the
-- timetable's minute granularity cannot resolve the hop:
--
--   best_peak -> avg_peak -> best_offpeak -> avg_offpeak -> distance estimate
--
-- weight_source names which one was used, so a routing answer can say exactly
-- how much of it rested on an estimate rather than a timetable.
--
-- A dangling edge is a bug, so the foreign keys to gold.graph_node make it fail
-- the load instead of quietly producing an orphan in Neo4j.

CREATE TABLE IF NOT EXISTS gold.graph_edge (
    rel_type   text        NOT NULL,
    from_label text        NOT NULL,
    from_key   text        NOT NULL,
    to_label   text        NOT NULL,
    to_key     text        NOT NULL,
    edge_key   text        NOT NULL,     -- disambiguates parallel relationships
    properties jsonb       NOT NULL,
    loaded_at  timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT graph_edge_pkey
        PRIMARY KEY (rel_type, from_label, from_key, to_label, to_key, edge_key),
    CONSTRAINT graph_edge_from_fk FOREIGN KEY (from_label, from_key)
        REFERENCES gold.graph_node ON DELETE CASCADE,
    CONSTRAINT graph_edge_to_fk FOREIGN KEY (to_label, to_key)
        REFERENCES gold.graph_node ON DELETE CASCADE,
    CONSTRAINT graph_edge_rel_type_check CHECK (rel_type IN
        ('ROUTE_SEGMENT', 'CONNECTS', 'NEAR_SCHOOL', 'IN_LGA', 'SERVES'))
);

CREATE INDEX IF NOT EXISTS graph_edge_rel_idx  ON gold.graph_edge (rel_type);
CREATE INDEX IF NOT EXISTS graph_edge_from_idx ON gold.graph_edge (from_label, from_key);
CREATE INDEX IF NOT EXISTS graph_edge_to_idx   ON gold.graph_edge (to_label, to_key);

DELETE FROM gold.graph_edge;

-- (Stop)-[:ROUTE_SEGMENT]->(Stop): the GTFS edge, per route and direction.
INSERT INTO gold.graph_edge
    (rel_type, from_label, from_key, to_label, to_key, edge_key, properties)
SELECT 'ROUTE_SEGMENT',
       'Stop', e.from_stop_id::text,
       'Stop', e.to_stop_id::text,
       e.edge_key,
       jsonb_strip_nulls(jsonb_build_object(
           'route_id',            e.route_id,
           'route_short_name',    e.route_short_name,
           'direction_id',        e.direction_id,
           'straight_line_m',     e.straight_line_m,
           'peak_s',              t.peak_s,
           'offpeak_s',           t.offpeak_s,
           'peak_trips',          t.peak_trips,
           'offpeak_trips',       t.offpeak_trips,
           'flag_zero_timepoint', t.any_zero,
           'flag_layover',        t.any_layover))
  FROM silver.bus_edge e
  LEFT JOIN (
      SELECT edge_key,
             max(avg_travel_time_s) FILTER (WHERE time_band = 'peak')    AS peak_s,
             max(avg_travel_time_s) FILTER (WHERE time_band = 'offpeak') AS offpeak_s,
             max(n_trips)           FILTER (WHERE time_band = 'peak')    AS peak_trips,
             max(n_trips)           FILTER (WHERE time_band = 'offpeak') AS offpeak_trips,
             bool_or(flag_zero_timepoint)                                AS any_zero,
             bool_or(flag_layover)                                       AS any_layover
        FROM silver.bus_edge_travel_time
       GROUP BY edge_key) t USING (edge_key);

-- (Stop)-[:CONNECTS]->(Stop): the routing edge, one per stop pair.
INSERT INTO gold.graph_edge
    (rel_type, from_label, from_key, to_label, to_key, edge_key, properties)
WITH timed AS (
    SELECT e.from_stop_id, e.to_stop_id, e.route_short_name, e.straight_line_m,
           t.time_band, t.avg_travel_time_s, t.n_trips, t.flag_zero_timepoint
      FROM silver.bus_edge e
      JOIN silver.bus_edge_travel_time t USING (edge_key)
), collapsed AS (
    SELECT from_stop_id, to_stop_id,
           count(DISTINCT route_short_name)::integer AS n_routes,
           array_agg(DISTINCT route_short_name)      AS routes,
           min(straight_line_m)                      AS straight_line_m,
           -- fastest, ignoring the whole-minute 0 s artefacts
           min(avg_travel_time_s) FILTER (
               WHERE time_band = 'peak' AND NOT flag_zero_timepoint)    AS best_peak_s,
           min(avg_travel_time_s) FILTER (
               WHERE time_band = 'offpeak' AND NOT flag_zero_timepoint) AS best_offpeak_s,
           -- trip-weighted average across the routes serving the pair
           (sum(avg_travel_time_s * n_trips) FILTER (WHERE time_band = 'peak')
            / nullif(sum(n_trips) FILTER (WHERE time_band = 'peak'), 0))::numeric(10,2)
                                                                        AS avg_peak_s,
           (sum(avg_travel_time_s * n_trips) FILTER (WHERE time_band = 'offpeak')
            / nullif(sum(n_trips) FILTER (WHERE time_band = 'offpeak'), 0))::numeric(10,2)
                                                                        AS avg_offpeak_s,
           sum(n_trips) FILTER (WHERE time_band = 'peak')::integer       AS peak_trips
      FROM timed
     GROUP BY from_stop_id, to_stop_id
)
SELECT 'CONNECTS',
       'Stop', from_stop_id::text,
       'Stop', to_stop_id::text,
       '',                                  -- one per pair, so no disambiguator
       jsonb_strip_nulls(jsonb_build_object(
           'n_routes',          n_routes,
           'route_short_names', to_jsonb(routes),
           'straight_line_m',   straight_line_m,
           'best_peak_s',       best_peak_s,
           'best_offpeak_s',    best_offpeak_s,
           'avg_peak_s',        avg_peak_s,
           'avg_offpeak_s',     avg_offpeak_s,
           'peak_trips',        peak_trips))
       -- the routing weight, always present; jsonb_strip_nulls above must not
       -- be able to remove it, so it is merged in afterwards
       || jsonb_build_object(
           'travel_time_s', round(greatest(coalesce(
                nullif(best_peak_s, 0), nullif(avg_peak_s, 0),
                nullif(best_offpeak_s, 0), nullif(avg_offpeak_s, 0),
                straight_line_m / 5.56),        -- 20 km/h in m/s
              1.0), 2),
           'weight_source',
                CASE WHEN nullif(best_peak_s, 0)    IS NOT NULL THEN 'best_peak'
                     WHEN nullif(avg_peak_s, 0)     IS NOT NULL THEN 'avg_peak'
                     WHEN nullif(best_offpeak_s, 0) IS NOT NULL THEN 'best_offpeak'
                     WHEN nullif(avg_offpeak_s, 0)  IS NOT NULL THEN 'avg_offpeak'
                     ELSE 'distance_estimate' END,
           'flag_weight_imputed', nullif(best_peak_s, 0) IS NULL)
  FROM collapsed;

-- (Stop)-[:NEAR_SCHOOL]->(School): the 200 m proximity, many-to-many.
INSERT INTO gold.graph_edge
    (rel_type, from_label, from_key, to_label, to_key, edge_key, properties)
SELECT 'NEAR_SCHOOL',
       'Stop',   b.stop_id::text,
       'School', b.school_code::text,
       '',
       jsonb_build_object(
           'distance_m',       b.distance_m,
           'rank_from_stop',   b.rank_from_stop,
           'rank_from_school', b.rank_from_school)
  FROM silver.bus_stop_school b
 WHERE b.radius_m = 200
   AND EXISTS (SELECT 1 FROM gold.graph_node n
                WHERE n.label = 'School' AND n.node_key = b.school_code::text);

-- (Stop)-[:IN_LGA]->(LGA)
INSERT INTO gold.graph_edge
    (rel_type, from_label, from_key, to_label, to_key, edge_key, properties)
SELECT 'IN_LGA',
       'Stop', sl.stop_id::text,
       'LGA',  sl.lga_code,
       '',
       jsonb_build_object(
           'assignment_method',   sl.assignment_method,
           'n_da_points',         sl.n_da_points,
           'flag_low_confidence', sl.flag_low_confidence)
  FROM silver.bus_stop_lga sl
 WHERE EXISTS (SELECT 1 FROM gold.graph_node n
                WHERE n.label = 'LGA' AND n.node_key = sl.lga_code);

-- (School)-[:IN_LGA]->(LGA)
INSERT INTO gold.graph_edge
    (rel_type, from_label, from_key, to_label, to_key, edge_key, properties)
SELECT 'IN_LGA',
       'School', s.school_code::text,
       'LGA',    silver.lga_key(s.lga),
       '',
       '{}'::jsonb
  FROM silver.school s
 WHERE s.is_usable
   AND s.lga IS NOT NULL
   AND EXISTS (SELECT 1 FROM gold.graph_node n
                WHERE n.label = 'LGA' AND n.node_key = silver.lga_key(s.lga));

-- (Route)-[:SERVES]->(Stop): from the routes_served array silver already parsed.
INSERT INTO gold.graph_edge
    (rel_type, from_label, from_key, to_label, to_key, edge_key, properties)
SELECT DISTINCT
       'SERVES',
       'Route', r.route_id,
       'Stop',  s.stop_id::text,
       '',
       '{}'::jsonb
  FROM silver.bus_stop s
  CROSS JOIN unnest(s.routes_served) AS short_name
  JOIN silver.route r ON r.route_short_name = short_name;
