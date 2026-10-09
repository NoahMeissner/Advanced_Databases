# @Noah Meissner 9.10.2026
"""The address report website.

Three screens from the design handoff (design/DESIGN.md §5):

    /                 start - type an address
    /report?address=  the A4 report page
    /map?address=     the same findings as toggleable map layers

plus the JSON the browser needs: /api/suggest for autocomplete and
/api/layers/<name> for the map.

Everything on screen comes from web.report.get_report(), so the templates never
query the database themselves and the report and the map can never disagree.

Run it from the repo root, with the databases up (./start.sh):
    python -m web.app
    python -m web.app --port 8000 --debug
"""
import argparse
import dataclasses

from flask import Flask, jsonify, redirect, render_template, request, url_for

from web import layers
from web.geocode import suggest
from web.report import SCHOOL_LIST_LIMIT, WALK_MINUTES, get_report
from web.timeband import choices as hour_choices

DATA_SOURCES = (
    "NSW Planning Portal · Valuer General property sales · "
    "NSW DoE school locations · TfNSW bus GTFS · NSW rental bond board"
)
DEFAULT_PORT = 5000

app = Flask(__name__)
app.config["DATA_SOURCES"] = DATA_SOURCES


@app.context_processor
def inject_globals() -> dict:
    """Values every template needs (product name, footer sources)."""
    return {
        "product_name": "Suburblens",
        "data_sources": DATA_SOURCES,
        "walk_minutes": WALK_MINUTES,
        "school_list_limit": SCHOOL_LIST_LIMIT,
        "hour_choices": hour_choices(),
    }


@app.route("/")
def start():
    """The start screen."""
    return render_template("start.html", query=request.args.get("address", ""))


@app.route("/api/suggest")
def api_suggest():
    """Autocomplete rows for the address box."""
    rows = suggest(request.args.get("q", ""))
    return jsonify([dataclasses.asdict(row) for row in rows])


@app.route("/report")
def report_page():
    """The A4 report page for one address."""
    query = request.args.get("address", "").strip()
    if not query:
        return redirect(url_for("start"))

    report = get_report(query, request.args.get("at"))
    if report is None:
        return render_template("not_found.html", query=query), 404
    return render_template("report.html", report=report, view="report")


@app.route("/map")
def map_page():
    """The interactive map for one address."""
    query = request.args.get("address", "").strip()
    if not query:
        return redirect(url_for("start"))

    report = get_report(query, request.args.get("at"))
    if report is None:
        return render_template("not_found.html", query=query), 404
    return render_template("map.html", report=report, view="map")


@app.route("/api/report")
def api_report():
    """The same report as JSON - useful for debugging and for reuse."""
    report = get_report(request.args.get("address", ""), request.args.get("at"))
    if report is None:
        return jsonify({"error": "address not found"}), 404
    return jsonify(dataclasses.asdict(report))


@app.route("/api/layers/<name>")
def api_layer(name: str):
    """GeoJSON for one map layer."""
    builder = layers.LAYERS.get(name)
    if builder is None:
        return jsonify({"error": f"unknown layer: {name}"}), 404

    report = get_report(request.args.get("address", ""), request.args.get("at"))
    if report is None:
        return jsonify({"error": "address not found"}), 404
    return jsonify(builder(report))


def main() -> None:
    """Parses the command line and starts the development server."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--debug", action="store_true")
    args = parser.parse_args()

    print(f"Address report site on http://{args.host}:{args.port}")
    app.run(host=args.host, port=args.port, debug=args.debug)


if __name__ == "__main__":
    main()
