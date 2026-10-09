-- silver.rent_lga - median weekly rent per LGA, quarter and dwelling type.
--
-- SCOPE WARNING, carried in the data rather than only in a README: the source
-- is 48 rows covering 6 LGAs (Sydney, Inner West, North Sydney, Parramatta,
-- Ryde, Canterbury-Bankstown) over 4 quarters and 2 dwelling types. It is
-- sample data, so "highest rent in Sydney" compares 6 LGAs, not 33.
--
-- A NULL median_weekly_rent with reliability_flag 'x' is SUPPRESSED, not
-- missing: the publisher withheld it because the bond count was too small.
-- flag_suppressed keeps that distinction, because a suppressed rent must never
-- be read as a cheap one - or coalesced to zero.

CREATE TABLE IF NOT EXISTS silver.rent_lga (
    lga_code             text        NOT NULL REFERENCES silver.lga,
    period_start         date        NOT NULL,
    dwelling_type        text        NOT NULL,       -- 'house' | 'flat'
    median_weekly_rent   numeric(10,2),
    new_bonds_count      integer,
    reliability_flag     text,
    flag_suppressed      boolean     NOT NULL DEFAULT false,
    flag_low_reliability boolean     NOT NULL DEFAULT false,
    is_usable            boolean     NOT NULL DEFAULT true,
    record_source        text        NOT NULL DEFAULT 'NSW_RENTAL_BOND_BOARD',
    loaded_at            timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT rent_lga_pkey PRIMARY KEY (lga_code, period_start, dwelling_type)
);

CREATE INDEX IF NOT EXISTS rent_lga_period_idx ON silver.rent_lga (period_start);

INSERT INTO silver.rent_lga AS t
    (lga_code, period_start, dwelling_type, median_weekly_rent, new_bonds_count,
     reliability_flag, flag_suppressed, flag_low_reliability, is_usable)
SELECT DISTINCT ON (silver.lga_key(b.lga_name), b.period_start, lower(trim(b.dwelling_type)))
       silver.lga_key(b.lga_name),
       b.period_start,
       lower(trim(b.dwelling_type)),
       b.median_weekly_rent,
       b.new_bonds_count,
       nullif(trim(b.reliability_flag), ''),
       -- 'x' = withheld by the publisher, so a NULL rent here is deliberate
       (b.median_weekly_rent IS NULL),
       (coalesce(trim(b.reliability_flag), '') <> 'n'),
       (b.median_weekly_rent IS NOT NULL AND b.median_weekly_rent > 0)
  FROM bronze.rent_data b
 WHERE b.lga_name      IS NOT NULL
   AND b.period_start  IS NOT NULL
   AND nullif(trim(b.dwelling_type), '') IS NOT NULL
   AND EXISTS (SELECT 1 FROM silver.lga l WHERE l.lga_code = silver.lga_key(b.lga_name))
 ORDER BY silver.lga_key(b.lga_name), b.period_start, lower(trim(b.dwelling_type)),
          b._loaded_at DESC
ON CONFLICT (lga_code, period_start, dwelling_type) DO UPDATE
   SET median_weekly_rent   = EXCLUDED.median_weekly_rent,
       new_bonds_count      = EXCLUDED.new_bonds_count,
       reliability_flag     = EXCLUDED.reliability_flag,
       flag_suppressed      = EXCLUDED.flag_suppressed,
       flag_low_reliability = EXCLUDED.flag_low_reliability,
       is_usable            = EXCLUDED.is_usable,
       loaded_at            = now()
 WHERE (t.median_weekly_rent, t.new_bonds_count, t.reliability_flag, t.is_usable)
       IS DISTINCT FROM
       (EXCLUDED.median_weekly_rent, EXCLUDED.new_bonds_count,
        EXCLUDED.reliability_flag, EXCLUDED.is_usable);

-- The latest usable quarter per LGA and dwelling type. Both the graph and the
-- comparison mart want "the current rent", and picking it in one place stops
-- two consumers disagreeing about which quarter that is.
CREATE OR REPLACE VIEW silver.rent_lga_latest AS
SELECT DISTINCT ON (lga_code, dwelling_type)
       lga_code, dwelling_type, period_start, median_weekly_rent,
       new_bonds_count, reliability_flag, flag_low_reliability
  FROM silver.rent_lga
 WHERE is_usable
 ORDER BY lga_code, dwelling_type, period_start DESC;
