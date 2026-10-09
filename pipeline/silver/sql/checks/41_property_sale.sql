-- Checks for silver.property_sale and its aggregates.
--
-- Two traps dominate this source. First, the publisher reissues sales for weeks
-- after registration, so the business key carries duplicates. Second,
-- bronze.area_m2 is already in m2 while area_type still names the ORIGINAL
-- unit - so a "helpful" hectare conversion double-converts and puts suburban
-- blocks at 200 km2. Both are asserted rather than assumed.

SELECT 'silver.property_sale'::text, 'dedup_business_key'::text,
       'uniqueness'::text, 'error'::text,
       (SELECT count(*) - count(DISTINCT (dealing_number, parcel_seq))
          FROM silver.property_sale),
       (SELECT count(*) FROM silver.property_sale), NULL::numeric,
       jsonb_build_object(
           'bronze_rows', (SELECT count(*) FROM bronze.property_sales),
           'silver_rows', (SELECT count(*) FROM silver.property_sale),
           'dropped_as_duplicates',
               (SELECT count(*) FROM bronze.property_sales)
               - (SELECT count(*) FROM silver.property_sale))
UNION ALL
-- The dedup must drop roughly the ~4,202 reissued rows. A much bigger drop
-- means the version tiebreak is discarding real sales.
SELECT 'silver.property_sale', 'dedup_drop_in_range', 'completeness', 'error',
       (SELECT CASE WHEN (SELECT count(*) FROM bronze.property_sales)
                         - (SELECT count(*) FROM silver.property_sale)
                         BETWEEN 0 AND 10000 THEN 0 ELSE 1 END)::bigint,
       (SELECT count(*) FROM bronze.property_sales)::bigint, NULL, NULL
UNION ALL
-- THE area check. bronze.area_m2 / area_source must be 10000 for 'H' rows and
-- 1 for 'M' rows, which is what proves area_m2 is already metres squared and
-- must NOT be converted again here.
--
-- Compared with a 1% RELATIVE tolerance, not exactly: area_m2 is rounded to 2
-- decimals upstream, so 37 rows with areas of 1-45 m2 land up to 0.33% off
-- (area_m2 1.2100 against area_source 1.214). The risk this check guards
-- against is a factor-10,000 unit error, so 1% is tight enough to catch that
-- while ignoring the publisher's rounding.
SELECT 'silver.property_sale', 'area_m2_already_normalised', 'validity', 'error',
       (SELECT count(*) FROM bronze.property_sales
         WHERE area_source IS NOT NULL AND area_m2 IS NOT NULL
           AND area_source::numeric <> 0
           AND abs((area_m2 / area_source::numeric)
                   / CASE WHEN upper(area_type) = 'H' THEN 10000 ELSE 1 END
                   - 1) > 0.01),
       (SELECT count(*) FROM bronze.property_sales WHERE area_source IS NOT NULL), NULL,
       (SELECT jsonb_object_agg(coalesce(upper(area_type), 'NULL'), ratio)
          FROM (SELECT area_type, round(avg(area_m2 / area_source::numeric), 4) ratio
                  FROM bronze.property_sales
                 WHERE area_source IS NOT NULL AND area_source::numeric <> 0
                   AND area_m2 IS NOT NULL
                 GROUP BY 1) q)
UNION ALL
-- A suburban block is a few hundred m2. If a conversion slipped back in, the
-- median area jumps four orders of magnitude and this catches it immediately.
SELECT 'silver.property_sale', 'area_median_plausible', 'accuracy', 'error',
       (SELECT CASE WHEN percentile_cont(0.5) WITHIN GROUP (ORDER BY area_m2)
                         BETWEEN 100 AND 5000 THEN 0 ELSE 1 END
          FROM silver.property_sale WHERE area_m2 IS NOT NULL)::bigint,
       1::bigint, NULL,
       (SELECT jsonb_build_object('median_area_m2',
            round((percentile_cont(0.5) WITHIN GROUP (ORDER BY area_m2))::numeric, 1))
          FROM silver.property_sale WHERE area_m2 IS NOT NULL)
UNION ALL
SELECT 'silver.property_sale', 'price_positive', 'validity', 'error',
       (SELECT count(*) FROM silver.property_sale
         WHERE is_usable AND (purchase_price IS NULL OR purchase_price < 1000)),
       (SELECT count(*) FROM silver.property_sale), NULL, NULL
UNION ALL
SELECT 'silver.property_sale', 'price_outlier', 'accuracy', 'warn',
       (SELECT count(*) FROM silver.property_sale WHERE flag_price_outlier),
       (SELECT count(*) FROM silver.property_sale), 0.05,
       (SELECT jsonb_build_object('max_price', max(purchase_price),
                                  'median_price', percentile_cont(0.5)
                                      WITHIN GROUP (ORDER BY purchase_price))
          FROM silver.property_sale)
UNION ALL
SELECT 'silver.property_sale', 'date_order', 'consistency', 'warn',
       (SELECT count(*) FROM silver.property_sale
         WHERE contract_date IS NOT NULL AND settlement_date IS NOT NULL
           AND settlement_date < contract_date),
       (SELECT count(*) FROM silver.property_sale), 0.01, NULL
UNION ALL
-- 10% of sales are first published more than 207 days after contract, so recent
-- medians keep moving. Flagged, not dropped - but a report must know.
SELECT 'silver.property_sale', 'recent_period_incomplete', 'timeliness', 'warn',
       (SELECT count(*) FROM silver.property_sale WHERE flag_period_incomplete),
       (SELECT count(*) FROM silver.property_sale), 0.15, NULL
UNION ALL
SELECT 'silver.property_sale', 'standard_sales_only_in_aggregates', 'consistency', 'error',
       (SELECT count(*) FROM silver.property_sale WHERE is_usable AND NOT is_standard_sale),
       (SELECT count(*) FROM silver.property_sale), NULL, NULL
UNION ALL
-- Street-level geocode coverage. Sales carry no coordinates at all, so this is
-- the number that decides whether the hexagon aggregates mean anything.
SELECT 'silver.property_sale', 'geocode_match_rate', 'completeness', 'warn',
       (SELECT count(*) FROM silver.property_sale WHERE is_usable AND hex_id IS NULL),
       (SELECT count(*) FROM silver.property_sale WHERE is_usable), 0.30,
       (SELECT jsonb_build_object(
            'geocoded', count(*) FILTER (WHERE hex_id IS NOT NULL),
            'usable', count(*),
            'method', 'da_street_centre')
          FROM silver.property_sale WHERE is_usable)
UNION ALL
-- The geocode is a street centre, not an address. Streets whose DA points
-- scatter wider than one hexagon are flagged so a consumer can exclude them.
SELECT 'silver.street_locality', 'coarse_geocode_share', 'accuracy', 'warn',
       (SELECT count(*) FROM silver.street_locality WHERE flag_coarse_geocode),
       (SELECT count(*) FROM silver.street_locality WHERE centroid IS NOT NULL), 0.25,
       (SELECT jsonb_build_object(
            'spread_p50_m', round(percentile_cont(0.5) WITHIN GROUP (ORDER BY geocode_spread_m)),
            'spread_p90_m', round(percentile_cont(0.9) WITHIN GROUP (ORDER BY geocode_spread_m)))
          FROM silver.street_locality WHERE centroid IS NOT NULL)
UNION ALL
-- A wrong-suburb match on a common street name would show here: the geocoded
-- centre must sit in the locality the sale claims.
SELECT 'silver.property_sales_hex_300m', 'sales_counts_reconcile', 'consistency', 'error',
       (SELECT abs(coalesce(sum(n_sales), 0)
                   - (SELECT count(*) FROM silver.property_sale
                       WHERE is_usable AND hex_id IS NOT NULL))
          FROM silver.property_sales_hex_300m
         WHERE period = 'all' AND property_type = 'all')::bigint,
       (SELECT count(*) FROM silver.property_sale WHERE is_usable)::bigint, NULL, NULL;
