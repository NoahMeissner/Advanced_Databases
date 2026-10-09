-- Checks for the routing table and the suburb rankings.
--
-- gold.connects_edge is a second copy of edges that also live in
-- gold.graph_edge and in Neo4j. Two copies that can disagree is exactly how a
-- map and a report start telling a user different things, so the first check
-- is that they cannot drift.

SELECT 'gold.connects_edge'::text, 'matches_graph_edge'::text,
       'consistency'::text, 'error'::text,
       abs((SELECT count(*) FROM gold.connects_edge)
           - (SELECT count(*) FROM gold.graph_edge WHERE rel_type = 'CONNECTS'))::bigint,
       (SELECT count(*) FROM gold.graph_edge WHERE rel_type = 'CONNECTS')::bigint,
       NULL::numeric, NULL::jsonb
UNION ALL
SELECT 'gold.connects_edge', 'same_endpoints_as_graph', 'consistency', 'error',
       (SELECT count(*) FROM gold.connects_edge c
         WHERE NOT EXISTS (SELECT 1 FROM gold.graph_edge g
                            WHERE g.rel_type = 'CONNECTS'
                              AND g.from_key = c.from_stop_id::text
                              AND g.to_key = c.to_stop_id::text)),
       (SELECT count(*) FROM gold.connects_edge), NULL, NULL
UNION ALL
-- A zero or NULL weight is a free hop: the search would walk the whole network
-- for nothing and report an absurd reachable area.
SELECT 'gold.connects_edge', 'weights_positive', 'validity', 'error',
       (SELECT count(*) FROM gold.connects_edge
         WHERE travel_time_s IS NULL OR travel_time_s <= 0
            OR (peak_s IS NOT NULL AND peak_s <= 0)
            OR (offpeak_s IS NOT NULL AND offpeak_s <= 0)),
       (SELECT count(*) FROM gold.connects_edge), NULL, NULL
UNION ALL
-- Every edge must run in at least one band, or it is unreachable at any hour
-- and should not be in a routing table at all.
SELECT 'gold.connects_edge', 'serves_some_band', 'completeness', 'error',
       (SELECT count(*) FROM gold.connects_edge
         WHERE peak_s IS NULL AND offpeak_s IS NULL),
       (SELECT count(*) FROM gold.connects_edge), NULL, NULL
UNION ALL
-- The band split IS the time-of-day effect, so its size is worth watching:
-- travel times differ only ~6% between bands, but which edges exist differs a
-- lot, and that is what moves the reachable area.
SELECT 'gold.connects_edge', 'band_coverage', 'completeness', 'warn',
       0::bigint,
       (SELECT count(*) FROM gold.connects_edge)::bigint, NULL,
       (SELECT jsonb_build_object(
            'both_bands', count(*) FILTER (WHERE peak_s IS NOT NULL
                                             AND offpeak_s IS NOT NULL),
            'peak_only', count(*) FILTER (WHERE peak_s IS NOT NULL
                                            AND offpeak_s IS NULL),
            'offpeak_only', count(*) FILTER (WHERE offpeak_s IS NOT NULL
                                               AND peak_s IS NULL))
          FROM gold.connects_edge)
UNION ALL
SELECT 'gold.suburb_comparison', 'min_sales_enforced', 'validity', 'error',
       (SELECT count(*) FROM gold.suburb_comparison WHERE n_sales < 30),
       (SELECT count(*) FROM gold.suburb_comparison), NULL, NULL
UNION ALL
-- The denominator is printed next to every rank, so it must be the truth.
SELECT 'gold.suburb_comparison', 'denominator_correct', 'consistency', 'error',
       (SELECT count(*) FROM gold.suburb_comparison
         WHERE n_ranked <> (SELECT count(*) FROM gold.suburb_comparison)),
       (SELECT count(*) FROM gold.suburb_comparison), NULL,
       (SELECT jsonb_build_object('suburbs_ranked', count(*)) FROM gold.suburb_comparison)
UNION ALL
SELECT 'gold.suburb_comparison', 'ranks_dense_from_one', 'validity', 'error',
       (SELECT CASE WHEN min(rank_median_price) = 1
                     AND max(rank_median_price) <= count(*) THEN 0 ELSE 1 END
          FROM gold.suburb_comparison)::bigint,
       1::bigint, NULL, NULL
UNION ALL
SELECT 'gold.suburb_comparison', 'medians_plausible', 'accuracy', 'error',
       (SELECT count(*) FROM gold.suburb_comparison
         WHERE median_price IS NOT NULL
           AND median_price NOT BETWEEN 100000 AND 50000000),
       (SELECT count(*) FROM gold.suburb_comparison), NULL,
       (SELECT jsonb_build_object('min', min(median_price), 'max', max(median_price))
          FROM gold.suburb_comparison)
UNION ALL
-- Price level and price per m2 can disagree sharply - Ultimo is 682nd on one
-- and 45th on the other. That is a real composition effect, and the report
-- explains it, so this records how widespread the divergence is.
SELECT 'gold.suburb_comparison', 'level_vs_per_m2_divergence', 'accuracy', 'warn',
       (SELECT count(*) FROM gold.suburb_comparison
         WHERE abs(rank_median_price - rank_price_per_m2) > 200),
       (SELECT count(*) FROM gold.suburb_comparison), 0.40,
       jsonb_build_object('note',
           'median price and price per m2 measure different things; both are published')
UNION ALL
-- Rent ranks out of 6 LGAs, never 776 suburbs. If the denominator ever stopped
-- matching the rows that actually have rent, the page would overstate coverage.
SELECT 'gold.lga_comparison', 'rent_rank_denominator', 'consistency', 'error',
       (SELECT count(*) FROM gold.lga_comparison
         WHERE n_ranked_rent <> (SELECT count(*) FROM gold.lga_comparison
                                  WHERE median_rent_weekly_house IS NOT NULL)),
       (SELECT count(*) FROM gold.lga_comparison), NULL,
       (SELECT jsonb_build_object('lgas_with_rent', max(n_ranked_rent),
                                  'lgas_total', count(*))
          FROM gold.lga_comparison);
