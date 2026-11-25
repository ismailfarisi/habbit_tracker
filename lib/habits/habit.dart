/// Generic habit model shared by the whole app.
///
/// * [HabitDef] describes one habit (built from a template or by the AI coach)
///   and carries the A2UI surface ([HabitDef.uiSurface]) used to log it.
/// * [HabitEntry] is what was logged for one habit on one day. It is stored in
///   `DayLog.habits[habitId]` and is also the A2UI data model of the habit's
///   surface (see [HabitEntry.toJson] for the paths: `/done`, `/value`,
///   `/minutes`, `/metrics/<key>`, `/notes`, `/sessions`, plus any extra
///   top-level keys kept in [HabitEntry.data]).
///
/// Read and write through `AppState.habits`, `AppState.upsertHabit`,
/// `AppState.archiveHabit` and `AppState.logHabit`; completion and streak
/// rules live in `lib/logic/stats.dart`.
library;

import 'dart:convert';

import '../models.dart';

enum HabitKind { check, count, duration, metric, practice }

enum StreakRule { strict, neverMissTwice }

T _enum<T extends Enum>(List<T> values, Object? name, T fallback) =>
    values.firstWhere((v) => v.name == name, orElse: () => fallback);

Map<String, num> _numMap(Object? raw) => {
      if (raw is Map)
        for (final e in raw.entries)
          if (e.value is num) e.key.toString(): e.value as num,
    };

/// A number the habit records (per day and per session), e.g. words/min.
class MetricField {
  final String key;
  final String label;
  final String unit;

  /// 'up' when a higher value is better, 'down' when lower is better.
  final String better;

  const MetricField({required this.key, required this.label, this.unit = '', this.better = 'up'});

  Map<String, dynamic> toJson() => {'key': key, 'label': label, 'unit': unit, 'better': better};

  factory MetricField.fromJson(Map<String, dynamic> j) => MetricField(
        key: j['key']?.toString() ?? '',
        label: j['label']?.toString() ?? j['key']?.toString() ?? '',
        unit: j['unit']?.toString() ?? '',
        better: j['better'] == 'down' ? 'down' : 'up',
      );
}

/// One practice session inside a day.
class HabitSession {
  final DateTime at;
  final int durationSec;
  final Map<String, num> metrics;
  final String? transcript;
  final String? aiFeedback;

  HabitSession({
    required this.at,
    this.durationSec = 0,
    Map<String, num>? metrics,
    this.transcript,
    this.aiFeedback,
  }) : metrics = metrics ?? {};

  Map<String, dynamic> toJson() => {
        'at': at.toIso8601String(),
        'durationSec': durationSec,
        'metrics': metrics,
        if (transcript != null) 'transcript': transcript,
        if (aiFeedback != null) 'aiFeedback': aiFeedback,
      };

  factory HabitSession.fromJson(Map<String, dynamic> j) => HabitSession(
        at: DateTime.tryParse(j['at']?.toString() ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
        durationSec: (j['durationSec'] as num?)?.toInt() ?? 0,
        metrics: _numMap(j['metrics']),
        transcript: j['transcript'] as String?,
        aiFeedback: j['aiFeedback'] as String?,
      );
}

/// What was logged for one habit on one day.
class HabitEntry {
  static const _known = {'done', 'value', 'minutes', 'metrics', 'notes', 'sessions'};

  /// Explicitly ticked off. Count/duration habits are also done once they
  /// reach their target (see `habitDone` in stats.dart).
  bool done;
  num? value;
  int? minutes;
  Map<String, num> metrics;
  String notes;
  List<HabitSession> sessions;

  /// Other top-level data-model keys a custom surface bound its inputs to.
  Map<String, dynamic> data;

  HabitEntry({
    this.done = false,
    this.value,
    this.minutes,
    Map<String, num>? metrics,
    this.notes = '',
    List<HabitSession>? sessions,
    Map<String, dynamic>? data,
  })  : metrics = metrics ?? {},
        sessions = sessions ?? [],
        data = data ?? {};

  bool get isEmpty =>
      !done &&
      (value == null || value == 0) &&
      (minutes == null || minutes == 0) &&
      metrics.isEmpty &&
      notes.isEmpty &&
      sessions.isEmpty &&
      data.isEmpty;

  /// Also the A2UI data model of the habit's surface.
  Map<String, dynamic> toJson() => {
        ...data,
        'done': done,
        if (value != null) 'value': value,
        if (minutes != null) 'minutes': minutes,
        'metrics': metrics,
        'notes': notes,
        'sessions': sessions.map((s) => s.toJson()).toList(),
      };

  factory HabitEntry.fromJson(Map<String, dynamic> j) => HabitEntry(
        done: j['done'] == true,
        value: j['value'] is num ? j['value'] as num : null,
        minutes: (j['minutes'] is num) ? (j['minutes'] as num).round() : null,
        metrics: _numMap(j['metrics']),
        notes: j['notes']?.toString() ?? '',
        sessions: [
          if (j['sessions'] is List)
            for (final s in j['sessions'] as List)
              if (s is Map) HabitSession.fromJson(s.cast<String, dynamic>()),
        ],
        data: {
          for (final e in j.entries)
            if (!_known.contains(e.key) && e.value != null) e.key: e.value,
        },
      );

  HabitEntry copy() => HabitEntry.fromJson(toJson());
}

class HabitDef {
  final String id;

  /// Small sequential number used to derive stable notification ids.
  final int seq;
  String title;
  String emoji;
  HabitKind kind;

  /// Daily goal for count (in [unit]) and duration/practice (minutes) habits.
  num target;
  String unit;

  /// 1 = Monday .. 7 = Sunday. Empty means every day.
  List<int> weekdays;

  /// HH:mm, enables a reminder.
  String? reminder;
  StreakRule streakRule;
  final bool createdByAi;
  final DateTime createdAt;
  bool archived;

  /// A2UI v1.0 `createSurface` message (components inline), normalised and
  /// validated by `normalizeHabitSurface` in lib/agent/habit_catalog.dart.
  /// Null means the built-in fallback UI for [kind].
  Map<String, dynamic>? uiSurface;
  /// The plain tracker is a display preference; the generated surface remains available.
  bool usePlainTracker;
  List<String> screenSteps;
  Map<String, dynamic>? previousScreen;
  List<MetricField> metricFields;

  /// Id of the seed template this habit was created from, if any.
  final String? templateId;

  /// Steps, done-when and an optional daily Quran portion (goal habits).
  TaskGuide? guide;

  HabitDef({
    required this.id,
    this.seq = 0,
    required this.title,
    this.emoji = '✅',
    this.kind = HabitKind.check,
    this.target = 1,
    this.unit = '',
    List<int>? weekdays,
    this.reminder,
    this.streakRule = StreakRule.neverMissTwice,
    this.createdByAi = false,
    DateTime? createdAt,
    this.archived = false,
    this.uiSurface,
    this.usePlainTracker = false,
    this.screenSteps = const [],
    this.previousScreen,
    List<MetricField>? metricFields,
    this.templateId,
    this.guide,
  })  : weekdays = weekdays ?? [],
        metricFields = metricFields ?? [],
        createdAt = createdAt ?? DateTime.now();

  bool get isDaily => weekdays.isEmpty || weekdays.length == 7;

  /// Whether the habit is expected on [day]: its weekday matches and the
  /// habit already existed.
  bool isScheduledOn(DateTime day) {
    final d = DateTime(day.year, day.month, day.day);
    if (d.isBefore(DateTime(createdAt.year, createdAt.month, createdAt.day))) return false;
    return weekdays.isEmpty || weekdays.contains(day.weekday);
  }

  String describeSchedule() {
    const names = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
    final at = reminder == null ? '' : ' at $reminder';
    if (isDaily) return 'Every day$at';
    return 'Every ${(weekdays.toList()..sort()).map((d) => names[d - 1]).join(', ')}$at';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'seq': seq,
        'title': title,
        'emoji': emoji,
        'kind': kind.name,
        'target': target,
        'unit': unit,
        'weekdays': weekdays,
        'reminder': reminder,
        'streakRule': streakRule.name,
        'createdByAi': createdByAi,
        'createdAt': createdAt.toIso8601String(),
        'archived': archived,
        'uiSurface': uiSurface,
        if (usePlainTracker) 'usePlainTracker': true,
        if (screenSteps.isNotEmpty) 'screenSteps': screenSteps,
        if (previousScreen != null) 'previousScreen': previousScreen,
        'metricFields': metricFields.map((m) => m.toJson()).toList(),
        if (templateId != null) 'templateId': templateId,
        if (guide != null) 'guide': guide!.toJson(),
      };

  factory HabitDef.fromJson(Map<String, dynamic> j) => HabitDef(
        id: j['id'] as String,
        seq: (j['seq'] as num?)?.toInt() ?? 0,
        title: j['title']?.toString() ?? '',
        emoji: j['emoji']?.toString() ?? '✅',
        kind: _enum(HabitKind.values, j['kind'], HabitKind.check),
        target: j['target'] is num ? j['target'] as num : 1,
        unit: j['unit']?.toString() ?? '',
        weekdays: [
          if (j['weekdays'] is List)
            for (final d in j['weekdays'] as List)
              if (d is num && d >= 1 && d <= 7) d.toInt(),
        ],
        reminder: j['reminder'] as String?,
        streakRule: _enum(StreakRule.values, j['streakRule'], StreakRule.neverMissTwice),
        createdByAi: j['createdByAi'] == true,
        createdAt: DateTime.tryParse(j['createdAt']?.toString() ?? ''),
        archived: j['archived'] == true,
        uiSurface: (j['uiSurface'] as Map?)?.cast<String, dynamic>(),
        usePlainTracker: j['usePlainTracker'] == true,
        screenSteps: [if (j['screenSteps'] is List) ...(j['screenSteps'] as List).whereType<String>()],
        previousScreen: (j['previousScreen'] as Map?)?.cast<String, dynamic>(),
        metricFields: [
          if (j['metricFields'] is List)
            for (final m in j['metricFields'] as List)
              if (m is Map) MetricField.fromJson(m.cast<String, dynamic>()),
        ],
        templateId: j['templateId'] as String?,
        guide: j['guide'] is Map ? TaskGuide.fromJson((j['guide'] as Map).cast<String, dynamic>()) : null,
      );

  /// Only screen configuration is versioned. Identity, schedule and measurements
  /// stay with the habit even when a prior screen is restored.
  Map<String, dynamic> get screenVersion => {
        'target': target,
        'uiSurface': uiSurface,
        'usePlainTracker': usePlainTracker,
        'screenSteps': screenSteps,
      };

  void rememberScreen(HabitDef before) {
    final previous = jsonEncode(before.screenVersion);
    if (previous != jsonEncode(screenVersion)) previousScreen = jsonDecode(previous) as Map<String, dynamic>;
  }

  void applyScreen(Map<String, dynamic> version) {
    final restored = HabitDef.fromJson({'id': id, ...version});
    target = restored.target;
    uiSurface = restored.uiSurface;
    usePlainTracker = restored.usePlainTracker;
    screenSteps = restored.screenSteps;
  }

  HabitDef copy() => HabitDef.fromJson(toJson());
}

String newHabitId() => 'h${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

int nextHabitSeq(Iterable<HabitDef> habits) => habits.fold(0, (m, h) => h.seq > m ? h.seq : m) + 1;

/// Id of the habit that replaced the old hardcoded articulation trainer.
const articulationHabitId = 'articulation';
