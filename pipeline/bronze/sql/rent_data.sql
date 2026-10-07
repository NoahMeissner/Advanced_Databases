CREATE SCHEMA IF NOT EXISTS bronze;

CREATE TABLE IF NOT EXISTS bronze.rent_data (
    rent_id              integer      NOT NULL,
    lga_name             text,
    period_start         date,
    dwelling_type        text,
    median_weekly_rent   numeric(10,2),
    new_bonds_count      integer,
    reliability_flag     text,
    -- Lineage: where the row comes from, when it was loaded
    _source_file         text         NOT NULL,
    _loaded_at           timestamptz  NOT NULL DEFAULT now(),

    CONSTRAINT rent_data_pkey PRIMARY KEY (rent_id)
);
