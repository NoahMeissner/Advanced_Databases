# NSW Valuer General property sales (PSI)

Owner: Kang Donghyun (Brian). Source #1 in Assignment 1, Appendix 7.1.

Pipeline that takes the Valuer General's bulk Property Sales Information from raw
zips to a Data Vault in PostgreSQL. It is scoped to **Greater Sydney** and
**archives published from 2021 onward** (see the scope note below).
Only the Python standard library is used.

```
raw zips ──extract──▶ landing (1 CSV per zip, every B record, lineage)
         ──transform─▶ staging  sale_versions + sales_current (versioned, typed, flagged)
         ──psi_load.sql─▶ Postgres raw vault  hubs / link / satellites + views
```

## Run it

```bash
# from the repo root
python -m ingestion.property_sales.download      # tries each zip; writes manual_download.html for the rest
python -m ingestion.property_sales.extract       # --region greater_sydney (default) | gsc33 | nsw
python -m ingestion.property_sales.transform
python -m ingestion.property_sales.psi_profile --out data/property_sales/profile.md

psql -d suburblens -f ingestion/property_sales/sql/psi_schema.sql
psql -d suburblens -f ingestion/property_sales/sql/psi_load.sql
```

All data goes under `data/`, which is git-ignored. **Downloads are blocked for
scripts.** Since mid-2026 the Valuer General site uses Cloudflare bot
protection, so `download` gets HTTP 403. Open the generated
`data/property_sales/raw/manual_download.html` in a browser, click through the
links, save the zips into `data/property_sales/raw/`, and run `extract`.

Runtime on a laptop for all 2021–2026 archives (76 MB of zips): extract takes about 30 s,
transform about 2 min, and the Postgres load about 2 min.

## The source

| | |
|---|---|
| Publisher | Valuer General NSW (Valuation NSW), from Notices of Sale lodged with NSW Land Registry Services |
| Access | `https://www.valuergeneral.nsw.gov.au/__psi/yearly/YYYY.zip` (past years), `.../weekly/YYYYMMDD.zip` (each Monday, current year) |
| Format | Nested zips of `;`-delimited `.DAT` files, one per district per week, no headers. Spec: *Current Property Sales Data File Format 2001 to Current* |
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

1. **Sales are republished ("restated").** 3.0% of parcel-sales get a second
   version. The change is almost always a **sale code added later**: 19,897
   cases, a median 28 days after first publication. Price or date changes are
   rare (2 price, 21 contract date). A report built from the first version
   would treat those sales as ordinary. → Every version is kept with
   `load_from`/`load_to`. This is the bitemporal evidence for criterion C2.
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
   hashdiff or legal description (78 resolved). 119 remain blank and are
   left out of the vault hubs.
5. **A stray CR inside a record** (e.g. `2023.zip/20230313.zip/210_…DAT`)
   breaks `str.splitlines()` and throws off the Z trailer count. → Lines are split on LF only.
   All 6,400+ files now pass the trailer check (`_manifest.csv`).
6. **Multi-parcel sales repeat the full price on every parcel.** Use
   `is_standard_sale` or `parcels_in_sale = 1` before computing medians.
7. **Zoning codes were reused in 2022** (e.g. `E1` changed from national park to
   local centre), and half of all rows are blank. Don't decode zoning from PSI.
8. `data_exploration/parse_psi.py` read `nature` and `dealing_number` from
   the wrong fields (off by one), so its de-dup never used the dealing
   number. This PR fixes those indexes.

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
| C1 query performance | `sales_current` is pre-flattened; indexes on contract date, address match columns, and lotidstring |
| C2 bitemporal history | `sat_parcel_sale`: `load_dts` = transaction time, contract/settlement = valid time; `sale_as_of(ts)` rebuilds what we knew at any date |
| C3 standardisation | ISO dates, area always in m², G-NAF street type codes, DCDB lotidstring |
| C4 lineage and quality | `record_source` = `archive/file:line`, a sha256 per archive in `_manifest.csv`, Z-trailer checks, and flags (never deletes) |
| C5 safe incremental loading | Landing is one file per zip, and archives already loaded are skipped by sha256. Vault inserts use `ON CONFLICT DO NOTHING`, so reruns change nothing |

## Files

| File | Purpose |
|---|---|
| `psi_format.py` | B/C record layout, street-type map, region filter |
| `download.py` | URL list, download attempt, manual-download page |
| `extract.py` | zips → landing CSV (lineage, trailer check, C join) |
| `transform.py` | landing → `sale_versions`, `sales_current` |
| `address.py` | G-NAF address split, lot/plan parser |
| `psi_profile.py` | the stats above |
| `reference/psi_districts.csv` | 130 PSI districts → LGA + Greater Sydney flags |
| `sql/psi_schema.sql`, `sql/psi_load.sql` | Postgres raw vault + views, idempotent load |

Attribution: *Contains NSW Valuer General Property Sales Information © State
of New South Wales.*
