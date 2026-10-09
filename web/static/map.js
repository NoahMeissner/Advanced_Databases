/* The map screen: Leaflet plus four toggleable layers.
   Layers are fetched lazily the first time they are switched on, then cached -
   the reach polygon in particular costs a graph query, so re-toggling it
   should not pay for it twice.
   Colours are read from the design tokens so this file never hard-codes one. */
(function () {
  "use strict";

  var host = document.getElementById("map");
  if (!host || typeof window.L === "undefined") { return; }

  var address = host.dataset.address;
  var lat = parseFloat(host.dataset.lat);
  var lon = parseFloat(host.dataset.lon);
  /* The hour decides which service band the reach is computed on, so it has to
     travel with every layer request - otherwise the map would quietly show the
     default band while the header claims another. */
  var hour = host.dataset.hour;

  function token(name) {
    return getComputedStyle(document.documentElement)
      .getPropertyValue(name).trim();
  }

  var COLOUR = {
    schools: token("--layer-schools"),
    activity: token("--layer-noise"),
    commute: token("--layer-commute"),
    market: token("--layer-market"),
    marketDown: token("--layer-market-down"),
    development: token("--layer-development"),
    developmentFaint: token("--layer-development-faint"),
    ink: token("--color-ink")
  };

  var map = L.map(host, { zoomControl: false, attributionControl: true })
    .setView([lat, lon], 15);

  /* The design wants a muted basemap in the map tokens with no POI clutter.
     Every ready-made muted tile set (CARTO Positron, Stadia Alidade) now needs
     an API key - CARTO even answers 200 with "API KEY REQUIRED" painted into
     the tile, so it fails silently rather than erroring. So: keyless OSM tiles,
     desaturated in CSS (.basemap in app.css) down to the token greys. That
     keeps street names for orientation while the four data layers stay the only
     colour on the map, which is the principle the design is actually built on.
     Leaflet itself is vendored; only the tiles need the network. */
  L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
    attribution: "&copy; OpenStreetMap contributors",
    className: "basemap",
    maxZoom: 19
  }).addTo(map);

  L.control.zoom({ position: "topright" }).addTo(map);

  /* The address is the only black mark on the map (DESIGN.md 4.11). */
  L.marker([lat, lon], {
    icon: L.divIcon({
      className: "",
      html: '<div class="mark-address"></div>',
      iconSize: [14, 14],
      iconAnchor: [7, 7]
    }),
    keyboard: false,
    title: address
  }).addTo(map);

  var cache = {};
  var groups = {};

  function url(name) {
    return "/api/layers/" + name +
      "?address=" + encodeURIComponent(address) +
      "&at=" + encodeURIComponent(hour);
  }

  function schoolsLayer(data) {
    return L.geoJSON(data, {
      pointToLayer: function (feature, latlng) {
        return L.marker(latlng, {
          icon: L.divIcon({
            className: "",
            html: '<div class="mark-school">' + feature.properties.rank + "</div>",
            iconSize: [26, 26],
            iconAnchor: [13, 13]
          }),
          title: feature.properties.name
        });
      },
      onEachFeature: function (feature, layer) {
        layer.bindPopup(
          "<strong>" + feature.properties.rank + ". " +
          feature.properties.name + "</strong><br>" +
          (feature.properties.level || "") + " · " +
          feature.properties.distance_m + " m"
        );
      }
    });
  }

  function activityLayer(data) {
    return L.geoJSON(data, {
      style: function (feature) {
        var band = feature.properties.band || 1;
        return {
          color: COLOUR.activity,
          weight: 1 + band * 1.2,
          /* low bands stay faint so the busy corridors read first */
          opacity: 0.25 + band * 0.13
        };
      },
      onEachFeature: function (feature, layer) {
        layer.bindPopup(
          feature.properties.trips_per_day + " bus trips/day<br>" +
          feature.properties.n_routes + " route(s): " +
          (feature.properties.routes || []).join(", ")
        );
      }
    });
  }

  function reachLayer(data) {
    return L.geoJSON(data, {
      style: {
        color: COLOUR.commute,
        weight: 1.5,
        fillColor: COLOUR.commute,
        fillOpacity: 0.09
      },
      onEachFeature: function (feature, layer) {
        layer.bindPopup(
          "Reachable by bus in " + feature.properties.minutes +
          " minutes at " + feature.properties.at +
          "<br>" + feature.properties.n_stops + " stops, from " +
          feature.properties.n_seed_stops + " starting stops" +
          "<br>" + feature.properties.band + " timetable"
        );
      }
    });
  }

  /* Development applications. Square markers so they are distinguishable from
     the school circles without relying on colour, and sized on a square-root
     scale so a $200m tower reads bigger than a $2m renovation without
     swallowing the block. */
  function daSize(cost, tier) {
    var base = tier === "pipeline" ? 9 : 6;
    if (!cost || cost <= 0) { return base; }
    var scaled = Math.sqrt(cost / 1000000) * 3;
    return Math.max(base, Math.min(tier === "pipeline" ? 26 : 16, base + scaled));
  }

  function money(value) {
    if (!value) { return "cost not stated"; }
    if (value >= 1000000) { return "$" + (value / 1000000).toFixed(1) + "m"; }
    return "$" + value.toLocaleString();
  }

  function developmentLayer(data) {
    return L.geoJSON(data, {
      pointToLayer: function (feature, latlng) {
        var props = feature.properties;
        var pipeline = props.tier === "pipeline";
        var size = daSize(props.cost, props.tier);
        return L.marker(latlng, {
          icon: L.divIcon({
            className: "",
            html: '<div class="mark-da' +
              (pipeline ? '" ' : ' mark-da-determined" ') +
              'style="width:' + size + "px;height:" + size + 'px"></div>',
            iconSize: [size, size],
            iconAnchor: [size / 2, size / 2]
          }),
          title: props.address || props.status
        });
      },
      onEachFeature: function (feature, layer) {
        var props = feature.properties;
        layer.bindPopup(
          "<strong>" + (props.address || "Development application") + "</strong><br>" +
          props.status + " · " + money(props.cost) +
          (props.dwellings ? "<br>" + props.dwellings + " new dwellings" : "") +
          (props.lodged ? "<br>lodged " + props.lodged : "") +
          "<br>" + props.distance_m + " m away" +
          (props.tier === "determined"
            ? "<br><em>Determined — approved, not necessarily built: " +
              "the source has no completion date.</em>"
            : "")
        );
      }
    });
  }

  function pricesLayer(data) {
    return L.geoJSON(data, {
      style: function (feature) {
        var change = feature.properties.change_pct;
        var up = change === null || change >= 0;
        return {
          color: up ? COLOUR.market : COLOUR.marketDown,
          weight: feature.properties.is_address_hex ? 1.6 : 0.5,
          fillColor: up ? COLOUR.market : COLOUR.marketDown,
          /* darker = bigger rise, so the ramp carries the magnitude */
          fillOpacity: change === null
            ? 0.12
            : Math.min(0.55, 0.12 + Math.abs(change) / 120)
        };
      },
      onEachFeature: function (feature, layer) {
        var props = feature.properties;
        layer.bindPopup(
          "Median $" + (props.median_price || 0).toLocaleString() +
          "<br>" + props.n_sales + " sales" +
          (props.change_pct === null
            ? ""
            : "<br>" + (props.change_pct > 0 ? "+" : "") + props.change_pct +
              "% since " + props.from_year)
        );
      }
    });
  }

  var BUILDERS = {
    schools: schoolsLayer,
    activity: activityLayer,
    reach: reachLayer,
    prices: pricesLayer,
    development: developmentLayer
  };

  function show(name, button) {
    if (groups[name]) { groups[name].addTo(map); return; }
    if (cache[name]) {
      groups[name] = BUILDERS[name](cache[name]).addTo(map);
      return;
    }
    button.disabled = true;
    fetch(url(name))
      .then(function (response) { return response.json(); })
      .then(function (data) {
        cache[name] = data;
        groups[name] = BUILDERS[name](data).addTo(map);
      })
      .catch(function () {
        button.setAttribute("aria-pressed", "false");
      })
      .finally(function () { button.disabled = false; });
  }

  function hide(name) {
    if (groups[name]) { map.removeLayer(groups[name]); }
  }

  document.querySelectorAll(".layer").forEach(function (row) {
    var name = row.dataset.layer;
    var button = row.querySelector("button");
    if (!BUILDERS[name]) { return; }

    if (button.getAttribute("aria-pressed") === "true") { show(name, button); }

    button.addEventListener("click", function () {
      var on = button.getAttribute("aria-pressed") === "true";
      button.setAttribute("aria-pressed", on ? "false" : "true");
      if (on) { hide(name); } else { show(name, button); }
    });
  });
})();
