# @Noah Meissner 9.10.2026
"""Silver-Layer: typed, cleaned, quality-flagged tables built from bronze.

Bronze keeps every row exactly as the source delivered it. Silver is the first
layer anyone may trust, so each step here does three things:

  1. type and standardise (ISO dates, SI units, one project CRS)
  2. flag problems in flag_* columns instead of deleting rows
  3. reduce the source to a per-bus-stop measure, because the bus stops are the
     reference points all sources are joined on

Every step is one SQL file in pipeline/silver/sql, run in its own transaction
and in the order of STEPS - later steps read earlier ones, so the order is the
dependency graph.

Re-running is safe: entity tables upsert with ON CONFLICT, derived aggregates
delete-then-insert inside their transaction. Nothing is TRUNCATEd.

Start from the repo root:
    python -m pipeline.silver.build              all steps
    python -m pipeline.silver.build bus_stop     one step
    python -m pipeline.silver.build --reset      drop the silver schema first
"""
import sys
from typing import NamedTuple

import psycopg
from psycopg import sql

import paths


class Step(NamedTuple):
    """One silver step: which SQL file runs, and which table to count after."""
    sql_file: str
    table: str | None
    """Table whose row count is printed. None for steps that only set things up."""


STEPS = {
    "extensions":      Step("00_extensions.sql", None),
    "quality":         Step("01_quality.sql", None),
    "bus_stop":        Step("10_bus_stop.sql", "bus_stop"),
    "hex_300m":        Step("11_hex_300m.sql", "hex_300m"),
    "bus_edge":        Step("12_bus_edge.sql", "bus_edge"),
    "edge_travel_time": Step("13_bus_edge_travel_time.sql", "bus_edge_travel_time"),
    "school":          Step("20_school.sql", "school"),
    "stop_school":     Step("21_bus_stop_school.sql", "bus_stop_school"),
    "da_application":  Step("30_da_application.sql", "da_application"),
    "da_hex":          Step("31_da_hex_300m.sql", "da_hex_300m"),
    "stop_da":         Step("32_bus_stop_da.sql", "bus_stop_da"),
    "street":          Step("40_street_locality.sql", "street_locality"),
    "property_sale":   Step("41_property_sale.sql", "property_sale"),
    "sales_street":    Step("42_property_sales_street.sql", "property_sales_street"),
    "sales_hex":       Step("43_property_sales_hex_300m.sql", "property_sales_hex_300m"),
    "stop_sales":      Step("44_bus_stop_property_sales.sql", "bus_stop_property_sales"),
    "traffic_segment": Step("50_traffic_segment.sql", "traffic_segment"),
    "traffic_hourly":  Step("51_traffic_hourly.sql", "traffic_segment_hourly"),
    "traffic_daypart": Step("52_traffic_daypart.sql", "traffic_segment_daypart"),
    "stop_traffic":    Step("53_bus_stop_traffic.sql", "bus_stop_traffic"),
    "stop_profile":    Step("90_bus_stop_profile.sql", "bus_stop_profile"),
}


def count_rows(conn, table: str) -> int:
    """Row count of silver.<table>."""
    query = sql.SQL("SELECT count(*) FROM {}").format(sql.Identifier("silver", table))
    return conn.execute(query).fetchone()[0]


def run_step(conn, name: str) -> None:
    """Runs one step in its own transaction and prints what it produced."""
    step = STEPS[name]
    statements = (paths.SILVER_SQL_DIR / step.sql_file).read_text(encoding="utf-8")

    with conn.transaction():
        conn.execute(statements)

    if step.table is None:
        print(f"  silver.{name:<24} ok")
    else:
        print(f"  silver.{step.table:<24} {count_rows(conn, step.table):>10,} rows")


def reset(conn) -> None:
    """Drops the whole silver schema.

    Only for development and for changes to a table's shape: CREATE TABLE IF NOT
    EXISTS leaves an existing table alone, so a new column would otherwise never
    appear. Bronze is untouched, so a reset costs one silver rebuild, not a
    re-ingest.
    """
    print("  dropping schema silver ...")
    conn.execute("DROP SCHEMA IF EXISTS silver CASCADE")


def run(selected: list[str] | None = None) -> None:
    """Runs the selected steps (or all) in dependency order.

    Called by pipeline/run.py, but can also be called individually.
    """
    do_reset = bool(selected) and "--reset" in selected
    selected = [name for name in (selected or []) if not name.startswith("--")]

    unknown = [name for name in selected if name not in STEPS]
    if unknown:
        raise ValueError(
            f"Unknown step: {', '.join(unknown)}. Allowed: {', '.join(STEPS)}"
        )
    # dict order is the dependency order, so never trust the order given on the CLI
    order = [name for name in STEPS if not selected or name in selected]

    with psycopg.connect(paths.postgres_dsn(), autocommit=True) as conn:
        if do_reset:
            reset(conn)
        for name in order:
            run_step(conn, name)


if __name__ == "__main__":
    run(sys.argv[1:])
