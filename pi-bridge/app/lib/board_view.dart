// The board's own web page (printer, camera, controls, slicer, settings) inside the app.
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'app_model.dart';
import 'native.dart';

/// Lets the rest of the app steer the board page (open the slicer, a file sent to it, …).
class BoardNav {
  static InAppWebViewController? controller;
  static bool loaded = false;

  /// Shows a part of the board page, e.g. '#home', '#slicer/prepare', '#slicer/prepare/inbox=<id>'.
  static Future<void> open(String hash) async {
    final c = controller;
    if (c == null || app.boardUrl.isEmpty) return;
    final url = await c.getUrl();
    if (loaded && url != null && url.toString().startsWith(app.boardUrl)) {
      await c.evaluateJavascript(source: 'location.hash = ${_js(hash)};');
    } else {
      await c.loadUrl(urlRequest: URLRequest(url: WebUri('${app.boardUrl}/$hash')));
    }
  }

  static String _js(String s) => "'${s.replaceAll('\\', '\\\\').replaceAll("'", "\\'")}'";
}

class BoardView extends StatefulWidget {
  /// Called with true when the page shows the slicer, false for the printer screens.
  final void Function(bool inSlicer) onSection;
  const BoardView({super.key, required this.onSection});

  @override
  State<BoardView> createState() => _BoardViewState();
}

class _BoardViewState extends State<BoardView> {
  String _shown = '';
  double _progress = 0;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    app.addListener(_onApp);
  }

  @override
  void dispose() {
    app.removeListener(_onApp);
    super.dispose();
  }

  void _onApp() {
    // a different board was picked: load its page
    if (app.boardUrl.isNotEmpty && app.boardUrl != _shown && BoardNav.controller != null) {
      _shown = app.boardUrl;
      BoardNav.loaded = false;
      BoardNav.controller!.loadUrl(urlRequest: URLRequest(url: WebUri('${app.boardUrl}/')));
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (app.boardUrl.isEmpty) {
      BoardNav.controller = null; // the web view is gone
      BoardNav.loaded = false;
      return _Message(
        icon: Icons.wifi_find,
        text: app.connecting ? 'Looking for your board…' : (app.error ?? 'No board yet. Find it in Settings.'),
        busy: app.connecting,
        action: app.connecting ? null : FilledButton(onPressed: () => app.connect(), child: const Text('Search again')),
      );
    }
    return Stack(children: [
      InAppWebView(
        initialUrlRequest: URLRequest(url: WebUri('${app.boardUrl}/')),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          domStorageEnabled: true,
          useOnDownloadStart: true,
          useShouldOverrideUrlLoading: true,
          mediaPlaybackRequiresUserGesture: false,
          supportZoom: false,
          builtInZoomControls: false,
          transparentBackground: true,
          supportMultipleWindows: false,
          mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
          cacheMode: CacheMode.LOAD_DEFAULT,
          // tells the board's pages they run inside the phone app (User-Agent ends with "FlashBridgeApp"), so
          // they can hide parts that don't suit the app (APP-NOTES.md); the model-site browser doesn't send it
          applicationNameForUserAgent: 'FlashBridgeApp',
        ),
        onWebViewCreated: (c) {
          BoardNav.controller = c;
          _shown = app.boardUrl;
        },
        onLoadStart: (c, url) => setState(() {
          BoardNav.loaded = false;
          _loadError = null;
        }),
        onLoadStop: (c, url) => setState(() => BoardNav.loaded = true),
        onProgressChanged: (c, p) => setState(() => _progress = p / 100),
        onReceivedError: (c, req, err) {
          if (req.isForMainFrame ?? true) setState(() => _loadError = err.description);
        },
        onUpdateVisitedHistory: (c, url, isReload) {
          final frag = url?.fragment ?? '';
          widget.onSection(frag.startsWith('slicer'));
        },
        // sliced files, backups … go to the phone's browser, which saves them in Downloads
        onDownloadStartRequest: (c, req) => Native.openExternal(req.url.toString()),
        // links away from the board (help pages, GitHub) open in the phone's browser
        shouldOverrideUrlLoading: (c, action) async {
          final u = action.request.url;
          if (u == null || action.isForMainFrame == false) return NavigationActionPolicy.ALLOW;
          final s = u.toString();
          if (s.startsWith(app.boardUrl) || s.startsWith('about:') || s.startsWith('data:') || s.startsWith('blob:')) return NavigationActionPolicy.ALLOW;
          await Native.openExternal(s);
          return NavigationActionPolicy.CANCEL;
        },
      ),
      if (_progress < 1) LinearProgressIndicator(value: _progress, minHeight: 2),
      if (_loadError != null)
        Positioned.fill(
          child: ColoredBox(
            color: Theme.of(context).colorScheme.surface,
            child: _Message(
              icon: Icons.cloud_off,
              text: 'The board did not answer ($_loadError).\nIs it switched on and on the same Wi-Fi?',
              action: FilledButton(
                onPressed: () async {
                  setState(() => _loadError = null);
                  if (await app.connect()) BoardNav.controller?.loadUrl(urlRequest: URLRequest(url: WebUri('${app.boardUrl}/')));
                },
                child: const Text('Try again'),
              ),
            ),
          ),
        ),
    ]);
  }
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String text;
  final Widget? action;
  final bool busy;
  const _Message({required this.icon, required this.text, this.action, this.busy = false});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            busy ? const SizedBox(width: 40, height: 40, child: CircularProgressIndicator()) : Icon(icon, size: 48, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text(text, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyLarge),
            if (action != null) ...[const SizedBox(height: 20), action!],
          ]),
        ),
      );
}
