"""NSW Valuer General Property Sales Information (PSI) ingestion.

Pipeline stages (run from the repository root):

    python -m sources.property_sales.bronze.download       # fetch / list the zips
    python -m sources.property_sales.bronze.extract        # zips -> landing CSV
    python -m sources.property_sales.silver.transform      # landing -> versioned sales
    python -m sources.property_sales.silver.street_prices  # average price per street
    python -m sources.property_sales.quality.psi_profile   # data-quality profile
    python -m sources.property_sales.quality.dashboard     # HTML dashboard + 3D map

Only the Python standard library is used, so the repo's pylint CI needs no
extra dependencies.
"""
