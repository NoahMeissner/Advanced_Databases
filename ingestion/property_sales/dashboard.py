"""Build a self-contained HTML dashboard from the PSI staging tables.

Reads ``sale_versions`` and ``sales_current`` (the output of ``transform``)
and the landing ``_manifest.csv``, reduces them to aggregates -- no individual
sale leaves this script -- and writes one HTML file with the aggregates
inlined. Charts are plain SVG; the 3D map uses deck.gl + MapLibre from a CDN.

Prices are **standard sales only** (``is_standard_sale``) with contract year
from 2021, split into strata (has a strata lot number) and non-strata.

Localities are placed at their NSW Points of Interest gazetteer point (Suburb,
Locality, Town, Village or City), cached in ``--places`` after the first run.
A locality missing from the gazetteer, or whose point lies far from the other
localities sharing its postcode (duplicate names such as Silverwater), is put
at its postcode centroid instead and marked approximate.

Usage:
    python -m ingestion.property_sales.dashboard [--staging-dir ...]
        [--landing-dir ...] [--places data/property_sales/places.json]
        [--out data/property_sales/dashboard.html]
"""

import argparse
import bisect
import csv
import datetime as dt
import json
import math
import os
import statistics
import sys
import urllib.parse
import urllib.request
from collections import Counter, defaultdict

from .psi_profile import days, read

DEFAULT_STAGING_DIR = os.path.join("data", "property_sales", "staging")
DEFAULT_LANDING_DIR = os.path.join("data", "property_sales", "landing")
DEFAULT_PLACES = os.path.join("data", "property_sales", "places.json")
DEFAULT_OUT = os.path.join("data", "property_sales", "dashboard.html")
TEMPLATE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "dashboard_template.html")

POI_URL = ("https://maps.six.nsw.gov.au/arcgis/rest/services/public/"
           "NSW_POI/MapServer/0/query")
PLACE_TYPES = ("Suburb", "Locality", "Town", "Village", "City")
BBOX = (149.9, -34.45, 151.7, -32.9)  # lon/lat box around Greater Sydney
# Homonyms inside the box (Silverwater, Balmoral) are ~90 km apart; rural
# postcodes such as 2250 span ~50 km.
MAX_KM_FROM_POSTCODE = 40.0

FIRST_YEAR = 2021
KINDS = ("all", "strata", "house")  # house = non-strata
HIST_EDGES = [round(10 ** (5 + i / 20)) for i in range(41)]  # $100k..$10M
COHORT_WEEKS = range(-13, 53)  # weeks relative to the contract quarter's end
COHORT_QUARTERS = 12  # most recent contract quarters drawn
SETTLE_MAX_DAYS = 60
CONTRACT_MAX_WEEKS = 52

FLAGS = (
    ("is_standard_sale", "Standard sale (1 parcel, whole interest, "
                         "price >= $1k, valid dates)"),
    ("flag_multi_parcel", "Multi-parcel dealing (price repeated per parcel)"),
    ("flag_has_sale_code", "Sale code present (non-arm's-length hint)"),
    ("flag_part_interest", "Part-interest sale"),
    ("flag_non_market_price", "Price below $1,000"),
    ("flag_settlement_before_contract", "Settlement before contract"),
    ("flag_bad_date", "Unparseable or out-of-range date"),
)


# --------------------------------------------------------------------------
# helpers


def med(values):
    """Median as an int, or None for an empty list."""
    return round(statistics.median(values)) if values else None


def nearest_rank(values: list, share: float):
    """Nearest-rank percentile of an unsorted list, or None."""
    if not values:
        return None
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(len(ordered) * share))]


def expand(counter: Counter, top: int) -> list:
    """Counter keyed 0..top -> dense list."""
    return [counter.get(i, 0) for i in range(top + 1)]


def km_between(lon1, lat1, lon2, lat2) -> float:
    """Equirectangular distance in km (plenty for < 100 km)."""
    x = math.radians(lon2 - lon1) * math.cos(math.radians((lat1 + lat2) / 2))
    return 6371.0 * math.hypot(x, math.radians(lat2 - lat1))


def quarter_end(date: str) -> dt.date:
    """Last day of the calendar quarter containing ISO ``date``."""
    year, month = int(date[:4]), int(date[5:7])
    last_month = (month - 1) // 3 * 3 + 3
    if last_month == 12:
        return dt.date(year, 12, 31)
    return dt.date(year, last_month + 1, 1) - dt.timedelta(days=1)


def quarter_label(date: str) -> str:
    """"2025-05-17" -> "2025Q2"."""
    return f"{date[:4]}Q{(int(date[5:7]) - 1) // 3 + 1}"


# --------------------------------------------------------------------------
# gazetteer


def fetch_places(path: str) -> list:
    """Return gazetteer place points, downloading them once into ``path``.

    The service rejects ``resultOffset`` paging (HTTP 400), so each place type
    is paged with an ``objectid >`` window instead.
    """
    if os.path.exists(path):
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    places = []
    for kind in PLACE_TYPES:
        last = -1
        while True:
            query = urllib.parse.urlencode({
                "where": f"poitype='{kind}' AND objectid>{last}",
                "outFields": "objectid,poiname", "outSR": "4326", "f": "json",
            })
            with urllib.request.urlopen(f"{POI_URL}?{query}",
                                        timeout=60) as resp:
                page = json.load(resp)
            if "error" in page:
                raise RuntimeError(f"POI query failed: {page['error']}")
            features = [f for f in page.get("features", [])
                        if f.get("geometry")]
            places += [{"type": kind,
                        "name": f["attributes"]["poiname"].strip().upper(),
                        "lon": round(f["geometry"]["x"], 5),
                        "lat": round(f["geometry"]["y"], 5)}
                       for f in features]
            if not features or not page.get("exceededTransferLimit"):
                break
            last = max(f["attributes"]["objectid"] for f in features)
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path + ".part", "w", encoding="utf-8") as handle:
        json.dump(places, handle)
    os.replace(path + ".part", path)
    return places


def postcode_centres(by_name: dict, loc_postcodes: dict) -> dict:
    """Row-weighted postcode centroids, seeded from unambiguous names only."""
    sums = defaultdict(lambda: [0.0, 0.0, 0])
    for loc, postcodes in loc_postcodes.items():
        if len(by_name.get(loc, ())) == 1:
            lon, lat = by_name[loc][0]
            for postcode, rows in postcodes.items():
                acc = sums[postcode]
                acc[0] += lon * rows
                acc[1] += lat * rows
                acc[2] += rows
    return {pc: (s[0] / s[2], s[1] / s[2]) for pc, s in sums.items()}


def place_localities(places: list, loc_postcodes: dict) -> dict:
    """Map locality -> ``(lon, lat, approximate)``.

    ``loc_postcodes`` is ``{locality: Counter(postcode -> rows)}``.
    """
    by_name = defaultdict(list)
    for place in places:
        if (BBOX[0] <= place["lon"] <= BBOX[2]
                and BBOX[1] <= place["lat"] <= BBOX[3]):
            by_name[place["name"]].append((place["lon"], place["lat"]))
    centre = postcode_centres(by_name, loc_postcodes)

    out = {}
    for loc, postcodes in loc_postcodes.items():
        home = centre.get(postcodes.most_common(1)[0][0])
        candidates = by_name.get(loc, [])
        if candidates and home:
            dist, best = min((km_between(*p, *home), p) for p in candidates)
            if dist <= MAX_KM_FROM_POSTCODE:
                out[loc] = (best[0], best[1], 0)
            else:
                out[loc] = (round(home[0], 5), round(home[1], 5), 1)
        elif len(candidates) == 1:
            out[loc] = (candidates[0][0], candidates[0][1], 0)
        elif home:
            out[loc] = (round(home[0], 5), round(home[1], 5), 1)
    return out


# --------------------------------------------------------------------------
# aggregation


def scan_versions(path: str):
    """First-publication time per parcel-sale plus restatement statistics.

    Restatements are also counted per publication date (the weekly file that
    introduced the new version), split into sale-code and other changes.
    """
    first_pub = {}
    versions = Counter()
    changed = Counter()
    by_date = defaultdict(lambda: [0, 0])  # load date -> [sale code, other]
    last_seen = ""
    for row in read(path):
        key = (row["property_id"], row["dealing_number"], row["parcel_seq"])
        versions[int(row["version_no"])] += 1
        last_seen = max(last_seen, row["last_seen"])
        counts = by_date[row["load_from"][:10]]
        if row["version_no"] == "1":
            first_pub[key] = row["load_from"]
            continue
        fields = row["changed_fields"].split("|")
        changed.update(fields)
        counts["sale_code" not in fields] += 1
    dates = sorted(by_date)
    return first_pub, {
        "versions": dict(sorted(versions.items())),
        "changed": changed.most_common(),
        "by_date": {"labels": dates,
                    "sale_code": [by_date[d][0] for d in dates],
                    "other": [by_date[d][1] for d in dates]},
        "last_seen": last_seen,
    }


class Collector:
    """Accumulate dashboard aggregates over one pass of ``sales_current``."""

    def __init__(self, first_pub: dict):
        self.first_pub = first_pub
        self.prices = defaultdict(list)  # (dim, key, kind, period) -> prices
        self.counts = Counter()
        self.lag = {"settle": Counter(), "contract": Counter(),
                    "settle_raw": [], "contract_raw": []}
        self.cohorts = defaultdict(list)  # quarter -> [(first pub, price)]
        self.by_pub_month = defaultdict(lambda: [0, 0])  # [rows, restated]
        self.loc_meta = defaultdict(Counter)  # loc -> (postcode, district)

    def postcodes(self) -> dict:
        """``{locality: Counter(postcode -> rows)}``."""
        out = defaultdict(Counter)
        for loc, meta in self.loc_meta.items():
            for (postcode, _), rows in meta.items():
                out[loc][postcode] += rows
        return out

    def add(self, row: dict) -> None:
        """Fold one current parcel-sale into the aggregates."""
        self.counts["rows"] += 1
        for flag, _ in FLAGS:
            self.counts[flag] += row[flag] == "1"
        self.counts["is_strata"] += bool(row["strata_lot_number"])
        self.counts["zoning_blank"] += not row["zoning"]
        self.counts["has_lotidstring"] += bool(row["lotidstring"])
        self.counts["has_street_type"] += bool(row["street_type_code"])
        key = (row["property_id"], row["dealing_number"], row["parcel_seq"])
        first = self.first_pub.get(key, row["load_from"])
        month = self.by_pub_month[first[:7]]
        month[0] += 1
        month[1] += row["version_no"] != "1"
        if row["is_standard_sale"] == "1":
            self._add_standard(row, first)

    def _add_standard(self, row: dict, first: str) -> None:
        settle = days(first, row["settlement_date"])
        contract = days(first, row["contract_date"])
        if settle is not None and settle >= 0:
            self.lag["settle"][min(settle, SETTLE_MAX_DAYS)] += 1
            self.lag["settle_raw"].append(settle)
        if contract is not None and contract >= 0:
            self.lag["contract"][min(contract // 7, CONTRACT_MAX_WEEKS)] += 1
            self.lag["contract_raw"].append(contract)
        year = row["contract_year"]
        if not year or int(year) < FIRST_YEAR:
            return
        price = round(float(row["purchase_price"]))
        loc = row["locality"].strip().upper()
        for kind in ("all", "strata" if row["strata_lot_number"] else "house"):
            self.prices[("month", row["contract_date"][:7], kind)].append(price)
            self.prices[("year", year, kind)].append(price)
            self.prices[("lga", row["district_name"], kind, year)].append(price)
            self.prices[("loc", loc, kind, year)].append(price)
        self.loc_meta[loc][(row["postcode"], row["district_name"])] += 1
        self.cohorts[quarter_label(row["contract_date"])].append(
            (first[:10], price))


def yearly(prices: dict, dim: str, key: str, years: list) -> dict:
    """``{"c": [[count per year] per kind], "m": [[median ...] ...]}``."""
    lists = [[prices.get((dim, key, kind, str(y)), []) for y in years]
             for kind in KINDS]
    return {"c": [[len(v) for v in row] for row in lists],
            "m": [[med(v) for v in row] for row in lists]}


def histogram(values: list) -> list:
    """Counts per ``HIST_EDGES`` bin; out-of-range values go to the ends."""
    counts = [0] * (len(HIST_EDGES) - 1)
    for value in values:
        idx = bisect.bisect_right(HIST_EDGES, value) - 1
        counts[max(0, min(len(counts) - 1, idx))] += 1
    return counts


def cohort_curves(cohorts: dict, last_seen: dt.date) -> list:
    """Sales known, and their median, N weeks after each contract quarter."""
    out = []
    for label in sorted(cohorts)[-COHORT_QUARTERS:]:
        items = sorted(cohorts[label])
        dates = [d for d, _ in items]
        end = quarter_end(f"{label[:4]}-{int(label[-1]) * 3:02d}-01")
        known, medians = [], []
        for week in COHORT_WEEKS:
            cutoff = end + dt.timedelta(days=7 * week)
            if cutoff > last_seen:
                known.append(None)
                medians.append(None)
                continue
            count = bisect.bisect_right(dates, cutoff.isoformat())
            known.append(count)
            medians.append(med([p for _, p in items[:count]]))
        out.append({"q": label, "n": known, "m": medians, "final": len(items)})
    return out


def read_manifest(landing_dir: str) -> dict:
    """Totals from the extract manifest (archives, files, trailer checks)."""
    totals = Counter()
    with open(os.path.join(landing_dir, "_manifest.csv"), newline="",
              encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            totals["archives"] += 1
            for col in ("dat_files", "b_records", "b_kept", "malformed"):
                totals[col] += int(row[col] or 0)
            totals["trailer_mismatches"] += int(row["trailer_mismatches"] or 0)
    return dict(totals)


def localities(col: Collector, places: dict, years: list):
    """Per-locality map rows, plus the number of sales that couldn't be placed."""
    rows, unplaced = [], 0
    for loc, meta in sorted(col.loc_meta.items()):
        if not loc or loc not in places:
            unplaced += sum(meta.values())
            continue
        (postcode, district), _ = meta.most_common(1)[0]
        lon, lat, approx = places[loc]
        rows.append({"n": loc.title(), "x": lon, "y": lat, "a": approx,
                     "d": district, "p": postcode,
                     **yearly(col.prices, "loc", loc, years)})
    return rows, unplaced


def build(col: Collector, restate: dict, manifest: dict, places: dict) -> dict:
    """Assemble the JSON document the template reads."""
    last_seen = dt.date.fromisoformat(restate.pop("last_seen")[:10])
    years = list(range(FIRST_YEAR, last_seen.year + 1))
    full_year = last_seen.year - 1
    months = sorted({k[1] for k in col.prices if k[0] == "month"})
    locs, unplaced = localities(col, places, years)
    lgas = sorted({k[1] for k in col.prices if k[0] == "lga"})
    counts = col.counts
    return {
        "meta": {
            "generated": dt.date.today().isoformat(),
            "last_seen": last_seen.isoformat(),
            "first_pub_month": min(col.by_pub_month),
            "years": years, "full_year": full_year, **manifest,
            "versions": sum(restate["versions"].values()),
            "current": counts["rows"], "standard": counts["is_standard_sale"],
            "restated": restate["versions"].get(2, 0),
            "placed_locs": len(locs), "approx_locs": sum(l["a"] for l in locs),
            "unplaced_rows": unplaced,
        },
        "year_median": {kind: {y: med(col.prices.get(("year", str(y), kind), []))
                               for y in years} for kind in KINDS},
        "monthly": {"labels": months,
                    "c": [[len(col.prices.get(("month", m, k), []))
                           for m in months] for k in KINDS],
                    "m": [[med(col.prices.get(("month", m, k), []))
                           for m in months] for k in KINDS]},
        "hist": {"edges": HIST_EDGES, "year": full_year,
                 "strata": histogram(col.prices.get(
                     ("year", str(full_year), "strata"), [])),
                 "house": histogram(col.prices.get(
                     ("year", str(full_year), "house"), []))},
        "lga": [{"name": name, **yearly(col.prices, "lga", name, years)}
                for name in lgas],
        "loc": locs,
        "cohort": {"weeks": list(COHORT_WEEKS),
                   "quarters": cohort_curves(col.cohorts, last_seen)},
        "restate": {**restate,
                    "by_month": {"labels": sorted(col.by_pub_month),
                                 "rows": [col.by_pub_month[m][0]
                                          for m in sorted(col.by_pub_month)],
                                 "restated": [col.by_pub_month[m][1]
                                              for m in sorted(col.by_pub_month)]}},
        "lag": {"settle": expand(col.lag["settle"], SETTLE_MAX_DAYS),
                "contract": expand(col.lag["contract"], CONTRACT_MAX_WEEKS),
                "settle_p50": nearest_rank(col.lag["settle_raw"], 0.5),
                "settle_p90": nearest_rank(col.lag["settle_raw"], 0.9),
                "contract_p50": nearest_rank(col.lag["contract_raw"], 0.5),
                "contract_p90": nearest_rank(col.lag["contract_raw"], 0.9)},
        "quality": [[label, counts[flag]] for flag, label in FLAGS] + [
            ["Strata (has strata lot number)", counts["is_strata"]],
            ["Zoning blank", counts["zoning_blank"]],
            ["Lot/plan parsed to DCDB lotidstring", counts["has_lotidstring"]],
            ["Street type parsed to G-NAF code", counts["has_street_type"]],
        ],
    }


def render(data: dict, out_path: str) -> None:
    """Inline ``data`` into the template and write ``out_path``."""
    with open(TEMPLATE, encoding="utf-8") as handle:
        template = handle.read()
    payload = json.dumps(data, separators=(",", ":")).replace("</", "<\\/")
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as handle:
        handle.write(template.replace("__DATA__", payload))


def main(argv=None) -> int:
    """CLI entry point."""
    parser = argparse.ArgumentParser(
        description=__doc__.split("\n", maxsplit=1)[0])
    parser.add_argument("--staging-dir", default=DEFAULT_STAGING_DIR)
    parser.add_argument("--landing-dir", default=DEFAULT_LANDING_DIR)
    parser.add_argument("--places", default=DEFAULT_PLACES)
    parser.add_argument("--out", default=DEFAULT_OUT)
    args = parser.parse_args(argv)

    first_pub, restate = scan_versions(
        os.path.join(args.staging_dir, "sale_versions.csv.gz"))
    col = Collector(first_pub)
    for row in read(os.path.join(args.staging_dir, "sales_current.csv.gz")):
        col.add(row)
    places = place_localities(fetch_places(args.places), col.postcodes())
    data = build(col, restate, read_manifest(args.landing_dir), places)
    render(data, args.out)
    meta = data["meta"]
    print(f"{meta['current']:,} parcel-sales, {meta['placed_locs']} localities "
          f"mapped ({meta['approx_locs']} at postcode centroid, "
          f"{meta['unplaced_rows']:,} sales unplaced) -> {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
