# @Noah Meissner 9.10.2026
"""get_report(address) - the one seam the whole site reads.

The design handoff asks for "a typed getReport(address) function so real data
sources can be plugged in later". The sources already exist, so this is where
the warehouse becomes a page: every template, every JSON endpoint and every map
layer reads the Report built here, and nothing queries the database behind its
back.

Four sections, matching the design:

  01 Schools    silver.school within WALK_RADIUS_M of the address point
  02 Activity   gold.transit_segment near the address. NOT noise - see below
  03 Commute    the Neo4j graph, from the nearest stop
  04 Market     silver.property_sale over the address's hexagon neighbourhood

WHY SECTION 02 IS NOT NOISE. The design specifies decibels and distance to the
nearest main road. This project has no noise measurements and no road
centrelines, and its traffic source is six synthetic segments without
coordinates. Rather than present invented decibels, section 02 reports scheduled
bus traffic on real geometry as a street-activity proxy, and labels it as such.

Everything the data cannot support honestly is collected in Report.caveats and
rendered on the page, not left in a README.
"""
from dataclasses import dataclass, field
from datetime import date

from web.db import POINT_M, postgres
from web.geocode import ResolvedAddress, resolve
from web.isochrone import WALK_SPEED_M_PER_MIN, NearestStop, reach
from web.timeband import TimeOfDay
from web.timeband import resolve as resolve_time

WALK_RADIUS_M = 1200
WALK_MINUTES = WALK_RADIUS_M // WALK_SPEED_M_PER_MIN
"""A 15-minute walk at 80 m/min. The design's copy says "12-minute walk"; the
radius is kept slightly wider so the list is not empty in low-density suburbs,
and every row still shows its own distance."""

ACTIVITY_RADIUS_M = 300
SCHOOL_LIST_LIMIT = 3
PRICE_SERIES_YEARS = 10
CHANGE_WINDOW_YEARS = 5

PIPELINE_STATUSES = (
    "Under Assessment", "Additional Information Requested",
    "Deferred Commencement", "Pending Lodgement", "On Exhibition",
)
"""Applications still moving - the forward-looking half of the pipeline.
6,633 of them across Sydney, worth $27.2 bn. Everything else is either already
determined (154,477, $238.8 bn) or withdrawn, and neither predicts anything."""


@dataclass(frozen=True)
class NearbySchool:
    """One school near the address, numbered to match the map markers."""
    rank: int
    school_code: int
    name: str
    level: str | None
    distance_m: float
    icsea: float | None
    enrolment: float | None


@dataclass(frozen=True)
class Activity:
    """Scheduled bus traffic near the address - a proxy, never decibels."""
    trips_per_day: int
    n_segments: int
    busiest_segment_m: float | None
    busiest_routes: list[str]
    band: int
    scale_position: int
    label: str


# A flat result record: the reach figures plus the time they were computed at.
@dataclass(frozen=True)
class Commute:  # pylint: disable=too-many-instance-attributes
    """Bus-only, timetabled travel, at a chosen time of day."""
    stop: NearestStop | None
    minutes_to_central: float | None
    reach_minutes: int
    n_stops_reachable: int
    n_seed_stops: int
    n_routes_available: int
    time_of_day: TimeOfDay
    stop_ids: list[int] = field(default_factory=list)


@dataclass(frozen=True)
class Investment:
    """Development money committed nearby - the forward-looking signal.

    Split on purpose: a determined application from 2019 says what already
    happened, while one still under assessment says what is coming. Lumping
    them into one total predicts nothing.
    """
    pipeline_n: int
    pipeline_value: int | None
    pipeline_dwellings: int | None
    determined_n: int
    determined_value: int | None
    determined_dwellings: int | None
    largest_project: str | None

    @property
    def has_pipeline(self) -> bool:
        """True when something nearby is still in train."""
        return self.pipeline_n > 0


@dataclass(frozen=True)
class Rank:
    """One ranked measure: where it sits, out of how many, and its value.

    The denominator travels with the rank because it changes per measure -
    suburbs are ranked out of 776, rent out of 6 - and "2nd" without it would
    imply a Sydney-wide ranking the rent data cannot support.
    """
    rank: int | None
    n_ranked: int
    value: float | None = None
    unit: str = "suburbs"

    @property
    def known(self) -> bool:
        """False when this measure could not be ranked for this place."""
        return self.rank is not None and self.n_ranked > 0

    @property
    def ordinal(self) -> str:
        """1 -> '1st', 682 -> '682nd'."""
        if self.rank is None:
            return "n/a"
        if 10 <= self.rank % 100 <= 20:
            suffix = "th"
        else:
            suffix = {1: "st", 2: "nd", 3: "rd"}.get(self.rank % 10, "th")
        return f"{self.rank}{suffix}"

    @property
    def summary(self) -> str:
        """'682nd of 776 suburbs'."""
        return f"{self.ordinal} of {self.n_ranked:,} {self.unit}"


@dataclass(frozen=True)
class Rankings:
    """Where this suburb sits against every other, on each measure.

    price and price_per_m2 are both carried because they can disagree sharply:
    Ultimo is 682nd of 776 on median price but 45th per square metre -
    cheap-looking only because it is mostly small apartments. Publishing the
    level alone would be misleading.
    """
    locality: str
    n_sales: int
    price: Rank
    price_per_m2: Rank
    growth: Rank
    rent_house: Rank
    lga_name: str | None


@dataclass(frozen=True)
class PriceChange:
    """How prices moved, and over exactly which window."""
    pct: float | None
    from_year: int | None
    to_year: int | None

    @property
    def years(self) -> int | None:
        """The real window, which is not always the 5 years asked for."""
        if self.from_year is None or self.to_year is None:
            return None
        return self.to_year - self.from_year


@dataclass(frozen=True)
class Rent:
    """LGA-level rent. Exists for only 6 of 33 LGAs."""
    lga_name: str | None
    house: float | None
    flat: float | None
    period: date | None

    @property
    def available(self) -> bool:
        """False for roughly four addresses in five."""
        return self.house is not None or self.flat is not None


@dataclass(frozen=True)
class Market:
    """Prices around the address, and rent for its LGA if we have any."""
    n_sales: int
    median_price: int | None
    price_per_m2: int | None
    change: PriceChange
    price_series: list[tuple[int, int]]
    rent: Rent


@dataclass(frozen=True)
class KeyFigure:
    """One of the four top-line numbers on the report."""
    value: str
    label: str


# One field per section of the page; grouping them further would only move the
# report's own structure somewhere it is harder to read.
@dataclass(frozen=True)
class Report:  # pylint: disable=too-many-instance-attributes
    """Everything one address report shows."""
    address: ResolvedAddress
    summary: str
    schools: list[NearbySchool]
    activity: Activity
    commute: Commute
    market: Market
    investment: Investment
    rankings: Rankings | None
    key_figures: list[KeyFigure]
    caveats: list[str]
    generated_on: date

    @property
    def file_name(self) -> str:
        """The Mono caption above the page, and the PDF's suggested name."""
        slug = "".join(
            c.lower() if c.isalnum() else "-" for c in self.address.address_text
        )
        while "--" in slug:
            slug = slug.replace("--", "-")
        return f"report-{slug.strip('-')[:48]}.pdf"


def _schools(conn, address: ResolvedAddress) -> list[NearbySchool]:
    """Schools within walking distance, nearest first."""
    rows = conn.execute(
        f"""
        SELECT s.school_code, s.school_name, s.level_of_schooling,
               ST_Distance(s.geom_m, {POINT_M}) AS distance_m,
               s.icsea_value, s.latest_year_enrolment_fte
          FROM silver.school s
         WHERE s.is_usable
           AND ST_DWithin(s.geom_m, {POINT_M}, %s)
         ORDER BY distance_m
        """,
        [address.longitude, address.latitude,
         address.longitude, address.latitude, WALK_RADIUS_M],
    ).fetchall()
    return [
        NearbySchool(rank=i, school_code=r[0], name=r[1], level=r[2],
                     distance_m=round(float(r[3])), icsea=r[4], enrolment=r[5])
        for i, r in enumerate(rows, start=1)
    ]


def _activity(conn, address: ResolvedAddress) -> Activity:
    """Bus trips per day on the segments around the address."""
    row = conn.execute(
        f"""
        WITH near AS (
            SELECT t.trips_per_day, t.route_short_names, t.activity_band,
                   ST_Distance(t.geom_m, {POINT_M}) AS distance_m
              FROM gold.transit_segment t
             WHERE NOT t.flag_long_segment
               AND ST_DWithin(t.geom_m, {POINT_M}, %s)
        )
        SELECT coalesce(sum(trips_per_day), 0)::integer,
               count(*)::integer,
               min(distance_m),
               coalesce(max(activity_band), 0),
               (SELECT route_short_names FROM near
                 ORDER BY trips_per_day DESC LIMIT 1)
          FROM near
        """,
        [address.longitude, address.latitude,
         address.longitude, address.latitude, ACTIVITY_RADIUS_M],
    ).fetchone()

    trips, n_segments, nearest_m, band, routes = row
    labels = {0: "No data", 1: "Very quiet", 2: "Quiet",
              3: "Moderate", 4: "Busy", 5: "Very busy"}
    return Activity(
        trips_per_day=trips,
        n_segments=n_segments,
        busiest_segment_m=round(float(nearest_m)) if nearest_m is not None else None,
        busiest_routes=list(routes or [])[:4],
        band=band,
        # the gradient bar's marker: 5 bands mapped onto 10..90% so the marker
        # never sits off the end of the track
        scale_position=10 + (max(band, 1) - 1) * 20,
        label=labels.get(band, "No data"),
    )


def _rent(conn, stop: NearestStop | None) -> Rent:
    """Rent for the LGA the nearest stop sits in, if that LGA has any."""
    if stop is None:
        return Rent(None, None, None, None)
    row = conn.execute(
        """
        SELECT l.lga_name,
               max(r.median_weekly_rent) FILTER (WHERE r.dwelling_type = 'house'),
               max(r.median_weekly_rent) FILTER (WHERE r.dwelling_type = 'flat'),
               max(r.period_start)
          FROM silver.bus_stop_lga sl
          JOIN silver.lga l USING (lga_code)
          LEFT JOIN silver.rent_lga_latest r ON r.lga_code = sl.lga_code
         WHERE sl.stop_id = %s
         GROUP BY l.lga_name
        """,
        [stop.stop_id],
    ).fetchone()
    return Rent(*row) if row else Rent(None, None, None, None)


def _price_change(points: list[tuple[int, int]]) -> PriceChange:
    """The change over CHANGE_WINDOW_YEARS, or the longest window available."""
    if not points:
        return PriceChange(None, None, None)
    to_year, to_price = points[-1]
    earlier = [(y, p) for y, p in points if y <= to_year - CHANGE_WINDOW_YEARS]
    if not earlier or not earlier[-1][1]:
        return PriceChange(None, None, to_year)
    from_year, from_price = earlier[-1]
    return PriceChange(round(100.0 * (to_price - from_price) / from_price, 1),
                       from_year, to_year)


def _hex_ring(conn, hex_id: str | None) -> list[str]:
    """The hexagon plus its 6 neighbours (~900 m across).

    A single 300 m cell is too sparse to carry a median or a sensible
    investment total, so every neighbourhood figure uses the ring.
    """
    if hex_id is None:
        return []
    return conn.execute(
        "SELECT array_agg(neighbour_hex_id) FROM silver.hex_300m_neighbour"
        " WHERE hex_id = %s", [hex_id],
    ).fetchone()[0] or [hex_id]


def _market(conn, ring: list[str], stop: NearestStop | None) -> Market:
    """Prices over the address's hexagon neighbourhood, plus LGA rent."""
    if not ring:
        return Market(0, None, None, PriceChange(None, None, None), [],
                      _rent(conn, stop))

    # re-aggregated from the sales themselves: an average of hexagon medians
    # would not be a median of anything
    totals = conn.execute(
        """
        SELECT count(*)::integer,
               percentile_cont(0.5) WITHIN GROUP (ORDER BY purchase_price),
               percentile_cont(0.5) WITHIN GROUP (ORDER BY price_per_m2)
          FROM silver.property_sale
         WHERE is_usable AND hex_id = ANY(%s)
        """,
        [ring],
    ).fetchone()

    series = conn.execute(
        """
        SELECT contract_year,
               percentile_cont(0.5) WITHIN GROUP (ORDER BY purchase_price)
          FROM silver.property_sale
         WHERE is_usable AND hex_id = ANY(%s) AND contract_year IS NOT NULL
         GROUP BY contract_year
        HAVING count(*) >= 3
         ORDER BY contract_year
        """,
        [ring],
    ).fetchall()
    points = [(int(y), int(p)) for y, p in series if p is not None]

    return Market(
        n_sales=totals[0],
        median_price=int(totals[1]) if totals[1] is not None else None,
        price_per_m2=int(totals[2]) if totals[2] is not None else None,
        change=_price_change(points),
        price_series=points[-PRICE_SERIES_YEARS:],
        rent=_rent(conn, stop),
    )


def _investment(conn, ring: list[str]) -> Investment:
    """Development money in the address's hexagon neighbourhood.

    flag_cost_outlier rows are excluded: the source's 21.6 bn maximum would
    otherwise be the entire answer for whichever cell contains it.
    """
    row = conn.execute(
        """
        SELECT count(*) FILTER (WHERE application_status = ANY(%s))::integer,
               sum(cost_of_development) FILTER (WHERE application_status = ANY(%s)),
               sum(number_of_new_dwellings) FILTER (WHERE application_status = ANY(%s)),
               count(*) FILTER (WHERE application_status = 'Determined')::integer,
               sum(cost_of_development) FILTER (WHERE application_status = 'Determined'),
               sum(number_of_new_dwellings) FILTER (WHERE application_status = 'Determined')
          FROM silver.da_application
         WHERE is_usable AND NOT flag_cost_outlier AND hex_id = ANY(%s)
        """,
        [list(PIPELINE_STATUSES)] * 3 + [ring],
    ).fetchone()

    largest = conn.execute(
        """
        SELECT full_address, cost_of_development
          FROM silver.da_application
         WHERE is_usable AND NOT flag_cost_outlier AND hex_id = ANY(%s)
           AND application_status = ANY(%s) AND cost_of_development > 0
         ORDER BY cost_of_development DESC
         LIMIT 1
        """,
        [ring, list(PIPELINE_STATUSES)],
    ).fetchone()

    return Investment(
        pipeline_n=row[0],
        pipeline_value=int(row[1]) if row[1] is not None else None,
        pipeline_dwellings=int(row[2]) if row[2] is not None else None,
        determined_n=row[3],
        determined_value=int(row[4]) if row[4] is not None else None,
        determined_dwellings=int(row[5]) if row[5] is not None else None,
        largest_project=largest[0] if largest else None,
    )


def _rankings(conn, address: ResolvedAddress) -> Rankings | None:
    """Where the address's suburb sits against every other ranked suburb."""
    if not address.locality:
        return None
    row = conn.execute(
        """
        SELECT s.locality, s.n_sales, s.rank_median_price, s.rank_price_per_m2,
               s.rank_change_5y, s.n_ranked, s.n_ranked_change,
               s.median_price, s.price_per_m2, s.change_5y_pct,
               s.lga_name, l.rank_median_rent_house, l.n_ranked_rent
          FROM gold.suburb_comparison s
          LEFT JOIN gold.lga_comparison l ON l.lga_code = s.lga_code
         WHERE s.locality = %s
        """,
        [address.locality.upper()],
    ).fetchone()
    if row is None:
        return None
    return Rankings(
        locality=row[0],
        n_sales=row[1],
        price=Rank(row[2], row[5], float(row[7]) if row[7] is not None else None),
        price_per_m2=Rank(row[3], row[5],
                          float(row[8]) if row[8] is not None else None),
        growth=Rank(row[4], row[6], float(row[9]) if row[9] is not None else None),
        rent_house=Rank(row[11], row[12] or 0, unit="LGAs"),
        lga_name=row[10],
    )


def _summary(address: ResolvedAddress, schools: list[NearbySchool],
             activity: Activity, commute: Commute, market: Market) -> str:
    """The one-paragraph statement under the address heading."""
    parts = []
    if schools:
        parts.append(f"{len(schools)} school{'s' if len(schools) > 1 else ''} "
                     f"within a {WALK_MINUTES}-minute walk")
    if commute.minutes_to_central is not None:
        parts.append(f"{commute.minutes_to_central:.0f} minutes to Central by bus "
                     f"at {commute.time_of_day.clock}")
    if activity.band:
        parts.append(f"{activity.label.lower()} street activity")
    if market.change.pct is not None:
        direction = "risen" if market.change.pct >= 0 else "fallen"
        parts.append(f"prices have {direction} "
                     f"{abs(market.change.pct):.0f}% since {market.change.from_year}")
    if not parts:
        return (f"No measurements are available around {address.address_text} "
                "in the data loaded so far.")
    return ". ".join(part[0].upper() + part[1:] for part in parts) + "."


def _key_figures(schools: list[NearbySchool], activity: Activity,
                 commute: Commute, rankings: Rankings | None) -> list[KeyFigure]:
    """The four figures across the top of the page.

    The fourth is the suburb's price RANK rather than its own price change: in
    the same space it says more, because a number only means something next to
    the other 775 suburbs.
    """
    nearest = f"{schools[0].distance_m:.0f} m" if schools else "none"
    central = (f"{commute.minutes_to_central:.0f} min"
               if commute.minutes_to_central is not None else "n/a")
    if rankings and rankings.price.known:
        rank_value = rankings.price.ordinal
        rank_label = f"of {rankings.price.n_ranked} suburbs by price"
    else:
        rank_value, rank_label = "n/a", "suburb price rank"
    return [
        KeyFigure(nearest, "nearest school"),
        KeyFigure(activity.label, "street activity"),
        KeyFigure(central, f"to Central, {commute.time_of_day.clock}"),
        KeyFigure(rank_value, rank_label),
    ]


def _caveats(address: ResolvedAddress, commute: Commute, market: Market,
             rankings: Rankings | None) -> list[str]:
    """What the reader has to know to read the numbers correctly."""
    out = []
    if not address.is_exact:
        out.append(
            f"Located to the centre of {address.address_text} "
            f"(±{address.accuracy_m:.0f} m), not to the exact address."
        )
    out.append(
        "Travel times are scheduled bus journeys only - this project has no "
        "train, metro or ferry data, and waiting and transfer time is not "
        "counted."
    )
    out.append(
        f"{commute.time_of_day.clock} resolves to the "
        f"\u2018{commute.time_of_day.band}\u2019 timetable - the data has two "
        "service bands, not hourly detail."
    )
    if commute.time_of_day.flag_reduced_service:
        out.append("Overnight service is thin, so the reachable area shown for "
                   "this hour is optimistic.")
    if rankings and rankings.price.known and rankings.price_per_m2.known:
        if abs(rankings.price.rank - rankings.price_per_m2.rank) > 200:
            out.append(
                f"{rankings.locality} ranks {rankings.price.ordinal} on median "
                f"price but {rankings.price_per_m2.ordinal} per square metre - "
                "the difference is dwelling size, not value."
            )
    out.append(
        "Street activity is scheduled bus traffic nearby, used as a proxy. "
        "It is not a noise measurement."
    )
    if rankings and rankings.rent_house.known:
        out.append(f"The rent rank is out of {rankings.rent_house.n_ranked} LGAs, "
                   "not all of Sydney - rent data covers 6 of 33.")
    if not market.rent.available:
        out.append("No rent data exists for this area - it covers 6 of 33 LGAs.")
    elif market.rent.period:
        out.append(f"Rent is the median for {market.rent.lga_name} in the quarter "
                   f"from {market.rent.period:%B %Y}; only four quarters exist, so "
                   "no multi-year rent trend can be shown.")
    return out


def get_report(query: str, at_hour: str | int | None = None) -> Report | None:
    """Builds the full report for a typed address, at a given time of day."""
    address = resolve(query)
    if address is None:
        return None

    time_of_day = resolve_time(at_hour)
    # Seeded from EVERY stop in walking distance, not just the nearest - see
    # web/isochrone.py for why that distinction is the whole ballgame.
    found = reach(address.latitude, address.longitude, band=time_of_day.band)
    commute = Commute(
        stop=found.nearest,
        minutes_to_central=found.minutes_to_central,
        reach_minutes=found.reach_minutes,
        n_stops_reachable=found.n_stops_reachable,
        n_seed_stops=found.n_seed_stops,
        n_routes_available=found.n_routes_available,
        time_of_day=time_of_day,
        stop_ids=found.stop_ids,
    )

    with postgres() as conn:
        ring = _hex_ring(conn, address.hex_id)
        schools = _schools(conn, address)
        activity = _activity(conn, address)
        market = _market(conn, ring, found.nearest)
        investment = _investment(conn, ring) if ring else Investment(
            0, None, None, 0, None, None, None)
        rankings = _rankings(conn, address)

    return Report(
        address=address,
        summary=_summary(address, schools, activity, commute, market),
        schools=schools,
        activity=activity,
        commute=commute,
        market=market,
        investment=investment,
        rankings=rankings,
        key_figures=_key_figures(schools, activity, commute, rankings),
        caveats=_caveats(address, commute, market, rankings),
        generated_on=date.today(),
    )
