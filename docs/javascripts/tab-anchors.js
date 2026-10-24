// Links into content tabs: when the URL points at a heading inside a tab that
// isn't showing (a table of contents entry, an in-page link, a shared URL),
// select that tab first, then scroll to the heading. Without this, Material
// changes the URL and leaves the other tab on screen.
(function () {
  "use strict";

  function reveal() {
    var id = decodeURIComponent(location.hash.slice(1));
    if (!id) return;
    var target = document.getElementById(id);
    var block = target && target.closest(".tabbed-block");
    if (!block) return;
    var blocks = Array.prototype.slice.call(block.parentElement.children);
    var set = block.closest(".tabbed-set");
    var inputs = set.querySelectorAll(":scope > input");
    var input = inputs[blocks.indexOf(block)];
    if (input && !input.checked) {
      input.checked = true;
      input.dispatchEvent(new Event("change"));
    }
    target.scrollIntoView();
  }

  window.addEventListener("hashchange", reveal);
  // Material's instant loading replays pages through document$; plain loads don't.
  if (window.document$) {
    window.document$.subscribe(reveal);
  } else {
    window.addEventListener("load", reveal);
  }
})();
