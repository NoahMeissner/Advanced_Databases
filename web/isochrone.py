# @Noah Meissner 9.10.2026
"""How far you can get by bus, and how long the city centre takes.

REWRITTEN TO FIX A REAL BUG. The first version seeded the search from the
single NEAREST stop. For HARRIS STREET, ULTIMO that is 'Harris St At Macarthur
St', 16 m away and served by exactly ONE route - while 28 stops within 800 m
serve 41 routes between them, including UTS Broadway (15 routes, 518 m) and
Central Station Railway Square (30 routes, 531 m). The old answer was 28 stops
reachable in 20 minutes; the correct answer is 286. Nobody walks to the nearest
stop if a hub is two minutes further, so the search now starts from EVERY stop
in walking distance, each seeded with the time it takes to walk there.

WHY POSTGRES AND NOT NEO4J. Multi-source means one Dijkstra per seed in GDS:
measured at 3.10 s for 28 seeds, and 3.51 s when batched into a single UNWIND -
the cost is the traversals, not the round-trips. A bounded multi-source
recursive CTE over gold.connects_edge returns the identical 286 stops in
0.03 s. Neo4j still holds the graph for Cypher and GDS exploration; this reads
the same edges through their relational projection.

WHAT IS STILL MISSING: waiting time and transfer penalties. The search counts
walking and riding only, so a 20-minute area that needs three buses is
optimistic. Frequency data exists, but the peak/offpeak window lengths were
lost upstream, so turning trip counts into minutes would be invention.
"""
from dataclasses import dataclass, field

from web.db import POINT_M, postgres
from web.timeband import OFFPEAK, PEAK

SEED_RADIUS_M = 800
"""About a 10-minute walk. Inside a 20-minute budget that still leaves half the
time on the bus, and it is what brings the real hubs into range."""

WALK_SPEED_M_PER_MIN = 80
DEFAULT_MINUTES = 20
CENTRAL_STOP_IDS = (200017, 200064)
"""Central Station, Railway Square - stands J and M, the two busiest Central
stops in the feed (30 and 25 routes). Whichever is quicker is the answer."""


@dataclass(frozen=True)
class NearestStop:
    """The closest stop, shown so the reader knows where walking starts."""
    stop_id: int
    stop_name: str
    distance_m: float
    route_count: int


# A flat result record: one search produces all of these together.
@dataclass(frozen=True)
class Reach:  # pylint: disable=too-many-instance-attributes
    """Where you can get to at a given time of day, and how far the centre is."""
    minutes_to_central: float | None
    reach_minutes: int
    band: str
    stop_ids: list[int] = field(default_factory=list)
    n_stops_reachable: int = 0
    n_seed_stops: int = 0
    n_routes_available: int = 0
    nearest: NearestStop | None = None

    @property
    def reachable(self) -> bool:
        """False when no stop is within walking distance at all."""
        return self.n_seed_stops > 0


def _band_column(band: str) -> str:
    """The travel-time column for a band.

    A NULL in the band column means no service in that band, and the join drops
    the edge - which is exactly the time-of-day effect we want.
    """
    return "peak_s" if band == PEAK else "offpeak_s"


def seed_stops(conn, latitude: float, longitude: float,
               radius_m: int = SEED_RADIUS_M) -> list[tuple]:
    """Every stop within walking distance, nearest first.

    Returns (stop_id, stop_name, route_count, distance_m, walk_seconds). The
    name and route count ride along because the first row IS the nearest stop -
    asking for it separately would mean a second query on a second connection
    for data this one already has.
    """
    return conn.execute(
        f"""
        SELECT s.stop_id, s.stop_name, s.route_count,
               ST_Distance(s.geom_m, {POINT_M}) AS distance_m,
               ST_Distance(s.geom_m, {POINT_M}) / %s * 60.0 AS walk_s
          FROM silver.bus_stop s
         WHERE ST_DWithin(s.geom_m, {POINT_M}, %s)
         ORDER BY distance_m
        """,
        [longitude, latitude, longitude, latitude, float(WALK_SPEED_M_PER_MIN),
         longitude, latitude, radius_m],
    ).fetchall()


def reach(latitude: float, longitude: float, minutes: int = DEFAULT_MINUTES,
          band: str = OFFPEAK) -> Reach:
    """Stops reachable within `minutes`, walking to any nearby stop first."""
    budget_s = minutes * 60.0
    column = _band_column(band)

    with postgres() as conn:
        seeds = seed_stops(conn, latitude, longitude)
        walkable = [(stop_id, walk_s) for stop_id, _, _, _, walk_s in seeds
                    if walk_s <= budget_s]
        if not walkable:
            return Reach(None, minutes, band)

        # seeds are ordered by distance, so the first is the nearest stop
        first = seeds[0]
        nearest = NearestStop(stop_id=first[0], stop_name=first[1],
                              route_count=first[2], distance_m=float(first[3]))

        # One bounded multi-source search: every seed starts at its own walking
        # time, the budget prunes the recursion, and min(cost) per stop is the
        # earliest arrival by any route from any of them.
        rows = conn.execute(
            f"""
            WITH RECURSIVE seed(stop_id, cost) AS (
                SELECT * FROM unnest(%s::integer[], %s::numeric[])
            ), search(stop_id, cost) AS (
                SELECT stop_id, cost FROM seed
                UNION ALL
                SELECT e.to_stop_id, s.cost + e.{column}
                  FROM search s
                  JOIN gold.connects_edge e ON e.from_stop_id = s.stop_id
                 WHERE e.{column} IS NOT NULL
                   AND s.cost + e.{column} <= %s
            )
            SELECT stop_id, min(cost) AS cost
              FROM search
             GROUP BY stop_id
            """,
            [[s for s, _ in walkable], [w for _, w in walkable], budget_s],
        ).fetchall()

        costs = {int(stop_id): float(cost) for stop_id, cost in rows}
        routes = conn.execute(
            "SELECT count(DISTINCT r) FROM silver.bus_stop s, unnest(s.routes_served) r"
            " WHERE s.stop_id = ANY(%s)",
            [[s for s, _ in walkable]],
        ).fetchone()[0]

    central = [costs[stop] for stop in CENTRAL_STOP_IDS if stop in costs]
    return Reach(
        # Central comes out of the same search, so the headline figure and the
        # shaded area can no longer disagree
        minutes_to_central=round(min(central) / 60.0) if central else None,
        reach_minutes=minutes,
        band=band,
        stop_ids=sorted(costs),
        n_stops_reachable=len(costs),
        n_seed_stops=len(walkable),
        n_routes_available=routes or 0,
        nearest=nearest,
    )


def reach_polygon(stop_ids: list[int]) -> str | None:
    """The reachable area as GeoJSON.

    Built in PostGIS from the stop ids: a concave hull hugs the served
    corridors instead of claiming the empty space between them.
    """
    if len(stop_ids) < 4:
        return None
    with postgres() as conn:
        row = conn.execute(
            "SELECT ST_AsGeoJSON(ST_Transform("
            "    ST_ConcaveHull(ST_Collect(geom_m), 0.4), 4326))"
            "  FROM silver.bus_stop WHERE stop_id = ANY(%s)",
            [stop_ids],
        ).fetchone()
    return row[0] if row and row[0] else None
