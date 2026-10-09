-- Data-quality framework: checks are data, not scattered asserts.
--
-- Bronze keeps every row, including the bad ones. Silver is the first layer
-- anyone may trust, so every Bronze -> Silver rule is recorded here with its
-- outcome instead of being applied silently.
--
--   dq_run     one row per quality run (what pipeline/silver/quality.py does)
--   dq_result  one row per check per run - the audit trail criterion C4 asks for
--   dq_reject  the rows a severity='error' check refused, kept not deleted
--
-- Nothing is ever DELETEd because a check failed: the row lands in dq_reject,
-- carries a flag_* column in its entity table and is excluded from aggregates
-- by an is_usable predicate. That way count(silver) + count(rejects) still
-- reconciles against Bronze.

CREATE TABLE IF NOT EXISTS silver.dq_run (
    run_id      bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    started_at  timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,
    git_rev     text,
    n_checks    integer,
    n_failed    integer,
    passed      boolean
);

CREATE TABLE IF NOT EXISTS silver.dq_result (
    run_id      bigint      NOT NULL REFERENCES silver.dq_run ON DELETE CASCADE,
    table_name  text        NOT NULL,       -- 'silver.da_application'
    check_name  text        NOT NULL,       -- 'coord_matches_council'
    dimension   text        NOT NULL,       -- see the CHECK below
    severity    text        NOT NULL,       -- 'error' aborts the run, 'warn' reports
    failed_rows bigint      NOT NULL,
    total_rows  bigint      NOT NULL,
    threshold   numeric,                    -- max tolerated failed fraction, NULL = 0
    passed      boolean     NOT NULL,
    detail      jsonb,                      -- free-form context, e.g. sample keys
    checked_at  timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT dq_result_pkey PRIMARY KEY (run_id, table_name, check_name),
    CONSTRAINT dq_result_dimension_check CHECK (dimension IN (
        'completeness', 'uniqueness', 'validity',
        'consistency', 'accuracy', 'timeliness')),
    CONSTRAINT dq_result_severity_check CHECK (severity IN ('error', 'warn'))
);

CREATE INDEX IF NOT EXISTS dq_result_failed_idx
    ON silver.dq_result (run_id, passed) WHERE NOT passed;

CREATE TABLE IF NOT EXISTS silver.dq_reject (
    run_id       bigint NOT NULL REFERENCES silver.dq_run ON DELETE CASCADE,
    source_table text   NOT NULL,           -- 'bronze.da_applications'
    source_key   text   NOT NULL,           -- the business key as text
    check_name   text   NOT NULL,
    reason       text,
    payload      jsonb                       -- the offending row, for triage
);

CREATE INDEX IF NOT EXISTS dq_reject_run_idx
    ON silver.dq_reject (run_id, source_table);
