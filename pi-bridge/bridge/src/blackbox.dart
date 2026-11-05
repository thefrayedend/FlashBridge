// The "black box": one line of readings every 30 s to <data>/blackbox.log, so that after the
// board dies (power, heat, memory, a hang) the last minutes before it can still be read. Kept
// small: the file is rotated at 1 MB, one older copy is kept (2 MB in all). The root helper
// (ffsys.py diag) returns the tail of it and the time of the last line before the bridge last
// started ("previous boot ended").
//
// Each line:
//   <time> up=<s> temp=<°C> cpu=<cur/max MHz per policy> throttled=<yes|no|?> uv=<power-supply flag|n/a>
//   load=<1,5,15> memavail=<MB> swapused=<MB> ai=<service>/<per-printer status:inference ms> cam=<viewers>
//   net=<up|down> printers=<online>/<all>
import 'dart:async';
import 'dart:io';

import 'ai_monitor.dart';
import 'core.dart';

class BlackBox {
  final BridgeHost host;
  final AiMonitor ai;
  final File file;
  Timer? _timer;
  static const period = Duration(seconds: 30);
  static const rotateAt = 1024 * 1024; // bytes per file; one rotated copy is kept

  BlackBox(this.host, this.ai, String dataDir) : file = File('$dataDir/blackbox.log');

  /// The time of the last reading written before this start (null if none).
  String? previousEnd;

  void start() {
    try {
      file.parent.createSync(recursive: true);
      previousEnd = _lastLine();
      _append('=== bridge start ${_now()}${previousEnd != null ? ' (previous entry: $previousEnd)' : ''} ===');
    } catch (e) {
      host.log.warn('Black box: cannot write ${file.path}: $e');
    }
    _timer = Timer.periodic(period, (_) => tick());
    tick();
  }

  void stop() => _timer?.cancel();

  String? _lastLine() {
    try {
      if (!file.existsSync() || file.lengthSync() == 0) return null;
      final raf = file.openSync();
      try {
        final len = raf.lengthSync();
        final from = len > 4096 ? len - 4096 : 0;
        raf.setPositionSync(from);
        final tail = String.fromCharCodes(raf.readSync(len - from));
        final lines = tail.split('\n').where((l) => l.trim().isNotEmpty && !l.startsWith('===')).toList();
        return lines.isEmpty ? null : lines.last.split(' ').first;
      } finally {
        raf.closeSync();
      }
    } catch (_) {
      return null;
    }
  }

  static String _now() => DateTime.now().toIso8601String().split('.').first;

  Future<void> tick() async {
    try {
      _append(await readings());
    } catch (e) {
      host.log.warn('Black box: $e');
    }
  }

  void _append(String line) {
    try {
      if (file.existsSync() && file.lengthSync() > rotateAt) {
        final old = File('${file.path}.1');
        if (old.existsSync()) old.deleteSync();
        file.renameSync(old.path);
      }
      file.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (e) {
      host.log.warn('Black box: cannot write: $e');
    }
  }

  static String _read(String path) {
    try {
      return File(path).readAsStringSync().trim();
    } catch (_) {
      return '';
    }
  }

  /// One line of readings (also used by tests).
  Future<String> readings() async {
    final parts = <String>[_now()];
    final up = _read('/proc/uptime').split(' ').first;
    parts.add('up=${up.isEmpty ? '?' : double.tryParse(up)?.round() ?? '?'}s');
    // SoC temperature: the hottest thermal zone
    double? temp;
    try {
      for (final e in Directory('/sys/class/thermal').listSync()) {
        if (!e.path.split('/').last.startsWith('thermal_zone')) continue;
        final t = int.tryParse(_read('${e.path}/temp'));
        if (t != null && (temp == null || t / 1000 > temp)) temp = t / 1000;
      }
    } catch (_) {}
    parts.add('temp=${temp == null ? '?' : temp.toStringAsFixed(1)}C');
    // CPU clocks per cpufreq policy, throttled when a policy runs well under its maximum
    final clocks = <String>[];
    var throttled = false;
    try {
      const base = '/sys/devices/system/cpu/cpufreq';
      final pols = Directory(base).listSync().map((e) => e.path).toList()..sort();
      for (final p in pols) {
        final cur = int.tryParse(_read('$p/scaling_cur_freq')), max = int.tryParse(_read('$p/cpuinfo_max_freq'));
        if (cur == null || max == null) continue;
        clocks.add('${cur ~/ 1000}/${max ~/ 1000}');
        if (cur < max * 0.75) throttled = true;
      }
    } catch (_) {}
    parts.add('cpu=${clocks.isEmpty ? '?' : clocks.join(',')}MHz');
    parts.add('throttled=${clocks.isEmpty ? '?' : (throttled ? 'yes' : 'no')}');
    // Raspberry Pi firmware flags (under-voltage); other boards have none
    var uv = 'n/a';
    for (final p in ['/sys/devices/platform/soc/soc:firmware/get_throttled', '/sys/devices/platform/soc/firmware/get_throttled']) {
      final v = int.tryParse(_read(p).replaceFirst('0x', ''), radix: 16);
      if (v != null) {
        uv = (v & 0x1) != 0 ? 'NOW' : ((v & 0x10000) != 0 ? 'occurred' : 'ok');
        if ((v & 0x4) != 0) throttled = true;
        break;
      }
    }
    parts.add('uv=$uv');
    final load = _read('/proc/loadavg').split(' ');
    parts.add('load=${load.length >= 3 ? load.take(3).join(',') : '?'}');
    final mem = <String, int>{};
    for (final l in _read('/proc/meminfo').split('\n')) {
      final m = RegExp(r'^(\w+):\s+(\d+)').firstMatch(l);
      if (m != null) mem[m.group(1)!] = int.parse(m.group(2)!);
    }
    parts.add('memavail=${mem.containsKey('MemAvailable') ? (mem['MemAvailable']! ~/ 1024) : '?'}MB');
    parts.add('swapused=${mem.containsKey('SwapTotal') ? ((mem['SwapTotal']! - (mem['SwapFree'] ?? 0)) ~/ 1024) : '?'}MB');
    // the AI service and what it is doing for each printer
    final svc = ai.service;
    final svcState = svc.pausedForSlicer ? 'paused-slicer' : (!svc.reachable ? 'off' : (svc.ready ? 'ready' : 'starting'));
    final per = <String>[];
    for (final p in host.config.printers) {
      final s = ai.states[p.id];
      if (s != null) per.add('${s.status}:${s.lastInferenceMs}ms');
    }
    parts.add('ai=$svcState${per.isEmpty ? '' : '/${per.join('|')}'}');
    var viewers = 0, online = 0;
    for (final inst in host.instances.values) {
      viewers += inst.bridge.camera.clientCount;
      if (inst.bridge.online) online++;
    }
    parts.add('cam=$viewers');
    var net = false;
    try {
      for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
        if (i.addresses.any((a) => !a.isLoopback)) net = true;
      }
    } catch (_) {}
    parts.add('net=${net ? 'up' : 'down'}');
    parts.add('printers=$online/${host.instances.length}');
    return parts.join(' ');
  }
}
