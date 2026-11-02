// MakerWorld addresses, worked out without the network (plain Dart: checked by ci/makerworld_check.dart).
//
// What "Open in Bambu Handy" does on a phone (seen 2026-11-02 on a model page):
//   1. the page itself switches (no new page load, so the web view's link check never sees it) to
//      makerworld.com/en/open-app?toPath=/design/model/detail?design_id=3272331&instance_id=3710672 —
//      a "Download Bambu Handy" screen that has nothing to do with the model;
//   2. then it loads makerworld.com/open-app/with-android?path=bambulab://bbl/design/model/detail?design_id=…
// Both carry the model's number (design_id) and the print profile (instance_id), so the model page can be
// opened straight from them: makerworld.com/en/models/3272331#profileId-3710672 (MakerWorld adds the name).

class MakerWorld {
  static bool isSite(Uri u) => u.host == 'makerworld.com' || u.host.endsWith('.makerworld.com');

  /// The Handy hand-off screen or redirect (step 1 or 2 above).
  static bool isOpenApp(Uri u) => isSite(u) && u.path.contains('/open-app');

  /// A model page: /en/models/3272331-midnight-majesty-black-jaguar (any language, with or without the name).
  static String? modelId(Uri u) {
    if (!isSite(u)) return null;
    return RegExp(r'/models/(\d+)').firstMatch(u.path)?.group(1);
  }

  /// The same page whatever its name part, language, query or #profile: "makerworld/models/3272331".
  static String? pageKey(Uri u) {
    final id = modelId(u);
    return id == null ? null : 'makerworld/models/$id';
  }

  /// The model page an open-app address is about, or null.
  static String? modelPageFor(Uri u) {
    if (!isOpenApp(u)) return null;
    final first = u.pathSegments.isNotEmpty ? u.pathSegments.first : '';
    final lang = RegExp(r'^[a-z]{2}(-[a-zA-Z]{2,4})?$').hasMatch(first) ? first : 'en';
    return modelPageIn(u.toString(), lang: lang);
  }

  /// The model page named by any address that carries design_id (an open-app address, or Bambu's own
  /// bambulab://bbl/design/model/detail?design_id=… link), or null.
  static String? modelPageIn(String address, {String lang = 'en'}) {
    var text = address;
    // the model's address sits inside, encoded once or twice
    for (var i = 0; i < 3; i++) {
      try {
        final d = Uri.decodeFull(text);
        if (d == text) break;
        text = d;
      } catch (_) {
        break;
      }
    }
    final id = RegExp(r'design_id=(\d+)').firstMatch(text)?.group(1);
    if (id == null) return null;
    final profile = RegExp(r'instance_id=(\d+)').firstMatch(text)?.group(1);
    return 'https://makerworld.com/$lang/models/$id${profile == null ? '' : '#profileId-$profile'}';
  }
}
