# <Source name>

Owner: <name>. Source #<n> in Assignment 1, §2.2.1.

<One paragraph: what this source says about an address, and which report
question it answers.>

## Run it

```bash
# from the repo root
python -m sources.<name>.bronze.<fetch step>
python -m sources.<name>.bronze.<parse step>
python -m sources.<name>.silver.<transform step>
```

## The source

| | |
|---|---|
| Publisher | |
| Access | URL / API, auth, rate limits |
| Format | |
| Licence | Exact wording, and where it's stated |
| Grain | One row = … |
| Spatial | Geometry type, CRS, or "none" |
| Freshness | Publication cadence and lag |
| History | How far back; whether past records are revised |

## Bronze → Silver

| Layer | Output (`data/<layer>/<name>/`) | Key | Notes |
|---|---|---|---|
| Bronze landing | | | Every record, with lineage |
| Silver | | business key + version | `hashdiff`, `load_from` / `load_to`, `flag_*` |

## Join keys

How this source reaches G-NAF (address parts, lot/plan, point-in-polygon, …),
and the expected match rate.

## Quality contract

| Check | Expected | Latest run |
|---|---|---|
| Freshness | | |
| Completeness | | |
| Suppressed / missing | | |

## Gotchas found in the real data

## Known data gaps

| Gap | Size | Impact / what to do |
|---|---:|---|
