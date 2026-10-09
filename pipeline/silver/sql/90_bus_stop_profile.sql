-- silver.bus_stop_profile - one row per bus stop, every source joined.
--
-- This is the layer's deliverable: the bus stops are the reference points, and
-- everything else has been reduced to a per-stop measure so Gold never has to
-- join raw sources at query time.
--
-- A TABLE rather than a view, so Metabase dashboards and any Neo4j export stay
-- fast; it is rebuilt from the per-source bridges on every Silver run.
--
-- has_* columns exist because NULL and 0 mean very different things here. A
-- stop with no nearby school and a stop whose traffic data has not been
-- ingested both show NULL in their respective columns; only the has_* flag
-- tells them apart. Never coalesce these to 0 in a report without checking.
--
-- Headline figures are the k-ring ones (the hexagon plus its 6 neighbours,
-- ~900 m across). The containing-hexagon equivalents stay available in
-- silver.bus_stop_da / silver.bus_stop_property_sales for anyone who wants the
-- literal cell.

CREATE TABLE IF NOT EXISTS silver.bus_stop_profile (
    stop_id      integer     PRIMARY KEY REFERENCES silver.bus_stop ON DELETE CASCADE,
    stop_name    text,
    geom         geometry(Point, 4326) NOT NULL,
    geom_m       geometry(Point, 7856) NOT NULL,
    hex_id       text,
    route_count  integer     NOT NULL,

    -- which LGA the stop sits in, inferred from the DA points (63_bus_stop_lga)
    lga_code                        text,
    lga_name                        text,
    lga_assignment_method           text,
    flag_lga_low_confidence         boolean,

    -- rent for that LGA, latest usable quarter. Only 6 of 33 LGAs have rent
    -- data at all, so this is NULL for roughly 4 stops in 5 - see has_rent_data.
    rent_median_weekly_house        numeric(10,2),
    rent_median_weekly_flat         numeric(10,2),
    rent_period                     date,

    -- development applications (k-ring 1, all periods)
    da_n_applications_kring1        integer,
    da_n_modifications_kring1       integer,
    da_sum_new_dwellings_kring1     integer,
    da_median_cost_kring1           numeric(16,2),
    da_n_applications_hex           integer,

    -- property sales (k-ring 1, all periods, all property types)
    sales_n_kring1                  integer,
    sales_median_price_kring1       numeric(16,2),
    sales_median_price_per_m2_kring1 numeric(16,2),
    sales_last_contract_date        date,

    -- schools within 200 m
    n_schools_200m                  integer,
    nearest_school_distance_m       numeric(8,2),
    sum_enrolment_fte_200m          numeric(12,1),
    avg_icsea_200m                  numeric(8,2),

    -- traffic within 500 m (NULL until a segment reference is ingested)
    traffic_avg_vph_rush            numeric(12,2),
    traffic_avg_vph_non_rush        numeric(12,2),
    traffic_avg_vph_night           numeric(12,2),
    traffic_nearest_segment_distance_m numeric(10,2),
    n_segments_500m                 integer,

    -- transit: the stop's own incident edges
    avg_edge_travel_time_peak_s     numeric(10,2),
    avg_edge_travel_time_offpeak_s  numeric(10,2),
    avg_edge_travel_time_morning_s  numeric(10,2),
    avg_edge_travel_time_afternoon_s numeric(10,2),
    avg_edge_travel_time_evening_s  numeric(10,2),
    n_edges                         integer     NOT NULL DEFAULT 0,
    n_edges_zero_timepoint          integer     NOT NULL DEFAULT 0,

    -- coverage: is a NULL above "nothing there" or "no data loaded"?
    has_lga_data      boolean NOT NULL DEFAULT false,
    has_rent_data     boolean NOT NULL DEFAULT false,
    has_da_data       boolean NOT NULL DEFAULT false,
    has_sales_data    boolean NOT NULL DEFAULT false,
    has_school_data   boolean NOT NULL DEFAULT false,
    has_traffic_data  boolean NOT NULL DEFAULT false,
    has_transit_data  boolean NOT NULL DEFAULT false,

    loaded_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS bus_stop_profile_geom_idx ON silver.bus_stop_profile USING gist (geom);
CREATE INDEX IF NOT EXISTS bus_stop_profile_hex_idx  ON silver.bus_stop_profile (hex_id);

DELETE FROM silver.bus_stop_profile;

INSERT INTO silver.bus_stop_profile
    (stop_id, stop_name, geom, geom_m, hex_id, route_count,
     lga_code, lga_name, lga_assignment_method, flag_lga_low_confidence,
     rent_median_weekly_house, rent_median_weekly_flat, rent_period,
     da_n_applications_kring1, da_n_modifications_kring1, da_sum_new_dwellings_kring1,
     da_median_cost_kring1, da_n_applications_hex,
     sales_n_kring1, sales_median_price_kring1, sales_median_price_per_m2_kring1,
     sales_last_contract_date,
     n_schools_200m, nearest_school_distance_m, sum_enrolment_fte_200m, avg_icsea_200m,
     traffic_avg_vph_rush, traffic_avg_vph_non_rush, traffic_avg_vph_night,
     traffic_nearest_segment_distance_m, n_segments_500m,
     avg_edge_travel_time_peak_s, avg_edge_travel_time_offpeak_s,
     avg_edge_travel_time_morning_s, avg_edge_travel_time_afternoon_s,
     avg_edge_travel_time_evening_s, n_edges, n_edges_zero_timepoint,
     has_lga_data, has_rent_data,
     has_da_data, has_sales_data, has_school_data, has_traffic_data, has_transit_data)
WITH transit AS (
    -- every edge touching the stop, in either direction
    SELECT i.stop_id,
           count(DISTINCT i.edge_key)::integer AS n_edges,
           count(*) FILTER (WHERE t.flag_zero_timepoint)::integer AS n_zero,
           round(avg(t.avg_travel_time_s) FILTER (WHERE t.time_band = 'peak'), 2)          AS peak_s,
           round(avg(t.avg_travel_time_s) FILTER (WHERE t.time_band = 'offpeak'), 2)       AS offpeak_s,
           round(avg(t.avg_travel_time_s) FILTER (WHERE t.time_band = 'morning_06_12'), 2) AS morning_s,
           round(avg(t.avg_travel_time_s) FILTER (WHERE t.time_band = 'afternoon_12_18'), 2) AS afternoon_s,
           round(avg(t.avg_travel_time_s) FILTER (WHERE t.time_band = 'evening_18_24'), 2) AS evening_s
      FROM (SELECT edge_key, from_stop_id AS stop_id FROM silver.bus_edge
            UNION ALL
            SELECT edge_key, to_stop_id   AS stop_id FROM silver.bus_edge) i
      JOIN silver.bus_edge_travel_time t USING (edge_key)
     GROUP BY i.stop_id
), rent AS (
    -- the latest usable quarter, pivoted to one row per LGA
    SELECT lga_code,
           max(median_weekly_rent) FILTER (WHERE dwelling_type = 'house') AS house,
           max(median_weekly_rent) FILTER (WHERE dwelling_type = 'flat')  AS flat,
           max(period_start)                                              AS period
      FROM silver.rent_lga_latest
     GROUP BY lga_code
), traffic AS (
    SELECT stop_id,
           max(avg_vehicles_per_hour) FILTER (WHERE daypart = 'rush')     AS vph_rush,
           max(avg_vehicles_per_hour) FILTER (WHERE daypart = 'non_rush') AS vph_non_rush,
           max(avg_vehicles_per_hour) FILTER (WHERE daypart = 'night')    AS vph_night,
           min(nearest_segment_distance_m)                                AS nearest_m,
           max(n_segments_500m)                                           AS n_segments
      FROM silver.bus_stop_traffic
     WHERE daypart_kind = 'summary'
     GROUP BY stop_id
)
SELECT s.stop_id, s.stop_name, s.geom, s.geom_m, s.hex_id, s.route_count,
       sl.lga_code, l.lga_name, sl.assignment_method, sl.flag_low_confidence,
       rt.house, rt.flat, rt.period,
       da.n_applications_kring1, da.n_modifications_kring1, da.sum_new_dwellings_kring1,
       da.median_cost_kring1, da.n_applications_hex,
       ps.n_sales_kring1, ps.median_price_kring1, ps.median_price_per_m2_kring1,
       ps.last_contract_date_kring1,
       sc.n_schools_200m, sc.nearest_school_distance_m, sc.sum_enrolment_fte_200m,
       sc.avg_icsea_200m,
       tr.vph_rush, tr.vph_non_rush, tr.vph_night, tr.nearest_m, tr.n_segments,
       tt.peak_s, tt.offpeak_s, tt.morning_s, tt.afternoon_s, tt.evening_s,
       coalesce(tt.n_edges, 0), coalesce(tt.n_zero, 0),
       sl.stop_id IS NOT NULL,
       rt.lga_code IS NOT NULL AND (rt.house IS NOT NULL OR rt.flat IS NOT NULL),
       da.stop_id IS NOT NULL,
       ps.stop_id IS NOT NULL,
       sc.stop_id IS NOT NULL,
       tr.stop_id IS NOT NULL,
       tt.stop_id IS NOT NULL
  FROM silver.bus_stop s
  LEFT JOIN silver.bus_stop_da da
         ON da.stop_id = s.stop_id AND da.period = 'all'
  LEFT JOIN silver.bus_stop_property_sales ps
         ON ps.stop_id = s.stop_id AND ps.period = 'all' AND ps.property_type = 'all'
  LEFT JOIN silver.bus_stop_lga sl            ON sl.stop_id = s.stop_id
  LEFT JOIN silver.lga l                      ON l.lga_code = sl.lga_code
  LEFT JOIN rent rt                           ON rt.lga_code = sl.lga_code
  LEFT JOIN silver.bus_stop_school_summary sc ON sc.stop_id = s.stop_id
  LEFT JOIN traffic tr                        ON tr.stop_id = s.stop_id
  LEFT JOIN transit tt                        ON tt.stop_id = s.stop_id;
