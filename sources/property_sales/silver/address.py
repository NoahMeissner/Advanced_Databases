"""Normalise PSI addresses and legal descriptions into join keys.

Two routes lead from a PSI sale to a location:

* **Address -> G-NAF.** PSI splits the address into unit, house number, street
  and locality, and abbreviates street types ("ST", "CRES"). G-NAF stores the
  same thing as flat number, number_first(+suffix), street name, street type
  code ("STREET") and locality. ``split_address`` produces G-NAF-shaped fields.
* **Lot/plan -> NSW cadastre.** The legal description ("69/SP106623",
  "748/1289945", "5/2/1234") names the parcel. ``parse_lot_plan`` turns it
  into the DCDB ``lotidstring`` form ("69//SP106623"), which joins to cadastre
  polygons -- a geometry match that survives address typos.
"""

import re

from ..psi_format import STREET_SUFFIXES, STREET_TYPES

_NUMBER = re.compile(r"^(\d+)\s*([A-Z]{0,2})$")
_LOT_PLAN = re.compile(r"([0-9A-Z]+)/(?:([0-9A-Z]+)/)?(SP)?(\d+)\b")
_SPACES = re.compile(r"\s+")


def _clean(text: str) -> str:
    return _SPACES.sub(" ", text.upper()).strip()


def split_number(text: str) -> tuple:
    """Split "35 A" / "35A" / "35" into ``(number, suffix)``; else raw."""
    text = _clean(text)
    match = _NUMBER.match(text)
    if match:
        return match.group(1), match.group(2)
    return text, ""


def split_street(text: str) -> tuple:
    """Split "PACIFIC HWY N" into ``(name, type code, suffix code)``.

    A street whose name would be empty or just "THE" keeps its full text as
    the name ("BROADWAY", "THE ESPLANADE"), matching how G-NAF stores them.
    """
    tokens = _clean(text).split(" ")
    suffix = ""
    if len(tokens) > 2 and tokens[-1] in STREET_SUFFIXES \
            and tokens[-2] in STREET_TYPES:
        suffix = STREET_SUFFIXES[tokens.pop()]
    street_type = ""
    if len(tokens) > 1 and tokens[-1] in STREET_TYPES \
            and tokens[:-1] != ["THE"]:
        street_type = STREET_TYPES[tokens.pop()]
    return " ".join(tokens), street_type, suffix


def split_address(unit: str, house: str, street: str) -> dict:
    """G-NAF-shaped address parts from the three PSI address fields."""
    flat_number, flat_suffix = split_number(unit) if unit else ("", "")
    number_first, number_suffix = split_number(house) if house else ("", "")
    street_name, street_type, street_suffix = split_street(street)
    return {
        "flat_number": flat_number,
        "flat_number_suffix": flat_suffix,
        "number_first": number_first,
        "number_first_suffix": number_suffix,
        "street_name_core": street_name,
        "street_type_code": street_type,
        "street_suffix_code": street_suffix,
    }


def address_label(parts: dict, locality: str, postcode: str) -> str:
    """One-line address, e.g. "4405/88A CHRISTIE STREET, ST LEONARDS NSW 2065"."""
    number = parts["number_first"] + parts["number_first_suffix"]
    if parts["flat_number"]:
        number = (f"{parts['flat_number']}{parts['flat_number_suffix']}"
                  f"/{number}")
    street = " ".join(x for x in (parts["street_name_core"],
                                  parts["street_type_code"],
                                  parts["street_suffix_code"]) if x)
    head = " ".join(x for x in (number, street) if x)
    return f"{head}, {_clean(locality)} NSW {postcode}".strip()


def parse_lot_plan(legal: str) -> dict:
    """First lot/section/plan in a legal description, plus DCDB lotidstring.

    "69/SP106623" -> lot 69, plan SP106623, lotidstring "69//SP106623".
    "748/1289945" -> plan DP1289945 (bare plan numbers are deposited plans).
    """
    match = _LOT_PLAN.search(legal.upper()) if legal else None
    if not match:
        return {"lot": "", "section": "", "plan": "", "lotidstring": ""}
    lot, section, strata, number = match.groups()
    plan = ("SP" if strata else "DP") + number
    return {
        "lot": lot,
        "section": section or "",
        "plan": plan,
        "lotidstring": f"{lot}/{section or ''}/{plan}",
    }
