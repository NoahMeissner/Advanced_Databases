# @Noah Meissner 6.10.2026
"""Bronze-Layer: Raw data from data/raw loaded unmodified to Postgres.

Supported are CSV (one row = one row) and GeoJSON (one row = one Feature).

For each source:
  1. Read file – everything as text, nothing is converted
  2. SQL-File calling (creates table if not exists)
  3. old rows of the file delete and new ones upload via COPY (one transaction)

Start from the repo root:
    python -m pipeline.bronze.load               all sources
    python -m pipeline.bronze.load rent_data     only one
"""
import json
import re
import sys
from pathlib import Path
from typing import Callable, NamedTuple
import pandas as pd
import psycopg
from psycopg import sql

import paths


class Source(NamedTuple):
    """A bronze source: which file lands via which SQL in which table."""
    sql_file: str
    table: str
    path: Path
    read: Callable[[Path], pd.DataFrame]
    drop: tuple[str, ...] = ()
    """Columns present in the file but deliberately not in the bronze table
    (snake_case, as after to_snake_case). Used for values that are derived
    rather than source data - those get built in silver instead."""


def load_csv_data(file_path: Path) -> pd.DataFrame:
    """Reads a CSV unmodified: each column as text, empty fields as ''."""
    return pd.read_csv(
        file_path,
        dtype=str,
        keep_default_na=False,
        encoding="utf-8-sig",
    )


def load_geojson_data(file_path: Path) -> pd.DataFrame:
    """Reads a GeoJSON-FeatureCollection: one Feature = one row.

    The columns are the keys from "properties" (lists/objects remain as JSON text
    standing, e.g., routes_served). Additionally, geometry_type and geometry are included – the
    geometry remains as a GeoJSON text to ensure lossless bronze storage.

    The file is read completely into memory (the largest is ~65 MB).
    """
    with file_path.open(encoding="utf-8") as fh:
        features = json.load(fh).get("features", [])

    rows = []
    for feature in features:
        geometry = feature.get("geometry") or {}
        row = {key: _as_text(value) for key, value in (feature.get("properties") or {}).items()}
        row["geometry_type"] = _as_text(geometry.get("type"))
        row["geometry"] = json.dumps(geometry, separators=(",", ":")) if geometry else ""
        rows.append(row)

    return pd.DataFrame(rows).fillna("")


def to_snake_case(name: str) -> str:
    """PlanningPortalApplicationNumber -> planning_portal_application_number,
    AccompaniedByVPAFlag -> accompanied_by_vpa_flag. Already-lowercase names stay as they are."""
    name = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1_\2", name.strip())   # VPAFlag -> VPA_Flag
    name = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", name)               # ByVPA   -> By_VPA
    return name.lower()


def _as_text(value) -> str:
    """Makes a value suitable for CSV/SQL: None -> '', lists/dicts/bools -> JSON, else str()."""
    if value is None:
        return ""
    if isinstance(value, (list, dict, bool)):
        return json.dumps(value, separators=(",", ":"), ensure_ascii=False)
    return str(value)


SOURCES = {
    "traffic_volume": Source("traffic_volume.sql", "traffic_segment_hourly",
                             paths.TRAFFIC_SEGMENT_HOURLY_CSV, load_csv_data),
    # The station_* columns are derived, not source data - silver builds them
    # from school_location + bus_stops. support_classes is empty in every row.
    "school_location": Source("school_location.sql", "school_location",
                              paths.SCHOOL_LOCATION_CSV, load_csv_data,
                              drop=("nearest_station_distance_m",
                                    "station_count_300m",
                                    "nearest_station_id",
                                    "station_match_status",
                                    "station_dataset",
                                    "support_classes")),
    # bedrooms is empty in every row of the source.
    "rent_data": Source("rent_data.sql", "rent_data",
                        paths.RENT_DATA_CSV, load_csv_data,
                        drop=("bedrooms",)),
    # load_to is the SCD2 end timestamp, empty in every row (all rows still open).
    "property_sales": Source("property_sales.sql", "property_sales",
                             paths.PROPERTY_SALES_CSV, load_csv_data,
                             drop=("load_to",)),
    "bus_stops": Source("station_stops.sql", "bus_stops",
                        paths.BUS_STOPS_GEOJSON, load_geojson_data),
    "bus_routes": Source("station_stops.sql", "bus_routes",
                         paths.BUS_ROUTES_GEOJSON, load_geojson_data),
    "bus_graph_edges": Source("gfts_historical.sql", "bus_graph_edges",
                              paths.BUS_GRAPH_EDGES_GEOJSON, load_geojson_data),
    "da_applications": Source("da_applications.sql", "da_applications",
                              paths.DA_APPLICATIONS_CSV, load_csv_data),
}


def write_to_bronze(conn, df: pd.DataFrame, sql_file: str, table: str, source: str) -> int:
    """Writes a DataFrame to bronze.<table>; returns the number of rows."""
    conn.execute((paths.BRONZE_SQL_DIR / sql_file).read_text(encoding="utf-8"))

    target = sql.Identifier("bronze", table)
    columns = sql.SQL(", ").join(
        sql.Identifier(c) for c in list(df.columns) + ["_source_file"]
    )
    copy_sql = sql.SQL("COPY {} ({}) FROM STDIN").format(target, columns)

    with conn.transaction():
        conn.execute(
            sql.SQL("DELETE FROM {} WHERE _source_file = %s").format(target), [source]
        )
        with conn.cursor().copy(copy_sql) as copy:
            for row in df.itertuples(index=False, name=None):
                values = [v if v != "" else None for v in row]   # '' -> NULL
                copy.write_row(values + [source])
    return len(df)


def run(selected: list[str] | None = None) -> None:
    """Loads the selected sources (or all) into the bronze layer.

    Called by pipeline/run.py, but can also be called individually.
    """
    selected = selected or list(SOURCES)
    unknown = [name for name in selected if name not in SOURCES]
    if unknown:
        raise ValueError(f"Unknown source: {', '.join(unknown)}. Allowed: {', '.join(SOURCES)}")

    with psycopg.connect(paths.postgres_dsn(), autocommit=True) as conn:
        for name in selected:
            src = SOURCES[name]
            source = src.path.relative_to(paths.DATA_DIR).as_posix()

            df = src.read(src.path)
            df.columns = [to_snake_case(c) for c in df.columns]
            df = df.drop(columns=list(src.drop), errors="ignore")
            rows = write_to_bronze(conn, df, src.sql_file, src.table, source)
            print(f"  bronze.{src.table:<25} {rows:>10,} rows  <- {source}")


if __name__ == "__main__":
    run(sys.argv[1:])
