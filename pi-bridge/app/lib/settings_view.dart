// The app's own settings: which board, notifications, model sites, app version and updates.
import 'package:flutter/material.dart';

import 'app_model.dart';
import 'app_update.dart';
import 'discovery.dart';
import 'native.dart';


class SettingsView extends StatefulWidget {
  const SettingsView({super.key});

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  final _host = TextEditingController();
  List<FoundBoard>? _found;
  bool _searching = false;
  String _version = '';
  String? _update;

  @override
  void initState() {
    super.initState();
    _host.text = app.host;
    app.addListener(_changed);
    Native.appVersion().then((v) {
      if (mounted) setState(() => _version = v);
    });
  }

  @override
  void dispose() {
    app.removeListener(_changed);
    _host.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _search() async {
    setState(() {
      _searching = true;
      _found = null;
    });
    final f = await findBoards();
    if (mounted) {
      setState(() {
        _searching = false;
        _found = f;
      });
    }
  }

  Future<void> _checkUpdate() async {
    setState(() => _update = 'Checking…');
    final r = await AppUpdate.check(manual: true);
    if (mounted) setState(() => _update = r);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final printers = app.printers;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('Settings', style: t.headlineSmall),
      const SizedBox(height: 12),
      // ------------------------------------------------ board
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Board', style: t.titleMedium),
            const SizedBox(height: 4),
            Text(
              app.connecting
                  ? 'Connecting…'
                  : app.connected
                      ? 'Connected to ${app.boardUrl} · Flash Bridge ${app.boardVersion}${printers.isEmpty ? '' : ' · ${printers.map((p) => p['name']).join(', ')}'}'
                      : (app.error ?? 'Not connected.'),
              style: t.bodyMedium,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _host,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: 'Board name or address', hintText: 'flashbridge.local or 192.168.1.50', border: OutlineInputBorder()),
              onSubmitted: (v) => app.setHost(v),
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton(onPressed: app.connecting ? null : () => app.setHost(_host.text), child: const Text('Connect')),
              OutlinedButton.icon(
                onPressed: _searching ? null : _search,
                icon: _searching ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.wifi_find),
                label: const Text('Find on this Wi-Fi'),
              ),
            ]),
            if (_found != null) ...[
              const SizedBox(height: 8),
              if (_found!.isEmpty) Text('No board answered. Is the phone on the same Wi-Fi as the board?', style: t.bodySmall),
              for (final b in _found!)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.memory),
                  title: Text(b.name),
                  subtitle: Text(b.url),
                  trailing: b.url == app.boardUrl ? const Icon(Icons.check) : null,
                  onTap: () {
                    _host.text = '${b.name}.local';
                    app.useBoard(b.url, name: b.name);
                  },
                ),
            ],
          ]),
        ),
      ),
      // ------------------------------------------------ notifications
      Card(
        child: SwitchListTile(
          value: app.watch,
          onChanged: app.boardUrl.isEmpty ? null : (v) => app.setWatch(v),
          title: const Text('Print notifications'),
          subtitle: const Text('Shows the running print (or slice) in the notification bar, and alerts you when a print finishes, '
              'is paused (also by the AI failure detection), fails or loses contact, and when a slice is done.'),
        ),
      ),
      // ------------------------------------------------ model sites
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Models from other apps', style: t.titleMedium),
            const SizedBox(height: 4),
            Text('Open or Share a 3MF, STL, OBJ or ZIP to Flash Bridge from any app (Files, Downloads, Discord, your browser): '
                'it opens in the slicer on the board. G-code files go to the printer. Sharing a model page\'s link opens it in the Models tab.',
                style: t.bodyMedium),
          ]),
        ),
      ),
      // ------------------------------------------------ app
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('App', style: t.titleMedium),
            const SizedBox(height: 4),
            Text('Flash Bridge for Android $_version', style: t.bodyMedium),
            if (_update != null) ...[const SizedBox(height: 6), Text(_update!, style: t.bodySmall)],
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: AppUpdate.autoUpdate,
              onChanged: (v) async {
                setState(() => AppUpdate.autoUpdate = v);
                await Native.setSettings(autoUpdate: v);
              },
              title: const Text('Update the app by itself'),
              subtitle: const Text('Checks GitHub when the app opens and every 12 hours, and installs new versions. '
                  'Android asks once to allow it; on Android 12 and newer, later updates need no tap.'),
            ),
            const SizedBox(height: 4),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton(onPressed: _checkUpdate, child: const Text('Check for updates')),
              if (app.boardUrl.isNotEmpty) OutlinedButton(onPressed: () => Native.openExternal('${app.boardUrl}/'), child: const Text('Open the board in the browser')),
            ]),
          ]),
        ),
      ),
    ]);
  }
}
