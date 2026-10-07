CREATE SCHEMA IF NOT EXISTS bronze;

-- --- Stops ----------------------------------------------------------------
-- Primary key: stop_id (verified unique and never null).
CREATE TABLE IF NOT EXISTS bronze.bus_stops (
    stop_id        integer      NOT NULL,
    name           text,
    routes_served  jsonb,                                -- JSON array, e.g. ["515","521","541"]
    geometry_type  text,                                 -- "Point"
    geometry       jsonb,                                -- e.g. {"type":"Point","coordinates":[151.08,-33.79]}
    -- Lineage: where the row comes from, when it was loaded
    _source_file   text         NOT NULL,
    _loaded_at     timestamptz  NOT NULL DEFAULT now(),

    CONSTRAINT bus_stops_pkey PRIMARY KEY (stop_id)
);

CREATE TABLE IF NOT EXISTS bronze.bus_routes (
    _row_id           bigint       GENERATED ALWAYS AS IDENTITY,
    route_id          text         NOT NULL,
    route_short_name  text,
    route_long_name   text,
    agency_id         integer,
    direction_id      smallint,                          -- GTFS: 0 or 1
    route_color       text,                              -- hex without '#', e.g. 00B5EF
    trip_headsign     text,
    geometry_type     text,                              -- "LineString"
    geometry          jsonb,                             -- the complete route shape
    -- Lineage: where the row comes from, when it was loaded
    _source_file      text         NOT NULL,
    _loaded_at        timestamptz  NOT NULL DEFAULT now(),

    CONSTRAINT bus_routes_pkey PRIMARY KEY (_row_id),
    CONSTRAINT bus_routes_direction_id_check CHECK (direction_id IN (0, 1))
);

CREATE INDEX IF NOT EXISTS bus_routes_route_id_idx
    ON bronze.bus_routes (route_id, direction_id);
