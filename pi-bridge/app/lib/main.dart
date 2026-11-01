// Flash Bridge for Android: the board's printer and slicer pages, a model-site browser whose downloads
// open in the slicer, Open with / Share for models and G-code, and print notifications.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_model.dart';
import 'app_update.dart';
import 'board.dart';
import 'board_view.dart';
import 'browser_view.dart';
import 'native.dart';
import 'settings_view.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  Native.init();
  runApp(const FlashBridgeApp());
}

class FlashBridgeApp extends StatelessWidget {
  const FlashBridgeApp({super.key});

  // the web page's own colours (style.css --primary), so app and page look like one thing
  static ThemeData _theme(Brightness b) => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: b == Brightness.dark ? const Color(0xFF4C9AFF) : const Color(0xFF1A73E8),
          brightness: b,
        ),
      );

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Flash Bridge',
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        home: const Shell(),
      );
}

/// Tabs: 0 Printer, 1 Slicer (both the board page), 2 Models (browser), 3 Settings.
class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _tab = 0;
  final _browser = GlobalKey<BrowserViewState>();

  @override
  void initState() {
    super.initState();
    Native.onIncoming = _drainIncoming;
    app.addListener(_changed);
    _start();
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    app.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Timer? _updateTimer;

  Future<void> _start() async {
    await app.load();
    final s = await Native.getSettings();
    AppUpdate.autoUpdate = s['autoUpdate'] != false;
    final ok = await app.connect();
    if (!ok && mounted) setState(() => _tab = 3);
    await _drainIncoming();
    // the app keeps itself up to date, like the board (app_update.dart)
    Future.delayed(const Duration(seconds: 20), _autoUpdate);
    _updateTimer = Timer.periodic(const Duration(hours: 12), (_) => _autoUpdate());
  }

  Future<void> _autoUpdate() async {
    if (!AppUpdate.autoUpdate) return;
    final r = await AppUpdate.check();
    if (r.startsWith('Allow') || r.startsWith('The update')) _snack(r);
  }

  int get _stackIndex => _tab <= 1 ? 0 : _tab - 1;

  void _select(int i) {
    setState(() => _tab = i);
    if (i == 0) BoardNav.open('#home');
    if (i == 1) BoardNav.open('#slicer/prepare');
  }

  // ------------------------------------------------------------------ files and links from outside
  bool _draining = false;
  Future<void> _drainIncoming() async {
    if (_draining) return;
    _draining = true;
    try {
      while (true) {
        final items = await Native.takeIncoming();
        if (items.isEmpty) break;
        for (final m in items) {
          await _handle(m);
        }
      }
    } finally {
      _draining = false;
    }
  }

  Future<void> _handle(Map<String, String> m) async {
    if (m['error'] != null) {
      _snack(m['error']!);
      return;
    }
    final open = m['open'];
    if (open != null) {
      if (open == 'slicer' || open == 'preview') {
        setState(() => _tab = 1);
        await BoardNav.open(open == 'preview' ? '#slicer/preview' : '#slicer/prepare');
      } else {
        setState(() => _tab = 0);
        await BoardNav.open('#home');
      }
      return;
    }
    final url = m['url'];
    if (url != null) {
      setState(() => _tab = 2);
      BrowserNav.open?.call(url);
      return;
    }
    final path = m['path'];
    if (path != null) await handleFile(File(path), m['name'] ?? path.split('/').last);
  }

  /// A model goes to the board's slicer, a sliced file to the printer. The phone's copy is removed after.
  Future<void> handleFile(File file, String name) async {
    try {
      if (!app.connected && !await app.connect()) {
        _snack(app.error ?? 'Not connected to the board.');
        return;
      }
      switch (kindOf(name)) {
        case FileKind.model:
          if (!app.capabilities.contains('slicer-inbox')) {
            _snack('The board\'s slicer is off or the board needs an update (Settings → Updates on its page).');
            return;
          }
          app.busy.value = Busy('Sending $name to the slicer…', 0);
          final id = await app.board.sendToSlicer(file, name, progress: (s, t) => app.busy.value = Busy('Sending $name to the slicer…', t > 0 ? s / t : null));
          setState(() => _tab = 1);
          await BoardNav.open('#slicer/prepare/inbox=$id');
        case FileKind.sliced:
          final printers = app.printers;
          if (printers.isEmpty) {
            _snack('The board has no printer set up yet.');
            return;
          }
          final p = printers.length == 1 ? printers.first : await _pickPrinter(printers);
          if (p == null) return;
          app.busy.value = Busy('Sending $name to ${p['name']}…', 0);
          final f = await app.board.sendToPrinter('${p['id']}', file, name, progress: (s, t) => app.busy.value = Busy('Sending $name to ${p['name']}…', t > 0 ? s / t : null));
          setState(() => _tab = 0);
          await BoardNav.open('#home');
          _snack('$f is on ${p['name']}: start it from the printer\'s file list.');
        case FileKind.other:
          _snack('Flash Bridge opens 3MF, STL, OBJ and ZIP models, and G-code. "$name" is none of those.');
      }
    } on BoardException catch (e) {
      _snack(e.message);
    } finally {
      app.busy.value = null;
      try {
        if (file.path.contains('/cache/')) await file.delete();
      } catch (_) {}
    }
  }

  Future<Map<String, dynamic>?> _pickPrinter(List<Map<String, dynamic>> printers) => showDialog<Map<String, dynamic>>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('Send to which printer?'),
          children: [for (final p in printers) SimpleDialogOption(onPressed: () => Navigator.pop(ctx, p), child: Text('${p['name']}'))],
        ),
      );

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 6)));
  }

  // ------------------------------------------------------------------ back button
  Future<void> _back() async {
    if (_stackIndex == 0) {
      final c = BoardNav.controller;
      if (c != null && await c.canGoBack()) {
        await c.goBack();
        return;
      }
    } else if (_stackIndex == 1) {
      if (await (_browser.currentState?.back() ?? Future.value(false))) return;
    }
    if (_tab != 0) {
      _select(0);
      return;
    }
    await SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _back();
      },
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: Column(children: [
            ValueListenableBuilder<Busy?>(
              valueListenable: app.busy,
              builder: (context, b, _) => b == null
                  ? const SizedBox.shrink()
                  : Material(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(b.text),
                          const SizedBox(height: 6),
                          LinearProgressIndicator(value: b.progress),
                        ]),
                      ),
                    ),
            ),
            Expanded(
              child: IndexedStack(index: _stackIndex, children: [
                BoardView(onSection: (inSlicer) {
                  final want = inSlicer ? 1 : 0;
                  if (_tab <= 1 && _tab != want) setState(() => _tab = want);
                }),
                BrowserView(key: _browser, onFile: handleFile),
                const SettingsView(),
              ]),
            ),
          ]),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: _select,
          destinations: const [
            NavigationDestination(icon: Icon(Icons.print_outlined), selectedIcon: Icon(Icons.print), label: 'Printer'),
            NavigationDestination(icon: Icon(Icons.view_in_ar_outlined), selectedIcon: Icon(Icons.view_in_ar), label: 'Slicer'),
            NavigationDestination(icon: Icon(Icons.travel_explore_outlined), selectedIcon: Icon(Icons.travel_explore), label: 'Models'),
            NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Settings'),
          ],
        ),
      ),
    );
  }
}
