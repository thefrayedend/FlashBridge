// A small script the app's browser runs in MakerWorld pages. It reads nothing and sends nothing anywhere;
// it only talks to the app. A tap on the big "Open in Bambu Handy" button (Bambu's own app) becomes what you
// would do by hand: open the arrow menu at the button's right end and tap its "Download 3MF" entry. That is
// the page's own download, which the app catches and opens in the board's slicer.
// The arrow itself still works as before. If the menu or its entry can't be found (MakerWorld changed), the
// app shows a hint pointing at the arrow. The page's own switch to its "Download Bambu Handy" screen
// (/open-app) is stopped too.
// Page structure (2026-11-02, phone layout): a split button <div><span class="primaryButton"><span>Open in
// Bambu Handy</span></span><div class="icon-box">(arrow)</div></div>; the menu is a [role=tooltip] popper
// ("Download 3MF", "Download STL/CAD Files"). MakerWorld puts the last action used on the big button, so after
// one 3MF download the big button reads "Download 3MF" and "Open in Bambu Handy" moves into the menu: a tap
// on it there is turned into a tap on the big "Download 3MF".
const makerWorldHandyScript = r'''
(function () {
  if (window.__flashBridgeHandy) return;
  window.__flashBridgeHandy = true;
  if (!/(^|\.)makerworld\.com$/.test(location.hostname)) return;
  var passing = false; // our own taps on the arrow and the menu entry go through
  function tell(what) {
    try { window.flutter_inappwebview.callHandler('flashBridgeHandy', String(what || ''), location.href); } catch (e) {}
  }
  function tap(el) {
    passing = true;
    try { el.click(); } finally { passing = false; }
  }
  function shown(el) { var r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0; }
  // MakerWorld's split button: a big main action plus an arrow menu with the others. It remembers the last
  // action used, so "Download 3MF" is either the main button or an entry in the menu.
  function mainButtons() {
    return Array.prototype.filter.call(document.querySelectorAll('span.primaryButton'), shown);
  }
  function entry3mf() {
    var menus = document.querySelectorAll('[role=tooltip]');
    for (var m = 0; m < menus.length; m++) {
      var all = menus[m].querySelectorAll('*');
      for (var i = 0; i < all.length; i++) {
        var t = (all[i].textContent || '').trim();
        if (all[i].children.length === 0 && /3MF/i.test(t) && !/STL/i.test(t) && t.length < 40) return all[i];
      }
    }
    var main = mainButtons();
    for (var j = 0; j < main.length; j++) if (/3MF/i.test(main[j].textContent || '') && !/STL/i.test(main[j].textContent || '')) return main[j];
    return null;
  }
  function download3mf(start) {
    var item = entry3mf();
    if (item) { tap(item); tell('download'); return; }
    var arrow = null;
    for (var n = start, i = 0; n && i < 4 && !arrow; n = n.parentElement, i++) arrow = n.querySelector('.icon-box');
    var main = mainButtons();
    if (!arrow && main.length) arrow = main[0].parentElement.querySelector('.icon-box');
    if (!arrow) { tell('nomenu'); return; }
    tap(arrow);
    var tries = 0;
    (function look() {
      var found = entry3mf();
      if (found) { tap(found); tell('download'); return; }
      if (++tries > 30) { tell('nomenu'); return; } // 3 s
      setTimeout(look, 100);
    })();
  }
  window.addEventListener('click', function (e) {
    if (passing) return;
    for (var n = e.target, i = 0; n && n.nodeType === 1 && i < 6; n = n.parentElement, i++) {
      if (n.classList && n.classList.contains('icon-box')) return; // the arrow: leave it alone
      var s = (n.textContent || '').trim();
      if (s.length > 60) break;
      if (/Bambu Handy/i.test(s) && !/download/i.test(s)) {
        e.preventDefault();
        e.stopImmediatePropagation();
        download3mf(n);
        return;
      }
    }
  }, true);
  // the page's own switch to the Handy screen
  ['pushState', 'replaceState'].forEach(function (k) {
    var orig = history[k];
    history[k] = function (state, title, url) {
      try {
        if (url != null && /\/open-app/.test(new URL(String(url), location.href).pathname)) {
          tell(new URL(String(url), location.href).href);
          return;
        }
      } catch (e) {}
      return orig.apply(this, arguments);
    };
  });
})();
''';
