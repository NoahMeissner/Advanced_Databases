# @Noah Meissner 9.10.2026
"""Turning typed text into a point on the map.

There is no G-NAF in this project, so gold.address_point is the gazetteer:
121k exact development-application addresses plus 26.5k street centres. Matching
is trigram similarity (pg_trgm), which tolerates abbreviations and typos -
"59 Enmore Rd Newtown" finds "59 ENMORE ROAD NEWTOWN 2042".

Every resolved address carries its own precision, because the two tiers are not
equally good and the report has to say so rather than imply address-level
accuracy everywhere.
"""
import re
from dataclasses import dataclass

from web.db import postgres

SUGGEST_LIMIT = 6
MIN_QUERY_LENGTH = 3
SUGGEST_FLOOR = 0.15
"""Autocomplete stays permissive: the user is mid-word, so a weak match is
still a useful suggestion they can read and reject."""

RESOLVE_FLOOR = 0.50
"""Committing to a point is stricter than suggesting one. Measured on this
gazetteer, real queries score 0.63-1.00 while "12 example st newtown" - a
street that does not exist - scores 0.368 against an unrelated street. Below
0.50 the honest answer is "not found", not a pin in the wrong place."""

_NORMALISE = "upper(regexp_replace(%s, '[^A-Za-z0-9]+', ' ', 'g'))"
_HOUSE_NUMBER = re.compile(r"^\s*(\d+)")
RESOLVE_CANDIDATES = 12


def house_number(text: str) -> str | None:
    """The leading house number of a typed address, if it has one."""
    match = _HOUSE_NUMBER.match(text or "")
    return match.group(1) if match else None


@dataclass(frozen=True)
class Suggestion:
    """One autocomplete row: the street line plus its muted locality line."""
    address_id: str
    address_text: str
    primary: str
    secondary: str
    precision: str


# A geocode result is a flat record by nature: identity, position, precision
# and the locality parts, none of which group meaningfully.
@dataclass(frozen=True)
class ResolvedAddress:  # pylint: disable=too-many-instance-attributes
    """A geocoded address, with how precisely it is known."""
    address_id: str
    address_text: str
    latitude: float
    longitude: float
    precision: str
    accuracy_m: float
    hex_id: str | None
    locality: str | None
    postcode: str | None

    @property
    def is_exact(self) -> bool:
        """True when this came from the address tier, not the street tier."""
        return self.precision == "address"

    @property
    def coordinates_label(self) -> str:
        """The report footer's coordinate line, e.g. '-33.90 S / 151.18 E'."""
        return (f"{abs(self.latitude):.2f}° S · "
                f"{abs(self.longitude):.2f}° E")


def _split_label(address_text: str, locality: str | None,
                 postcode: str | None) -> tuple[str, str]:
    """Splits a label into the bold street line and the muted locality line."""
    tail = " ".join(part for part in (locality, "NSW", postcode) if part)
    head = address_text
    if locality and locality.upper() in address_text.upper():
        cut = address_text.upper().rindex(locality.upper())
        head = address_text[:cut].strip(" ,")
    return head or address_text, tail


def suggest(query: str, limit: int = SUGGEST_LIMIT) -> list[Suggestion]:
    """Ranked autocomplete rows for a partial address."""
    text = (query or "").strip()
    if len(text) < MIN_QUERY_LENGTH:
        return []

    # <-> is 1 - similarity, so nearest-first is most-similar-first, and it is
    # the only ordering the GiST index can satisfy without a full recheck.
    sql = f"""
        SELECT address_id, address_text, locality, postcode, precision,
               1 - (search_key <-> {_NORMALISE}) AS score
          FROM gold.address_point
         WHERE search_key %% {_NORMALISE}
         ORDER BY search_key <-> {_NORMALISE}
         LIMIT %s
    """
    with postgres() as conn:
        rows = conn.execute(sql, [text, text, text, limit]).fetchall()

    out = []
    for address_id, address_text, locality, postcode, precision, score in rows:
        if score is not None and score < SUGGEST_FLOOR:
            continue
        primary, secondary = _split_label(address_text, locality, postcode)
        out.append(Suggestion(address_id, address_text, primary, secondary, precision))
    return out


def _pick(candidates: list, wanted_number: str | None):
    """Chooses between an exact-address match and a street-centre match.

    Trigram similarity happily matches "99999 Enmore Road" to "97 Enmore road",
    which would then be served as an EXACT address with accuracy 0 - a pin on
    somebody else's house, presented as certain. So when the query carries a
    house number, an address-tier row only wins if it is that same number;
    otherwise the street centre is the honest answer.
    """
    if not candidates:
        return None

    # No house number typed means the user asked about a STREET, so the street
    # centre is what they asked for - picking some arbitrary house on it would
    # claim a precision they never requested.
    if wanted_number is None:
        for row in candidates:
            if row[4] == "street":
                return row
        return candidates[0]

    for row in candidates:
        if row[4] == "address" and house_number(row[1]) == wanted_number:
            return row
    for row in candidates:
        if row[4] == "street":
            return row
    return candidates[0]


def resolve(query: str) -> ResolvedAddress | None:
    """The single best point for a typed address, or None if nothing matches.

    Accepts an address_id (what a clicked suggestion sends) or free text.
    """
    text = (query or "").strip()
    if not text:
        return None

    columns = ("address_id, address_text, ST_Y(geom), ST_X(geom), precision,"
               " accuracy_m, hex_id, locality, postcode")

    with postgres() as conn:
        row = None
        if len(text) == 32 and all(c in "0123456789abcdef" for c in text):
            row = conn.execute(
                f"SELECT {columns} FROM gold.address_point WHERE address_id = %s",
                [text],
            ).fetchone()
        if row is None:
            # The floor stays a WHERE clause so a hopeless query still returns
            # nothing; the ORDER BY is the index-friendly distance operator.
            candidates = conn.execute(
                f"""SELECT {columns}
                      FROM gold.address_point
                     WHERE search_key %% {_NORMALISE}
                       AND 1 - (search_key <-> {_NORMALISE}) >= %s
                     ORDER BY search_key <-> {_NORMALISE}
                     LIMIT %s""",
                [text, text, RESOLVE_FLOOR, text, RESOLVE_CANDIDATES],
            ).fetchall()
            row = _pick(candidates, house_number(text))

    if row is None:
        return None
    return ResolvedAddress(
        address_id=row[0], address_text=row[1],
        latitude=float(row[2]), longitude=float(row[3]),
        precision=row[4], accuracy_m=float(row[5]),
        hex_id=row[6], locality=row[7], postcode=row[8],
    )
