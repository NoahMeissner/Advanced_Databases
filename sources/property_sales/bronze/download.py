"""Fetch PSI archives into a weekly raw store, or list what to fetch by hand.

The raw directory holds **one zip per week**: ``YYYYMMDD.zip``, byte-for-byte
as the Valuer General published it that Monday. Two archive kinds exist:

    yearly  {URL_BASE}/yearly/YYYY.zip      a bundle of every weekly zip of a past year
    weekly  {URL_BASE}/weekly/YYYYMMDD.zip  one Monday's file, current year

Past years are only published as yearly bundles, so a bundle is **split** into
its weekly zips on arrival (``unbundle``). The members are written unchanged,
each bundle's sha256 and members are logged in ``_bundles.csv`` for lineage,
and the bundle itself is then removed.

Since mid-2026 the server sits behind Cloudflare bot protection: scripted
requests get HTTP 403 while the same URL works in a browser. This script tries
each file once and, for any it cannot get, writes ``manual_download.html`` --
a page of links to click through in a browser. Save the zips (yearly or
weekly) into the raw directory and carry on with ``extract``, which splits any
yearly bundles it finds.

Usage:
    python -m sources.property_sales.bronze.download [--from-year 2021]
        [--raw-dir data/bronze/property_sales/raw] [--list-only]
"""

import argparse
import csv
import datetime as dt
import glob
import hashlib
import io
import os
import re
import sys
import urllib.error
import urllib.request
import zipfile

from ..psi_format import URL_BASE

DEFAULT_RAW_DIR = os.path.join("data", "bronze", "property_sales", "raw")
USER_AGENT = "Mozilla/5.0 (UTS 32113 Advanced Databases coursework)"
BUNDLE_LOG = "_bundles.csv"
BUNDLE_COLUMNS = ["bundle", "bundle_sha256", "weekly_file", "weekly_sha256"]
WEEKLY_NAME = re.compile(r"^\d{8}\.zip$")
YEARLY_NAME = re.compile(r"^\d{4}\.zip$")


def mondays(year: int, until: dt.date) -> list:
    """Every Monday of ``year`` up to ``until``, as ``YYYYMMDD.zip`` names."""
    day = dt.date(year, 1, 1)
    day += dt.timedelta(days=(7 - day.weekday()) % 7)  # first Monday
    names = []
    while day.year == year and day <= until:
        names.append(f"{day:%Y%m%d}.zip")
        day += dt.timedelta(days=7)
    return names


def needed(from_year: int, today: dt.date, raw_dir: str) -> list:
    """``(kind, file name)`` pairs still missing from the weekly raw store.

    A past year counts as present once its bundle has been split (it is in
    ``_bundles.csv``) or every one of its Mondays is on disk; otherwise the
    yearly bundle is needed. The current year is fetched week by week.
    """
    present = set(os.listdir(raw_dir)) if os.path.isdir(raw_dir) else set()
    bundled = {row["bundle"] for row in read_bundle_log(raw_dir)}
    out = []
    for year in range(from_year, today.year):
        if f"{year}.zip" not in bundled and \
                not set(mondays(year, today)) <= present:
            out.append(("yearly", f"{year}.zip"))
    out += [("weekly", name) for name in mondays(today.year, today)
            if name not in present]
    return out


def url_for(kind: str, name: str) -> str:
    """Download URL for an archive."""
    return f"{URL_BASE}/{kind}/{name}"


def fetch(url: str, target: str, timeout: int = 120) -> str:
    """Download ``url`` to ``target`` atomically. Return a status string."""
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as resp:
            data = resp.read()
    except urllib.error.HTTPError as err:
        return f"HTTP {err.code}"
    except (urllib.error.URLError, OSError) as err:
        return f"error: {err}"
    if not data.startswith(b"PK"):
        return "not a zip (bot-protection page?)"
    write_atomic(target, data)
    return "ok"


def write_atomic(target: str, data: bytes) -> None:
    """Write ``data`` to ``target`` via a ``.part`` file and rename."""
    partial = target + ".part"
    with open(partial, "wb") as handle:
        handle.write(data)
    os.replace(partial, target)


def read_bundle_log(raw_dir: str) -> list:
    """Rows of ``_bundles.csv``, or an empty list."""
    path = os.path.join(raw_dir, BUNDLE_LOG)
    if not os.path.exists(path):
        return []
    with open(path, newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def unbundle(raw_dir: str) -> list:
    """Split every yearly bundle in ``raw_dir`` into its weekly zips.

    Weekly members are written byte-for-byte (``zipfile`` verifies each CRC).
    A weekly file that already exists must be identical; a different one
    stops the split rather than overwrite raw data. A bundle holding anything
    other than weekly zips is left in place. Returns the bundles split.
    """
    log = read_bundle_log(raw_dir)
    split = []
    for path in sorted(glob.glob(os.path.join(raw_dir, "*.zip"))):
        name = os.path.basename(path)
        if not YEARLY_NAME.match(name):
            continue
        with open(path, "rb") as handle:
            blob = handle.read()
        with zipfile.ZipFile(io.BytesIO(blob)) as bundle:
            members = [m for m in bundle.namelist() if not m.endswith("/")]
            if not members or not all(
                    WEEKLY_NAME.match(os.path.basename(m)) for m in members):
                print(f"{name}: not a bundle of weekly zips, left as is",
                      file=sys.stderr)
                continue
            rows = [{"bundle": name,
                     "bundle_sha256": hashlib.sha256(blob).hexdigest(),
                     **store_weekly(raw_dir, os.path.basename(member),
                                    bundle.read(member))}
                    for member in members]
        log = [row for row in log if row["bundle"] != name] + rows
        write_bundle_log(raw_dir, log)
        os.remove(path)
        split.append(name)
        print(f"{name}: split into {len(rows)} weekly zips", file=sys.stderr)
    return split


def store_weekly(raw_dir: str, name: str, data: bytes) -> dict:
    """Write one weekly zip unless an identical copy exists."""
    digest = hashlib.sha256(data).hexdigest()
    target = os.path.join(raw_dir, name)
    if os.path.exists(target):
        with open(target, "rb") as handle:
            if hashlib.sha256(handle.read()).hexdigest() != digest:
                raise RuntimeError(f"{target} exists with different content; "
                                   "refusing to overwrite raw data")
    else:
        write_atomic(target, data)
    return {"weekly_file": name, "weekly_sha256": digest}


def write_bundle_log(raw_dir: str, rows: list) -> None:
    """Rewrite ``_bundles.csv`` sorted by weekly file."""
    path = os.path.join(raw_dir, BUNDLE_LOG)
    with open(path + ".part", "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=BUNDLE_COLUMNS)
        writer.writeheader()
        writer.writerows(sorted(rows, key=lambda r: r["weekly_file"]))
    os.replace(path + ".part", path)


def write_manual_page(missing: list, path: str) -> None:
    """Write an HTML page linking every archive that still needs downloading."""
    links = "\n".join(
        f'<li><a href="{url_for(kind, name)}">{kind}/{name}</a></li>'
        for kind, name in missing
    )
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(
            "<!doctype html><meta charset=utf-8><title>PSI downloads</title>"
            "<h1>PSI archives to download by hand</h1>"
            "<p>Click each link in a normal browser and save the zip into "
            f"<code>{os.path.dirname(path)}</code>.</p><ol>{links}</ol>"
        )


def main(argv=None) -> int:
    """CLI entry point."""
    parser = argparse.ArgumentParser(description=__doc__.split("\n", maxsplit=1)[0])
    parser.add_argument("--from-year", type=int, default=2021)
    parser.add_argument("--raw-dir", default=DEFAULT_RAW_DIR)
    parser.add_argument("--list-only", action="store_true",
                        help="don't download, just write the manual page")
    args = parser.parse_args(argv)

    os.makedirs(args.raw_dir, exist_ok=True)
    unbundle(args.raw_dir)  # bundles saved by hand since the last run
    missing = []
    for kind, name in needed(args.from_year, dt.date.today(), args.raw_dir):
        status = "skipped" if args.list_only else fetch(
            url_for(kind, name), os.path.join(args.raw_dir, name))
        print(f"{kind:6} {name:14} {status}", file=sys.stderr)
        if status != "ok":
            missing.append((kind, name))
    unbundle(args.raw_dir)

    page = os.path.join(args.raw_dir, "manual_download.html")
    if missing:
        write_manual_page(missing, page)
        print(f"{len(missing)} archive(s) still needed -> open {page}",
              file=sys.stderr)
    else:
        if os.path.exists(page):
            os.remove(page)
        print("all weekly archives present", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
