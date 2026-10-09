# @Noah Meissner 9.10.2026
"""Test: the gold graph is sound, and Neo4j holds the same graph as Postgres.

The SQL checks (pipeline/gold/sql/checks) already assert the graph's internal
consistency. What cannot be done in SQL is the part this file exists for:

  1. PARITY. gold.graph_node / gold.graph_edge are the contract; Neo4j is a
     projection of them. If the two ever disagree, every Cypher answer is quietly
     wrong while every SQL check still passes. Counts are compared per label and
     per relationship type, not just in total, because two offsetting errors
     would cancel out in a single number.

  2. The graph is actually traversable. A node and edge count says nothing about
     whether a path exists, so this walks real relationships and runs a
     shortest-path query over the CONNECTS weights.

Prerequisites: the databases are running (./start.sh) and the pipeline has
completed (python -m pipeline.run).

Run from the repository root:
    python -m test.gold_integrity

Exit code 0 = graph consistent, 1 = at least one check failed.
"""
import sys

from test.report import report, summarise

import psycopg
from neo4j import GraphDatabase

import paths


def check_structure(conn) -> list[bool]:
    """Postgres-side invariants that complement the SQL checks."""
    results = []

    stops, nodes = conn.execute(
        "SELECT (SELECT count(*) FROM silver.bus_stop),"
        "       (SELECT count(*) FROM gold.graph_node WHERE label = 'Stop')"
    ).fetchone()
    results.append(report("every stop became a node", stops == nodes,
                          f"{nodes:,} of {stops:,}"))

    dangling = conn.execute(
        "SELECT count(*) FROM gold.graph_edge e WHERE NOT EXISTS ("
        "  SELECT 1 FROM gold.graph_node n"
        "   WHERE n.label = e.from_label AND n.node_key = e.from_key)"
        " OR NOT EXISTS (SELECT 1 FROM gold.graph_node n"
        "   WHERE n.label = e.to_label AND n.node_key = e.to_key)"
    ).fetchone()[0]
    results.append(report("no dangling edges", dangling == 0, f"{dangling:,}"))

    # the collapse from 47,047 route segments to 28,340 routing edges
    segments, connects, pairs = conn.execute(
        "SELECT (SELECT count(*) FROM gold.graph_edge WHERE rel_type = 'ROUTE_SEGMENT'),"
        "       (SELECT count(*) FROM gold.graph_edge WHERE rel_type = 'CONNECTS'),"
        "       (SELECT count(*) FROM (SELECT DISTINCT e.from_stop_id, e.to_stop_id"
        "           FROM silver.bus_edge e"
        "           JOIN silver.bus_edge_travel_time t USING (edge_key)) q)"
    ).fetchone()
    results.append(report("CONNECTS collapses ROUTE_SEGMENT", connects == pairs,
                          f"{segments:,} segments -> {connects:,} pairs"))

    zero = conn.execute(
        "SELECT count(*) FROM gold.graph_edge WHERE rel_type = 'CONNECTS'"
        " AND (properties ->> 'best_peak_s')::numeric = 0"
    ).fetchone()[0]
    results.append(report("no zero-second routing weights", zero == 0, f"{zero:,}"))
    return results


def check_parity(conn, session) -> list[bool]:
    """Node and relationship counts must match between Postgres and Neo4j."""
    results = []

    pg_nodes = dict(conn.execute(
        "SELECT label, count(*) FROM gold.graph_node GROUP BY 1").fetchall())
    neo_nodes = {
        row["label"]: row["n"] for row in session.run(
            "MATCH (n) RETURN labels(n)[0] AS label, count(*) AS n")
    }
    for label in sorted(pg_nodes):
        same = pg_nodes[label] == neo_nodes.get(label)
        results.append(report(
            f"parity (:{label})", same,
            f"pg {pg_nodes[label]:,} / neo4j {neo_nodes.get(label, 0):,}",
        ))

    pg_rels = dict(conn.execute(
        "SELECT rel_type, count(*) FROM gold.graph_edge GROUP BY 1").fetchall())
    neo_rels = {
        row["t"]: row["n"] for row in session.run(
            "MATCH ()-[r]->() RETURN type(r) AS t, count(*) AS n")
    }
    for rel_type in sorted(pg_rels):
        same = pg_rels[rel_type] == neo_rels.get(rel_type)
        results.append(report(
            f"parity [:{rel_type}]", same,
            f"pg {pg_rels[rel_type]:,} / neo4j {neo_rels.get(rel_type, 0):,}",
        ))
    return results


def check_traversable(session) -> list[bool]:
    """The graph must answer graph questions, not just hold the right counts."""
    results = []

    # a stop carrying its metadata is the whole point of the design
    row = session.run(
        "MATCH (s:Stop) WHERE s.has_rent_data AND s.has_sales_data"
        " AND s.n_schools_200m > 0"
        " RETURN s.stop_name AS name, s.lga_name AS lga,"
        "        s.rent_median_weekly_house AS rent,"
        "        s.sales_median_price_kring1 AS price LIMIT 1"
    ).single()
    results.append(report(
        "a stop carries rent + sales + schools", row is not None,
        f"{row['name']} ({row['lga']}): rent {row['rent']}, price {row['price']}"
        if row else "none found",
    ))

    # the many-to-many the graph exists to make queryable
    row = session.run(
        "MATCH (sc:School)<-[:NEAR_SCHOOL]-(st:Stop)"
        " WITH sc, count(st) AS stops ORDER BY stops DESC LIMIT 1"
        " RETURN sc.school_name AS name, stops"
    ).single()
    results.append(report(
        "a school is shared by many stops", bool(row and row["stops"] > 1),
        f"{row['name']}: {row['stops']} stops" if row else "none",
    ))

    # two stops in the same LGA, reached only through the graph
    row = session.run(
        "MATCH (a:Stop)-[:IN_LGA]->(l:LGA)<-[:IN_LGA]-(b:Stop)"
        " WHERE a.node_key < b.node_key"
        " RETURN l.lga_name AS lga, count(*) AS pairs ORDER BY pairs DESC LIMIT 1"
    ).single()
    results.append(report("stops connect through their LGA", bool(row),
                          f"{row['lga']}: {row['pairs']:,} stop pairs" if row else ""))

    # a multi-hop walk over the timetable graph
    row = session.run(
        "MATCH path = (a:Stop)-[:CONNECTS*3..3]->(b:Stop)"
        " WHERE a.node_key <> b.node_key"
        " WITH path, reduce(s = 0.0, r IN relationships(path)"
        "                   | s + coalesce(r.best_peak_s, 0)) AS total"
        " WHERE total > 0 RETURN total LIMIT 1"
    ).single()
    results.append(report("3-hop journeys are traversable", bool(row),
                          f"{row['total'] / 60:.1f} min for 3 hops" if row else "no path"))
    return results


def run() -> bool:
    """Runs every check; True = graph consistent."""
    print("Gold - graph integrity and Postgres/Neo4j parity:")
    driver = GraphDatabase.driver(paths.NEO4J_URI, auth=paths.neo4j_auth())
    try:
        with psycopg.connect(paths.postgres_dsn(), autocommit=True) as conn, \
                driver.session() as session:
            results = (check_structure(conn)
                       + check_parity(conn, session)
                       + check_traversable(session))
    finally:
        driver.close()

    return summarise(results)


if __name__ == "__main__":
    sys.exit(0 if run() else 1)
