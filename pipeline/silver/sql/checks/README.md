# Silver quality checks

One SQL file per source. Each file returns a UNION ALL of check rows in this
exact shape, which `pipeline/silver/quality.py` writes into `silver.dq_result`:

| column | meaning |
|---|---|
| `table_name` | the silver table being checked |
| `check_name` | unique within the table |
| `dimension` | completeness / uniqueness / validity / consistency / accuracy / timeliness |
| `severity` | `error` fails the run, `warn` is recorded and reported |
| `failed_rows` | how many rows break the rule |
| `total_rows` | the denominator |
| `threshold` | max tolerated **fraction** failing; NULL means zero tolerance |
| `detail` | jsonb, free-form context (sample keys, measured values) |

A check never deletes anything. Rows that break an `error` check are written to
`silver.dq_reject`, carry a `flag_*` column on their entity table, and are
excluded from aggregates by `is_usable` - so `count(silver) + count(rejects)`
still reconciles against bronze.

`proximity_oracle_agrees` deliberately lives in `test/silver_integrity.py`
instead of here: it compares against columns in the raw school CSV that bronze
drops as derived data, so it needs to read the file, not the database.
