# @Noah Meissner 6.10.2026
"""Pipeline-Start: calls all layers step by step.

Start from here
    python -m pipeline.run                  every source will be loaded
    python -m pipeline.run rent_data        only one source will be loaded
    python -m pipeline.run bus_stops bus_routes bus_graph_edges

The names of the bronze sources are in pipeline/bronze/load.py (SOURCES), the
silver steps in pipeline/silver/build.py (STEPS). Given names are matched
against both, so `python -m pipeline.run school_location school` runs that
source's bronze load and its silver step.

Prerequisites: the databases are running (./start.sh).

The run ends with the silver quality checks and exits non-zero if any
error-level check failed, so a broken load cannot pass silently.
"""
import sys

from pipeline.bronze import load as bronze
from pipeline.silver import build as silver
from pipeline.silver import quality


def main(selected: list[str] | None = None) -> int:
    """Loads the selected sources (or all) through every layer.

    Returns the process exit code: 0 when the quality checks passed.
    """
    names = selected or []
    bronze_names = [n for n in names if n in bronze.SOURCES]
    silver_names = [n for n in names if n in silver.STEPS or n.startswith("--")]

    unknown = set(names) - set(bronze_names) - set(silver_names)
    if unknown:
        raise ValueError(
            f"Unknown name: {', '.join(sorted(unknown))}. "
            f"Bronze sources: {', '.join(bronze.SOURCES)}. "
            f"Silver steps: {', '.join(silver.STEPS)}"
        )

    print("Bronze - Raw data to Postgres:")
    bronze.run(bronze_names or None)

    print("\nSilver - typed, cleaned, mapped onto the bus stops:")
    silver.run(silver_names or None)

    print()
    return 0 if quality.run() else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
