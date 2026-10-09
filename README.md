# Suburblens

A medallion pipeline over NSW open data, with **Sydney bus stops as the reference
point**: every source is reduced to a per-stop measure so one table answers
"what is happening around this stop".

## Installation

1. Download the Raw Folder from Google Drive and put all the files in `data/raw/`
2. Download Docker and it should run
3. Then run `./start.sh`
4. Then run `python -m pipeline.run`

```
./start.sh stop     stop docker (data is kept)
./start.sh reset    kill the databases
./start.sh purge    kill everything that was installed before
```

## Layers

| Layer | Code | Schema | Rule |
|---|---|---|---|
| Bronze | `pipeline/bronze/` | `bronze` | An unaltered copy of the source. Every row, including the bad ones. Rows in the file == rows in the table |
| Silver | `pipeline/silver/` | `silver` | Typed, standardised, quality-flagged, and mapped onto the bus stops. Problems get a `flag_*` column; nothing is deleted |

```bash
python -m pipeline.run                 # bronze, then silver, then the quality checks
python -m pipeline.run rent_data       # one bronze source
python -m pipeline.silver.build        # silver only
python -m pipeline.silver.build da_hex # one silver step
python -m pipeline.silver.build --reset   # drop schema silver and rebuild it
python -m pipeline.silver.quality      # the quality checks on their own
python -m test.data_completness        # bronze: file rows == table rows
python -m test.silver_integrity        # silver: keys, joins, and the school oracle
```

`python -m pipeline.run` exits non-zero if an `error`-level quality check fails,
so a broken load cannot pass silently.

## What silver produces

`silver.bus_stop_profile` is the deliverable: one row per bus stop, every source
joined. The tables behind it:

| Measure | Table | How it reaches a stop |
|---|---|---|
| Development applications | `da_hex_300m`, `bus_stop_da` | 300 m hexagon, plus the k-ring-1 average |
| Property sales | `property_sales_hex_300m`, `property_sales_street`, `bus_stop_property_sales` | same hexagon + k-ring; also a street-grain aggregate |
| Schools | `bus_stop_school`, `bus_stop_school_summary` | every stop within **200 m** (one school maps to several stops) |
| Transit travel time | `bus_edge`, `bus_edge_travel_time` | per stop-to-stop edge, per time band |
| Traffic volume | `traffic_segment_daypart`, `bus_stop_traffic` | rush / non-rush / night; stops within **500 m** |

### Spatial conventions

- `geom` is always **EPSG:4326**; `geom_m` is always **EPSG:7856** (GDA2020 / MGA
  zone 56). All distances and buffers use `geom_m` - `ST_DWithin` on degrees is
  meaningless.
- `silver.hex_300m` is a real 300 m grid: `ST_HexagonGrid(173.205)` in EPSG:7856
  gives cells exactly 300.0 m flat-to-flat and 77,942 m². H3 res 9 was measured
  first and rejected - its cells are 126,636 m² and ~420 m across here, 1.4x the
  requested size.
- `silver.hex_300m_neighbour` is the k-ring: a cell plus its 6 neighbours
  (~900 m across). It is the **headline** figure for DA and sales, because only
  23,638 of 181,492 cells contain any application at all - 2,464 stops read zero
  from their own cell but have activity next door.
- `silver.aoi` is the study area, derived from the stops themselves (2 km around
  their convex hull), not hard-coded.

### Reading the numbers safely

- **`NULL` is not `0`.** `has_da_data` / `has_sales_data` / `has_school_data` /
  `has_traffic_data` / `has_transit_data` on `bus_stop_profile` tell "nothing
  there" from "not ingested". Do not `coalesce` without checking them.
- **Aggregates use `is_usable` only.** Rows failing an error-level check keep
  their `flag_*` column and stay in the table, so
  `count(silver) + count(rejects)` still reconciles with bronze.
- **Quality results are data.** `silver.dq_run` / `dq_result` / `dq_reject` hold
  every check, its threshold and its outcome, per run.

## Known data gaps

| Gap | Size | What it means |
|---|---:|---|
| No raw GTFS feed on disk | - | `bus_graph_edges` only has pre-computed peak/offpeak, so `time_band` is `'peak'`/`'offpeak'` and the 06-12 / 12-18 / 18-24 bands are not built yet. The window definitions are not recorded anywhere, and `service_profile` is `'unknown'`. Dropping a GTFS static feed in unlocks them with no schema change |
| Property sales have no coordinates | all rows | Geocoded to **street centre** from DA application points: 75.3% of usable sales, error p50 86 m / p90 479 m. `geocode_level` and `flag_coarse_geocode` travel with every row. A real centreline layer, or `lotidstring` -> DCDB parcels, would raise both |
| No traffic segment geometry | all 6 segments | `SEG001`..`SEG006` cannot be placed, so `bus_stop_traffic` is empty and the profile's traffic columns are NULL. The 500 m join is written and runs; it needs the TfNSW segment reference |
| Traffic volume is a sample | 432 rows | 6 synthetic segments over 3 days. The `is_mock_data` check warns about exactly this so nobody mistakes it for production |
| DA coordinates | 1,105 bad | Flagged by comparing each point against the median point of its own council - e.g. a Bayside Council application plotted near Albury. A bounding box alone cannot catch these |
| Schools outside the study area | 1,133 of 2,210 | The source is NSW-wide, down to Lord Howe Island. Kept, flagged, and left unprojected |
| `zoning` blank | 50% | Reported, never filtered on |
| Recent sale periods incomplete | last ~7 months | 10% of sales are first published more than 207 days after contract, so recent medians keep moving. `flag_period_incomplete` marks them |
| `bronze.rent_data` | 48 rows | Also a sample, and LGA-level only, so it has no path to a stop yet. `lga_name` / `lga` / `district_name` / `council_name` are four unconformed spellings of the same thing |
