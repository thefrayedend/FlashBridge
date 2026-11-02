// A small script the app's browser runs in MakerWorld pages. It reads nothing and sends nothing anywhere;
// it only talks to the app. A tap on the big "Open in Bambu Handy" button (Bambu's own app) becomes what you
// would do by hand: open the arrow menu at the button's right end and tap its "Download 3MF" entry. That is
// the page's own download, which the app catches and opens in the board's slicer.
// The arrow itself still works as before. If the menu or its entry can't be found (MakerWorld changed), the
// app shows a hint pointing at the arrow. The page's own switch to its "Download Bambu Handy" screen
// (/open-app) is stopped too. Only that split button (and its menu entry) is caught; MakerWorld's
// "Get the full app experience" pop-up is closed for the user (its Cancel is tapped), and every other button
// works as the page made it.
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
  var HANDY = /Bambu Handy/i;
  // which tap is ours: the split button on a model page, or the Handy entry in its arrow menu. Every other
  // "Bambu Handy" button is left alone (except the pop-up below).
  function splitButton(t) {
    // the tap may land on the text, the big button's padding or its frame: look a few levels up for the
    // short element that holds both the main button and the arrow
    for (var n = t, i = 0; n && n.nodeType === 1 && i < 5; n = n.parentElement, i++) {
      if ((n.textContent || '').trim().length > 60) return null;
      var main = n.matches('span.primaryButton') ? n : n.querySelector('span.primaryButton');
      if (main && (main === n || n.querySelector('.icon-box'))) {
        if (!HANDY.test(main.textContent || '')) return null;
        var box = main.parentElement;
        return box && box.querySelector('.icon-box') ? main : null;
      }
    }
    return null;
  }
  function menuEntry(t) {
    var menu = t.closest && t.closest('[role=tooltip]');
    if (!menu) return null;
    for (var n = t, i = 0; n && n !== menu && i < 4; n = n.parentElement, i++) {
      var s = (n.textContent || '').trim();
      if (s.length < 40 && HANDY.test(s)) return n;
    }
    return null;
  }
  // MakerWorld's "Get the full app experience" pop-up: a dialog with an "Open in Bambu Handy" button and a
  // Cancel button. Its Handy button just closes it; the pop-up is closed by itself as soon as it shows.
  function handyPopup(root) {
    var dialogs = (root || document).querySelectorAll('[role=dialog]');
    for (var d = 0; d < dialogs.length; d++) {
      var buttons = dialogs[d].querySelectorAll('button');
      var handy = null, other = null;
      for (var b = 0; b < buttons.length; b++) {
        if (HANDY.test(buttons[b].textContent || '')) handy = buttons[b]; else other = other || buttons[b];
      }
      if (handy && other && buttons.length === 2 && !dialogs[d].querySelector('span.primaryButton')) return { dialog: dialogs[d], handy: handy, cancel: other };
    }
    return null;
  }
  var closed = typeof WeakSet === 'function' ? new WeakSet() : null;
  var queued = false;
  function closePopup() {
    queued = false;
    var p = handyPopup();
    if (!p || (closed && closed.has(p.dialog))) return;
    if (closed) closed.add(p.dialog);
    tap(p.cancel);
  }
  window.addEventListener('click', function (e) {
    if (passing) return;
    var t = e.target;
    if (!t || t.nodeType !== 1) return;
    if (t.closest('.icon-box')) return; // the arrow: leave it alone
    var popup = handyPopup();
    if (popup && popup.handy.contains(t)) {
      e.preventDefault();
      e.stopImmediatePropagation();
      tap(popup.cancel);
      return;
    }
    var hit = splitButton(t) || menuEntry(t);
    if (!hit) return;
    e.preventDefault();
    e.stopImmediatePropagation();
    download3mf(hit);
  }, true);
  function watch() {
    closePopup();
    new MutationObserver(function () {
      if (!queued) { queued = true; setTimeout(closePopup, 50); }
    }).observe(document.documentElement, { childList: true, subtree: true });
  }
  if (document.documentElement) watch(); else document.addEventListener('DOMContentLoaded', watch);
  // the page's own switch to the Handy screen
  ['pushState', 'replaceState'].forEach(function (k) {
    var orig = history[k];
    history[k] = function (state, title, url) {
      try {
        if (url != null && /\/open-app/.test(new URL(String(url), location.href).pathname)) {
          if (mainButtons().length) tell(new URL(String(url), location.href).href); // a hint only on a model page
          return;
        }
      } catch (e) {}
      return orig.apply(this, arguments);
    };
  });
})();
''';
