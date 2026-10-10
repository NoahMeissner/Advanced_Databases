# Suburblens

A medallion pipeline over NSW open data, with **Sydney bus stops as the reference
point**: every source is reduced to a per-stop measure so one table answers
"what is happening around this stop" — plus a website that turns an address into
a one-page report and a map.

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
| Gold | `pipeline/gold/` | `gold` + Neo4j | The serving layer: one graph, the comparison marts, and the tables the site reads. Reads Silver only, never Bronze |
| Website | `web/` | — | Address → report + map. Reads Gold and Silver through one `get_report()` function |

```bash
python -m pipeline.run                 # every layer, then the quality checks
python -m pipeline.run rent_data       # one bronze source
python -m pipeline.run stop_profile    # one silver step
python -m pipeline.run graph_node      # one gold step
python -m pipeline.run --skip-graph    # everything except the Neo4j load

python -m pipeline.silver.build        # silver only   (--reset to drop the schema)
python -m pipeline.gold.build          # gold SQL only (--reset to drop the schema)
python -m pipeline.gold.graph          # (re)load the graph into Neo4j
python -m pipeline.gold.graph --reset  # wipe the Neo4j graph first

python -m pipeline.quality             # all checks   (or: ... quality gold)
python -m test.data_completness        # bronze: file rows == table rows
python -m test.silver_integrity        # silver: keys, joins, and the school oracle
python -m test.gold_integrity          # gold: graph soundness + Postgres/Neo4j parity
python -m test.web_smoke               # site: routes, geocoder, and agreement with SQL
```

## The website

```bash
./start.sh                             # databases
python -m pipeline.run                 # load everything (once)
python -m web.app                      # http://127.0.0.1:5000
```

| Screen | What it does |
|---|---|
| `/` | Type an address. Autocomplete over 147,561 points, trigram-ranked |
| `/report?address=…&at=HH` | The A4 page: schools, street activity, commute, market. "Download PDF" is the browser's own print; the A4 sheet is the print target (`@page { size: A4 }`) |
| `/map?address=…&at=HH` | The same findings as four toggleable Leaflet layers |

`?at=HH` is the time of day. It changes the reachable area and the trip to
Central, and the URL carries it so a link reproduces exactly what you saw.

Built from the design handoff in `design/`. `DESIGN.md` is the spec and
`design/tokens.css` is copied verbatim into `web/static/` as the single source
of every colour, size and radius.

### Printing the report on one A4 page

"Download PDF" is the browser's own print; the A4 sheet on screen is the print
target. Getting that to produce one page needed three fixes, and the first did
most of the work:

1. **The responsive breakpoint also matched the paper.** A4 is ~794 px wide at
   96 dpi, so an unscoped `@media (max-width: 860px)` applied when printing:
   the 2×2 grid collapsed to one column and the report ran to two pages. The
   responsive block is now `@media screen and (...)`, and the print block
   re-asserts the grid explicitly.
2. **Chrome drops background colours** unless the user ticks "Background
   graphics", so the section dots, the activity gradient and the rule under the
   header printed as blank gaps. Fixed with `print-color-adjust: exact`.
3. **`@page { margin: 0 }` left nowhere** for Chrome's own URL/date/page-number
   furniture, which then printed over the report. Now `margin: 12mm 14mm`.

Measured afterwards across five addresses of different lengths, against the
1,032 px a printed A4 actually offers:

| Address | Printed height | Headroom |
|---|---:|---:|
| Harris Street, Ultimo | 959 px | 73 px |
| 59 Enmore Road, Newtown | 959 px | 73 px |
| 1 Pitt Street, Sydney | 959 px | 73 px |
| McEvoy Road, Padstow | 918 px | 114 px |
| Richards Road, Appin | 873 px | 159 px |

The compaction is light (body text stays at the design's 13 px) because the
breakpoint fix did most of the work. `web/static/print.js` covers anything
unusual: it measures on `beforeprint` and scales only if a particularly full
report would still overflow.

Everything on screen comes from `web/report.py:get_report()`. Templates never
query the database, so the report and the map cannot disagree, and
`test/web_smoke.py` re-runs the same figures straight against `silver` to check
the page matches the warehouse.

### Section 02: street activity instead of noise

The design's second section is Noise (decibels, nearest main road, heat bands).
This project has no noise data and no road centrelines, and its traffic
source is six synthetic segments with no coordinates. Rather than invent
decibels, section 02 reports scheduled bus traffic on real geometry
(`gold.transit_segment`, 28,340 segments, 1–1,279 trips/day) as a street-activity
proxy, and says so on the page.

### Reach is seeded from every nearby stop

The first version started the 20-minute search at the single closest stop. For
`HARRIS STREET, ULTIMO` that is *Harris St At Macarthur St*, 16 m away and served
by one route, while 28 stops within 800 m serve 41 routes, including
UTS Broadway (15 routes) and Central Station (30 routes), both ~520 m away.

The search now starts from every stop in walking distance, each seeded with
the time it takes to walk there. For Ultimo that gives 286 reachable stops
instead of 28, 10× more network.

It also moved from Neo4j to Postgres, because multi-source means one Dijkstra
per seed in GDS:

| Approach | 20-min reach | Time |
|---|---:|---:|
| Neo4j GDS, 28 separate Dijkstras | 286 stops | 3.10 s |
| Neo4j GDS, one `UNWIND` statement | 286 stops | 3.51 s |
| **Postgres recursive CTE over `gold.connects_edge`** | **286 stops** | **0.03 s** |

Batching the Cypher does not help: the cost is the 28 full traversals, not the
round-trips. Neo4j still holds the graph for Cypher and GDS; `gold.connects_edge`
is a relational projection of the same edges, and a quality check asserts the two
cannot drift.

### Time of day

The hour picker maps onto the two service bands the data has. There is no raw
GTFS feed, so hourly detail does not exist and the caption always names the band
an hour resolved to. The bands matter: travel times differ by only ~6%,
but 1,703 stop pairs run at peak only and 2,375 off-peak only, so changing
band changes which connections exist. Ultimo reaches 172 stops at 08:00 and 420
at 14:00.

Waiting and transfer time are not counted. Frequency data exists, but the
band window lengths were lost upstream, so turning trip counts into minutes would
be invention.

### Rankings

`gold.suburb_comparison` ranks 776 suburbs (every locality with ≥30 usable
sales) on median price, price per m² and 5-year growth. Rent ranks separately, out
of 6 LGAs, because that is all the rent data covers; the denominator is
always printed next to the rank.

Both price measures are published because they disagree:

| | Ultimo | Newtown | Mosman | Blacktown |
|---|---:|---:|---:|---:|
| median price | $750k · **682nd** | $1.46m · 268th | $2.59m · 75th | $780k · 659th |
| price per m² | $13,289 · **45th** | $12,762 · 52nd | $11,512 · 64th | $2,076 · 491st |

Ultimo looks like one of Sydney's cheaper suburbs by median and one of its dearest
per square metre, because it is mostly small apartments. The report raises that
automatically as a caveat whenever the two ranks diverge by more than 200 places.

### The development layer

The layer uses square markers, not circles: DESIGN.md §7 requires a layer to be identifiable
without relying on colour, and the schools are already circles. The fifth colour
(`--layer-development`, brick red) is defined in `web/static/app.css`, not in
`tokens.css`, so that file stays the handoff's own copied verbatim.

Within 1 km of a city address there are ~1,878 applications, so plotting all of
them would be unreadable. The layer shows the ~57 still in the pipeline solid,
plus determined ones over $1m (~300) faint. Marker size is √cost, so a $200m
tower reads bigger than a $2m renovation without swallowing the block.

The scopes differ on purpose and each is labelled: the report's investment
figure covers the ~900 m hexagon neighbourhood, the map layer covers 1 km.

### Development investment

The Market section splits the **pipeline** (Under Assessment, Additional
Information Requested, Deferred Commencement, Pending Lodgement, On Exhibition)
from what is **already determined**. Only the pipeline is forward-looking: a
determined 2019 application describes what already happened. Sydney-wide that is
6,633 applications worth $27.2 bn against 154,477 determined worth $238.8 bn.

### Geocoding without G-NAF

`gold.address_point` is the gazetteer: 120,995 exact development-application
addresses (`accuracy_m = 0`) plus 26,566 street centres (`accuracy_m` = that
street's own measured spread, floored at 50 m). Two guards apply:

- Typing a house number we do not have falls back to the **street centre** rather
  than snapping to a neighbour's house and claiming exact precision.
- A query that scores below 0.50 trigram similarity returns nothing. Real
  queries score 0.63–1.00; an invented street scores 0.37.

The precision used is shown in the suggestion list, on the map, and in the
report's caveats.

`python -m pipeline.run` exits non-zero if an `error`-level quality check fails,
so a broken load cannot pass silently. Silver and Gold checks share one
`dq_run`, because a Gold number is only trustworthy if the Silver under it is.

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

## The graph

`gold.graph_node` and `gold.graph_edge` in Postgres are the contract;
`pipeline/gold/graph.py` projects them into Neo4j for Cypher and GDS. The graph
is therefore checkable in SQL and still builds when Neo4j is down.

| Node | Key | Count | Carries |
|---|---|---:|---|
| `Stop` | `stop_id` | 23,427 | the whole per-stop profile as properties - rent, sales, DA activity, schools nearby, traffic, travel times |
| `School` | `school_code` | 1,077 | name, level, enrolment, ICSEA |
| `LGA` | `lga_code` | 33 | the whole `gold.lga_comparison` row |
| `Route` | `route_id` | 602 | short/long name, agency, headsigns |

| Relationship | | Count | Use it for |
|---|---|---:|---|
| `ROUTE_SEGMENT` | Stop→Stop | 47,047 | which routes link two stops, with each route's own timings |
| `CONNECTS` | Stop→Stop | 28,340 | routing. One per stop pair, carrying `travel_time_s` |
| `NEAR_SCHOOL` | Stop→School | 2,209 | a school within 200 m - many stops per school |
| `IN_LGA` | Stop/School→LGA | 23,545 | everything in an LGA, and the rent comparison |
| `SERVES` | Route→Stop | 46,265 | which stops a route serves |

`travel_time_s` is the routing weight and is never NULL or zero. Both would
break GDS silently: a missing property projects as NaN and propagates along the
path (Dijkstra then returns NaN and picks a distorted route), and a 0-weight
edge is a free hop. It falls back
`best_peak → avg_peak → best_offpeak → avg_offpeak → distance at 20 km/h`, and
`weight_source` on every edge says which was used (83% real peak timings, 6.6%
distance-estimated).

```cypher
// one stop, everything around it
MATCH (s:Stop {node_key: '201023'}) RETURN s;

// schools shared by several stops - a traversal, not a join
MATCH (sc:School)<-[:NEAR_SCHOOL]-(st:Stop)
WITH sc, count(st) AS stops WHERE stops > 5
RETURN sc.school_name, stops ORDER BY stops DESC;

// fastest timetabled journey, via GDS
CALL gds.graph.project('busgraph', 'Stop',
     {CONNECTS: {properties: 'travel_time_s'}});
MATCH (a:Stop {node_key: '201023'}), (b:Stop {node_key: '212214'})
CALL gds.shortestPath.dijkstra.stream('busgraph',
     {sourceNode: a, targetNode: b, relationshipWeightProperty: 'travel_time_s'})
YIELD totalCost RETURN totalCost / 60 AS minutes;
```

Neo4j Browser: http://localhost:7474 (`grep NEO4J_PASSWORD .env`).

## Comparison marts

| Table | Grain | Answers |
|---|---|---|
| `gold.lga_comparison` | 33 LGAs | highest rent, most development, dearest sales, most stops - with `rank_*` columns so "highest" is a column, not a client-side sort |
| `gold.traffic_ranking` | 6 segments | most traffic by rush / non-rush / night |

`gold.lga_comparison` and `gold.suburb_comparison` also carry the gap to a reference in percent (`sale_price_vs_sydney_pct`, `rent_house_vs_ref_pct` / `rent_flat_vs_ref_pct` against the median of the 6 LGAs with rent, `price_vs_sydney_pct`, `price_per_m2_vs_sydney_pct`) plus a 0-100 percentile on suburbs (`price_percentile`, `price_per_m2_percentile`), and the report shows it under each rank, e.g. "24% below the Sydney median".

`silver.lga` is the conformed LGA dimension these rest on. Four sources spell
the same LGA four ways (`Parramatta` / `City of Parramatta Council` /
`PARRAMATTA` / `BAYSIDE (NSW)`); `silver.lga_key()` is the single function they
all go through, and all 33 councils resolve to a key the sales districts and
school LGAs also produce.

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
| Rent is LGA-level and tiny | 48 rows, 6 LGAs | So only **4,568 of 23,427 stops (19.5%)** carry a rent figure, and "highest rent in Sydney" compares 6 LGAs, not 33. `has_rent_data` is why a NULL cannot be read as cheap |
| Stop to LGA is inferred, not surveyed | 22,599 of 23,427 | No LGA boundary polygons on disk, so the LGA is the majority council among DA applications within 1 km (median 197 points behind each choice, nearest 69 m). 828 Illawarra / South Coast stops get **no** LGA rather than a wrong one - the nearest council was up to 113 km away |
| A suppressed rent is not a cheap rent | some quarters | `reliability_flag = 'x'` means the publisher withheld it; `flag_suppressed` keeps that apart from missing |
