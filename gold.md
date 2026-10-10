# Gold layer

Gold is the layer the website and the graph queries read from. It reads Silver
only, never Bronze, and anything built from two or more sources lives here.

## Build

```bash
python -m pipeline.gold.build            # all gold SQL steps
python -m pipeline.gold.build --reset    # drop the gold schema first
python -m pipeline.gold.graph            # load the graph into Neo4j
python -m pipeline.gold.graph --reset    # wipe the Neo4j graph first
```

`python -m pipeline.run` runs these after Silver, then runs the Silver and Gold
quality checks together in one `silver.dq_run`.

Every gold table is fully derived, so each step deletes and re-inserts inside
one transaction. The Neo4j load uses `MERGE` + `SET +=`, so re-running it gives
the same graph instead of duplicates.

Steps run in this order (`pipeline/gold/build.py`):

| Step | Table | Rows |
|---|---|---:|
| `00_schema.sql` | schema `gold` | - |
| `10_lga_comparison.sql` | `gold.lga_comparison` | 33 |
| `11_traffic_ranking.sql` | `gold.traffic_ranking` | 6 |
| `12_suburb_comparison.sql` | `gold.suburb_comparison` | 776 |
| `20_graph_node.sql` | `gold.graph_node` | 25,139 |
| `21_graph_edge.sql` | `gold.graph_edge` | 147,406 |
| `22_connects_edge.sql` | `gold.connects_edge` | 28,340 |
| `30_address_point.sql` | `gold.address_point` | 147,561 |
| `31_transit_segment.sql` | `gold.transit_segment` | 28,340 |

`lga_comparison` runs before the graph because the `LGA` nodes read their
properties from it.

## The graph

The graph is stored twice. `gold.graph_node` and `gold.graph_edge` in Postgres
are the source of truth, and `pipeline/gold/graph.py` copies them into Neo4j for
Cypher and GDS. Keeping it in Postgres means it can be checked in SQL and still
builds when Neo4j is down.

Both tables are generic: a label (or relationship type), a key, and a `jsonb`
`properties` column, because that maps directly onto a Neo4j node or
relationship. Edges have foreign keys to `gold.graph_node`, so an edge pointing
at a missing node fails the build.

Bus stops are the main nodes and carry their own metadata. Schools, LGAs and
routes are nodes too, so questions like "which stops share a school" or "every
stop in this LGA" are traversals rather than joins.

### Nodes

| Label | Key | Count | Properties come from |
|---|---|---:|---|
| `Stop` | `stop_id` | 23,427 | `silver.bus_stop_profile`: rent, sales, DA activity, schools nearby, traffic, travel times, and every `has_*` flag |
| `School` | `school_code` | 1,077 | `silver.school`, usable rows only |
| `LGA` | `lga_code` | 33 | `gold.lga_comparison` |
| `Route` | `route_id` | 602 | `silver.route` |

### Relationships

| Type | From → To | Count | Used for |
|---|---|---:|---|
| `ROUTE_SEGMENT` | Stop → Stop | 47,047 | one edge per route and direction, with that route's own timings |
| `CONNECTS` | Stop → Stop | 28,340 | routing; one edge per stop pair |
| `NEAR_SCHOOL` | Stop → School | 2,209 | schools within 200 m of a stop |
| `IN_LGA` | Stop → LGA | 22,599 | every stop in an LGA |
| `IN_LGA` | School → LGA | 946 | every school in an LGA |
| `SERVES` | Route → Stop | 46,265 | which stops a route serves |

`CONNECTS` is `ROUTE_SEGMENT` collapsed on `(from, to)`. `best_*` is the minimum
over the routes and `avg_*` is the trip-weighted average, not an average of
averages. Segments flagged `flag_zero_timepoint` are left out of `best_*`, so a
whole-minute rounding artefact in the timetable cannot show up as a 0-second
hop.

`travel_time_s` is the routing weight. It is never NULL or zero, because GDS
handles both badly: a missing weight turns the path cost into NaN, and a zero
weight is a free hop. It falls back in this order:

`best_peak` → `avg_peak` → `best_offpeak` → `avg_offpeak` → straight-line
distance at 20 km/h

`weight_source` on each edge records which one was used. In the current build
that is 23,641 `best_peak`, 2,816 `best_offpeak` and 1,883 `distance_estimate`.

### Loading into Neo4j

`graph.py` uses the official `neo4j` driver:

1. One uniqueness constraint per label. The constraint also creates the index
   that every `MERGE` matches on.
2. Nodes are written with `UNWIND $rows ... MERGE ... SET n += row.props`, one
   query per label, in batches of 5,000.
3. Relationships are written the same way. `edge_key` is part of the `MERGE`
   pattern so parallel `ROUTE_SEGMENT` edges between the same two stops are kept.
4. `--reset` deletes the existing graph in batches before loading.

Example queries (Neo4j Browser at http://localhost:7474, password via
`grep NEO4J_PASSWORD .env`):

```cypher
// one stop and everything attached to it
MATCH (s:Stop {node_key: '201023'})-[r]-(x)
RETURN type(r), labels(x)[0], count(*) ORDER BY 3 DESC;

// schools near more than five stops
MATCH (sc:School)<-[:NEAR_SCHOOL]-(s:Stop)
WITH sc, count(s) AS stops WHERE stops > 5
RETURN sc.school_name, stops ORDER BY stops DESC LIMIT 5;

// fastest timetabled trip between two stops
CALL gds.graph.project('busgraph', 'Stop',
     {CONNECTS: {properties: 'travel_time_s'}});
MATCH (a:Stop {node_key: '201023'}), (b:Stop {node_key: '212214'})
CALL gds.shortestPath.dijkstra.stream('busgraph',
     {sourceNode: a, targetNode: b, relationshipWeightProperty: 'travel_time_s'})
YIELD totalCost RETURN totalCost / 60 AS minutes;
```

## Comparison tables

**`gold.lga_comparison`**, one row per LGA (33). Stop counts, schools and
ICSEA, sale prices (median, per m², p25/p75), DA counts and costs, and weekly
rent for houses and flats. It has `rank_*` columns so "highest rent" or "most
development" is a lookup. Medians are `percentile_cont` over the underlying
sales, not averages of hexagon medians.

Rent only exists for 6 of the 33 LGAs. `has_rent_data` marks those rows so a
NULL rent is not read as a low one, and `n_ranked_rent` gives the denominator for
the rent rank.

The four sources spell LGA names differently (`Parramatta`,
`City of Parramatta Council`, `PARRAMATTA`, `BAYSIDE (NSW)`). They all go through
one function, `silver.lga_key()`, which strips prefixes and suffixes like
`City of` and `Council`.

**`gold.suburb_comparison`**, one row per locality with at least 30 usable
sales (776 localities). Median price, median price per m², and 5-year change,
each with a rank and the number of suburbs ranked. Suburbs are the level people
actually compare at; an LGA like City of Sydney covers Ultimo, Newtown and
Redfern at once.

**`gold.traffic_ranking`**, one row per traffic segment (6). Vehicles per hour
for rush, non-rush and night, ranked on rush hour. `flag_sample_data` and
`flag_no_geometry` are set on every row, because the source is a 3-day sample of
6 segments with no coordinates.

### Is that a lot?

A rank says where a place sits but not how far apart places are, so both
tables also carry the gap to a reference value in percent:

| Table | Columns | Compared against |
|---|---|---|
| `lga_comparison` | `sale_price_vs_sydney_pct` | median of every usable Sydney sale (`sydney_median_sale_price`, $985,000) |
| `lga_comparison` | `rent_house_vs_ref_pct`, `rent_flat_vs_ref_pct` | median of the 6 LGAs with rent data (`ref_rent_weekly_house` $770, `ref_rent_weekly_flat`) |
| `suburb_comparison` | `price_vs_sydney_pct`, `price_per_m2_vs_sydney_pct` | Sydney median price and price per m² |
| `suburb_comparison` | `price_percentile`, `price_per_m2_percentile` | other ranked suburbs, 0 = cheapest, 100 = dearest |

So North Sydney's $1,130 a week for a house is 47% above the rent reference,
and Ultimo is 24% below the Sydney median on price but 307% above it per m².
Rent has no Sydney-wide figure in this data, which is why its reference is the
6 covered LGAs and the report says so. The report shows these under each rank.

## Website tables

**`gold.address_point`** is the address lookup (147,561 points): 120,995 exact
DA addresses (`accuracy_m = 0`) and 26,566 street centres, where `accuracy_m` is
that street's measured spread. A trigram index on `search_key` drives the
autocomplete.

**`gold.connects_edge`** is a plain relational copy of the `CONNECTS` edges with
separate peak and off-peak times. The website's 20-minute reach search runs as a
recursive query over this table in Postgres, which is much faster than one GDS
Dijkstra per nearby stop. A quality check makes sure it matches `graph_edge`.

**`gold.transit_segment`** has one row per stop pair with its line geometry and
scheduled trips per day, split into five activity bands (`ntile(5)`). The report
uses it as a street-activity measure, since there is no noise data.

## Quality checks

Gold checks live in `pipeline/gold/sql/checks/` and write to the same
`silver.dq_run` as the Silver checks. They cover:

- **Graph shape:** keys unique per label, no dangling edges, no self-loops,
  stop nodes and `ROUTE_SEGMENT` counts matching Silver.
- **Routing:** `CONNECTS` collapses `ROUTE_SEGMENT` correctly, `best_*` is the
  real minimum, no zero-timepoint segments in `best_*`, and `travel_time_s` is
  never NULL.
- **Comparison tables:** one row per LGA, plausible medians, correct rank
  denominators, minimum sales enforced for suburbs, and every "x% above/below"
  figure present and pointing the same way as its value.
- **Website tables:** both address precisions present, geometry present,
  `connects_edge` matches the graph.

`test/gold_integrity.py` also checks that node and relationship counts in
Neo4j match Postgres.

## Known gaps

- **Traffic does not reach the graph.** The 6 segments (`SEG001`–`SEG006`) have
  no coordinates, so every `Stop` traffic property is NULL. A TfNSW segment
  reference file would fix both this and the traffic ranking.
- **Rent covers 19.5% of stops.** Only 6 LGAs have data, and it is quarterly at
  LGA level, so even where it exists it is an area average.
- **828 stops have no LGA.** LGA is inferred from nearby DA applications, and
  the Illawarra / South Coast stops are too far from any DA to assign one.
- **Silver is not bitemporal.** History is overwritten (type 1). The assignment
  asked for a Data Vault Silver, so this needs a team decision.
