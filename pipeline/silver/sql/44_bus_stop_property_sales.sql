-- silver.bus_stop_property_sales - sale prices mapped onto each bus stop.
--
-- Same two readings as bus_stop_da:
--   *_hex     the single 300 m cell the stop sits in
--   *_kring1  that cell plus its 6 neighbours (~900 m across) - the headline,
--             and the figure the street-centre geocode is accurate enough for
--             (p90 error 479 m, see 40_street_locality.sql)
--
-- The k-ring price statistics are RE-AGGREGATED from the underlying sales
-- across the seven cells. Averaging seven hexagon medians would produce a
-- number that is not a median of anything - the same reasoning as bus_stop_da,
-- and it matters more here because prices are heavily skewed.
--
-- Grain is (stop_id, period, property_type) so "units near this stop" and
-- "houses near this stop" stay separable; property_type 'all' is the roll-up.

CREATE TABLE IF NOT EXISTS silver.bus_stop_property_sales (
    stop_id                  integer     NOT NULL REFERENCES silver.bus_stop ON DELETE CASCADE,
    period                   text        NOT NULL,
    property_type            text        NOT NULL,
    hex_id                   text,
    n_hexes_in_ring          integer     NOT NULL,
    n_hexes_with_data        integer     NOT NULL,
    -- containing cell
    n_sales_hex              integer     NOT NULL DEFAULT 0,
    median_price_hex         numeric(16,2),
    median_price_per_m2_hex  numeric(16,2),
    -- k-ring 1, re-aggregated from the sales themselves
    n_sales_kring1           integer     NOT NULL DEFAULT 0,
    n_sales_precise_kring1   integer     NOT NULL DEFAULT 0,
    median_price_kring1      numeric(16,2),
    mean_price_kring1        numeric(16,2),
    p25_price_kring1         numeric(16,2),
    p75_price_kring1         numeric(16,2),
    median_price_per_m2_kring1 numeric(16,2),
    median_area_m2_kring1    numeric(16,2),
    last_contract_date_kring1 date,
    record_source            text        NOT NULL DEFAULT 'NSW_VG_PROPERTY_SALES',
    loaded_at                timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT bus_stop_property_sales_pkey PRIMARY KEY (stop_id, period, property_type)
);

CREATE INDEX IF NOT EXISTS bus_stop_property_sales_period_idx
    ON silver.bus_stop_property_sales (period, property_type);

DELETE FROM silver.bus_stop_property_sales;

INSERT INTO silver.bus_stop_property_sales
    (stop_id, period, property_type, hex_id, n_hexes_in_ring, n_hexes_with_data,
     n_sales_hex, median_price_hex, median_price_per_m2_hex,
     n_sales_kring1, n_sales_precise_kring1, median_price_kring1, mean_price_kring1,
     p25_price_kring1, p75_price_kring1, median_price_per_m2_kring1,
     median_area_m2_kring1, last_contract_date_kring1)
WITH ring AS (
    SELECT s.stop_id, s.hex_id AS centre_hex, n.neighbour_hex_id AS hex_id
      FROM silver.bus_stop s
      JOIN silver.hex_300m_neighbour n ON n.hex_id = s.hex_id
     WHERE s.hex_id IS NOT NULL
), ring_size AS (
    SELECT stop_id, centre_hex, count(*)::integer AS n_hexes_in_ring
      FROM ring GROUP BY stop_id, centre_hex
), sales AS (
    SELECT r.stop_id, p.hex_id, p.contract_year, p.property_type,
           p.purchase_price, p.price_per_m2, p.area_m2, p.contract_date,
           p.flag_coarse_geocode
      FROM ring r
      JOIN silver.property_sale p ON p.hex_id = r.hex_id
     WHERE p.is_usable
), typed AS (
    SELECT * FROM sales
    UNION ALL
    SELECT stop_id, hex_id, contract_year, 'all', purchase_price, price_per_m2,
           area_m2, contract_date, flag_coarse_geocode
      FROM sales
), kring AS (
    SELECT stop_id,
           coalesce(contract_year::text, 'all') AS period,
           property_type,
           count(DISTINCT hex_id)::integer      AS n_hexes_with_data,
           count(*)::integer                    AS n_sales,
           count(*) FILTER (WHERE NOT flag_coarse_geocode)::integer AS n_sales_precise,
           percentile_cont(0.5)  WITHIN GROUP (ORDER BY purchase_price)::numeric(16,2) AS median_price,
           round(avg(purchase_price), 2)        AS mean_price,
           percentile_cont(0.25) WITHIN GROUP (ORDER BY purchase_price)::numeric(16,2) AS p25_price,
           percentile_cont(0.75) WITHIN GROUP (ORDER BY purchase_price)::numeric(16,2) AS p75_price,
           percentile_cont(0.5)  WITHIN GROUP (ORDER BY price_per_m2)::numeric(16,2)   AS median_m2,
           percentile_cont(0.5)  WITHIN GROUP (ORDER BY area_m2)::numeric(16,2)        AS median_area,
           max(contract_date)                   AS last_contract_date
      FROM typed
     GROUP BY GROUPING SETS ((stop_id, contract_year, property_type),
                             (stop_id, property_type))
)
SELECT k.stop_id, k.period, k.property_type,
       rs.centre_hex, rs.n_hexes_in_ring, k.n_hexes_with_data,
       coalesce(c.n_sales, 0), c.median_price, c.median_price_per_m2,
       k.n_sales, k.n_sales_precise, k.median_price, k.mean_price,
       k.p25_price, k.p75_price, k.median_m2, k.median_area, k.last_contract_date
  FROM kring k
  JOIN ring_size rs USING (stop_id)
  LEFT JOIN silver.property_sales_hex_300m c
         ON c.hex_id = rs.centre_hex
        AND c.period = k.period
        AND c.property_type = k.property_type;
