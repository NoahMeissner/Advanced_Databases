# Silver Layer — Implementation Plan

## Context

Bronze is complete: `pipeline/bronze/load.py` COPYs 8 raw files into schema `bronze` as a
faithful, typed-but-uncleaned copy (DDL in `pipeline/bronze/sql/*.sql`), with one
row-count parity test (`test/data_completness.py`). `pipeline/silver/` holds a single
orphaned file, `sql/school_locations.sql`, which nothing executes.

Silver has two jobs:

1. **Quality-gate Bronze → Silver.** Bronze keeps every row including bad ones. Silver is
   the first layer anyone may trust: typed entities, explicit `flag_*` columns (team
   contract, recoverable at `git show f3467c0:sources/README.md` — *"Flag problems as
   `flag_*` columns; don't delete rows"*), and a recorded check run rather than silent drops.
2. **Make bus stops the spine.** Every source reduces to a per-stop measure so Gold can
   answer "what is happening around this stop" without touching Bronze: DA → 300 m
   hexagons → stops; property sales → hexagons → stops; GTFS → per-edge travel time by
   time band; schools → stops within 200 m; traffic → segments within 500 m split
   rush/non-rush/night; all joined into one `silver.bus_stop_profile`.

## What the data actually looks like

Verified row counts (what `test/data_completness.py` should report): DA 180,861 ·
property sales 685,187 · schools 2,210 · bus stops 23,427 · bus routes 4,317 ·
bus graph edges 135,097 · traffic 432 · rent 48.

Findings that drive the design:

- **No GTFS feed exists anywhere on disk.** `sydney_bus_graph_edges.geojson` is a
  pre-aggregated peak/offpeak graph; there are no `stop_times.txt`/`trips.txt`, no
  arrival/departure times, no `service_id`. The peak/offpeak window definitions are not
  recorded in the data or the code.
- **`bus_graph_edges` is not deduplicated.** 135,097 rows collapse to **47,047** distinct
  `(from_stop_id, to_stop_id, route_id, direction_id)`; 29,832 duplicate groups, 29,015 of
  them with *conflicting* measures (one pair has 19 rows ranging from `n_trips=0, null` to
  `avg=40.0, n=6`). A plain `avg()` is wrong — it must be trip-weighted.
  `avg_travel_time_peak_s` is NULL in 46,843 rows meaning **"no service in that window"**,
  not missing. ~17k rows are a genuine `0.0` because GTFS timepoints are whole minutes.
  Max offpeak is 3,900 s (a terminus layover artifact).
  Referential integrity to `bus_stops` is **perfect** (0 orphans); 69 stops have no edge.
- **Traffic volume is a 432-row mock**: `SEG001`–`SEG006` × 3 days × 24 h, perfectly
  rectangular, `observation_count = station_count = 1` and `max = avg` in every row, no
  coordinates, and **no segment-reference file exists** to resolve `SEG001` to a location.
- **Property sales have no coordinates at all** — only `address_label`/`locality`/
  `postcode` and `lotidstring` (`173//DP270913`). Business key `(dealing_number,
  parcel_seq)` has **4,202 duplicate rows**; `is_current = 1` on all rows; `zoning` 50 %
  blank; `purchase_price` min 100, median 1,000,000, max 895,000,000; `area_type` is
  `M` (m²) or `H` (hectares) and **must** be normalised before any $/m².
- **`school_location.csv` already ships a 300 m stop-proximity answer** that Bronze
  deliberately drops: `nearest_station_id` (prefixed `bus_stop_`, e.g. `bus_stop_206430`),
  `nearest_station_distance_m`, `station_count_300m`, `station_match_status`
  (873 `matched_within_300m` / 1,337 not). **This is a free validation oracle** for the
  proximity join. `coordinate_crs` = `EPSG:4326 (assumed)` on every row.
- **Extent is NSW-wide with real bad geocodes.** DA spans lon 143.67–153.61; 1,131 rows
  sit outside Greater Sydney, including `PAN-431048` (Bayside Council, blank suburb) at
  `146.915, -36.069` — near Albury, 500 km from Bayside. Three of those share identical
  coordinates, which smells like a geocoder centroid fallback.
  `cost_of_development` max is **21,625,742,730** (21.6 bn). `determination_date` runs
  1988-06-24 → 2026-10-27 (future-dated).
  48,097 rows are Modification Applications and 1,942 are Reviews of determination.
- **PostGIS 3.6.4 and H3 4.2.3 are installed in the image but never enabled.**
  `git grep "CREATE EXTENSION"` across all commits returns nothing; `pg_extension`
  contains only `plpgsql`.
- The repo's `data/` is empty (git-ignored); the downloaded copy lives at
  `/Users/noah/Documents/es/data/raw/`. Symlink or copy it to `data/raw/` before running.

## Decisions taken (confirmed with you)

| Topic | Decision |
|---|---|
| Study area | Convex hull of all 23,427 bus stops, buffered 2 km. Keeps the legitimate Illawarra/South Coast stops; drops NSW-wide DA and school noise. |
| Property-sales location | Geocode via a street-centreline reference on `street_name_core` + `street_type_code` + `street_suffix_code` + `locality` + `postcode`; sale sits at the matched segment midpoint. |
| GTFS time bands | Ingest raw GTFS static (`stop_times`/`trips`/`routes`/`calendar`/`stops`) as new Bronze tables and compute 06–12 / 12–18 / 18–24 in Silver. |
| Traffic geometry | Ingest a segment/station reference with coordinates as a new Bronze source. |
| Hex → stop | Both the containing hex and the k-ring-1 average (hex + 6 neighbours, ≈600 m across); k-ring is the headline because per-300 m DA counts are mostly 0 or 1. |
| DA modifications | Separate columns: `n_applications` (Development Applications only), `n_modifications`, `n_reviews`. |
| Sequencing | **Two tiers.** Tier A builds now against data on disk; Tier B slots in when three missing inputs arrive, with no schema redesign. |

### Tier A (buildable today) vs Tier B (needs new raw inputs)

| Deliverable | Tier | Note |
|---|---|---|
| PostGIS/H3 enabled, CRS convention, `silver.hex_300m`, `silver.aoi` | A | |
| `silver.bus_stop`, `silver.bus_edge` | A | |
| Edge travel time, **peak/offpeak**, trip-weighted and deduplicated | A | the hard part of the GTFS work, and it is doable now |
| Schools → stops within 200 m (+ validation against the shipped 300 m answer) | A | |
| DA → hexagons → stops | A | |
| Traffic dayparts (rush/non-rush/night) per `segment_id` | A | no geometry, so no stop join |
| Property sales cleaned + aggregated at street × locality grain | A | |
| `silver.bus_stop_profile` | A | with Tier B columns present and NULL |
| Edge travel time in **06–12 / 12–18 / 18–24** | B | needs the GTFS static feed |
| Property sales → hexagons → stops | B | needs street centrelines |
| Traffic → stops within 500 m | B | needs the segment reference + real extract |

Tier B needs no redesign because `time_band` and `geocode_level` are *values in a column*,
not columns — adding bands or a better geocoder inserts rows, it does not alter tables.

---

## 1. Prerequisites — extensions, CRS, study area

`pipeline/silver/sql/00_extensions.sql`
```sql
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS h3;
CREATE EXTENSION IF NOT EXISTS h3_postgis CASCADE;
CREATE SCHEMA IF NOT EXISTS silver;
```
The `suburblens` role is the image's `POSTGRES_USER` and therefore superuser, so this works
unprivileged-free. This is the first thing any Silver run must do.

**CRS convention** (team contract C3 asks for one project CRS):

- Storage / interchange: `geometry(Point, 4326)` — matches the GeoJSON in Bronze and what
  H3 consumes directly.
- Metric work (buffers, distances, areas): `geometry(..., 7856)` = **GDA2020 / MGA zone
  56**. Valid for 150–156 °E, which covers the whole bus-stop hull (150.34–151.33 °E).
- Stored as a **second plain column filled on insert**, not a generated column —
  `ST_Transform`'s immutability is version-dependent and will bite on dump/restore. GiST
  index on both.
- Never `ST_DWithin` on degrees. All radii (200 m, 500 m, 2 km) run against `geom_m`.
- Schools outside the hull (Broken Hill is MGA zone 54, Lord Howe zone 57) stay in
  `silver.school` with `flag_outside_aoi` and a NULL `geom_m` — never reprojected into
  zone 56, which would be silently wrong by kilometres.

**Study area**, derived not hard-coded:
```sql
CREATE MATERIALIZED VIEW silver.aoi AS
SELECT ST_Buffer(ST_ConvexHull(ST_Collect(geom_m)), 2000) AS geom_m
  FROM silver.bus_stop;
```

### Why H3 resolution 9 is "300 × 300 m"

H3 res 9: edge ≈ 174.4 m, so flat-to-flat width ≈ **302 m**, point-to-point ≈ 349 m, area
≈ 0.105 km². The standard grid closest to a 300 m cell, with free neighbour lookup
(`h3_grid_disk`) and a stable global id — and the extension is already in the image.
(`ST_HexagonGrid(173.2, …)` in EPSG:7856 is the alternative; it buys exactness we don't
need and loses the k-ring operator.)

```sql
CREATE TABLE IF NOT EXISTS silver.hex_300m (
    hex_id     h3index  PRIMARY KEY,
    resolution smallint NOT NULL DEFAULT 9,
    geom       geometry(Polygon, 4326) NOT NULL,   -- h3_cell_to_boundary_geometry
    centroid   geometry(Point,   4326) NOT NULL,   -- h3_cell_to_geometry
    geom_m     geometry(Polygon, 7856) NOT NULL
);
```
Populated from the union of every hex a Silver point lands in **plus**
`h3_grid_disk(hex_id, 1)` around every bus-stop hex, so k-ring joins never miss a cell.

---

## 2. Quality checks (Bronze → Silver)

### Framework

Three tables plus one runner, so checks are data rather than scattered asserts. This also
closes the contract's C4 gap — there is currently no audit table of any kind.

`pipeline/silver/sql/01_quality.sql`
```sql
CREATE TABLE IF NOT EXISTS silver.dq_run (
    run_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    started_at  timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,
    git_rev     text,
    passed      boolean
);

CREATE TABLE IF NOT EXISTS silver.dq_result (
    run_id      bigint      NOT NULL REFERENCES silver.dq_run,
    table_name  text        NOT NULL,   -- 'silver.da_application'
    check_name  text        NOT NULL,   -- 'coord_matches_council'
    dimension   text        NOT NULL,   -- completeness|uniqueness|validity|
                                        -- consistency|accuracy|timeliness
    severity    text        NOT NULL,   -- 'error' | 'warn'
    failed_rows bigint      NOT NULL,
    total_rows  bigint      NOT NULL,
    threshold   numeric,                -- max tolerated failed fraction
    passed      boolean     NOT NULL,
    detail      jsonb,
    checked_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (run_id, table_name, check_name)
);

CREATE TABLE IF NOT EXISTS silver.dq_reject (
    run_id       bigint NOT NULL REFERENCES silver.dq_run,
    source_table text   NOT NULL,
    source_key   text   NOT NULL,       -- business key as text
    check_name   text   NOT NULL,
    reason       text,
    payload      jsonb                  -- the offending row
);
```

Each check is one SQL file under `pipeline/silver/sql/checks/` returning the fixed shape
`(check_name, dimension, severity, failed_rows, total_rows, threshold, detail)`.
`pipeline/silver/quality.py` runs them all into `dq_result` and exits non-zero if any
`severity='error'` check fails, so `python -m pipeline.run` and CI can gate on it.

Rows failing an **error** check are never deleted: they go to `silver.dq_reject` and carry
a `flag_*` column plus an `is_usable` boolean, so aggregates exclude them with a predicate
and the count still reconciles to Bronze.

### Cross-cutting checks (every source)

| Check | Dimension | Rule |
|---|---|---|
| `row_count_vs_bronze` | completeness | `count(silver) + count(rejects) = count(bronze)` — nothing vanishes silently |
| `pk_not_null` / `pk_unique` | uniqueness | business key non-null and unique after dedup |
| `no_full_duplicates` | uniqueness | no two rows identical on all descriptive columns |
| `row_count_drift` | accuracy | within ±X % of the previous `dq_run` — catches a truncated source file |
| `freshness` | timeliness | `max(_loaded_at)` recent; source date not older than the publisher's cadence |
| `future_dates` | validity | no date > `current_date`, except genuinely forward-looking fields (exhibition end) |
| `geom_valid` | validity | `ST_IsValid`, non-empty, `ST_SRID = 4326`, declared geometry type |
| `geom_inside_aoi` | validity | inside `silver.aoi`; catches (0,0), lat/lon swaps and NSW-wide leakage |

### DA applications

| Check | Rule |
|---|---|
| `coords_present` | lat and lon both non-null — **7 rows fail**, report the rate; needed for hexing |
| `coords_plausible` | `lat < 0 AND lon > 0` (lat/lon swap), and inside `silver.aoi` — ~1,131 rows fail |
| `coord_matches_council` | **the valuable one:** distance from the coordinate to the median coordinate of its own `council_name`; > 50 km ⇒ `flag_bad_geocode`. This is what catches a Bayside application sitting near Albury, which a bbox test alone would pass if the bbox were NSW-wide |
| `coord_centroid_fallback` | ≥ 3 applications sharing an identical coordinate across different addresses ⇒ `flag_geocode_collision` (the geocoder-centroid smell) |
| `date_order` | `submission_date ≤ lodgement_date ≤ determination_date` |
| `determined_has_date` | status "Determined" ⇒ `determination_date` non-null |
| `determination_date_range` | between 1990 and `current_date + 1 year`; flags the 1988 and 2026-10-27 tails |
| `cost_non_negative` | `cost_of_development >= 0` |
| `cost_outlier` | outside p0.1–p99.9 ⇒ `flag_cost_outlier` (warn). The 21.6 bn max would single-handedly destroy a hex mean |
| `dwellings_sane` | `number_of_new_dwellings` ∈ [0, 5000]; `number_of_storeys` ∈ [0, 100] |
| `status_domain` / `type_domain` | values in the observed set (20 statuses, 3 types); new values = warn, so a source change is visible |
| `development_types_split` | every `;`-token non-empty and the token count equals `development_type_count` (the file pairs a 4-token value with `DevelopmentTypeCount=4`, so this is directly testable) |
| `postcode_format` | `~ '^[0-9]{4}$'`, in the NSW range 1000–2999 |

### GTFS / bus edges

| Check | Rule |
|---|---|
| `edge_endpoints_exist` | `from_stop_id`/`to_stop_id` in `bus_stops` — **error**. Currently 0 orphans; keep it as a regression guard |
| `no_self_edge` | `from_stop_id <> to_stop_id` |
| `edge_dedup_ratio` | 135,097 raw rows → 47,047 logical edges; assert the collapse lands in that range. **This check is the whole reason the aggregate is correct** |
| `edge_weighted_mean_used` | assert no logical edge was averaged unweighted: `n_trips` summed must equal the sum over its member rows |
| `null_means_no_service` | a NULL `avg_travel_time_*_s` always pairs with `n_trips_* = 0` (46,843 peak / 34,210 offpeak rows) — **error** if a NULL ever appears with trips, because then it really is missing data |
| `zero_travel_time` | `= 0` ⇒ `flag_zero_timepoint` (~16.6k peak / 21.2k offpeak). Whole-minute GTFS timepoints, not errors — but they must be excluded from speed calculations, or hex travel times come out optimistically fast |
| `edge_time_upper_bound` | > 1800 s ⇒ `flag_layover` (the 3,900 s offpeak edge is a terminus artifact, not a journey) |
| `edge_speed_plausible` | `length_m / travel_time_s` ∈ [1, 100] km/h ⇒ `flag_implausible_speed`. Note `length_m` is the straight-line 2-point geometry, so it underestimates road distance |
| `edge_min_trips` | publish an edge/band average only at `n_trips >= 3`, else `flag_low_sample` |
| `route_id_exists` | all 598 edge `route_id`s exist in `bus_routes` — currently clean |
| **Tier B** `stop_times_fk` | `stop_times.trip_id` → `trips`, `trips.route_id` → `routes` |
| **Tier B** `stop_sequence_monotonic` | per trip, strictly increasing, no gaps that break consecutive-pair logic |
| **Tier B** `time_parse` | parses including the legal 24 h+ overflow (`25:30:00`); unparseable ⇒ reject |
| **Tier B** `band_coverage` | every edge has all three bands, or an explicit NULL + flag — a missing band must never read as zero |
| **Tier B** `gtfs_stop_crosswalk` | GTFS `stop_id` → `silver.bus_stop.stop_id` match rate; **error below 95 %**, with a nearest-stop-within-50 m fallback recorded in `match_method` |
| **Tier B** `bands_agree_with_edges` | compare the new 06–12 band against the trip-weighted peak figure from `bus_graph_edges` (warn on divergence). Validates the new pipeline against the only transit data you have today |

### Property sales

| Check | Rule |
|---|---|
| `dedup_business_key` | `(dealing_number, parcel_seq)` has 4,202 duplicate rows; keep one via `DISTINCT ON (…) ORDER BY version_no DESC, last_seen DESC`. Assert the drop lands near 4,202 — a much larger drop means the tiebreak is wrong |
| `is_current_all_true` | `is_current` is 1 on every row today; warn if that stops being true, because then the `load_to` column Bronze drops starts mattering |
| `price_positive` | `purchase_price >= 1000` (the source's own standard-sale floor; the raw min is 100) |
| `price_outlier` | outside p0.5–p99.5, or price/m² outside p1–p99 ⇒ `flag_price_outlier`, excluded from medians (raw max 895,000,000) |
| `area_normalised` | `area_type = 'H'` × 10 000 → m²; result > 0 and < 1e7. **Without this, $/m² is wrong by 10,000× on hectare rows** |
| `date_order` | `contract_date <= settlement_date`; honour the existing `flag_bad_date` and `flag_settlement_before_contract` |
| `contract_date_present` | 149 rows have no `contract_date` but do have `settlement_date` ⇒ `flag_no_contract_date`, excluded from year-period aggregates |
| `standard_sale_only` | aggregates use `is_standard_sale` (650,952 of 685,187) — excludes multi-parcel and part-interest rows whose price is not the property price |
| `zoning_coverage` | 50 % blank — report it, never filter on zoning |
| `recent_months_incomplete` | last ~7 months ⇒ `flag_period_incomplete`; 10 % of sales are first published > 207 days after contract, so recent medians keep moving |
| **Tier B** `geocode_match_rate` | % of standard sales matched to a street centreline; **error below 80 %**; `geocode_level` ∈ `street`/`locality`/`none` per row |
| **Tier B** `geocode_locality_agrees` | matched street's locality equals the sale's `locality` — guards a wrong-suburb match on a common street name |

### Schools

| Check | Rule |
|---|---|
| `coords_present` | all 2,210 populated today — keep as a regression guard |
| `coordinate_crs_expected` | `coordinate_crs` is `EPSG:4326 (assumed)` and `coordinate_status` is `valid_assumed_wgs84` on every row; **warn on any other value**, because a different CRS silently shifts a school by hundreds of metres |
| `cleaning_status_ok` | every `*_status` column in its known set; unexpected = warn. The source's own cleaning trail is a free quality signal |
| `suppressed_not_leaked` | `indigenous_pct_raw = 'np'` (`status = source_marker_np`) must leave the numeric column NULL — assert the sentinel never became a number |
| `icsea_range` | `icsea_value` ∈ [500, 1400]; `indigenous_pct`/`lbote_pct` ∈ [0, 100] |
| `enrolment_positive` | `latest_year_enrolment_fte > 0` where present (2,169 of 2,210) |
| `duplicate_site` | two schools at an identical coordinate ⇒ warn (co-located campuses are real; so are bad geocodes) |
| `proximity_oracle_agrees` | **the high-value one:** Bronze drops `nearest_station_id` / `station_count_300m` / `station_match_status`, but the raw CSV has them (873 `matched_within_300m`, 1,337 not). Recompute at 300 m and compare: `station_count_300m` should match, and `nearest_station_id` should match after stripping the `bus_stop_` prefix. **Error if agreement < 95 %** — this validates the whole proximity-join approach before you trust the 200 m version |

### Bus stops / routes (the spine)

| Check | Rule |
|---|---|
| `stop_id_unique` | 23,427 distinct, no nulls, all digits with no leading zeros (so the `integer` cast is safe) |
| `geometry_is_point` | `geometry->>'type' = 'Point'`, exactly 2 coordinates |
| `routes_served_valid` | JSON array of non-empty strings; each value exists in `bus_routes.route_short_name` (592 distinct) ⇒ warn on orphans |
| `stop_has_edges` | 69 stops have no edge ⇒ `flag_no_service`, so a NULL travel time is explained rather than mysterious |
| `stop_duplicate_location` | stops within 5 m ⇒ warn; opposite-direction pairs are legitimate, identical points are not |
| `route_shape_variants` | `bus_routes` is 4,317 rows over 602 `route_id` / 1,062 `(route_id, direction_id)` — assert the surrogate `_row_id` PK is doing its job and no code assumes `route_id` is unique |

### Traffic volume

| Check | Rule |
|---|---|
| `hour_completeness` | each `(segment_id, observation_date)` has 24 hours, else `flag_partial_day`. A missing hour must never be averaged as zero |
| `count_non_negative` | `avg_vehicle_count >= 0` |
| `max_ge_avg` | `max_vehicle_count >= avg_vehicle_count` (trivially true on the mock, where they are equal) |
| `quality_flag_respected` | `quality_flag = 'caution'` (72 of 432 rows, all `SEG004`, `min_station_quality = 4`) excluded from headline aggregates but kept and counted |
| `observation_count_min` | daypart averages need `observation_count >= N`, else `flag_low_sample`. Every mock row is 1, so this will flag everything — correctly |
| `diurnal_shape` | night (22–07) mean must not exceed the am-peak mean per segment ⇒ warn. Catches a shifted hour axis or a UTC/local bug. **Expect this to fail on the mock**, whose values are flat-random (385–2,623) — a failure here is the check working |
| `is_mock_data` | ≤ 10 distinct `segment_id` or ≤ 5 distinct `observation_date` ⇒ warn `"sample data, not a real extract"`, so nobody mistakes a 432-row stub for production |
| **Tier B** `segment_geometry_present` | every `segment_id` in the hourly table has geometry in the segment reference; **error below 95 %** |

### Integration

| Check | Rule |
|---|---|
| `stop_profile_one_row_per_stop` | `count(bus_stop_profile) = count(bus_stop)` |
| `hex_assignment_total` | every Silver point with a geom has a non-null `hex_id` present in `silver.hex_300m` |
| `kring_completeness` | every stop's `h3_grid_disk(hex_id, 1)` exists in `silver.hex_300m` |
| `school_match_symmetry` | every school within 200 m of a stop appears in `bus_stop_school`, and no row has `distance_m > 200` |
| `coverage_report` | per measure, the fraction of stops that actually got a value. Written to `dq_result.detail` — low coverage is a finding to report, not a failure |

---

## 3. Silver tables

Convention: singular entity tables, `*_hex_300m` for hex aggregates, `bus_stop_*` for
per-stop bridges. Every table carries `record_source` + `loaded_at`, matching the existing
`silver.school`. (Note the Bronze/Silver inconsistency to settle: Bronze uses `_loaded_at`,
the existing Silver file uses `loaded_at` — Silver keeps `loaded_at`.)

### Spine

**`silver.bus_stop`** — `stop_id` PK, `stop_name`, `routes_served text[]`, `route_count`,
`geom` 4326, `geom_m` 7856, `hex_id`, `flag_no_service`, `flag_outside_aoi`, lineage.
GeoJSON out of `jsonb`: `ST_SetSRID(ST_GeomFromGeoJSON(geometry), 4326)`; `routes_served`
via `jsonb_array_elements_text`. `route_count` is the cheap service measure, free from the
array without touching the edges file.

**`silver.hex_300m`**, **`silver.aoi`** — as in §1.

### Transit edges

**`silver.bus_edge`** — one row per **logical** edge, the deduplication the Bronze file
needs: `edge_key` PK (surrogate), `from_stop_id`, `to_stop_id` (FK → `silver.bus_stop`),
`route_id`, `route_short_name`, `direction_id`, `geom geometry(LineString, 4326)`,
`geom_m`, `straight_line_m`, `n_source_rows`, `flag_*`. 135,097 → ~47,047 rows.
`bronze.bus_graph_edges.edge_id` is retained in a `silver.bus_edge_source` bridge so
lineage back to the raw feature survives the collapse.

**`silver.bus_edge_travel_time`** — the deliverable, long-format so Tier B is additive:
```
PRIMARY KEY (edge_key, service_profile, time_band)
time_band        Tier A: 'peak', 'offpeak'
                 Tier B: 'morning_06_12', 'afternoon_12_18', 'evening_18_24',
                         'night_00_06'
service_profile  Tier A: 'unknown' (the feed's calendar is lost)
                 Tier B: 'weekday' | 'saturday' | 'sunday'
avg_travel_time_s, median_travel_time_s, p90_travel_time_s,
n_trips, avg_speed_kmh, flag_low_sample, flag_zero_timepoint, flag_layover
```

Tier A aggregation — the one piece of SQL that must be right:
```sql
SELECT from_stop_id, to_stop_id, route_id, direction_id,
       SUM(avg_travel_time_peak_s * n_trips_peak) / NULLIF(SUM(n_trips_peak), 0)
           AS avg_travel_time_s,                 -- trip-weighted, NOT avg()
       SUM(n_trips_peak) AS n_trips
  FROM bronze.bus_graph_edges
 WHERE avg_travel_time_peak_s IS NOT NULL        -- NULL = no service, not missing
 GROUP BY 1, 2, 3, 4;
```
A plain `avg()` lets the many `n_trips = 1` rows dominate; with up to 19 conflicting rows
per logical edge that is a large error, not a rounding one. `flag_zero_timepoint` edges are
kept but excluded from `avg_speed_kmh`.

Tier B: pair consecutive `stop_sequence` rows within a trip; travel time =
`arrival_s(next) - departure_s(current)`; band from the from-stop's departure,
`mod(departure_s, 86400)` so post-midnight overflow buckets correctly; default
`service_profile = 'weekday'` for headline numbers — averaging a Sunday timetable into a
Tuesday one is the classic mistake here. `night_00_06` falls out for free and is computed,
though it is not one of the three you asked for.

A view `silver.bus_edge_travel_time_wide` pivots bands to columns for easy reading.

### DA applications

**`silver.da_application`** — PK `planning_portal_application_number` (verified unique,
180,861 distinct); typed dates, `cost_of_development`, `number_of_new_dwellings`,
`number_of_storeys`, `council_name`, `application_type`, `application_status`,
`geom`/`geom_m`/`hex_id`, `flag_bad_geocode`, `flag_geocode_collision`,
`flag_cost_outlier`, `flag_missing_coords`, `is_usable`.

**`silver.da_development_type`** — `(application_number, development_type)` from the
`;`-split, so `"Balconies, decks…; Demolition; Retaining walls…; Garages…"` becomes four
queryable rows instead of one unsearchable string.

**`silver.da_hex_300m`** — `(hex_id, period)` with `period` a year plus an `'all'`
roll-up: `n_applications` (Development Applications only), `n_modifications`, `n_reviews`,
`n_determined`, `sum_new_dwellings`, `n_applications_last_12m`,
`median_cost_of_development`, `mean_cost_of_development`, `sum_cost_of_development`,
`avg_storeys`, `avg_days_to_determination`. Only `is_usable` rows contribute.

**`silver.bus_stop_da`** — `(stop_id, period)`; each measure appears twice, `*_hex`
(containing cell) and `*_kring1` (over `h3_grid_disk(hex_id, 1)`), plus
`n_hexes_with_data` so "no data" is distinguishable from a true zero.

### Property sales

**Tier B Bronze source**: `bronze.street_centreline` — NSW street centrelines (or OSM
roads clipped to the AOI) as GeoJSON.

**`silver.street_locality`** — `street_id` PK, `md5` of
`street_name_core|street_type_code|street_suffix_code|locality|postcode` — the G-NAF
STREET_LOCALITY grain the Bronze columns already follow, and the same key the historical
`street_prices.py` used. Keeps "SMITH ST, PARRAMATTA" apart from "SMITH ST, NEWTOWN" and
makes `RD`/`ROAD` the same street. Holds merged `geom`, `centroid`, `centroid_m`, `hex_id`
(Tier B).

**`silver.property_sale`** — one row per deduplicated `(dealing_number, parcel_seq)`;
`purchase_price`, `area_m2` (normalised via `area_type`), `price_per_m2`, `contract_date`,
`contract_year`, `contract_quarter`, `property_type` (`house`/`unit`/`land`/`other`,
derived as in the historical `street_prices.py`: `nature_of_property = 'R'` plus
`strata_lot_number` ⇒ unit; `'V'` ⇒ land), `street_id`, `lotidstring`,
`geom`/`geom_m`/`hex_id` (nullable until Tier B), `geocode_level`,
`flag_price_outlier`, `flag_period_incomplete`, `flag_no_contract_date`,
`is_standard_sale`.

**`silver.property_sales_street`** (Tier A) — `(street_id, period, property_type)` with
`n_sales`, `median_price`, `mean_price`, `p25`/`p75`, `median_price_per_m2`,
`first_contract_date`, `last_contract_date`.

**`silver.property_sales_hex_300m`** (Tier B) — same measures keyed
`(hex_id, period, property_type)`, `period` = contract year plus `'all'`, `property_type`
including an `'all'` row. Medians via `percentile_cont(0.5)`; with a 1,000,000 median
against an 895,000,000 max, the mean alone is misleading.

**`silver.bus_stop_property_sales`** — same `*_hex` / `*_kring1` shape as `bus_stop_da`.
The k-ring figures **re-aggregate the underlying sales across the 7 cells**; they are not
an average of hex medians, which would be a meaningless statistic.

### Schools

**`silver.school`** — extend the existing table (currently name/address only) with
`latitude`/`longitude` → `geom`/`geom_m`/`hex_id`, `level_of_schooling`, `school_gender`,
`selective_school`, `latest_year_enrolment_fte`, `icsea_value`, `lga`,
`flag_outside_aoi`, `flag_suppressed_metrics`. Its `ON CONFLICT DO UPDATE … WHERE IS
DISTINCT FROM` pattern stays as-is — just more columns.

**`silver.bus_stop_school`** — the many-to-many you asked for: `(stop_id, school_code)` PK,
`distance_m`, `rank_from_school`, `rank_from_stop`. Built with
`ST_DWithin(stop.geom_m, school.geom_m, 200)` — one school legitimately yields several
rows, one per nearby stop. A 300 m variant is materialised alongside purely to run
`proximity_oracle_agrees` against the figures the source CSV already ships.

**`silver.bus_stop_school_summary`** — per stop: `n_schools_200m`, `nearest_school_code`,
`nearest_school_distance_m`, `sum_enrolment_fte_200m`, `avg_icsea_200m`, `has_primary`,
`has_secondary`.

### Traffic

**Tier B Bronze source**: `bronze.traffic_segment` — `segment_id` + geometry. The 500 m
join is impossible without it; nothing on disk can resolve `SEG001` to a place.

**`silver.traffic_segment`** (Tier B) — `segment_id` PK, `geom`/`geom_m`, `road_name`,
`geometry_source`, `flag_*`.

**`silver.traffic_segment_hourly`** (Tier A) — typed clean copy keyed
`(segment_id, observation_date, hour_of_day)`: `avg_vehicle_count`, `max_vehicle_count`,
`observation_count`, `quality_flag`, `flag_low_quality`, `flag_partial_day`,
`flag_low_sample`, `is_usable`.

**`silver.traffic_segment_daypart`** (Tier A) — fine split and coarse roll-up in one table
via `daypart_kind`:

| daypart | hours | daypart_kind |
|---|---|---|
| `am_peak` | 07–09 | `rush` |
| `midday` | 09–16 | `non_rush` |
| `pm_peak` | 16–19 | `rush` |
| `evening` | 19–22 | `non_rush` |
| `night` | 22–07 | `night` |
| `rush` / `non_rush` / `night` | roll-ups | `summary` |

Measures: `avg_vehicles_per_hour`, `max_vehicles_per_hour`, `total_vehicles`,
`n_hours_observed`, `n_days_observed`, `peak_hour_of_day`, `rush_to_night_ratio`,
`flag_low_sample`. Averages are per-hour means **over usable hours only** — never a sum
over a nominal hour count, which treats a missing hour as zero traffic. All times are
Sydney local (`transformed_at` carries `+11:00` AEDT), so hours need no conversion.

**`silver.bus_stop_traffic`** (Tier B) — `(stop_id, daypart)`: `n_segments_500m`,
`avg_vehicles_per_hour`, `avg_vehicles_per_hour_idw` (inverse-distance-weighted, so a
segment 40 m away outweighs one at 480 m), `max_vehicles_per_hour`, `nearest_segment_id`,
`nearest_segment_distance_m`. `ST_DWithin(stop.geom_m, segment.geom_m, 500)`.

### The join-everything table

**`silver.bus_stop_profile`** — one row per `stop_id`, what Gold reads:

```
stop_id, stop_name, geom, geom_m, hex_id, route_count,
-- DA ('all' and last 12 months)
da_n_applications_kring1, da_n_modifications_kring1, da_sum_new_dwellings_kring1,
da_median_cost_kring1, …
-- property sales (Tier A: via street_id; Tier B: hex + k-ring)
sales_n_kring1, sales_median_price_kring1, sales_median_price_per_m2_kring1, …
-- schools
n_schools_200m, nearest_school_distance_m, sum_enrolment_fte_200m, avg_icsea_200m,
-- traffic (Tier B)
traffic_avg_vph_rush, traffic_avg_vph_non_rush, traffic_avg_vph_night,
traffic_nearest_segment_distance_m, n_segments_500m,
-- transit (roll-up of the stop's incident edges)
avg_edge_travel_time_peak_s, avg_edge_travel_time_offpeak_s,      -- Tier A
avg_edge_travel_time_morning_s, avg_edge_travel_time_afternoon_s,
avg_edge_travel_time_evening_s,                                    -- Tier B
n_edges, n_edges_zero_timepoint,
-- coverage flags, so a NULL is never read as a zero
has_da_data, has_sales_data, has_school_data, has_traffic_data, has_transit_data
```
A table, not a view, so Metabase and any Neo4j export stay fast; rebuilt every Silver run.
It is also the natural input for the provisioned-but-unused Neo4j graph projection.

---

## 4. Code to write

| File | Purpose |
|---|---|
| `pipeline/silver/__init__.py` | new, empty (the package currently has no `__init__.py`, so `pipeline/silver/sql/school_locations.sql` cannot be run by any module) |
| `pipeline/silver/build.py` | the runner, mirroring `pipeline/bronze/load.py`'s shape: an ordered `STEPS` tuple of `(sql_file, label)`, each executed in its own `conn.transaction()` via `psycopg`, printing the resulting row count. Supports `python -m pipeline.silver.build` and `python -m pipeline.silver.build da_hex` |
| `pipeline/silver/quality.py` | runs `sql/checks/*.sql`, writes `dq_run`/`dq_result`/`dq_reject`, prints a table, exits 1 on any failed `error` check |
| `pipeline/silver/sql/*.sql` | the numbered steps below |
| `pipeline/silver/sql/checks/*.sql` | one file per check |
| `pipeline/run.py` | call `silver.build.run(selected)` then `silver.quality.run()` after bronze |
| `test/silver_integrity.py` | new, following `test/data_completness.py`'s exit-code convention: PK uniqueness, FKs to `silver.bus_stop`, `bus_stop_profile` row count, hex coverage |
| **Tier B** `pipeline/bronze/sql/gtfs_static.sql`, `street_centreline.sql`, `traffic_segment.sql` | DDL for the new Bronze tables |
| **Tier B** `pipeline/bronze/load.py` | new `SOURCES` entries; add a `chunksize` field to `Source` and stream chunks through the same `COPY` cursor — `stop_times.txt` is millions of rows and the current reader loads whole files into a DataFrame |
| **Tier B** `paths.py` | `GTFS_DIR`, `STREET_CENTRELINE_GEOJSON`, `TRAFFIC_SEGMENT_GEOJSON` |
| **Tier B** `test/data_completness.py` | chunked row counting for the streamed source |

### SQL step order

```
00_extensions.sql            postgis / h3 / h3_postgis, schema silver
01_quality.sql               dq_run / dq_result / dq_reject
10_bus_stop.sql              silver.bus_stop + silver.aoi
11_hex_300m.sql              hex grid (point cells + k-ring 1 around stops)
12_bus_edge.sql              dedup 135,097 -> ~47,047 logical edges + source bridge
13_bus_edge_travel_time.sql  Tier A: trip-weighted peak/offpeak
14_gtfs_stop_time.sql        Tier B: 24h+ parsing, service_profile
15_bus_edge_bands.sql        Tier B: 06-12 / 12-18 / 18-24
20_school.sql                extend silver.school with geometry and metrics
21_bus_stop_school.sql       200 m many-to-many (+ 300 m oracle variant) + summary
30_da_application.sql        silver.da_application + da_development_type
31_da_hex_300m.sql           hex aggregates
32_bus_stop_da.sql           hex + k-ring 1 -> stop
40_street_locality.sql       street grain (centrelines in Tier B)
41_property_sale.sql         dedup, standard sales, area normalisation, geocode
42_property_sales_street.sql Tier A aggregate
43_property_sales_hex.sql    Tier B
44_bus_stop_property_sales.sql
50_traffic_segment.sql       Tier B geometry reference
51_traffic_hourly.sql        cleaned hourly
52_traffic_daypart.sql       rush / non-rush / night
53_bus_stop_traffic.sql      Tier B: 500 m -> stop
90_bus_stop_profile.sql      the wide join
```

**Idempotency** (contract C5): entity tables use `CREATE TABLE IF NOT EXISTS` plus
`INSERT … ON CONFLICT DO UPDATE … WHERE IS DISTINCT FROM`, exactly as
`silver/sql/school_locations.sql` already does. Aggregate tables are fully derived, so
they `DELETE` then `INSERT` inside one transaction — the same shape Bronze uses
(`DELETE WHERE _source_file` then `COPY`). No `TRUNCATE`.

**Dependencies**: all geospatial and hex work happens in SQL via PostGIS/H3, so
`requirements.txt` stays `pandas` + `psycopg` — consistent with the contract's "the
standard library is preferred". CI runs `pylint` over every tracked `.py`, so new modules
need module and function docstrings and the existing naming style.

---

## 5. Data to obtain (Tier B)

`data/` is git-ignored and empty in the repo; the downloaded copy is at
`/Users/noah/Documents/es/data/raw/` — symlink or copy it to `data/raw/` first.

| Path | Source |
|---|---|
| `data/raw/gfts_historical/gtfs/{stops,stop_times,trips,routes,calendar,calendar_dates}.txt` | TfNSW Open Data GTFS static for Sydney Buses. The `sj2` fragment in `route_id` (`11-545-sj2-1`) is the surviving trace of which calendar version the edges file was built from — match it if that version is still published, otherwise expect small divergence from the Tier A peak figures |
| `data/raw/property_sales/nsw_street_centrelines.geojson` | NSW street centrelines (Spatial Services / SIX), or OSM roads clipped to the AOI |
| `data/raw/traffic_volume/traffic_segments.geojson` + a real hourly extract | TfNSW traffic volume counts — the station/segment reference *and* a real extract. The 432-row file on disk is a mock with synthetic `SEG001`–`SEG006` ids that will not join to anything real |

---

## 6. Verification

1. `./start.sh`, then `python -m pipeline.run` — Bronze, Silver, quality run, one entry point.
2. `python -m test.data_completness` — expect exactly 180,861 / 685,187 / 2,210 / 23,427 /
   4,317 / 135,097 / 432 / 48 rows.
3. `python -m pipeline.silver.quality` — exit 0 required. Then read the warn-level rows in
   `silver.dq_result` and the quarantined rows in `silver.dq_reject`. Expected warns on
   today's data: traffic `diurnal_shape` and `is_mock_data`, DA `coord_matches_council`
   (~1,131), DA `cost_outlier`.
4. `python -m test.silver_integrity` — PKs, FKs to `silver.bus_stop`, hex coverage,
   `bus_stop_profile` row count == `bus_stop` row count.
5. Targeted spot-checks (Adminer `localhost:8080`, Metabase `localhost:3000`):
   - `SELECT ST_Area(geom_m) FROM silver.hex_300m LIMIT 1` ≈ 105,000 m²
   - `SELECT count(*) FROM silver.bus_edge` ≈ 47,047, and
     `SELECT sum(n_source_rows) FROM silver.bus_edge` = 135,097 — the dedup reconciles
   - the `proximity_oracle_agrees` detail: recomputed `station_count_300m` vs the source's
     873 matched / 1,337 unmatched. **This is the single most convincing check in the
     build** — it validates the proximity machinery against an independently produced answer
   - pick a school with `station_count_300m = 2` and confirm it appears against **several**
     stops in `silver.bus_stop_school`, all with `distance_m <= 200`
   - `SELECT daypart_kind, avg(avg_vehicles_per_hour) FROM silver.traffic_segment_daypart
     GROUP BY 1` — on real data rush > non_rush > night; on the mock they will be flat,
     which is the expected mock signature
   - `SELECT count(*), count(da_n_applications_kring1), count(nearest_school_distance_m),
     count(avg_edge_travel_time_peak_s) FROM silver.bus_stop_profile` — the coverage story
     in one row
6. Map check in Metabase: plot `silver.bus_stop` coloured by `n_schools_200m` and by
   `da_n_applications_kring1`. A CRS or geocoding error is obvious on a map and invisible
   in a count.

## Open items

- **Peak/offpeak windows are undefined.** No window definition exists in the edges data or
  anywhere in the repo. Tier A must publish `time_band = 'peak'`/`'offpeak'` as opaque
  labels with a comment saying the boundaries are unknown; `historical-gtfs-api-documentation.pdf`
  in your Downloads may define them. Tier B's explicit hour bands supersede this.
- **`lotidstring` is a better geocoding key than street centrelines** and is already 100 %
  populated in `sales_current.csv` (`173//DP270913` joins the NSW DCDB lot layer directly,
  giving a parcel polygon even when the address string is messy). You chose street
  centrelines, which is the lighter lift; `geocode_level` leaves room to add
  `'parcel'` as a higher-precision tier later without touching the schema.
- **`bronze.rent_data`** (48 rows, also a sample) is not in your list. It is LGA-level, so
  it can only reach a stop through an LGA polygon join, and `lga_name` / `lga` /
  `district_name` / `council_name` are four unconformed spellings of the same thing across
  four sources. The lost `psi_districts.csv` (`git show
  f3467c0:sources/property_sales/reference/psi_districts.csv`, 130 districts with Greater
  Sydney flags) would seed a conformed LGA dimension. Say the word and I'll add it.
- **Bitemporality (contract C2, weighted 25 %)** is only partly satisfied. Bronze's
  delete-then-reload destroys cross-load history for DA applications, whose
  `date_last_updated` + status is the natural second bitemporal source. This plan builds
  type-1 Silver entities matching the existing `school_locations.sql` precedent; adding
  SCD2 satellites is a separate decision worth raising with your team, since the assignment
  spec explicitly called for a Data Vault Silver.
