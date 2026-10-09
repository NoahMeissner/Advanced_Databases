-- silver.bus_stop - the spine every other source is measured against.
--
-- Bronze keeps the GeoJSON losslessly in a jsonb column; this is where it
-- becomes real PostGIS geometry. Two geometry columns on purpose:
--
--   geom    EPSG:4326  storage / interchange, and what H3 consumes directly
--   geom_m  EPSG:7856  GDA2020 / MGA zone 56 - the ONLY column distances and
--                      buffers may use. The whole stop hull is 150.34-151.33 E,
--                      comfortably inside zone 56's 150-156 E validity range.
--
-- geom_m is a plain column filled on insert rather than a generated column:
-- ST_Transform's IMMUTABLE marking is version-dependent and a generated column
-- built on it breaks on dump/restore.
--
-- routes_served comes out of the jsonb array, which gives route_count for free
-- without touching the 135k-row edges table.
--
-- hex_id stays NULL here and is filled by 11_hex_300m.sql: the hexagon grid is
-- generated from the AOI, and the AOI is derived from these very stops.

CREATE TABLE IF NOT EXISTS silver.bus_stop (
    stop_id         integer     PRIMARY KEY,
    stop_name       text,
    routes_served   text[]      NOT NULL DEFAULT '{}',
    route_count     integer     NOT NULL DEFAULT 0,
    geom            geometry(Point, 4326) NOT NULL,
    geom_m          geometry(Point, 7856) NOT NULL,
    hex_id          text,       -- -> silver.hex_300m, set by 11_hex_300m.sql
    -- 69 stops have no edge in bronze.bus_graph_edges. Flagged so a NULL
    -- travel time downstream is explained rather than mysterious.
    flag_no_service boolean     NOT NULL DEFAULT false,
    record_source   text        NOT NULL DEFAULT 'SYDNEY_BUS_STOPS_GEOJSON',
    loaded_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS bus_stop_geom_idx     ON silver.bus_stop USING gist (geom);
CREATE INDEX IF NOT EXISTS bus_stop_geom_m_idx   ON silver.bus_stop USING gist (geom_m);
CREATE INDEX IF NOT EXISTS bus_stop_hex_idx      ON silver.bus_stop (hex_id);

INSERT INTO silver.bus_stop AS t
    (stop_id, stop_name, routes_served, route_count, geom, geom_m, flag_no_service)
WITH src AS (
    SELECT DISTINCT ON (b.stop_id)
           b.stop_id,
           nullif(trim(b.name), '')                            AS stop_name,
           COALESCE(
               (SELECT array_agg(DISTINCT trim(r))
                  FROM jsonb_array_elements_text(b.routes_served) AS r
                 WHERE nullif(trim(r), '') IS NOT NULL),
               '{}')                                           AS routes_served,
           ST_SetSRID(ST_GeomFromGeoJSON(b.geometry), 4326)     AS geom
      FROM bronze.bus_stops b
     WHERE b.stop_id IS NOT NULL
       AND b.geometry IS NOT NULL
       AND b.geometry ->> 'type' = 'Point'
     ORDER BY b.stop_id, b._loaded_at DESC          -- on duplicates the newest wins
), served AS (
    SELECT DISTINCT from_stop_id AS stop_id FROM bronze.bus_graph_edges
                                            WHERE from_stop_id IS NOT NULL
    UNION
    SELECT DISTINCT to_stop_id   AS stop_id FROM bronze.bus_graph_edges
                                            WHERE to_stop_id IS NOT NULL
)
SELECT s.stop_id,
       s.stop_name,
       s.routes_served,
       cardinality(s.routes_served),
       s.geom,
       ST_Transform(s.geom, 7856),
       (e.stop_id IS NULL)
  FROM src s
  LEFT JOIN served e USING (stop_id)
ON CONFLICT (stop_id) DO UPDATE
   SET stop_name       = EXCLUDED.stop_name,
       routes_served   = EXCLUDED.routes_served,
       route_count     = EXCLUDED.route_count,
       geom            = EXCLUDED.geom,
       geom_m          = EXCLUDED.geom_m,
       flag_no_service = EXCLUDED.flag_no_service,
       loaded_at       = now()
 WHERE (t.stop_name, t.routes_served, t.route_count, t.flag_no_service)
       IS DISTINCT FROM
       (EXCLUDED.stop_name, EXCLUDED.routes_served, EXCLUDED.route_count,
        EXCLUDED.flag_no_service)
    OR NOT ST_Equals(t.geom, EXCLUDED.geom);

-- The study area, derived from the stops rather than hard-coded: a 2 km buffer
-- around their convex hull. Keeps the ~830 genuine Illawarra / South Coast
-- stops in scope while giving DA and school rows (which span all of NSW, Lord
-- Howe Island included) a defensible "is this plausibly in our area" test.
CREATE MATERIALIZED VIEW IF NOT EXISTS silver.aoi AS
SELECT ST_Buffer(ST_ConvexHull(ST_Collect(geom_m)), 2000) AS geom_m,
       count(*)                                           AS n_stops
  FROM silver.bus_stop;

REFRESH MATERIALIZED VIEW silver.aoi;
