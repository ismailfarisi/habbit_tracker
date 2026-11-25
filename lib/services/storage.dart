import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../agent/habit_templates.dart';
import '../habits/habit.dart';
import '../models.dart';
import '../goals/goal.dart';
import '../finance/finance.dart';

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
  static const _goalsKey = 'goals.v1';
  static const _financeKey = 'finance.v1';
  static const _threadsKey = 'chat.threads.v1';
  static const _currentThreadKey = 'chat.current.v1';
  static const _legacyChatKey = 'chat.v1';
  static const _restoreJournal = 'restore.undo.v1';
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
      final tasks = (jsonDecode(raw) as List).map((e) => Task.fromJson((e as Map).cast<String, dynamic>())).toList();
      projectGoalPauses(loadGoals(), tasks: tasks);
      return tasks;
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
      final habits = (jsonDecode(raw) as List).map((e) => HabitDef.fromJson((e as Map).cast<String, dynamic>())).toList();
      projectGoalPauses(loadGoals(), habits: habits);
      return habits;
    } catch (_) {
      return [];
    }
  }

  Future<void> saveHabits(List<HabitDef> habits) => _saveCollection(_habitsKey, habits.map((h) => h.toJson()));

  List<Goal> loadGoals() {
    try {
      return [for (final g in jsonDecode(prefs.getString(_goalsKey) ?? '[]') as List) Goal.fromJson((g as Map).cast())];
    } catch (_) {
      return [];
    }
  }

  Future<void> saveGoals(List<Goal> goals) => _saveCollection(_goalsKey, goals.map((g) => g.toJson()));

  Future<void> _saveCollection(String key, Iterable<Map<String, dynamic>> records) async {
    try {
      if (!await prefs.setString(key, jsonEncode(records.toList()))) {
        throw StateError('Could not save $key.');
      }
    } catch (_) {
      // SharedPreferences updates its memory cache before the platform write.
      await prefs.reload();
      rethrow;
    }
  }

  Finance loadFinance() {
    try {
      final raw = prefs.getString(_financeKey);
      return raw == null ? Finance() : Finance.fromJson((jsonDecode(raw) as Map).cast());
    } catch (_) {
      return Finance();
    }
  }

  bool get hasFinance => prefs.containsKey(_financeKey);

  Future<void> saveFinance(Finance f) => prefs.setString(_financeKey, jsonEncode(f.toJson()));

  Future<String> loadApiKey() async {
    try {
      return await _secure.read(key: _apiKeyKey) ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<void> saveApiKey(String key) =>
      key.isEmpty ? _secure.delete(key: _apiKeyKey) : _secure.write(key: _apiKeyKey, value: key);

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

  // Check stored values instead of forgiving model loaders: a damaged
  // local record must not be mistaken for an empty device before replacement.
  bool _empty(String key, String empty) => !prefs.containsKey(key) || prefs.get(key) == empty;

  bool get hasNoData => !prefs.containsKey(_settingsKey) && !hasFinance &&
      _empty(_logsKey, '{}') && _empty(_tasksKey, '[]') && _empty(_habitsKey, '[]') &&
      _empty(_goalsKey, '[]') && _empty(_threadsKey, '[]') && _empty(_legacyChatKey, '[]');

  Map<String, dynamic> _exportChat() {
    final raw = prefs.getString(_threadsKey);
    final legacy = prefs.getString(_legacyChatKey);
    if (raw == null && legacy != null) {
      final messages = jsonDecode(legacy) as List;
      if (messages.isNotEmpty) {
        return {
          'threads': [
            {'id': 'legacy', 'title': 'Chat', 'messages': messages},
          ],
          'current': 'legacy',
        };
      }
    }
    return {
      'threads': raw == null ? [] : jsonDecode(raw),
      'current': prefs.getString(_currentThreadKey),
    };
  }

  String exportJson({DateTime? at, bool includeChat = false}) => const JsonEncoder.withIndent('  ').convert({
    'app': 'daily-discipline',
    'version': backupVersion,
    'exportedAt': (at ?? DateTime.now()).toIso8601String(),
    'settings': prefs.containsKey(_settingsKey) ? jsonDecode(prefs.getString(_settingsKey)!) : Settings().toJson(),
    'logs': jsonDecode(prefs.getString(_logsKey) ?? '{}'),
    'tasks': jsonDecode(prefs.getString(_tasksKey) ?? '[]'),
    'habits': hasHabits ? jsonDecode(prefs.getString(_habitsKey)!) : loadHabits().map((h) => h.toJson()).toList(),
    'goals': jsonDecode(prefs.getString(_goalsKey) ?? '[]'),
    'finance': hasFinance ? jsonDecode(prefs.getString(_financeKey)!) : Finance().toJson(),
    if (includeChat) 'chat': _exportChat(),
  });

  /// Materialize the same replacement for preview and import. Serializing every
  /// domain here also forces lazy casts in nested model fields before writing.
  static ({BackupSummary summary, Map<String, String?> values}) _prepare(String raw) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw const FormatException('Not a Daily Discipline backup (the file is not JSON)');
    }
    if (decoded is! Map<String, dynamic> || decoded['app'] != 'daily-discipline') {
      throw const FormatException('Not a Daily Discipline backup');
    }
    final j = decoded;
    final version = j['version'] ?? 1;
    if (version is! int || version < 1) throw const FormatException('Invalid backup version');
    if (version > backupVersion) {
      throw const FormatException('This backup was made by a newer version of the app. Update the app first.');
    }
    String section = 'settings';
    try {
      List<Map<String, dynamic>> rows(String key) {
        section = key;
        return j.containsKey(key) ? (j[key] as List).cast<Map<String, dynamic>>() : [];
      }
      final rawSettings = j['settings'] as Map<String, dynamic>;
      final settings = Settings.fromJson(rawSettings);
      final apps = rawSettings['focusApps'] as List?;
      if (apps != null && apps.length != settings.focusApps.length) {
        throw const FormatException('Invalid focus apps');
      }
      final values = <String, String?>{_settingsKey: jsonEncode(settings.toJson())};
      section = 'logs';
      final logs = (j['logs'] as Map<String, dynamic>).map(
        (k, v) => MapEntry(k, _readBackupDay(k, v as Map<String, dynamic>)),
      );
      values[_logsKey] = jsonEncode({for (final e in logs.entries) if (!e.value.isEmpty) e.key: e.value.toJson()});
      final tasks = rows('tasks').map(Task.fromJson).toList();
      values[_tasksKey] = jsonEncode(tasks);
      final habits = j.containsKey('habits')
          ? rows('habits').map(HabitDef.fromJson).toList()
          : migrateHabits(settings, logs, existingInstall: true);
      values[_habitsKey] = jsonEncode(habits);
      final goals = rows('goals').map(Goal.fromJson).toList();
      values[_goalsKey] = jsonEncode(goals);
      section = 'finance';
      final money = j.containsKey('finance') ? j['finance'] as Map<String, dynamic> : <String, dynamic>{};
      // Additional currencies are independent ledgers. Count each in its own
      // unit and preserve their optional fields when moving between app builds.
      final ledgers = [money, ...(money['otherLedgers'] as List? ?? []).cast<Map<String, dynamic>>()];
      final ledgerLines = <String>[];
      for (final ledger in ledgers) {
        if (ledger.containsKey('zakat') && ledger['zakat'] is! Map) {
          throw const FormatException('Invalid zakat settings');
        }
        final f = Finance.fromJson(ledger);
        // Force lazy model casts now, before a single preference is changed.
        jsonEncode(f.toJson());
        final recurring = (ledger['recurring'] as List? ?? []).cast<Map<String, dynamic>>().toList();
        final categories = (ledger['customCategories'] as List? ?? []).cast<String>().toList();
        final parts = [
          _count(f.entries.length, 'entry', 'entries'),
          _count(f.budgets.length, 'budget'), _count(f.pots.length, 'savings pot'),
          _count(f.debts.length, 'debt'),
          if (recurring.isNotEmpty) _count(recurring.length, 'recurring item'),
          if (categories.isNotEmpty) _count(categories.length, 'custom category', 'custom categories'),
        ];
        ledgerLines.add('Money (${f.currency}): ${parts.join(', ')} and zakat settings.');
      }
      values[_financeKey] = jsonEncode(money);
      section = 'chat';
      int? threadCount;
      if (j.containsKey('chat')) {
        final chat = j['chat'] as Map<String, dynamic>;
        final threads = (chat['threads'] as List).cast<Map<String, dynamic>>();
        _validateThreads(threads);
        threadCount = threads.length;
        values[_threadsKey] = jsonEncode(threads);
        values[_currentThreadKey] = chat['current'] as String?;
        values[_legacyChatKey] = null;
      }
      return (values: values, summary: BackupSummary(
        version: version,
        exportedAt: DateTime.tryParse('${j['exportedAt'] ?? ''}'),
        days: logs.length, tasks: tasks.length, habits: j.containsKey('habits') ? habits.length : null,
        goals: j.containsKey('goals') ? goals.length : null,
        money: j.containsKey('finance') ? ledgerLines : null, chats: threadCount,
      ));
    } catch (_) {
      throw FormatException('The $section section of this backup is invalid');
    }
  }

  // The on-device log reader tolerates damaged subtrees for display. During
  // destructive import they must be checked rather than silently discarded.
  static DayLog _readBackupDay(String key, Map<String, dynamic> day) {
    if (DateTime.tryParse(key) == null) throw const FormatException('Invalid log day');
    for (final field in ['wakeAt', 'bedtimeAt']) {
      final at = day[field];
      if (at != null && (at is! String || DateTime.tryParse(at) == null)) {
        throw const FormatException('Invalid log time');
      }
    }
    if ((day['prayers'] as List? ?? []).any((v) => v is! String) ||
        (day['prayerStatus'] as Map? ?? {}).values.any((v) => v is! String)) {
      throw const FormatException('Invalid prayer record');
    }
    for (final entry in (day['habits'] as Map? ?? {}).values.cast<Map>()) {
      final sessions = (entry['sessions'] as List? ?? []).cast<Map>();
      for (final row in [entry, ...sessions]) {
        if ((row['metrics'] as Map? ?? {}).values.any((v) => v is! num)) {
          throw const FormatException('Invalid habit metrics');
        }
      }
      if (['value', 'minutes'].any((f) => entry[f] != null && entry[f] is! num)) {
        throw const FormatException('Invalid habit log');
      }
    }
    return DayLog.fromJson(day);
  }

  static String _count(int n, String singular, [String? plural]) =>
      '$n ${n == 1 ? singular : plural ?? '${singular}s'}';

  static void _validateThreads(List<Map<String, dynamic>> threads) {
    for (final t in threads) {
      if (t['id'] is! String || (t['title'] != null && t['title'] is! String) ||
          (t['goalId'] != null && t['goalId'] is! String) ||
          (t['updatedAt'] != null && t['updatedAt'] is! String)) {
        throw const FormatException('Invalid conversation');
      }
      for (final m in (t['messages'] as List).cast<Map>()) {
        if (m['role'] is! String || (m['content'] != null && m['content'] is! String) ||
            (m['callId'] != null && m['callId'] is! String)) {
          throw const FormatException('Invalid message');
        }
        for (final c in (m['calls'] as List? ?? []).cast<Map>()) {
          if (c['id'] is! String || c['name'] is! String || (c['args'] != null && c['args'] is! String)) {
            throw const FormatException('Invalid message');
          }
        }
      }
    }
  }

  static BackupSummary describeBackup(String raw) => _prepare(raw).summary;

  Future<void> _set(String key, String? value) async {
    final ok = value == null ? await prefs.remove(key) : await prefs.setString(key, value);
    if (!ok) throw StateError('Could not save device data');
  }

  // A single journal holds exact old strings (including absent keys), so a
  // failed write or a process stopped between writes can undo the whole import.
  Future<void> recoverInterruptedRestore() async {
    final raw = prefs.getString(_restoreJournal);
    if (raw == null) return;
    final old = (jsonDecode(raw) as Map).cast<String, String?>();
    for (final e in old.entries) {
      await _set(e.key, e.value);
    }
    await _set(_restoreJournal, null);
  }

  Future<void> importJson(
    String raw, {
    void Function()? beforeReplace,
    Future<void> Function()? beforeCommit,
  }) async {
    final values = _prepare(raw).values;
    await recoverInterruptedRestore();
    final old = {for (final key in values.keys) key: prefs.getString(key)};
    await _set(_restoreJournal, jsonEncode(old));
    try {
      beforeReplace?.call();
      for (final e in values.entries) {
        await _set(e.key, e.value);
      }
      await beforeCommit?.call();
      await _set(_restoreJournal, null);
    } catch (_) {
      // SharedPreferences changes its cache before the platform write finishes.
      // Use the local copy even if removing the journal itself failed.
      for (final e in old.entries) {
        await _set(e.key, e.value);
      }
      await _set(_restoreJournal, null);
      rethrow;
    }
  }

  Future<void> clearAll() async {
    if (!await prefs.clear()) throw StateError('Could not clear device data');
    // Record an empty habit list so saving new settings cannot trigger v1 migration.
    await saveHabits([]);
    await saveApiKey('');
    await saveSecret(openaiKeyName, '');
    await saveSecret(xaiKeyName, '');
  }
}

class BackupSummary {
  final int version;
  final DateTime? exportedAt;
  final int days, tasks;
  final int? habits, goals, chats;
  final List<String>? money;
  const BackupSummary({required this.version, this.exportedAt, required this.days, required this.tasks,
    this.habits, this.goals, this.money, this.chats});

  String describe() => [
    '$days ${days == 1 ? 'day' : 'days'} of history',
    '$tasks ${tasks == 1 ? 'task' : 'tasks'}',
    if (habits != null) '$habits ${habits == 1 ? 'habit' : 'habits'}',
  ].join(', ');

  String manifest() {
    return [
      'Settings, ${describe()}${habits == null ? ' (habits derived from older training data)' : ''}.',
      goals == null ? 'Goals omitted.' : 'Goals: $goals.',
      ...?money,
      if (money == null) 'Money omitted.',
      chats == null ? 'Chat omitted.' : 'Chat: $chats ${chats == 1 ? 'conversation' : 'conversations'}.',
      'API keys, screen-time history, diagnostics and downloaded files are excluded.',
    ].join('\n');
  }
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
