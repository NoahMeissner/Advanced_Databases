-- silver.da_hex_300m - development activity per 300 m hexagon, per period.
--
-- Application types are counted SEPARATELY rather than lumped together. A
-- Modification Application re-references a site that already has a DA, so a
-- single development with five modifications would otherwise read as six
-- developments. 130,822 DAs / 48,097 modifications / 1,942 reviews.
--
-- Only is_usable applications contribute (coordinate present, inside the study
-- area, and not contradicting its own council's location). Cost aggregates
-- additionally drop flag_cost_outlier rows - the source's 21.6 bn maximum would
-- otherwise set the mean for its whole hexagon single-handedly.
--
-- period is the lodgement year, plus an 'all' roll-up from GROUPING SETS.
-- n_applications_last_12m is relative to the newest lodgement date in the data,
-- not to now(), so re-running the pipeline reproduces the same number.

CREATE TABLE IF NOT EXISTS silver.da_hex_300m (
    hex_id                     text        NOT NULL REFERENCES silver.hex_300m ON DELETE CASCADE,
    period                     text        NOT NULL,   -- '2024' | 'all'
    n_applications             integer     NOT NULL,   -- Development Applications only
    n_modifications            integer     NOT NULL,
    n_reviews                  integer     NOT NULL,
    n_determined               integer     NOT NULL,
    sum_new_dwellings          integer,
    n_applications_last_12m    integer,                -- only on period = 'all'
    median_cost_of_development numeric(16,2),
    mean_cost_of_development   numeric(16,2),
    sum_cost_of_development    numeric(20,2),
    avg_storeys                numeric(8,2),
    avg_days_to_determination  numeric(10,2),
    record_source              text        NOT NULL DEFAULT 'NSW_PLANNING_PORTAL_DA',
    loaded_at                  timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT da_hex_300m_pkey PRIMARY KEY (hex_id, period)
);

CREATE INDEX IF NOT EXISTS da_hex_300m_period_idx ON silver.da_hex_300m (period);

-- Fully derived from silver.da_application: rebuild wholesale in-transaction.
DELETE FROM silver.da_hex_300m;

INSERT INTO silver.da_hex_300m
    (hex_id, period, n_applications, n_modifications, n_reviews, n_determined,
     sum_new_dwellings, n_applications_last_12m, median_cost_of_development,
     mean_cost_of_development, sum_cost_of_development, avg_storeys,
     avg_days_to_determination)
WITH bounds AS (
    SELECT max(lodgement_date) AS latest FROM silver.da_application WHERE is_usable
), src AS (
    SELECT d.hex_id,
           extract(year FROM d.lodgement_date)::integer AS yr,
           d.application_type,
           d.application_status,
           d.number_of_new_dwellings,
           d.number_of_storeys,
           d.days_to_determination,
           CASE WHEN d.flag_cost_outlier THEN NULL ELSE d.cost_of_development END AS cost,
           (d.lodgement_date > b.latest - interval '12 months')       AS last_12m
      FROM silver.da_application d
      CROSS JOIN bounds b
     WHERE d.is_usable
       AND d.hex_id IS NOT NULL
)
SELECT hex_id,
       coalesce(yr::text, 'all'),
       count(*) FILTER (WHERE application_type = 'Development Application')::integer,
       count(*) FILTER (WHERE application_type = 'Modification Application')::integer,
       count(*) FILTER (WHERE application_type = 'Review of determination')::integer,
       count(*) FILTER (WHERE application_status = 'Determined')::integer,
       sum(number_of_new_dwellings)::integer,
       CASE WHEN yr IS NULL
            THEN count(*) FILTER (WHERE last_12m)::integer END,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY cost)::numeric(16,2),
       round(avg(cost), 2),
       sum(cost),
       round(avg(number_of_storeys), 2),
       round(avg(days_to_determination), 2)
  FROM src
 GROUP BY GROUPING SETS ((hex_id, yr), (hex_id));
