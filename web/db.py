# @Noah Meissner 9.10.2026
"""Database access for the website.

Postgres only. The site used to open a Neo4j driver as well, for the GDS
isochrone, but that search now runs as a bounded recursive CTE over
gold.connects_edge (see web/isochrone.py for why), so nothing here needs a
graph connection. Neo4j is still built and checked by the pipeline -
pipeline/gold/graph.py owns that.

One short-lived connection per call is fine for three screens; the DSN comes
from paths.py so the site never reads config itself.
"""
from contextlib import contextmanager

import psycopg

import paths

POINT_M = "ST_Transform(ST_SetSRID(ST_MakePoint(%s, %s), 4326), 7856)"
"""A lon/lat parameter pair projected into EPSG:7856, the CRS every distance
in this project is measured in. Interpolated into queries rather than repeated,
because getting the argument order backwards (it is longitude FIRST) puts the
address in the wrong hemisphere and nothing complains."""


@contextmanager
def postgres():
    """A read-only Postgres connection for one request."""
    with psycopg.connect(paths.postgres_dsn(), autocommit=True) as conn:
        yield conn
