# Noah Meissner 6.10.2026
"""All the project’s paths in one place.

Everything is relative to ROOT (= the folder containing this file, i.e. the repo root). This ensures
that the paths work on any computer, regardless of where the repo is located and from
where a script is run.
"""
import os
from pathlib import Path
from urllib.parse import quote_plus

ROOT = Path(__file__).resolve().parent

# --- Data ------------------------------------------------------------------
DATA_DIR = ROOT / "data"
RAW_DIR = DATA_DIR / "raw"

TRAFFIC_SEGMENT_HOURLY_CSV = RAW_DIR / "traffic_volume" / "traffic_segment_hourly.csv"
SCHOOL_LOCATION_CSV = RAW_DIR / "school_location" / "school_location.csv"
RENT_DATA_CSV = RAW_DIR / "rent_data" / "bronze_rent_data.csv"
PROPERTY_SALES_CSV = RAW_DIR / "property_sales" / "sales_current.csv"
DA_APPLICATIONS_CSV = RAW_DIR / "da_applications" / "nsw_da_greater_applications.csv"

BUS_STOPS_GEOJSON = RAW_DIR / "station_stops" / "sydney_bus_stops.geojson"
BUS_ROUTES_GEOJSON = RAW_DIR / "station_stops" / "sydney_bus_routes.geojson"
BUS_GRAPH_EDGES_GEOJSON = RAW_DIR / "gfts_historical" / "sydney_bus_graph_edges.geojson"

# --- Pipeline ---------------------------------------------------------------
PIPELINE_DIR = ROOT / "pipeline"
BRONZE_SQL_DIR = PIPELINE_DIR / "bronze" / "sql"
SILVER_SQL_DIR = PIPELINE_DIR / "silver" / "sql"
GOLD_SQL_DIR = PIPELINE_DIR / "gold" / "sql"

# --- Databases ------------------------------------------------------------
# Credentials are NOT in the code but in the .env in the repo root
# (template: .env.example, created by ./start.sh). The .env is in .gitignore.
ENV_FILE = ROOT / ".env"


def _load_env(path: Path = ENV_FILE) -> None:
    """Reads KEY=VALUE from the .env into os.environ.

    Already set environment variables win, so that e.g. CI or
    `POSTGRES_PASSWORD=... python -m pipeline.run` can override the file.
    """
    if not path.is_file():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        os.environ.setdefault(key, value)


def _require(key: str) -> str:
    value = os.environ.get(key)
    if not value:
        raise RuntimeError(
            f"{key} is missing. Please create a .env (cp .env.example .env) or "
            f"run ./start.sh - that creates a .env with random passwords."
        )
    return value


_load_env()

POSTGRES_DB = os.environ.get("POSTGRES_DB", "suburblens")
POSTGRES_USER = os.environ.get("POSTGRES_USER", "suburblens")
POSTGRES_HOST = os.environ.get("POSTGRES_HOST", "localhost")
POSTGRES_PORT = os.environ.get("POSTGRES_PORT", "5432")

NEO4J_HOST = os.environ.get("NEO4J_HOST", "localhost")
NEO4J_BOLT_PORT = os.environ.get("NEO4J_BOLT_PORT", "7687")
NEO4J_USER = os.environ.get("NEO4J_USER", "neo4j")

NEO4J_URI = f"bolt://{NEO4J_HOST}:{NEO4J_BOLT_PORT}"


def postgres_dsn() -> str:
    """Postgres connection string; the password is read from the .env only here."""
    password = quote_plus(_require("POSTGRES_PASSWORD"))
    user = quote_plus(POSTGRES_USER)
    return f"postgresql://{user}:{password}@{POSTGRES_HOST}:{POSTGRES_PORT}/{POSTGRES_DB}"


def neo4j_auth() -> tuple[str, str]:
    """(user, password) for the Neo4j driver."""
    return (NEO4J_USER, _require("NEO4J_PASSWORD"))
