-- silver.lga - the conformed Local Government Area dimension.
--
-- Four sources name the same LGA four different ways, which is why nothing
-- could be compared across them until now:
--
--   bronze.rent_data.lga_name          'Parramatta'
--   silver.da_application.council_name 'City of Parramatta Council'
--   silver.property_sale.district_name 'Parramatta'
--   silver.school.lga                  'PARRAMATTA'   (and 'BAYSIDE (NSW)')
--
-- silver.lga_key() is the single normalisation every source goes through.
-- Deliberately ONE function rather than a copied regex: four copies is exactly
-- how these spellings drifted apart in the first place.
--
-- It strips, in order: a bracketed state qualifier ('(NSW)' - the school file
-- disambiguates Bayside and Campbelltown from their Victorian namesakes), then
-- the generic government words wherever they appear, then collapses spaces.
-- Removing the words anywhere rather than only as a prefix/suffix is what makes
-- 'The Hills Shire Council' and 'The Hills Shire' agree.
--
-- Verified on the real data: all 33 DA councils resolve to a key that both the
-- sales districts and the school LGAs also produce, all 6 rent LGAs match, and
-- no key collapses two different councils together.

CREATE SCHEMA IF NOT EXISTS silver;

CREATE OR REPLACE FUNCTION silver.lga_key(raw_name text)
RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
    SELECT upper(trim(regexp_replace(regexp_replace(regexp_replace(
        lower(raw_name),
        '\([a-z]+\)', ' ', 'g'),                      -- '(NSW)'
        '\y(the|council|of|city|shire|municipality|municipal|borough|area)\y',
        ' ', 'g'),
        '\s+', ' ', 'g')))
$$;

COMMENT ON FUNCTION silver.lga_key(text) IS
    'Conforms an LGA / council / district name to one key. Use this everywhere.';

CREATE TABLE IF NOT EXISTS silver.lga (
    lga_code      text        PRIMARY KEY,          -- silver.lga_key(...)
    lga_name      text        NOT NULL,             -- best display name
    -- which sources know this LGA; the honest answer to "can I compare it"
    source_da     boolean     NOT NULL DEFAULT false,
    source_psi    boolean     NOT NULL DEFAULT false,
    source_school boolean     NOT NULL DEFAULT false,
    source_rent   boolean     NOT NULL DEFAULT false,
    record_source text        NOT NULL DEFAULT 'CONFORMED_FROM_FOUR_SOURCES',
    loaded_at     timestamptz NOT NULL DEFAULT now()
);

INSERT INTO silver.lga AS t
    (lga_code, lga_name, source_da, source_psi, source_school, source_rent)
WITH da AS (
    SELECT silver.lga_key(council_name) AS lga_code,
           min(council_name)            AS raw_name
      FROM silver.da_application
     WHERE council_name IS NOT NULL
     GROUP BY 1
), psi AS (
    SELECT silver.lga_key(district_name) AS lga_code,
           min(district_name)            AS raw_name
      FROM silver.property_sale
     WHERE district_name IS NOT NULL
     GROUP BY 1
), school AS (
    SELECT silver.lga_key(lga) AS lga_code,
           -- drop the state qualifier for display, keep the rest as published
           min(trim(regexp_replace(lga, '\([A-Za-z]+\)', '', 'g'))) AS raw_name
      FROM silver.school
     WHERE lga IS NOT NULL
     GROUP BY 1
), rent AS (
    SELECT silver.lga_key(lga_name) AS lga_code,
           min(lga_name)            AS raw_name
      FROM bronze.rent_data
     WHERE lga_name IS NOT NULL
     GROUP BY 1
), keys AS (
    SELECT lga_code FROM da
    UNION SELECT lga_code FROM psi
    UNION SELECT lga_code FROM school
    UNION SELECT lga_code FROM rent
)
SELECT k.lga_code,
       -- display name preference: the shortest, cleanest publisher wins
       coalesce(r.raw_name, p.raw_name, initcap(s.raw_name), d.raw_name, k.lga_code),
       d.lga_code IS NOT NULL,
       p.lga_code IS NOT NULL,
       s.lga_code IS NOT NULL,
       r.lga_code IS NOT NULL
  FROM keys k
  LEFT JOIN da     d USING (lga_code)
  LEFT JOIN psi    p USING (lga_code)
  LEFT JOIN school s USING (lga_code)
  LEFT JOIN rent   r USING (lga_code)
ON CONFLICT (lga_code) DO UPDATE
   SET lga_name      = EXCLUDED.lga_name,
       source_da     = EXCLUDED.source_da,
       source_psi    = EXCLUDED.source_psi,
       source_school = EXCLUDED.source_school,
       source_rent   = EXCLUDED.source_rent,
       loaded_at     = now()
 WHERE (t.lga_name, t.source_da, t.source_psi, t.source_school, t.source_rent)
       IS DISTINCT FROM
       (EXCLUDED.lga_name, EXCLUDED.source_da, EXCLUDED.source_psi,
        EXCLUDED.source_school, EXCLUDED.source_rent);
