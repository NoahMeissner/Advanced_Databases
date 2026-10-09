/* Address autocomplete for the start screen.
   Debounced so typing does not fire a query per keystroke, and keyboard
   navigable because the suggestion list is a real listbox. */
(function () {
  "use strict";

  var DEBOUNCE_MS = 160;
  var input = document.getElementById("address");
  var list = document.getElementById("suggestions");
  if (!input || !list) { return; }

  var timer = null;
  var rows = [];
  var active = -1;

  function close() {
    list.classList.remove("open");
    list.innerHTML = "";
    input.setAttribute("aria-expanded", "false");
    rows = [];
    active = -1;
  }

  function choose(row) {
    input.value = row.address_text;
    close();
    input.form.submit();
  }

  function highlight(next) {
    var buttons = list.querySelectorAll("button");
    if (!buttons.length) { return; }
    active = (next + buttons.length) % buttons.length;
    buttons.forEach(function (button, i) {
      button.setAttribute("aria-selected", i === active ? "true" : "false");
    });
  }

  function render(items) {
    rows = items;
    list.innerHTML = "";
    if (!items.length) { close(); return; }

    items.forEach(function (row) {
      var button = document.createElement("button");
      button.type = "button";
      button.setAttribute("role", "option");
      button.setAttribute("aria-selected", "false");

      var primary = document.createElement("span");
      primary.className = "primary";
      primary.textContent = row.primary;

      var secondary = document.createElement("span");
      secondary.className = "secondary";
      secondary.textContent = row.secondary;

      button.appendChild(primary);
      button.appendChild(secondary);

      /* the two tiers are not equally precise, so the row says which it is */
      if (row.precision === "street") {
        var tag = document.createElement("span");
        tag.className = "precision";
        tag.textContent = "street";
        button.appendChild(tag);
      }

      button.addEventListener("click", function () { choose(row); });
      list.appendChild(button);
    });

    list.classList.add("open");
    input.setAttribute("aria-expanded", "true");
  }

  function search() {
    var query = input.value.trim();
    if (query.length < 3) { close(); return; }
    fetch("/api/suggest?q=" + encodeURIComponent(query))
      .then(function (response) { return response.json(); })
      .then(render)
      .catch(close);
  }

  input.addEventListener("input", function () {
    window.clearTimeout(timer);
    timer = window.setTimeout(search, DEBOUNCE_MS);
  });

  input.addEventListener("keydown", function (event) {
    if (event.key === "ArrowDown") { event.preventDefault(); highlight(active + 1); }
    else if (event.key === "ArrowUp") { event.preventDefault(); highlight(active - 1); }
    else if (event.key === "Escape") { close(); }
    else if (event.key === "Enter" && active >= 0 && rows[active]) {
      event.preventDefault();
      choose(rows[active]);
    }
  });

  document.addEventListener("click", function (event) {
    if (!list.contains(event.target) && event.target !== input) { close(); }
  });
})();
