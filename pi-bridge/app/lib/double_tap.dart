// Two quick taps on the same bottom tab (plain Dart: checked by ci/double_tap_check.dart).
// Used for the Models tab: a double tap closes the open model site and shows the site picker.

class DoubleTap {
  /// How close the two taps must be.
  final Duration gap;
  DoubleTap({this.gap = const Duration(milliseconds: 400)});

  int? _tab;
  DateTime? _at;

  /// Call on every tab tap; true when this tap is the second of a quick pair on [tab].
  /// A tap on another tab in between breaks the pair, and a third quick tap starts a new pair.
  bool tap(int tab, DateTime now) {
    final pair = _tab == tab && _at != null && !now.isBefore(_at!) && now.difference(_at!) <= gap;
    if (pair) {
      _tab = null;
      _at = null;
    } else {
      _tab = tab;
      _at = now;
    }
    return pair;
  }
}
