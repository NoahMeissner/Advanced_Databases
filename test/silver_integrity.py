# @Noah Meissner 9.10.2026
"""Test: the silver layer hangs together, and its proximity join is believable.

Two kinds of assertion live here rather than in the SQL check framework
(pipeline/silver/sql/checks):

  1. Structural invariants that are cheaper to express in Python - primary keys,
     foreign keys back to the spine, one-row-per-stop in the profile.

  2. The proximity ORACLE. The raw school CSV ships its own answer to the
     question this layer rebuilds: nearest_station_id, station_count_300m and
     station_match_status, computed by whoever produced the extract. Bronze
     deliberately drops those columns as derived data (see the `drop` tuple in
     pipeline/bronze/load.py), so the comparison has to read the file - which is
     exactly why it cannot be a SQL check. An independently produced answer is
     worth far more than any self-consistency test: if our 300 m join
     reproduces it, the 200 m join it shares its code path with is trustworthy.

Prerequisites: the databases are running (./start.sh) and the pipeline has
completed (python -m pipeline.run).

Run from the repository root:
    python -m test.silver_integrity

Exit code 0 = everything consistent, 1 = at least one check failed.
"""
import sys

import psycopg

import paths
from pipeline.bronze.load import SOURCES, to_snake_case

# How closely our recomputed 300 m match must agree with the source's own answer
ORACLE_MIN_AGREEMENT = 0.95


def report(label: str, ok: bool, detail: str = "") -> bool:
    """Prints one result line; returns ok so callers can collect it."""
    print(f"  {label:<44} {'OK' if ok else 'ERROR':<6} {detail}")
    return ok


def check_counts(conn) -> list[bool]:
    """Row counts that must match by construction."""
    results = []

    stops, profile = conn.execute(
        "SELECT (SELECT count(*) FROM silver.bus_stop),"
        "       (SELECT count(*) FROM silver.bus_stop_profile)"
    ).fetchone()
    results.append(report(
        "profile has one row per stop", stops == profile,
        f"{profile:,} profile / {stops:,} stops",
    ))

    edges, claimed, lineage, raw = conn.execute(
        "SELECT (SELECT count(*) FROM silver.bus_edge),"
        "       (SELECT coalesce(sum(n_source_rows), 0) FROM silver.bus_edge),"
        "       (SELECT count(*) FROM silver.bus_edge_source),"
        "       (SELECT count(*) FROM bronze.bus_graph_edges)"
    ).fetchone()
    results.append(report(
        "edge dedup reconciles", claimed == lineage == raw,
        f"{edges:,} logical edges cover {lineage:,} of {raw:,} raw features",
    ))

    return results


def check_referential_integrity(conn) -> list[bool]:
    """Everything that points at the spine must actually find it."""
    results = []
    for table, column in (
        ("silver.bus_stop_da", "stop_id"),
        ("silver.bus_stop_property_sales", "stop_id"),
        ("silver.bus_stop_school", "stop_id"),
        ("silver.bus_stop_school_summary", "stop_id"),
        ("silver.bus_stop_profile", "stop_id"),
    ):
        orphans = conn.execute(
            f"SELECT count(*) FROM {table} t WHERE NOT EXISTS ("
            f"  SELECT 1 FROM silver.bus_stop s WHERE s.stop_id = t.{column})"
        ).fetchone()[0]
        results.append(report(f"{table} -> bus_stop", orphans == 0,
                              f"{orphans:,} orphans"))

    bad_hex = conn.execute(
        "SELECT count(*) FROM silver.bus_stop s WHERE s.hex_id IS NOT NULL"
        " AND NOT EXISTS (SELECT 1 FROM silver.hex_300m h WHERE h.hex_id = s.hex_id)"
    ).fetchone()[0]
    results.append(report("stop hex ids resolve to the grid", bad_hex == 0,
                          f"{bad_hex:,} unknown"))
    return results


def read_school_oracle() -> dict[int, dict]:
    """The dropped station columns, read straight from the raw school CSV.

    Uses the loader's own reader and snake_case so this reads the file exactly
    as bronze does - the point is to compare answers, not parsers.
    """
    src = SOURCES["school_location"]
    frame = src.read(src.path)
    frame.columns = [to_snake_case(c) for c in frame.columns]
    oracle = {}
    for row in frame.itertuples(index=False):
        values = row._asdict()
        code = values.get("school_code")
        if not code:
            continue
        station = values.get("nearest_station_id") or ""
        oracle[int(code)] = {
            "count_300m": int(values["station_count_300m"] or 0),
            # the file prefixes the id, e.g. 'bus_stop_206430'
            "nearest_stop": station.replace("bus_stop_", "") or None,
            "status": values.get("station_match_status") or "",
        }
    return oracle


def check_proximity_oracle(conn) -> list[bool]:
    """Compares our 300 m join against the answer the source CSV ships."""
    results = []
    if not SOURCES["school_location"].path.exists():
        return [report("school proximity oracle", False, "raw CSV missing")]

    oracle = read_school_oracle()
    matched_in_file = sum(1 for v in oracle.values()
                          if v["status"] == "matched_within_300m")

    ours = dict(conn.execute(
        "SELECT school_code, count(*) FROM silver.bus_stop_school"
        " WHERE radius_m = 300 GROUP BY school_code"
    ).fetchall())
    results.append(report(
        "schools matched within 300 m", len(ours) == matched_in_file,
        f"ours {len(ours):,} / source says {matched_in_file:,}",
    ))

    agree = sum(1 for code, value in oracle.items()
                if ours.get(code, 0) == value["count_300m"])
    share = agree / len(oracle) if oracle else 0.0
    results.append(report(
        "station_count_300m agrees", share >= ORACLE_MIN_AGREEMENT,
        f"{share:.1%} of {len(oracle):,} schools",
    ))

    nearest = dict(conn.execute(
        "SELECT school_code, stop_id::text FROM silver.bus_stop_school"
        " WHERE radius_m = 300 AND rank_from_school = 1"
    ).fetchall())
    # The file publishes a nearest_station_id even when that station is FURTHER
    # than 300 m away (status 'no_supplied_station_within_300m', 1,337 schools).
    # Our 300 m table correctly has no row for those, so comparing against them
    # would measure the radius filter, not the ranking.
    comparable = {c: v for c, v in oracle.items()
                  if v["nearest_stop"] and v["status"] == "matched_within_300m"}
    same = sum(1 for code, value in comparable.items()
               if nearest.get(code) == value["nearest_stop"])
    share = same / len(comparable) if comparable else 0.0
    results.append(report(
        "nearest_station_id agrees", share >= ORACLE_MIN_AGREEMENT,
        f"{share:.1%} of {len(comparable):,} matched schools",
    ))
    return results


def run() -> bool:
    """Runs every check; True = all consistent."""
    print("Silver - integrity and the proximity oracle:")
    with psycopg.connect(paths.postgres_dsn(), autocommit=True) as conn:
        results = (check_counts(conn)
                   + check_referential_integrity(conn)
                   + check_proximity_oracle(conn))

    failed = results.count(False)
    if failed:
        print(f"\n{failed} of {len(results)} checks failed.")
    else:
        print(f"\nAll {len(results)} checks passed.")
    return failed == 0


if __name__ == "__main__":
    sys.exit(0 if run() else 1)
