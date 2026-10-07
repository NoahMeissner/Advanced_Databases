CREATE SCHEMA IF NOT EXISTS bronze;

CREATE TABLE IF NOT EXISTS bronze.bus_graph_edges (
    edge_id                    integer      NOT NULL,
    from_stop_id               integer,     -- -> bronze.bus_stops.stop_id
    to_stop_id                 integer,     -- -> bronze.bus_stops.stop_id
    route_id                   text,        -- -> bronze.bus_routes.route_id
    route_short_name           text,
    direction_id               smallint,    -- GTFS: 0 or 1
    avg_travel_time_peak_s     numeric(10,2),   -- seconds, 0.0 does occur in the source
    n_trips_peak               integer,
    avg_travel_time_offpeak_s  numeric(10,2),   -- seconds, 0.0 does occur in the source
    n_trips_offpeak            integer,
    geometry_type              text,        -- "LineString"
    geometry                   jsonb,       -- two points: from -> to
    -- Lineage: where the row comes from, when it was loaded
    _source_file               text         NOT NULL,
    _loaded_at                 timestamptz  NOT NULL DEFAULT now(),

    CONSTRAINT bus_graph_edges_pkey PRIMARY KEY (edge_id),
    CONSTRAINT bus_graph_edges_direction_id_check CHECK (direction_id IN (0, 1))
);

CREATE INDEX IF NOT EXISTS bus_graph_edges_from_stop_idx
    ON bronze.bus_graph_edges (from_stop_id);
CREATE INDEX IF NOT EXISTS bus_graph_edges_to_stop_idx
    ON bronze.bus_graph_edges (to_stop_id);
