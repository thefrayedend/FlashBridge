// A small web browser for model sites (MakerWorld, Printables, Thingiverse …). Downloads of models are
// caught and opened in the board's slicer; sliced files go to the printer. Logins are the sites' own,
// kept by the phone's web view like in any browser.
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'board.dart';
import 'makerworld.dart';
import 'makerworld_script.dart';
import 'native.dart';

class Site {
  final String name, url, note;
  final IconData icon;
  const Site(this.name, this.url, this.note, this.icon);
}

const sites = [
  Site('MakerWorld', 'https://makerworld.com/', 'Bambu Lab\'s model site. Tap "Open in Bambu Handy" on a model: the 3MF opens in the slicer. Log in with your e-mail; Google sign-in does not work inside apps.', Icons.public),
  Site('Printables', 'https://www.printables.com/', 'Prusa\'s model site. "Download all" ZIPs open with every model inside.', Icons.category),
  Site('Thingiverse', 'https://www.thingiverse.com/', 'The classic model library.', Icons.inventory_2),
  Site('Thangs', 'https://thangs.com/', 'Search across many model sites.', Icons.search),
];

/// Lets the app open a link in this browser (a page shared from another app).
class BrowserNav {
  static void Function(String url)? open;
}

class BrowserView extends StatefulWidget {
  /// A downloaded file is ready: [file] on the phone, its [name].
  final Future<void> Function(File file, String name) onFile;
  const BrowserView({super.key, required this.onFile});

  @override
  State<BrowserView> createState() => BrowserViewState();
}

class BrowserViewState extends State<BrowserView> {
  InAppWebViewController? _c;
  final _address = TextEditingController();
  final _focus = FocusNode();
  bool _home = true;
  bool _loading = false;
  double _progress = 0;
  String? _pendingUrl;
  bool _wipeWhenBlank = false; // closeSite loaded about:blank: clear the back history once it is there
  int _pageReads = 0; // files being read out of the page (blob: downloads) — closing the page would break them
  bool _closeAfterRead = false;

  @override
  void initState() {
    super.initState();
    BrowserNav.open = openUrl;
  }

  @override
  void dispose() {
    BrowserNav.open = null;
    _address.dispose();
    _focus.dispose();
    super.dispose();
  }

  void openUrl(String url) {
    setState(() => _home = false);
    _tipOnce();
    final c = _c;
    if (c == null) {
      _pendingUrl = url; // the web view is not made yet: it opens this first
    } else {
      c.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    }
  }

  // ------------------------------------------------------------------ MakerWorld's "Open in Bambu Handy"
  // On a phone, MakerWorld's big green button is "Open in Bambu Handy" (Bambu's app). The arrow at its right end
  // has "Download 3MF", a normal download this browser catches. A small script in MakerWorld pages
  // (makerworld_script.dart) turns a tap on the big button into exactly that: it opens the arrow menu and taps
  // "Download 3MF" itself. Nothing in this browser is handed to another app.
  static const _arrowHint = 'That button opens Bambu\'s own app. Tap the small arrow at the right end of the green button and '
      'choose "Download 3MF": it opens here, in the slicer.';
  DateTime? _caughtAt; // MakerWorld's Handy screen was last caught (it hands off twice for one tap)

  /// The page script reports: [args] = ['download' (it tapped Download 3MF) | 'nomenu' (no such entry found) |
  /// the /open-app address the page tried to switch to; the page's own address].
  Object? _handyFromPage(InAppWebViewController c, List<dynamic> args) {
    final what = args.isNotEmpty ? '${args[0]}' : '';
    if (what == 'download') {
      _snack('Downloading the 3MF into the slicer…');
    } else {
      _snack(_arrowHint, long: true);
    }
    return null;
  }

  /// MakerWorld got to its "Download Bambu Handy" screen anyway ([from]: that address): back to the model
  /// page it is about, with the hint where Download 3MF is; without a model, just back (no hint).
  Future<void> _leaveHandyScreen(InAppWebViewController c, Uri from) async {
    final now = DateTime.now();
    final last = _caughtAt;
    if (last != null && now.difference(last) < const Duration(seconds: 4)) return; // second hand-off of the same tap
    _caughtAt = now;
    final target = MakerWorld.modelPageFor(from);
    if (target != null) {
      await c.loadUrl(urlRequest: URLRequest(url: WebUri(target)));
      _snack(_arrowHint, long: true);
    } else if (await c.canGoBack()) {
      await c.goBack(); // not about a model (e.g. MakerWorld's app pop-up): just back to where it was
    }
  }

  /// Every address change, also the ones a page makes itself without loading (those never reach _route).
  void _visited(InAppWebViewController c, WebUri? url) {
    if (url == null || url.toString() == 'about:blank') return;
    if (!_focus.hasFocus) _address.text = url.toString();
    final u = Uri.tryParse(url.toString());
    if (u != null && MakerWorld.isOpenApp(u)) _leaveHandyScreen(c, u);
  }

  Future<NavigationActionPolicy> _route(InAppWebViewController c, NavigationAction action) async {
    final url = action.request.url;
    final s = url?.toString() ?? '';
    final main = action.isForMainFrame != false;
    if (s.isEmpty || s.startsWith('about:') || s.startsWith('blob:') || s.startsWith('data:')) return NavigationActionPolicy.ALLOW;
    if (s.startsWith('http://') || s.startsWith('https://')) {
      // MakerWorld's Handy hand-off goes through makerworld.com/…/open-app/…
      if (MakerWorld.isOpenApp(url!)) {
        if (main) await _leaveHandyScreen(c, url);
        return NavigationActionPolicy.CANCEL;
      }
      return NavigationActionPolicy.ALLOW;
    }
    // bambustudio://open?file=…, bambulab://…, intent://… and the like
    if (!main) return NavigationActionPolicy.CANCEL;
    var decoded = s;
    try {
      decoded = Uri.decodeFull(s);
    } catch (_) {}
    final inner = RegExp(r'https?://[^\s"<>]+').firstMatch(decoded)?.group(0);
    if (inner != null) {
      final name = safeFileName(Uri.tryParse(inner)?.path ?? inner);
      if (kindOf(name) != FileKind.other) {
        await _fetch(WebUri(inner), name);
        return NavigationActionPolicy.CANCEL;
      }
    }
    if (RegExp(r'bambu|handy', caseSensitive: false).hasMatch(s)) {
      _snack(_arrowHint, long: true);
    } else {
      _snack('That link is for another app. Flash Bridge keeps you here: look for a Download button on the page instead.');
    }
    return NavigationActionPolicy.CANCEL;
  }

  /// Back inside the browser; false when there is nothing to go back to.
  Future<bool> back() async {
    if (_home) return false;
    final c = _c;
    if (c != null && await c.canGoBack()) {
      // the blank page closeSite left behind is not a place to go back to: that is the site picker
      final h = await c.getCopyBackForwardList();
      final list = h?.list ?? const <WebHistoryItem>[];
      final i = (h?.currentIndex ?? 0) - 1;
      final before = i >= 0 && i < list.length ? list[i].url?.toString() : null;
      if (before != 'about:blank') {
        await c.goBack();
        return true;
      }
    }
    setState(() => _home = true);
    return true;
  }

  // ------------------------------------------------------------------ double-tap on Models
  /// Closes the open model site (its page and back history) and shows the site picker. Logins stay (cookies
  /// and site data are untouched); downloads already running carry on (they don't use the page, except a
  /// file being read out of the page, which is left to finish first).
  Future<void> closeSite() async {
    _focus.unfocus();
    _address.clear();
    setState(() {
      _home = true;
      _loading = false;
    });
    final c = _c;
    if (c == null) return;
    if (_pageReads > 0) {
      _closeAfterRead = true;
      return;
    }
    await _blank(c);
  }

  Future<void> _blank(InAppWebViewController c) async {
    _closeAfterRead = false;
    _wipeWhenBlank = true;
    await c.stopLoading();
    await c.loadUrl(urlRequest: URLRequest(url: WebUri('about:blank')));
  }

  /// The first time a site is opened: how to get back to the picker. A marker file in the app's cache
  /// remembers it (if the cache is cleared, the tip shows once more).
  bool _tipChecked = false;
  Future<void> _tipOnce() async {
    if (_tipChecked) return;
    _tipChecked = true;
    try {
      final f = File('${(await Native.cacheDir()).path}/models-tip-shown');
      if (await f.exists()) return;
      await f.writeAsString('1');
      await Future.delayed(const Duration(seconds: 2));
      if (mounted && !_home) _snack('Tip: double-tap Models at the bottom to close this site and pick another.');
    } catch (_) {}
  }

  void _go(String text) {
    var t = text.trim();
    if (t.isEmpty) return;
    if (!t.contains('://')) {
      t = t.contains('.') && !t.contains(' ') ? 'https://$t' : 'https://www.printables.com/search/models?q=${Uri.encodeQueryComponent(t)}';
    }
    _focus.unfocus();
    openUrl(t);
  }

  // ------------------------------------------------------------------ downloads
  Future<void> _download(DownloadStartRequest req) async {
    final name = safeFileName(req.suggestedFilename ?? filenameFromDisposition(req.contentDisposition) ?? req.url.pathSegments.lastOrNull ?? 'download', mimeType: req.mimeType);
    await _fetch(req.url, name, userAgent: req.userAgent);
  }

  /// Downloads a model (with the site's login cookies) and hands it to the slicer / printer.
  Future<void> _fetch(WebUri wurl, String name, {String? userAgent}) async {
    final url = wurl.toString();
    if (kindOf(name) == FileKind.other) {
      _snack('$name is not something Flash Bridge can print (it opens 3MF, STL, OBJ, ZIP and G-code). On model pages, pick the 3MF or STL download.');
      return;
    }
    final dir = Directory('${(await Native.cacheDir()).path}/downloads');
    final dest = File('${dir.path}/${DateTime.now().millisecondsSinceEpoch}-$name');
    try {
      _snack('Downloading $name…', long: true);
      if (url.startsWith('blob:') || url.startsWith('data:')) {
        await _saveFromPage(url, dest);
      } else {
        final cookies = await CookieManager.instance().getCookies(url: wurl);
        final page = await _c?.getUrl();
        await download(wurl, dest, headers: {
          'Cookie': cookies.map((c) => '${c.name}=${c.value}').join('; '),
          'User-Agent': userAgent ?? '',
          'Referer': page?.toString() ?? '',
        });
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      await widget.onFile(dest, name);
    } on BoardException catch (e) {
      _snack(e.message);
    } catch (e) {
      _snack('The download failed: $e');
    }
  }

  /// Files a page makes itself (blob: links): the page reads them and hands them over.
  Future<void> _saveFromPage(String url, File dest) async {
    _pageReads++;
    try {
      await _readFromPage(url, dest);
    } finally {
      _pageReads--;
      final c = _c;
      if (_pageReads == 0 && _closeAfterRead && c != null) await _blank(c);
    }
  }

  Future<void> _readFromPage(String url, File dest) async {
    final r = await _c?.callAsyncJavaScript(functionBody: '''
      const r = await fetch(url);
      const b = await r.blob();
      return await new Promise((ok, fail) => {
        const fr = new FileReader();
        fr.onload = () => ok(String(fr.result).split(',')[1] || '');
        fr.onerror = () => fail('could not read the file');
        fr.readAsDataURL(b);
      });
    ''', arguments: {'url': url});
    final v = r?.value;
    if (r == null || r.error != null || v is! String || v.isEmpty) throw BoardException('The page did not hand over the file (${r?.error ?? 'empty'}).');
    await dest.parent.create(recursive: true);
    await dest.writeAsBytes(base64Decode(v));
  }

  void _snack(String text, {bool long = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text), duration: Duration(seconds: long ? 30 : 5)));
  }

  // ------------------------------------------------------------------ screen
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(children: [
      Material(
        color: cs.surfaceContainer,
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
            child: Row(children: [
              IconButton(tooltip: 'Model sites', icon: const Icon(Icons.home_outlined), onPressed: () => setState(() => _home = true)),
              IconButton(tooltip: 'Back', icon: const Icon(Icons.arrow_back), onPressed: _home ? null : () => back()),
              Expanded(
                child: TextField(
                  controller: _address,
                  focusNode: _focus,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.go,
                  onSubmitted: _go,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Search Printables or type an address',
                    filled: true,
                    fillColor: cs.surface,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                  ),
                ),
              ),
              IconButton(
                tooltip: _loading ? 'Stop' : 'Reload',
                icon: Icon(_loading ? Icons.close : Icons.refresh),
                onPressed: _home ? null : () => _loading ? _c?.stopLoading() : _c?.reload(),
              ),
            ]),
          ),
        ),
      ),
      if (_loading && !_home) LinearProgressIndicator(value: _progress > 0 ? _progress : null, minHeight: 2),
      Expanded(
        child: Stack(children: [
          InAppWebView(
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              domStorageEnabled: true,
              useOnDownloadStart: true,
              useShouldOverrideUrlLoading: true,
              supportMultipleWindows: false,
              javaScriptCanOpenWindowsAutomatically: false,
              mediaPlaybackRequiresUserGesture: true,
              thirdPartyCookiesEnabled: true,
            ),
            // catches MakerWorld's "Open in Bambu Handy" tap inside the page (see makerworld_script.dart)
            initialUserScripts: UnmodifiableListView<UserScript>([
              UserScript(source: makerWorldHandyScript, injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START),
            ]),
            onWebViewCreated: (c) {
              _c = c;
              c.addJavaScriptHandler(handlerName: 'flashBridgeHandy', callback: (args) => _handyFromPage(c, args));
              final u = _pendingUrl;
              _pendingUrl = null;
              if (u != null) c.loadUrl(urlRequest: URLRequest(url: WebUri(u)));
            },
            onLoadStart: (c, url) => setState(() {
              if (url?.toString() == 'about:blank') return; // closeSite's blank page: stays behind the picker
              _loading = true;
              if (url != null && !_focus.hasFocus) _address.text = url.toString();
            }),
            onLoadStop: (c, url) {
              setState(() => _loading = false);
              if (_wipeWhenBlank) {
                // closeSite's blank page (or a site picked before it finished loading) is up: the closed
                // site's pages are gone from Back
                _wipeWhenBlank = false;
                c.clearHistory();
              }
              // last resort: MakerWorld's Handy screen got loaded anyway → open the model page instead
              final u = url == null ? null : Uri.tryParse(url.toString());
              if (u != null && MakerWorld.isOpenApp(u)) _leaveHandyScreen(c, u);
            },
            onProgressChanged: (c, p) => setState(() => _progress = p / 100),
            onUpdateVisitedHistory: (c, url, reload) => _visited(c, url),
            onDownloadStartRequest: (c, req) => _download(req),
            // links for other apps (Bambu Handy / Studio …) are caught here, never handed over
            shouldOverrideUrlLoading: _route,
          ),
          if (_home) Positioned.fill(child: ColoredBox(color: cs.surface, child: _SitesHome(onOpen: openUrl))),
        ]),
      ),
    ]);
  }
}

class _SitesHome extends StatelessWidget {
  final void Function(String url) onOpen;
  const _SitesHome({required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('Find a model', style: t.headlineSmall),
      const SizedBox(height: 6),
      Text('Tap Download on any model: it opens straight in the slicer on your board. Sliced files (G-code) go to the printer.',
          style: t.bodyMedium),
      const SizedBox(height: 16),
      for (final s in sites)
        Card(
          child: ListTile(
            leading: Icon(s.icon, size: 32),
            title: Text(s.name, style: t.titleMedium),
            subtitle: Text(s.note),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => onOpen(s.url),
          ),
        ),
      const SizedBox(height: 12),
      Text('Tip: double-tap Models at the bottom to close the open site and come back here (you stay logged in).', style: t.bodySmall),
      const SizedBox(height: 6),
      Text('Tip: in your phone\'s browser or any app, Share a model page or file to Flash Bridge.', style: t.bodySmall),
    ]);
  }
}
