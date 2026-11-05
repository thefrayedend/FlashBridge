// Black box checks:  dart run test/blackbox_check.dart
// The readings line has every field, the file rotates at 1 MB keeping one old copy, and the
// bridge finds the time of the last reading from before its start.
import 'dart:io';

import '../src/ai_monitor.dart';
import '../src/blackbox.dart';
import '../src/core.dart';
import '../src/pi_config.dart';

var fails = 0;
void check(String name, bool ok, [Object? detail]) {
  stdout.writeln('${ok ? 'ok  ' : 'FAIL'} $name${ok ? '' : '  -> $detail'}');
  if (!ok) fails++;
}

Future<void> main() async {
  final tmp = Directory.systemTemp.createTempSync('ffb-bb');
  final host = BridgeHost(tmp.path, tmp.path);
  final pi = PiConfig(tmp.path);
  final ai = AiMonitor(host, pi, Uri.parse('http://127.0.0.1:1'), host.log);

  // 1) a readings line
  final bb = BlackBox(host, ai, tmp.path);
  final line = await bb.readings();
  stdout.writeln('     $line');
  final fields = line.split(' ');
  check('starts with a time', RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d$').hasMatch(fields.first), fields.first);
  for (final k in ['up=', 'temp=', 'cpu=', 'throttled=', 'uv=', 'load=', 'memavail=', 'swapused=', 'ai=', 'cam=', 'net=', 'printers=']) {
    check('has $k', fields.any((f) => f.startsWith(k)));
  }
  check('memory in MB', RegExp(r'memavail=(\d+|\?)MB').hasMatch(line), line);
  check('no printers -> printers=0/0, cam=0', line.contains('printers=0/0') && line.contains('cam=0'));
  check('AI service off in this test', line.contains('ai=off'), line);

  // 2) start writes a marker and remembers the previous end
  final f = File('${tmp.path}/blackbox.log');
  f.writeAsStringSync('2026-11-04T10:01:00 up=60s temp=41.0C\n2026-11-04T10:01:30 up=90s temp=42.0C\n');
  bb.start();
  bb.stop();
  await Future<void>.delayed(const Duration(milliseconds: 300));
  final text = f.readAsStringSync();
  check('previous end found', bb.previousEnd == '2026-11-04T10:01:30', bb.previousEnd);
  check('start marker written with the previous entry', text.contains('=== bridge start ') && text.contains('(previous entry: 2026-11-04T10:01:30)'), text);
  check('first reading written right after the marker', text.trim().split('\n').length == 4, text.trim().split('\n').length);

  // 3) rotation at 1 MB keeps one older copy
  final big = StringBuffer();
  while (big.length < 1024 * 1024 + 100) {
    big.writeln('2026-11-04T11:00:00 up=1s temp=40.0C cpu=?MHz throttled=? uv=n/a load=0,0,0 memavail=1MB swapused=0MB ai=off cam=0 net=up printers=0/0');
  }
  f.writeAsStringSync(big.toString());
  await bb.tick();
  final old = File('${tmp.path}/blackbox.log.1');
  check('rotated: old copy kept', old.existsSync() && old.lengthSync() > 1024 * 1024, old.existsSync());
  check('new file holds just the new line', f.existsSync() && f.readAsStringSync().trim().split('\n').length == 1, f.lengthSync());
  await bb.tick();
  check('rotation keeps only one old copy (2 MB in all at most)', old.lengthSync() > 1024 * 1024 && f.lengthSync() < 1024 && !File('${tmp.path}/blackbox.log.2').existsSync());

  // 4) a bridge start with no earlier file
  f.deleteSync();
  old.deleteSync();
  final bb2 = BlackBox(host, ai, tmp.path)..start();
  bb2.stop();
  check('no earlier file -> previous end unknown, marker without it', bb2.previousEnd == null && f.readAsStringSync().startsWith('=== bridge start ') && !f.readAsStringSync().contains('previous entry'));

  tmp.deleteSync(recursive: true);
  stdout.writeln(fails == 0 ? 'all black box checks passed' : '$fails FAILED');
  exit(fails == 0 ? 0 : 1);
}
