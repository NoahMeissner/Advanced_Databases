
CREATE SCHEMA IF NOT EXISTS silver;

CREATE TABLE IF NOT EXISTS silver.school (
    school_code   integer     PRIMARY KEY,
    school_name   text        NOT NULL,
    street        text,
    town_suburb   text,
    postcode      char(4)     CHECK (postcode ~ '^[0-9]{4}$'),
    -- Lineage
    record_source text        NOT NULL DEFAULT 'NSW_DOE_SCHOOL_LOCATIONS',
    loaded_at     timestamptz NOT NULL DEFAULT now()
);

INSERT INTO silver.school AS s (school_code, school_name, street, town_suburb, postcode)
SELECT DISTINCT ON (school_code)
       school_code,
       trim(school_name),
       nullif(regexp_replace(trim(street), '\s+', ' ', 'g'), ''),   -- collapse repeated spaces
       upper(nullif(trim(town_suburb), '')),                         -- consistently UPPER, like G-NAF
       nullif(trim(postcode), '')
  FROM bronze.school_location
 WHERE school_code IS NOT NULL
   AND nullif(trim(school_name), '') IS NOT NULL
 ORDER BY school_code, _loaded_at DESC                               -- on duplicates the newest one wins
ON CONFLICT (school_code) DO UPDATE
   SET school_name = EXCLUDED.school_name,
       street      = EXCLUDED.street,
       town_suburb = EXCLUDED.town_suburb,
       postcode    = EXCLUDED.postcode,
       loaded_at   = now()
 WHERE (s.school_name, s.street, s.town_suburb, s.postcode)
       IS DISTINCT FROM
       (EXCLUDED.school_name, EXCLUDED.street, EXCLUDED.town_suburb, EXCLUDED.postcode);

SELECT count(*) AS silver_rows FROM silver.school;