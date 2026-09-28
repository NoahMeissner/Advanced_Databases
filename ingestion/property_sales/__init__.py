"""NSW Valuer General Property Sales Information (PSI) ingestion.

Pipeline stages (run from the repository root):

    python -m ingestion.property_sales.download    # fetch / list the zips
    python -m ingestion.property_sales.extract     # zips -> landing CSV
    python -m ingestion.property_sales.transform   # landing -> staging CSVs
    python -m ingestion.property_sales.psi_profile # data-quality profile

Only the Python standard library is used, so the repo's pylint CI needs no
extra dependencies.
"""
