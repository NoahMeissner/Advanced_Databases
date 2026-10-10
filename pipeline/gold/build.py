# @Noah Meissner 9.10.2026
"""Gold-Layer: the serving layer - one graph, plus the comparison marts.

Gold reads silver only, never bronze (the team contract). Anything built from
two or more sources belongs here, which is why the graph and the cross-LGA
comparison live in gold while per-source cleaning stayed in silver.

The SQL builds the graph as two tables in Postgres (gold.graph_node /
gold.graph_edge). pipeline/gold/graph.py then pushes those into Neo4j. Keeping
them separate means the graph is checkable in SQL and still builds when Neo4j
is down.

The step order is the dependency graph; the mechanics live in pipeline/layer.py.

Start from the repo root:
    python -m pipeline.gold.build              all steps
    python -m pipeline.gold.build graph_node   one step
    python -m pipeline.gold.build --reset      drop the gold schema first
"""
import sys

import paths
from pipeline.layer import Layer, Step

STEPS = {

    "schema":          Step("00_schema.sql", None),
    "lga_comparison":  Step("10_lga_comparison.sql", "lga_comparison"),
    "traffic_ranking": Step("11_traffic_ranking.sql", "traffic_ranking"),
    "suburb_comparison": Step("12_suburb_comparison.sql", "suburb_comparison"),
    # graph_node reads gold.lga_comparison for the LGA node properties, so the
    # marts have to be built first.
    "graph_node":      Step("20_graph_node.sql", "graph_node"),
    "graph_edge":      Step("21_graph_edge.sql", "graph_edge"),
    # the relational routing table the website's reach search uses
    "connects_edge":   Step("22_connects_edge.sql", "connects_edge"),
    # serving tables for the website: the geocoder and the activity layer
    "address_point":   Step("30_address_point.sql", "address_point"),
    "transit_segment": Step("31_transit_segment.sql", "transit_segment"),
}

_LAYER = Layer("gold", paths.GOLD_SQL_DIR, STEPS)


def run(selected: list[str] | None = None) -> None:
    """Runs the selected steps (or all) in dependency order."""
    _LAYER.run(selected)


if __name__ == "__main__":
    run(sys.argv[1:])
