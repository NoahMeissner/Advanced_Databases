-- Gold: the serving layer.
--
-- Gold reads SILVER ONLY, never bronze (the team contract in
-- `git show f3467c0:gold/README.md`). Anything built from two or more sources
-- belongs here, which is why the graph and the cross-LGA marts live in gold
-- while the per-source cleaning stayed in silver.
--
-- Everything in this schema is fully derived, so every step is delete-then-
-- insert inside its own transaction and can be rebuilt from silver at any time.

CREATE SCHEMA IF NOT EXISTS gold;
