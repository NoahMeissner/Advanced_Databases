-- Checks for silver.da_application.
--
-- The published coordinates are the weak point here, so three checks attack
-- them from different angles: presence, study area, and agreement with the
-- application's own council.

SELECT 'silver.da_application'::text, 'row_count_vs_bronze'::text,
       'completeness'::text, 'error'::text,
       abs((SELECT count(*) FROM silver.da_application)
           - (SELECT count(*) FROM bronze.da_applications))::bigint,
       (SELECT count(*) FROM bronze.da_applications)::bigint,
       NULL::numeric, NULL::jsonb
UNION ALL
SELECT 'silver.da_application', 'pk_unique', 'uniqueness', 'error',
       (SELECT count(*) - count(DISTINCT application_number) FROM silver.da_application),
       (SELECT count(*) FROM silver.da_application), NULL, NULL
UNION ALL
SELECT 'silver.da_application', 'coords_present', 'completeness', 'warn',
       (SELECT count(*) FROM silver.da_application WHERE flag_missing_coords),
       (SELECT count(*) FROM silver.da_application), 0.001, NULL
UNION ALL
-- The check a bounding box cannot do: compare each point against the median
-- point of its OWN council. A Bayside Council application plotted near Albury
-- is inside NSW and would pass any bbox test.
SELECT 'silver.da_application', 'coord_matches_council', 'accuracy', 'warn',
       (SELECT count(*) FROM silver.da_application WHERE flag_bad_geocode),
       (SELECT count(*) FROM silver.da_application), 0.02,
       (SELECT jsonb_build_object('examples', jsonb_agg(application_number))
          FROM (SELECT application_number FROM silver.da_application
                 WHERE flag_bad_geocode ORDER BY application_number LIMIT 5) q)
UNION ALL
-- Several applications at one identical point across different addresses is the
-- signature of a geocoder falling back to a centroid.
SELECT 'silver.da_application', 'geocode_collision', 'accuracy', 'warn',
       (SELECT count(*) FROM silver.da_application WHERE flag_geocode_collision),
       (SELECT count(*) FROM silver.da_application), 0.10, NULL
UNION ALL
SELECT 'silver.da_application', 'outside_study_area', 'validity', 'warn',
       (SELECT count(*) FROM silver.da_application WHERE flag_outside_aoi),
       (SELECT count(*) FROM silver.da_application), 0.05, NULL
UNION ALL
SELECT 'silver.da_application', 'date_order', 'consistency', 'warn',
       (SELECT count(*) FROM silver.da_application WHERE flag_date_order),
       (SELECT count(*) FROM silver.da_application), 0.02, NULL
UNION ALL
SELECT 'silver.da_application', 'determined_has_date', 'consistency', 'warn',
       (SELECT count(*) FROM silver.da_application
         WHERE application_status = 'Determined' AND determination_date IS NULL),
       (SELECT count(*) FROM silver.da_application), 0.02, NULL
UNION ALL
SELECT 'silver.da_application', 'determination_date_range', 'validity', 'warn',
       (SELECT count(*) FROM silver.da_application
         WHERE determination_date IS NOT NULL
           AND (determination_date < date '1990-01-01'
                OR determination_date > current_date + interval '1 year')),
       (SELECT count(*) FROM silver.da_application), 0.01,
       (SELECT jsonb_build_object('min', min(determination_date), 'max', max(determination_date))
          FROM silver.da_application)
UNION ALL
SELECT 'silver.da_application', 'cost_non_negative', 'validity', 'error',
       (SELECT count(*) FROM silver.da_application WHERE cost_of_development < 0),
       (SELECT count(*) FROM silver.da_application), NULL, NULL
UNION ALL
-- The published maximum is 21,625,742,730. One such row sets the mean for its
-- whole hexagon, so the tails are flagged and excluded from aggregates.
SELECT 'silver.da_application', 'cost_outlier', 'accuracy', 'warn',
       (SELECT count(*) FROM silver.da_application WHERE flag_cost_outlier),
       (SELECT count(*) FROM silver.da_application), 0.01,
       (SELECT jsonb_build_object('max_cost', max(cost_of_development))
          FROM silver.da_application)
UNION ALL
SELECT 'silver.da_application', 'dwellings_sane', 'validity', 'warn',
       (SELECT count(*) FROM silver.da_application
         WHERE number_of_new_dwellings NOT BETWEEN 0 AND 5000
            OR number_of_storeys       NOT BETWEEN 0 AND 100),
       (SELECT count(*) FROM silver.da_application), 0.001, NULL
UNION ALL
-- The source publishes development_type_count alongside the ';'-separated
-- string, so the split is verifiable against the publisher's own count.
SELECT 'silver.da_development_type', 'split_matches_source_count', 'consistency', 'error',
       (SELECT count(*) FROM (
            SELECT b.planning_portal_application_number
              FROM bronze.da_applications b
              JOIN silver.da_development_type d
                ON d.application_number = b.planning_portal_application_number
             GROUP BY b.planning_portal_application_number, b.development_type_count
            HAVING b.development_type_count <> count(d.development_type)) q),
       (SELECT count(DISTINCT application_number) FROM silver.da_development_type), NULL, NULL
UNION ALL
-- Modification applications must stay out of the headline DA count, or one
-- development with five modifications reads as six developments.
SELECT 'silver.da_hex_300m', 'types_counted_separately', 'consistency', 'error',
       (SELECT abs(coalesce(sum(n_applications + n_modifications + n_reviews), 0)
                   - (SELECT count(*) FROM silver.da_application
                       WHERE is_usable AND hex_id IS NOT NULL))
          FROM silver.da_hex_300m WHERE period = 'all')::bigint,
       (SELECT count(*) FROM silver.da_application WHERE is_usable)::bigint, NULL,
       (SELECT jsonb_object_agg(application_type, n)
          FROM (SELECT application_type, count(*) n FROM silver.da_application
                 GROUP BY 1) q);
