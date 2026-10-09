-- silver.property_sales_street - price statistics at the street x locality grain.
--
-- This is the full-coverage aggregate: it needs no geocode, so all 46,550
-- streets are represented, unlike the hexagon version which depends on the
-- 57%-matched street centres.
--
-- Only is_usable sales contribute: standard sales (one parcel, whole interest,
-- price >= $1,000, valid dates) with a plausible price. Including multi-parcel
-- dealings would repeat one price across every parcel and inflate every figure.
--
-- Prices are skewed - median $1,000,000 against an $895,000,000 maximum - so
-- the median is the headline and the mean is kept only for comparison.

CREATE TABLE IF NOT EXISTS silver.property_sales_street (
    street_id           text        NOT NULL REFERENCES silver.street_locality ON DELETE CASCADE,
    period              text        NOT NULL,          -- '2024' | 'all'
    property_type       text        NOT NULL,          -- house|unit|land|other|all
    n_sales             integer     NOT NULL,
    median_price        numeric(16,2),
    mean_price          numeric(16,2),
    p25_price           numeric(16,2),
    p75_price           numeric(16,2),
    min_price           bigint,
    max_price           bigint,
    median_price_per_m2 numeric(16,2),
    median_area_m2      numeric(16,2),
    first_contract_date date,
    last_contract_date  date,
    record_source       text        NOT NULL DEFAULT 'NSW_VG_PROPERTY_SALES',
    loaded_at           timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT property_sales_street_pkey PRIMARY KEY (street_id, period, property_type)
);

CREATE INDEX IF NOT EXISTS property_sales_street_period_idx
    ON silver.property_sales_street (period, property_type);

DELETE FROM silver.property_sales_street;

INSERT INTO silver.property_sales_street
    (street_id, period, property_type, n_sales, median_price, mean_price,
     p25_price, p75_price, min_price, max_price, median_price_per_m2,
     median_area_m2, first_contract_date, last_contract_date)
WITH src AS (
    -- each sale counted once under its own type and once under 'all'
    SELECT street_id, contract_year, property_type, purchase_price,
           price_per_m2, area_m2, contract_date
      FROM silver.property_sale
     WHERE is_usable AND street_id IS NOT NULL
    UNION ALL
    SELECT street_id, contract_year, 'all', purchase_price,
           price_per_m2, area_m2, contract_date
      FROM silver.property_sale
     WHERE is_usable AND street_id IS NOT NULL
)
SELECT street_id,
       coalesce(contract_year::text, 'all'),
       property_type,
       count(*)::integer,
       percentile_cont(0.5)  WITHIN GROUP (ORDER BY purchase_price)::numeric(16,2),
       round(avg(purchase_price), 2),
       percentile_cont(0.25) WITHIN GROUP (ORDER BY purchase_price)::numeric(16,2),
       percentile_cont(0.75) WITHIN GROUP (ORDER BY purchase_price)::numeric(16,2),
       min(purchase_price),
       max(purchase_price),
       percentile_cont(0.5)  WITHIN GROUP (ORDER BY price_per_m2)::numeric(16,2),
       percentile_cont(0.5)  WITHIN GROUP (ORDER BY area_m2)::numeric(16,2),
       min(contract_date),
       max(contract_date)
  FROM src
 GROUP BY GROUPING SETS ((street_id, contract_year, property_type),
                         (street_id, property_type));
