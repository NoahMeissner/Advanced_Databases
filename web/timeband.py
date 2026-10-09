# @Noah Meissner 9.10.2026
"""Mapping a time of day onto the two service bands the data actually has.

The user picks an hour; the warehouse only knows 'peak' and 'offpeak', because
the project has no raw GTFS feed and the upstream edge file was already
aggregated into those two windows before it reached us. This module is the one
place that mapping lives, and every label it returns names the band it
resolved to, so an hour picker never implies hourly data.

The two bands are not cosmetic. Travel times differ by only about 6% between
them, but 1,703 stop pairs have peak service only and 2,375 offpeak only - so
changing band changes which connections exist at all, which is what actually
moves the reachable area.
"""
from dataclasses import dataclass

PEAK_HOURS = frozenset({7, 8, 9, 16, 17, 18})
"""Morning and afternoon commuter peaks. The source's own window definitions
were not preserved, so these are the conventional Sydney peaks."""

NIGHT_HOURS = frozenset({22, 23, 0, 1, 2, 3, 4})
"""Resolve to offpeak, but flagged: the timetable thins out overnight and the
reachable area is optimistic for these hours."""

DEFAULT_HOUR = 8
PEAK = "peak"
OFFPEAK = "offpeak"


@dataclass(frozen=True)
class TimeOfDay:
    """A chosen hour, and the band the data can answer it with."""
    hour: int
    band: str
    label: str
    flag_reduced_service: bool

    @property
    def clock(self) -> str:
        """'08:00', for the Mono caption under the picker."""
        return f"{self.hour:02d}:00"

    @property
    def caption(self) -> str:
        """'08:00 · morning peak' - the hour and what it resolved to."""
        return f"{self.clock} · {self.label}"


def parse_hour(raw: str | int | None, default: int = DEFAULT_HOUR) -> int:
    """Reads an hour from a query string, falling back to the default.

    Accepts '8', '08' and '08:00' so a hand-edited URL still works.
    """
    if raw is None or raw == "":
        return default
    try:
        hour = int(str(raw).split(":", maxsplit=1)[0])
    except (TypeError, ValueError):
        return default
    return hour if 0 <= hour <= 23 else default


def band_for_hour(hour: int) -> str:
    """'peak' or 'offpeak' - the only two answers the data supports."""
    return PEAK if hour in PEAK_HOURS else OFFPEAK


def label_for_hour(hour: int) -> str:
    """A human name for the hour, naming the band it resolves to."""
    if hour in (7, 8, 9):
        return "morning peak"
    if hour in (16, 17, 18):
        return "afternoon peak"
    if hour in NIGHT_HOURS:
        return "night, reduced service"
    if 10 <= hour <= 15:
        return "midday, off-peak"
    return "evening, off-peak"


def resolve(raw: str | int | None = None) -> TimeOfDay:
    """The full time-of-day context for a request."""
    hour = parse_hour(raw)
    return TimeOfDay(
        hour=hour,
        band=band_for_hour(hour),
        label=label_for_hour(hour),
        flag_reduced_service=hour in NIGHT_HOURS,
    )


def choices() -> list[tuple[int, str]]:
    """(hour, label) for the picker, ordered through the day."""
    return [(hour, f"{hour:02d}:00") for hour in range(24)]
