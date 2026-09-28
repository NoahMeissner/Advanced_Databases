"""Turn landing rows into versioned, typed staging tables.

Business key: one **parcel-sale** = ``(property_id, dealing_number,
parcel_seq)``. A dealing (the Land Registry document) can cover several
parcels. Usually each has its own property id, but strata lots bought
together (a unit plus its car-space lot) share the building's property id and
appear as several B records in the same file. ``parcel_seq`` numbers those
rows 1..n in file order, which is stable across republications.

The Valuer General republishes a parcel-sale in later weekly files -- often
unchanged, sometimes corrected (sale code added, strata lot or unit number
fixed, legal description updated after plan registration). Descriptive fields
are hashed (``hashdiff``, as in a Data Vault satellite); a new hash is a new
**version**. That gives two time axes (criterion C2):

    valid time        contract_date / settlement_date  -- when it happened
    transaction time  load_from .. load_to              -- when we knew it

Outputs (gzip CSV in ``--staging-dir``):

    sale_versions   every version, with load_from/load_to, version_no,
                    changed_fields and lineage of the row that introduced it
    sales_current   latest version per parcel-sale plus parcels_in_sale and
                    quality flags -- what the reporting layer reads

Quality problems are **flagged, never deleted** (criterion C4).

Usage:
    python -m ingestion.property_sales.transform [--landing-dir ...]
        [--staging-dir ...]
"""

import argparse
import csv
import datetime as dt
import glob
import gzip
import hashlib
import os
import sys

from .address import address_label, parse_lot_plan, split_address
from .psi_format import AREA_UNITS_TO_M2, NATURE_OF_PROPERTY, load_districts

DEFAULT_LANDING_DIR = os.path.join("data", "property_sales", "landing")
DEFAULT_STAGING_DIR = os.path.join("data", "property_sales", "staging")

# Descriptive fields whose change makes a new version. sale_counter and
# download_datetime are excluded: they change on every republication.
HASHED = (
    "district_code", "property_name", "unit_number", "house_number",
    "street_name", "locality", "postcode", "area", "area_type",
    "contract_date", "settlement_date", "purchase_price", "zoning",
    "nature_of_property", "primary_purpose", "strata_lot_number",
    "component_code", "sale_code", "interest_of_sale_pct",
    "legal_description",
)

VERSION_COLUMNS = [
    "property_id", "dealing_number", "parcel_seq", "version_no", "hashdiff",
    "load_from", "load_to", "last_seen", "times_published", "is_current",
    "changed_fields",
    # typed business fields
    "district_code", "district_name", "contract_date", "settlement_date",
    "contract_year", "purchase_price", "area_m2", "area_source",
    "area_type", "zoning", "nature_of_property", "nature_description",
    "primary_purpose", "strata_lot_number", "component_code", "sale_code",
    "interest_of_sale_pct",
    # address as published + G-NAF-shaped parts
    "property_name", "unit_number", "house_number", "street_name",
    "locality", "postcode", "flat_number", "flat_number_suffix",
    "number_first", "number_first_suffix", "street_name_core",
    "street_type_code", "street_suffix_code", "address_label",
    # parcel
    "legal_description", "lot", "section", "plan", "lotidstring",
    # quality flags
    "flag_non_market_price", "flag_part_interest", "flag_has_sale_code",
    "flag_settlement_before_contract", "flag_bad_date",
    # lineage of the row that introduced this version
    "source_archive", "source_file", "source_line",
]
CURRENT_COLUMNS = VERSION_COLUMNS + ["parcels_in_sale", "flag_multi_parcel",
                                     "is_standard_sale"]
MIN_PRICE = 1000
EARLIEST = dt.date(1990, 1, 1)


def hashdiff(row: dict) -> str:
    """md5 over the descriptive fields, ``||``-joined (Data Vault style)."""
    joined = "||".join(row[col].strip().upper() for col in HASHED)
    return hashlib.md5(joined.encode("utf-8")).hexdigest()


def parse_date(text: str, today: dt.date):
    """``CCYYMMDD`` -> ISO string, or ``None`` if blank / impossible."""
    if not text:
        return None
    try:
        value = dt.datetime.strptime(text, "%Y%m%d").date()
    except ValueError:
        return None
    if value < EARLIEST or value > today:
        return None
    return value.isoformat()


def load_ts(text: str) -> str:
    """``CCYYMMDD HH24:MI`` -> ``YYYY-MM-DD HH:MM``."""
    return dt.datetime.strptime(text, "%Y%m%d %H:%M").strftime(
        "%Y-%m-%d %H:%M")


def enrich(row: dict, districts: dict, today: dt.date) -> dict:
    """Typed, flagged, address-normalised copy of a landing row."""
    out = {col: row.get(col, "") for col in VERSION_COLUMNS}
    contract = parse_date(row["contract_date"], today)
    settlement = parse_date(row["settlement_date"], today)
    price = int(row["purchase_price"]) if row["purchase_price"].isdigit() \
        else None
    area = float(row["area"]) if row["area"] else None
    factor = AREA_UNITS_TO_M2.get(row["area_type"])
    interest = row["interest_of_sale_pct"]
    interest = "" if interest in ("", "0", "100") else interest

    parts = split_address(row["unit_number"], row["house_number"],
                          row["street_name"])
    out.update(parts)
    out.update(parse_lot_plan(row["legal_description"]))
    out.update({
        "district_name": districts.get(row["district_code"], {}).get(
            "district_name", ""),
        "contract_date": contract or "",
        "settlement_date": settlement or "",
        "contract_year": contract[:4] if contract else "",
        "purchase_price": "" if price is None else price,
        "area_source": row["area"],
        "area_m2": "" if area is None or factor is None
                   else round(area * factor, 2),
        "nature_description": NATURE_OF_PROPERTY.get(
            row["nature_of_property"], ""),
        "interest_of_sale_pct": interest,
        "address_label": address_label(parts, row["locality"],
                                       row["postcode"]),
        "flag_non_market_price": int(price is None or price < MIN_PRICE),
        "flag_part_interest": int(bool(interest)),
        "flag_has_sale_code": int(bool(row["sale_code"])),
        "flag_settlement_before_contract": int(
            bool(contract and settlement and settlement < contract)),
        "flag_bad_date": int(bool(row["contract_date"]) and contract is None),
    })
    return out


def landing_rows(landing_dir: str):
    """Yield landing rows in publication order (download time, file, line)."""
    paths = sorted(glob.glob(os.path.join(landing_dir, "psi_*.csv.gz")))
    batches = []
    for path in paths:
        with gzip.open(path, "rt", newline="", encoding="utf-8") as handle:
            rows = list(csv.DictReader(handle))
        if rows:
            rows.sort(key=lambda r: (r["download_datetime"], r["source_file"],
                                     int(r["source_line"])))
            batches.append((rows[0]["download_datetime"], rows))
    for _, rows in sorted(batches, key=lambda b: b[0]):
        yield from rows


class Versioner:  # pylint: disable=too-many-instance-attributes
    """Track the open version of every parcel-sale while rows stream past.

    Rows are buffered one source file at a time, because two things need the
    whole file: numbering parcel_seq, and resolving blank property ids.
    """

    def __init__(self, districts: dict, today: dt.date, writer):
        self.districts = districts
        self.today = today
        self.writer = writer
        self.open = {}      # key -> (enriched row, raw row)
        self.blank = {}     # dealing -> {keys still open with no property id}
        self.by_deal = {}   # dealing -> {open keys that have a property id}
        self.batch = []     # rows of the file currently streaming
        self.stats = {"rows": 0, "versions": 0, "restated_unchanged": 0,
                      "resolved_blank_property_id": 0,
                      "filled_blank_property_id": 0}

    def add(self, raw: dict) -> None:
        """Feed one landing row (rows must arrive grouped by source file)."""
        self.stats["rows"] += 1
        if self.batch and raw["source_file"] != self.batch[0]["source_file"]:
            self.flush()
        self.batch.append(raw)

    def flush(self) -> None:
        """Version every row of the buffered file."""
        seq = {}
        keyed = []
        for raw in self._fill_blank_ids(self.batch):
            sale = (raw["property_id"], raw["dealing_number"])
            seq[sale] = seq.get(sale, 0) + 1
            keyed.append((sale + (seq[sale],), raw, hashdiff(raw)))
        adopted = self._resolve_blank_ids(keyed)
        for index, (key, raw, digest) in enumerate(keyed):
            self._apply(key, raw, digest, adopted.get(index))
        self.batch = []

    def _fill_blank_ids(self, batch: list) -> list:
        """Give blank-id rows the id already known for the same parcel-sale.

        The reverse of ``_resolve_blank_ids``: a parcel-sale published with
        its property id can later be republished with the id blank. Match on
        dealing number, then identical hashdiff, then legal description.
        """
        out = []
        used = set()
        for raw in batch:
            candidates = [] if raw["property_id"] else sorted(
                self.by_deal.get(raw["dealing_number"], ()))
            if candidates:
                digest = hashdiff(raw)
                match = next((k for k in candidates if k not in used
                              and self.open[k][0]["hashdiff"] == digest),
                             None) or next(
                    (k for k in candidates if k not in used
                     and self.open[k][1]["legal_description"]
                     == raw["legal_description"]), None)
                if match:
                    used.add(match)
                    raw = dict(raw, property_id=match[0])
                    self.stats["filled_blank_property_id"] += 1
            out.append(raw)
        return out

    def _resolve_blank_ids(self, keyed: list) -> dict:
        """Map row index -> earlier blank-property-id version it continues.

        A sale in a newly registered strata plan is sometimes first published
        before the property exists in the Register of Land Values, so its
        property id is blank; a later file repeats it with the id filled in.
        Candidates share the dealing number; an identical hashdiff wins, then
        an identical legal description. The adopted version moves under the
        resolved key so the history stays one chain.
        """
        wanted = [i for i, (key, raw, _) in enumerate(keyed)
                  if raw["property_id"] and key not in self.open
                  and self.blank.get(key[1])]
        adopted = {}
        for match_on in ("hashdiff", "legal_description"):
            for index in wanted:
                if index in adopted:
                    continue
                key, raw, digest = keyed[index]
                for blank_key in sorted(self.blank.get(key[1], ())):
                    old_row, old_raw = self.open[blank_key]
                    same = (old_row["hashdiff"] == digest
                            if match_on == "hashdiff" else
                            old_raw["legal_description"]
                            == raw["legal_description"])
                    if same:
                        self.blank[key[1]].discard(blank_key)
                        adopted[index] = self.open.pop(blank_key)
                        old_row["property_id"] = raw["property_id"]
                        old_row["parcel_seq"] = key[2]
                        self.stats["resolved_blank_property_id"] += 1
                        break
        return adopted

    def _apply(self, key: tuple, raw: dict, digest: str, adopted) -> None:
        """Open a new version for ``key`` unless nothing changed."""
        seen = load_ts(raw["download_datetime"])
        previous = adopted or self.open.get(key)
        if previous and previous[0]["hashdiff"] == digest \
                and previous[1]["property_id"] == raw["property_id"]:
            previous[0]["last_seen"] = seen
            previous[0]["times_published"] += 1
            self.stats["restated_unchanged"] += 1
            self.open[key] = previous
            return
        row = enrich(raw, self.districts, self.today)
        row.update({"parcel_seq": key[2], "hashdiff": digest,
                    "load_from": seen, "load_to": "", "last_seen": seen,
                    "times_published": 1, "version_no": 1,
                    "changed_fields": ""})
        if previous:
            old_row, old_raw = previous
            old_row["load_to"] = seen
            old_row["is_current"] = 0
            self.writer.writerow(old_row)
            row["version_no"] = old_row["version_no"] + 1
            row["changed_fields"] = "|".join(
                col for col in ("property_id",) + HASHED
                if old_raw[col] != raw[col])
        self.open[key] = (row, raw)
        if key[0]:
            self.by_deal.setdefault(key[1], set()).add(key)
        else:
            self.blank.setdefault(key[1], set()).add(key)
        self.stats["versions"] += 1

    def current(self) -> list:
        """Close the stream: write open versions, return them as current."""
        if self.batch:
            self.flush()
        rows = []
        for row, _ in self.open.values():
            row["is_current"] = 1
            self.writer.writerow(row)
            rows.append(row)
        return rows


def add_sale_level(rows: list) -> None:
    """Derive parcels_in_sale and the standard-sale filter on current rows."""
    parcels = {}
    for row in rows:
        parcels[row["dealing_number"]] = parcels.get(
            row["dealing_number"], 0) + 1
    for row in rows:
        count = parcels[row["dealing_number"]]
        row["parcels_in_sale"] = count
        row["flag_multi_parcel"] = int(count > 1)
        row["is_standard_sale"] = int(
            count == 1 and not row["flag_non_market_price"]
            and not row["flag_part_interest"] and bool(row["contract_date"]))


def main(argv=None) -> int:
    """CLI entry point."""
    parser = argparse.ArgumentParser(description=__doc__.split("\n", maxsplit=1)[0])
    parser.add_argument("--landing-dir", default=DEFAULT_LANDING_DIR)
    parser.add_argument("--staging-dir", default=DEFAULT_STAGING_DIR)
    args = parser.parse_args(argv)

    os.makedirs(args.staging_dir, exist_ok=True)
    versions_path = os.path.join(args.staging_dir, "sale_versions.csv.gz")
    current_path = os.path.join(args.staging_dir, "sales_current.csv.gz")

    with gzip.open(versions_path + ".part", "wt", newline="",
                   encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=VERSION_COLUMNS,
                                extrasaction="ignore")
        writer.writeheader()
        versioner = Versioner(load_districts(), dt.date.today(), writer)
        for raw in landing_rows(args.landing_dir):
            versioner.add(raw)
        current = versioner.current()
    os.replace(versions_path + ".part", versions_path)

    add_sale_level(current)
    current.sort(key=lambda r: (r["contract_date"], r["dealing_number"],
                                r["property_id"], r["parcel_seq"]))
    with gzip.open(current_path + ".part", "wt", newline="",
                   encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=CURRENT_COLUMNS,
                                extrasaction="ignore")
        writer.writeheader()
        writer.writerows(current)
    os.replace(current_path + ".part", current_path)

    stats = versioner.stats
    print(f"landing rows {stats['rows']:,} -> versions {stats['versions']:,}"
          f" ({stats['restated_unchanged']:,} unchanged republications)"
          f" -> current parcel-sales {len(current):,}; resolved "
          f"{stats['resolved_blank_property_id']:,} and filled "
          f"{stats['filled_blank_property_id']:,} blank property ids, "
          f"{sum(1 for r in current if not r['property_id']):,} still blank",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
