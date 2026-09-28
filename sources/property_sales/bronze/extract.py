"""Extract PSI archives into an append-only landing layer (one CSV per zip).

Each B record becomes one row, exactly as published -- nothing is
de-duplicated here. The Valuer General re-issues ("restates") a sale in later
weekly files, sometimes with a corrected price or date; keeping every version
is what lets later layers answer "what did we know on date X" (bitemporal
history, criterion C2).

Every row carries lineage columns (criterion C4):

    source_archive   zip the row came from, e.g. ``2024.zip``
    source_file      inner path down to the .DAT file
    source_line      1-based line number of the B record in that file
    record_hash      md5 of the raw B line -- identical restatements share it

Incremental and idempotent (criterion C5): an archive is processed once;
``_manifest.csv`` records its sha256, row counts and trailer checks, and a
rerun skips archives whose hash is already there.

Usage:
    python -m sources.property_sales.bronze.extract [--raw-dir ...]
        [--landing-dir ...] [--region greater_sydney|gsc33|nsw]
"""

import argparse
import csv
import glob
import gzip
import hashlib
import io
import os
import sys
import zipfile

from ..psi_format import (B_FIELD_COUNT, B_FIELDS, C_DISTRICT, C_PROPERTY_ID,
                         C_SALE_COUNTER, C_TEXT, region_codes)

DEFAULT_RAW_DIR = os.path.join("data", "bronze", "property_sales", "raw")
DEFAULT_LANDING_DIR = os.path.join("data", "bronze", "property_sales", "landing")

LINEAGE_COLUMNS = ["source_archive", "source_file", "source_line",
                   "record_hash"]
LANDING_COLUMNS = (list(B_FIELDS) + ["legal_description", "c_record_count"]
                   + LINEAGE_COLUMNS)
MANIFEST_COLUMNS = ["source_archive", "sha256", "dat_files", "b_records",
                    "b_kept", "malformed", "trailer_mismatches"]


class FileStats:  # pylint: disable=too-few-public-methods
    """Counters for one archive."""

    def __init__(self):
        self.dat_files = 0
        self.b_records = 0
        self.b_kept = 0
        self.malformed = 0
        self.trailer_mismatches = []


def iter_dat_files(blob: bytes, prefix: str = ""):
    """Yield ``(inner path, bytes)`` for every .DAT, descending nested zips."""
    with zipfile.ZipFile(io.BytesIO(blob)) as archive:
        for name in sorted(archive.namelist()):
            lower = name.lower()
            if lower.endswith(".zip"):
                yield from iter_dat_files(archive.read(name),
                                          f"{prefix}{name}/")
            elif lower.endswith(".dat"):
                yield f"{prefix}{name}", archive.read(name)


def parse_dat(text: str, keep_districts, stats: FileStats,  # pylint: disable=too-many-locals
              source_file: str):
    """Yield landing rows (lists, no lineage yet) from one .DAT file's text.

    C records are joined to their B record on (district, property id, sale
    counter) within this file only, and concatenated without separators as
    the spec requires.
    """
    # Split on LF only: a few files carry a stray CR inside a record, which
    # str.splitlines() would treat as a line break and corrupt the record.
    lines = [line for line in text.replace("\r", "").split("\n") if line]
    b_rows = []        # (line_no, fields)
    legal = {}         # C key -> [chunks]
    counts = {"B": 0, "C": 0, "D": 0}
    trailer = None
    for line_no, line in enumerate(lines, start=1):
        kind = line[:1]
        if kind in counts:
            counts[kind] += 1
        if kind == "B":
            fields = line.split(";")
            if len(fields) != B_FIELD_COUNT:
                stats.malformed += 1
                continue
            b_rows.append((line_no, fields, line))
        elif kind == "C":
            fields = line.split(";")
            if len(fields) > C_TEXT:
                key = (fields[C_DISTRICT], fields[C_PROPERTY_ID],
                       fields[C_SALE_COUNTER])
                legal.setdefault(key, []).append(fields[C_TEXT])
        elif kind == "Z":
            trailer = line.split(";")

    if trailer is not None and len(trailer) >= 5:
        expected = (len(lines), counts["B"], counts["C"], counts["D"])
        published = tuple(int(x or 0) for x in trailer[1:5])
        if expected != published:
            stats.trailer_mismatches.append(source_file)

    stats.b_records += len(b_rows)
    for line_no, fields, raw in b_rows:
        if keep_districts is not None and fields[1] not in keep_districts:
            continue
        key = (fields[1], fields[2], fields[3])
        chunks = legal.get(key, [])
        row = [fields[idx].strip() for idx in B_FIELDS.values()]
        row += ["".join(chunks), len(chunks)]
        digest = hashlib.md5(raw.encode("latin-1")).hexdigest()
        stats.b_kept += 1
        yield row, line_no, digest


def extract_archive(path: str, landing_dir: str,  # pylint: disable=too-many-locals
                    keep_districts) -> dict:
    """Write one landing CSV for the zip at ``path``; return manifest row."""
    with open(path, "rb") as handle:
        blob = handle.read()
    archive = os.path.basename(path)
    stats = FileStats()
    out_path = os.path.join(landing_dir, f"psi_{archive[:-4]}.csv.gz")
    partial = out_path + ".part"
    with gzip.open(partial, "wt", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(LANDING_COLUMNS)
        for inner, data in iter_dat_files(blob):
            stats.dat_files += 1
            text = data.decode("latin-1")
            for row, line_no, digest in parse_dat(text, keep_districts,
                                                  stats, inner):
                writer.writerow(row + [archive, inner, line_no, digest])
    os.replace(partial, out_path)
    return {
        "source_archive": archive,
        "sha256": hashlib.sha256(blob).hexdigest(),
        "dat_files": stats.dat_files,
        "b_records": stats.b_records,
        "b_kept": stats.b_kept,
        "malformed": stats.malformed,
        "trailer_mismatches": "|".join(stats.trailer_mismatches),
    }


def read_manifest(path: str) -> dict:
    """Return ``{archive: manifest row}`` or an empty dict."""
    if not os.path.exists(path):
        return {}
    with open(path, newline="", encoding="utf-8") as handle:
        return {row["source_archive"]: row for row in csv.DictReader(handle)}


def write_manifest(path: str, rows: dict) -> None:
    """Write the manifest sorted by archive name."""
    with open(path, "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=MANIFEST_COLUMNS)
        writer.writeheader()
        for name in sorted(rows):
            writer.writerow(rows[name])


def sha256_of(path: str) -> str:
    """sha256 of a file on disk."""
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main(argv=None) -> int:  # pylint: disable=too-many-locals
    """CLI entry point."""
    parser = argparse.ArgumentParser(description=__doc__.split("\n", maxsplit=1)[0])
    parser.add_argument("--raw-dir", default=DEFAULT_RAW_DIR)
    parser.add_argument("--landing-dir", default=DEFAULT_LANDING_DIR)
    parser.add_argument("--region", default="greater_sydney",
                        choices=["greater_sydney", "gsc33", "nsw"])
    args = parser.parse_args(argv)

    keep = None if args.region == "nsw" else region_codes(args.region)
    os.makedirs(args.landing_dir, exist_ok=True)
    manifest_path = os.path.join(args.landing_dir, "_manifest.csv")
    manifest = read_manifest(manifest_path)

    zips = sorted(glob.glob(os.path.join(args.raw_dir, "*.zip")))
    if not zips:
        print(f"no zips in {args.raw_dir} -- run download first",
              file=sys.stderr)
        return 1
    for path in zips:
        name = os.path.basename(path)
        known = manifest.get(name)
        if known and known["sha256"] == sha256_of(path):
            print(f"{name:14} unchanged, skipped", file=sys.stderr)
            continue
        row = extract_archive(path, args.landing_dir, keep)
        manifest[name] = row
        write_manifest(manifest_path, manifest)
        flag = " TRAILER MISMATCH" if row["trailer_mismatches"] else ""
        print(f"{name:14} {row['b_kept']:>7,} of {row['b_records']:>7,} "
              f"B records kept{flag}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
