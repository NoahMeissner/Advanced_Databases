"""Data-quality and coverage profile of the staging tables, as Markdown.

Usage:
    python -m ingestion.property_sales.psi_profile [--staging-dir ...]
        [--out profile.md]
"""

import argparse
import csv
import datetime as dt
import gzip
import os
import statistics
import sys
from collections import Counter, defaultdict

DEFAULT_STAGING_DIR = os.path.join("data", "property_sales", "staging")
OLD_YEAR = "2020"  # contract years before this are bucketed together


def read(path: str):
    """Stream rows of a gzip CSV."""
    with gzip.open(path, "rt", newline="", encoding="utf-8") as handle:
        yield from csv.DictReader(handle)


def days(later: str, earlier: str):
    """Whole days between two ISO dates/timestamps, or None."""
    if not later or not earlier:
        return None
    return (dt.date.fromisoformat(later[:10])
            - dt.date.fromisoformat(earlier[:10])).days


def pct(part: int, whole: int) -> str:
    """Percentage string."""
    return f"{100 * part / whole:.1f}%" if whole else "n/a"


def median(values) -> str:
    """Median formatted with thousands separators, or n/a."""
    values = list(values)
    return f"{statistics.median(values):,.0f}" if values else "n/a"


def percentile(values: list, share: float) -> str:
    """Nearest-rank percentile, or n/a."""
    if not values:
        return "n/a"
    ordered = sorted(values)
    return f"{ordered[min(len(ordered) - 1, int(len(ordered) * share))]:,}"


def profile_current(path: str) -> list:  # pylint: disable=too-many-locals
    """Markdown lines describing sales_current."""
    total = 0
    flags = Counter()
    by_year = defaultdict(list)
    year_rows = Counter()
    lag_settle = []
    lag_contract = []
    districts = Counter()
    dealings = set()
    for row in read(path):
        total += 1
        dealings.add(row["dealing_number"])
        districts[row["district_name"]] += 1
        year = row["contract_year"] or "(none)"
        if year.isdigit() and year < OLD_YEAR:
            year = f"before {OLD_YEAR}"
        year_rows[year] += 1
        for col in row:
            if col.startswith("flag_") and row[col] == "1":
                flags[col] += 1
        flags["has_lotidstring"] += bool(row["lotidstring"])
        flags["has_house_number"] += bool(row["number_first"])
        flags["has_street_type"] += bool(row["street_type_code"])
        flags["is_strata"] += bool(row["strata_lot_number"])
        flags["zoning_blank"] += not row["zoning"]
        if row["is_standard_sale"] == "1":
            flags["is_standard_sale"] += 1
            kind = "strata" if row["strata_lot_number"] else "non-strata"
            by_year[(year, kind)].append(
                int(row["purchase_price"]))
        lag = days(row["load_from"], row["settlement_date"])
        if lag is not None:
            lag_settle.append(lag)
        lag = days(row["load_from"], row["contract_date"])
        if lag is not None:
            lag_contract.append(lag)

    out = ["## Current parcel-sales (`sales_current`)", "",
           f"- Parcel-sale rows: **{total:,}** across **{len(dealings):,}** "
           "dealings", ""]
    out += ["| Check | Rows | Share |", "|---|---:|---:|"]
    for name in sorted(flags):
        out.append(f"| `{name}` | {flags[name]:,} | {pct(flags[name], total)} |")
    out += ["", "### By contract year", "",
            "| Contract year | Rows | Standard sales: median strata $ "
            "| median non-strata $ |", "|---|---:|---:|---:|"]
    for year in sorted(year_rows):
        out.append(f"| {year} | {year_rows[year]:,} | "
                   f"{median(by_year.get((year, 'strata'), []))} | "
                   f"{median(by_year.get((year, 'non-strata'), []))} |")
    out += ["", "Publication lag (first published minus ...):", "",
            f"- settlement date: median **{median(lag_settle)} days**, "
            f"90th percentile {percentile(lag_settle, .9)} days",
            f"- contract date: median **{median(lag_contract)} days**, "
            f"90th percentile {percentile(lag_contract, .9)} days",
            "", "### Largest districts", "",
            "| District | Rows |", "|---|---:|"]
    for name, count in districts.most_common(10):
        out.append(f"| {name} | {count:,} |")
    return out


def profile_versions(path: str) -> list:
    """Markdown lines describing sale_versions (restatement behaviour)."""
    versions = Counter()
    changed = Counter()
    restated_keys = set()
    sale_code_lag = []
    first_seen = {}
    for row in read(path):
        key = (row["property_id"], row["dealing_number"], row["parcel_seq"])
        versions[row["version_no"]] += 1
        if row["version_no"] == "1":
            first_seen[key] = row["load_from"]
            continue
        restated_keys.add(key)
        fields = row["changed_fields"].split("|")
        changed.update(fields)
        if "sale_code" in fields and key in first_seen:
            sale_code_lag.append(days(row["load_from"], first_seen[key]))
    total = versions["1"]
    out = ["## Restatements (`sale_versions`)", "",
           f"- Parcel-sales with more than one version: "
           f"**{len(restated_keys):,}** ({pct(len(restated_keys), total)})",
           "- Versions by number: " + ", ".join(
               f"v{k}: {v:,}" for k, v in sorted(versions.items(),
                                                 key=lambda kv: int(kv[0]))),
           f"- Sale code added after first publication: median "
           f"{median(sale_code_lag)} days later", "",
           "| Field changed in a later version | Times |", "|---|---:|"]
    for name, count in changed.most_common():
        out.append(f"| `{name}` | {count:,} |")
    return out


def main(argv=None) -> int:
    """CLI entry point."""
    parser = argparse.ArgumentParser(description=__doc__.split("\n", maxsplit=1)[0])
    parser.add_argument("--staging-dir", default=DEFAULT_STAGING_DIR)
    parser.add_argument("--out", default="")
    args = parser.parse_args(argv)
    lines = ["# PSI profile", ""]
    lines += profile_current(os.path.join(args.staging_dir,
                                          "sales_current.csv.gz"))
    lines += [""] + profile_versions(os.path.join(args.staging_dir,
                                                  "sale_versions.csv.gz"))
    text = "\n".join(lines) + "\n"
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(text)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
