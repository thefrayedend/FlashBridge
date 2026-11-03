// Printer-name <-> board-name checks:  dart run test/sentname_check.dart
// The printer stores an upload under an OrcaSlicer-style name ("face Classic.gcode.3mf" ->
// "face_Classic.gcode.3mf") and reports the running job under that name; the board must still
// find its own file (picture, metadata) and list it once.
import 'dart:convert';
import 'dart:io';

import '../../../android-tv-app/source/lib/core/ff/ff_client.dart';
import '../../../android-tv-app/source/lib/core/moonraker/file_manager.dart';

var fails = 0;
void check(String name, bool ok, [Object? detail]) {
  stdout.writeln('${ok ? 'ok  ' : 'FAIL'} $name${ok ? '' : '  -> $detail'}');
  if (!ok) fails++;
}

void main() {
  final tmp = Directory.systemTemp.createTempSync('ffb-sent');
  const local = 'face Classic Maul Helmet Do3D.gcode.3mf';
  final onPrinter = FlashForgeClient.printerFileName(local);
  check('printer name has only safe characters', onPrinter == 'face_Classic_Maul_Helmet_Do3D.gcode.3mf', onPrinter);

  var fm = FileManager(tmp.path);
  File('${fm.gcodes.path}/$local').writeAsStringSync('zip');
  File('${fm.gcodes.path}/other.gcode').writeAsStringSync('G1');
  fm.updatePrinterFiles([onPrinter, 'benchy_C5.gcode'], {});

  // 1) nothing recorded (older version sent it): found by the same-name-with-underscores match
  check('printer job name -> board file (scan)', fm.localNameFor(onPrinter) == local, fm.localNameFor(onPrinter));
  check('resolve() maps it too', fm.resolve(onPrinter) == local, fm.resolve(onPrinter));
  check('Moonraker alias maps it too', fm.resolve('face_Classic_Maul_Helmet_Do3D.3mf.gcode') == local);
  check('a printer-only file stays as it is', fm.localNameFor('benchy_C5.gcode') == 'benchy_C5.gcode');
  check('a local file stays as it is', fm.localNameFor('other.gcode') == 'other.gcode');
  check('the board file counts as on the printer', fm.onPrinter(local) && !fm.onPrinter('other.gcode'));
  final names = fm.listFiles('gcodes').map((e) => e['path']).toList();
  check('file list shows the board file once, plus the printer-only file',
      names.length == 3 && names.contains('face Classic Maul Helmet Do3D.3mf.gcode') && names.contains('benchy_C5.gcode') && !names.contains('face_Classic_Maul_Helmet_Do3D.3mf.gcode'), names);
  final dir = fm.getDirectory('gcodes')['files'] as List;
  check('Mainsail list shows it once too', dir.length == 3, dir.map((e) => (e as Map)['filename']).toList());

  // 2) recorded at upload time and kept across a restart
  fm.rememberSentAs(onPrinter, local);
  final saved = jsonDecode(File('${tmp.path}/sent_names.json').readAsStringSync()) as Map;
  check('sent name saved on disk', saved[onPrinter] == local, saved);
  fm = FileManager(tmp.path);
  fm.updatePrinterFiles([onPrinter], {});
  check('after a restart the record is used', fm.localNameFor(onPrinter) == local);
  check('metadata comes from the board file', (fm.metadataFor(onPrinter)?['size'] as int?) == 3, fm.metadataFor(onPrinter));

  // 3) the board file is gone: the printer name is used as it is
  File('${fm.gcodes.path}/$local').deleteSync();
  check('without the board file the printer name stays', fm.localNameFor(onPrinter) == onPrinter);

  // 4) a new matching file appears later (folder changed): found again
  File('${fm.gcodes.path}/$local').writeAsStringSync('zip2');
  fm = FileManager(tmp.path);
  File('${tmp.path}/sent_names.json').deleteSync();
  fm = FileManager(tmp.path);
  fm.updatePrinterFiles([onPrinter], {});
  check('found again by scan after the record is gone', fm.localNameFor(onPrinter) == local);

  tmp.deleteSync(recursive: true);
  stdout.writeln(fails == 0 ? 'all sent-name checks passed' : '$fails FAILED');
  exit(fails == 0 ? 0 : 1);
}
