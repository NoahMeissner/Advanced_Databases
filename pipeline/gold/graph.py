# @Noah Meissner 9.10.2026
"""Pushes the gold graph tables into Neo4j.

gold.graph_node and gold.graph_edge are the contract: built and checked in SQL,
then projected here into Neo4j so the graph can be queried with Cypher and run
through GDS. Keeping the projection in its own module means gold still builds
when Neo4j is down, and the graph can be reloaded without rebuilding the SQL.

Idempotent by MERGE: a re-run converges on the same graph instead of
duplicating it, so this is safe to run as often as the rest of the pipeline.

Start from the repo root:
    python -m pipeline.gold.graph             load (merge) the graph
    python -m pipeline.gold.graph --reset     delete the graph first
"""
import sys

import psycopg
from neo4j import GraphDatabase

import paths

BATCH_SIZE = 5_000
"""Rows per Cypher call. Large enough to keep round-trips down, small enough
that a transaction stays well inside the container's 1 GB heap."""

NODE_LABELS = ("Stop", "School", "LGA", "Route")

REL_TYPES = (
    # (rel_type, from_label, to_label)
    ("ROUTE_SEGMENT", "Stop", "Stop"),
    ("CONNECTS", "Stop", "Stop"),
    ("NEAR_SCHOOL", "Stop", "School"),
    ("IN_LGA", "Stop", "LGA"),
    ("IN_LGA", "School", "LGA"),
    ("SERVES", "Route", "Stop"),
)


def batched(rows: list, size: int = BATCH_SIZE):
    """Yields rows in chunks of `size`."""
    for start in range(0, len(rows), size):
        yield rows[start:start + size]


def create_constraints(session) -> None:
    """One uniqueness constraint per label.

    This is both the integrity guarantee and the index: every MERGE below
    matches on the key, and without a backing index each MERGE would scan all
    nodes of that label.
    """
    for label in NODE_LABELS:
        session.run(
            f"CREATE CONSTRAINT {label.lower()}_key IF NOT EXISTS "
            f"FOR (n:{label}) REQUIRE n.node_key IS UNIQUE"
        )


def reset(session) -> None:
    """Deletes the whole graph in batches, to keep each transaction's heap use bounded."""
    print("  deleting existing graph ...")
    while True:
        summary = session.run(
            "MATCH (n) WITH n LIMIT $limit DETACH DELETE n RETURN count(*) AS n",
            limit=BATCH_SIZE,
        ).single()
        if not summary or summary["n"] == 0:
            return


def fetch_nodes(conn, label: str) -> list[dict]:
    """Nodes of one label, as {key, props} rows ready for UNWIND."""
    rows = conn.execute(
        "SELECT node_key, properties, ST_Y(geom), ST_X(geom)"
        " FROM gold.graph_node WHERE label = %s",
        [label],
    ).fetchall()
    out = []
    for node_key, properties, lat, lon in rows:
        props = dict(properties or {})
        if lat is not None:
            props["latitude"] = lat
            props["longitude"] = lon
        out.append({"key": node_key, "props": props})
    return out


def fetch_edges(conn, rel_type: str, from_label: str, to_label: str) -> list[dict]:
    """Relationships of one type between one pair of labels."""
    rows = conn.execute(
        "SELECT from_key, to_key, edge_key, properties FROM gold.graph_edge"
        " WHERE rel_type = %s AND from_label = %s AND to_label = %s",
        [rel_type, from_label, to_label],
    ).fetchall()
    return [
        {"from": from_key, "to": to_key, "key": edge_key, "props": dict(props or {})}
        for from_key, to_key, edge_key, props in rows
    ]


def load_nodes(session, label: str, rows: list[dict]) -> None:
    """MERGEs one label's nodes in batches."""
    query = (
        "UNWIND $rows AS row "
        f"MERGE (n:{label} {{node_key: row.key}}) "
        "SET n += row.props"
    )
    for batch in batched(rows):
        session.run(query, rows=batch)
    print(f"  (:{label}){'':<{max(0, 16 - len(label))}} {len(rows):>10,} nodes")


def load_edges(session, rel_type: str, from_label: str, to_label: str,
               rows: list[dict]) -> None:
    """MERGEs one relationship type in batches.

    edge_key is part of the MERGE pattern so parallel relationships survive:
    up to 21 routes run between the same two stops, and each is its own
    ROUTE_SEGMENT rather than overwriting the last.
    """
    query = (
        "UNWIND $rows AS row "
        f"MATCH (a:{from_label} {{node_key: row.from}}) "
        f"MATCH (b:{to_label} {{node_key: row.to}}) "
        f"MERGE (a)-[r:{rel_type} {{edge_key: row.key}}]->(b) "
        "SET r += row.props"
    )
    for batch in batched(rows):
        session.run(query, rows=batch)
    label = f"[:{rel_type}] {from_label}->{to_label}"
    print(f"  {label:<34} {len(rows):>10,} rels")


def load(do_reset: bool = False) -> None:
    """Projects gold.graph_node / gold.graph_edge into Neo4j."""
    print("Gold - projecting the graph into Neo4j:")
    driver = GraphDatabase.driver(paths.NEO4J_URI, auth=paths.neo4j_auth())
    try:
        driver.verify_connectivity()
        with driver.session() as session, \
                psycopg.connect(paths.postgres_dsn(), autocommit=True) as conn:
            if do_reset:
                reset(session)
            create_constraints(session)

            for label in NODE_LABELS:
                load_nodes(session, label, fetch_nodes(conn, label))
            # edges only after every node exists, or the MATCH finds nothing
            for rel_type, from_label, to_label in REL_TYPES:
                load_edges(session, rel_type, from_label, to_label,
                           fetch_edges(conn, rel_type, from_label, to_label))
    finally:
        driver.close()


if __name__ == "__main__":
    load("--reset" in sys.argv[1:])
