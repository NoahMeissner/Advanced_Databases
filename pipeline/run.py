# @Noah Meissner 6.10.2026
"""Pipeline-Start: calls all layers step by step.

Start from here
    python -m pipeline.run                  every source and layer
    python -m pipeline.run rent_data        only one bronze source
    python -m pipeline.run stop_profile     only one silver step
    python -m pipeline.run graph_node       only one gold step
    python -m pipeline.run --skip-graph     everything except the Neo4j load

Names are matched against the bronze sources (pipeline/bronze/load.py SOURCES),
the silver steps (pipeline/silver/build.py STEPS) and the gold steps
(pipeline/gold/build.py STEPS), so one name can drive the layer it belongs to.

Prerequisites: the databases are running (./start.sh).

The run ends with the quality checks for silver AND gold in one dq_run, and
exits non-zero if any error-level check failed, so a broken load cannot pass
silently.
"""
import sys

from pipeline import quality
from pipeline.bronze import load as bronze
from pipeline.gold import build as gold
from pipeline.gold import graph
from pipeline.silver import build as silver


def main(selected: list[str] | None = None) -> int:
    """Loads the selected sources and steps (or all) through every layer.

    Returns the process exit code: 0 when the quality checks passed.
    """
    names = selected or []
    flags = [n for n in names if n.startswith("--")]
    skip_graph = "--skip-graph" in flags

    bronze_names = [n for n in names if n in bronze.SOURCES]
    silver_names = [n for n in names if n in silver.STEPS]
    gold_names = [n for n in names if n in gold.STEPS]

    unknown = (set(names) - set(bronze_names) - set(silver_names)
               - set(gold_names) - set(flags))
    if unknown:
        raise ValueError(
            f"Unknown name: {', '.join(sorted(unknown))}. "
            f"Bronze sources: {', '.join(bronze.SOURCES)}. "
            f"Silver steps: {', '.join(silver.STEPS)}. "
            f"Gold steps: {', '.join(gold.STEPS)}"
        )
    # a run naming only one layer should not rebuild the others
    layer_named = bool(bronze_names or silver_names or gold_names)
    reset = [f for f in flags if f == "--reset"]

    if bronze_names or not layer_named:
        print("Bronze - Raw data to Postgres:")
        bronze.run(bronze_names or None)

    if silver_names or not layer_named:
        print("\nSilver - typed, cleaned, mapped onto the bus stops:")
        silver.run((silver_names or []) + reset or None)

    if gold_names or not layer_named:
        print("\nGold - the graph and the comparison marts:")
        gold.run((gold_names or []) + reset or None)

        if not skip_graph:
            print()
            graph.load(do_reset=bool(reset))

    print()
    return 0 if quality.run() else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
