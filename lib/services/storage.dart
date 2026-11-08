import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';

/// Persists settings and daily logs. Safe to use from the background
/// notification-action isolate as well as the UI isolate.
class Storage {
  static const _settingsKey = 'settings.v1';
  static const _logsKey = 'logs.v1';
  static const _apiKeyKey = 'openrouter_api_key';
  static const _secure = FlutterSecureStorage();

  final SharedPreferences prefs;
  Storage._(this.prefs);

  static Future<Storage> open() async => Storage._(await SharedPreferences.getInstance());

  /// Re-read from disk (picks up writes made by the background isolate).
  Future<void> reload() => prefs.reload();

  Settings loadSettings() {
    final raw = prefs.getString(_settingsKey);
    if (raw == null) return Settings();
    try {
      return Settings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return Settings();
    }
  }

  Future<void> saveSettings(Settings s) => prefs.setString(_settingsKey, jsonEncode(s.toJson()));

  Map<String, DayLog> loadLogs() {
    final raw = prefs.getString(_logsKey);
    if (raw == null) return {};
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return m.map((k, v) => MapEntry(k, DayLog.fromJson(v as Map<String, dynamic>)));
    } catch (_) {
      return {};
    }
  }

  Future<void> saveLogs(Map<String, DayLog> logs) => prefs.setString(
        _logsKey,
        jsonEncode({
          for (final e in logs.entries)
            if (!e.value.isEmpty) e.key: e.value.toJson(),
        }),
      );

  Future<String> loadApiKey() async {
    try {
      return await _secure.read(key: _apiKeyKey) ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<void> saveApiKey(String key) => key.isEmpty
      ? _secure.delete(key: _apiKeyKey)
      : _secure.write(key: _apiKeyKey, value: key);

  String exportJson() => const JsonEncoder.withIndent('  ').convert({
        'app': 'daily-discipline',
        'version': 1,
        'settings': loadSettings().toJson(),
        'logs': jsonDecode(prefs.getString(_logsKey) ?? '{}'),
      });

  /// Restores a backup made by [exportJson]. Throws [FormatException] on bad input.
  Future<void> importJson(String raw) async {
    final j = jsonDecode(raw);
    if (j is! Map || j['app'] != 'daily-discipline') {
      throw const FormatException('Not a Daily Discipline backup');
    }
    final settings = Settings.fromJson((j['settings'] as Map).cast<String, dynamic>());
    final logs = (j['logs'] as Map).map(
      (k, v) => MapEntry(k as String, DayLog.fromJson((v as Map).cast<String, dynamic>())),
    );
    await saveSettings(settings);
    await saveLogs(logs);
  }

  Future<void> clearAll() async {
    await prefs.remove(_settingsKey);
    await prefs.remove(_logsKey);
    await saveApiKey('');
  }
}
