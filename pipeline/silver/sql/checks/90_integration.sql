-- Cross-source checks: does the layer actually hang together on the spine?
--
-- coverage_report is not a pass/fail rule - it records, per measure, how many
-- stops actually got a value. Low coverage is a finding to report, not a
-- failure, and it is the honest answer to "is this column usable yet".

SELECT 'silver.bus_stop_profile'::text, 'one_row_per_stop'::text,
       'completeness'::text, 'error'::text,
       abs((SELECT count(*) FROM silver.bus_stop_profile)
           - (SELECT count(*) FROM silver.bus_stop))::bigint,
       (SELECT count(*) FROM silver.bus_stop)::bigint,
       NULL::numeric, NULL::jsonb
UNION ALL
SELECT 'silver.bus_stop_profile', 'geom_not_null', 'completeness', 'error',
       (SELECT count(*) FROM silver.bus_stop_profile WHERE geom IS NULL OR geom_m IS NULL),
       (SELECT count(*) FROM silver.bus_stop_profile), NULL, NULL
UNION ALL
-- Every hex_id anywhere in silver must exist in the grid, or a join silently
-- drops rows instead of failing.
SELECT 'silver.hex_300m', 'hex_ids_resolve', 'consistency', 'error',
       (SELECT count(*) FROM (
            SELECT hex_id FROM silver.bus_stop        WHERE hex_id IS NOT NULL
            UNION
            SELECT hex_id FROM silver.da_application  WHERE hex_id IS NOT NULL
            UNION
            SELECT hex_id FROM silver.property_sale   WHERE hex_id IS NOT NULL
            UNION
            SELECT hex_id FROM silver.school          WHERE hex_id IS NOT NULL) u
         WHERE NOT EXISTS (SELECT 1 FROM silver.hex_300m h WHERE h.hex_id = u.hex_id)),
       (SELECT count(*) FROM silver.hex_300m), NULL, NULL
UNION ALL
-- Every stop's k-ring must be fully present in the grid, otherwise a k-ring
-- average is computed over fewer cells than it claims.
SELECT 'silver.hex_300m_neighbour', 'kring_complete_for_stops', 'consistency', 'error',
       (SELECT count(*) FROM silver.bus_stop s
         WHERE s.hex_id IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM silver.hex_300m_neighbour n
                            WHERE n.hex_id = s.hex_id)),
       (SELECT count(*) FROM silver.bus_stop), NULL, NULL
UNION ALL
-- has_* must agree with the data actually present, since a report relies on
-- them to tell "nothing there" from "not loaded".
SELECT 'silver.bus_stop_profile', 'coverage_flags_honest', 'consistency', 'error',
       (SELECT count(*) FROM silver.bus_stop_profile
         WHERE (has_school_data  AND n_schools_200m IS NULL)
            OR (has_transit_data AND n_edges = 0)
            OR (NOT has_school_data  AND n_schools_200m IS NOT NULL)
            OR (has_traffic_data AND n_segments_500m IS NULL)),
       (SELECT count(*) FROM silver.bus_stop_profile), NULL, NULL
UNION ALL
SELECT 'silver.bus_stop_profile', 'coverage_report', 'completeness', 'warn',
       0::bigint,
       (SELECT count(*) FROM silver.bus_stop_profile)::bigint, NULL,
       (SELECT jsonb_build_object(
            'stops',            count(*),
            'with_da',          count(*) FILTER (WHERE has_da_data),
            'with_sales',       count(*) FILTER (WHERE has_sales_data),
            'with_school_200m', count(*) FILTER (WHERE has_school_data),
            'with_traffic',     count(*) FILTER (WHERE has_traffic_data),
            'with_transit',     count(*) FILTER (WHERE has_transit_data))
          FROM silver.bus_stop_profile);
