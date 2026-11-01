// The Android side of the app (MainActivity.kt): settings, files other apps send here, the background
// watch service, the multicast lock, opening links in the phone's browser.
import 'dart:io';

import 'package:flutter/services.dart';

class Native {
  static const _ch = MethodChannel('flashbridge/app');

  /// Called when another app sent files or a link, or a notification was tapped (see takeIncoming).
  static void Function()? onIncoming;

  static void init() {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'incoming') onIncoming?.call();
      return null;
    });
  }

  /// Waiting items: {path, name} (a file), {url} (a shared link), {open: printer|slicer|preview}, {error}.
  static Future<List<Map<String, String>>> takeIncoming() async {
    final r = await _ch.invokeMethod<List<dynamic>>('takeIncoming') ?? const [];
    return [for (final m in r) Map<String, String>.from(m as Map)];
  }

  static Future<Map<String, dynamic>> getSettings() async {
    final r = await _ch.invokeMethod<Map<dynamic, dynamic>>('getSettings');
    return Map<String, dynamic>.from(r ?? const {});
  }

  static Future<void> setSettings({String? board, String? host, bool? watch}) async {
    await _ch.invokeMethod<bool>('setSettings', <String, dynamic>{
      if (board != null) 'board': board,
      if (host != null) 'host': host,
      if (watch != null) 'watch': watch,
    });
  }

  /// Asks for the notification permission (Android 13+); true when it is already granted.
  static Future<bool> requestNotifications() async => await _ch.invokeMethod<bool>('requestNotifications') ?? false;

  static Future<bool> openExternal(String url) async => await _ch.invokeMethod<bool>('openExternal', {'url': url}) ?? false;

  static Future<void> multicastLock(bool on) async {
    await _ch.invokeMethod<bool>('multicastLock', {'on': on});
  }

  static Future<Directory> cacheDir() async {
    final p = await _ch.invokeMethod<String>('cacheDir');
    return p == null ? Directory.systemTemp : Directory(p);
  }

  static Future<String> appVersion() async => await _ch.invokeMethod<String>('appVersion') ?? '';
}
