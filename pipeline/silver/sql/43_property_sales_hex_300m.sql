-- silver.property_sales_hex_300m - price statistics per 300 m hexagon.
--
-- Depends on the street geocode from 40_street_locality.sql, so coverage is
-- the 75.3% of usable sales whose street could be located. A sale sits at its
-- street's centre, p90 479 m from the real street line, so a single hexagon's
-- figure is noisier than the k-ring figure built on top of it in
-- 44_bus_stop_property_sales.sql.
--
-- n_sales_precise counts only sales from streets whose DA points cluster inside
-- one hexagon width (flag_coarse_geocode = false), so a consumer can tell how
-- much of a cell's number rests on a tight geocode.

CREATE TABLE IF NOT EXISTS silver.property_sales_hex_300m (
    hex_id              text        NOT NULL REFERENCES silver.hex_300m ON DELETE CASCADE,
    period              text        NOT NULL,
    property_type       text        NOT NULL,
    n_sales             integer     NOT NULL,
    n_sales_precise     integer     NOT NULL,
    median_price        numeric(16,2),
    mean_price          numeric(16,2),
    p25_price           numeric(16,2),
    p75_price           numeric(16,2),
    median_price_per_m2 numeric(16,2),
    median_area_m2      numeric(16,2),
    first_contract_date date,
    last_contract_date  date,
    record_source       text        NOT NULL DEFAULT 'NSW_VG_PROPERTY_SALES',
    loaded_at           timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT property_sales_hex_300m_pkey PRIMARY KEY (hex_id, period, property_type)
);

CREATE INDEX IF NOT EXISTS property_sales_hex_300m_period_idx
    ON silver.property_sales_hex_300m (period, property_type);

DELETE FROM silver.property_sales_hex_300m;

INSERT INTO silver.property_sales_hex_300m
    (hex_id, period, property_type, n_sales, n_sales_precise, median_price,
     mean_price, p25_price, p75_price, median_price_per_m2, median_area_m2,
     first_contract_date, last_contract_date)
WITH src AS (
    SELECT hex_id, contract_year, property_type, purchase_price, price_per_m2,
           area_m2, contract_date, flag_coarse_geocode
      FROM silver.property_sale
     WHERE is_usable AND hex_id IS NOT NULL
    UNION ALL
    SELECT hex_id, contract_year, 'all', purchase_price, price_per_m2,
           area_m2, contract_date, flag_coarse_geocode
      FROM silver.property_sale
     WHERE is_usable AND hex_id IS NOT NULL
)
SELECT hex_id,
       coalesce(contract_year::text, 'all'),
       property_type,
       count(*)::integer,
       count(*) FILTER (WHERE NOT flag_coarse_geocode)::integer,
       percentile_cont(0.5)  WITHIN GROUP (ORDER BY purchase_price)::numeric(16,2),
       round(avg(purchase_price), 2),
       percentile_cont(0.25) WITHIN GROUP (ORDER BY purchase_price)::numeric(16,2),
       percentile_cont(0.75) WITHIN GROUP (ORDER BY purchase_price)::numeric(16,2),
       percentile_cont(0.5)  WITHIN GROUP (ORDER BY price_per_m2)::numeric(16,2),
       percentile_cont(0.5)  WITHIN GROUP (ORDER BY area_m2)::numeric(16,2),
       min(contract_date),
       max(contract_date)
  FROM src
 GROUP BY GROUPING SETS ((hex_id, contract_year, property_type),
                         (hex_id, property_type));
