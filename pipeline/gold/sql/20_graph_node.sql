-- gold.graph_node - every node of the one graph.
--
-- One generic table rather than four typed ones, because the Neo4j loader then
-- needs no per-label code and the graph is a single object you can count, diff
-- and check. `properties` is jsonb because that is literally what a Neo4j node
-- takes, so the loader is UNWIND + SET n += r.props and nothing more.
--
--   Stop    the reference point. Carries its metadata as properties - rent,
--           sales, development, schools nearby, traffic - so one node answers
--           "what is happening around this stop" without a traversal.
--   School  its own node, so "which stops share a school" is a traversal.
--           A school 200 m from 13 stops is one node with 13 edges, not 13
--           copies of a school name.
--   LGA     its own node, so "every stop in this LGA" and the rent comparison
--           hang off the graph rather than off a join.
--   Route   its own node, so "which stops does the 545 serve" is a traversal.
--
-- Hexagons are deliberately NOT nodes: 181,492 of them, mostly empty, and the
-- hexagon figure is already a property of the stop that sits in it.

CREATE TABLE IF NOT EXISTS gold.graph_node (
    label      text        NOT NULL,        -- 'Stop' | 'School' | 'LGA' | 'Route'
    node_key   text        NOT NULL,        -- unique within label
    properties jsonb       NOT NULL,
    geom       geometry(Point, 4326),       -- NULL for LGA and Route
    loaded_at  timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT graph_node_pkey PRIMARY KEY (label, node_key),
    CONSTRAINT graph_node_label_check
        CHECK (label IN ('Stop', 'School', 'LGA', 'Route'))
);

CREATE INDEX IF NOT EXISTS graph_node_label_idx ON gold.graph_node (label);
CREATE INDEX IF NOT EXISTS graph_node_geom_idx  ON gold.graph_node USING gist (geom);

DELETE FROM gold.graph_node;

-- Stop: the whole per-stop profile, flattened into properties.
-- to_jsonb(row) then '-' the geometry columns: listing 40 keys by hand is how a
-- new silver measure silently fails to reach the graph.
INSERT INTO gold.graph_node (label, node_key, properties, geom)
SELECT 'Stop',
       p.stop_id::text,
       to_jsonb(p) - 'geom' - 'geom_m' - 'loaded_at' - 'stop_id',
       p.geom
  FROM silver.bus_stop_profile p;

INSERT INTO gold.graph_node (label, node_key, properties, geom)
SELECT 'School',
       s.school_code::text,
       jsonb_strip_nulls(jsonb_build_object(
           'school_name',        s.school_name,
           'level_of_schooling', s.level_of_schooling,
           'school_gender',      s.school_gender,
           'selective_school',   s.selective_school,
           'enrolment_fte',      s.latest_year_enrolment_fte,
           'icsea_value',        s.icsea_value,
           'town_suburb',        s.town_suburb,
           'postcode',           s.postcode,
           'lga_code',           silver.lga_key(s.lga),
           'hex_id',             s.hex_id)),
       s.geom
  FROM silver.school s
 WHERE s.is_usable;

-- LGA: the comparison mart is the node's property bag, so a Cypher query can
-- rank LGAs without leaving the graph.
INSERT INTO gold.graph_node (label, node_key, properties, geom)
SELECT 'LGA',
       c.lga_code,
       to_jsonb(c) - 'loaded_at' - 'lga_code',
       NULL
  FROM gold.lga_comparison c;

INSERT INTO gold.graph_node (label, node_key, properties, geom)
SELECT 'Route',
       r.route_id,
       jsonb_strip_nulls(jsonb_build_object(
           'route_short_name', r.route_short_name,
           'route_long_name',  r.route_long_name,
           'agency_id',        r.agency_id,
           'route_color',      r.route_color,
           'headsigns',        to_jsonb(r.headsigns),
           'n_directions',     r.n_directions,
           'n_stops_served',   (SELECT count(*) FROM silver.bus_stop s
                                 WHERE r.route_short_name = ANY (s.routes_served)))),
       NULL
  FROM silver.route r;
