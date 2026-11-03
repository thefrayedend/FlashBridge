// Checks lib/double_tap.dart with plain Dart: dart run ci/double_tap_check.dart (from pi-bridge/app)
import 'dart:io';

import '../lib/double_tap.dart';

var failed = 0;
void check(String what, Object? got, Object? want) {
  if (got == want) {
    print('ok   $what');
  } else {
    print('FAIL $what\n     got:  $got\n     want: $want');
    failed++;
  }
}

void main() {
  final t0 = DateTime(2026, 11, 3, 9);
  DateTime at(int ms) => t0.add(Duration(milliseconds: ms));
  const models = 2, printer = 0;

  var d = DoubleTap();
  check('first tap is not a double', d.tap(models, at(0)), false);
  check('second tap 300 ms later is', d.tap(models, at(300)), true);
  check('a third quick tap starts over', d.tap(models, at(500)), false);
  check('… and a fourth makes a pair again', d.tap(models, at(700)), true);

  d = DoubleTap();
  d.tap(models, at(0));
  check('exactly 400 ms still counts', d.tap(models, at(400)), true);

  d = DoubleTap();
  d.tap(models, at(0));
  check('450 ms apart is two single taps', d.tap(models, at(450)), false);
  check('… the slow second tap can start a new pair', d.tap(models, at(700)), true);

  d = DoubleTap();
  d.tap(models, at(0));
  d.tap(printer, at(100));
  check('another tab in between breaks the pair', d.tap(models, at(200)), false);

  d = DoubleTap();
  d.tap(printer, at(0));
  check('from another tab: Printer then Models is not a double', d.tap(models, at(100)), false);
  check('… Models twice is (works from any tab)', d.tap(models, at(300)), true);

  d = DoubleTap();
  d.tap(models, at(1000));
  check('clock going backwards is not a double', d.tap(models, at(900)), false);

  if (failed > 0) {
    print('$failed check(s) failed');
    exit(1);
  }
  print('All double-tap checks passed.');
}
