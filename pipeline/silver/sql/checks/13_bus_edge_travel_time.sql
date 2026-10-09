-- Checks for the travel-time aggregate.
--
-- The headline risk is a silently wrong average, which no row count would
-- reveal. These checks target the specific ways this source misleads: NULL
-- meaning "no service", 0 s meaning "same timepoint minute", and the fact that
-- an unweighted mean over trip-pattern variants looks perfectly plausible.

SELECT 'silver.bus_edge_travel_time'::text, 'trips_reconcile'::text,
       'completeness'::text, 'error'::text,
       -- every source trip must land in exactly one band total
       abs((SELECT coalesce(sum(n_trips), 0) FROM silver.bus_edge_travel_time
             WHERE time_band = 'peak')
           - (SELECT coalesce(sum(e.n_trips_peak), 0) FROM bronze.bus_graph_edges e
               JOIN silver.bus_edge_source s USING (edge_id)
              WHERE e.avg_travel_time_peak_s IS NOT NULL AND e.n_trips_peak > 0))::bigint,
       (SELECT coalesce(sum(n_trips), 0) FROM silver.bus_edge_travel_time
         WHERE time_band = 'peak')::bigint,
       NULL::numeric, NULL::jsonb
UNION ALL
-- A NULL average always pairs with n_trips = 0 across all 135,097 source rows,
-- which is what licenses dropping those rows as "no service". If a NULL ever
-- arrives WITH trips, the assumption is broken and the averages are wrong.
SELECT 'silver.bus_edge_travel_time', 'null_means_no_service', 'validity', 'error',
       (SELECT count(*) FROM bronze.bus_graph_edges
         WHERE (avg_travel_time_peak_s    IS NULL AND coalesce(n_trips_peak, 0)    <> 0)
            OR (avg_travel_time_offpeak_s IS NULL AND coalesce(n_trips_offpeak, 0) <> 0)),
       (SELECT count(*) FROM bronze.bus_graph_edges), NULL, NULL
UNION ALL
SELECT 'silver.bus_edge_travel_time', 'travel_time_non_negative', 'validity', 'error',
       (SELECT count(*) FROM silver.bus_edge_travel_time WHERE avg_travel_time_s < 0),
       (SELECT count(*) FROM silver.bus_edge_travel_time), NULL, NULL
UNION ALL
-- Whole-minute GTFS timepoints make adjacent stops share a timestamp, so 0 s is
-- real data, not corruption. It must stay flagged and out of speed figures, or
-- travel times read optimistically fast.
SELECT 'silver.bus_edge_travel_time', 'zero_timepoint_share', 'accuracy', 'warn',
       (SELECT count(*) FROM silver.bus_edge_travel_time WHERE flag_zero_timepoint),
       (SELECT count(*) FROM silver.bus_edge_travel_time), 0.30,
       (SELECT jsonb_build_object('zero_rows', count(*) FILTER (WHERE flag_zero_timepoint),
                                  'note', 'GTFS timepoints are whole minutes')
          FROM silver.bus_edge_travel_time)
UNION ALL
SELECT 'silver.bus_edge_travel_time', 'speed_excluded_when_zero', 'consistency', 'error',
       (SELECT count(*) FROM silver.bus_edge_travel_time
         WHERE flag_zero_timepoint AND avg_speed_kmh IS NOT NULL),
       (SELECT count(*) FROM silver.bus_edge_travel_time), NULL, NULL
UNION ALL
SELECT 'silver.bus_edge_travel_time', 'layover_outliers', 'accuracy', 'warn',
       (SELECT count(*) FROM silver.bus_edge_travel_time WHERE flag_layover),
       (SELECT count(*) FROM silver.bus_edge_travel_time), 0.01,
       (SELECT jsonb_build_object('max_s', max(avg_travel_time_s))
          FROM silver.bus_edge_travel_time)
UNION ALL
SELECT 'silver.bus_edge_travel_time', 'implausible_speed', 'accuracy', 'warn',
       (SELECT count(*) FROM silver.bus_edge_travel_time WHERE flag_implausible_speed),
       (SELECT count(*) FROM silver.bus_edge_travel_time), 0.10, NULL
UNION ALL
SELECT 'silver.bus_edge_travel_time', 'low_sample', 'accuracy', 'warn',
       (SELECT count(*) FROM silver.bus_edge_travel_time WHERE flag_low_sample),
       (SELECT count(*) FROM silver.bus_edge_travel_time), 0.40, NULL
UNION ALL
-- Peak should not be systematically faster than off-peak. If it is, the two
-- columns were swapped somewhere upstream.
SELECT 'silver.bus_edge_travel_time', 'peak_not_faster_than_offpeak', 'accuracy', 'warn',
       (SELECT CASE WHEN avg(avg_travel_time_s) FILTER (WHERE time_band = 'peak')
                         < avg(avg_travel_time_s) FILTER (WHERE time_band = 'offpeak') * 0.95
                    THEN 1 ELSE 0 END
          FROM silver.bus_edge_travel_time)::bigint,
       1::bigint, NULL,
       (SELECT jsonb_build_object(
            'avg_peak_s',    round(avg(avg_travel_time_s) FILTER (WHERE time_band = 'peak'), 2),
            'avg_offpeak_s', round(avg(avg_travel_time_s) FILTER (WHERE time_band = 'offpeak'), 2))
          FROM silver.bus_edge_travel_time);
