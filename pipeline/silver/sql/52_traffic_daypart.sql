-- silver.traffic_segment_daypart - rush / non-rush / night traffic per segment.
--
-- Fine-grained dayparts and the coarse roll-up live in ONE table, told apart by
-- daypart_kind, so a consumer can ask either question without a second join:
--
--   daypart        hours    daypart_kind
--   am_peak_07_09  07-09    rush
--   midday_09_16   09-16    non_rush
--   pm_peak_16_19  16-19    rush
--   evening_19_22  19-22    non_rush
--   night_22_07    22-07    night
--   rush / non_rush / night               summary   <- the three asked for
--
-- The fine buckets carry their hours in the name so they cannot collide with
-- the summary bucket names - 'night' is both a fine daypart and a roll-up, and
-- without the suffix the two would share a primary key.
--
-- night wraps midnight (22:00-07:00), which is why the hour sets are spelled
-- out rather than expressed as a BETWEEN.
--
-- avg_vehicles_per_hour is the mean over OBSERVED usable hours. It is never a
-- total divided by a nominal hour count: with a partial day that would silently
-- treat a missing hour as zero traffic and understate the segment.

CREATE TABLE IF NOT EXISTS silver.traffic_segment_daypart (
    segment_id            text        NOT NULL,
    daypart               text        NOT NULL,
    daypart_kind          text        NOT NULL,
    hours_in_daypart      smallint    NOT NULL,
    avg_vehicles_per_hour numeric(12,2),
    max_vehicles_per_hour integer,
    total_vehicles        numeric(16,2),
    n_hours_observed      integer     NOT NULL,
    n_days_observed       integer     NOT NULL,
    peak_hour_of_day      smallint,
    flag_low_sample       boolean     NOT NULL DEFAULT false,
    record_source         text        NOT NULL DEFAULT 'TFNSW_TRAFFIC_VOLUME_COUNTS',
    loaded_at             timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT traffic_segment_daypart_pkey PRIMARY KEY (segment_id, daypart),
    CONSTRAINT traffic_segment_daypart_kind_check
        CHECK (daypart_kind IN ('rush', 'non_rush', 'night', 'summary'))
);

DELETE FROM silver.traffic_segment_daypart;

INSERT INTO silver.traffic_segment_daypart
    (segment_id, daypart, daypart_kind, hours_in_daypart, avg_vehicles_per_hour,
     max_vehicles_per_hour, total_vehicles, n_hours_observed, n_days_observed,
     peak_hour_of_day, flag_low_sample)
WITH classified AS (
    SELECT h.segment_id, h.observation_date, h.hour_of_day,
           h.avg_vehicle_count, h.max_vehicle_count,
           CASE WHEN h.hour_of_day BETWEEN  7 AND  8 THEN 'am_peak_07_09'
                WHEN h.hour_of_day BETWEEN  9 AND 15 THEN 'midday_09_16'
                WHEN h.hour_of_day BETWEEN 16 AND 18 THEN 'pm_peak_16_19'
                WHEN h.hour_of_day BETWEEN 19 AND 21 THEN 'evening_19_22'
                ELSE 'night_22_07' END AS daypart      -- 22,23,0..6
      FROM silver.traffic_segment_hourly h
     WHERE h.is_usable
), kinded AS (
    SELECT c.*,
           CASE c.daypart WHEN 'am_peak_07_09' THEN 'rush'
                          WHEN 'pm_peak_16_19' THEN 'rush'
                          WHEN 'night_22_07'   THEN 'night'
                          ELSE 'non_rush' END AS kind
      FROM classified c
), unioned AS (
    -- the fine daypart, plus its summary bucket as a second row
    SELECT segment_id, daypart, kind AS daypart_kind,
           observation_date, hour_of_day, avg_vehicle_count, max_vehicle_count
      FROM kinded
    UNION ALL
    SELECT segment_id, kind AS daypart, 'summary',
           observation_date, hour_of_day, avg_vehicle_count, max_vehicle_count
      FROM kinded
)
SELECT segment_id,
       daypart,
       daypart_kind,
       count(DISTINCT hour_of_day)::smallint,
       round(avg(avg_vehicle_count), 2),                -- per observed hour
       max(max_vehicle_count),
       sum(avg_vehicle_count),
       count(*)::integer,
       count(DISTINCT observation_date)::integer,
       (array_agg(hour_of_day ORDER BY avg_vehicle_count DESC, hour_of_day))[1]::smallint,
       count(*) < 3
  FROM unioned
 GROUP BY segment_id, daypart, daypart_kind;
