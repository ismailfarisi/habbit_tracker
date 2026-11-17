import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../agent/habit_templates.dart';
import '../habits/habit.dart';
import '../models.dart';

/// Persists settings, daily logs, tasks and habits. Safe to use from the
/// background notification-action isolate as well as the UI isolate.
///
/// Keys are versioned. `logs.v1` keeps its name: [DayLog.fromJson] reads old
/// entries (including `trainingMinutes`) and new fields are additive.
/// `habits.v1` holds the habit definitions; while it is missing,
/// [loadHabits] derives them from the old data (see [migrateHabits]).
/// Backups are version 2 (with `habits`); version 1 backups still import.
class Storage {
  static const _settingsKey = 'settings.v1';
  static const _logsKey = 'logs.v1';
  static const _tasksKey = 'tasks.v1';
  static const _habitsKey = 'habits.v1';
  static const backupVersion = 2;
  static const _apiKeyKey = 'openrouter_api_key';
  static const openaiKeyName = 'openai_api_key';
  static const xaiKeyName = 'xai_api_key';
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

  List<Task> loadTasks() {
    final raw = prefs.getString(_tasksKey);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List).map((e) => Task.fromJson((e as Map).cast<String, dynamic>())).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveTasks(List<Task> tasks) =>
      prefs.setString(_tasksKey, jsonEncode(tasks.map((t) => t.toJson()).toList()));

  bool get hasHabits => prefs.containsKey(_habitsKey);

  /// Habit definitions, including archived ones.
  List<HabitDef> loadHabits() {
    final raw = prefs.getString(_habitsKey);
    if (raw == null) {
      return migrateHabits(
        loadSettings(),
        loadLogs(),
        existingInstall: prefs.containsKey(_settingsKey) || prefs.containsKey(_logsKey),
      );
    }
    try {
      return (jsonDecode(raw) as List).map((e) => HabitDef.fromJson((e as Map).cast<String, dynamic>())).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveHabits(List<HabitDef> habits) =>
      prefs.setString(_habitsKey, jsonEncode(habits.map((h) => h.toJson()).toList()));

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

  /// Another provider's API key kept in secure storage ([openaiKeyName],
  /// [xaiKeyName]); never part of backups.
  Future<String> loadSecret(String name) async {
    try {
      return await _secure.read(key: name) ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<void> saveSecret(String name, String value) =>
      value.isEmpty ? _secure.delete(key: name) : _secure.write(key: name, value: value);

  /// True when there is nothing worth backing up (fresh install or reset).
  bool get hasNoData => loadLogs().isEmpty && loadTasks().isEmpty && loadHabits().isEmpty;

  String exportJson({DateTime? at}) => const JsonEncoder.withIndent('  ').convert({
        'app': 'daily-discipline',
        'version': backupVersion,
        'exportedAt': (at ?? DateTime.now()).toIso8601String(),
        'settings': loadSettings().toJson(),
        'logs': {for (final e in loadLogs().entries) e.key: e.value.toJson()},
        'tasks': jsonDecode(prefs.getString(_tasksKey) ?? '[]'),
        'habits': loadHabits().map((h) => h.toJson()).toList(),
      });

  /// Restores a backup made by [exportJson] (version 2) or by an older
  /// build (version 1, no `habits`; they are derived from the training
  /// data). Throws [FormatException] on bad input.
  Future<void> importJson(String raw) async {
    final j = _decodeBackup(raw);
    final settings = Settings.fromJson((j['settings'] as Map).cast<String, dynamic>());
    final logs = (j['logs'] as Map).map(
      (k, v) => MapEntry(k as String, DayLog.fromJson((v as Map).cast<String, dynamic>())),
    );
    final tasks = ((j['tasks'] as List?) ?? const [])
        .map((e) => Task.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
    final rawHabits = j['habits'];
    final habits = rawHabits is List
        ? rawHabits.map((e) => HabitDef.fromJson((e as Map).cast<String, dynamic>())).toList()
        : migrateHabits(settings, logs, existingInstall: true);
    await saveSettings(settings);
    await saveLogs(logs);
    await saveTasks(tasks);
    await saveHabits(habits);
  }

  /// Checks [raw] without restoring it, for a confirmation prompt.
  /// Throws [FormatException] like [importJson].
  static BackupSummary describeBackup(String raw) {
    final j = _decodeBackup(raw);
    final logs = j['logs'];
    final tasks = j['tasks'];
    final habits = j['habits'];
    if (logs is! Map || j['settings'] is! Map) throw const FormatException('The backup is incomplete');
    return BackupSummary(
      version: (j['version'] as num?)?.toInt() ?? 1,
      exportedAt: DateTime.tryParse('${j['exportedAt'] ?? ''}'),
      days: logs.length,
      tasks: tasks is List ? tasks.length : 0,
      habits: habits is List ? habits.length : null,
    );
  }

  static Map _decodeBackup(String raw) {
    final Object? j;
    try {
      j = jsonDecode(raw.trim());
    } on FormatException {
      throw const FormatException('Not a Daily Discipline backup (the file is not JSON)');
    }
    if (j is! Map || j['app'] != 'daily-discipline') {
      throw const FormatException('Not a Daily Discipline backup');
    }
    final v = j['version'];
    if (v is num && v > backupVersion) {
      throw const FormatException('This backup was made by a newer version of the app. Update the app first.');
    }
    return j;
  }

  Future<void> clearAll() async {
    await prefs.remove(_settingsKey);
    await prefs.remove(_logsKey);
    await prefs.remove(_tasksKey);
    await saveHabits([]);
    await saveApiKey('');
    await saveSecret(openaiKeyName, '');
    await saveSecret(xaiKeyName, '');
  }
}

/// What a backup holds; [habits] is null for a version 1 backup (they are
/// derived from its training data on import).
class BackupSummary {
  final int version;
  final DateTime? exportedAt;
  final int days;
  final int tasks;
  final int? habits;
  const BackupSummary({required this.version, this.exportedAt, required this.days, required this.tasks, this.habits});

  String describe() => [
        '$days ${days == 1 ? 'day' : 'days'} of history',
        '$tasks ${tasks == 1 ? 'task' : 'tasks'}',
        if (habits != null) '$habits ${habits == 1 ? 'habit' : 'habits'}',
      ].join(', ');
}

/// Habits for data written before habits existed: an install that already
/// used the hardcoded articulation trainer gets it back as the
/// "Articulation practice" habit, with the old daily goal and reminder time.
/// A fresh install starts with no habits.
List<HabitDef> migrateHabits(Settings s, Map<String, DayLog> logs, {required bool existingInstall}) {
  final trained = logs.entries.where((e) => e.value.habits.containsKey(articulationHabitId)).map((e) => e.key).toList()
    ..sort();
  if (!existingInstall && trained.isEmpty) return [];
  final keys = logs.keys.toList()..sort();
  final first = trained.isNotEmpty ? trained.first : (keys.isNotEmpty ? keys.first : null);
  return [
    habitFromTemplate(
      articulationTemplate,
      id: articulationHabitId,
      seq: 1,
      target: s.trainingGoalMin,
      reminder: fmtHm(s.trainingTime),
      createdAt: first == null ? null : DateTime.tryParse(first),
    ),
  ];
}
