# NSW Valuer General property sales (PSI)

Owner: Kang Donghyun (Brian). Source #1 in Assignment 1, Appendix 7.1.

Pipeline that takes the Valuer General's bulk Property Sales Information from raw
zips to a Data Vault in PostgreSQL. It is scoped to **Greater Sydney** and
**archives published from 2021 onward** (see the scope note below).
Only the Python standard library is used.

```
Bronze  weekly zips ──extract──▶ landing (1 CSV per week, every B record, lineage)
                                data/bronze/property_sales/{raw,landing}/
Silver  landing ──transform──▶ sale_versions + sales_current (versioned, typed, flagged)
        sales_current ──street_prices──▶ street_prices (average price per street)
                                data/silver/property_sales/
        sale_versions ──psi_load.sql──▶ Postgres raw vault: hubs / link / satellites + views
```

## Run it

```bash
# from the repo root
python -m sources.property_sales.bronze.download      # tries each zip; writes manual_download.html for the rest
python -m sources.property_sales.bronze.extract       # --region greater_sydney (default) | gsc33 | nsw
python -m sources.property_sales.silver.transform
python -m sources.property_sales.silver.street_prices
python -m sources.property_sales.quality.psi_profile --out data/reports/property_sales/profile.md
python -m sources.property_sales.quality.dashboard    # -> data/reports/property_sales/dashboard.html

psql -d suburblens -f sources/property_sales/sql/psi_schema.sql
psql -d suburblens -f sources/property_sales/sql/psi_load.sql
```

All data goes under `data/`, which is git-ignored. **Downloads are blocked for
scripts.** Since mid-2026 the Valuer General site uses Cloudflare bot
protection, so `download` gets HTTP 403. Open the generated
`data/bronze/property_sales/raw/manual_download.html` in a browser, click through the
links, save the zips into `data/bronze/property_sales/raw/`, and run `extract`.

**The raw store is one zip per week** (`raw/YYYYMMDD.zip`, 300 files from
2021-01-04 to 2026-09-28, 77 MB), byte-for-byte what the Valuer General
published each Monday. Past years are only offered as yearly bundles, so
`download` and `extract` split any `YYYY.zip` they find into its weekly zips.
Each bundle's sha256 and members are logged in `raw/_bundles.csv`, and the
bundle is then removed. Re-saving a bundle that's already been split is a
no-op. If a weekly file already exists with different content, the split
stops instead of overwriting raw data. A new week is just one more file: drop
it in and re-run `extract`, which only processes weeks it hasn't seen (by
sha256).

Runtime on a laptop for all 300 weeks: extract takes about 20 s,
transform about 2 min, and the Postgres load about 2 min.

`dashboard` (about 25 s) writes one self-contained HTML page. It includes monthly
medians, a deck.gl 3D map of localities, district medians and growth, publication lag,
as-of cohort curves (what was known about a contract quarter N weeks later), and
restatements by publication file. Only aggregates are inlined, never individual
sales. Localities are placed at their NSW POI gazetteer point, cached in
`data/reports/property_sales/places.json` on first run, or at their postcode centroid when
the gazetteer has no match. Open the page in a browser; the map needs the CDN scripts
(serve with `python -m http.server` if your browser blocks them on `file://`).

## Silver: average price per street (`street_prices`)

`data/silver/property_sales/street_prices.csv.gz` has one row per **street ×
property type × period**. On archives to 2026-09-28 it covers 649,604 standard
sales on 46,328 streets (502,961 rows).

| Column | Meaning |
|---|---|
| `street_id` | `street_name_core\|street_type_code\|street_suffix_code\|locality\|postcode`. This is the G-NAF `STREET_LOCALITY` grain: the same name in two suburbs is two streets, and `RD` and `ROAD` are one |
| `street_label` | e.g. `BONDI ROAD, BONDI NSW 2026` |
| `district_code`, `district_name` | PSI district (≈ LGA) with the most sales on the street |
| `property_type` | `house` (non-strata residence), `unit` (strata residence), `land` (vacant), `other` (commercial, industrial, car space, …), or `all` |
| `period` | Contract year, or `all` |
| `sales` | Standard sales behind the figures (one parcel, whole interest, price ≥ $1k) |
| `mean_price`, `median_price`, `min_price`, `max_price` | AUD |
| `first_contract_date`, `last_contract_date` | Range of contract dates behind the row |
| `as_of` | Latest publication date in the input: what we knew when the table was built |

Read it with care:

- **Mean vs median.** Prices are skewed, and one commercial or trophy sale drags
  the mean. For example, Christie Street, St Leonards (2025, `all`) has a mean of
  $2.66M and a median of $1.35M. Use `median_price` and a specific
  `property_type` for "typical price".
- **Small samples.** The median street has 6 standard sales across all years,
  and only 15,855 streets have 10 or more. Filter on `sales` before comparing
  streets.
- **Recent years are incomplete** (see Known data gaps), so compare a street's
  `2026` row with other streets' `2026` rows, not with its own `2025`.
- 1,348 standard sales have no street name or locality and aren't counted.

## The source

| | |
|---|---|
| Publisher | Valuer General NSW (Valuation NSW), from Notices of Sale lodged with NSW Land Registry Services |
| Access | `https://www.valuergeneral.nsw.gov.au/__psi/yearly/YYYY.zip` (past years, a bundle of that year's weekly zips), `.../weekly/YYYYMMDD.zip` (each Monday, current year) |
| Format | Weekly zips of `;`-delimited `.DAT` files, one per district per week, no headers. Spec: *Current Property Sales Data File Format 2001 to Current* |
| Licence | `creative_commons.txt` inside every zip is **CC BY**; the nsw.gov.au web page says CC BY-NC-ND. We attribute, don't redistribute the data, and keep raw data out of git |
| Grain | One B record per parcel per sale. There is no lat/lon, so location comes from the address or from lot/plan |
| Freshness | Weekly. First published a median **7 days after settlement** (**52 days after contract**; 90th pct 193, due to off-the-plan sales) |

Record types: `A` header, `B` sale/property (25 fields, layout in
`psi_format.py`), `C` legal description (1+ chunks per B, concatenated **without
spaces**), `D` owner (names suppressed), `Z` trailer with line and record counts.
The C→B join key `(district, property id, sale counter)` is **only unique within
one file**.

## What the data looks like (Greater Sydney, archives 2021-01 → 2026-08-24)

Measured with `psi_profile.py` on the real archives:

| | |
|---|---|
| B records in the landing layer | 717,200 (from 1,198,409 statewide) |
| Distinct versions after hashdiff | 692,710 (24,490 republications were identical) |
| Current parcel-sales | 672,570 across 653,338 dealings |
| Standard sales (1 parcel, whole interest, price ≥ $1k, valid date) | 638,683 (95.0%) |
| Strata (has strata lot number) | 47.7% |
| Multi-parcel dealings (price repeated on each parcel row) | 4.8% of rows |
| Sale code present (`XA`, `AC`, …, no published code list) | 3.1% |
| Part-interest sales | 0.3% |
| Zoning blank | 50.0%. Use a planning layer instead |
| Legal description parsed to a DCDB `lotidstring` | ~100% |
| Street type parsed to a G-NAF code | 98.7% |

Median price of standard sales by contract year:

| Contract year | Rows | Strata median | Non-strata median |
|---|---:|---:|---:|
| 2021 | 145,457 | $775,000 | $1,102,000 |
| 2022 | 101,867 | $760,000 | $1,280,000 |
| 2023 | 107,936 | $780,000 | $1,305,000 |
| 2024 | 118,076 | $800,000 | $1,375,000 |
| 2025 | 118,265 | $827,000 | $1,462,500 |
| 2026 (to Aug) | 46,139 | $830,500 | $1,460,000 |

Scope note: archives are selected by **publication date** (2021 onward), so
contracts from 2020 or earlier that settled later are included (26,596 from
2020 and 8,234 before that, mostly off-the-plan). If you need contract years, filter on
`contract_year`.

## Gotchas found in the real files (and what the pipeline does)

1. **Sales are republished ("restated"), but almost all of it is one event.**
   2.9% of parcel-sales have a second version, and 99% of those changes are a
   sale code being filled in. They are **not** a routine late correction. 94%
   of all restatements come from just two weekly files, `20250811` and
   `20250922`. Those files republished the previous weeks' sales with sale
   codes filled in (88% of the records in `20250811` have one). Every other
   file has a code on under 0.3% of its records. Without those two files,
   only 0.16% of parcel-sales are ever restated. Price or date changes are
   rare (2 price, 21 contract date). So `sale_code` coverage depends on
   *when* a sale was published: sales first published around June–September
   2025 mostly have codes, other sales mostly don't. Don't use it as a
   reliable non-arm's-length filter. → Every version is kept with
   `load_from`/`load_to`, so a report can be rebuilt as of any date. This is
   the bitemporal evidence for criterion C2.
2. **Identical republications.** The same parcel-sale is republished for
   weeks (one off-the-plan sale appears in 66 weekly files), sometimes twice
   in one file. → A hashdiff over the descriptive fields means only real
   changes create versions.
3. **Property id is not unique within a sale.** A unit and its car-space lot
   can share the building's property id and appear as two B rows in the same
   file. → The key is `(property_id, dealing_number, parcel_seq)`. Keying on
   `(property_id, dealing)` alone made one parcel look like it changed on
   every publication, flipping between the two rows.
4. **Blank property ids.** Some new strata lots are published before they're
   in the Register of Land Values, or lose the id in a later file. → The
   pipeline matches the row back to its parcel-sale by dealing number plus
   hashdiff or legal description (78 resolved). On archives to 2026-09-28,
   340 remain blank and are left out of the vault hubs. 221 of them are from
   the four newest weekly files, so the count is mostly recent sales still
   waiting for an id and drops as later files fill it in.
5. **A stray CR inside a record** (e.g. `20230313.zip`, file `210_…DAT`)
   breaks `str.splitlines()` and throws off the Z trailer count. → Lines are split on LF only.
   All 36,794 district files in the 300 weekly zips now pass the trailer
   check (`_manifest.csv`: 0 mismatches, 0 malformed lines).
6. **Multi-parcel sales repeat the full price on every parcel.** Use
   `is_standard_sale` or `parcels_in_sale = 1` before computing medians.
7. **Zoning codes were reused in 2022** (e.g. `E1` changed from national park to
   local centre), and half of all rows are blank. Don't decode zoning from PSI.
8. `data_exploration/parse_psi.py` read `nature` and `dealing_number` from
   the wrong fields (off by one), so its de-dup never used the dealing
   number. This PR fixes those indexes.

## Known data gaps

These are flagged or left as they are, never silently dropped. Figures are
from archives up to 2026-09-28 (685,187 current parcel-sales).

| Gap | Size | Impact / what to do |
|---|---:|---|
| No coordinates in PSI | all rows | Location has to come from G-NAF (address) or DCDB (`lotidstring`); neither join is built yet |
| Zoning blank | 50.2% | And codes were reused in 2022. Take zoning from a planning layer instead |
| Sale code only filled in by two batch files | 3.0% have one | Coverage depends on publication date (gotcha 1), so it can't reliably separate non-arm's-length sales |
| Multi-parcel dealings | 4.7% | Full price repeated on each parcel; excluded by `is_standard_sale` |
| Part-interest sales | 0.3% | Price is for a share, not the whole property; excluded by `is_standard_sale` |
| Blank property id | 340 | Left out of the vault hubs; mostly recent sales (gotcha 4) |
| Blank postcode | 2,124 | Weakens the G-NAF address match; fall back to `lotidstring` |
| Street type not parsed to a G-NAF code | 1.4% | Unusual or misspelt types; match on street name + locality, or use lot/plan |
| Blank locality | 263 | Can't be mapped by suburb; lot/plan is the only location key |
| Contract or settlement date unusable | 121 flagged (`flag_bad_date`) | Excluded from standard sales |
| Recent months incomplete | last ~7 months | 10% of sales are first published more than 207 days after contract (off-the-plan), so recent volumes and medians keep moving. Compare like with like, or query as of a fixed date |
| Contracts before 2021 | 34,767 | Included because selection is by publication date; filter on `contract_year` |
| No published code lists for `sale_code`, `component_code` or `primary_purpose` | – | Values are shown as published; meanings are inferred |
| Licence wording conflicts | – | The zips say CC BY, the nsw.gov.au page says CC BY-NC-ND. Raw data stays out of git; check before publishing derived data |
| Scripted download blocked | – | Cloudflare returns 403 to scripts; archives have to be fetched in a browser (see "Run it") |

## Linking to the other sources (entity resolution)

- **Address → G-NAF.** `address.py` splits the PSI address into G-NAF columns:
  `flat_number`, `number_first(+suffix)`, `street_name_core`,
  `street_type_code` (e.g. `ST`→`STREET`), `street_suffix_code`, `locality`,
  and `postcode`. Match on those columns against G-NAF's `ADDRESS_DETAIL` joined to
  `STREET_LOCALITY` and `LOCALITY` to get `ADDRESS_DETAIL_PID` and a geocode.
- **Lot/plan → NSW cadastre.** `lotidstring` (`69//SP106623`,
  `748//DP1289945`) joins the DCDB lot layer directly, which gives the parcel
  polygon even when the address string is messy. We recommend this as the
  fallback when G-NAF matching fails.
- `district_code` maps to the LGA in `reference/psi_districts.csv`. That file
  has flags for the ABS Greater Sydney area (34 LGAs) and the 33-LGA metro
  area.

## Mapping to the Assignment 1 criteria

| Criterion | Where it is handled |
|---|---|
| C1 query performance | `sales_current` is pre-flattened and `street_prices` pre-aggregated; indexes on contract date, address match columns, and lotidstring |
| C2 bitemporal history | `sat_parcel_sale`: `load_dts` = transaction time, contract/settlement = valid time; `sale_as_of(ts)` rebuilds what we knew at any date |
| C3 standardisation | ISO dates, area always in m², G-NAF street type codes, DCDB lotidstring |
| C4 lineage and quality | `record_source` = `weekly zip/file:line`, a sha256 per week in `_manifest.csv` (and per yearly bundle in `raw/_bundles.csv`), Z-trailer checks, and flags (never deletes) |
| C5 safe incremental loading | Raw and landing are one file per week, and weeks already loaded are skipped by sha256. Vault inserts use `ON CONFLICT DO NOTHING`, so reruns change nothing |

## Files

| File | Purpose |
|---|---|
| `psi_format.py` | B/C record layout, street-type map, region filter (shared by all layers) |
| `bronze/download.py` | Which weeks are missing, download attempt, yearly-bundle split, manual-download page |
| `bronze/extract.py` | weekly zips → landing CSV (lineage, trailer check, C join) |
| `silver/transform.py` | landing → `sale_versions`, `sales_current` |
| `silver/address.py` | G-NAF address split, lot/plan parser |
| `silver/street_prices.py` | `sales_current` → average / median price per street, type and year |
| `quality/psi_profile.py` | the stats above |
| `quality/dashboard.py`, `quality/dashboard_template.html` | aggregates → self-contained HTML dashboard + 3D map |
| `reference/psi_districts.csv` | 130 PSI districts → LGA + Greater Sydney flags |
| `sql/psi_schema.sql`, `sql/psi_load.sql` | Postgres raw vault + views, idempotent load |

Attribution: *Contains NSW Valuer General Property Sales Information © State
of New South Wales.*
