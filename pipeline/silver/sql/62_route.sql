-- silver.route - one row per bus route.
--
-- Exists so the Gold graph's Route nodes have attributes without Gold reading
-- Bronze (the team contract: "Gold reads Silver only, never Bronze").
--
-- bronze.bus_routes is 4,317 features over 602 route_id values, because each
-- feature is a per-trip-pattern shape variant: one route_id can appear up to 25
-- times with different trip_headsign values. So this collapses to the route
-- grain and keeps the variant count rather than pretending route_id was unique.
--
-- direction_id is NOT part of the key: a route runs both ways and the headsigns
-- for each direction are collected into arrays instead.

CREATE TABLE IF NOT EXISTS silver.route (
    route_id         text        PRIMARY KEY,
    route_short_name text,
    route_long_name  text,
    agency_id        integer,
    route_color      text,
    headsigns        text[]      NOT NULL DEFAULT '{}',
    n_shape_variants integer     NOT NULL,
    n_directions     smallint    NOT NULL,
    record_source    text        NOT NULL DEFAULT 'SYDNEY_BUS_ROUTES_GEOJSON',
    loaded_at        timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS route_short_name_idx ON silver.route (route_short_name);

INSERT INTO silver.route AS t
    (route_id, route_short_name, route_long_name, agency_id, route_color,
     headsigns, n_shape_variants, n_directions)
SELECT route_id,
       min(nullif(trim(route_short_name), '')),
       min(nullif(trim(route_long_name), '')),
       min(agency_id),
       min(nullif(trim(route_color), '')),
       coalesce((array_agg(DISTINCT trim(trip_headsign))
                 FILTER (WHERE nullif(trim(trip_headsign), '') IS NOT NULL)), '{}'),
       count(*)::integer,
       count(DISTINCT direction_id)::smallint
  FROM bronze.bus_routes
 WHERE route_id IS NOT NULL
 GROUP BY route_id
ON CONFLICT (route_id) DO UPDATE
   SET route_short_name = EXCLUDED.route_short_name,
       route_long_name  = EXCLUDED.route_long_name,
       agency_id        = EXCLUDED.agency_id,
       route_color      = EXCLUDED.route_color,
       headsigns        = EXCLUDED.headsigns,
       n_shape_variants = EXCLUDED.n_shape_variants,
       n_directions     = EXCLUDED.n_directions,
       loaded_at        = now()
 WHERE (t.route_short_name, t.route_long_name, t.agency_id, t.headsigns,
        t.n_shape_variants, t.n_directions)
       IS DISTINCT FROM
       (EXCLUDED.route_short_name, EXCLUDED.route_long_name, EXCLUDED.agency_id,
        EXCLUDED.headsigns, EXCLUDED.n_shape_variants, EXCLUDED.n_directions);
