-- silver.traffic_segment_hourly - the hourly counts, typed and flagged.
--
-- All timestamps in the source are Sydney local (transformed_at carries +11:00
-- AEDT), so hour_of_day needs no timezone conversion. Getting that wrong would
-- shift the whole rush-hour definition, which is why 52's diurnal_shape check
-- exists.
--
-- Quality signals the publisher already provides, carried through rather than
-- re-derived: quality_flag ('reported' | 'caution') and min_station_quality.
-- 'caution' rows stay in the table and are counted, but is_usable excludes them
-- from headline aggregates.
--
-- flag_partial_day matters more than it looks: if a segment-day is missing
-- hours, a naive "total / 24" would treat those hours as zero traffic. 52
-- averages over observed hours only, and this flag is how you know which days
-- are affected.

CREATE TABLE IF NOT EXISTS silver.traffic_segment_hourly (
    segment_id          text        NOT NULL,
    observation_date    date        NOT NULL,
    hour_of_day         smallint    NOT NULL,
    avg_vehicle_count   numeric(12,4),
    max_vehicle_count   integer,
    observation_count   integer,
    station_count       integer,
    min_station_quality smallint,
    quality_flag        text,
    flag_low_quality    boolean     NOT NULL DEFAULT false,
    flag_partial_day    boolean     NOT NULL DEFAULT false,
    flag_low_sample     boolean     NOT NULL DEFAULT false,
    is_usable           boolean     NOT NULL DEFAULT true,
    record_source       text        NOT NULL DEFAULT 'TFNSW_TRAFFIC_VOLUME_COUNTS',
    loaded_at           timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT traffic_segment_hourly_pkey
        PRIMARY KEY (segment_id, observation_date, hour_of_day),
    CONSTRAINT traffic_segment_hourly_hour_check CHECK (hour_of_day BETWEEN 0 AND 23),
    CONSTRAINT traffic_segment_hourly_count_check CHECK (avg_vehicle_count >= 0)
);

CREATE INDEX IF NOT EXISTS traffic_segment_hourly_segment_idx
    ON silver.traffic_segment_hourly (segment_id, hour_of_day) WHERE is_usable;

INSERT INTO silver.traffic_segment_hourly AS t
    (segment_id, observation_date, hour_of_day, avg_vehicle_count,
     max_vehicle_count, observation_count, station_count, min_station_quality,
     quality_flag, flag_low_quality, flag_partial_day, flag_low_sample, is_usable)
WITH src AS (
    SELECT DISTINCT ON (b.segment_id, b.observation_date, b.hour_of_day)
           b.segment_id, b.observation_date, b.hour_of_day,
           b.avg_vehicle_count, b.max_vehicle_count, b.observation_count,
           b.station_count, b.min_station_quality,
           nullif(trim(b.quality_flag), '') AS quality_flag
      FROM bronze.traffic_segment_hourly b
     WHERE b.segment_id       IS NOT NULL
       AND b.observation_date IS NOT NULL
       AND b.hour_of_day BETWEEN 0 AND 23
       AND coalesce(b.avg_vehicle_count, 0) >= 0
     ORDER BY b.segment_id, b.observation_date, b.hour_of_day, b._loaded_at DESC
), day_cover AS (
    SELECT segment_id, observation_date, count(*) AS hours_present
      FROM src GROUP BY segment_id, observation_date
)
SELECT s.segment_id, s.observation_date, s.hour_of_day, s.avg_vehicle_count,
       s.max_vehicle_count, s.observation_count, s.station_count,
       s.min_station_quality, s.quality_flag,
       (s.quality_flag = 'caution' OR s.min_station_quality < 5),  -- flag_low_quality
       (d.hours_present < 24),                                     -- flag_partial_day
       (coalesce(s.observation_count, 0) < 2),                     -- flag_low_sample
       s.quality_flag = 'reported' AND s.avg_vehicle_count IS NOT NULL
  FROM src s
  JOIN day_cover d USING (segment_id, observation_date)
ON CONFLICT (segment_id, observation_date, hour_of_day) DO UPDATE
   SET avg_vehicle_count   = EXCLUDED.avg_vehicle_count,
       max_vehicle_count   = EXCLUDED.max_vehicle_count,
       observation_count   = EXCLUDED.observation_count,
       station_count       = EXCLUDED.station_count,
       min_station_quality = EXCLUDED.min_station_quality,
       quality_flag        = EXCLUDED.quality_flag,
       flag_low_quality    = EXCLUDED.flag_low_quality,
       flag_partial_day    = EXCLUDED.flag_partial_day,
       flag_low_sample     = EXCLUDED.flag_low_sample,
       is_usable           = EXCLUDED.is_usable,
       loaded_at           = now()
 WHERE (t.avg_vehicle_count, t.max_vehicle_count, t.quality_flag, t.is_usable)
       IS DISTINCT FROM
       (EXCLUDED.avg_vehicle_count, EXCLUDED.max_vehicle_count,
        EXCLUDED.quality_flag, EXCLUDED.is_usable);
