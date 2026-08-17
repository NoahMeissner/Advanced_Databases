# Data exploration — NSW property-signal sources

Reconnaissance of three NSW open datasets for the property-forecasting project.
Goal of the model: forecast how an **address** will out- or under-perform its
**suburb median over three years**, driven by committed changes nearby.

This folder documents what each source actually holds, the gotchas, and how each
becomes a model feature. Interactive visualisations are in [`viz/`](viz/).

| Source | Role | Access | Grain |
|--------|------|--------|-------|
| Valuer General property sales | ground truth (label) | free bulk `.DAT`, CC BY-NC-ND | individual sale |
| NSW Points of Interest (POI) | amenity / access | open ArcGIS REST, no key | point |
| Opal Tap patronage | demand momentum | raw taps need free login; aggregates public | commercial centre, daily |

## 1. Valuer General property sales — the label

- **Where:** `https://www.valuergeneral.nsw.gov.au/__psi/{weekly/YYYYMMDD,yearly/YYYY}.zip`
- **Fields:** price, address, contract + settlement dates, land size, zoning, legal (lot/plan).
- **History:** weekly per-LGA 2001→now; annual flat file 1990–2001.
- **Sample:** 2024 = **193,837 sales** after dedup. Median **$870k**, mid-50% $600k–$1.4M.

**Insights**
- **De-dup is mandatory.** Weekly files reissue sales for weeks after registration.
  Keyed on `district + dealing-number`, one sample suburb dropped from 12,558 to 983;
  ~11% of raw rows are duplicates.
- **Zoning is ~39% blank** — unreliable; derive zoning from a planning layer instead.
- **No lat/lon** — geocode on street + suburb + postcode (or join to DCDB) to map.
- Download sits behind **Cloudflare** — a plain HTTP client gets 403; pull the zip
  in a browser, then run `parse_psi.py` on the local file.

**Feeds the model**
- Target = `log(price)` residual vs **suburb × quarter** median.
- Repeat-sales pairs → clean address-level appreciation index.
- Filters: arm's-length only, drop `price < $1k` and price/m² outliers.

## 2. NSW Points of Interest — amenity / access

- **Where:** `https://maps.six.nsw.gov.au/arcgis/rest/services/public/NSW_POI/MapServer/0`
- **Size:** 145,779 points, single layer, 9 groups, GDA94 (WKID 4283).
- **Fields:** `poitype`, `poiname`, geometry, `startdate` / `enddate` / `lastupdate`, `urbanity`.

**Insights**
- Model-relevant categories are small and clean: **4,068 education**, **582 railway
  stations**, 570 hospitals, 451 childcare.
- Points carry `startdate` / `enddate` — you can **date when a POI appeared**, which
  turns "new station" into a step-change feature.
- **1000-row query cap**; page with `resultOffset`. `resultRecordCount` alone 400s.

**Feeds the model**
- `dist_nearest_station`; count schools / parks within 800 m and 1.6 km.
- In-catchment-school flag (join to catchment polygons).
- New-POI event from `startdate` → dated step-change feature.

## 3. Opal Tap patronage — demand momentum

- **Where:** `https://opendata.transport.nsw.gov.au/data/dataset/opal-patronage`
- **Fields:** journey date, tap-on / tap-off counts. Jan 2020→, refreshed every 15 min.
- **Published FY2025 mode split:** 665.2M trips — Trains 285M (43%), Bus 243M (37%),
  Metro 72M (11%), Light Rail 47M (7%), Ferry 19M (3%). Metro ≈ 215k trips/day.

**Insights**
- This is **realised demand, not timetabled service** — the reason to use it.
- Aggregated **by commercial centre, not per station** → coarse for a single address.
- Raw tap files need a **free Open Data account**; only aggregates are ungated.

**Feeds the model**
- Nearest-centre tap trend: 3 / 6 / 12-month momentum.
- Leading indicator — demand tends to rise before price.
- Pair with **GTFS-Realtime** for realised travel-time (not headway).

## How they combine

    3-year outperformance = model(
        pipeline shocks (DA / CDC)        # not yet wired
      + access Δ (new station, travel-time, GTFS-RT)
      + amenity (schools, parks — POI)
      + demand momentum (Opal)
    )   trained on historical sale residuals

Each factor is broken out per address **and dated**, so the map can show what drives
the number and when each effect lands (now / year 1 / year 2–3).

**Not yet wired:** DA/CDC development pipeline, GTFS-Realtime, traffic/speed/carriageway.

## Scripts

| Script | What it does |
|--------|--------------|
| `poi_query.py` | Query the NSW POI ArcGIS service (counts, group stats, paged fetch). |
| `parse_psi.py` | Parse + de-duplicate a downloaded PSI zip → CSV. |

```bash
pip install requests
python poi_query.py                 # prints category counts
python parse_psi.py 2024.zip out.csv  # parse a PSI archive you downloaded
```
