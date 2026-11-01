// A small web browser for model sites (MakerWorld, Printables, Thingiverse …). Downloads of models are
// caught and opened in the board's slicer; sliced files go to the printer. Logins are the sites' own,
// kept by the phone's web view like in any browser.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'board.dart';
import 'native.dart';

class Site {
  final String name, url, note;
  final IconData icon;
  const Site(this.name, this.url, this.note, this.icon);
}

const sites = [
  Site('MakerWorld', 'https://makerworld.com/', 'Bambu Lab\'s model site. Tap "Open in Bambu Handy" on a model: the page switches to the layout with Download 3MF. Log in with your e-mail; Google sign-in does not work inside apps.', Icons.public),
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
    final c = _c;
    if (c == null) {
      _pendingUrl = url; // the web view is not made yet: it opens this first
    } else {
      _layoutFor(url).then((_) => c.loadUrl(urlRequest: URLRequest(url: WebUri(url))));
    }
  }

  // ------------------------------------------------------------------ desktop layout, one MakerWorld page at a time
  // MakerWorld's phone layout (nice for browsing) only offers "Open in Bambu Handy". Its desktop layout
  // has the arrow next to the green button with "Download 3MF", a normal download this browser catches.
  // So browsing stays in the phone layout; when the Handy button is tapped, that one model page is shown
  // in the desktop layout (like Chrome's "Desktop site"), and leaving it goes back to the phone layout.
  String? _desktopPage; // host + path of the model page shown in the desktop layout
  static String _pageKey(String url) {
    final u = Uri.tryParse(url);
    return u == null ? url : '${u.host}${u.path}';
  }

  bool _wantsDesktop(String url) => _desktopPage != null && _pageKey(url) == _desktopPage;
  String? _phoneUa;
  bool _desktop = false;

  /// Switches the web view's layout for [url]; true when it changed (the page must be loaded again).
  Future<bool> _layoutFor(String url) async {
    final c = _c;
    final want = _wantsDesktop(url);
    if (c == null || want == _desktop) return false;
    _phoneUa ??= await InAppWebViewController.getDefaultUserAgent();
    final phone = _phoneUa ?? '';
    final chrome = RegExp(r'Chrome/[\d.]+').firstMatch(phone)?.group(0) ?? 'Chrome/130.0.0.0';
    final desktopUa = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) $chrome Safari/537.36';
    // start from the current settings: a fresh settings object would switch download catching off
    final st = await c.getSettings() ?? InAppWebViewSettings();
    st.userAgent = want ? desktopUa : phone;
    st.useWideViewPort = want;
    st.loadWithOverviewMode = want;
    st.supportZoom = true;
    st.builtInZoomControls = true;
    st.displayZoomControls = false;
    st.useOnDownloadStart = true;
    st.useShouldOverrideUrlLoading = true;
    await c.setSettings(settings: st);
    _desktop = want;
    return true;
  }

  // ------------------------------------------------------------------ links meant for other apps
  // Nothing in this browser is handed to another app. Bambu's app links are caught: when one carries the
  // model file's address it is downloaded here; otherwise the user is shown the Download 3MF button.
  static const _bambuHint = 'That button opens Bambu\'s own app. Tap the small arrow next to the green button and choose '
      '"Download 3MF": it opens here, in the slicer.';
  static const _desktopHint = 'This page is now in the desktop layout: tap the small arrow next to the green "Open in Bambu Studio" '
      'button and choose "Download 3MF". It opens here, in the slicer.';

  /// The Handy button was tapped: show this model page in the desktop layout, where Download 3MF is.
  Future<void> _showDownloadLayout(InAppWebViewController c) async {
    final page = await c.getUrl();
    if (page == null) {
      _snack(_bambuHint);
      return;
    }
    _desktopPage = _pageKey(page.toString());
    if (await _layoutFor(page.toString())) await c.loadUrl(urlRequest: URLRequest(url: page));
    _snack(_desktopHint, long: true);
  }

  Future<NavigationActionPolicy> _route(InAppWebViewController c, NavigationAction action) async {
    final url = action.request.url;
    final s = url?.toString() ?? '';
    final main = action.isForMainFrame != false;
    if (s.isEmpty || s.startsWith('about:') || s.startsWith('blob:') || s.startsWith('data:')) return NavigationActionPolicy.ALLOW;
    if (s.startsWith('http://') || s.startsWith('https://')) {
      // MakerWorld's "Open in Bambu Handy" goes through makerworld.com/…/open-app/…
      if (url!.host.endsWith('makerworld.com') && url.path.contains('/open-app')) {
        if (main) await _showDownloadLayout(c);
        return NavigationActionPolicy.CANCEL;
      }
      if (main && await _layoutFor(s)) {
        await c.loadUrl(urlRequest: URLRequest(url: url));
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
      if (_desktop) {
        _snack(_bambuHint);
      } else {
        await _showDownloadLayout(c);
      }
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
      await c.goBack();
      return true;
    }
    setState(() => _home = true);
    return true;
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
            onWebViewCreated: (c) {
              _c = c;
              final u = _pendingUrl;
              _pendingUrl = null;
              if (u != null) _layoutFor(u).then((_) => c.loadUrl(urlRequest: URLRequest(url: WebUri(u))));
            },
            onLoadStart: (c, url) => setState(() {
              _loading = true;
              if (url != null && !_focus.hasFocus) _address.text = url.toString();
            }),
            onLoadStop: (c, url) => setState(() => _loading = false),
            onProgressChanged: (c, p) => setState(() => _progress = p / 100),
            onUpdateVisitedHistory: (c, url, reload) {
              if (url != null && !_focus.hasFocus) _address.text = url.toString();
            },
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
      Text('Tip: in your phone\'s browser or any app, Share a model page or file to Flash Bridge.', style: t.bodySmall),
    ]);
  }
}
