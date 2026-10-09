-- gold.traffic_ranking - which segments carry the most traffic.
--
-- Deliberately small, and deliberately self-labelling. The traffic source on
-- disk is a 432-row sample: 6 synthetic segment ids ('SEG001'..'SEG006') over
-- 3 days, with NO coordinates and no reference file that would locate them.
--
-- So two things are true at once and both belong in the table rather than only
-- in a README:
--   flag_sample_data   this ranks 6 made-up segments, not Sydney's roads
--   flag_no_geometry   the segment cannot be placed, so no stop can inherit a
--                      traffic figure and n_stops_nearest_segment stays 0
--
-- SEG004 is excluded from the usable aggregates upstream because every one of
-- its hours is quality_flag = 'caution', so it appears here with NULL measures
-- rather than being silently dropped - that is the difference between "no
-- traffic" and "no trustworthy reading".

CREATE TABLE IF NOT EXISTS gold.traffic_ranking (
    segment_id          text        PRIMARY KEY,
    avg_vph_rush        numeric(12,2),
    avg_vph_non_rush    numeric(12,2),
    avg_vph_night       numeric(12,2),
    max_vph             integer,
    rush_to_night_ratio numeric(8,2),
    peak_hour_of_day    smallint,
    n_hours_observed    integer,
    n_days_observed     integer,
    rank_rush           integer,
    n_stops_nearest_segment integer NOT NULL DEFAULT 0,
    flag_sample_data    boolean     NOT NULL DEFAULT false,
    flag_no_geometry    boolean     NOT NULL DEFAULT false,
    loaded_at           timestamptz NOT NULL DEFAULT now()
);

DELETE FROM gold.traffic_ranking;

INSERT INTO gold.traffic_ranking
    (segment_id, avg_vph_rush, avg_vph_non_rush, avg_vph_night, max_vph,
     rush_to_night_ratio, peak_hour_of_day, n_hours_observed, n_days_observed,
     rank_rush, n_stops_nearest_segment, flag_sample_data, flag_no_geometry)
WITH scope AS (
    -- every segment the hourly table knows, so a segment with no usable hours
    -- still appears with NULL measures instead of vanishing
    SELECT DISTINCT segment_id FROM silver.traffic_segment_hourly
), pivoted AS (
    SELECT segment_id,
           max(avg_vehicles_per_hour) FILTER (WHERE daypart = 'rush')     AS rush,
           max(avg_vehicles_per_hour) FILTER (WHERE daypart = 'non_rush') AS non_rush,
           max(avg_vehicles_per_hour) FILTER (WHERE daypart = 'night')    AS night,
           max(max_vehicles_per_hour)                                     AS max_vph,
           max(peak_hour_of_day) FILTER (WHERE daypart = 'rush')          AS peak_hour,
           sum(n_hours_observed) FILTER (WHERE daypart_kind = 'summary')::integer AS hours,
           max(n_days_observed)                                           AS days
      FROM silver.traffic_segment_daypart
     GROUP BY segment_id
), sample_scale AS (
    SELECT count(DISTINCT segment_id)       AS n_segments,
           count(DISTINCT observation_date) AS n_dates
      FROM silver.traffic_segment_hourly
)
SELECT s.segment_id,
       p.rush, p.non_rush, p.night, p.max_vph,
       CASE WHEN p.night > 0 THEN round(p.rush / p.night, 2) END,
       p.peak_hour, p.hours, p.days,
       CASE WHEN p.rush IS NOT NULL
            THEN rank() OVER (ORDER BY p.rush DESC NULLS LAST) END,
       -- silver.bus_stop_traffic is keyed per STOP, so the per-segment figure
       -- is "stops for which this is the closest segment"
       coalesce((SELECT count(*)::integer FROM silver.bus_stop_traffic t
                  WHERE t.nearest_segment_id = s.segment_id
                    AND t.daypart = 'rush'), 0),
       (sc.n_segments <= 10 OR sc.n_dates <= 5),
       NOT EXISTS (SELECT 1 FROM silver.traffic_segment g
                    WHERE g.segment_id = s.segment_id AND g.geom_m IS NOT NULL)
  FROM scope s
  CROSS JOIN sample_scale sc
  LEFT JOIN pivoted p USING (segment_id);
