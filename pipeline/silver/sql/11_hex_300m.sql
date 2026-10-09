-- silver.hex_300m - the 300 x 300 m hexagon grid, and its neighbour bridge.
--
-- WHY NOT H3: h3 res 9 is the nearest H3 resolution, but measured on this data
-- its cells are 126,636 m2 and ~420 m across - 1.41x the requested 300 m cell.
-- The next resolution down (res 10) is ~18,000 m2, far too small. So the grid
-- is generated with ST_HexagonGrid in the projected CRS instead, where the size
-- is exact:
--
--   ST_HexagonGrid(173.205, ...) -> 300.0 m flat-to-flat, 346 m point-to-point,
--                                   77,942 m2  (a 300x300 m square is 90,000 m2)
--
-- edge = 300 / sqrt(3) = 173.205 m, so the flat-to-flat width is exactly 300 m.
--
-- hex_id is derived from the grid's own (i, j), not a serial, so it is stable
-- across rebuilds and reproducible from the size + SRID alone.
--
-- The grid is clipped to silver.aoi (2 km around the bus-stop convex hull), so
-- it covers the study area and nothing else.

CREATE TABLE IF NOT EXISTS silver.hex_300m (
    hex_id     text        PRIMARY KEY,     -- 'h300_<i>_<j>'
    grid_i     integer     NOT NULL,
    grid_j     integer     NOT NULL,
    geom       geometry(Polygon, 4326) NOT NULL,
    geom_m     geometry(Polygon, 7856) NOT NULL,
    centroid   geometry(Point,   4326) NOT NULL,
    centroid_m geometry(Point,   7856) NOT NULL,
    area_m2    numeric(12,2) NOT NULL,
    edge_m     numeric(10,3) NOT NULL DEFAULT 173.205,
    loaded_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS hex_300m_geom_m_idx     ON silver.hex_300m USING gist (geom_m);
CREATE INDEX IF NOT EXISTS hex_300m_geom_idx       ON silver.hex_300m USING gist (geom);
CREATE INDEX IF NOT EXISTS hex_300m_centroid_m_idx ON silver.hex_300m USING gist (centroid_m);

INSERT INTO silver.hex_300m (hex_id, grid_i, grid_j, geom, geom_m, centroid, centroid_m, area_m2)
SELECT 'h300_' || g.i || '_' || g.j,
       g.i,
       g.j,
       ST_Transform(g.geom, 4326),
       g.geom,
       ST_Transform(ST_Centroid(g.geom), 4326),
       ST_Centroid(g.geom),
       ST_Area(g.geom)
  FROM silver.aoi a,
       ST_HexagonGrid(173.205, a.geom_m) AS g
 WHERE ST_Intersects(g.geom, a.geom_m)
ON CONFLICT (hex_id) DO NOTHING;      -- the grid is deterministic; nothing to update

-- k-ring 1 as a bridge table: the cell plus its 6 edge-sharing neighbours.
--
-- Adjacent hexagon centres are exactly one flat-to-flat width apart (300 m), so
-- a 310 m centroid radius picks up precisely the 6 neighbours - no i/j offset
-- arithmetic, and no dependency on how PostGIS numbers its rows. Every
-- bus_stop_* step reuses this instead of re-deriving the neighbourhood.
CREATE TABLE IF NOT EXISTS silver.hex_300m_neighbour (
    hex_id           text    NOT NULL REFERENCES silver.hex_300m ON DELETE CASCADE,
    neighbour_hex_id text    NOT NULL REFERENCES silver.hex_300m ON DELETE CASCADE,
    is_self          boolean NOT NULL,
    CONSTRAINT hex_300m_neighbour_pkey PRIMARY KEY (hex_id, neighbour_hex_id)
);

INSERT INTO silver.hex_300m_neighbour (hex_id, neighbour_hex_id, is_self)
SELECT h.hex_id, n.hex_id, (h.hex_id = n.hex_id)
  FROM silver.hex_300m h
  JOIN silver.hex_300m n
    ON ST_DWithin(h.centroid_m, n.centroid_m, 310)
ON CONFLICT (hex_id, neighbour_hex_id) DO NOTHING;

-- Now that the grid exists, place the stops in it.
UPDATE silver.bus_stop s
   SET hex_id = h.hex_id
  FROM silver.hex_300m h
 WHERE ST_Intersects(h.geom_m, s.geom_m)
   AND s.hex_id IS DISTINCT FROM h.hex_id;
