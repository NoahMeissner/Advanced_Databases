-- silver.da_application - development applications, typed, placed and flagged.
--
-- The coordinates in this source are not trustworthy as published. Three
-- separate problems, each flagged rather than deleted:
--
--  1. 7 rows have no coordinate at all.
--  2. ~1,131 rows fall outside the study area. Some are genuine non-Sydney
--     councils; others are plainly broken - PAN-431048 is a Bayside Council
--     application plotted near Albury, 500 km away.
--  3. A bbox test alone cannot catch (2), because a wrong point can still land
--     inside NSW. So flag_bad_geocode compares each point against the MEDIAN
--     point of its own council: more than 50 km from where that council
--     actually is means the coordinate is wrong, whatever the bbox says.
--     Distance is computed on the spheroid (geography), because a broken point
--     may sit far outside MGA zone 56 where projected metres stop meaning
--     anything.
--  4. Three of the outliers share an identical coordinate across different
--     addresses - the signature of a geocoder falling back to some centroid.
--     flag_geocode_collision catches that pattern generally.
--
-- cost_of_development reaches 21,625,742,730 (21.6 bn). One such row would
-- dominate any hexagon mean, so the extreme tails are flagged and excluded from
-- aggregates while staying in the table.

CREATE TABLE IF NOT EXISTS silver.da_application (
    application_number       text        PRIMARY KEY,   -- PlanningPortalApplicationNumber
    council_application_number text,
    council_name             text,
    application_type         text,
    application_status       text,
    submission_date          date,
    lodgement_date           date,
    determination_date       date,
    date_last_updated        timestamptz,
    determination_authority  text,
    cost_of_development      numeric(16,2),
    number_of_new_dwellings  integer,
    number_of_storeys        integer,
    number_of_existing_lots  integer,
    number_of_proposed_lots  integer,
    days_to_determination    integer,
    suburb                   text,
    postcode                 text,
    full_address             text,
    geom                     geometry(Point, 4326),
    geom_m                   geometry(Point, 7856),     -- NULL unless inside the AOI
    hex_id                   text,
    flag_missing_coords      boolean     NOT NULL DEFAULT false,
    flag_outside_aoi         boolean     NOT NULL DEFAULT false,
    flag_bad_geocode         boolean     NOT NULL DEFAULT false,
    flag_geocode_collision   boolean     NOT NULL DEFAULT false,
    flag_cost_outlier        boolean     NOT NULL DEFAULT false,
    flag_date_order          boolean     NOT NULL DEFAULT false,
    is_usable                boolean     NOT NULL DEFAULT true,
    record_source            text        NOT NULL DEFAULT 'NSW_PLANNING_PORTAL_DA',
    loaded_at                timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS da_application_hex_idx    ON silver.da_application (hex_id);
CREATE INDEX IF NOT EXISTS da_application_geom_m_idx ON silver.da_application USING gist (geom_m);
CREATE INDEX IF NOT EXISTS da_application_council_idx ON silver.da_application (council_name);
CREATE INDEX IF NOT EXISTS da_application_lodged_idx ON silver.da_application (lodgement_date);

INSERT INTO silver.da_application AS t
    (application_number, council_application_number, council_name, application_type,
     application_status, submission_date, lodgement_date, determination_date,
     date_last_updated, determination_authority, cost_of_development,
     number_of_new_dwellings, number_of_storeys, number_of_existing_lots,
     number_of_proposed_lots, days_to_determination, suburb, postcode, full_address,
     geom, geom_m, flag_missing_coords, flag_outside_aoi, flag_bad_geocode,
     flag_geocode_collision, flag_cost_outlier, flag_date_order, is_usable)
WITH aoi AS (
    SELECT ST_Transform(geom_m, 4326) AS geom FROM silver.aoi
), src AS (
    SELECT DISTINCT ON (b.planning_portal_application_number)
           b.planning_portal_application_number        AS application_number,
           nullif(trim(b.council_application_number), '') AS council_application_number,
           nullif(trim(b.council_name), '')            AS council_name,
           nullif(trim(b.application_type), '')        AS application_type,
           nullif(trim(b.application_status), '')      AS application_status,
           b.submission_date, b.lodgement_date, b.determination_date,
           b.date_last_updated,
           nullif(trim(b.determination_authority), '') AS determination_authority,
           b.cost_of_development,
           b.number_of_new_dwellings, b.number_of_storeys,
           b.number_of_existing_lots, b.number_of_proposed_lots,
           upper(nullif(trim(b.suburb), ''))           AS suburb,
           CASE WHEN trim(b.postcode) ~ '^[0-9]{4}$' THEN trim(b.postcode) END AS postcode,
           nullif(trim(b.full_address), '')            AS full_address,
           CASE WHEN b.latitude IS NOT NULL AND b.longitude IS NOT NULL
                     -- a positive latitude or negative longitude here means the
                     -- pair was swapped at the source; treat as no coordinate
                     AND b.latitude < 0 AND b.longitude > 0
                THEN ST_SetSRID(ST_MakePoint(b.longitude, b.latitude), 4326) END AS geom
      FROM bronze.da_applications b
     WHERE b.planning_portal_application_number IS NOT NULL
     ORDER BY b.planning_portal_application_number, b._loaded_at DESC
), cost_bounds AS (
    SELECT percentile_cont(0.001) WITHIN GROUP (ORDER BY cost_of_development) AS lo,
           percentile_cont(0.999) WITHIN GROUP (ORDER BY cost_of_development) AS hi
      FROM src WHERE cost_of_development IS NOT NULL
), council_centre AS (
    -- where each council's applications actually cluster
    SELECT council_name,
           ST_SetSRID(ST_MakePoint(
               percentile_cont(0.5) WITHIN GROUP (ORDER BY ST_X(geom)),
               percentile_cont(0.5) WITHIN GROUP (ORDER BY ST_Y(geom))), 4326) AS centre
      FROM src
     WHERE geom IS NOT NULL AND council_name IS NOT NULL
     GROUP BY council_name
), collisions AS (
    -- same exact point used by 3+ applications at different addresses
    SELECT geom
      FROM src
     WHERE geom IS NOT NULL
     GROUP BY geom
    HAVING count(*) >= 3 AND count(DISTINCT coalesce(full_address, '')) >= 3
), scored AS (
    SELECT s.*,
           (s.geom IS NOT NULL AND ST_Intersects(s.geom, a.geom))      AS inside_aoi,
           (s.geom IS NOT NULL AND cc.centre IS NOT NULL
             AND ST_Distance(s.geom::geography, cc.centre::geography) > 50000)
                                                                       AS bad_geocode,
           (co.geom IS NOT NULL)                                       AS collision,
           (s.cost_of_development IS NOT NULL
             AND (s.cost_of_development < cb.lo OR s.cost_of_development > cb.hi))
                                                                       AS cost_outlier,
           (s.lodgement_date     < s.submission_date
             OR s.determination_date < s.lodgement_date)               AS date_disorder
      FROM src s
      CROSS JOIN aoi a
      CROSS JOIN cost_bounds cb
      LEFT JOIN council_centre cc USING (council_name)
      LEFT JOIN collisions co ON co.geom = s.geom
)
SELECT application_number, council_application_number, council_name, application_type,
       application_status, submission_date, lodgement_date, determination_date,
       date_last_updated, determination_authority, cost_of_development,
       number_of_new_dwellings, number_of_storeys, number_of_existing_lots,
       number_of_proposed_lots,
       CASE WHEN determination_date IS NOT NULL AND lodgement_date IS NOT NULL
                 AND determination_date >= lodgement_date
            THEN determination_date - lodgement_date END,
       suburb, postcode, full_address,
       geom,
       CASE WHEN inside_aoi AND NOT bad_geocode THEN ST_Transform(geom, 7856) END,
       geom IS NULL,
       geom IS NOT NULL AND NOT inside_aoi,
       bad_geocode,
       collision,
       cost_outlier,
       coalesce(date_disorder, false),
       inside_aoi AND NOT bad_geocode
  FROM scored
ON CONFLICT (application_number) DO UPDATE
   SET application_status      = EXCLUDED.application_status,
       determination_date      = EXCLUDED.determination_date,
       date_last_updated       = EXCLUDED.date_last_updated,
       cost_of_development     = EXCLUDED.cost_of_development,
       number_of_new_dwellings = EXCLUDED.number_of_new_dwellings,
       number_of_storeys       = EXCLUDED.number_of_storeys,
       days_to_determination   = EXCLUDED.days_to_determination,
       geom                    = EXCLUDED.geom,
       geom_m                  = EXCLUDED.geom_m,
       flag_missing_coords     = EXCLUDED.flag_missing_coords,
       flag_outside_aoi        = EXCLUDED.flag_outside_aoi,
       flag_bad_geocode        = EXCLUDED.flag_bad_geocode,
       flag_geocode_collision  = EXCLUDED.flag_geocode_collision,
       flag_cost_outlier       = EXCLUDED.flag_cost_outlier,
       flag_date_order         = EXCLUDED.flag_date_order,
       is_usable               = EXCLUDED.is_usable,
       loaded_at               = now()
 WHERE (t.application_status, t.determination_date, t.cost_of_development,
        t.number_of_new_dwellings, t.is_usable)
       IS DISTINCT FROM
       (EXCLUDED.application_status, EXCLUDED.determination_date,
        EXCLUDED.cost_of_development, EXCLUDED.number_of_new_dwellings,
        EXCLUDED.is_usable);

UPDATE silver.da_application d
   SET hex_id = h.hex_id
  FROM silver.hex_300m h
 WHERE d.geom_m IS NOT NULL
   AND ST_Intersects(h.geom_m, d.geom_m)
   AND d.hex_id IS DISTINCT FROM h.hex_id;

-- development_types is a ';'-separated multi-value field, e.g.
--   "Balconies, decks, patios...; Demolition; Retaining walls...; Garages..."
-- which is unsearchable as one string. Split into one row per type; the source
-- also publishes development_type_count, so the split is directly verifiable.
CREATE TABLE IF NOT EXISTS silver.da_development_type (
    application_number text        NOT NULL REFERENCES silver.da_application ON DELETE CASCADE,
    development_type   text        NOT NULL,
    loaded_at          timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT da_development_type_pkey PRIMARY KEY (application_number, development_type)
);

CREATE INDEX IF NOT EXISTS da_development_type_type_idx
    ON silver.da_development_type (development_type);

DELETE FROM silver.da_development_type;

INSERT INTO silver.da_development_type (application_number, development_type)
SELECT DISTINCT
       b.planning_portal_application_number,
       trim(part)
  FROM bronze.da_applications b
  CROSS JOIN unnest(string_to_array(b.development_types, ';')) AS part
 WHERE b.development_types IS NOT NULL
   AND nullif(trim(part), '') IS NOT NULL
   AND EXISTS (SELECT 1 FROM silver.da_application d
                WHERE d.application_number = b.planning_portal_application_number);
