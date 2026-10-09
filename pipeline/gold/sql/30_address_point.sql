-- gold.address_point - the geocoder behind the address box.
--
-- There is no G-NAF in this project, so "type an address and get a point" has
-- to be answered from the data we have. Two tiers, and the site always says
-- which one it used:
--
--   precision = 'address'  121,551 distinct development-application addresses
--                          that carry a real coordinate ('59 ENMORE ROAD
--                          NEWTOWN 2042'). Exact, accuracy_m = 0.
--   precision = 'street'   26,566 street centres from silver.street_locality,
--                          themselves derived from DA points. Used when the
--                          typed address is not one of the above, which is the
--                          common case - most homes have never had a DA.
--                          accuracy_m carries the street's own measured spread.
--
-- search_key is what the trigram index matches on: upper-cased, punctuation
-- reduced to single spaces. Keeping it as a separate column (rather than
-- normalising in the query) is what lets the GIN index actually be used.
--
-- pg_trgm gives fuzzy prefix/substring ranking over ~148k rows, so a partial or
-- slightly-misspelled address still finds its street.

CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE TABLE IF NOT EXISTS gold.address_point (
    address_id   text        PRIMARY KEY,     -- md5(search_key || precision)
    address_text text        NOT NULL,        -- what the user sees
    search_key   text        NOT NULL,        -- what the index matches
    street_name  text,
    locality     text,
    postcode     text,
    street_id    text,                        -- -> silver.street_locality
    precision    text        NOT NULL,
    accuracy_m   numeric(10,2) NOT NULL,
    geom         geometry(Point, 4326) NOT NULL,
    geom_m       geometry(Point, 7856) NOT NULL,
    hex_id       text,
    loaded_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT address_point_precision_check
        CHECK (precision IN ('address', 'street'))
);

-- GiST, not GIN, and the queries order by the <-> distance operator.
--
-- With a GIN trigram index the % operator produced a lossy bitmap of 56,044
-- candidate rows for a three-word query, of which 55,726 were thrown away on
-- recheck after reading 4,721 heap blocks - 302 ms for one address lookup, the
-- single slowest thing the website did. GiST supports <-> nearest-neighbour
-- ordering, so Postgres walks the index in similarity order and stops at the
-- limit: the same five queries drop from 188 ms average to 39 ms.
-- Index build costs about 2.5 s at pipeline time.
-- Dropped first: the index METHOD changed from gin to gist, and
-- CREATE INDEX IF NOT EXISTS would silently keep a stale gin index that cannot
-- serve <-> at all. Rebuilding costs ~2.5 s, against a table this step
-- repopulates from scratch anyway.
DROP INDEX IF EXISTS gold.address_point_search_idx;
CREATE INDEX address_point_search_idx
    ON gold.address_point USING gist (search_key gist_trgm_ops);
CREATE INDEX IF NOT EXISTS address_point_geom_m_idx
    ON gold.address_point USING gist (geom_m);
CREATE INDEX IF NOT EXISTS address_point_precision_idx
    ON gold.address_point (precision);

DELETE FROM gold.address_point;

-- Tier 1: exact addresses from development applications.
INSERT INTO gold.address_point
    (address_id, address_text, search_key, street_name, locality, postcode,
     street_id, precision, accuracy_m, geom, geom_m, hex_id)
WITH cleaned AS (
    SELECT DISTINCT ON (upper(regexp_replace(trim(d.full_address), '[^A-Za-z0-9]+', ' ', 'g')))
           trim(regexp_replace(d.full_address, '\s+', ' ', 'g'))               AS address_text,
           upper(regexp_replace(trim(d.full_address), '[^A-Za-z0-9]+', ' ', 'g')) AS search_key,
           d.suburb,
           d.postcode,
           d.geom,
           d.geom_m,
           d.hex_id
      FROM silver.da_application d
     WHERE d.is_usable
       AND nullif(trim(d.full_address), '') IS NOT NULL
       -- several applications share one address; keep the newest coordinate
     ORDER BY upper(regexp_replace(trim(d.full_address), '[^A-Za-z0-9]+', ' ', 'g')),
              d.lodgement_date DESC NULLS LAST
)
SELECT md5(search_key || '|address'),
       address_text,
       search_key,
       NULL,                 -- the DA address is unparsed; the street tier has it
       suburb,
       postcode,
       NULL,
       'address',
       0,
       geom,
       geom_m,
       hex_id
  FROM cleaned;

-- Tier 2: street centres, for everything the first tier does not contain.
INSERT INTO gold.address_point
    (address_id, address_text, search_key, street_name, locality, postcode,
     street_id, precision, accuracy_m, geom, geom_m, hex_id)
SELECT md5(upper(regexp_replace(trim(l.street_label), '[^A-Za-z0-9]+', ' ', 'g')) || '|street'),
       l.street_label,
       upper(regexp_replace(trim(l.street_label), '[^A-Za-z0-9]+', ' ', 'g')),
       concat_ws(' ', l.street_name_core, l.street_type_code, l.street_suffix_code),
       l.locality,
       l.postcode,
       l.street_id,
       'street',
       -- The street's own measured spread about its centre, floored at 50 m.
       -- A street built from a single DA point has a p90 spread of exactly 0,
       -- which means "only one observation", not "perfectly located" - 8,787
       -- streets are in that position. Letting a street row claim 0 m would
       -- make it indistinguishable from an exact address.
       greatest(coalesce(l.geocode_spread_m, 300), 50),
       l.centroid,
       l.centroid_m,
       l.hex_id
  FROM silver.street_locality l
 WHERE l.centroid IS NOT NULL
   AND nullif(trim(l.street_label), '') IS NOT NULL
ON CONFLICT (address_id) DO NOTHING;
