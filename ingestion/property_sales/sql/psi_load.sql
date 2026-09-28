-- Load staging CSVs into the PSI raw vault. Idempotent: safe to rerun.
--
-- Run from the repository root after transform.py:
--
--   psql -d suburblens -f ingestion/property_sales/sql/psi_schema.sql
--   psql -d suburblens -f ingestion/property_sales/sql/psi_load.sql
--
-- psql's \copy reads client-side files, so no server file access is needed.

SET search_path = psi;

-- Reference
CREATE TEMP TABLE tmp_district (district_code text, district_name text,
                                in_gccsa int, in_gsc33 int);
\copy tmp_district FROM 'ingestion/property_sales/reference/psi_districts.csv' WITH (FORMAT csv, HEADER true)
INSERT INTO ref_psi_district
SELECT district_code, district_name, in_gccsa = 1, in_gsc33 = 1
FROM tmp_district
ON CONFLICT (district_code) DO UPDATE
   SET district_name = EXCLUDED.district_name,
       in_gccsa = EXCLUDED.in_gccsa, in_gsc33 = EXCLUDED.in_gsc33;

-- Staging: full reload of the version file
TRUNCATE stg_psi_sale_version;
\copy stg_psi_sale_version FROM PROGRAM 'gzip -dc data/property_sales/staging/sale_versions.csv.gz' WITH (FORMAT csv, HEADER true)

-- Hubs: first time each business key was seen
INSERT INTO hub_property (property_hk, property_id, load_dts, record_source)
SELECT md5(upper(trim(property_id))), property_id, min(load_from), 'PSI'
FROM stg_psi_sale_version WHERE property_id IS NOT NULL
GROUP BY property_id
ON CONFLICT DO NOTHING;

INSERT INTO hub_dealing (dealing_hk, dealing_number, load_dts, record_source)
SELECT md5(upper(trim(dealing_number))), dealing_number, min(load_from), 'PSI'
FROM stg_psi_sale_version WHERE property_id IS NOT NULL
GROUP BY dealing_number
ON CONFLICT DO NOTHING;

-- Link
INSERT INTO link_parcel_sale (parcel_sale_hk, property_hk, dealing_hk,
                              parcel_seq, load_dts, record_source)
SELECT md5(upper(trim(property_id)) || '||' || upper(trim(dealing_number))
           || '||' || parcel_seq),
       md5(upper(trim(property_id))), md5(upper(trim(dealing_number))),
       parcel_seq, min(load_from), 'PSI'
FROM stg_psi_sale_version WHERE property_id IS NOT NULL
GROUP BY property_id, dealing_number, parcel_seq
ON CONFLICT DO NOTHING;

-- Sale satellite: one row per version
INSERT INTO sat_parcel_sale
SELECT md5(upper(trim(property_id)) || '||' || upper(trim(dealing_number))
           || '||' || parcel_seq),
       load_from, hashdiff, contract_date, settlement_date, purchase_price,
       interest_of_sale_pct, NULLIF(sale_code, ''),
       NULLIF(nature_of_property, ''), NULLIF(primary_purpose, ''),
       NULLIF(zoning, ''), NULLIF(component_code, ''), area_m2,
       flag_non_market_price = 1, flag_part_interest = 1,
       flag_has_sale_code = 1, flag_settlement_before_contract = 1,
       flag_bad_date = 1,
       source_archive || '/' || source_file || ':' || source_line
FROM stg_psi_sale_version WHERE property_id IS NOT NULL
ON CONFLICT DO NOTHING;

-- Address satellite: a new row only when the property's address/legal
-- description actually changes (several sales of one property often carry
-- the same address).
WITH addr AS (
    SELECT md5(upper(trim(property_id))) AS property_hk,
           md5(concat_ws('||', district_code, property_name, unit_number,
                         house_number, street_name, locality, postcode,
                         strata_lot_number, legal_description)) AS addr_hash,
           v.*
    FROM stg_psi_sale_version v
    WHERE parcel_seq = 1 AND property_id IS NOT NULL
), changes AS (
    SELECT *, lag(addr_hash) OVER (PARTITION BY property_hk
                                  ORDER BY load_from, dealing_number) AS prev
    FROM addr
)
INSERT INTO sat_property_address
SELECT DISTINCT ON (property_hk, load_from)
       property_hk, load_from, addr_hash, district_code, property_name,
       unit_number, house_number, street_name, locality, postcode,
       flat_number, flat_number_suffix, number_first, number_first_suffix,
       street_name_core, street_type_code, street_suffix_code, address_label,
       strata_lot_number, legal_description, lotidstring,
       source_archive || '/' || source_file || ':' || source_line
FROM changes
WHERE prev IS DISTINCT FROM addr_hash
ORDER BY property_hk, load_from, dealing_number
ON CONFLICT DO NOTHING;

ANALYZE;
