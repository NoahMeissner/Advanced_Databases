-- gold.lga_comparison - one row per LGA, every source side by side.
--
-- Compares LGAs across Sydney. Scope is the 33 LGAs that
-- actually contain bus stops, not all 129 in the dimension (the school source
-- is NSW-wide, down to Broken Hill).
--
-- Rent is the sparse column. Only 6 of the 33 LGAs have rent data at all, so
-- has_rent_data exists to stop a NULL being read as "cheap". Every other column
-- is built from full-coverage sources, so the comparison stays useful where
-- rent is missing.
--
-- Medians come from percentile_cont over the underlying sales, never from
-- averaging the hexagon medians, because an average of medians is not a median of
-- anything, and prices here are heavily skewed.
--
-- Ranks are materialised columns rather than left to the caller, so "highest
-- rent" and "most development" are a WHERE clause, and every consumer agrees
-- on what the ranking was.
--
-- A rank alone does not say whether a number is high. The *_vs_* columns give
-- the gap to a reference in percent, so $1,000 a week reads as "x% above".
-- Sale prices compare against the median of every usable Sydney sale. Rent
-- compares against the median of the LGAs that have rent data, because there
-- is no Sydney-wide rent figure to compare with.

CREATE TABLE IF NOT EXISTS gold.lga_comparison (
    lga_code                   text        PRIMARY KEY REFERENCES silver.lga,
    lga_name                   text        NOT NULL,

    -- transit
    n_stops                    integer     NOT NULL,
    n_stops_low_confidence     integer     NOT NULL,
    avg_route_count            numeric(8,2),
    avg_edge_travel_time_peak_s numeric(10,2),

    -- schools
    n_schools                  integer     NOT NULL,
    avg_icsea                  numeric(8,2),
    sum_enrolment_fte          numeric(12,1),

    -- property sales
    n_sales                    integer     NOT NULL,
    median_sale_price          numeric(16,2),
    median_price_per_m2        numeric(16,2),
    p25_sale_price             numeric(16,2),
    p75_sale_price             numeric(16,2),

    -- development pipeline
    da_n_applications          integer     NOT NULL,
    da_n_modifications         integer     NOT NULL,
    da_sum_new_dwellings       integer,
    da_median_cost             numeric(16,2),

    -- rent (6 of 33 LGAs)
    median_rent_weekly_house   numeric(10,2),
    median_rent_weekly_flat    numeric(10,2),
    rent_period                date,
    rent_new_bonds             integer,
    ref_rent_weekly_house      numeric(10,2),   -- median across LGAs with rent data
    ref_rent_weekly_flat       numeric(10,2),
    rent_house_vs_ref_pct      numeric(8,2),
    rent_flat_vs_ref_pct       numeric(8,2),

    -- sale price against all of Sydney
    sydney_median_sale_price   numeric(16,2),
    sale_price_vs_sydney_pct   numeric(8,2),

    -- rankings: 1 = highest / most
    rank_median_rent_house     integer,
    rank_median_sale_price     integer,
    rank_da_applications       integer,
    rank_n_stops               integer,

    n_ranked_rent              integer     NOT NULL DEFAULT 0,
    has_rent_data              boolean     NOT NULL DEFAULT false,
    has_sales_data             boolean     NOT NULL DEFAULT false,
    has_school_data            boolean     NOT NULL DEFAULT false,
    loaded_at                  timestamptz NOT NULL DEFAULT now()
);

DELETE FROM gold.lga_comparison;

INSERT INTO gold.lga_comparison
    (lga_code, lga_name, n_stops, n_stops_low_confidence, avg_route_count,
     avg_edge_travel_time_peak_s, n_schools, avg_icsea, sum_enrolment_fte,
     n_sales, median_sale_price, median_price_per_m2, p25_sale_price, p75_sale_price,
     da_n_applications, da_n_modifications, da_sum_new_dwellings, da_median_cost,
     median_rent_weekly_house, median_rent_weekly_flat, rent_period, rent_new_bonds,
     ref_rent_weekly_house, ref_rent_weekly_flat, rent_house_vs_ref_pct, rent_flat_vs_ref_pct,
     sydney_median_sale_price, sale_price_vs_sydney_pct,
     rank_median_rent_house, rank_median_sale_price, rank_da_applications, rank_n_stops,
     n_ranked_rent, has_rent_data, has_sales_data, has_school_data)
WITH stops AS (
    SELECT sl.lga_code,
           count(*)::integer                                        AS n_stops,
           count(*) FILTER (WHERE sl.flag_low_confidence)::integer   AS n_low_conf,
           round(avg(p.route_count), 2)                              AS avg_routes,
           round(avg(p.avg_edge_travel_time_peak_s), 2)              AS avg_peak_s
      FROM silver.bus_stop_lga sl
      JOIN silver.bus_stop_profile p USING (stop_id)
     GROUP BY sl.lga_code
), schools AS (
    SELECT silver.lga_key(lga)             AS lga_code,
           count(*)::integer               AS n_schools,
           round(avg(icsea_value), 2)      AS avg_icsea,
           sum(latest_year_enrolment_fte)  AS enrolment
      FROM silver.school
     WHERE lga IS NOT NULL
     GROUP BY 1
), sales AS (
    SELECT silver.lga_key(district_name) AS lga_code,
           count(*)::integer             AS n_sales,
           percentile_cont(0.5)  WITHIN GROUP (ORDER BY purchase_price)::numeric(16,2) AS median_price,
           percentile_cont(0.5)  WITHIN GROUP (ORDER BY price_per_m2)::numeric(16,2)   AS median_m2,
           percentile_cont(0.25) WITHIN GROUP (ORDER BY purchase_price)::numeric(16,2) AS p25,
           percentile_cont(0.75) WITHIN GROUP (ORDER BY purchase_price)::numeric(16,2) AS p75
      FROM silver.property_sale
     WHERE is_usable AND district_name IS NOT NULL
     GROUP BY 1
), das AS (
    SELECT silver.lga_key(council_name) AS lga_code,
           count(*) FILTER (WHERE application_type = 'Development Application')::integer  AS n_apps,
           count(*) FILTER (WHERE application_type = 'Modification Application')::integer AS n_mods,
           sum(number_of_new_dwellings)::integer AS new_dwellings,
           percentile_cont(0.5) WITHIN GROUP (
               ORDER BY CASE WHEN flag_cost_outlier THEN NULL
                             ELSE cost_of_development END)::numeric(16,2) AS median_cost
      FROM silver.da_application
     WHERE is_usable AND council_name IS NOT NULL
     GROUP BY 1
), rent AS (
    SELECT lga_code,
           max(median_weekly_rent) FILTER (WHERE dwelling_type = 'house') AS house,
           max(median_weekly_rent) FILTER (WHERE dwelling_type = 'flat')  AS flat,
           max(period_start)                                              AS period,
           sum(new_bonds_count)::integer                                  AS bonds
      FROM silver.rent_lga_latest
     GROUP BY lga_code
), joined AS (
    SELECT l.lga_code, l.lga_name,
           st.n_stops, st.n_low_conf, st.avg_routes, st.avg_peak_s,
           coalesce(sc.n_schools, 0) AS n_schools, sc.avg_icsea, sc.enrolment,
           coalesce(sa.n_sales, 0) AS n_sales, sa.median_price, sa.median_m2,
           sa.p25, sa.p75,
           coalesce(d.n_apps, 0) AS n_apps, coalesce(d.n_mods, 0) AS n_mods,
           d.new_dwellings, d.median_cost,
           r.house, r.flat, r.period, r.bonds
      FROM silver.lga l
      -- the scope: an LGA is comparable only if bus stops land in it
      JOIN stops   st USING (lga_code)
      LEFT JOIN schools sc USING (lga_code)
      LEFT JOIN sales   sa USING (lga_code)
      LEFT JOIN das     d  USING (lga_code)
      LEFT JOIN rent    r  USING (lga_code)
), refs AS (
    SELECT (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY purchase_price)
              FROM silver.property_sale WHERE is_usable)::numeric(16,2) AS sydney_price,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY house)::numeric(10,2) AS ref_house,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY flat)::numeric(10,2)  AS ref_flat
      FROM joined
)
SELECT lga_code, lga_name, n_stops, n_low_conf, avg_routes, avg_peak_s,
       n_schools, avg_icsea, enrolment,
       n_sales, median_price, median_m2, p25, p75,
       n_apps, n_mods, new_dwellings, median_cost,
       house, flat, period, bonds,
       ref_house, ref_flat,
       round(100.0 * (house - ref_house) / nullif(ref_house, 0), 2),
       round(100.0 * (flat - ref_flat) / nullif(ref_flat, 0), 2),
       sydney_price,
       round(100.0 * (median_price - sydney_price) / nullif(sydney_price, 0), 2),
       -- NULLS LAST so "no data" never outranks a real value
       CASE WHEN house IS NOT NULL
            THEN rank() OVER (ORDER BY house DESC NULLS LAST) END,
       CASE WHEN median_price IS NOT NULL
            THEN rank() OVER (ORDER BY median_price DESC NULLS LAST) END,
       rank() OVER (ORDER BY n_apps DESC),
       rank() OVER (ORDER BY n_stops DESC),
       -- denominator for the rent rank: rent exists for 6 of 33 LGAs, so a bare "2nd"
       -- would imply a Sydney-wide ranking this data cannot support
       count(*) FILTER (WHERE house IS NOT NULL) OVER ()::integer,
       (house IS NOT NULL OR flat IS NOT NULL),
       n_sales > 0,
       n_schools > 0
  FROM joined
 CROSS JOIN refs;
