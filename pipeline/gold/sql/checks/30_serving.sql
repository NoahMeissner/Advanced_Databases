-- Checks for the two tables the website depends on.
--
-- These are the only Gold tables whose failure is invisible from the warehouse
-- side: a broken geocoder does not make any query fail, it just quietly
-- answers the wrong address or none at all.

SELECT 'gold.address_point'::text, 'both_tiers_present'::text,
       'completeness'::text, 'error'::text,
       (SELECT CASE WHEN count(DISTINCT precision) = 2 THEN 0 ELSE 1 END
          FROM gold.address_point)::bigint,
       1::bigint, NULL::numeric,
       (SELECT jsonb_object_agg(precision, n)
          FROM (SELECT precision, count(*) n FROM gold.address_point
                 GROUP BY 1) q)
UNION ALL
-- Every DA address that could be geocoded must be in the gazetteer, or the
-- search silently loses addresses it was supposed to know.
SELECT 'gold.address_point', 'covers_da_addresses', 'completeness', 'error',
       (SELECT count(*) FROM (
            SELECT DISTINCT upper(regexp_replace(trim(full_address),
                                                 '[^A-Za-z0-9]+', ' ', 'g')) AS k
              FROM silver.da_application
             WHERE is_usable AND nullif(trim(full_address), '') IS NOT NULL) d
         WHERE NOT EXISTS (SELECT 1 FROM gold.address_point a
                            WHERE a.search_key = d.k)),
       (SELECT count(DISTINCT full_address) FROM silver.da_application
         WHERE is_usable AND full_address IS NOT NULL)::bigint, NULL, NULL
UNION ALL
SELECT 'gold.address_point', 'geometry_present', 'validity', 'error',
       (SELECT count(*) FROM gold.address_point
         WHERE geom IS NULL OR geom_m IS NULL OR ST_IsEmpty(geom)),
       (SELECT count(*) FROM gold.address_point), NULL, NULL
UNION ALL
-- An address-tier row claims exact precision, so accuracy_m must be 0; a
-- street-tier row must NOT claim it.
SELECT 'gold.address_point', 'accuracy_matches_precision', 'consistency', 'error',
       (SELECT count(*) FROM gold.address_point
         WHERE (precision = 'address' AND accuracy_m <> 0)
            OR (precision = 'street' AND accuracy_m <= 0)),
       (SELECT count(*) FROM gold.address_point), NULL, NULL
UNION ALL
SELECT 'gold.address_point', 'inside_study_area', 'validity', 'warn',
       (SELECT count(*) FROM gold.address_point a
         WHERE NOT EXISTS (SELECT 1 FROM silver.aoi o
                            WHERE ST_Intersects(a.geom_m, o.geom_m))),
       (SELECT count(*) FROM gold.address_point), 0.02, NULL
UNION ALL
-- The trigram index is what keeps lookup interactive at ~148k rows. It must be
-- GiST specifically: GIN cannot serve the <-> ordering the queries rely on, and
-- falling back to it silently costs 302 ms per address instead of 39 ms.
SELECT 'gold.address_point', 'trigram_index_exists', 'validity', 'error',
       (SELECT CASE WHEN count(*) > 0 THEN 0 ELSE 1 END
          FROM pg_indexes
         WHERE schemaname = 'gold' AND tablename = 'address_point'
           AND indexdef ILIKE '%gist%' AND indexdef ILIKE '%trgm%')::bigint,
       1::bigint, NULL, NULL
UNION ALL
SELECT 'gold.transit_segment', 'matches_stop_pairs', 'completeness', 'error',
       abs((SELECT count(*) FROM gold.transit_segment)
           - (SELECT count(*) FROM (
                  SELECT DISTINCT e.from_stop_id, e.to_stop_id
                    FROM silver.bus_edge e
                    JOIN silver.bus_edge_travel_time t USING (edge_key)) q))::bigint,
       (SELECT count(*) FROM gold.transit_segment)::bigint, NULL, NULL
UNION ALL
SELECT 'gold.transit_segment', 'trips_positive', 'validity', 'error',
       (SELECT count(*) FROM gold.transit_segment WHERE trips_per_day <= 0),
       (SELECT count(*) FROM gold.transit_segment), NULL, NULL
UNION ALL
-- ntile(5) must actually produce five roughly equal bands, or the map's colour
-- ramp stops meaning anything.
SELECT 'gold.transit_segment', 'bands_are_quintiles', 'accuracy', 'error',
       (SELECT CASE WHEN max(n) - min(n) <= 1 AND count(*) = 5 THEN 0 ELSE 1 END
          FROM (SELECT activity_band, count(*) n FROM gold.transit_segment
                 GROUP BY 1) q)::bigint,
       1::bigint, NULL,
       (SELECT jsonb_object_agg(activity_band, n)
          FROM (SELECT activity_band, count(*) n FROM gold.transit_segment
                 GROUP BY 1) q)
UNION ALL
-- The long segments are real but undrawable as street bands, so the map
-- excludes them; this records how much is being left out.
SELECT 'gold.transit_segment', 'long_segments_flagged', 'accuracy', 'warn',
       (SELECT count(*) FROM gold.transit_segment WHERE flag_long_segment),
       (SELECT count(*) FROM gold.transit_segment), 0.05,
       (SELECT jsonb_build_object('max_length_m', round(max(length_m)),
                                  'median_length_m',
                                  round(percentile_cont(0.5)
                                      WITHIN GROUP (ORDER BY length_m)))
          FROM gold.transit_segment);
