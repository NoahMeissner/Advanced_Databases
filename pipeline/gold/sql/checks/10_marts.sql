-- Checks for the comparison marts.

SELECT 'gold.lga_comparison'::text, 'covers_lgas_with_stops'::text,
       'completeness'::text, 'error'::text,
       abs((SELECT count(*) FROM gold.lga_comparison)
           - (SELECT count(DISTINCT lga_code) FROM silver.bus_stop_lga))::bigint,
       (SELECT count(DISTINCT lga_code) FROM silver.bus_stop_lga)::bigint,
       NULL::numeric, NULL::jsonb
UNION ALL
-- Every stop must be counted under exactly one LGA, so the mart's stop counts
-- add up to the whole network.
SELECT 'gold.lga_comparison', 'stop_counts_reconcile', 'consistency', 'error',
       abs((SELECT coalesce(sum(n_stops), 0) FROM gold.lga_comparison)
           - (SELECT count(*) FROM silver.bus_stop_lga))::bigint,
       (SELECT count(*) FROM silver.bus_stop_lga)::bigint, NULL, NULL
UNION ALL
SELECT 'gold.lga_comparison', 'medians_plausible', 'accuracy', 'error',
       (SELECT count(*) FROM gold.lga_comparison
         WHERE median_sale_price IS NOT NULL
           AND median_sale_price NOT BETWEEN 100000 AND 20000000),
       (SELECT count(*) FROM gold.lga_comparison), NULL,
       (SELECT jsonb_build_object('min', min(median_sale_price),
                                  'max', max(median_sale_price))
          FROM gold.lga_comparison)
UNION ALL
SELECT 'gold.lga_comparison', 'rent_flag_consistent', 'consistency', 'error',
       (SELECT count(*) FROM gold.lga_comparison
         WHERE has_rent_data <> (median_rent_weekly_house IS NOT NULL
                                 OR median_rent_weekly_flat IS NOT NULL)),
       (SELECT count(*) FROM gold.lga_comparison), NULL, NULL
UNION ALL
-- Rent covers 6 of 33 LGAs. Recorded, not failed: it is the ceiling of the
-- source, and has_rent_data is what keeps it from being read as zero.
SELECT 'gold.lga_comparison', 'rent_coverage', 'completeness', 'warn',
       (SELECT count(*) FROM gold.lga_comparison WHERE NOT has_rent_data),
       (SELECT count(*) FROM gold.lga_comparison), 0.90,
       (SELECT jsonb_build_object(
            'lgas_with_rent', count(*) FILTER (WHERE has_rent_data),
            'lgas_total', count(*),
            'highest_rent_lga', (SELECT lga_name FROM gold.lga_comparison
                                  WHERE rank_median_rent_house = 1))
          FROM gold.lga_comparison)
UNION ALL
-- A rank must be dense and start at 1, or "highest" is meaningless.
SELECT 'gold.lga_comparison', 'ranks_well_formed', 'validity', 'error',
       (SELECT count(*) FROM gold.lga_comparison
         WHERE rank_n_stops IS NULL OR rank_da_applications IS NULL)
       + (SELECT CASE WHEN min(rank_n_stops) = 1 THEN 0 ELSE 1 END
            FROM gold.lga_comparison),
       (SELECT count(*) FROM gold.lga_comparison), NULL, NULL
UNION ALL
SELECT 'gold.traffic_ranking', 'covers_all_segments', 'completeness', 'error',
       abs((SELECT count(*) FROM gold.traffic_ranking)
           - (SELECT count(DISTINCT segment_id) FROM silver.traffic_segment_hourly))::bigint,
       (SELECT count(DISTINCT segment_id) FROM silver.traffic_segment_hourly)::bigint,
       NULL, NULL
UNION ALL
-- Rush must outrank night, or the hour axis is shifted somewhere.
SELECT 'gold.traffic_ranking', 'rush_exceeds_night', 'accuracy', 'error',
       (SELECT count(*) FROM gold.traffic_ranking
         WHERE avg_vph_rush IS NOT NULL AND avg_vph_night IS NOT NULL
           AND avg_vph_rush <= avg_vph_night),
       (SELECT count(*) FROM gold.traffic_ranking), NULL,
       (SELECT jsonb_build_object('top_segment', segment_id, 'rush_vph', avg_vph_rush)
          FROM gold.traffic_ranking WHERE rank_rush = 1)
UNION ALL
-- The whole traffic source is a 6-segment sample with no coordinates. Both
-- facts are flagged per row; this asserts the flags are actually set.
SELECT 'gold.traffic_ranking', 'sample_and_geometry_flagged', 'validity', 'warn',
       (SELECT count(*) FROM gold.traffic_ranking
         WHERE NOT flag_sample_data OR NOT flag_no_geometry),
       (SELECT count(*) FROM gold.traffic_ranking), NULL,
       jsonb_build_object('note',
           '6 synthetic segments, no coordinates - cannot be mapped to stops');
