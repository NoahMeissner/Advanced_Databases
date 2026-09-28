# Sources: the contract every data source follows

Each folder under `sources/` is one **data product** with one owner. The rules
below are what lets Gold join sources safely. Each one traces back to a
criterion (C1–C5) in the root README.

## Adding a source

1. `cp -r sources/_template sources/<name>`. Use a lowercase, underscore name,
   because it's a Python package.
2. Fill in `sources/<name>/README.md` (the data-product card) before writing
   code. Grain, cadence and licence decide the design.
3. Build Bronze, then Silver, running each stage as a module from the repo root:
   `python -m sources.<name>.bronze.<step>`.
4. Put your name against the source in the root README table, and open a PR
   into `main`.

## Layers and paths

| Layer | Code | Writes to | Rule |
|---|---|---|---|
| Bronze | `sources/<name>/bronze/` | `data/bronze/<name>/raw/` (downloads as published) and `data/bronze/<name>/landing/` (parsed, one file per raw file) | Never edit raw files. Keep **every** record, including bad ones. Parsing only splits fields; no cleaning |
| Silver | `sources/<name>/silver/` | `data/silver/<name>/` | Typed, standardised, versioned, flagged. G-NAF / CRS resolution happens here, once |
| Gold | `gold/` | `data/gold/` | Reads Silver only, never Bronze |
| Reports | `sources/<name>/quality/` | `data/reports/<name>/` | Profiles, checks, dashboards |

`data/` is git-ignored. Only commit code, small reference tables and, if the
licence allows, aggregate outputs.

## Conventions

**Lineage (C4).** Every Bronze landing row carries where it came from:
`source_archive` / `source_file` / `source_line` (or the API request and page),
and the download time. Keep a `_manifest.csv` per Bronze run: one row per raw
file with its sha256 and record counts, plus any trailer or checksum checks the
format offers.

**Incremental and idempotent (C5).** A raw file already in the manifest (same
sha256) is skipped. Re-running any stage on the same input produces the same
output. Database loads use `ON CONFLICT DO NOTHING` (or `MERGE`), never
`TRUNCATE` + reload.

**History (C2).** Silver never overwrites. Hash the descriptive fields
(`hashdiff`); a new hash makes a new version with `load_from` / `load_to`
(transaction time). Keep the source's own dates (contract date, DA status date,
…) as valid time. Keep both axes.

**Standardisation (C3).** ISO-8601 dates, SI units (m, m², seconds), prices in
AUD as integers, and one project CRS for geometry (put the transform in
`shared/`, not per source). Address parts go in G-NAF-shaped columns
(`flat_number`, `number_first`, `street_name`, `street_type_code`, `locality`,
`postcode`). Parcels use the DCDB `lotidstring`.

**Quality flags (C4).** Flag problems as `flag_*` columns; don't delete rows.
Put the counts in the profile.

**Code.** Must pass `pylint` with the repo defaults, since CI runs it on every
tracked `.py` file. The standard library is preferred. If you need a package,
add it to `requirements.txt` and to the workflow in the same PR.

**Data-product card.** Your README states the quality contract: expected
freshness, completeness, and what is suppressed or missing. Keep "Known data
gaps" up to date with real numbers from your latest run.
