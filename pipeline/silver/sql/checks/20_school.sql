-- Checks for silver.school.
--
-- This source cleans itself upstream and leaves the trail in *_raw / *_status
-- column pairs. That trail is free quality signal, so several checks here
-- assert the publisher's own verdict rather than re-deriving it.

SELECT 'silver.school'::text, 'row_count_vs_bronze'::text, 'completeness'::text,
       'error'::text,
       abs((SELECT count(*) FROM silver.school)
           - (SELECT count(*) FROM bronze.school_location))::bigint,
       (SELECT count(*) FROM bronze.school_location)::bigint,
       NULL::numeric, NULL::jsonb
UNION ALL
SELECT 'silver.school', 'coords_present', 'completeness', 'error',
       (SELECT count(*) FROM silver.school WHERE flag_missing_coords),
       (SELECT count(*) FROM silver.school), NULL, NULL
UNION ALL
-- The only CRS statement anywhere in the data. Every row says
-- 'EPSG:4326 (assumed)' / 'valid_assumed_wgs84'. Any other value means the
-- coordinates are in a different frame and every distance below shifts.
SELECT 'silver.school', 'coordinate_crs_expected', 'validity', 'error',
       (SELECT count(*) FROM bronze.school_location
         WHERE coalesce(coordinate_crs, '') <> 'EPSG:4326 (assumed)'
            OR coalesce(coordinate_status, '') <> 'valid_assumed_wgs84'),
       (SELECT count(*) FROM bronze.school_location), NULL,
       (SELECT jsonb_object_agg(coalesce(coordinate_crs, 'NULL'), n)
          FROM (SELECT coordinate_crs, count(*) n FROM bronze.school_location
                 GROUP BY 1) q)
UNION ALL
-- Suppressed small counts arrive as the literal 'np'. Bronze parks it in
-- *_raw and leaves the numeric column NULL; if the sentinel ever became a
-- number, every average over these columns would be silently wrong.
SELECT 'silver.school', 'suppressed_not_leaked', 'validity', 'error',
       (SELECT count(*) FROM bronze.school_location
         WHERE (indigenous_pct_raw = 'np' AND indigenous_pct IS NOT NULL)
            OR (lbote_pct_raw      = 'np' AND lbote_pct      IS NOT NULL)),
       (SELECT count(*) FROM bronze.school_location), NULL, NULL
UNION ALL
SELECT 'silver.school', 'icsea_in_range', 'validity', 'warn',
       (SELECT count(*) FROM silver.school
         WHERE icsea_value IS NOT NULL AND icsea_value NOT BETWEEN 500 AND 1400),
       (SELECT count(*) FROM silver.school), NULL,
       (SELECT jsonb_build_object('min', min(icsea_value), 'max', max(icsea_value))
          FROM silver.school)
UNION ALL
SELECT 'silver.school', 'enrolment_positive', 'validity', 'warn',
       (SELECT count(*) FROM silver.school
         WHERE latest_year_enrolment_fte IS NOT NULL AND latest_year_enrolment_fte <= 0),
       (SELECT count(*) FROM silver.school), NULL, NULL
UNION ALL
-- Half the schools are outside the study area (the source is NSW-wide, down to
-- Lord Howe Island). Expected, so this records the share rather than failing.
SELECT 'silver.school', 'outside_study_area', 'validity', 'warn',
       (SELECT count(*) FROM silver.school WHERE flag_outside_aoi),
       (SELECT count(*) FROM silver.school), 0.60, NULL
UNION ALL
-- Co-located campuses are real; identical coordinates can also be a bad
-- geocode. Warn so it gets eyeballed, never auto-dropped.
SELECT 'silver.school', 'duplicate_site', 'uniqueness', 'warn',
       (SELECT count(*) FROM silver.school a
         WHERE a.geom IS NOT NULL
           AND EXISTS (SELECT 1 FROM silver.school b
                        WHERE b.school_code <> a.school_code AND ST_Equals(b.geom, a.geom))),
       (SELECT count(*) FROM silver.school), 0.02, NULL
UNION ALL
-- The join this layer was asked for: a school 200 m from several stops must
-- appear against each one. Asserts the relationship really is many-to-many and
-- that no row sneaked past the radius.
SELECT 'silver.bus_stop_school', 'within_radius', 'validity', 'error',
       (SELECT count(*) FROM silver.bus_stop_school WHERE distance_m > radius_m),
       (SELECT count(*) FROM silver.bus_stop_school), NULL, NULL
UNION ALL
SELECT 'silver.bus_stop_school', 'is_many_to_many', 'consistency', 'error',
       (SELECT CASE WHEN max(n) > 1 THEN 0 ELSE 1 END
          FROM (SELECT count(*) n FROM silver.bus_stop_school
                 WHERE radius_m = 200 GROUP BY school_code) q)::bigint,
       1::bigint, NULL,
       (SELECT jsonb_build_object('max_stops_per_school', max(n))
          FROM (SELECT count(*) n FROM silver.bus_stop_school
                 WHERE radius_m = 200 GROUP BY school_code) q)
UNION ALL
SELECT 'silver.bus_stop_school_summary', 'summary_matches_pairs', 'consistency', 'error',
       (SELECT count(*) FROM silver.bus_stop_school_summary s
         WHERE s.n_schools_200m <> (SELECT count(*) FROM silver.bus_stop_school b
                                     WHERE b.stop_id = s.stop_id AND b.radius_m = 200)),
       (SELECT count(*) FROM silver.bus_stop_school_summary), NULL, NULL;
