// Checks lib/makerworld.dart with plain Dart: dart run ci/makerworld_check.dart (from pi-bridge/app)
import 'dart:io';

import '../lib/makerworld.dart';
import '../lib/makerworld_script.dart';

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
  // the two addresses MakerWorld really used (2026-11-02, phone layout, "Open in Bambu Handy")
  final step1 = Uri.parse('https://makerworld.com/en/open-app?toPath=%2Fdesign%2Fmodel%2Fdetail%3Fdesign_id%3D3272331%26instance_id%3D3710672&from=Model');
  final step2 = Uri.parse('https://makerworld.com/open-app/with-android?path=bambulab%3A%2F%2Fbbl%2Fdesign%2Fmodel%2Fdetail%3Fdesign_id%3D3272331%26instance_id%3D3710672%26source_from%3DPromotionLanding');
  final page = Uri.parse('https://makerworld.com/en/models/3272331-midnight-majesty-black-jaguar#profileId-3710672');

  check('step 1 is open-app', MakerWorld.isOpenApp(step1), true);
  check('step 2 is open-app', MakerWorld.isOpenApp(step2), true);
  check('model page is not open-app', MakerWorld.isOpenApp(page), false);
  check('step 1 → model page', MakerWorld.modelPageFor(step1), 'https://makerworld.com/en/models/3272331#profileId-3710672');
  check('step 2 → model page (no language in it: en)', MakerWorld.modelPageFor(step2), 'https://makerworld.com/en/models/3272331#profileId-3710672');
  check('other language kept', MakerWorld.modelPageFor(Uri.parse('https://makerworld.com/de/open-app?toPath=%2Fdesign%2Fmodel%2Fdetail%3Fdesign_id%3D42')),
      'https://makerworld.com/de/models/42');
  check('open-app without a model', MakerWorld.modelPageFor(Uri.parse('https://makerworld.com/en/open-app?from=Home')), null);
  check('not MakerWorld', MakerWorld.modelPageFor(Uri.parse('https://example.com/open-app?design_id=1')), null);

  check('Bambu app link', MakerWorld.modelPageIn('bambulab://bbl/design/model/detail?design_id=3272331&instance_id=3710672&source_from=PromotionLanding'),
      'https://makerworld.com/en/models/3272331#profileId-3710672');
  check('link without a model', MakerWorld.modelPageIn('bambulab://bbl/home'), null);

  check('www host', MakerWorld.isOpenApp(Uri.parse('https://www.makerworld.com/en/open-app?x=1')), true);

  // Jon's address from the phone (0.1.4, 2026-11-02)
  check("Jon's Handy screen → model page",
      MakerWorld.modelPageFor(Uri.parse('https://makerworld.com/en/open-app?toPath=%2Fdesign%2Fmodel%2Fdetail%3Fdesign_id%3D3427154%26instance_id%3D3906475&from=Model')),
      'https://makerworld.com/en/models/3427154#profileId-3906475');
  // the page script calls the handler the app registers
  check('page script names the app handler', makerWorldHandyScript.contains("callHandler('flashBridgeHandy'"), true);
  check('page script reports the two answers the app knows',
      makerWorldHandyScript.contains("tell('download')") && makerWorldHandyScript.contains("tell('nomenu')"), true);
  // and is valid JavaScript (when node is there)
  final js = File('${Directory.systemTemp.path}/flashbridge-handy.js')..writeAsStringSync(makerWorldHandyScript);
  try {
    final r = Process.runSync('node', ['--check', js.path]);
    check('page script is valid JavaScript', r.exitCode, 0);
  } on ProcessException {
    print('skip page script syntax (no node)');
  }

  if (failed > 0) {
    print('$failed check(s) failed');
    exit(1);
  }
  print('All MakerWorld checks passed.');
}
