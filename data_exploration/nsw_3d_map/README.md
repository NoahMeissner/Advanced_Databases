# NSW property — 3D suburb map

Interactive 3D map of 249 NSW suburbs from the 2024 Valuer General sales.
Extruded columns on a real basemap — **height & colour = median sale price**,
radius = sales volume. Drag to pan, right-drag to tilt/rotate, scroll to zoom,
hover for detail. Toggle height between price and volume.

Built with [deck.gl](https://deck.gl) (`ColumnLayer`) over a
[MapLibre GL](https://maplibre.org) basemap (CARTO dark-matter style). Libraries
load from CDN; suburb data is inlined in `index.html`.

## Run

Just open it — no build step:

```bash
open index.html          # macOS, double-click also works
```

Or serve it (needed on some browsers for the CDN scripts):

```bash
python3 -m http.server 8777
# then visit http://localhost:8777
```

## Data

| File | What |
|------|------|
| `index.html` | the map (data inlined) |
| `nsw_suburbs_2024.csv` | suburb, lon, lat, sales, median_price |
| `nsw_suburbs_2024.geojson` | same as point features |

Coordinates are POI place-centroids per suburb; sales/median are deduped 2024
figures (see `../README.md`). To point this at **predicted 3-year
outperformance**, swap the `getElevation` / `getFillColor` accessors in
`index.html` to read that field instead of `median_price`.
