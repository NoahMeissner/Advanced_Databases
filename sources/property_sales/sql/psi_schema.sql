-- NSW Valuer General property sales (PSI) -- PostgreSQL 14+ schema.
--
-- Follows the architecture recommended in Assignment 1: a Data Vault 2.0
-- raw vault for history and loading, with a thin reporting view on top.
--
--   stg_psi_sale_version   staging copy of sale_versions.csv.gz (truncate+load)
--   hub_property           one row per Valuer General property id
--   hub_dealing            one row per Land Registry dealing (= one sale)
--   link_parcel_sale       property x dealing x parcel_seq
--   sat_parcel_sale        versioned sale facts   (price, dates, codes)
--   sat_property_address   versioned address + lot/plan, keyed on property
--   ref_psi_district       district code -> LGA name, Greater Sydney flags
--
-- Hash keys are md5 of the upper-cased business key, as in DV 2.0. All vault
-- loads are insert-only and idempotent: rerunning psi_load.sql adds nothing
-- that is already there (criterion C5).

CREATE SCHEMA IF NOT EXISTS psi;
SET search_path = psi;

-- Reference ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ref_psi_district (
    district_code  char(3)  PRIMARY KEY,
    district_name  text     NOT NULL,
    in_gccsa       boolean  NOT NULL,  -- ABS Greater Sydney (34 LGAs)
    in_gsc33       boolean  NOT NULL   -- 33-LGA metro (excl. Central Coast)
);

-- Staging (mirrors transform.VERSION_COLUMNS) -----------------------------
CREATE TABLE IF NOT EXISTS stg_psi_sale_version (
    property_id            text,
    dealing_number         text,
    parcel_seq             int,
    version_no             int,
    hashdiff               char(32),
    load_from              timestamp,
    load_to                timestamp,
    last_seen              timestamp,
    times_published        int,
    is_current             int,
    changed_fields         text,
    district_code          char(3),
    district_name          text,
    contract_date          date,
    settlement_date        date,
    contract_year          int,
    purchase_price         bigint,
    area_m2                numeric,
    area_source            numeric,
    area_type              text,
    zoning                 text,
    nature_of_property     text,
    nature_description     text,
    primary_purpose        text,
    strata_lot_number      text,
    component_code         text,
    sale_code              text,
    interest_of_sale_pct   numeric,
    property_name          text,
    unit_number            text,
    house_number           text,
    street_name            text,
    locality               text,
    postcode               text,
    flat_number            text,
    flat_number_suffix     text,
    number_first           text,
    number_first_suffix    text,
    street_name_core       text,
    street_type_code       text,
    street_suffix_code     text,
    address_label          text,
    legal_description      text,
    lot                    text,
    section                text,
    plan                   text,
    lotidstring            text,
    flag_non_market_price  int,
    flag_part_interest     int,
    flag_has_sale_code     int,
    flag_settlement_before_contract int,
    flag_bad_date          int,
    source_archive         text,
    source_file            text,
    source_line            int
);

-- Hubs --------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS hub_property (
    property_hk    char(32)   PRIMARY KEY,
    property_id    text       NOT NULL UNIQUE,
    load_dts       timestamp  NOT NULL,
    record_source  text       NOT NULL
);

CREATE TABLE IF NOT EXISTS hub_dealing (
    dealing_hk     char(32)   PRIMARY KEY,
    dealing_number text       NOT NULL UNIQUE,
    load_dts       timestamp  NOT NULL,
    record_source  text       NOT NULL
);

-- Link --------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS link_parcel_sale (
    parcel_sale_hk char(32)   PRIMARY KEY,
    property_hk    char(32)   NOT NULL REFERENCES hub_property,
    dealing_hk     char(32)   NOT NULL REFERENCES hub_dealing,
    parcel_seq     int        NOT NULL,
    load_dts       timestamp  NOT NULL,
    record_source  text       NOT NULL,
    UNIQUE (property_hk, dealing_hk, parcel_seq)
);
CREATE INDEX IF NOT EXISTS ix_link_parcel_sale_dealing
    ON link_parcel_sale (dealing_hk);

-- Satellites --------------------------------------------------------------
-- load_dts = when the Valuer General published this version (transaction
-- time). contract_date / settlement_date = when it happened (valid time).
CREATE TABLE IF NOT EXISTS sat_parcel_sale (
    parcel_sale_hk        char(32)   NOT NULL REFERENCES link_parcel_sale,
    load_dts              timestamp  NOT NULL,
    hashdiff              char(32)   NOT NULL,
    contract_date         date,
    settlement_date       date,
    purchase_price        bigint,
    interest_of_sale_pct  numeric,
    sale_code             text,
    nature_of_property    text,
    primary_purpose       text,
    zoning                text,
    component_code        text,
    area_m2               numeric,
    flag_non_market_price boolean,
    flag_part_interest    boolean,
    flag_has_sale_code    boolean,
    flag_settlement_before_contract boolean,
    flag_bad_date         boolean,
    record_source         text       NOT NULL,  -- archive/file:line
    PRIMARY KEY (parcel_sale_hk, load_dts)
);
CREATE INDEX IF NOT EXISTS ix_sat_parcel_sale_contract
    ON sat_parcel_sale (contract_date);

CREATE TABLE IF NOT EXISTS sat_property_address (
    property_hk          char(32)   NOT NULL REFERENCES hub_property,
    load_dts             timestamp  NOT NULL,
    hashdiff             char(32)   NOT NULL,
    district_code        char(3),
    property_name        text,
    unit_number          text,
    house_number         text,
    street_name          text,
    locality             text,
    postcode             text,
    flat_number          text,
    flat_number_suffix   text,
    number_first         text,
    number_first_suffix  text,
    street_name_core     text,
    street_type_code     text,
    street_suffix_code   text,
    address_label        text,
    strata_lot_number    text,
    legal_description    text,
    lotidstring          text,   -- joins NSW DCDB lot polygons
    record_source        text       NOT NULL,
    PRIMARY KEY (property_hk, load_dts)
);
CREATE INDEX IF NOT EXISTS ix_sat_property_address_match
    ON sat_property_address (locality, street_name_core, number_first);
CREATE INDEX IF NOT EXISTS ix_sat_property_address_lot
    ON sat_property_address (lotidstring);

-- Reporting views -----------------------------------------------------------
-- Latest known state of every parcel-sale.
CREATE OR REPLACE VIEW v_sale_current AS
SELECT l.parcel_sale_hk, hp.property_id, hd.dealing_number, l.parcel_seq,
       s.contract_date, s.settlement_date, s.purchase_price, s.sale_code,
       s.interest_of_sale_pct, s.nature_of_property, s.area_m2, s.zoning,
       count(*) OVER (PARTITION BY l.dealing_hk) AS parcels_in_sale,
       s.load_dts AS known_since, s.record_source
FROM link_parcel_sale l
JOIN hub_property hp USING (property_hk)
JOIN hub_dealing  hd USING (dealing_hk)
JOIN LATERAL (
    SELECT * FROM sat_parcel_sale s
    WHERE s.parcel_sale_hk = l.parcel_sale_hk
    ORDER BY s.load_dts DESC LIMIT 1
) s ON true;

-- As-of query: what the vault knew at a point in transaction time. A report
-- issued in March can be reproduced exactly in June (criterion C2).
CREATE OR REPLACE FUNCTION sale_as_of(as_of timestamp)
RETURNS TABLE (parcel_sale_hk char(32), contract_date date,
               purchase_price bigint, sale_code text, load_dts timestamp)
LANGUAGE sql STABLE AS $$
    SELECT DISTINCT ON (s.parcel_sale_hk)
           s.parcel_sale_hk, s.contract_date, s.purchase_price, s.sale_code,
           s.load_dts
    FROM sat_parcel_sale s
    WHERE s.load_dts <= as_of
    ORDER BY s.parcel_sale_hk, s.load_dts DESC
$$;
