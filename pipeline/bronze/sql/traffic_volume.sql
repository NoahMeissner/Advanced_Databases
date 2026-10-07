CREATE SCHEMA IF NOT EXISTS bronze;

CREATE TABLE IF NOT EXISTS bronze.traffic_segment_hourly (
    segment_id           text         NOT NULL,          -- e.g. SEG001, not numeric
    observation_date     date         NOT NULL,
    hour_of_day          smallint     NOT NULL,
    avg_vehicle_count    numeric(12,4),                  -- fractional, it is an average
    max_vehicle_count    integer,
    observation_count    integer,
    station_count        integer,
    min_station_quality  smallint,
    quality_flag         text,                           -- 'reported' | 'caution'
    record_source        text,
    transformed_at       timestamptz,
    -- Lineage: where the row comes from, when it was loaded
    _source_file         text         NOT NULL,
    _loaded_at           timestamptz  NOT NULL DEFAULT now(),

    CONSTRAINT traffic_segment_hourly_pkey
        PRIMARY KEY (segment_id, observation_date, hour_of_day),
    CONSTRAINT traffic_segment_hourly_hour_of_day_check
        CHECK (hour_of_day BETWEEN 0 AND 23)
);
