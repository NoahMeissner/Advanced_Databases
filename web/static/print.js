/* Guarantees the report prints as exactly one A4 page.
 *
 * The compacted print stylesheet in app.css handles the normal case, but
 * content length varies by address - more schools, longer names, four rank
 * rows instead of two - so a particularly full report could still spill onto a
 * second sheet. This measures just before printing and, only if needed,
 * scales the page down enough to fit.
 *
 * zoom rather than transform: scale, because zoom reflows. A transform would
 * leave the layout at its original size and clip it at the page edge.
 */
(function () {
  "use strict";

  var MM_TO_PX = 96 / 25.4;
  var A4_HEIGHT_MM = 297;
  var PAGE_MARGIN_MM = 12;          /* must match @page in app.css */
  var MIN_SCALE = 0.82;
  /* Below this the page is too small to read, so an extreme report is better
     off overflowing visibly than shrinking into illegibility. */

  var page = document.querySelector(".page");
  if (!page) { return; }

  function availableHeight() {
    return (A4_HEIGHT_MM - 2 * PAGE_MARGIN_MM) * MM_TO_PX;
  }

  function fit() {
    page.style.zoom = "";
    var actual = page.scrollHeight;
    var available = availableHeight();
    if (actual <= available) { return; }

    var scale = Math.max(MIN_SCALE, available / actual);
    page.style.zoom = String(scale);
  }

  function reset() {
    page.style.zoom = "";
  }

  window.addEventListener("beforeprint", fit);
  window.addEventListener("afterprint", reset);

  /* Safari and some Chrome paths fire the media query rather than the events. */
  if (window.matchMedia) {
    var query = window.matchMedia("print");
    if (query.addEventListener) {
      query.addEventListener("change", function (event) {
        if (event.matches) { fit(); } else { reset(); }
      });
    }
  }
})();
