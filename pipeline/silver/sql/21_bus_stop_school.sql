-- silver.bus_stop_school - schools near a stop, many-to-many.
--
-- One school legitimately produces several rows, one per nearby stop, which is
-- exactly what was asked for: a school 200 m from three stops belongs to all
-- three.
--
-- Two radii live in one table, discriminated by radius_m:
--   200  the requested threshold, what downstream code uses
--   300  exists ONLY to validate the join. The raw school CSV ships its own
--        answer at 300 m (nearest_station_id / station_count_300m /
--        station_match_status, 873 matched vs 1,337 not) which Bronze
--        deliberately drops as derived data. test/silver_integrity.py compares
--        our 300 m result against it - an independently produced oracle for the
--        whole proximity approach, which is worth far more than a self-check.
--
-- Distances are metres because both sides are EPSG:7856; ST_DWithin on 4326
-- degrees would silently compare apples to nothing.

CREATE TABLE IF NOT EXISTS silver.bus_stop_school (
    stop_id          integer       NOT NULL REFERENCES silver.bus_stop   ON DELETE CASCADE,
    school_code      integer       NOT NULL REFERENCES silver.school     ON DELETE CASCADE,
    radius_m         smallint      NOT NULL,
    distance_m       numeric(8,2)  NOT NULL,
    rank_from_stop   integer       NOT NULL,   -- 1 = this stop's closest school
    rank_from_school integer       NOT NULL,   -- 1 = this school's closest stop
    record_source    text          NOT NULL DEFAULT 'SCHOOL_X_BUS_STOP_PROXIMITY',
    loaded_at        timestamptz   NOT NULL DEFAULT now(),

    CONSTRAINT bus_stop_school_pkey PRIMARY KEY (radius_m, stop_id, school_code),
    CONSTRAINT bus_stop_school_radius_check CHECK (radius_m IN (200, 300))
);

CREATE INDEX IF NOT EXISTS bus_stop_school_school_idx
    ON silver.bus_stop_school (school_code, radius_m);

-- Derived join: rebuild wholesale inside the step's transaction.
DELETE FROM silver.bus_stop_school;

INSERT INTO silver.bus_stop_school
    (stop_id, school_code, radius_m, distance_m, rank_from_stop, rank_from_school)
WITH pairs AS (
    -- 300 m once, then the 200 m set is a filter on it rather than a second
    -- spatial pass over 23,427 stops x 1,077 schools
    SELECT st.stop_id,
           sc.school_code,
           ST_Distance(st.geom_m, sc.geom_m)::numeric AS distance_m
      FROM silver.bus_stop st
      JOIN silver.school   sc
        ON ST_DWithin(st.geom_m, sc.geom_m, 300)
     WHERE sc.is_usable
), banded AS (
    SELECT stop_id, school_code, distance_m, 300 AS radius_m FROM pairs
    UNION ALL
    SELECT stop_id, school_code, distance_m, 200 FROM pairs WHERE distance_m <= 200
)
SELECT stop_id,
       school_code,
       radius_m,
       round(distance_m, 2),
       rank() OVER (PARTITION BY radius_m, stop_id     ORDER BY distance_m, school_code),
       rank() OVER (PARTITION BY radius_m, school_code ORDER BY distance_m, stop_id)
  FROM banded;

-- Per-stop roll-up at the requested 200 m, so the profile table is a plain join.
CREATE TABLE IF NOT EXISTS silver.bus_stop_school_summary (
    stop_id                   integer     PRIMARY KEY REFERENCES silver.bus_stop ON DELETE CASCADE,
    n_schools_200m            integer     NOT NULL,
    nearest_school_code       integer,
    nearest_school_distance_m numeric(8,2),
    sum_enrolment_fte_200m    numeric(12,1),
    avg_icsea_200m            numeric(8,2),
    has_primary               boolean     NOT NULL DEFAULT false,
    has_secondary             boolean     NOT NULL DEFAULT false,
    record_source             text        NOT NULL DEFAULT 'SCHOOL_X_BUS_STOP_PROXIMITY',
    loaded_at                 timestamptz NOT NULL DEFAULT now()
);

DELETE FROM silver.bus_stop_school_summary;

INSERT INTO silver.bus_stop_school_summary
    (stop_id, n_schools_200m, nearest_school_code, nearest_school_distance_m,
     sum_enrolment_fte_200m, avg_icsea_200m, has_primary, has_secondary)
SELECT b.stop_id,
       count(*)::integer,
       (array_agg(s.school_code ORDER BY b.distance_m, s.school_code))[1],
       min(b.distance_m),
       sum(s.latest_year_enrolment_fte),
       round(avg(s.icsea_value), 2),
       bool_or(s.level_of_schooling ILIKE '%primary%'
               OR s.level_of_schooling ILIKE '%infants%'
               OR s.level_of_schooling ILIKE '%central%'),
       bool_or(s.level_of_schooling ILIKE '%secondary%'
               OR s.level_of_schooling ILIKE '%central%')
  FROM silver.bus_stop_school b
  JOIN silver.school s USING (school_code)
 WHERE b.radius_m = 200
 GROUP BY b.stop_id;
