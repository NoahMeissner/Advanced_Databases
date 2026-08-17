"""Query the NSW Points of Interest ArcGIS service.

The service exposes a single layer (145k+ points across NSW) with no API key.
Docs: https://maps.six.nsw.gov.au/arcgis/rest/services/public/NSW_POI/MapServer

Two things worth knowing before you use it:
  * A single query returns at most 1000 rows; page through with ``resultOffset``.
  * ``resultRecordCount`` on its own triggers a 400 -- pass it together with
    ``resultOffset`` and ``orderByFields`` when paging.
"""

import time
from typing import Iterator

import requests

BASE = (
    "https://maps.six.nsw.gov.au/arcgis/rest/services/"
    "public/NSW_POI/MapServer/0/query"
)
PAGE_SIZE = 1000


def count(where: str = "1=1") -> int:
    """Return the number of features matching ``where``."""
    resp = requests.get(
        BASE,
        params={"where": where, "returnCountOnly": "true", "f": "json"},
        timeout=60,
    )
    resp.raise_for_status()
    return resp.json()["count"]


def group_counts() -> dict:
    """Return feature counts grouped by ``poitype`` (statewide)."""
    stats = '[{"statisticType":"count","onStatisticField":"objectid",' \
            '"outStatisticFieldName":"c"}]'
    resp = requests.get(
        BASE,
        params={
            "where": "1=1",
            "outStatistics": stats,
            "groupByFieldsForStatistics": "poitype",
            "f": "json",
        },
        timeout=60,
    )
    resp.raise_for_status()
    out = {}
    for feature in resp.json().get("features", []):
        attrs = feature["attributes"]
        out[attrs["poitype"]] = attrs["c"]
    return out


def fetch(where: str, out_fields: str = "poitype,poiname",
          geometry: bool = True) -> Iterator[dict]:
    """Yield every feature matching ``where``, paging past the 1000-row cap.

    Coordinates are returned in WGS84 (``outSR=4326``) when ``geometry`` is set.
    """
    offset = 0
    while True:
        params = {
            "where": where,
            "outFields": out_fields,
            "returnGeometry": "true" if geometry else "false",
            "outSR": "4326",
            "orderByFields": "objectid",
            "resultOffset": offset,
            "resultRecordCount": PAGE_SIZE,
            "f": "json",
        }
        resp = requests.get(BASE, params=params, timeout=60)
        resp.raise_for_status()
        features = resp.json().get("features", [])
        if not features:
            return
        yield from features
        if len(features) < PAGE_SIZE:
            return
        offset += PAGE_SIZE
        time.sleep(0.2)


def main() -> None:
    """Print a quick summary of the model-relevant POI categories."""
    print(f"total POIs: {count():,}")
    for label, where in (
        ("schools", "poitype LIKE '%School%'"),
        ("railway stations", "poitype='Railway Station'"),
        ("hospitals", "poitype='Hospital'"),
    ):
        print(f"  {label:20s}: {count(where):,}")


if __name__ == "__main__":
    main()
