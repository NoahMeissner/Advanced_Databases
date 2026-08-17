"""Parse a NSW Valuer General bulk Property Sales Information (PSI) archive.

Download the ``.zip`` first from the portal (it sits behind Cloudflare, so a
plain HTTP client gets a 403 -- use a browser):

    weekly  https://www.valuergeneral.nsw.gov.au/__psi/weekly/YYYYMMDD.zip
    annual  https://www.valuergeneral.nsw.gov.au/__psi/yearly/YYYY.zip

Archive shapes handled here:
  * annual  -> zip of weekly zips -> per-LGA ``.DAT`` files (current format)
  * weekly  -> per-LGA ``.DAT`` files
  * archive -> one big ``ARCHIVE_SALES_YYYY.DAT`` (1990-2001 flat format)

Records are ``;``-delimited, one type per line. ``B`` rows are sales.

De-duplication matters: weekly files reissue the same sale for several weeks,
so a naive read double-counts (~11% in one sample year). Sales are keyed on
``district + dealing-number`` and the first occurrence wins.

Usage:
    python parse_psi.py 2024.zip sales_2024.csv
"""

import csv
import io
import sys
import zipfile

# Current-format B record: index -> meaning (see "Current PSI File Format" PDF).
FIELDS = {
    "district": 1,
    "property_id": 2,
    "unit_number": 6,
    "house_number": 7,
    "street": 8,
    "locality": 9,
    "postcode": 10,
    "area": 11,
    "area_type": 12,
    "contract_date": 13,
    "settlement_date": 14,
    "price": 15,
    "zoning": 16,
    "nature": 18,
    "dealing_number": 24,
}
OUT_COLUMNS = list(FIELDS)


def _iter_dat_bytes(data: bytes):
    """Yield raw ``.DAT`` byte blobs from a PSI zip, descending into inner zips."""
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        for name in archive.namelist():
            lower = name.lower()
            if lower.endswith(".dat"):
                yield archive.read(name)
            elif lower.endswith(".zip"):
                yield from _iter_dat_bytes(archive.read(name))


def _row(fields: list) -> dict:
    """Map a split B-record line to the named output columns."""
    return {
        col: fields[idx] if idx < len(fields) else ""
        for col, idx in FIELDS.items()
    }


def parse(zip_path: str):
    """Yield deduped sale dicts from a PSI zip at ``zip_path``."""
    with open(zip_path, "rb") as handle:
        blob = handle.read()

    seen = set()
    dupes = 0
    for dat in _iter_dat_bytes(blob):
        for line in dat.decode("latin-1").splitlines():
            if not line.startswith("B;"):
                continue
            fields = line.split(";")
            row = _row(fields)
            if not row["price"] or int(row["price"] or 0) < 1000:
                continue
            deal = row["dealing_number"]
            key = (
                (row["district"], deal) if deal
                else (row["district"], row["property_id"], fields[3])
            )
            if key in seen:
                dupes += 1
                continue
            seen.add(key)
            yield row

    print(f"deduped sales: {len(seen):,}  (dropped {dupes:,} duplicate rows)",
          file=sys.stderr)


def main() -> None:
    """CLI: parse a PSI zip into a deduped CSV."""
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    zip_path, out_path = sys.argv[1], sys.argv[2]
    with open(out_path, "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=OUT_COLUMNS)
        writer.writeheader()
        writer.writerows(parse(zip_path))
    print(f"wrote {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
