// Fake printers that hang up during an upload: the bridge must report what the printer said, not "broken pipe".
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../android-tv-app/source/lib/core/ff/ff_client.dart';

Future<String> run(String mode, File f) async {
  final srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  srv.listen((s) {
    var got = 0, headerDone = false, want = 0;
    final buf = <int>[];
    s.listen((d) {
      if (!headerDone) {
        buf.addAll(d);
        if (!latin1.decode(buf).contains('\r\n\r\n')) return;
        headerDone = true;
        final h = latin1.decode(buf);
        want = int.parse(RegExp(r'Content-Length: (\d+)').firstMatch(h)!.group(1)!);
        got = buf.length - (h.indexOf('\r\n\r\n') + 4);
        if (mode == 'refuse-now') {
          s.add(utf8.encode('HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{"code":1,"message":"File already exists"}'));
          s.destroy();
          return;
        }
        s.add(utf8.encode('HTTP/1.1 100 Continue\r\n\r\n'));
        return;
      }
      got += d.length;
      if (got > 2 * 1048576 && mode != 'ok') {
        if (mode == 'refuse-mid') s.add(utf8.encode('HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{"code":1,"message":"Not enough space"}'));
        s.destroy();
      }
      if (mode == 'ok' && got >= want) {
        s.add(utf8.encode('HTTP/1.1 200 OK\r\n\r\n{"code":0,"message":"Success"}'));
        s.close();
      }
    }, onError: (_) {});
  });
  final c = FlashForgeClient('127.0.0.1', 'SN', 'CC', httpPort: srv.port)..isCreator5 = true;
  try {
    await c.upload(f, 'big.gcode.3mf').timeout(const Duration(seconds: 30));
    return 'OK';
  } catch (e) {
    return '${e.runtimeType}: $e';
  } finally {
    await srv.close();
  }
}

Future<void> main() async {
  final f = File('${Directory.systemTemp.path}/ffb-up-test.bin');
  await f.writeAsBytes(List.filled(40 * 1048576, 65));
  var fail = 0;
  for (final m in ['refuse-now', 'refuse-mid', 'hangup', 'ok']) {
    final r = await run(m, f);
    print('$m -> $r');
    final good = switch (m) {
      'refuse-now' => r.contains('File already exists'),
      'refuse-mid' => r.contains('Not enough space') && r.contains('of 40.0 MB'),
      'hangup' => r.contains('closed the connection after') && !r.contains('Broken pipe'),
      _ => r == 'OK',
    };
    if (!good) fail++;
  }
  await f.delete();
  print(fail == 0 ? 'all upload checks passed' : '$fail upload checks FAILED');
  exit(fail == 0 ? 0 : 1);
}
