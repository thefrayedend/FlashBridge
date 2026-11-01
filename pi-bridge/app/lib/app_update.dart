// The app keeps itself up to date, like the board does: it checks the "latest-app" release on GitHub
// when it opens and every 12 hours, downloads a newer APK and hands it to Android's installer
// (Updater.kt). Android asks once to allow installs; after that updates go in by themselves (Android 12+).
import 'dart:convert';
import 'dart:io';

import 'app_model.dart';
import 'board.dart';
import 'native.dart';

/// Where GitHub Actions publishes the app (pi-bridge/app/ci/build-apk.sh).
const appReleaseBase = 'https://github.com/thefrayedend/ffbridge-pi/releases/download/latest-app';

class AppUpdate {
  static bool _running = false;
  static bool autoUpdate = true;

  /// Checks for a newer app; installs it when [install] (or when automatic updates are on).
  /// Returns a line for the Settings page.
  static Future<String> check({bool manual = false}) async {
    if (_running) return 'Already checking…';
    _running = true;
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final current = await Native.appVersion();
      final req = await c.getUrl(Uri.parse('$appReleaseBase/flash-bridge-app.json'));
      final res = await req.close().timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        await res.drain<void>();
        return 'Could not check for updates (GitHub answered ${res.statusCode}).';
      }
      final j = jsonDecode(await utf8.decodeStream(res)) as Map<String, dynamic>;
      final latest = '${j['version'] ?? ''}';
      if (!isNewerVersion(latest, current)) return 'This is the latest version ($current).';
      if (!manual && !autoUpdate) return 'Version $latest is out (automatic updates are off).';
      final dir = await Native.cacheDir();
      final apk = File('${dir.path}/update/flash-bridge-$latest.apk');
      app.busy.value = Busy('Downloading Flash Bridge $latest…', 0);
      await download(Uri.parse('$appReleaseBase/${j['apk'] ?? 'flash-bridge.apk'}'), apk,
          progress: (got, total) => app.busy.value = Busy('Downloading Flash Bridge $latest…', total > 0 ? got / total : null));
      app.busy.value = Busy('Installing Flash Bridge $latest…');
      final r = await Native.installApk(apk.path);
      if (r == 'permission') {
        return 'Allow "Install unknown apps" for Flash Bridge (Android just opened that switch), then come back: the update installs next time.';
      }
      if (r.startsWith('error')) return 'The update could not be installed ($r).';
      return 'Installing version $latest…';
    } on BoardException catch (e) {
      return 'The update download failed: ${e.message}';
    } catch (e) {
      return 'Could not check for updates (no internet?).';
    } finally {
      app.busy.value = null;
      c.close(force: true);
      _running = false;
    }
  }
}
