// Content tabs and the table of contents.
//
// 1. When the URL points at a heading inside a tab that isn't showing (a table
//    of contents entry, an in-page link, a shared URL), select that tab first,
//    then scroll to the heading. Without this, Material changes the URL and
//    leaves the other tab on screen.
// 2. The table of contents lists every heading on the page, whichever tab it's
//    in. Show only the entries of the tab that's open, and switch with it.
// 3. A plain visit, with no link into a tab, opens on the first tab.
(function () {
  "use strict";

  // The tab block a heading sits in, and whether that tab is the one selected.
  function tabOf(el) {
    var block = el && el.closest(".tabbed-block");
    if (!block) return null;
    var blocks = Array.prototype.slice.call(block.parentElement.children);
    var inputs = block.closest(".tabbed-set").querySelectorAll(":scope > input");
    return inputs[blocks.indexOf(block)] || null;
  }

  function syncToc() {
    var links = document.querySelectorAll(".md-nav--secondary a.md-nav__link[href^='#']");
    Array.prototype.forEach.call(links, function (link) {
      var id = decodeURIComponent(link.getAttribute("href").slice(1));
      var input = tabOf(document.getElementById(id));
      var item = link.closest(".md-nav__item");
      if (item) item.hidden = Boolean(input && !input.checked);
    });
  }

  function select(input) {
    if (input && !input.checked) {
      input.checked = true;
      input.dispatchEvent(new Event("change", { bubbles: true }));
    }
  }

  function reveal() {
    var id = decodeURIComponent(location.hash.slice(1));
    var target = id && document.getElementById(id);
    // Clicking a tab puts its own id in the URL (#__tabbed_1_2): that's the tab.
    var input = target && target.matches(".tabbed-set > input") ? target : tabOf(target);
    if (!input) {
      // A plain visit opens each page on its first tab, whatever tab the
      // reader chose last time (content.tabs.link remembers it).
      Array.prototype.forEach.call(document.querySelectorAll(".tabbed-set"), function (set) {
        select(set.querySelector(":scope > input"));
      });
    }
    select(input);
    syncToc();
    if (input && input !== target) target.scrollIntoView();
  }

  document.addEventListener("change", function (event) {
    if (event.target.matches(".tabbed-set > input")) syncToc();
  });
  window.addEventListener("hashchange", reveal);
  // Material's instant loading replays pages through document$; plain loads don't.
  if (window.document$) {
    window.document$.subscribe(reveal);
  } else {
    window.addEventListener("load", reveal);
  }
})();
