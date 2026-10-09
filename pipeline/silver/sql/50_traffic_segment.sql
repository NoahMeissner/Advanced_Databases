-- silver.traffic_segment - where a traffic segment is.
--
-- EMPTY UNTIL A REFERENCE LANDS. bronze.traffic_segment_hourly identifies
-- segments only as 'SEG001'..'SEG006' with no coordinates, and no file on disk
-- resolves them to a place. The hourly counts are therefore usable per segment
-- (51, 52) but cannot be joined to bus stops (53) yet.
--
-- The table is created now, not later, so that:
--   - 53_bus_stop_traffic.sql runs and produces 0 rows rather than failing
--   - silver.bus_stop_profile already carries its traffic columns as NULL
--   - ingesting the TfNSW segment/station reference is a data drop plus one
--     INSERT here, with no schema change anywhere downstream
--
-- geometry_source records how the geometry was obtained, because the publisher
-- may supply station points rather than road lines, in which case a segment's
-- geometry is derived from its stations rather than published directly.

CREATE TABLE IF NOT EXISTS silver.traffic_segment (
    segment_id      text        PRIMARY KEY,
    road_name       text,
    geom            geometry(Geometry, 4326),
    geom_m          geometry(Geometry, 7856),
    geometry_source text,
    n_stations      integer,
    flag_outside_aoi boolean    NOT NULL DEFAULT false,
    record_source   text        NOT NULL DEFAULT 'TFNSW_TRAFFIC_VOLUME_COUNTS',
    loaded_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS traffic_segment_geom_m_idx ON silver.traffic_segment USING gist (geom_m);
