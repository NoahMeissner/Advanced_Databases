CREATE SCHEMA IF NOT EXISTS bronze;

CREATE TABLE IF NOT EXISTS bronze.da_applications (
    planning_portal_application_number                 text          NOT NULL,
    council_application_number                         text,
    council_name                                       text,
    application_type                                   text,
    application_status                                 text,
    development_types                                  text,        -- multi-value, ';'-separated
    submission_date                                    date,
    lodgement_date                                     date,
    determination_date                                 date,
    date_last_updated                                  timestamptz,
    determination_authority                            text,
    cost_of_development                                numeric(16,2),
    number_of_new_dwellings                            integer,
    number_of_storeys                                  integer,
    suburb                                             text,
    postcode                                           text,        -- identifier, never arithmetic
    full_address                                       text,
    longitude                                          numeric(12,8),
    latitude                                           numeric(12,8),
    assessment_exhibition_end_date                     timestamptz,
    assessment_exhibition_start_date                   timestamptz,
    number_of_existing_lots                            integer,
    accompanied_by_vpa_flag                            boolean,
    development_subject_to_sic_flag                    boolean,
    epi_variation_proposed_flag                        boolean,
    subdivision_proposed_flag                          boolean,
    development_type_count                             integer,
    location_count                                     integer,
    street_number1                                     text,
    street_number2                                     text,
    street_name                                        text,
    street_type                                        text,
    street_suffix                                      text,
    state                                              text,
    lots                                               text,        -- long multi-value list
    variation_to_development_standards_approved_flag   boolean,
    modification_application_number                    text,
    number_of_proposed_lots                            integer,
    -- Lineage: where the row comes from, when it was loaded
    _source_file                                       text         NOT NULL,
    _loaded_at                                         timestamptz  NOT NULL DEFAULT now(),

    CONSTRAINT da_applications_pkey PRIMARY KEY (planning_portal_application_number)
);

CREATE INDEX IF NOT EXISTS da_applications_council_idx
    ON bronze.da_applications (council_name);
CREATE INDEX IF NOT EXISTS da_applications_lodgement_date_idx
    ON bronze.da_applications (lodgement_date);
