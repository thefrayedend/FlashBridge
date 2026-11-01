// Talking to the Flash Bridge board: its JSON API (the same one the web page uses) and file uploads.
// Plain dart:io, no Flutter: this file is tested on its own against a running bridge.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// What a file is, by its name: a model to slice, an already sliced file to print, or neither.
enum FileKind { model, sliced, other }

FileKind kindOf(String name) {
  final n = name.toLowerCase();
  if (n.endsWith('.gcode.3mf') || n.endsWith('.gcode') || n.endsWith('.gco') || n.endsWith('.g') || n.endsWith('.bgcode')) {
    return FileKind.sliced;
  }
  if (n.endsWith('.3mf') || n.endsWith('.stl') || n.endsWith('.obj') || n.endsWith('.zip')) return FileKind.model;
  return FileKind.other;
}

class BoardException implements Exception {
  final String message;
  BoardException(this.message);
  @override
  String toString() => message;
}

class Board {
  /// e.g. http://192.168.1.50 (no trailing slash)
  final String base;
  Board(String base) : base = base.endsWith('/') ? base.substring(0, base.length - 1) : base;

  HttpClient _client() => HttpClient()..connectionTimeout = const Duration(seconds: 6);

  Future<Map<String, dynamic>> getJson(String path, {Duration timeout = const Duration(seconds: 10)}) async {
    final c = _client();
    try {
      final req = await c.getUrl(Uri.parse('$base$path')).timeout(timeout);
      final res = await req.close().timeout(timeout);
      final body = await utf8.decodeStream(res).timeout(timeout);
      if (res.statusCode == 401) throw BoardException('The board asks for a password. Open its web page once in the Printer tab and log in.');
      final j = jsonDecode(body);
      if (j is! Map<String, dynamic>) throw BoardException('The board gave an unexpected answer.');
      return j;
    } on TimeoutException {
      throw BoardException('The board at $base did not answer in time.');
    } on IOException {
      // no route, refused, closed early, not a web server, https typed for a plain-http board …
      throw BoardException('Could not reach the board at $base.');
    } on FormatException {
      throw BoardException('$base answered, but it does not look like a Flash Bridge board.');
    } finally {
      c.close(force: true);
    }
  }

  /// Bridge name, version, printers (with their live state), AI and slicer flags.
  Future<Map<String, dynamic>> status() => getJson('/api/status');

  /// Opens a model (3MF, STL, OBJ or a ZIP of them) in the board's slicer; returns the inbox id.
  /// The slicer page opens it at '#slicer/prepare/inbox=<id>'.
  Future<String> sendToSlicer(File file, String name, {void Function(int sent, int total)? progress}) async {
    final r = await _upload('/api/slicer/inbox', file, name, progress: progress);
    final id = r['id'];
    if (r['ok'] != true || id is! String) throw BoardException('${r['message'] ?? 'The board did not take the file.'}');
    return id;
  }

  /// Puts an already sliced file (.gcode / .gcode.3mf) into a printer's file list.
  Future<String> sendToPrinter(String printerId, File file, String name, {void Function(int sent, int total)? progress}) async {
    final r = await _upload('/api/printers/${Uri.encodeComponent(printerId)}/upload', file, name, progress: progress);
    if (r['ok'] != true) throw BoardException('${r['message'] ?? 'The printer did not take the file.'}');
    return '${r['file'] ?? name}';
  }

  Future<Map<String, dynamic>> _upload(String path, File file, String name, {void Function(int sent, int total)? progress}) async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    final boundary = '----flashbridge${DateTime.now().microsecondsSinceEpoch}';
    final safe = name.replaceAll('"', "'").replaceAll('\r', '').replaceAll('\n', '');
    final head = utf8.encode('--$boundary\r\nContent-Disposition: form-data; name="file"; filename="$safe"\r\n'
        'Content-Type: application/octet-stream\r\n\r\n');
    final tail = utf8.encode('\r\n--$boundary--\r\n');
    final len = await file.length();
    try {
      final req = await c.postUrl(Uri.parse('$base$path'));
      req.headers.contentType = ContentType('multipart', 'form-data', parameters: {'boundary': boundary});
      req.contentLength = head.length + len + tail.length;
      req.add(head);
      var sent = 0;
      await for (final chunk in file.openRead()) {
        req.add(chunk);
        sent += chunk.length;
        progress?.call(sent, len);
      }
      req.add(tail);
      final res = await req.close().timeout(const Duration(minutes: 5));
      final body = await utf8.decodeStream(res);
      final j = jsonDecode(body);
      if (j is! Map<String, dynamic>) throw BoardException('The board gave an unexpected answer (${res.statusCode}).');
      return j;
    } on IOException {
      throw BoardException('Lost the connection to the board while sending $name.');
    } on FormatException {
      throw BoardException('The board did not accept $name (it may need an update).');
    } finally {
      c.close(force: true);
    }
  }
}

/// Downloads [url] into [dest] (following redirects), with the browser's cookies when given.
Future<File> download(Uri url, File dest, {Map<String, String> headers = const {}, void Function(int got, int total)? progress}) async {
  final c = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final req = await c.getUrl(url);
    headers.forEach((k, v) {
      if (v.isNotEmpty) req.headers.set(k, v);
    });
    final res = await req.close().timeout(const Duration(seconds: 60));
    if (res.statusCode >= 400) {
      await res.drain<void>();
      throw BoardException('The site answered ${res.statusCode} for that download${res.statusCode == 401 || res.statusCode == 403 ? ' (log in on the site first)' : ''}.');
    }
    await dest.parent.create(recursive: true);
    final sink = dest.openWrite();
    var got = 0;
    final total = res.contentLength;
    try {
      await for (final chunk in res.timeout(const Duration(seconds: 60))) {
        sink.add(chunk);
        got += chunk.length;
        progress?.call(got, total);
      }
    } finally {
      await sink.close();
    }
    return dest;
  } on IOException catch (e) {
    throw BoardException('The download failed: $e');
  } on TimeoutException {
    throw BoardException('The download stalled.');
  } finally {
    c.close(force: true);
  }
}

/// The file name from a Content-Disposition header (filename*=UTF-8''… or filename="…").
String? filenameFromDisposition(String? cd) {
  if (cd == null || cd.isEmpty) return null;
  final star = RegExp(r"""filename\*\s*=\s*(?:UTF-8|utf-8)''([^;]+)""").firstMatch(cd);
  if (star != null) {
    try {
      return Uri.decodeComponent(star.group(1)!.trim().replaceAll('"', ''));
    } catch (_) {}
  }
  final plain = RegExp(r'''filename\s*=\s*"?([^";]+)"?''').firstMatch(cd);
  return plain?.group(1)?.trim();
}

/// A safe local file name: no folders, nothing the file system dislikes, an extension when known.
String safeFileName(String raw, {String? mimeType}) {
  var n = raw.split('?').first.split('#').first;
  n = n.replaceAll('\\', '/').split('/').last;
  try {
    n = Uri.decodeComponent(n);
  } catch (_) {}
  n = n.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
  if (n.isEmpty) n = 'download';
  if (!n.contains('.') && mimeType != null) {
    final m = mimeType.toLowerCase();
    if (m.contains('zip')) {
      n += '.zip';
    } else if (m.contains('3mf') || m.contains('3dmanufacturing')) {
      n += '.3mf';
    } else if (m.contains('stl') || m.contains('sla')) {
      n += '.stl';
    } else if (m.contains('obj')) {
      n += '.obj';
    }
  }
  return n.length > 120 ? n.substring(n.length - 120) : n;
}

/// "1.2.10" > "1.2.9"; anything that is not a number counts as 0.
bool isNewerVersion(String latest, String current) {
  List<int> parts(String v) => v.split(RegExp(r'[.+-]')).map((s) => int.tryParse(s) ?? 0).toList();
  final a = parts(latest), b = parts(current);
  for (var i = 0; i < (a.length > b.length ? a.length : b.length); i++) {
    final x = i < a.length ? a[i] : 0, y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}
