-- Checks for the conformed LGA dimension, the rent table and the stop->LGA
-- assignment.
--
-- lga_key_conforms is the one that matters most: the whole point of the
-- dimension is that four differently-spelled sources resolve to the same key.
-- If that stops being true, every cross-source comparison silently loses rows
-- instead of failing - the mart would just show fewer LGAs.

SELECT 'silver.lga'::text, 'lga_key_conforms'::text, 'consistency'::text,
       'error'::text,
       -- every DA council must also be reachable from the sales districts and
       -- the school LGAs through the same key
       (SELECT count(*) FROM (
            SELECT silver.lga_key(council_name) AS k
              FROM silver.da_application
             WHERE council_name IS NOT NULL
             GROUP BY 1) d
         WHERE NOT EXISTS (SELECT 1 FROM silver.property_sale p
                            WHERE silver.lga_key(p.district_name) = d.k)
            OR NOT EXISTS (SELECT 1 FROM silver.school s
                            WHERE silver.lga_key(s.lga) = d.k)),
       (SELECT count(DISTINCT silver.lga_key(council_name))
          FROM silver.da_application WHERE council_name IS NOT NULL)::bigint,
       NULL::numeric,
       (SELECT jsonb_build_object(
            'lgas_in_dimension', count(*),
            'known_to_da', count(*) FILTER (WHERE source_da),
            'known_to_sales', count(*) FILTER (WHERE source_psi),
            'known_to_school', count(*) FILTER (WHERE source_school),
            'known_to_rent', count(*) FILTER (WHERE source_rent))
          FROM silver.lga)
UNION ALL
-- All 6 rent LGAs must resolve, or the rent column cannot be joined at all.
SELECT 'silver.lga', 'rent_lgas_resolve', 'consistency', 'error',
       (SELECT count(*) FROM bronze.rent_data b
         WHERE b.lga_name IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM silver.lga l
                            WHERE l.lga_code = silver.lga_key(b.lga_name))),
       (SELECT count(*) FROM bronze.rent_data), NULL, NULL
UNION ALL
-- One key must never collapse two genuinely different councils together.
SELECT 'silver.lga', 'no_key_collisions', 'uniqueness', 'error',
       (SELECT count(*) FROM (
            SELECT silver.lga_key(council_name)
              FROM silver.da_application
             WHERE council_name IS NOT NULL
             GROUP BY 1
            HAVING count(DISTINCT council_name) > 1) q),
       (SELECT count(DISTINCT silver.lga_key(council_name))
          FROM silver.da_application WHERE council_name IS NOT NULL)::bigint,
       NULL, NULL
UNION ALL
SELECT 'silver.bus_stop_lga', 'stop_lga_coverage', 'completeness', 'error',
       (SELECT count(*) FROM silver.bus_stop s
         WHERE NOT EXISTS (SELECT 1 FROM silver.bus_stop_lga l
                            WHERE l.stop_id = s.stop_id)),
       (SELECT count(*) FROM silver.bus_stop), 0.10,
       (SELECT jsonb_object_agg(assignment_method, n) FROM (
            SELECT assignment_method, count(*) n FROM silver.bus_stop_lga
             GROUP BY 1) q)
UNION ALL
-- Near a real boundary the DA majority is genuinely ambiguous. Flagged, not
-- failed - but the share is capped so a regression in the method shows up.
SELECT 'silver.bus_stop_lga', 'assignment_confidence', 'accuracy', 'warn',
       (SELECT count(*) FROM silver.bus_stop_lga WHERE flag_low_confidence),
       (SELECT count(*) FROM silver.bus_stop_lga), 0.15,
       (SELECT jsonb_build_object(
            'nearest_da_p50_m', round(percentile_cont(0.5)
                WITHIN GROUP (ORDER BY nearest_da_distance_m)),
            'nearest_da_p90_m', round(percentile_cont(0.9)
                WITHIN GROUP (ORDER BY nearest_da_distance_m)),
            'da_points_p50', percentile_cont(0.5)
                WITHIN GROUP (ORDER BY n_da_points))
          FROM silver.bus_stop_lga)
UNION ALL
-- A suppressed rent ('x') is withheld, not zero. If a NULL ever became a
-- number, every rent ranking would be quietly wrong.
SELECT 'silver.rent_lga', 'suppressed_not_zero', 'validity', 'error',
       (SELECT count(*) FROM silver.rent_lga
         WHERE (flag_suppressed AND median_weekly_rent IS NOT NULL)
            OR (median_weekly_rent IS NOT NULL AND median_weekly_rent <= 0)),
       (SELECT count(*) FROM silver.rent_lga), NULL, NULL
UNION ALL
SELECT 'silver.rent_lga', 'row_count_vs_bronze', 'completeness', 'error',
       abs((SELECT count(*) FROM silver.rent_lga)
           - (SELECT count(*) FROM bronze.rent_data))::bigint,
       (SELECT count(*) FROM bronze.rent_data)::bigint, NULL, NULL
UNION ALL
-- The "latest" view must return exactly one row per LGA and dwelling type, or
-- two consumers would disagree about which quarter the current rent is.
SELECT 'silver.rent_lga_latest', 'one_row_per_lga_dwelling', 'uniqueness', 'error',
       (SELECT count(*) FROM (
            SELECT lga_code, dwelling_type FROM silver.rent_lga_latest
             GROUP BY 1, 2 HAVING count(*) > 1) q),
       (SELECT count(*) FROM silver.rent_lga_latest), NULL,
       (SELECT jsonb_build_object('rows', count(*),
                                  'lgas', count(DISTINCT lga_code))
          FROM silver.rent_lga_latest)
UNION ALL
SELECT 'silver.route', 'row_count_vs_bronze_route_ids', 'completeness', 'error',
       abs((SELECT count(*) FROM silver.route)
           - (SELECT count(DISTINCT route_id) FROM bronze.bus_routes))::bigint,
       (SELECT count(DISTINCT route_id) FROM bronze.bus_routes)::bigint, NULL, NULL
UNION ALL
SELECT 'silver.bus_stop_profile', 'rent_flag_consistent', 'consistency', 'error',
       (SELECT count(*) FROM silver.bus_stop_profile
         WHERE has_rent_data <> (rent_median_weekly_house IS NOT NULL
                                 OR rent_median_weekly_flat IS NOT NULL)),
       (SELECT count(*) FROM silver.bus_stop_profile), NULL,
       (SELECT jsonb_build_object(
            'stops_with_rent', count(*) FILTER (WHERE has_rent_data),
            'stops_total', count(*))
          FROM silver.bus_stop_profile);
