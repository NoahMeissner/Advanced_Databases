CREATE SCHEMA IF NOT EXISTS bronze;

CREATE TABLE IF NOT EXISTS bronze.school_location (
    school_code                             integer      NOT NULL,
    age_id                                  integer,
    school_name                             text,
    street                                  text,
    town_suburb                             text,
    postcode                                text,        -- identifier, never arithmetic
    phone                                   text,
    school_email                            text,
    website                                 text,
    fax                                     text,
    latest_year_enrolment_fte                numeric(10,1),
    indigenous_pct                          numeric(5,2),
    lbote_pct                               numeric(5,2),
    icsea_value                             numeric(8,2),
    level_of_schooling                      text,
    selective_school                        text,        -- Not / Partially / Fully Selective
    opportunity_class                       boolean,
    school_specialty_type                   text,
    school_subtype                          text,
    preschool_ind                           boolean,
    distance_education                      text,        -- 'C' | 'N' | 'S', not a boolean
    intensive_english_centre                boolean,
    school_gender                           text,
    late_opening_school                     boolean,
    date_1st_teacher                        date,
    lga                                     text,
    electorate_from_2023                    text,
    electorate_2015_2022                    text,
    fed_electorate_from_2025                text,
    fed_electorate_2016_2024                text,
    operational_directorate                 text,
    principal_network                       text,
    operational_directorate_office          text,
    operational_directorate_office_phone    text,
    operational_directorate_office_address  text,
    facs_district                           text,
    local_health_district                   text,
    aecg_region                             text,
    asgs_remoteness                         text,
    latitude                                numeric(12,8),
    longitude                               numeric(12,8),
    assets_unit                             text,
    sa4                                     text,
    foei_value                              numeric(8,2),
    date_extracted                          date,
    -- Source-side cleaning trail: *_raw = value before cleaning, *_status = outcome
    postcode_raw                            text,
    postcode_status                         text,
    latest_year_enrolment_fte_raw            numeric(10,1),
    latest_year_enrolment_fte_status         text,
    indigenous_pct_raw                      text,        -- holds banded values like 'np'
    indigenous_pct_status                   text,
    lbote_pct_raw                           text,        -- holds banded values like 'np'
    lbote_pct_status                        text,
    icsea_value_raw                         numeric(8,2),
    icsea_value_status                      text,
    opportunity_class_raw                   boolean,     -- 'Y'/'N' in the CSV
    opportunity_class_status                text,
    preschool_ind_raw                       boolean,     -- 'Y'/'N' in the CSV
    preschool_ind_status                    text,
    distance_education_raw                  text,        -- 'C' | 'N' | 'S'
    distance_education_status               text,
    intensive_english_centre_raw            boolean,     -- 'Y'/'N' in the CSV
    intensive_english_centre_status         text,
    late_opening_school_raw                 boolean,     -- 'Y'/'N' in the CSV
    late_opening_school_status              text,
    date_1st_teacher_raw                    date,
    date_1st_teacher_status                 text,
    latitude_raw                            numeric(12,8),
    latitude_status                         text,
    longitude_raw                           numeric(12,8),
    longitude_status                        text,
    foei_value_raw                          numeric(8,2),
    foei_value_status                       text,
    date_extracted_raw                      date,
    date_extracted_status                   text,
    school_id                               text,
    source_file                             text,
    source_row_number                       integer,
    source_date                             date,
    coordinate_crs                          text,
    coordinate_status                       text,
    -- Lineage: where the row comes from, when it was loaded
    _source_file                            text         NOT NULL,
    _loaded_at                              timestamptz  NOT NULL DEFAULT now(),

    CONSTRAINT school_location_pkey PRIMARY KEY (school_code)
);

CREATE INDEX IF NOT EXISTS school_location_postcode_idx
    ON bronze.school_location (postcode);
CREATE INDEX IF NOT EXISTS school_location_lga_idx
    ON bronze.school_location (lga);
