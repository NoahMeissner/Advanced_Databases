-- gold.suburb_comparison - where a suburb sits against every other suburb.
--
-- Answers "is Ultimo more expensive than other suburbs, or not" at the grain
-- people actually think in. LGAs are too coarse for that: Ultimo, Newtown and
-- Redfern are all City of Sydney, and nobody compares them as one place.
--
-- Scope is every locality with at least MIN_SALES usable sales, which is 776 of
-- the 893 localities that have any. Below that a median is noise, and a rank
-- built on noise is worse than no rank.
--
-- Ranks are materialised columns, matching gold.lga_comparison, so "682nd of
-- 776" is a lookup rather than a sort every caller has to repeat identically.
--
-- BOTH price level AND price per m2 are ranked, on purpose. Ultimo's median is
-- $750k, which ranks it 682nd of 776 - near the cheap end - but that is largely
-- composition: it is mostly small apartments. Per m2 it ranks very differently.
-- Publishing only the level would make an expensive suburb look cheap.
--
-- RENT IS NOT RANKED HERE. Rent exists for 6 LGAs and nothing finer, so a
-- suburb-level rent rank would be fabricated. The LGA rank is joined through
-- lga_code instead, and gold.lga_comparison.n_ranked_rent carries its real
-- denominator of 6.

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
     n_ranked, n_ranked_change, lga_code, lga_name)
WITH bounds AS (
    SELECT max(contract_year) AS to_year,
           max(contract_year) - 5 AS from_year
      FROM silver.property_sale WHERE is_usable
), totals AS (
    SELECT p.locality,
           count(*)::integer AS n_sales,
           percentile_cont(0.5)  WITHIN GROUP (ORDER BY p.purchase_price)::numeric(16,2) AS median_price,
           percentile_cont(0.5)  WITHIN GROUP (ORDER BY p.price_per_m2)::numeric(16,2)   AS price_per_m2,
           percentile_cont(0.25) WITHIN GROUP (ORDER BY p.purchase_price)::numeric(16,2) AS p25,
           percentile_cont(0.75) WITHIN GROUP (ORDER BY p.purchase_price)::numeric(16,2) AS p75,
           -- the LGA most of the suburb's sales sit in; a locality can straddle
           -- a boundary, so this is a majority, not an assumption
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
       l.lga_code, l.lga_name
  FROM joined j
  LEFT JOIN silver.lga l ON l.lga_code = silver.lga_key(j.district_name);
