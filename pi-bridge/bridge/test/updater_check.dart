// Checks that each board only ever sees its own update packages (FFB_BOARD, release tag, "board" field).
import 'dart:io';
import '../src/updater.dart';

void main() {
  var failed = 0;
  void check(String what, bool ok, [Object? detail]) {
    stdout.writeln('${ok ? 'ok  ' : 'FAIL'} $what${ok ? '' : '  -> $detail'}');
    if (!ok) failed++;
  }

  check('Orange Pi keeps the original release name', Updater.releaseTag('orangepi-zero4') == 'latest-image');
  check('Raspberry Pi 4 has its own release', Updater.releaseTag('raspberrypi-4') == 'latest-image-pi4', Updater.releaseTag('raspberrypi-4'));
  check('package without a board field is accepted (older packages)', Updater.forThisBoard({'version': '1.0.40'}, 'orangepi-zero4'));
  check('package for the same board is accepted', Updater.forThisBoard({'board': 'raspberrypi-4'}, 'raspberrypi-4'));
  check('package for another board is refused', !Updater.forThisBoard({'board': 'orangepi-zero4'}, 'raspberrypi-4'));
  check('newer version still compared', Updater.isNewer('1.0.41', '1.0.40') && !Updater.isNewer('1.0.40', '1.0.40'));
  stdout.writeln(failed == 0 ? 'all updater checks passed' : '$failed FAILED');
  exit(failed == 0 ? 0 : 1);
}
