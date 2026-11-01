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
  Site('MakerWorld', 'https://makerworld.com/', 'Bambu Lab\'s model site. Log in with your e-mail (Google sign-in does not work inside apps).', Icons.public),
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
      c.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    }
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
    final url = req.url.toString();
    final name = safeFileName(req.suggestedFilename ?? filenameFromDisposition(req.contentDisposition) ?? req.url.pathSegments.lastOrNull ?? 'download', mimeType: req.mimeType);
    if (kindOf(name) == FileKind.other) {
      _snack('$name is not a model Flash Bridge can open (3MF, STL, OBJ, ZIP or G-code). Opening it in your phone\'s browser instead.');
      await Native.openExternal(url);
      return;
    }
    final dir = Directory('${(await Native.cacheDir()).path}/downloads');
    final dest = File('${dir.path}/${DateTime.now().millisecondsSinceEpoch}-$name');
    try {
      _snack('Downloading $name…', long: true);
      if (url.startsWith('blob:') || url.startsWith('data:')) {
        await _saveFromPage(url, dest);
      } else {
        final cookies = await CookieManager.instance().getCookies(url: req.url);
        final page = await _c?.getUrl();
        await download(req.url, dest, headers: {
          'Cookie': cookies.map((c) => '${c.name}=${c.value}').join('; '),
          'User-Agent': req.userAgent ?? '',
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
              if (u != null) c.loadUrl(urlRequest: URLRequest(url: WebUri(u)));
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
            // links for other apps (intent://, market://, mailto:) go to Android instead of an error page
            shouldOverrideUrlLoading: (c, action) async {
              final s = action.request.url?.toString() ?? '';
              if (s.isEmpty || s.startsWith('http://') || s.startsWith('https://') || s.startsWith('about:') || s.startsWith('blob:') || s.startsWith('data:')) {
                return NavigationActionPolicy.ALLOW;
              }
              if (action.isForMainFrame != false) await Native.openExternal(s);
              return NavigationActionPolicy.CANCEL;
            },
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
