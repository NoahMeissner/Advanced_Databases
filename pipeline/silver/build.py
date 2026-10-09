# @Noah Meissner 9.10.2026
"""Silver-Layer: typed, cleaned, quality-flagged tables built from bronze.

Bronze keeps every row exactly as the source delivered it. Silver is the first
layer anyone may trust, so each step here does three things:

  1. type and standardise (ISO dates, SI units, one project CRS)
  2. flag problems in flag_* columns instead of deleting rows
  3. reduce the source to a per-bus-stop measure, because the bus stops are the
     reference points all sources are joined on

The step order is the dependency graph; the mechanics live in pipeline/layer.py.

Start from the repo root:
    python -m pipeline.silver.build              all steps
    python -m pipeline.silver.build bus_stop     one step
    python -m pipeline.silver.build --reset      drop the silver schema first
"""
import sys

import paths
from pipeline.layer import Layer, Step

STEPS = {

    "extensions":      Step("00_extensions.sql", None),
    "quality":         Step("01_quality.sql", None),
    "bus_stop":        Step("10_bus_stop.sql", "bus_stop"),
    "hex_300m":        Step("11_hex_300m.sql", "hex_300m"),
    "bus_edge":        Step("12_bus_edge.sql", "bus_edge"),
    "edge_travel_time": Step("13_bus_edge_travel_time.sql", "bus_edge_travel_time"),
    "school":          Step("20_school.sql", "school"),
    "stop_school":     Step("21_bus_stop_school.sql", "bus_stop_school"),
    "da_application":  Step("30_da_application.sql", "da_application"),
    "da_hex":          Step("31_da_hex_300m.sql", "da_hex_300m"),
    "stop_da":         Step("32_bus_stop_da.sql", "bus_stop_da"),
    "street":          Step("40_street_locality.sql", "street_locality"),
    "property_sale":   Step("41_property_sale.sql", "property_sale"),
    "sales_street":    Step("42_property_sales_street.sql", "property_sales_street"),
    "sales_hex":       Step("43_property_sales_hex_300m.sql", "property_sales_hex_300m"),
    "stop_sales":      Step("44_bus_stop_property_sales.sql", "bus_stop_property_sales"),
    "traffic_segment": Step("50_traffic_segment.sql", "traffic_segment"),
    "traffic_hourly":  Step("51_traffic_hourly.sql", "traffic_segment_hourly"),
    "traffic_daypart": Step("52_traffic_daypart.sql", "traffic_segment_daypart"),
    "stop_traffic":    Step("53_bus_stop_traffic.sql", "bus_stop_traffic"),
    "lga":             Step("60_lga.sql", "lga"),
    "rent_lga":        Step("61_rent_lga.sql", "rent_lga"),
    "route":           Step("62_route.sql", "route"),
    "stop_lga":        Step("63_bus_stop_lga.sql", "bus_stop_lga"),
    "stop_profile":    Step("90_bus_stop_profile.sql", "bus_stop_profile"),
}

_LAYER = Layer("silver", paths.SILVER_SQL_DIR, STEPS)


def run(selected: list[str] | None = None) -> None:
    """Runs the selected steps (or all) in dependency order.

    Called by pipeline/run.py, but can also be called individually.
    """
    _LAYER.run(selected)


if __name__ == "__main__":
    run(sys.argv[1:])
