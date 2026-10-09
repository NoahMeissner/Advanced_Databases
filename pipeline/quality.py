# @Noah Meissner 9.10.2026
"""Runs the Bronze -> Silver quality checks and records the outcome.

Each file in pipeline/silver/sql/checks returns check rows in one fixed shape
(see that folder's README). This module runs them all against one dq_run,
writes the results, prints them, and exits non-zero if any check marked
'error' failed - so `python -m pipeline.run` and CI can gate on data quality
rather than only on whether the SQL executed.

A failing check never deletes data. Rows that break an error-level rule keep a
flag_* column on their entity table and are excluded from aggregates by
is_usable, so count(silver) + count(rejects) still reconciles with bronze.

Start from the repo root:
    python -m pipeline.silver.quality
"""
import subprocess
import sys

import psycopg
from psycopg.types.json import Jsonb

import paths

CHECK_COLUMNS = (
    "table_name", "check_name", "dimension", "severity",
    "failed_rows", "total_rows", "threshold", "detail",
)

# The results table lives in silver, so one run covers both layers.
LAYER_CHECK_DIRS = {
    "silver": paths.SILVER_SQL_DIR / "checks",
    "gold": paths.GOLD_SQL_DIR / "checks",
}


def git_revision() -> str | None:
    """Short commit hash, so a result set can be traced back to the code."""
    try:
        done = subprocess.run(
            ["git", "-C", str(paths.ROOT), "rev-parse", "--short", "HEAD"],
            capture_output=True, text=True, check=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    return done.stdout.strip() or None


def check_files(layers: list[str] | None = None) -> list:
    """The check SQL files for the given layers, layer then filename order."""
    chosen = layers or list(LAYER_CHECK_DIRS)
    unknown = [name for name in chosen if name not in LAYER_CHECK_DIRS]
    if unknown:
        raise ValueError(
            f"Unknown layer: {', '.join(unknown)}. "
            f"Allowed: {', '.join(LAYER_CHECK_DIRS)}"
        )
    files = []
    for name in chosen:
        directory = LAYER_CHECK_DIRS[name]
        if directory.is_dir():
            files.extend(sorted(directory.glob("*.sql")))
    return files


def passed(failed_rows: int, total_rows: int, threshold) -> bool:
    """A check passes if the failing share stays within its threshold.

    threshold is a fraction; None means zero tolerance. A threshold is how a
    known, accepted data defect (half the schools are outside the study area)
    is recorded without failing the run every time.
    """
    if threshold is None:
        return failed_rows == 0
    if total_rows == 0:
        return failed_rows == 0
    return (failed_rows / total_rows) <= float(threshold)


def start_run(conn) -> int:
    """Opens a dq_run and returns its id."""
    return conn.execute(
        "INSERT INTO silver.dq_run (git_rev) VALUES (%s) RETURNING run_id",
        [git_revision()],
    ).fetchone()[0]


def run_checks(conn, run_id: int, layers: list[str] | None = None) -> list[tuple]:
    """Runs every check file and stores the results; returns the rows."""
    results = []
    for path in check_files(layers):
        for row in conn.execute(path.read_text(encoding="utf-8")).fetchall():
            table, name, dimension, severity, failed, total, threshold, detail = row
            ok = passed(failed, total, threshold)
            conn.execute(
                "INSERT INTO silver.dq_result (run_id, table_name, check_name,"
                " dimension, severity, failed_rows, total_rows, threshold,"
                " passed, detail) VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)"
                " ON CONFLICT (run_id, table_name, check_name) DO NOTHING",
                [run_id, table, name, dimension, severity, failed, total,
                 threshold, ok,
                 # psycopg hands jsonb back as a dict; it needs wrapping to go
                 # back in as jsonb rather than being rejected as unadaptable
                 None if detail is None else Jsonb(detail)],
            )
            results.append((table, name, dimension, severity, failed, total, ok, detail))
    return results


def finish_run(conn, run_id: int, results: list[tuple]) -> None:
    """Closes the dq_run with its summary."""
    failed = [r for r in results if not r[6]]
    errors = [r for r in failed if r[3] == "error"]
    conn.execute(
        "UPDATE silver.dq_run SET finished_at = now(), n_checks = %s,"
        " n_failed = %s, passed = %s WHERE run_id = %s",
        [len(results), len(failed), not errors, run_id],
    )


def report(results: list[tuple]) -> None:
    """Prints one line per check, failures last so they are the final thing read."""
    for table, name, _dim, severity, failed, total, ok, detail in sorted(
        results, key=lambda r: (r[6], r[3] != "error")
    ):
        status = "ok  " if ok else ("FAIL" if severity == "error" else "warn")
        share = f"{failed:,}/{total:,}" if total else f"{failed:,}"
        line = f"  {status}  {table + '.' + name:<58} {share:>18}"
        if not ok and detail:
            line += f"  {detail}"
        print(line)


def run(layers: list[str] | None = None) -> bool:
    """Runs all checks for the given layers; True = no error-level check failed."""
    print(f"Data quality ({', '.join(layers or LAYER_CHECK_DIRS)}):")
    with psycopg.connect(paths.postgres_dsn(), autocommit=True) as conn:
        run_id = start_run(conn)
        results = run_checks(conn, run_id, layers)
        finish_run(conn, run_id, results)

    report(results)
    errors = [r for r in results if not r[6] and r[3] == "error"]
    warns = [r for r in results if not r[6] and r[3] == "warn"]
    print(f"\n  {len(results)} checks, {len(errors)} failed, {len(warns)} warnings"
          f"  (run {run_id})")
    return not errors


if __name__ == "__main__":
    sys.exit(0 if run(sys.argv[1:] or None) else 1)
