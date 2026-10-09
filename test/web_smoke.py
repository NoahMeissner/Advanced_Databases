# @Noah Meissner 9.10.2026
"""Test: the website serves, and it serves the warehouse's own numbers.

Two things are checked, and the second is the one that matters:

  1. Every route answers, every layer is valid GeoJSON, and the geocoder's two
     tiers behave - an exact address resolves exactly, an invented house number
     falls back to its street, nonsense resolves to nothing rather than to a
     pin in the wrong suburb.

  2. The report AGREES WITH SQL. A page that renders beautifully while showing
     a number the database disagrees with is the one failure this whole stack
     cannot catch any other way, so the nearest-school distance, the sale count
     and the median price are recomputed straight from silver and compared.

Runs the Flask app in-process with its test client, so no server has to be
started first. The databases do have to be up (./start.sh) and the pipeline
must have completed (python -m pipeline.run).

Run from the repository root:
    python -m test.web_smoke

Exit code 0 = everything consistent, 1 = at least one check failed.
"""
import json
import sys

from test.report import report, summarise

import paths
from web.app import app
from web.db import POINT_M, postgres
from web.geocode import resolve
from web.isochrone import reach
from web.layers import DEVELOPMENT_RADIUS_M
from web.report import (PIPELINE_STATUSES, WALK_RADIUS_M, _hex_ring,
                        get_report)

SAMPLE_ADDRESS = "59 ENMORE ROAD NEWTOWN 2042"
"""A real address from the data: it has a development application, so it
exercises the exact-match tier."""

INVENTED_NUMBER = "99999 ENMORE ROAD NEWTOWN"
NONSENSE = "qqzzxx not a street anywhere"

ULTIMO = "HARRIS STREET ULTIMO"
"""The address that exposed the reachability bug: its nearest stop is 16 m away
and serves ONE route, while 28 stops within 800 m serve 41 between them."""

MIN_ULTIMO_REACH = 200
"""Before the multi-source fix this address reached 28 stops. Anything near
that number means the search has regressed to seeding from one stop."""


def check_routes(client) -> list[bool]:
    """Every screen and endpoint answers as expected."""
    results = []
    encoded = SAMPLE_ADDRESS.replace(" ", "%20")

    for label, path, expected in (
        ("GET /", "/", 200),
        ("GET /report", f"/report?address={encoded}", 200),
        ("GET /map", f"/map?address={encoded}", 200),
        ("GET /api/report", f"/api/report?address={encoded}", 200),
        ("GET /report (no address)", "/report", 302),
        ("GET /report (nonsense)", f"/report?address={NONSENSE}", 404),
        ("GET /api/layers/nope", f"/api/layers/nope?address={encoded}", 404),
    ):
        status = client.get(path).status_code
        results.append(report(label, status == expected,
                              f"{status}, expected {expected}"))
    return results


def check_layers(client) -> list[bool]:
    """Each map layer returns a well-formed FeatureCollection."""
    results = []
    encoded = SAMPLE_ADDRESS.replace(" ", "%20")
    for name in ("schools", "activity", "reach", "prices", "development"):
        response = client.get(f"/api/layers/{name}?address={encoded}")
        data = json.loads(response.data) if response.status_code == 200 else {}
        ok = (data.get("type") == "FeatureCollection"
              and isinstance(data.get("features"), list)
              and all("geometry" in f and "properties" in f
                      for f in data["features"]))
        results.append(report(f"layer {name}", ok,
                              f"{len(data.get('features', []))} features"))
    return results


def check_geocoder(client) -> list[bool]:
    """The two tiers behave, and a hopeless query returns nothing."""
    results = []

    exact = resolve(SAMPLE_ADDRESS)
    results.append(report(
        "exact address resolves exactly",
        exact is not None and exact.precision == "address" and exact.accuracy_m == 0,
        f"{exact.precision if exact else 'none'}",
    ))

    fallback = resolve(INVENTED_NUMBER)
    results.append(report(
        "invented number falls back to its street",
        fallback is not None and fallback.accuracy_m > 0,
        f"{fallback.precision if fallback else 'none'}, "
        f"±{fallback.accuracy_m if fallback else 0:.0f} m",
    ))

    results.append(report("nonsense resolves to nothing",
                          resolve(NONSENSE) is None))

    rows = json.loads(client.get("/api/suggest?q=enmore+road+newtown").data)
    results.append(report("autocomplete returns ranked rows",
                          len(rows) > 0 and "primary" in rows[0],
                          f"{len(rows)} suggestions"))
    results.append(report("autocomplete ignores a 2-character query",
                          json.loads(client.get("/api/suggest?q=en").data) == []))
    return results


def check_reachability() -> list[bool]:
    """The bug that started this: reach must start from every nearby stop.

    Seeding from the single nearest stop gave 28 reachable stops for Ultimo;
    seeding from all 28 stops in walking distance gives ~286. These assertions
    fail loudly if that ever regresses.
    """
    results = []
    address = resolve(ULTIMO)
    found = reach(address.latitude, address.longitude, 20, "offpeak")

    results.append(report("reach seeds from many stops, not one",
                          found.n_seed_stops > 1,
                          f"{found.n_seed_stops} seed stops, "
                          f"{found.n_routes_available} routes"))
    results.append(report("reach covers the real network",
                          found.n_stops_reachable > MIN_ULTIMO_REACH,
                          f"{found.n_stops_reachable} stops "
                          f"(was 28 before the fix)"))
    results.append(report("Central is reachable from Ultimo",
                          found.minutes_to_central is not None,
                          f"{found.minutes_to_central} min"))

    peak = reach(address.latitude, address.longitude, 20, "peak")
    results.append(report(
        "time of day changes the reachable area",
        peak.n_stops_reachable != found.n_stops_reachable,
        f"peak {peak.n_stops_reachable} vs offpeak {found.n_stops_reachable}",
    ))
    return results


def check_rankings_and_investment() -> list[bool]:
    """Ranks and investment must agree with the warehouse."""
    results = []
    built = get_report(ULTIMO, 8)
    ranks = built.rankings

    results.append(report("the suburb is ranked", ranks is not None,
                          ranks.locality if ranks else "none"))
    if ranks is None:
        return results

    with postgres() as conn:
        expected = conn.execute(
            """
            WITH s AS (
                SELECT locality,
                       percentile_cont(0.5) WITHIN GROUP (ORDER BY purchase_price) med
                  FROM silver.property_sale
                 WHERE is_usable AND locality IS NOT NULL
                 GROUP BY 1 HAVING count(*) >= 30
            )
            SELECT rk, total FROM (
                SELECT locality, rank() OVER (ORDER BY med DESC) rk,
                       count(*) OVER () total FROM s) r
             WHERE locality = %s
            """,
            [ranks.locality],
        ).fetchone()
        # the same neighbourhood helper the report uses, so this cannot drift
        ring = _hex_ring(conn, built.address.hex_id)
        pipeline, determined = conn.execute(
            """
            SELECT count(*) FILTER (WHERE application_status = ANY(%s)),
                   count(*) FILTER (WHERE application_status = 'Determined')
              FROM silver.da_application
             WHERE is_usable AND NOT flag_cost_outlier AND hex_id = ANY(%s)
            """,
            [list(PIPELINE_STATUSES), ring],
        ).fetchone()

    results.append(report(
        "suburb price rank matches SQL",
        (ranks.price.rank, ranks.price.n_ranked) == (expected[0], expected[1]),
        f"report {ranks.price.summary} vs sql {expected[0]} of {expected[1]}",
    ))
    results.append(report(
        "price-per-m2 rank is published too",
        ranks.price_per_m2.known,
        f"{ranks.price.ordinal} by price vs "
        f"{ranks.price_per_m2.ordinal} per m2 - composition, not value",
    ))
    results.append(report("rent rank carries its real denominator",
                          ranks.rent_house.n_ranked == 6,
                          f"out of {ranks.rent_house.n_ranked} LGAs"))
    results.append(report(
        "investment splits pipeline from determined",
        (built.investment.pipeline_n, built.investment.determined_n)
        == (pipeline, determined),
        f"pipeline {built.investment.pipeline_n} / "
        f"determined {built.investment.determined_n}",
    ))
    return results


def check_time_of_day(client) -> list[bool]:
    """The hour picker must reach the report and change the answer."""
    results = []
    encoded = ULTIMO.replace(" ", "%20")
    for hour, expected_band in (("08", "peak"), ("14", "offpeak")):
        built = get_report(ULTIMO, hour)
        results.append(report(
            f"?at={hour} resolves to {expected_band}",
            built.commute.time_of_day.band == expected_band,
            built.commute.time_of_day.caption,
        ))
        status = client.get(f"/report?address={encoded}&at={hour}").status_code
        results.append(report(f"GET /report?at={hour}", status == 200, str(status)))

    layer = json.loads(
        client.get(f"/api/layers/reach?address={encoded}&at=08").data)
    band = (layer["features"][0]["properties"]["band"]
            if layer["features"] else None)
    results.append(report("reach layer follows the chosen hour", band == "peak",
                          str(band)))
    return results


def check_development_layer(client) -> list[bool]:
    """The development layer, and that it agrees with the database."""
    results = []
    encoded = ULTIMO.replace(" ", "%20")
    data = json.loads(
        client.get(f"/api/layers/development?address={encoded}").data)
    features = data.get("features", [])

    tiers = [f["properties"].get("tier") for f in features]
    results.append(report("every DA feature is tiered",
                          all(t in ("pipeline", "determined") for t in tiers)
                          and bool(features),
                          f"{tiers.count('pipeline')} pipeline, "
                          f"{tiers.count('determined')} determined"))

    address = resolve(ULTIMO)
    with postgres() as conn:
        expected = conn.execute(
            f"""
            SELECT count(*) FROM silver.da_application
             WHERE is_usable AND NOT flag_cost_outlier
               AND application_status = ANY(%s)
               AND ST_DWithin(geom_m, {POINT_M}, %s)
            """,
            [list(PIPELINE_STATUSES), address.longitude, address.latitude,
             DEVELOPMENT_RADIUS_M],
        ).fetchone()[0]

    results.append(report("pipeline markers match SQL",
                          tiers.count("pipeline") == expected,
                          f"layer {tiers.count('pipeline')} vs sql {expected}"))
    results.append(report(
        "determined markers are all above the cost floor",
        all(f["properties"]["cost"] is None or f["properties"]["cost"] >= 1_000_000
            for f in features if f["properties"]["tier"] == "determined"),
    ))
    return results


def check_print_layout() -> list[bool]:
    """Guards the two CSS faults that silently broke the A4 export.

    These are stylesheet facts, not rendering, so they are cheap to assert and
    they catch the exact regressions that produced a two-page PDF: an unscoped
    responsive breakpoint (A4 is only ~794 px wide, so a max-width query
    matches the PAPER and collapsed the 2x2 grid), and missing
    print-color-adjust (Chrome drops every background colour by default).
    """
    results = []
    css = (paths.ROOT / "web" / "static" / "app.css").read_text(encoding="utf-8")

    results.append(report(
        "responsive breakpoint is scoped to screen",
        "@media screen and (max-width: 860px)" in css
        and "@media (max-width: 860px)" not in css,
    ))
    results.append(report("print keeps background colours",
                          "print-color-adjust: exact" in css))
    results.append(report("print re-asserts the two-column grid",
                          "grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 26px"
                          in css))
    results.append(report("@page has a margin for the browser's own furniture",
                          "@page { size: A4; margin: 12mm 14mm; }" in css))
    results.append(report("the auto-fit script exists",
                          (paths.ROOT / "web" / "static" / "print.js").is_file()))
    return results


def check_numbers_match_sql() -> list[bool]:
    """The report's figures must equal the same query run against silver."""
    results = []
    built = get_report(SAMPLE_ADDRESS)
    if built is None:
        return [report("report builds", False, "address did not resolve")]

    lon, lat = built.address.longitude, built.address.latitude
    with postgres() as conn:
        nearest = conn.execute(
            f"""
            SELECT min(ST_Distance(s.geom_m, {POINT_M}))
              FROM silver.school s
             WHERE s.is_usable
               AND ST_DWithin(s.geom_m, {POINT_M}, %s)
            """,
            [lon, lat, lon, lat, WALK_RADIUS_M],
        ).fetchone()[0]

        # the same helper the report uses, so the test cannot drift from it
        ring = _hex_ring(conn, built.address.hex_id)
        sales = conn.execute(
            "SELECT count(*), percentile_cont(0.5) WITHIN GROUP"
            " (ORDER BY purchase_price) FROM silver.property_sale"
            " WHERE is_usable AND hex_id = ANY(%s)", [ring],
        ).fetchone()

    results.append(report(
        "nearest school matches SQL",
        built.schools and round(float(nearest)) == built.schools[0].distance_m,
        f"report {built.schools[0].distance_m if built.schools else '-'} m "
        f"vs sql {round(float(nearest)) if nearest else '-'} m",
    ))
    results.append(report("sale count matches SQL",
                          built.market.n_sales == sales[0],
                          f"report {built.market.n_sales} vs sql {sales[0]}"))
    results.append(report(
        "median price matches SQL",
        built.market.median_price == (int(sales[1]) if sales[1] else None),
        f"report {built.market.median_price} vs sql "
        f"{int(sales[1]) if sales[1] else None}",
    ))
    results.append(report(
        "every section is populated",
        bool(built.schools) and built.activity.trips_per_day > 0
        and built.commute.stop is not None and built.market.n_sales > 0
        and len(built.key_figures) == 4,
        f"{len(built.schools)} schools, {built.activity.trips_per_day} trips, "
        f"{built.market.n_sales} sales",
    ))
    results.append(report("caveats are surfaced", len(built.caveats) >= 2,
                          f"{len(built.caveats)} caveats"))
    return results


def run() -> bool:
    """Runs every check; True = the site serves what the warehouse holds."""
    print("Website - routes, geocoder and agreement with SQL:")
    app.config.update(TESTING=True)
    with app.test_client() as client:
        results = (check_routes(client)
                   + check_layers(client)
                   + check_geocoder(client)
                   + check_reachability()
                   + check_time_of_day(client)
                   + check_rankings_and_investment()
                   + check_development_layer(client)
                   + check_print_layout()
                   + check_numbers_match_sql())
    return summarise(results)


if __name__ == "__main__":
    sys.exit(0 if run() else 1)
