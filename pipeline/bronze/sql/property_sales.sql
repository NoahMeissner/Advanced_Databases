CREATE SCHEMA IF NOT EXISTS bronze;

CREATE TABLE IF NOT EXISTS bronze.property_sales (
    _row_id                          bigint       GENERATED ALWAYS AS IDENTITY,
    property_id                      integer,
    dealing_number                   text,        -- not always numeric
    parcel_seq                       smallint,
    version_no                       smallint,
    hashdiff                         text,        -- 32-char change hash
    load_from                        timestamptz,
    last_seen                        timestamptz,
    times_published                  integer,
    is_current                       boolean,
    changed_fields                   text,
    district_code                    smallint,
    district_name                    text,
    contract_date                    date,
    settlement_date                  date,
    contract_year                    smallint,
    purchase_price                   bigint,      -- cents-free whole dollars, up to 9 digits
    area_m2                          numeric(16,4),
    area_source                      text,
    area_type                        text,        -- 'M' (m2) | 'H' (hectares)
    zoning                           text,
    nature_of_property               text,        -- 'V' | 'R' | '3'
    nature_description               text,
    primary_purpose                  text,
    strata_lot_number                integer,
    component_code                   text,
    sale_code                        text,
    interest_of_sale_pct             smallint,
    property_name                    text,
    unit_number                      text,
    house_number                     text,
    street_name                      text,
    locality                         text,
    postcode                         text,        -- identifier, never arithmetic
    flat_number                      text,
    flat_number_suffix               text,
    number_first                     text,
    number_first_suffix              text,
    street_name_core                 text,
    street_type_code                 text,
    street_suffix_code               text,
    address_label                    text,
    legal_description                text,
    lot                              text,
    section                          text,
    plan                             text,
    lotidstring                      text,
    flag_non_market_price            boolean,
    flag_part_interest               boolean,
    flag_has_sale_code               boolean,
    flag_settlement_before_contract  boolean,
    flag_bad_date                    boolean,
    source_archive                   text         NOT NULL,
    source_file                      text         NOT NULL,
    source_line                      integer      NOT NULL,
    parcels_in_sale                  smallint,
    flag_multi_parcel                boolean,
    is_standard_sale                 boolean,
    -- Lineage: where the row comes from, when it was loaded
    _source_file                     text         NOT NULL,
    _loaded_at                       timestamptz  NOT NULL DEFAULT now(),

    CONSTRAINT property_sales_pkey PRIMARY KEY (_row_id),
    CONSTRAINT property_sales_source_position_key
        UNIQUE (source_archive, source_file, source_line)
);

-- The business key: not unique, but this is how the table is queried.
CREATE INDEX IF NOT EXISTS property_sales_dealing_idx
    ON bronze.property_sales (dealing_number, parcel_seq);
CREATE INDEX IF NOT EXISTS property_sales_contract_date_idx
    ON bronze.property_sales (contract_date);
