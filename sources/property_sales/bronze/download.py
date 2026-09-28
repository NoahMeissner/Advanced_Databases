"""Fetch PSI archives from the Valuer General, or list what to fetch by hand.

Two archive kinds are published:

    yearly  {URL_BASE}/yearly/YYYY.zip      every weekly file of a past year
    weekly  {URL_BASE}/weekly/YYYYMMDD.zip  one Monday's file, current year

Since mid-2026 the server sits behind Cloudflare bot protection: scripted
requests get HTTP 403 while the same URL works in a browser. This script tries
each file once and, for any it cannot get, writes ``manual_download.html`` --
a page of links to click through in a browser. Save the zips into the raw
directory and carry on with ``extract``.

Usage:
    python -m sources.property_sales.bronze.download [--from-year 2021]
        [--raw-dir data/bronze/property_sales/raw] [--list-only]
"""

import argparse
import datetime as dt
import os
import sys
import urllib.error
import urllib.request

from ..psi_format import URL_BASE

DEFAULT_RAW_DIR = os.path.join("data", "bronze", "property_sales", "raw")
USER_AGENT = "Mozilla/5.0 (UTS 32113 Advanced Databases coursework)"


def archive_names(from_year: int, today: dt.date) -> list:
    """Return ``(kind, file name)`` pairs from ``from_year`` up to ``today``.

    Past years come as one yearly zip; the current year as weekly zips, one
    per Monday up to ``today``.
    """
    names = [("yearly", f"{year}.zip") for year in range(from_year, today.year)]
    day = dt.date(today.year, 1, 1)
    day += dt.timedelta(days=(7 - day.weekday()) % 7)  # first Monday
    while day <= today:
        names.append(("weekly", f"{day:%Y%m%d}.zip"))
        day += dt.timedelta(days=7)
    return names


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
    partial = target + ".part"
    with open(partial, "wb") as handle:
        handle.write(data)
    os.replace(partial, target)
    return "ok"


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
    missing = []
    for kind, name in archive_names(args.from_year, dt.date.today()):
        target = os.path.join(args.raw_dir, name)
        if os.path.exists(target):
            continue
        status = "skipped" if args.list_only else fetch(url_for(kind, name),
                                                        target)
        print(f"{kind:6} {name:14} {status}", file=sys.stderr)
        if status != "ok":
            missing.append((kind, name))

    if missing:
        page = os.path.join(args.raw_dir, "manual_download.html")
        write_manual_page(missing, page)
        print(f"{len(missing)} archive(s) still needed -> open {page}",
              file=sys.stderr)
    else:
        print("all archives present", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
