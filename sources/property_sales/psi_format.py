"""Record layouts and reference data for the current (2001+) PSI format.

Source: "Current Property Sales Data File Format 2001 to Current" (Valuer
General NSW), cross-checked field by field against the 2021-2026 archives.

Every ``.DAT`` file is ``;``-delimited with one record per line:

    A  file header      A;RTSALEDATA;<district>;<CCYYMMDD HH24:MI>;<submitter>;
    B  sale / property  25 fields incl. trailing empty field (layout below)
    C  legal descr.     C;<district>;<property id>;<sale counter>;<dl dt>;<text>;
                        one or more per B; chunks concatenate WITHOUT spaces
    D  owner            vendor / purchaser rows; names are suppressed
    Z  trailer          Z;<total lines>;<B count>;<C count>;<D count>;

The (district, property id, sale counter) key that joins C to B is only
unique *within one file* -- never join C records across files.
"""
# pylint: disable=duplicate-code

import csv
import os

# Zero-based index of each field in a split B record.
B_FIELDS = {
    "district_code": 1,
    "property_id": 2,
    "sale_counter": 3,
    "download_datetime": 4,
    "property_name": 5,
    "unit_number": 6,
    "house_number": 7,
    "street_name": 8,
    "locality": 9,
    "postcode": 10,
    "area": 11,
    "area_type": 12,
    "contract_date": 13,
    "settlement_date": 14,
    "purchase_price": 15,
    "zoning": 16,
    "nature_of_property": 17,
    "primary_purpose": 18,
    "strata_lot_number": 19,
    "component_code": 20,
    "sale_code": 21,
    "interest_of_sale_pct": 22,
    "dealing_number": 23,
}
B_FIELD_COUNT = 25  # 24 data fields + empty field after the trailing ';'

C_DISTRICT, C_PROPERTY_ID, C_SALE_COUNTER, C_TEXT = 1, 2, 3, 5

NATURE_OF_PROPERTY = {"R": "Residence", "V": "Vacant land", "3": "Other"}
AREA_UNITS_TO_M2 = {"M": 1.0, "H": 10000.0}

URL_BASE = "https://www.valuergeneral.nsw.gov.au/__psi"
LICENCE = (
    "Contains NSW Valuer General Property Sales Information "
    "(c) State of New South Wales, Creative Commons Attribution licence "
    "(see creative_commons.txt inside each archive)."
)

REFERENCE_DIR = os.path.join(os.path.dirname(__file__), "reference")
DISTRICTS_CSV = os.path.join(REFERENCE_DIR, "psi_districts.csv")


def load_districts(path: str = DISTRICTS_CSV) -> dict:
    """Return ``{district_code: row}`` from the district reference CSV."""
    with open(path, newline="", encoding="utf-8") as handle:
        return {row["district_code"]: row for row in csv.DictReader(handle)}


def region_codes(region: str, path: str = DISTRICTS_CSV) -> set:
    """District codes for ``region``: ``greater_sydney``, ``gsc33`` or ``nsw``.

    ``greater_sydney`` is the ABS Greater Capital City Statistical Area
    (34 LGAs, includes Central Coast). ``gsc33`` is the 33-LGA metropolitan
    region used by NSW planning (excludes Central Coast). ``nsw`` = all.
    """
    districts = load_districts(path)
    if region == "nsw":
        return set(districts)
    column = {"greater_sydney": "in_gccsa", "gsc33": "in_gsc33"}[region]
    return {code for code, row in districts.items() if row[column] == "1"}


# AS 4590 / G-NAF street-type abbreviations seen in PSI -> G-NAF
# STREET_TYPE_AUT code. PSI mostly abbreviates; a minority is spelled out.
STREET_TYPES = {
    "ALLY": "ALLEY", "ARC": "ARCADE", "AVE": "AVENUE", "AV": "AVENUE",
    "AVENUE": "AVENUE", "BVD": "BOULEVARD", "BVDE": "BOULEVARDE",
    "BOULEVARD": "BOULEVARD", "BOULEVARDE": "BOULEVARDE", "CCT": "CIRCUIT", "CIRCUIT": "CIRCUIT",
    "CIR": "CIRCLE", "CL": "CLOSE", "CLOSE": "CLOSE", "CNR": "CORNER",
    "CT": "COURT", "COURT": "COURT", "CRES": "CRESCENT",
    "CRESCENT": "CRESCENT", "CRST": "CREST", "CRSS": "CROSS",
    "CSWY": "CAUSEWAY", "DR": "DRIVE", "DRIVE": "DRIVE", "ESP": "ESPLANADE",
    "ESPLANADE": "ESPLANADE", "GDNS": "GARDENS", "GLD": "GLADE",
    "GLADE": "GLADE", "GLEN": "GLEN", "GR": "GROVE", "GROVE": "GROVE",
    "GRA": "GRANGE", "HTS": "HEIGHTS", "HWY": "HIGHWAY",
    "HIGHWAY": "HIGHWAY", "LANE": "LANE",
    "LA": "LANE", "LINK": "LINK", "LOOP": "LOOP", "MALL": "MALL",
    "MEWS": "MEWS", "PARADE": "PARADE", "PDE": "PARADE", "PKWY": "PARKWAY",
    "PL": "PLACE", "PLACE": "PLACE", "PLZA": "PLAZA", "PROM": "PROMENADE",
    "QY": "QUAY", "RD": "ROAD", "ROAD": "ROAD", "RDGE": "RIDGE",
    "RIDGE": "RIDGE", "RISE": "RISE", "ROW": "ROW", "SQ": "SQUARE",
    "ST": "STREET", "STREET": "STREET", "TCE": "TERRACE",
    "TERRACE": "TERRACE", "TRL": "TRAIL", "VIEW": "VIEW", "VSTA": "VISTA",
    "WALK": "WALK", "WAY": "WAY", "WHF": "WHARF", "WYND": "WYND",
}
# Trailing direction words that follow the street type ("PACIFIC HWY N").
STREET_SUFFIXES = {"N": "N", "S": "S", "E": "E", "W": "W",
                   "NTH": "N", "STH": "S", "EXT": "EX"}
