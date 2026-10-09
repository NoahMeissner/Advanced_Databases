-- gold.transit_segment - how busy the street outside is, as far as we can tell.
--
-- The design's section 02 is Noise: decibels, "nearest main road 120 m", heat
-- bands along roads. NO noise data exists in this project, and no road
-- centrelines either - the traffic source is 6 synthetic segments with no
-- coordinates. So rather than invent decibels, this measures what we do have:
-- scheduled bus traffic on real geometry.
--
--   28,340 segments, one per stop pair, with the 2-point line between them
--   trips_per_day 1 / 33 / 1,279 (min / median / max) - a real gradient
--
-- It is a TRANSIT ACTIVITY proxy and the UI says so. A busy bus corridor is a
-- reasonable stand-in for a busy street front; it is not a sound measurement,
-- and nothing here is labelled dB.
--
-- flag_long_segment marks the few segments over 2 km (the longest is 27 km
-- against a 273 m median). They are real express hops, but drawn as a "street
-- band" they would streak across the city, so the map layer excludes them.

CREATE TABLE IF NOT EXISTS gold.transit_segment (
    from_stop_id      integer     NOT NULL REFERENCES silver.bus_stop,
    to_stop_id        integer     NOT NULL REFERENCES silver.bus_stop,
    geom              geometry(LineString, 4326) NOT NULL,
    geom_m            geometry(LineString, 7856) NOT NULL,
    length_m          numeric(12,2) NOT NULL,
    trips_per_day     integer     NOT NULL,
    n_routes          integer     NOT NULL,
    route_short_names text[]      NOT NULL DEFAULT '{}',
    activity_band     smallint    NOT NULL,   -- 1 (quietest) .. 5 (busiest)
    flag_long_segment boolean     NOT NULL DEFAULT false,
    loaded_at         timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT transit_segment_pkey PRIMARY KEY (from_stop_id, to_stop_id),
    CONSTRAINT transit_segment_trips_check CHECK (trips_per_day > 0),
    CONSTRAINT transit_segment_band_check CHECK (activity_band BETWEEN 1 AND 5)
);

CREATE INDEX IF NOT EXISTS transit_segment_geom_m_idx
    ON gold.transit_segment USING gist (geom_m);
CREATE INDEX IF NOT EXISTS transit_segment_band_idx
    ON gold.transit_segment (activity_band);

DELETE FROM gold.transit_segment;

INSERT INTO gold.transit_segment
    (from_stop_id, to_stop_id, geom, geom_m, length_m, trips_per_day,
     n_routes, route_short_names, activity_band, flag_long_segment)
WITH collapsed AS (
    -- several routes share a stop pair, so their trips add up: that is the
    -- point, it is how busy the segment is in total
    SELECT e.from_stop_id,
           e.to_stop_id,
           (array_agg(e.geom   ORDER BY e.edge_key))[1] AS geom,
           (array_agg(e.geom_m ORDER BY e.edge_key))[1] AS geom_m,
           min(e.straight_line_m)                       AS length_m,
           sum(t.n_trips)::integer                      AS trips_per_day,
           count(DISTINCT e.route_short_name)::integer   AS n_routes,
           coalesce(array_agg(DISTINCT e.route_short_name)
                    FILTER (WHERE e.route_short_name IS NOT NULL), '{}') AS routes
      FROM silver.bus_edge e
      JOIN silver.bus_edge_travel_time t USING (edge_key)
     GROUP BY e.from_stop_id, e.to_stop_id
)
SELECT from_stop_id, to_stop_id, geom, geom_m, length_m, trips_per_day,
       n_routes, routes,
       ntile(5) OVER (ORDER BY trips_per_day),
       length_m > 2000
  FROM collapsed;
