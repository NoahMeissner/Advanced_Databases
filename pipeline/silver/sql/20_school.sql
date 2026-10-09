-- silver.school - schools, typed and placed in space.
--
-- Extends the original school_locations.sql (same upsert shape, more columns)
-- with the geometry and the metrics the per-stop profile needs.
--
-- SCOPE: the source is NSW-wide - 2,210 schools reaching Broken Hill (MGA zone
-- 54) and Lord Howe Island (zone 57), while our study area is Greater Sydney
-- plus the Illawarra (zone 56). Out-of-area schools are KEPT but get
-- flag_outside_aoi and a NULL geom_m: projecting lon 159 into zone 56 would
-- produce a number that looks fine and is wrong by kilometres.
--
-- SUPPRESSED VALUES: indigenous_pct / lbote_pct carry 'np' in their *_raw
-- column when the publisher suppressed a small count. Bronze already parks the
-- sentinel in *_raw and leaves the numeric column NULL, so a NULL here means
-- "suppressed", not "unknown" - flag_suppressed_metrics records which rows.

CREATE TABLE IF NOT EXISTS silver.school (
    school_code              integer     PRIMARY KEY,
    school_name              text        NOT NULL,
    street                   text,
    town_suburb              text,
    postcode                 char(4)     CHECK (postcode ~ '^[0-9]{4}$'),
    lga                      text,
    level_of_schooling       text,
    school_gender            text,
    selective_school         text,
    latest_year_enrolment_fte numeric(10,1),
    icsea_value              numeric(8,2),
    geom                     geometry(Point, 4326),
    geom_m                   geometry(Point, 7856),      -- NULL outside the AOI
    hex_id                   text,
    flag_missing_coords      boolean     NOT NULL DEFAULT false,
    flag_outside_aoi         boolean     NOT NULL DEFAULT false,
    flag_suppressed_metrics  boolean     NOT NULL DEFAULT false,
    is_usable                boolean     NOT NULL DEFAULT true,
    record_source            text        NOT NULL DEFAULT 'NSW_DOE_SCHOOL_LOCATIONS',
    loaded_at                timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS school_postcode_idx ON silver.school (postcode);
CREATE INDEX IF NOT EXISTS school_lga_idx      ON silver.school (lga);
CREATE INDEX IF NOT EXISTS school_geom_m_idx   ON silver.school USING gist (geom_m);
CREATE INDEX IF NOT EXISTS school_hex_idx      ON silver.school (hex_id);

INSERT INTO silver.school AS s
    (school_code, school_name, street, town_suburb, postcode, lga,
     level_of_schooling, school_gender, selective_school,
     latest_year_enrolment_fte, icsea_value,
     geom, geom_m, flag_missing_coords, flag_outside_aoi,
     flag_suppressed_metrics, is_usable)
WITH aoi AS (
    SELECT ST_Transform(geom_m, 4326) AS geom FROM silver.aoi
), src AS (
    SELECT DISTINCT ON (b.school_code)
           b.school_code,
           trim(b.school_name)                                        AS school_name,
           nullif(regexp_replace(trim(b.street), '\s+', ' ', 'g'), '') AS street,
           upper(nullif(trim(b.town_suburb), ''))                     AS town_suburb,
           -- the CHECK above would abort the load on a malformed postcode, so
           -- anything not exactly 4 digits becomes NULL rather than a failure
           CASE WHEN trim(b.postcode) ~ '^[0-9]{4}$' THEN trim(b.postcode) END AS postcode,
           upper(nullif(trim(b.lga), ''))                             AS lga,
           nullif(trim(b.level_of_schooling), '')                     AS level_of_schooling,
           nullif(trim(b.school_gender), '')                          AS school_gender,
           nullif(trim(b.selective_school), '')                       AS selective_school,
           b.latest_year_enrolment_fte,
           b.icsea_value,
           CASE WHEN b.latitude IS NOT NULL AND b.longitude IS NOT NULL
                THEN ST_SetSRID(ST_MakePoint(b.longitude, b.latitude), 4326) END AS geom,
           (b.indigenous_pct IS NULL AND b.indigenous_pct_raw IS NOT NULL)
             OR (b.lbote_pct IS NULL AND b.lbote_pct_raw IS NOT NULL)          AS suppressed
      FROM bronze.school_location b
     WHERE b.school_code IS NOT NULL
       AND nullif(trim(b.school_name), '') IS NOT NULL
     ORDER BY b.school_code, b._loaded_at DESC      -- on duplicates the newest wins
)
SELECT src.school_code, src.school_name, src.street, src.town_suburb, src.postcode,
       src.lga, src.level_of_schooling, src.school_gender, src.selective_school,
       src.latest_year_enrolment_fte, src.icsea_value,
       src.geom,
       CASE WHEN src.geom IS NOT NULL AND ST_Intersects(src.geom, aoi.geom)
            THEN ST_Transform(src.geom, 7856) END,
       src.geom IS NULL,                                           -- flag_missing_coords
       src.geom IS NOT NULL AND NOT ST_Intersects(src.geom, aoi.geom),  -- flag_outside_aoi
       src.suppressed,
       src.geom IS NOT NULL AND ST_Intersects(src.geom, aoi.geom)  -- is_usable
  FROM src CROSS JOIN aoi
ON CONFLICT (school_code) DO UPDATE
   SET school_name               = EXCLUDED.school_name,
       street                    = EXCLUDED.street,
       town_suburb               = EXCLUDED.town_suburb,
       postcode                  = EXCLUDED.postcode,
       lga                       = EXCLUDED.lga,
       level_of_schooling        = EXCLUDED.level_of_schooling,
       school_gender             = EXCLUDED.school_gender,
       selective_school          = EXCLUDED.selective_school,
       latest_year_enrolment_fte = EXCLUDED.latest_year_enrolment_fte,
       icsea_value               = EXCLUDED.icsea_value,
       geom                      = EXCLUDED.geom,
       geom_m                    = EXCLUDED.geom_m,
       flag_missing_coords       = EXCLUDED.flag_missing_coords,
       flag_outside_aoi          = EXCLUDED.flag_outside_aoi,
       flag_suppressed_metrics   = EXCLUDED.flag_suppressed_metrics,
       is_usable                 = EXCLUDED.is_usable,
       loaded_at                 = now()
 WHERE (s.school_name, s.street, s.town_suburb, s.postcode, s.lga,
        s.level_of_schooling, s.school_gender, s.selective_school,
        s.latest_year_enrolment_fte, s.icsea_value, s.is_usable)
       IS DISTINCT FROM
       (EXCLUDED.school_name, EXCLUDED.street, EXCLUDED.town_suburb,
        EXCLUDED.postcode, EXCLUDED.lga, EXCLUDED.level_of_schooling,
        EXCLUDED.school_gender, EXCLUDED.selective_school,
        EXCLUDED.latest_year_enrolment_fte, EXCLUDED.icsea_value, EXCLUDED.is_usable);

UPDATE silver.school s
   SET hex_id = h.hex_id
  FROM silver.hex_300m h
 WHERE s.geom_m IS NOT NULL
   AND ST_Intersects(h.geom_m, s.geom_m)
   AND s.hex_id IS DISTINCT FROM h.hex_id;
