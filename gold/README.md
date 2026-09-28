# Gold: serving layer

Gold turns Silver into the two access patterns the product needs (report §4.6,
Recommendation 1):

- **Dimensional mart for the address report (C1).** Facts such as sales, DA
  status events and traffic counts, with conformed dimensions for address
  (G-NAF), street, locality, LGA and date. Joins are precomputed so a report
  never joins raw sources at query time.
- **Graph projection for proximity queries.** "What's happening around here":
  address → nearby DAs, stops, schools and road segments, on a spatial index
  (PostGIS / H3).

Rules:

- Read **Silver only**, never Bronze.
- Anything built from two or more sources lives here, not in a source folder.
- Outputs go to `data/gold/`, and are rebuilt from Silver whenever needed.
