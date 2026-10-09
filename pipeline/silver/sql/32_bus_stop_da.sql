-- silver.bus_stop_da - development activity mapped onto each bus stop.
--
-- Two readings of "the hexagon value at this stop", both exposed:
--
--   *_hex     the single 300 m cell the stop sits in. Literal, but sparse and
--             jumpy: only 23,638 of 181,492 cells contain any application at
--             all, so a stop 10 m across a cell boundary can read zero.
--   *_kring1  the cell plus its 6 edge-sharing neighbours (7 cells, ~900 m
--             across). The headline figure, for exactly that sparsity reason.
--
-- Counts and sums roll up additively over the ring. Cost figures do NOT: an
-- average of seven medians is not a median of anything. So the k-ring cost
-- statistics are RE-AGGREGATED from the underlying applications across the
-- seven cells, which is why this step reads silver.da_application directly
-- instead of averaging silver.da_hex_300m.
--
-- n_applications_per_hex_kring1 is the literal per-hexagon average over the
-- ring - a density, where the _kring1 counts are totals.

CREATE TABLE IF NOT EXISTS silver.bus_stop_da (
    stop_id                        integer     NOT NULL REFERENCES silver.bus_stop ON DELETE CASCADE,
    period                         text        NOT NULL,
    hex_id                         text,
    n_hexes_in_ring                integer     NOT NULL,
    n_hexes_with_data              integer     NOT NULL,
    -- containing cell
    n_applications_hex             integer     NOT NULL DEFAULT 0,
    n_modifications_hex            integer     NOT NULL DEFAULT 0,
    sum_new_dwellings_hex          integer,
    median_cost_hex                numeric(16,2),
    -- k-ring 1 (cell + 6 neighbours)
    n_applications_kring1          integer     NOT NULL DEFAULT 0,
    n_modifications_kring1         integer     NOT NULL DEFAULT 0,
    n_reviews_kring1               integer     NOT NULL DEFAULT 0,
    n_determined_kring1            integer     NOT NULL DEFAULT 0,
    sum_new_dwellings_kring1       integer,
    n_applications_per_hex_kring1  numeric(10,3),
    median_cost_kring1             numeric(16,2),
    mean_cost_kring1               numeric(16,2),
    avg_storeys_kring1             numeric(8,2),
    avg_days_to_determination_kring1 numeric(10,2),
    record_source                  text        NOT NULL DEFAULT 'NSW_PLANNING_PORTAL_DA',
    loaded_at                      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT bus_stop_da_pkey PRIMARY KEY (stop_id, period)
);

CREATE INDEX IF NOT EXISTS bus_stop_da_period_idx ON silver.bus_stop_da (period);

DELETE FROM silver.bus_stop_da;

INSERT INTO silver.bus_stop_da
    (stop_id, period, hex_id, n_hexes_in_ring, n_hexes_with_data,
     n_applications_hex, n_modifications_hex, sum_new_dwellings_hex, median_cost_hex,
     n_applications_kring1, n_modifications_kring1, n_reviews_kring1,
     n_determined_kring1, sum_new_dwellings_kring1, n_applications_per_hex_kring1,
     median_cost_kring1, mean_cost_kring1, avg_storeys_kring1,
     avg_days_to_determination_kring1)
WITH ring AS (
    -- every stop joined to the 7 cells of its k-ring
    SELECT s.stop_id, s.hex_id AS centre_hex, n.neighbour_hex_id AS hex_id
      FROM silver.bus_stop s
      JOIN silver.hex_300m_neighbour n ON n.hex_id = s.hex_id
     WHERE s.hex_id IS NOT NULL
), ring_size AS (
    SELECT stop_id, centre_hex, count(*)::integer AS n_hexes_in_ring
      FROM ring GROUP BY stop_id, centre_hex
), apps AS (
    -- applications inside each stop's ring, re-aggregated from the entity table
    -- so medians are real medians over applications, not over hexagon medians
    SELECT r.stop_id,
           extract(year FROM d.lodgement_date)::integer AS yr,
           d.hex_id,
           d.application_type, d.application_status,
           d.number_of_new_dwellings, d.number_of_storeys, d.days_to_determination,
           CASE WHEN d.flag_cost_outlier THEN NULL ELSE d.cost_of_development END AS cost
      FROM ring r
      JOIN silver.da_application d ON d.hex_id = r.hex_id
     WHERE d.is_usable
), kring AS (
    SELECT stop_id,
           coalesce(yr::text, 'all')                                      AS period,
           count(DISTINCT hex_id)::integer                                AS n_hexes_with_data,
           count(*) FILTER (WHERE application_type = 'Development Application')::integer AS n_applications,
           count(*) FILTER (WHERE application_type = 'Modification Application')::integer AS n_modifications,
           count(*) FILTER (WHERE application_type = 'Review of determination')::integer  AS n_reviews,
           count(*) FILTER (WHERE application_status = 'Determined')::integer AS n_determined,
           sum(number_of_new_dwellings)::integer                           AS sum_new_dwellings,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY cost)::numeric(16,2) AS median_cost,
           round(avg(cost), 2)                                            AS mean_cost,
           round(avg(number_of_storeys), 2)                               AS avg_storeys,
           round(avg(days_to_determination), 2)                           AS avg_days
      FROM apps
     GROUP BY GROUPING SETS ((stop_id, yr), (stop_id))
)
SELECT k.stop_id,
       k.period,
       rs.centre_hex,
       rs.n_hexes_in_ring,
       k.n_hexes_with_data,
       coalesce(c.n_applications, 0),
       coalesce(c.n_modifications, 0),
       c.sum_new_dwellings,
       c.median_cost_of_development,
       k.n_applications,
       k.n_modifications,
       k.n_reviews,
       k.n_determined,
       k.sum_new_dwellings,
       round(k.n_applications::numeric / rs.n_hexes_in_ring, 3),
       k.median_cost,
       k.mean_cost,
       k.avg_storeys,
       k.avg_days
  FROM kring k
  JOIN ring_size rs USING (stop_id)
  LEFT JOIN silver.da_hex_300m c
         ON c.hex_id = rs.centre_hex AND c.period = k.period;
