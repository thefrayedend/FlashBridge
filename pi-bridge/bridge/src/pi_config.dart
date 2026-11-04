// Settings that only exist on the Pi build (AI failure detection, setup page password).
// Stored next to the shared ffbridge.json in <dataDir>/pi.json so the TV app's config
// format stays untouched.
import 'dart:convert';
import 'dart:io';

class AiSettings {
  /// Master switch for failure detection.
  bool enabled;

  /// 'notify' = warn only, 'pause' = warn and pause the print when the failure is clear.
  String action;

  /// 'low' | 'medium' | 'high' (maps to Obico's "detective sensitivity" multiplier).
  String sensitivity;

  /// Seconds between checks while printing. Obico's thresholds are tuned for 10 s.
  int intervalSeconds;

  /// Printer ids that have detection switched off.
  Set<String> disabledPrinters;

  AiSettings({
    this.enabled = true,
    this.action = 'notify',
    this.sensitivity = 'medium',
    this.intervalSeconds = 10,
    Set<String>? disabledPrinters,
  }) : disabledPrinters = disabledPrinters ?? {};

  double get sensitivityFactor => switch (sensitivity) { 'low' => 0.8, 'high' => 1.2, _ => 1.0 };

  bool enabledFor(String printerId) => enabled && !disabledPrinters.contains(printerId);

  factory AiSettings.fromJson(Map<String, dynamic> j) => AiSettings(
        enabled: j['enabled'] ?? true,
        action: (j['action'] == 'pause') ? 'pause' : 'notify',
        sensitivity: const ['low', 'medium', 'high'].contains(j['sensitivity']) ? j['sensitivity'] : 'medium',
        intervalSeconds: ((j['intervalSeconds'] as num?)?.toInt() ?? 10).clamp(5, 120),
        disabledPrinters: {for (final e in (j['disabledPrinters'] as List? ?? [])) e.toString()},
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'action': action,
        'sensitivity': sensitivity,
        'intervalSeconds': intervalSeconds,
        'disabledPrinters': disabledPrinters.toList(),
      };
}

/// The optional "Custom" tab in the web page: a web address or an HTML file the user uploaded
/// (kept at <data>/custom/index.html), shown in a frame under the top bar.
class CustomTab {
  bool enabled = false;
  String name = 'Custom';
  String mode = 'url'; // 'url' | 'file'
  String url = '';

  CustomTab();

  factory CustomTab.fromJson(Map<String, dynamic> j) => CustomTab()
    ..enabled = j['enabled'] == true
    ..name = cleanName(j['name']?.toString() ?? 'Custom')
    ..mode = j['mode'] == 'file' ? 'file' : 'url'
    ..url = cleanUrl(j['url']?.toString() ?? '');

  Map<String, dynamic> toJson() => {'enabled': enabled, 'name': name, 'mode': mode, 'url': url};

  /// 1-16 printable characters; empty -> "Custom".
  static String cleanName(String n) {
    final t = n.replaceAll(RegExp(r'[\x00-\x1f<>]'), '').trim();
    final c = t.length > 16 ? t.substring(0, 16).trim() : t;
    return c.isEmpty ? 'Custom' : c;
  }

  /// Only http(s) addresses; anything else -> empty.
  static String cleanUrl(String u) {
    final t = u.trim();
    final uri = Uri.tryParse(t);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https') || uri.host.isEmpty) return '';
    return t;
  }
}

class PiConfig {
  final File _file;
  AiSettings ai = AiSettings();
  CustomTab customTab = CustomTab();

  /// Optional password for the setup page (empty = open on the local network).
  String setupPassword = '';

  /// Show the slicer (Prepare / Paint / Preview) in the web page.
  bool slicerEnabled = true;

  PiConfig(String dataDir) : _file = File('$dataDir/pi.json') {
    load();
  }

  void load() {
    try {
      final j = jsonDecode(_file.readAsStringSync()) as Map<String, dynamic>;
      ai = AiSettings.fromJson(Map<String, dynamic>.from(j['ai'] as Map? ?? {}));
      setupPassword = j['setupPassword'] ?? '';
      slicerEnabled = j['slicerEnabled'] ?? true;
      customTab = CustomTab.fromJson(Map<String, dynamic>.from(j['customTab'] as Map? ?? {}));
    } catch (_) {}
  }

  void save() {
    _file.parent.createSync(recursive: true);
    final tmp = File('${_file.path}.tmp');
    tmp.writeAsStringSync(const JsonEncoder.withIndent('  ').convert({'ai': ai.toJson(), 'setupPassword': setupPassword, 'slicerEnabled': slicerEnabled, 'customTab': customTab.toJson()}));
    tmp.renameSync(_file.path);
  }
}
