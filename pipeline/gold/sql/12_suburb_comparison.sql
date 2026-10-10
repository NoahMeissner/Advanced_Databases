-- gold.suburb_comparison - where a suburb sits against every other suburb.
--
-- Answers "is Ultimo more expensive than other suburbs, or not" at suburb
-- level. LGAs are too coarse for that: Ultimo, Newtown and Redfern are all
-- City of Sydney, so an LGA figure lumps them together.
--
-- Scope is every locality with at least 30 usable sales, which is 776 of
-- the 893 localities that have any. Below that a median is noise, so those
-- localities get no rank.
--
-- Ranks are materialised columns, matching gold.lga_comparison, so "682nd of
-- 776" is a lookup rather than a sort every caller has to repeat identically.
--
-- Both price level and price per m2 are ranked. Ultimo's median is $750k,
-- which ranks it 682nd of 776 (near the cheap end), but that is largely
-- composition: it is mostly small apartments. Per m2 it ranks very differently.
-- Publishing only the level would make an expensive suburb look cheap.
--
-- Rent is not ranked here. Rent exists for 6 LGAs and nothing finer, so a
-- suburb-level rent rank would be fabricated. The LGA rank is joined through
-- lga_code instead, and gold.lga_comparison.n_ranked_rent carries its real
-- denominator of 6.
--
-- Each price also has its gap to the Sydney median in percent and a
-- percentile (0 = cheapest ranked suburb, 100 = dearest), so a reader can tell
-- whether a median is high without knowing Sydney prices.

CREATE TABLE IF NOT EXISTS gold.suburb_comparison (
    locality            text        PRIMARY KEY,
    n_sales             integer     NOT NULL,
    median_price        numeric(16,2),
    price_per_m2        numeric(16,2),
    p25_price           numeric(16,2),
    p75_price           numeric(16,2),
    median_price_before numeric(16,2),
    change_5y_pct       numeric(8,2),
    change_from_year    integer,
    change_to_year      integer,
    rank_median_price   integer,
    rank_price_per_m2   integer,
    rank_change_5y      integer,
    n_ranked            integer     NOT NULL,   -- the denominator, always shown
    n_ranked_change     integer     NOT NULL,
    lga_code            text,
    lga_name            text,
    sydney_median_price numeric(16,2),      -- median of every usable sale
    sydney_price_per_m2 numeric(16,2),
    price_vs_sydney_pct numeric(8,2),
    price_per_m2_vs_sydney_pct numeric(8,2),
    price_percentile    smallint,
    price_per_m2_percentile smallint,
    loaded_at           timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS suburb_comparison_rank_idx
    ON gold.suburb_comparison (rank_median_price);
CREATE INDEX IF NOT EXISTS suburb_comparison_lga_idx
    ON gold.suburb_comparison (lga_code);

DELETE FROM gold.suburb_comparison;

INSERT INTO gold.suburb_comparison
    (locality, n_sales, median_price, price_per_m2, p25_price, p75_price,
     median_price_before, change_5y_pct, change_from_year, change_to_year,
     rank_median_price, rank_price_per_m2, rank_change_5y,
     n_ranked, n_ranked_change, lga_code, lga_name,
     sydney_median_price, sydney_price_per_m2, price_vs_sydney_pct,
     price_per_m2_vs_sydney_pct, price_percentile, price_per_m2_percentile)
WITH bounds AS (
    SELECT max(contract_year) AS to_year,
           max(contract_year) - 5 AS from_year
      FROM silver.property_sale WHERE is_usable
), sydney AS (
    SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY purchase_price)::numeric(16,2) AS price,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY price_per_m2)::numeric(16,2)   AS per_m2
      FROM silver.property_sale WHERE is_usable
), totals AS (
    SELECT p.locality,
           count(*)::integer AS n_sales,
           percentile_cont(0.5)  WITHIN GROUP (ORDER BY p.purchase_price)::numeric(16,2) AS median_price,
           percentile_cont(0.5)  WITHIN GROUP (ORDER BY p.price_per_m2)::numeric(16,2)   AS price_per_m2,
           percentile_cont(0.25) WITHIN GROUP (ORDER BY p.purchase_price)::numeric(16,2) AS p25,
           percentile_cont(0.75) WITHIN GROUP (ORDER BY p.purchase_price)::numeric(16,2) AS p75,
           -- the LGA most of the suburb's sales sit in; a locality can straddle
           -- a boundary, so this takes the majority LGA
           mode() WITHIN GROUP (ORDER BY p.district_name) AS district_name
      FROM silver.property_sale p
     WHERE p.is_usable AND p.locality IS NOT NULL
     GROUP BY p.locality
    HAVING count(*) >= 30
), earlier AS (
    SELECT p.locality,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY p.purchase_price)::numeric(16,2) AS median_before
      FROM silver.property_sale p, bounds b
     WHERE p.is_usable AND p.locality IS NOT NULL
       AND p.contract_year = b.from_year
     GROUP BY p.locality
    HAVING count(*) >= 10
), joined AS (
    SELECT t.*, e.median_before, b.from_year, b.to_year,
           CASE WHEN e.median_before > 0
                THEN round(100.0 * (t.median_price - e.median_before)
                           / e.median_before, 2) END AS change_pct
      FROM totals t
      CROSS JOIN bounds b
      LEFT JOIN earlier e USING (locality)
)
SELECT j.locality, j.n_sales, j.median_price, j.price_per_m2, j.p25, j.p75,
       j.median_before, j.change_pct, j.from_year, j.to_year,
       rank() OVER (ORDER BY j.median_price DESC NULLS LAST),
       rank() OVER (ORDER BY j.price_per_m2 DESC NULLS LAST),
       CASE WHEN j.change_pct IS NOT NULL
            THEN rank() OVER (ORDER BY j.change_pct DESC NULLS LAST) END,
       count(*) OVER ()::integer,
       count(*) FILTER (WHERE j.change_pct IS NOT NULL) OVER ()::integer,
       l.lga_code, l.lga_name,
       s.price, s.per_m2,
       round(100.0 * (j.median_price - s.price) / nullif(s.price, 0), 2),
       round(100.0 * (j.price_per_m2 - s.per_m2) / nullif(s.per_m2, 0), 2),
       round(100 * percent_rank() OVER (ORDER BY j.median_price))::smallint,
       CASE WHEN j.price_per_m2 IS NOT NULL
            THEN round(100 * percent_rank() OVER (ORDER BY j.price_per_m2))::smallint END
  FROM joined j
 CROSS JOIN sydney s
  LEFT JOIN silver.lga l ON l.lga_code = silver.lga_key(j.district_name);
