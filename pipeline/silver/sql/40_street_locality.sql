-- silver.street_locality - the street x locality grain, and its geocode.
--
-- Property sales carry NO coordinates (the publisher supplies none), so this is
-- the location key. It is the G-NAF STREET_LOCALITY grain, which the Bronze
-- columns already follow:
--
--   street_name_core | street_type_code | street_suffix_code | locality | postcode
--
-- Using the parsed parts rather than the address string keeps
-- "SMITH ST, PARRAMATTA" apart from "SMITH ST, NEWTOWN", and makes "RD" and
-- "ROAD" the same street. street_id is md5 over the '||'-joined key, the same
-- hashing convention the project uses for hashdiff, so it is stable.
--
-- GEOCODE WITHOUT A NEW DOWNLOAD. A street-centreline reference is not on disk,
-- but DA applications are - 177,625 usable, geocoded, and carrying the same
-- street_name / street_type / suburb parts. The median DA point on a street is
-- therefore a street centre. Measured against the DA points themselves:
--
--   match rate   57.1% of streets, 75.3% of usable sales
--   error        p50 86 m, p90 479 m, p99 1,465 m from the street centre
--
-- So it is solid for the ~900 m k-ring figure and reasonable for a 300 m cell,
-- but it is a street centre, not an address. Two columns keep that honest:
-- geocode_spread_m (p90 of the DA points about the centre, per street) and
-- flag_coarse_geocode when that exceeds 300 m - one hexagon's width. Ingesting
-- a real centreline layer later replaces the centroid and raises coverage
-- without touching the schema.

CREATE TABLE IF NOT EXISTS silver.street_locality (
    street_id          text        PRIMARY KEY,
    street_label       text        NOT NULL,
    street_name_core   text        NOT NULL,
    street_type_code   text,
    street_suffix_code text,
    locality           text        NOT NULL,
    postcode           text,
    geom               geometry(MultiLineString, 4326),  -- set by a centreline source
    centroid           geometry(Point, 4326),
    centroid_m         geometry(Point, 7856),
    hex_id             text,
    geocode_method     text,                             -- 'da_street_centre' | NULL
    geocode_n_points   integer,
    geocode_spread_m   numeric(10,2),                    -- p90 about the centre
    flag_coarse_geocode boolean    NOT NULL DEFAULT false,
    record_source      text        NOT NULL DEFAULT 'NSW_VG_PROPERTY_SALES',
    loaded_at          timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS street_locality_locality_idx ON silver.street_locality (locality, postcode);
CREATE INDEX IF NOT EXISTS street_locality_hex_idx      ON silver.street_locality (hex_id);
CREATE INDEX IF NOT EXISTS street_locality_key_idx
    ON silver.street_locality (street_name_core, street_type_code, locality);

INSERT INTO silver.street_locality AS t
    (street_id, street_label, street_name_core, street_type_code,
     street_suffix_code, locality, postcode)
WITH parts AS (
    SELECT DISTINCT
           upper(trim(street_name_core))                        AS street_name_core,
           upper(nullif(trim(street_type_code), ''))            AS street_type_code,
           upper(nullif(trim(street_suffix_code), ''))          AS street_suffix_code,
           upper(trim(locality))                                AS locality,
           CASE WHEN trim(postcode) ~ '^[0-9]{4}$' THEN trim(postcode) END AS postcode
      FROM bronze.property_sales
     WHERE nullif(trim(street_name_core), '') IS NOT NULL
       AND nullif(trim(locality), '')         IS NOT NULL
)
SELECT md5(concat_ws('||', street_name_core, coalesce(street_type_code, ''),
                     coalesce(street_suffix_code, ''), locality, coalesce(postcode, ''))),
       concat_ws(' ', street_name_core, street_type_code, street_suffix_code)
         || ', ' || locality || coalesce(' ' || postcode, ''),
       street_name_core, street_type_code, street_suffix_code, locality, postcode
  FROM parts
ON CONFLICT (street_id) DO UPDATE
   SET street_label = EXCLUDED.street_label,
       loaded_at    = now()
 WHERE t.street_label IS DISTINCT FROM EXCLUDED.street_label;

-- Street centres from the DA points, with their spread.
CREATE TEMP TABLE da_street_point AS
SELECT upper(trim(b.street_name)) AS nm,
       upper(trim(b.street_type)) AS ty,
       upper(trim(b.suburb))      AS loc,
       d.geom
  FROM silver.da_application d
  JOIN bronze.da_applications b
    ON b.planning_portal_application_number = d.application_number
 WHERE d.is_usable
   AND nullif(trim(b.street_name), '') IS NOT NULL
   AND nullif(trim(b.street_type), '') IS NOT NULL
   AND nullif(trim(b.suburb), '')      IS NOT NULL;

CREATE TEMP TABLE da_street_centre AS
WITH centre AS (
    SELECT nm, ty, loc,
           count(*)::integer AS n_points,
           ST_SetSRID(ST_MakePoint(
               percentile_cont(0.5) WITHIN GROUP (ORDER BY ST_X(geom)),
               percentile_cont(0.5) WITHIN GROUP (ORDER BY ST_Y(geom))), 4326) AS centroid
      FROM da_street_point
     GROUP BY nm, ty, loc
)
SELECT c.nm, c.ty, c.loc, c.n_points, c.centroid,
       percentile_cont(0.9) WITHIN GROUP (
           ORDER BY ST_Distance(p.geom::geography, c.centroid::geography)
       )::numeric(10,2) AS spread_m
  FROM centre c
  JOIN da_street_point p USING (nm, ty, loc)
 GROUP BY c.nm, c.ty, c.loc, c.n_points, c.centroid;

CREATE INDEX ON da_street_centre (nm, ty, loc);

UPDATE silver.street_locality s
   SET centroid            = a.centroid,
       centroid_m          = ST_Transform(a.centroid, 7856),
       geocode_method      = 'da_street_centre',
       geocode_n_points    = a.n_points,
       geocode_spread_m    = a.spread_m,
       flag_coarse_geocode = (a.spread_m > 300),
       loaded_at           = now()
  FROM da_street_centre a
 WHERE a.nm  = s.street_name_core
   AND a.ty  = s.street_type_code
   AND a.loc = s.locality;

UPDATE silver.street_locality s
   SET hex_id = h.hex_id
  FROM silver.hex_300m h
 WHERE s.centroid_m IS NOT NULL
   AND ST_Intersects(h.geom_m, s.centroid_m)
   AND s.hex_id IS DISTINCT FROM h.hex_id;
