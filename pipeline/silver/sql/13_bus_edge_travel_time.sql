-- silver.bus_edge_travel_time - how long an edge takes, per time band.
--
-- Long format on purpose: adding the 06-12 / 12-18 / 18-24 bands later (once a
-- raw GTFS feed exists) INSERTs rows, it does not alter the table.
--
--   time_band        now:   'peak', 'offpeak'
--                    later: 'morning_06_12', 'afternoon_12_18', 'evening_18_24'
--   service_profile  now:   'unknown' - the source feed's calendar is not
--                           preserved anywhere in the data or the repo, so the
--                           weekday/weekend split cannot be reconstructed.
--                    later: 'weekday' | 'saturday' | 'sunday'
--
-- THE TRIP-WEIGHTED MEAN IS THE WHOLE POINT. A logical edge is built from up to
-- 19 source rows that each already carry an average over n_trips. A plain avg()
-- of those averages lets a variant with 1 trip count as much as one with 21, so
-- it is wrong by a wide margin, not by rounding:
--
--   SUM(avg_travel_time * n_trips) / SUM(n_trips)
--
-- Rows with a NULL average are excluded: verified across all 135,097 source
-- rows, a NULL average always pairs with n_trips = 0, i.e. "no service in that
-- window" rather than "value missing". 0 s averages are real (GTFS timepoints
-- are whole minutes, so adjacent stops share a timestamp) and are kept, but
-- flagged and excluded from the speed figure.

CREATE TABLE IF NOT EXISTS silver.bus_edge_travel_time (
    edge_key               text        NOT NULL REFERENCES silver.bus_edge ON DELETE CASCADE,
    service_profile        text        NOT NULL,
    time_band              text        NOT NULL,
    avg_travel_time_s      numeric(10,2) NOT NULL,   -- trip-weighted
    -- the spread across the trip-pattern variants that were folded together.
    -- No true median/percentile is possible: the source rows are already
    -- averages, so the per-trip distribution did not survive upstream.
    min_source_avg_s       numeric(10,2) NOT NULL,
    max_source_avg_s       numeric(10,2) NOT NULL,
    n_trips                integer     NOT NULL,
    n_source_rows          integer     NOT NULL,
    avg_speed_kmh          numeric(8,2),             -- NULL when travel time is 0
    flag_zero_timepoint    boolean     NOT NULL DEFAULT false,
    flag_layover           boolean     NOT NULL DEFAULT false,
    flag_low_sample        boolean     NOT NULL DEFAULT false,
    flag_implausible_speed boolean     NOT NULL DEFAULT false,
    is_usable              boolean     NOT NULL DEFAULT true,
    record_source          text        NOT NULL DEFAULT 'SYDNEY_BUS_GRAPH_EDGES_GEOJSON',
    loaded_at              timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT bus_edge_travel_time_pkey PRIMARY KEY (edge_key, service_profile, time_band),
    CONSTRAINT bus_edge_travel_time_band_check CHECK (time_band IN (
        'peak', 'offpeak',
        'morning_06_12', 'afternoon_12_18', 'evening_18_24', 'night_00_06')),
    CONSTRAINT bus_edge_travel_time_trips_check CHECK (n_trips > 0)
);

CREATE INDEX IF NOT EXISTS bus_edge_travel_time_band_idx
    ON silver.bus_edge_travel_time (time_band) WHERE is_usable;

-- Fully derived from Bronze, so delete-then-insert for the two bands this step
-- owns. Scoped by time_band so a later GTFS step's bands are left untouched.
DELETE FROM silver.bus_edge_travel_time WHERE time_band IN ('peak', 'offpeak');

INSERT INTO silver.bus_edge_travel_time
    (edge_key, service_profile, time_band, avg_travel_time_s,
     min_source_avg_s, max_source_avg_s, n_trips, n_source_rows, avg_speed_kmh,
     flag_zero_timepoint, flag_layover, flag_low_sample, flag_implausible_speed, is_usable)
WITH src AS (
    SELECT s.edge_key, 'peak' AS time_band,
           e.avg_travel_time_peak_s AS avg_s, e.n_trips_peak AS n_trips
      FROM bronze.bus_graph_edges e
      JOIN silver.bus_edge_source s USING (edge_id)
     WHERE e.avg_travel_time_peak_s IS NOT NULL
       AND e.n_trips_peak > 0
    UNION ALL
    SELECT s.edge_key, 'offpeak',
           e.avg_travel_time_offpeak_s, e.n_trips_offpeak
      FROM bronze.bus_graph_edges e
      JOIN silver.bus_edge_source s USING (edge_id)
     WHERE e.avg_travel_time_offpeak_s IS NOT NULL
       AND e.n_trips_offpeak > 0
), agg AS (
    SELECT edge_key,
           time_band,
           sum(avg_s * n_trips) / sum(n_trips) AS avg_travel_time_s,
           min(avg_s)                          AS min_source_avg_s,
           max(avg_s)                          AS max_source_avg_s,
           sum(n_trips)::integer               AS n_trips,
           count(*)::integer                   AS n_source_rows
      FROM src
     GROUP BY edge_key, time_band
)
SELECT a.edge_key,
       'unknown',
       a.time_band,
       round(a.avg_travel_time_s, 2),
       a.min_source_avg_s,
       a.max_source_avg_s,
       a.n_trips,
       a.n_source_rows,
       CASE WHEN a.avg_travel_time_s > 0
            THEN round((e.straight_line_m / a.avg_travel_time_s) * 3.6, 2) END,
       a.avg_travel_time_s = 0,                            -- flag_zero_timepoint
       a.avg_travel_time_s > 1800,                         -- flag_layover
       a.n_trips < 3,                                      -- flag_low_sample
       CASE WHEN a.avg_travel_time_s > 0
            THEN (e.straight_line_m / a.avg_travel_time_s) * 3.6 NOT BETWEEN 1 AND 100
            ELSE false END,                                -- flag_implausible_speed
       a.avg_travel_time_s > 0 AND a.avg_travel_time_s <= 1800 AND a.n_trips >= 3
  FROM agg a
  JOIN silver.bus_edge e USING (edge_key);

-- Convenience view: one row per edge with the bands side by side. This is what
-- a human reads; the long table is what downstream code joins.
CREATE OR REPLACE VIEW silver.bus_edge_travel_time_wide AS
SELECT e.edge_key, e.from_stop_id, e.to_stop_id, e.route_short_name, e.direction_id,
       e.straight_line_m,
       max(t.avg_travel_time_s) FILTER (WHERE t.time_band = 'peak')          AS peak_s,
       max(t.avg_travel_time_s) FILTER (WHERE t.time_band = 'offpeak')       AS offpeak_s,
       max(t.avg_travel_time_s) FILTER (WHERE t.time_band = 'morning_06_12') AS morning_s,
       max(t.avg_travel_time_s) FILTER (WHERE t.time_band = 'afternoon_12_18') AS afternoon_s,
       max(t.avg_travel_time_s) FILTER (WHERE t.time_band = 'evening_18_24') AS evening_s,
       max(t.n_trips)           FILTER (WHERE t.time_band = 'peak')          AS peak_trips,
       max(t.n_trips)           FILTER (WHERE t.time_band = 'offpeak')       AS offpeak_trips
  FROM silver.bus_edge e
  LEFT JOIN silver.bus_edge_travel_time t USING (edge_key)
 GROUP BY e.edge_key, e.from_stop_id, e.to_stop_id, e.route_short_name,
          e.direction_id, e.straight_line_m;
