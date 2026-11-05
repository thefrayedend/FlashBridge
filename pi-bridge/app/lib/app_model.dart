// What the whole app shares: which board, whether it answers, and the "something is happening" bar.
import 'package:flutter/foundation.dart';

import 'board.dart';
import 'discovery.dart';
import 'native.dart';

class Busy {
  final String text;
  final double? progress; // 0..1, null = unknown
  Busy(this.text, [this.progress]);
}

class AppModel extends ChangeNotifier {
  /// What the user typed (or the default): a name like flashbridge.local or an address.
  String host = 'flashbridge.local';

  /// The address the app uses, e.g. http://192.168.1.50 (empty until the board was found once).
  String boardUrl = '';
  bool watch = false;
  Map<String, dynamic>? status;
  String? error;
  bool connecting = false;
  final busy = ValueNotifier<Busy?>(null);

  Board get board => Board(boardUrl);
  bool get connected => status != null;
  List<Map<String, dynamic>> get printers => [for (final p in (status?['printers'] as List? ?? const [])) Map<String, dynamic>.from(p as Map)];
  List<String> get capabilities => [for (final c in (status?['capabilities'] as List? ?? const [])) '$c'];
  String get boardVersion => '${status?['version'] ?? ''}';

  Future<void> load() async {
    final s = await Native.getSettings();
    host = '${s['host'] ?? ''}'.trim().isEmpty ? 'flashbridge.local' : '${s['host']}'.trim();
    boardUrl = '${s['board'] ?? ''}';
    watch = s['watch'] == true;
    notifyListeners();
  }

  /// Finds and checks the board: the last known address first, then the name (mDNS / DNS), then a
  /// search of the Wi-Fi. True when a board answered.
  Future<bool> connect({bool search = true}) async {
    connecting = true;
    error = null;
    notifyListeners();
    try {
      final tries = <String>[];
      if (boardUrl.isNotEmpty) tries.add(boardUrl);
      final h = host.trim();
      if (h.isNotEmpty) {
        if (h.startsWith('http://') || h.startsWith('https://')) {
          tries.add(h);
        } else if (RegExp(r'^\d+\.\d+\.\d+\.\d+(:\d+)?$').hasMatch(h)) {
          tries.add('http://$h');
        } else {
          final ip = await resolveLocal(h);
          if (ip != null) tries.add('http://$ip');
          tries.add('http://$h'); // a router that knows the name
        }
      }
      for (final url in tries.toSet()) {
        if (await _try(url)) return true;
      }
      if (search) {
        final found = await findBoards();
        if (found.length == 1 && await _try(found.first.url)) return true;
        if (found.length > 1) {
          error = 'Found ${found.length} boards: pick one in Settings.';
          return false;
        }
      }
      error ??= 'No Flash Bridge board found. Check that the phone is on the same Wi-Fi as the board, or type its address in Settings.';
      return false;
    } finally {
      connecting = false;
      notifyListeners();
    }
  }

  Future<bool> _try(String url) async {
    try {
      final st = await Board(url).status();
      if (st['printers'] is! List) return false;
      status = st;
      if (url != boardUrl) {
        boardUrl = url;
        await Native.setSettings(board: url);
      }
      return true;
    } on BoardException catch (e) {
      error = e.message;
      return false;
    }
  }

  Future<void> useBoard(String url, {String? name}) async {
    boardUrl = url;
    if (name != null) host = name.endsWith('.local') ? name : '$name.local';
    await Native.setSettings(board: url, host: host);
    await connect(search: false);
  }

  Future<void> setHost(String h) async {
    host = h.trim();
    boardUrl = '';
    await Native.setSettings(host: host, board: '');
    await connect();
  }

  Future<void> setWatch(bool on) async {
    if (on) await Native.requestNotifications();
    watch = on;
    await Native.setSettings(watch: on);
    notifyListeners();
  }

  Future<void> refreshStatus() async {
    if (boardUrl.isEmpty) return;
    try {
      status = await board.status();
      error = null;
    } on BoardException catch (e) {
      error = e.message;
    }
    notifyListeners();
  }
}

final app = AppModel();
