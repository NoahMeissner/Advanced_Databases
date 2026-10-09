# Gold Layer — Implementation Plan

## Context

Bronze and Silver are done and verified: `python -m pipeline.run` loads 8 raw sources,
builds 21 Silver steps, and gates on 73 quality checks (0 failures). Silver already reduces
every source to a per-stop measure in `silver.bus_stop_profile` (23,427 rows, one per stop).

Gold has two jobs, both asked for directly:

1. **One graph.** Bus stops are nodes carrying their metadata (rent, sales, DA activity,
   nearby schools, traffic); GTFS-derived stop-to-stop edges connect them; schools, LGAs
   and routes are nodes in their own right so "which stops share a school" and "every stop
   in this LGA" become traversals instead of joins.
2. **Comparison marts.** Rank and compare Sydney LGAs — rent, traffic, prices, development
   — as plain tables next to the graph.

Neo4j 5 with APOC + GDS has been running since day one and **no code has ever touched it**.
`paths.NEO4J_URI` and `paths.neo4j_auth()` exist and are unused; `paths.GOLD_SQL_DIR` is
declared and `pipeline/gold/` does not exist. This layer is what those were for.

The team contract (`git show f3467c0:gold/README.md`) is explicit: **Gold reads Silver only,
never Bronze**, and anything built from two or more sources lives here.

## Decisions taken (confirmed with you)

| Topic | Decision |
|---|---|
| Where the graph lives | `gold.graph_node` / `gold.graph_edge` in Postgres as the contract, then a loader pushes them into Neo4j for Cypher and GDS. Testable in SQL, rebuildable without Neo4j. |
| Node types | `Stop` (metadata as properties) **plus** `School`, `LGA`, `Route` as their own nodes. Hexagons stay out — 181,492 mostly-empty nodes add nothing the stop does not already carry. |
| Edge grain | **Both**: `ROUTE_SEGMENT` per route+direction (47,047, faithful to GTFS) and `CONNECTS` per stop pair (28,340, fastest/average travel time) for GDS routing. |
| Comparison tables | One `gold.lga_comparison` across all 33 LGAs built from the data that is real, with rent as one more column where it exists. Traffic gets its own small ranking table. |

## What the data supports (measured, not assumed)

- **The four LGA spellings conform.** `bronze.rent_data.lga_name`,
  `silver.da_application.council_name`, `silver.school.lga` and
  `silver.property_sale.district_name` normalise to one key by stripping
  `The`, `Council of the`, `City of`, `Shire of`, `Municipality of` and the trailing
  `… City/Shire/Municipal Council`. Verified: all 6 rent LGAs match DA, school *and* sales;
  **32 of 33** DA councils match a sales district, **31 of 33** match a school LGA.
  (`Ryde` → `Ryde City Council`, `Sydney` → `Council of the City of Sydney`.)
- **Stops can get an LGA from the DA points.** Majority `council_name` among usable DA
  applications within 1 km of the stop: **22,565 of 23,427 stops (96.3%)**, median nearest-DA
  distance **69 m** (p90 168 m), with a median of **197 DA points** behind each choice — a
  robust majority, not a single-point guess. The 862 unassigned stops are the Illawarra /
  South Coast tail the DA file does not cover.
- **Rent is thin and that is the ceiling.** `bronze.rent_data` is 48 rows: 6 LGAs
  (Sydney, Inner West, North Sydney, Parramatta, Ryde, Canterbury-Bankstown) × 4 quarters
  (2025-10-01 … 2026-07-01) × {house, flat}. Some rows have a NULL rent with
  `reliability_flag = 'x'` (suppressed). So **only 4,568 of 23,427 stops (19.5%)** can carry
  a rent figure, and the "highest rent in Sydney" ranking compares 6 LGAs, not 33.
- **Traffic cannot reach the graph at all.** 6 synthetic segments (`SEG001`–`SEG006`), no
  coordinates, no reference file. `silver.bus_stop_traffic` is empty, so every stop's traffic
  property is NULL. The ranking table can still rank the segments: rush vehicles/hour run
  2,272 (SEG002) down to 1,241 (SEG001), with SEG004 excluded as `quality_flag = 'caution'`.
- **Routes for the `SERVES` edge are already parsed.** `silver.bus_stop.routes_served` is a
  `text[]` with ~3 routes per stop; `bronze.bus_routes` has 602 `route_id` over 592
  `route_short_name`, so `Route` nodes key on `route_id` and carry the short name.

## 1. Silver additions first (3 steps)

Gold may not read Bronze, and rent only exists in Bronze. Three new Silver steps, in the
existing `pipeline/silver/sql/` numbering and registered in `pipeline/silver/build.py`
`STEPS`:

**`60_lga.sql` → `silver.lga`** — the conformed dimension the project has been missing
(flagged as an open item when Silver was built). `lga_code` is the normalised key,
`lga_name` the display name, plus `source_da` / `source_psi` / `source_school` /
`source_rent` booleans recording which sources know this LGA. The normalisation lives in
**one** `silver.lga_key(text)` immutable SQL function so all four sources use the identical
expression — four copies of a regex is how spellings drift apart again.

**`61_rent_lga.sql` → `silver.rent_lga`** — `(lga_code, period_start, dwelling_type)`:
`median_weekly_rent`, `new_bonds_count`, `reliability_flag`,
`flag_suppressed` (a NULL rent with a flag — the value is withheld, not missing),
`flag_low_reliability`, `is_usable`. Plus `silver.rent_lga_latest`, a view picking the most
recent non-suppressed quarter per LGA × dwelling type, which is what both the graph and the
mart want.

**`22_bus_stop_lga.sql` → `silver.bus_stop_lga`** — `stop_id` PK, `lga_code`,
`assignment_method` (`da_majority_1km` | `da_nearest`), `n_da_points`,
`nearest_da_distance_m`, `flag_low_confidence` (fewer than 10 backing points, or nearest
point beyond 500 m). Sits beside the existing `bus_stop_school` / `bus_stop_da` bridges,
matching where the repo already puts per-stop bridges.

`90_bus_stop_profile.sql` gains `lga_code`, `lga_name`, `rent_median_weekly_house`,
`rent_median_weekly_flat`, `rent_period`, `has_lga_data`, `has_rent_data` — the profile is
already the one-row-per-stop table, and rent belongs on it like every other measure.

Four new check files extend the existing framework (`silver.dq_run` / `dq_result`):
`lga_key_conforms` (assert the 6 rent LGAs and ≥30 of 33 councils resolve),
`stop_lga_coverage` (≥90%, error below), `rent_suppressed_not_zero`,
`rent_period_is_latest`.

## 2. Gold: the graph

Two generic tables, so the Neo4j loader stays trivial and the graph is one object rather
than a dozen typed tables. `properties` is `jsonb` because that is exactly what a Neo4j
node takes.

`pipeline/gold/sql/10_graph_node.sql`
```sql
CREATE TABLE IF NOT EXISTS gold.graph_node (
    label      text  NOT NULL,          -- 'Stop' | 'School' | 'LGA' | 'Route'
    node_key   text  NOT NULL,          -- unique within label
    properties jsonb NOT NULL,
    geom       geometry(Point, 4326),   -- NULL for LGA and Route
    loaded_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT graph_node_pkey PRIMARY KEY (label, node_key)
);
```

| label | key | properties (from) |
|---|---|---|
| `Stop` | `stop_id` | name, lat, lon, route_count, hex_id, lga_code/name, `da_*`, `sales_*`, `n_schools_200m`, `nearest_school_distance_m`, `avg_icsea_200m`, `traffic_*`, `rent_*`, `avg_edge_travel_time_*`, and every `has_*` flag — straight off `silver.bus_stop_profile` |
| `School` | `school_code` | name, level_of_schooling, school_gender, enrolment_fte, icsea_value, town_suburb, lga_code — `silver.school` where `is_usable` |
| `LGA` | `lga_code` | name, n_stops, n_schools, median_sale_price, da_n_applications, median_rent_house/flat, has_rent_data — `gold.lga_comparison` |
| `Route` | `route_id` | route_short_name, route_long_name, agency_id, n_stops_served — `bronze.bus_routes` **via** `silver.bus_edge` (Gold reads Silver only, so the route attributes come through a small `silver.route` step added in §1 if `bus_edge` proves insufficient) |

`pipeline/gold/sql/11_graph_edge.sql`
```sql
CREATE TABLE IF NOT EXISTS gold.graph_edge (
    rel_type   text  NOT NULL,
    from_label text  NOT NULL, from_key text NOT NULL,
    to_label   text  NOT NULL, to_key   text NOT NULL,
    edge_key   text  NOT NULL,          -- disambiguates parallel edges
    properties jsonb NOT NULL,
    loaded_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT graph_edge_pkey PRIMARY KEY (rel_type, from_label, from_key,
                                            to_label, to_key, edge_key),
    CONSTRAINT graph_edge_from_fk FOREIGN KEY (from_label, from_key)
        REFERENCES gold.graph_node, -- a dangling edge is a bug, not a warning
    CONSTRAINT graph_edge_to_fk   FOREIGN KEY (to_label, to_key)
        REFERENCES gold.graph_node
);
```

| rel_type | from → to | count | properties |
|---|---|---:|---|
| `ROUTE_SEGMENT` | Stop → Stop | 47,047 | route_id, route_short_name, direction_id, peak_s, offpeak_s, n_trips, straight_line_m, `flag_zero_timepoint`, `flag_layover` |
| `CONNECTS` | Stop → Stop | 28,340 | best_peak_s, avg_peak_s, best_offpeak_s, n_routes, route_short_names[] — the GDS routing edge |
| `NEAR_SCHOOL` | Stop → School | 2,209 | distance_m, rank_from_stop, rank_from_school |
| `IN_LGA` | Stop → LGA | 22,565 | assignment_method, n_da_points, flag_low_confidence |
| `IN_LGA` | School → LGA | ~2,100 | — |
| `SERVES` | Route → Stop | ~70,000 | from `silver.bus_stop.routes_served` |

≈26,300 nodes and ≈172,000 edges — comfortable for Neo4j's 1 GB heap.

`CONNECTS` is derived by collapsing `ROUTE_SEGMENT` on `(from, to)`, taking `min()` as
`best_*` and the trip-weighted `avg()` as `avg_*`. It is **not** an average of averages: the
weighting carries through from `silver.bus_edge_travel_time`, and edges flagged
`flag_zero_timepoint` are excluded from `best_*` so a whole-minute GTFS artefact cannot
present as a 0-second hop in shortest-path results.

### Neo4j loader

`pipeline/gold/graph.py`, using the official `neo4j` driver (added to `requirements.txt`;
CI already does `pip install -r requirements.txt`, so the workflow needs no change):

1. `CREATE CONSTRAINT … IF NOT EXISTS` — one uniqueness constraint per label, which is both
   the integrity guarantee and the index every `MERGE` needs.
2. Nodes in batches via `UNWIND $rows AS r MERGE (n:Stop {stop_id: r.key}) SET n += r.props`
   — one query per label, parameterised, ~5k rows per batch.
3. Edges the same way, matching on the constraint-backed key.
4. `--reset` drops the graph first (`MATCH (n) DETACH DELETE n` in batches) for a clean rebuild.
5. Idempotent: `MERGE` + `SET +=` means re-running converges rather than duplicating.

Separate module from `build.py` so Gold's SQL still builds when Neo4j is down, and
`python -m pipeline.gold.graph` can reload the graph alone.

## 3. Gold: the comparison marts

**`gold.lga_comparison`** — one row per LGA (33), the mart that answers "compare them in
Sydney". Built from Silver only:

```
lga_code, lga_name,
n_stops, n_stops_low_confidence, n_schools, avg_icsea, sum_enrolment_fte,
n_sales, median_sale_price, median_price_per_m2, p25_price, p75_price,
da_n_applications, da_n_modifications, da_sum_new_dwellings, da_median_cost,
median_rent_weekly_house, median_rent_weekly_flat, rent_period, rent_new_bonds,
avg_route_count, avg_edge_travel_time_peak_s, n_schools_per_1000_stops,
-- ranks, so "highest/most" is a column not a client-side sort
rank_median_sale_price, rank_median_rent_house, rank_da_applications, rank_n_stops,
has_rent_data, has_sales_data
```

Rent populates for 6 of 33 rows; `has_rent_data` is why that is visible rather than
mistakable for zero. Medians use `percentile_cont` over the underlying sales, never an
average of hexagon medians.

**`gold.traffic_ranking`** — one row per segment, `daypart_kind` pivoted:
`segment_id`, `avg_vph_rush`, `avg_vph_non_rush`, `avg_vph_night`,
`rush_to_night_ratio`, `peak_hour_of_day`, `n_days_observed`,
`rank_rush`, `flag_sample_data`, `flag_no_geometry`, `n_stops_500m` (0 until a segment
reference exists). Deliberately small and deliberately flagged: ranking 6 synthetic
segments is all the data supports, and the table says so in its own columns.

## 4. Code to write

| File | Purpose |
|---|---|
| `pipeline/gold/__init__.py` | new package |
| `pipeline/gold/build.py` | runner, same `STEPS`/`Step` shape as `pipeline/silver/build.py`, one transaction per step, `--reset` supported |
| `pipeline/gold/graph.py` | Neo4j loader (above) |
| `pipeline/gold/sql/00_schema.sql` | `CREATE SCHEMA gold` |
| `pipeline/gold/sql/{10_graph_node,11_graph_edge,20_lga_comparison,21_traffic_ranking}.sql` | as above; `20` runs **before** `10` because the `LGA` node reads the mart |
| `pipeline/gold/sql/checks/*.sql` | gold checks in the existing result shape |
| `pipeline/silver/sql/{22_bus_stop_lga,60_lga,61_rent_lga}.sql` + 4 check files | §1 |
| `pipeline/silver/sql/90_bus_stop_profile.sql` | add the LGA and rent columns |
| `pipeline/silver/build.py` | register the 3 new steps |
| `pipeline/silver/quality.py` | take a layer argument so it runs `silver/sql/checks` **and** `gold/sql/checks` into the same `dq_run`; move to `pipeline/quality.py` since it now serves both layers |
| `pipeline/run.py` | add `gold.build.run()` then `gold.graph.load()` after silver, before the quality gate |
| `test/gold_integrity.py` | node/edge counts, no dangling edges, `CONNECTS` collapses `ROUTE_SEGMENT` correctly, Postgres-vs-Neo4j parity |
| `requirements.txt` | `+ neo4j>=5.0` |
| `README.md` | gold section, Cypher examples, updated gaps |

**Idempotency**, as in Silver: `gold.*` is fully derived, so each step is `DELETE` +
`INSERT` inside its transaction; Neo4j uses `MERGE` + `SET +=`. No `TRUNCATE`.

## 5. Gold quality checks

Same framework, written into the same `silver.dq_run` so one run covers both layers.

| Check | Severity | Rule |
|---|---|---|
| `node_key_unique` | error | per label, `node_key` unique (the PK, re-asserted because Neo4j's constraint depends on it) |
| `no_dangling_edges` | error | every `from`/`to` resolves to a node — enforced by FK, checked so the failure is reported not just raised |
| `stop_nodes_match_silver` | error | `count(Stop) = count(silver.bus_stop)` = 23,427 |
| `route_segment_count` | error | `count(ROUTE_SEGMENT) = count(silver.bus_edge)` = 47,047 |
| `connects_collapses_correctly` | error | `count(CONNECTS)` = distinct `(from,to)` in `bus_edge`; every `best_peak_s` equals the `min` over its members |
| `connects_excludes_zero_timepoint` | error | no `best_peak_s = 0` |
| `no_self_loop` | error | `from_key <> to_key` on both stop-to-stop types |
| `graph_connectivity` | warn | largest weakly-connected component covers ≥90% of stops with service — a fragmented graph breaks every routing query, and 69 stops legitimately have no edge |
| `lga_comparison_covers_all` | error | 33 rows, one per `silver.lga` with stops |
| `lga_rent_coverage` | warn | 6 of 33 — recorded, with `has_rent_data` asserted consistent |
| `lga_medians_plausible` | error | `median_sale_price` within 100k–20M per LGA |
| `traffic_ranking_is_sample` | warn | ≤10 segments ⇒ "sample data, not a real extract" |
| `neo4j_parity` | error | (in `test/gold_integrity.py`) node and edge counts per label/type identical in Postgres and Neo4j |

## 6. Verification

1. `python -m pipeline.run` — bronze → silver → gold → Neo4j → quality gate, exit 0.
2. `python -m test.data_completness`, `python -m test.silver_integrity`,
   `python -m test.gold_integrity` — all must pass.
3. `pylint $(git ls-files '*.py')` at 10.00/10, as CI runs it.
4. Postgres spot-checks:
   - `SELECT label, count(*) FROM gold.graph_node GROUP BY 1` → Stop 23,427 / School ~2,210
     / LGA 33 / Route ~602
   - `SELECT rel_type, count(*) FROM gold.graph_edge GROUP BY 1` → ROUTE_SEGMENT 47,047,
     CONNECTS 28,340, IN_LGA 22,565 + ~2,100, NEAR_SCHOOL 2,209, SERVES ~70,000
   - `SELECT lga_name, median_rent_weekly_house, median_sale_price, da_n_applications
      FROM gold.lga_comparison ORDER BY rank_median_rent_house NULLS LAST LIMIT 10`
     — the "highest rent" answer, with context columns
   - `SELECT * FROM gold.traffic_ranking ORDER BY rank_rush` — SEG002 first at ~2,272 vph
5. Neo4j, at `http://localhost:7474` (credentials via `grep PASSWORD .env`):
   ```cypher
   MATCH (n) RETURN labels(n)[0] AS label, count(*) ORDER BY 2 DESC;

   // a stop and everything attached to it
   MATCH (s:Stop {stop_id: '201023'})-[r]-(x)
   RETURN type(r), labels(x)[0], count(*) ORDER BY 3 DESC;

   // schools served by more than one stop - a traversal, not a join
   MATCH (sc:School)<-[:NEAR_SCHOOL]-(s:Stop)
   WITH sc, count(s) AS stops WHERE stops > 5
   RETURN sc.name, stops ORDER BY stops DESC LIMIT 5;

   // fastest timetabled path between two stops, using GDS on CONNECTS
   MATCH (a:Stop {stop_id: '201023'}), (b:Stop {stop_id: '212214'})
   CALL gds.shortestPath.dijkstra.stream('busgraph', {
     sourceNode: a, targetNode: b, relationshipWeightProperty: 'best_peak_s'})
   YIELD totalCost RETURN totalCost / 60 AS minutes;
   ```
   Expect `Liverpool Public School` near the top of the shared-school query — Silver already
   showed it reaching 13 stops within 200 m.
6. Metabase (`localhost:3000`): `gold.lga_comparison` as a bar chart of rent vs median sale
   price, and `gold.graph_node` filtered to `Stop` plotted on a map coloured by `lga_code` —
   a wrong LGA assignment is obvious on a map and invisible in a count.

## Open items

- **Traffic never reaches the graph.** Every `Stop.traffic_*` property is NULL and
  `gold.traffic_ranking` ranks 6 synthetic segments, because nothing on disk locates
  `SEG001`–`SEG006`. The TfNSW segment reference is the single file that fixes both.
- **Rent reaches 19.5% of stops.** 6 of 33 LGAs have data, and it is quarterly LGA-level, so
  even where present it is a neighbourhood average, not a property-level rent.
- **`Route` node attributes come from `bronze.bus_routes`.** Gold may not read Bronze, so
  either a thin `silver.route` step is added in §1 (preferred, ~602 rows) or Route nodes
  carry only what `silver.bus_edge` already has (`route_id`, `route_short_name`). I will add
  the Silver step — it is small and keeps the contract intact.
- **Bitemporality (contract C2, weighted 25%)** remains type-1 throughout, unchanged by this
  layer. Worth raising with the team separately, since the assignment spec asked for a Data
  Vault Silver.
