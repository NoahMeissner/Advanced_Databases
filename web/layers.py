# @Noah Meissner 9.10.2026
"""GeoJSON for the four map layers.

One function per toggle in the design's sidebar. Each returns a
FeatureCollection the browser can hand straight to Leaflet, so the client holds
no query logic - it only decides what is visible.

Layer colours come from the design tokens and are applied in map.js; the
properties here carry only the data the layer needs (the number shown on a
school marker, the activity band, the price direction).
"""
import json

from web.db import POINT_M, postgres
from web.isochrone import reach_polygon
from web.report import PIPELINE_STATUSES, Report

DEVELOPMENT_RADIUS_M = 1000
DETERMINED_MIN_COST = 1_000_000
"""Within 1 km of a city address there are ~1,878 applications, of which only
~57 are still in the pipeline. Plotting all of them would be unreadable, so the
determined ones are filtered to those over $1m - about 300 - which keeps the
map legible while still showing where building has already happened."""

PRICE_RADIUS_M = 1500
ACTIVITY_MAP_RADIUS_M = 1000
"""Wider than the report's 300 m figure: the report answers "outside this
address", the map wants enough context to see where the corridors run."""


def _collection(features: list[dict]) -> dict:
    """Wraps features as a GeoJSON FeatureCollection."""
    return {"type": "FeatureCollection", "features": features}


def schools(report: Report) -> dict:
    """Numbered school markers, matching the report's list order."""
    if not report.schools:
        return _collection([])

    codes = [s.school_code for s in report.schools]
    ranks = {s.school_code: s.rank for s in report.schools}
    with postgres() as conn:
        rows = conn.execute(
            "SELECT school_code, school_name, level_of_schooling,"
            "       ST_AsGeoJSON(geom)::jsonb"
            "  FROM silver.school WHERE school_code = ANY(%s)",
            [codes],
        ).fetchall()

    return _collection([
        {
            "type": "Feature",
            "geometry": geometry,
            "properties": {
                "rank": ranks[code],
                "name": name,
                "level": level,
                "distance_m": next(s.distance_m for s in report.schools
                                   if s.school_code == code),
            },
        }
        for code, name, level, geometry in rows
    ])


def activity(report: Report) -> dict:
    """Bus-traffic bands along the segments near the address.

    flag_long_segment rows are excluded: a 27 km express hop is real data but
    drawn as a street band it would streak across the city.
    """
    with postgres() as conn:
        rows = conn.execute(
            f"""
            SELECT ST_AsGeoJSON(t.geom)::jsonb, t.trips_per_day,
                   t.activity_band, t.n_routes, t.route_short_names
              FROM gold.transit_segment t
             WHERE NOT t.flag_long_segment
               AND ST_DWithin(t.geom_m, {POINT_M}, %s)
             ORDER BY t.activity_band
            """,
            [report.address.longitude, report.address.latitude,
             ACTIVITY_MAP_RADIUS_M],
        ).fetchall()

    return _collection([
        {
            "type": "Feature",
            "geometry": geometry,
            "properties": {"trips_per_day": trips, "band": band,
                           "n_routes": n_routes,
                           "routes": list(routes or [])[:6]},
        }
        for geometry, trips, band, n_routes, routes in rows
    ])


def reach(report: Report) -> dict:
    """The reachable area for the report's chosen time of day.

    The stop ids already come from a multi-source, band-aware search, so this
    only has to hull them - and the polygon therefore changes when the hour
    changes, which is the point.
    """
    polygon = reach_polygon(report.commute.stop_ids)
    if polygon is None:
        return _collection([])
    return _collection([{
        "type": "Feature",
        "geometry": json.loads(polygon),
        "properties": {
            "minutes": report.commute.reach_minutes,
            "n_stops": report.commute.n_stops_reachable,
            "n_seed_stops": report.commute.n_seed_stops,
            "band": report.commute.time_of_day.band,
            "at": report.commute.time_of_day.clock,
        },
    }])


def development(report: Report) -> dict:
    """Development applications near the address, split by how settled they are.

    Two tiers, matching the report's investment section exactly:

      pipeline    still moving - under assessment, awaiting information,
                  deferred. This is the forward-looking half, drawn solid.
      determined  already decided, and over $1m so the map stays readable.
                  Drawn faint: the source has no completion date, so a
                  determined application means "approved at some point", NOT
                  "built", and the popup says so.

    Marker size scales with cost on a square-root scale - a $200m tower should
    read as bigger than a $2m renovation without swallowing the whole block.
    """
    with postgres() as conn:
        rows = conn.execute(
            f"""
            SELECT ST_AsGeoJSON(d.geom)::jsonb,
                   d.application_status,
                   CASE WHEN d.application_status = ANY(%s)
                        THEN 'pipeline' ELSE 'determined' END AS tier,
                   d.cost_of_development,
                   d.number_of_new_dwellings,
                   d.full_address,
                   d.lodgement_date,
                   round(ST_Distance(d.geom_m, {POINT_M})) AS distance_m
              FROM silver.da_application d
             WHERE d.is_usable
               AND NOT d.flag_cost_outlier
               AND ST_DWithin(d.geom_m, {POINT_M}, %s)
               AND (d.application_status = ANY(%s)
                    OR (d.application_status = 'Determined'
                        AND d.cost_of_development >= %s))
             -- determined first so the pipeline markers draw on top
             ORDER BY (d.application_status = ANY(%s)), d.cost_of_development
            """,
            [list(PIPELINE_STATUSES),
             report.address.longitude, report.address.latitude,
             report.address.longitude, report.address.latitude,
             DEVELOPMENT_RADIUS_M,
             list(PIPELINE_STATUSES), DETERMINED_MIN_COST,
             list(PIPELINE_STATUSES)],
        ).fetchall()

    return _collection([
        {
            "type": "Feature",
            "geometry": geometry,
            "properties": {
                "status": status,
                "tier": tier,
                "cost": int(cost) if cost is not None else None,
                "dwellings": int(dwellings) if dwellings is not None else None,
                "address": address,
                "lodged": lodged.isoformat() if lodged else None,
                "distance_m": int(distance),
            },
        }
        for geometry, status, tier, cost, dwellings, address, lodged, distance in rows
    ])


def prices(report: Report) -> dict:
    """300 m hexagons shaded by their five-year price direction.

    The design asks for prices by street, but this project never ingested street
    centrelines - only street centre points. The hexagon grid is real polygon
    geometry with real medians, so it carries the same meaning without
    pretending a point is a street.
    """
    with postgres() as conn:
        rows = conn.execute(
            f"""
            WITH nearby AS (
                SELECT h.hex_id, ST_AsGeoJSON(h.geom)::jsonb AS geometry
                  FROM silver.hex_300m h
                 WHERE ST_DWithin(h.centroid_m, {POINT_M}, %s)
            ), latest AS (
                SELECT hex_id,
                       max(period) FILTER (WHERE period <> 'all') AS to_period
                  FROM silver.property_sales_hex_300m
                 WHERE property_type = 'all' AND period <> 'all'
                   AND hex_id IN (SELECT hex_id FROM nearby)
                 GROUP BY hex_id
            )
            SELECT n.hex_id, n.geometry, a.median_price, a.n_sales,
                   l.to_period::integer AS to_year, e.median_price AS from_price,
                   e.period::integer AS from_year
              FROM nearby n
              JOIN latest l USING (hex_id)
              JOIN silver.property_sales_hex_300m a
                ON a.hex_id = n.hex_id AND a.property_type = 'all'
               AND a.period = l.to_period
              LEFT JOIN silver.property_sales_hex_300m e
                ON e.hex_id = n.hex_id AND e.property_type = 'all'
               AND e.period = (l.to_period::integer - 5)::text
             WHERE a.n_sales >= 3
            """,
            [report.address.longitude, report.address.latitude, PRICE_RADIUS_M],
        ).fetchall()

    features = []
    for hex_id, geometry, median, n_sales, to_year, from_price, from_year in rows:
        change = None
        if from_price and median:
            change = round(100.0 * (float(median) - float(from_price))
                           / float(from_price), 1)
        features.append({
            "type": "Feature",
            "geometry": geometry,
            "properties": {
                "hex_id": hex_id,
                "median_price": int(median) if median is not None else None,
                "n_sales": n_sales,
                "change_pct": change,
                "from_year": from_year,
                "to_year": to_year,
                "is_address_hex": hex_id == report.address.hex_id,
            },
        })
    return _collection(features)


LAYERS = {
    "schools": schools,
    "activity": activity,
    "reach": reach,
    "prices": prices,
    "development": development,
}
"""Name -> builder. app.py exposes exactly these at /api/layers/<name>, so a
typo in the URL is a 404 rather than an empty map."""
