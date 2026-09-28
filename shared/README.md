# Shared: code used by two or more sources

Move code here as soon as a second source needs it, rather than copying it.
Expected residents:

- **G-NAF reference and matching.** Load G-NAF, and resolve address parts or
  points to `ADDRESS_DETAIL_PID`. The match rules and thresholds have to be
  defined and tested per source pair (report §4.5).
- **CRS transformation.** One agreed project CRS; GDA94 ↔ GDA2020 and
  lon/lat ↔ projected metres, so proximity queries are metrically valid.
- **Common reference tables.** LGA / district codes, suburb and postcode lookups.
- **Pipeline helpers.** Data paths (`data/<layer>/<source>/`), manifest and
  sha256 handling, `hashdiff` and versioning.

Keep it small: a helper earns its place here by having at least two callers.
