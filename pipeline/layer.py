# @Noah Meissner 9.10.2026
"""Shared runner for a SQL-file layer (silver, gold).

Both layers are the same machine: an ordered set of SQL files, each run in its
own transaction, each reporting what it produced. Only the schema, the SQL
directory and the step list differ, so that is all a layer has to declare.

The step order IS the dependency graph - later files read what earlier ones
wrote - so the order given on the command line is deliberately ignored.

Re-running is safe: entity tables upsert with ON CONFLICT, derived aggregates
delete-then-insert inside their transaction. Nothing is TRUNCATEd.
"""
from typing import NamedTuple

import psycopg
from psycopg import sql

import paths


class Step(NamedTuple):
    """One step of a layer: which SQL file runs, and which table to count after."""
    sql_file: str
    table: str | None
    """Table whose row count is printed. None for steps that only set things up."""


class Layer:
    """One medallion layer built from numbered SQL files."""

    def __init__(self, schema: str, sql_dir, steps: dict[str, Step]):
        self.schema = schema
        self.sql_dir = sql_dir
        self.steps = steps

    def count_rows(self, conn, table: str) -> int:
        """Row count of <schema>.<table>."""
        query = sql.SQL("SELECT count(*) FROM {}").format(
            sql.Identifier(self.schema, table)
        )
        return conn.execute(query).fetchone()[0]

    def run_step(self, conn, name: str) -> None:
        """Runs one step in its own transaction and prints what it produced."""
        step = self.steps[name]
        statements = (self.sql_dir / step.sql_file).read_text(encoding="utf-8")

        with conn.transaction():
            conn.execute(statements)

        prefix = f"  {self.schema}."
        if step.table is None:
            print(f"{prefix}{name:<26} ok")
        else:
            rows = self.count_rows(conn, step.table)
            print(f"{prefix}{step.table:<26} {rows:>10,} rows")

    def reset(self, conn) -> None:
        """Drops the whole schema.

        Needed after a change to a table's shape: CREATE TABLE IF NOT EXISTS
        leaves an existing table alone, so a new column would never appear.
        Only this layer is dropped, so a reset costs one rebuild.
        """
        print(f"  dropping schema {self.schema} ...")
        conn.execute(
            sql.SQL("DROP SCHEMA IF EXISTS {} CASCADE").format(
                sql.Identifier(self.schema)
            )
        )

    def run(self, selected: list[str] | None = None) -> None:
        """Runs the selected steps (or all) in dependency order."""
        do_reset = bool(selected) and "--reset" in selected
        chosen = [name for name in (selected or []) if not name.startswith("--")]

        unknown = [name for name in chosen if name not in self.steps]
        if unknown:
            raise ValueError(
                f"Unknown step: {', '.join(unknown)}. "
                f"Allowed: {', '.join(self.steps)}"
            )
        order = [name for name in self.steps if not chosen or name in chosen]

        with psycopg.connect(paths.postgres_dsn(), autocommit=True) as conn:
            if do_reset:
                self.reset(conn)
            for name in order:
                self.run_step(conn, name)
