-- Checks for the graph itself.
--
-- The graph is a projection of silver, so most of these assert that nothing was
-- lost or invented on the way. The CONNECTS checks matter most: collapsing
-- 47,047 route segments into 28,340 routing edges is where a plausible-looking
-- but wrong number is most likely to be introduced.

SELECT 'gold.graph_node'::text, 'node_key_unique'::text, 'uniqueness'::text,
       'error'::text,
       (SELECT count(*) - count(DISTINCT (label, node_key)) FROM gold.graph_node),
       (SELECT count(*) FROM gold.graph_node), NULL::numeric, NULL::jsonb
UNION ALL
-- Enforced by the foreign keys, checked so a failure is reported rather than
-- only raised: a dangling edge would become an orphan relationship in Neo4j.
SELECT 'gold.graph_edge', 'no_dangling_edges', 'consistency', 'error',
       (SELECT count(*) FROM gold.graph_edge e
         WHERE NOT EXISTS (SELECT 1 FROM gold.graph_node n
                            WHERE n.label = e.from_label AND n.node_key = e.from_key)
            OR NOT EXISTS (SELECT 1 FROM gold.graph_node n
                            WHERE n.label = e.to_label AND n.node_key = e.to_key)),
       (SELECT count(*) FROM gold.graph_edge), NULL, NULL
UNION ALL
SELECT 'gold.graph_node', 'stop_nodes_match_silver', 'completeness', 'error',
       abs((SELECT count(*) FROM gold.graph_node WHERE label = 'Stop')
           - (SELECT count(*) FROM silver.bus_stop))::bigint,
       (SELECT count(*) FROM silver.bus_stop)::bigint, NULL,
       (SELECT jsonb_object_agg(label, n) FROM (
            SELECT label, count(*) n FROM gold.graph_node GROUP BY 1) q)
UNION ALL
SELECT 'gold.graph_node', 'stop_has_geometry', 'completeness', 'error',
       (SELECT count(*) FROM gold.graph_node WHERE label = 'Stop' AND geom IS NULL),
       (SELECT count(*) FROM gold.graph_node WHERE label = 'Stop'), NULL, NULL
UNION ALL
SELECT 'gold.graph_edge', 'route_segment_matches_silver', 'completeness', 'error',
       abs((SELECT count(*) FROM gold.graph_edge WHERE rel_type = 'ROUTE_SEGMENT')
           - (SELECT count(*) FROM silver.bus_edge))::bigint,
       (SELECT count(*) FROM silver.bus_edge)::bigint, NULL, NULL
UNION ALL
-- CONNECTS must be exactly the distinct stop pairs that carry a travel time.
SELECT 'gold.graph_edge', 'connects_collapses_correctly', 'consistency', 'error',
       abs((SELECT count(*) FROM gold.graph_edge WHERE rel_type = 'CONNECTS')
           - (SELECT count(*) FROM (
                  SELECT DISTINCT e.from_stop_id, e.to_stop_id
                    FROM silver.bus_edge e
                    JOIN silver.bus_edge_travel_time t USING (edge_key)) q))::bigint,
       (SELECT count(*) FROM gold.graph_edge WHERE rel_type = 'CONNECTS')::bigint,
       NULL, NULL
UNION ALL
-- best_peak_s must really be the minimum over the pair's non-zero segments.
-- It catches a silently wrong routing weight.
SELECT 'gold.graph_edge', 'connects_best_is_min', 'accuracy', 'error',
       (SELECT count(*) FROM gold.graph_edge g
         JOIN (SELECT e.from_stop_id, e.to_stop_id,
                      min(t.avg_travel_time_s) AS expected
                 FROM silver.bus_edge e
                 JOIN silver.bus_edge_travel_time t USING (edge_key)
                WHERE t.time_band = 'peak' AND NOT t.flag_zero_timepoint
                GROUP BY 1, 2) m
           ON m.from_stop_id::text = g.from_key AND m.to_stop_id::text = g.to_key
        WHERE g.rel_type = 'CONNECTS'
          AND (g.properties ->> 'best_peak_s')::numeric <> m.expected),
       (SELECT count(*) FROM gold.graph_edge WHERE rel_type = 'CONNECTS'), NULL, NULL
UNION ALL
-- A 0 s hop would hand Dijkstra a free move. GTFS timepoints are whole minutes,
-- so 0 s is an artefact and must never become a routing weight.
SELECT 'gold.graph_edge', 'connects_excludes_zero_timepoint', 'validity', 'error',
       (SELECT count(*) FROM gold.graph_edge
         WHERE rel_type = 'CONNECTS'
           AND (properties ->> 'best_peak_s')::numeric = 0),
       (SELECT count(*) FROM gold.graph_edge WHERE rel_type = 'CONNECTS'), NULL, NULL
UNION ALL
-- The routing weight must never be NULL. A missing property projects into GDS
-- as NaN, which propagates through the whole path: Dijkstra then reports NaN
-- for the total cost AND picks a distorted route. The node and edge counts look
-- perfect either way, so only this check catches it.
SELECT 'gold.graph_edge', 'connects_weight_never_null', 'completeness', 'error',
       (SELECT count(*) FROM gold.graph_edge
         WHERE rel_type = 'CONNECTS'
           AND ((properties ->> 'travel_time_s') IS NULL
                OR (properties ->> 'travel_time_s')::numeric <= 0)),
       (SELECT count(*) FROM gold.graph_edge WHERE rel_type = 'CONNECTS'), NULL,
       (SELECT jsonb_build_object(
            'imputed_weights', count(*) FILTER (
                WHERE (properties ->> 'flag_weight_imputed')::boolean),
            'total', count(*))
          FROM gold.graph_edge WHERE rel_type = 'CONNECTS')
UNION ALL
-- An imputed weight is a substituted figure, so the share is worth watching.
SELECT 'gold.graph_edge', 'connects_weight_imputed_share', 'accuracy', 'warn',
       (SELECT count(*) FROM gold.graph_edge
         WHERE rel_type = 'CONNECTS'
           AND (properties ->> 'flag_weight_imputed')::boolean),
       (SELECT count(*) FROM gold.graph_edge WHERE rel_type = 'CONNECTS'), 0.25, NULL
UNION ALL
SELECT 'gold.graph_edge', 'no_self_loop', 'validity', 'error',
       (SELECT count(*) FROM gold.graph_edge
         WHERE rel_type IN ('ROUTE_SEGMENT', 'CONNECTS') AND from_key = to_key),
       (SELECT count(*) FROM gold.graph_edge), NULL, NULL
UNION ALL
SELECT 'gold.graph_edge', 'near_school_matches_silver', 'completeness', 'error',
       abs((SELECT count(*) FROM gold.graph_edge WHERE rel_type = 'NEAR_SCHOOL')
           - (SELECT count(*) FROM silver.bus_stop_school b
               WHERE b.radius_m = 200
                 AND EXISTS (SELECT 1 FROM gold.graph_node n
                              WHERE n.label = 'School'
                                AND n.node_key = b.school_code::text)))::bigint,
       (SELECT count(*) FROM gold.graph_edge WHERE rel_type = 'NEAR_SCHOOL')::bigint,
       NULL, NULL
UNION ALL
-- Every stop belongs to exactly one LGA.
SELECT 'gold.graph_edge', 'stop_in_exactly_one_lga', 'consistency', 'error',
       (SELECT count(*) FROM (
            SELECT from_key FROM gold.graph_edge
             WHERE rel_type = 'IN_LGA' AND from_label = 'Stop'
             GROUP BY from_key HAVING count(*) <> 1) q),
       (SELECT count(*) FROM gold.graph_node WHERE label = 'Stop'), NULL, NULL
UNION ALL
-- Stops that have service must form one navigable network. 69 stops genuinely
-- have no edge at all, so the share is capped rather than required to be zero.
SELECT 'gold.graph_edge', 'stops_reachable', 'consistency', 'warn',
       (SELECT count(*) FROM gold.graph_node n
         WHERE n.label = 'Stop'
           AND NOT EXISTS (SELECT 1 FROM gold.graph_edge e
                            WHERE e.rel_type = 'CONNECTS'
                              AND (e.from_key = n.node_key OR e.to_key = n.node_key))),
       (SELECT count(*) FROM gold.graph_node WHERE label = 'Stop'), 0.01,
       jsonb_build_object('note', '69 stops have no edge in the source feed')
UNION ALL
-- The Stop node must actually carry the metadata, not just exist.
SELECT 'gold.graph_node', 'stop_properties_populated', 'completeness', 'error',
       (SELECT count(*) FROM gold.graph_node
         WHERE label = 'Stop'
           AND NOT (properties ? 'stop_name' AND properties ? 'has_da_data'
                    AND properties ? 'has_rent_data' AND properties ? 'route_count')),
       (SELECT count(*) FROM gold.graph_node WHERE label = 'Stop'), NULL, NULL;
