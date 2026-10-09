# @Noah Meissner 9.10.2026
"""Shared result reporting for the integrity tests.

Both test modules print one line per check and exit non-zero when any failed,
so the formatting and the tally live here rather than twice.
"""


def report(label: str, ok: bool, detail: str = "", width: int = 46) -> bool:
    """Prints one result line; returns ok so callers can collect it."""
    print(f"  {label:<{width}} {'OK' if ok else 'ERROR':<6} {detail}")
    return ok


def summarise(results: list[bool]) -> bool:
    """Prints the tally; True = everything passed."""
    failed = results.count(False)
    if failed:
        print(f"\n{failed} of {len(results)} checks failed.")
    else:
        print(f"\nAll {len(results)} checks passed.")
    return failed == 0
