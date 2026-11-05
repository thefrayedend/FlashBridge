// Tiny logger writing to a rotating file + in-memory ring for the TV UI.
import 'dart:async';
import 'dart:collection';
import 'dart:io';

class Log {
  final File? file;
  final lines = ListQueue<String>();
  Log([String? path]) : file = path == null ? null : File(path) {
    try {
      if (file != null && file!.existsSync() && file!.lengthSync() > 2 * 1024 * 1024) {
        file!.renameSync('${file!.path}.1');
      }
    } catch (_) {}
  }

  void _w(String level, String msg) {
    final line = '${DateTime.now().toIso8601String()} [$level] $msg';
    lines.add(line);
    while (lines.length > 300) {
      lines.removeFirst();
    }
    _console(line);
    try {
      file?.writeAsStringSync('$line\n', mode: FileMode.append);
    } catch (_) {}
  }

  // Console copy (systemd sends it to the journal). print() writes synchronously: if the journal
  // stops reading for a while (journald restarting, flushing, a full /var/log), the whole bridge
  // froze on that write - web page dead on every address, box otherwise fine (2026-11-04). Now the
  // write is asynchronous and at most [_maxBacklog] lines wait; beyond that lines are dropped from
  // the console copy only (the log file and the page's log still get every line).
  static IOSink? _out;
  static int _backlog = 0, _dropped = 0;
  static const _maxBacklog = 200;

  static void _console(String line) {
    try {
      _out ??= stdout.nonBlocking;
      if (_backlog >= _maxBacklog) {
        _dropped++;
        return;
      }
      final out = _out!;
      if (_dropped > 0) {
        out.writeln('(log: $_dropped lines not shown here - the journal was not reading)');
        _dropped = 0;
      }
      _backlog++;
      out.writeln(line);
      unawaited(out.flush().then((_) => _backlog = 0, onError: (_) => _backlog = 0));
    } catch (_) {}
  }

  void info(String m) => _w('INFO', m);
  void warn(String m) => _w('WARN', m);
  void error(String m) => _w('ERROR', m);
}
