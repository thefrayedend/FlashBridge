// A small script the app's browser runs in MakerWorld pages (it reads nothing, sends nothing anywhere):
// it catches the "Open in Bambu Handy" tap inside the page itself and tells the app, which then opens the
// same model page in the desktop layout (where "Download 3MF" is). Done in the page because MakerWorld
// switches to its "Download Bambu Handy" screen without a page load, which the web view's own checks can miss.
// Also stops the page from switching its address to /open-app (the Handy screen) and reports that instead.
const makerWorldHandyScript = r'''
(function () {
  if (window.__flashBridgeHandy) return;
  window.__flashBridgeHandy = true;
  if (!/(^|\.)makerworld\.com$/.test(location.hostname)) return;
  function tell(target) {
    try { window.flutter_inappwebview.callHandler('flashBridgeHandy', String(target || ''), location.href); } catch (e) {}
  }
  // the button: a short element whose text names Bambu Handy ("Open in Bambu Handy")
  window.addEventListener('click', function (e) {
    for (var n = e.target, i = 0; n && n.nodeType === 1 && i < 6; n = n.parentElement, i++) {
      var s = (n.textContent || '').trim();
      if (s.length > 60) break;
      if (/Bambu Handy/i.test(s) && !/download/i.test(s)) {
        e.preventDefault();
        e.stopImmediatePropagation();
        tell('');
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
