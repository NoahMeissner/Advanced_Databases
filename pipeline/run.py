# @Noah Meissner 6.10.2026
"""Pipeline-Start: calls all layers step by step.

Start from here
    python -m pipeline.run                  every source will be loaded
    python -m pipeline.run rent_data        only one source will be loaded
    python -m pipeline.run bus_stops bus_routes bus_graph_edges

Prerequisites: the databases are running (./start.sh).
The names of the sources are in pipeline/bronze/load.py (SOURCES).
"""
import sys

from pipeline.bronze import load as bronze


def main(selected: list[str] | None = None) -> None:
    """Loads the selected sources (or all) through the pipeline."""
    print("Bronze – Raw data to Postgres:")
    bronze.run(selected)


if __name__ == "__main__":
    main(sys.argv[1:])
