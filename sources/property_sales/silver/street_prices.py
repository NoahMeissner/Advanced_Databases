"""Average sale price per street, by property type and contract year.

Reads ``sales_current`` and writes ``street_prices`` (gzip CSV) to the Silver
directory. One row per **street x property type x period**:

    street      street_name_core + street_type_code + street_suffix_code +
                locality + postcode (the G-NAF STREET_LOCALITY grain, so
                "SMITH ST, PARRAMATTA" and "SMITH ST, NEWTOWN" stay apart,
                and "RD" / "ROAD" are the same street)
    type        house (non-strata residence), unit (strata residence),
                land (vacant land), other (commercial, industrial, ...), all
    period      contract year, or "all" for every year together

Only **standard sales** count (``is_standard_sale``: one parcel, whole
interest, price >= $1,000, valid dates), so multi-parcel prices, which PSI
repeats on every parcel row, don't inflate averages. Rows without a street
name or locality are skipped and counted.

``mean_price`` is the arithmetic average. Prices are skewed, so
``median_price`` is usually the better "typical price". Check ``sales``
before trusting either: the median street has about six standard sales across
all years.

Usage:
    python -m sources.property_sales.silver.street_prices [--silver-dir ...]
"""

import argparse
import csv
import gzip
import os
import statistics
import sys
from collections import Counter, defaultdict

from .address import address_label

DEFAULT_SILVER_DIR = os.path.join("data", "silver", "property_sales")
ALL = "all"

COLUMNS = [
    "street_id", "street_label", "street_name_core", "street_type_code",
    "street_suffix_code", "locality", "postcode", "district_code",
    "district_name", "property_type", "period", "sales", "mean_price",
    "median_price", "min_price", "max_price", "first_contract_date",
    "last_contract_date", "as_of",
]


def property_type(row: dict) -> str:
    """house / unit / land / other from nature of property + strata lot."""
    nature = row["nature_of_property"]
    if nature == "R":
        return "unit" if row["strata_lot_number"] else "house"
    if nature == "V":
        return "land"
    return "other"


def street_parts(row: dict) -> tuple:
    """Street key parts, or None when the row has no street or locality."""
    parts = (row["street_name_core"].strip(), row["street_type_code"],
             row["street_suffix_code"], row["locality"].strip().upper(),
             row["postcode"].strip())
    return parts if parts[0] and parts[3] else None


def collect(path: str):
    """Group standard-sale prices by (street, type, period)."""
    prices = defaultdict(list)       # (street, type, period) -> [(date, price)]
    districts = defaultdict(Counter)  # street -> (code, name) -> rows
    stats = Counter()
    as_of = ""
    with gzip.open(path, "rt", newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            as_of = max(as_of, row["last_seen"])
            if row["is_standard_sale"] != "1":
                continue
            street = street_parts(row)
            if street is None or not row["contract_year"]:
                stats["skipped_no_street_or_year"] += 1
                continue
            stats["used"] += 1
            sale = (row["contract_date"], round(float(row["purchase_price"])))
            for kind in (property_type(row), ALL):
                for period in (row["contract_year"], ALL):
                    prices[(street, kind, period)].append(sale)
            districts[street][(row["district_code"],
                               row["district_name"])] += 1
    return prices, districts, stats, as_of[:10]


def street_columns(street: tuple) -> dict:
    """Key, label and G-NAF-shaped parts for one street."""
    name, stype, suffix, locality, postcode = street
    label = address_label(
        {"number_first": "", "number_first_suffix": "", "flat_number": "",
         "flat_number_suffix": "", "street_name_core": name,
         "street_type_code": stype, "street_suffix_code": suffix},
        locality, postcode)
    return {"street_id": "|".join(street), "street_label": label.lstrip(),
            "street_name_core": name, "street_type_code": stype,
            "street_suffix_code": suffix, "locality": locality,
            "postcode": postcode}


def rows_out(prices: dict, districts: dict, as_of: str):
    """Yield one output row per (street, type, period), sorted by street."""
    for (street, kind, period), sales in sorted(prices.items()):
        (district_code, district_name), _ = districts[street].most_common(1)[0]
        values = [price for _, price in sales]
        dates = [date for date, _ in sales]
        yield {
            **street_columns(street),
            "district_code": district_code, "district_name": district_name,
            "property_type": kind, "period": period, "sales": len(values),
            "mean_price": round(statistics.fmean(values)),
            "median_price": round(statistics.median(values)),
            "min_price": min(values), "max_price": max(values),
            "first_contract_date": min(dates), "last_contract_date": max(dates),
            "as_of": as_of,
        }


def main(argv=None) -> int:
    """CLI entry point."""
    parser = argparse.ArgumentParser(
        description=__doc__.split("\n", maxsplit=1)[0])
    parser.add_argument("--silver-dir", default=DEFAULT_SILVER_DIR)
    args = parser.parse_args(argv)
    prices, districts, stats, as_of = collect(
        os.path.join(args.silver_dir, "sales_current.csv.gz"))
    out_path = os.path.join(args.silver_dir, "street_prices.csv.gz")
    streets = set()
    written = 0
    with gzip.open(out_path + ".part", "wt", newline="",
                   encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=COLUMNS)
        writer.writeheader()
        for row in rows_out(prices, districts, as_of):
            writer.writerow(row)
            streets.add(row["street_id"])
            written += 1
    os.replace(out_path + ".part", out_path)
    print(f"{stats['used']:,} standard sales on {len(streets):,} streets -> "
          f"{written:,} rows ({stats['skipped_no_street_or_year']:,} skipped: "
          f"no street, locality or contract year) -> {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
