/// Scoring, streaks and consistency for everything the app tracks.
///
/// * Built-ins: [wakeResult] / [wakeDone], [prayersDone].
/// * Habits: [habitDone], [habitProgress], [habitDoneOn], [habitStreak],
///   [habitConsistency], [metricHistory].
/// * Repeating tasks count as habits: [taskCountsOn], [taskStreak],
///   [taskConsistency].
/// * Any item: [streakInfo] (rules: strict, neverMissTwice, monthly freezes)
///   and [consistencyBy] ("28 of last 30"). Only days an item is scheduled
///   are scored.
/// * The day: [dayScore] is done/total over the items scheduled that day
///   (wake + 5 prayers + scheduled habits + scheduled repeating tasks);
///   [perfectDayStreak] applies `Settings.freezesPerMonth`.
///
/// Everything here is pure: pass `today` in tests.
library;

import '../goals/goal.dart';
import '../habits/habit.dart';
import 'tracking.dart';
import '../models.dart';
import 'tasks.dart';

String dayKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

DateTime _prevDay(DateTime d) => DateTime(d.year, d.month, d.day - 1);
DateTime _nextDay(DateTime d) => DateTime(d.year, d.month, d.day + 1);

enum WakeResult { none, onTime, late }

WakeResult wakeResult(DayLog? log, Settings s) {
  final at = log?.wakeAt;
  if (at == null) return WakeResult.none;
  final deadline = DateTime(at.year, at.month, at.day, s.wakeTime.hour, s.wakeTime.minute)
      .add(Duration(minutes: s.wakeGraceMin));
  return at.isAfter(deadline) ? WakeResult.late : WakeResult.onTime;
}

bool wakeDone(DayLog? log, Settings s) => wakeResult(log, s) == WakeResult.onTime;
bool prayersDone(DayLog? log) => log != null && prayerNames.every(log.prayers.contains);

// ---------- Habits ----------

/// Whether [entry] completes [def] for its day: ticked off explicitly, or
/// the count / minutes reached the target, or (metric habits) a value was
/// recorded.
bool habitDone(HabitEntry? entry, HabitDef def) {
  if (entry == null) return false;
  if (entry.done) return true;
  final target = def.target > 0 ? def.target : 1;
  return switch (def.kind) {
    HabitKind.check => false,
    HabitKind.count => (entry.value ?? 0) >= target,
    HabitKind.duration || HabitKind.practice => (entry.minutes ?? 0) >= target,
    HabitKind.metric => entry.metrics.isNotEmpty || entry.value != null,
  };
}

/// 0..1 towards the day's target (1 when [habitDone]).
double habitProgress(HabitEntry? entry, HabitDef def) {
  if (habitDone(entry, def)) return 1;
  if (entry == null) return 0;
  final target = def.target > 0 ? def.target : 1;
  final have = switch (def.kind) {
    HabitKind.count => entry.value ?? 0,
    HabitKind.duration || HabitKind.practice => entry.minutes ?? 0,
    _ => 0,
  };
  return (have / target).clamp(0, 1).toDouble();
}

/// A logged practice counts as showing up even below the day's target.
bool practisedHabit(HabitEntry? entry, HabitDef def) => entry != null &&
    (habitDone(entry, def) || habitProgress(entry, def) > 0 ||
      entry.sessions.isNotEmpty || entry.metrics.isNotEmpty);

bool habitDoneOn(Map<String, DayLog> logs, HabitDef def, DateTime day) =>
    habitDone(logs[dayKey(day)]?.habits[def.id], def);

/// Values of [metric] for [def] over the [days] days ending at [end], oldest
/// first; null where nothing was logged. [metric] is a metrics key, or
/// `minutes` or `value`.
List<num?> metricHistory(Map<String, DayLog> logs, HabitDef def, String metric, {int days = 30, DateTime? end}) {
  final last = dateOnly(end ?? DateTime.now());
  return [
    for (var i = days - 1; i >= 0; i--)
      switch (logs[dayKey(DateTime(last.year, last.month, last.day - i))]?.habits[def.id]) {
        null => null,
        final e => switch (metric) {
            'minutes' => e.minutes,
            'value' => e.value,
            _ => e.metrics[metric],
          },
      },
  ];
}

// ---------- Streaks ----------

typedef DayTest = bool Function(DateTime day);

class StreakInfo {
  final int current;
  final int best;

  /// Freezes spent in the calendar month of `today`.
  final int freezesUsedThisMonth;
  const StreakInfo(this.current, this.best, {this.freezesUsedThisMonth = 0});

  @override
  String toString() => 'StreakInfo(current: $current, best: $best)';
}

/// Current and best streak of days for which [done] holds, walking from
/// [start] to [today].
///
/// * Days where [scheduled] is false are skipped: they neither extend nor
///   break the streak.
/// * Today never breaks the streak while it is still not done.
/// * [StreakRule.strict]: any missed scheduled day resets the streak.
/// * [StreakRule.neverMissTwice]: one missed scheduled day is forgiven (it
///   doesn't count towards the streak), two in a row reset it.
/// * [freezesPerMonth]: that many further misses per calendar month are
///   forgiven, spent only while a streak is running.
StreakInfo streakInfo({
  required DayTest done,
  DayTest? scheduled,
  required DateTime start,
  DateTime? today,
  StreakRule rule = StreakRule.strict,
  int freezesPerMonth = 0,
}) {
  final end = dateOnly(today ?? DateTime.now());
  var run = 0, best = 0, missesInARow = 0;
  final frozen = <int, int>{};
  for (var day = dateOnly(start); !day.isAfter(end); day = _nextDay(day)) {
    if (scheduled != null && !scheduled(day)) continue;
    if (done(day)) {
      run++;
      missesInARow = 0;
      if (run > best) best = run;
      continue;
    }
    if (day == end || run == 0) continue;
    final month = day.year * 12 + day.month;
    if (rule == StreakRule.neverMissTwice && missesInARow == 0) {
      missesInARow = 1;
    } else if ((frozen[month] ?? 0) < freezesPerMonth) {
      frozen[month] = (frozen[month] ?? 0) + 1;
    } else {
      run = 0;
      missesInARow = 0;
    }
  }
  return StreakInfo(run, best, freezesUsedThisMonth: frozen[end.year * 12 + end.month] ?? 0);
}

class Consistency {
  final int done;
  final int total;
  const Consistency(this.done, this.total);

  double get fraction => total == 0 ? 0 : done / total;

  /// e.g. "28/30".
  @override
  String toString() => '$done/$total';
}

/// How many of the scheduled days among the last [days] (ending today) were
/// done. Today only counts once it is done.
Consistency consistencyBy({required DayTest done, DayTest? scheduled, int days = 30, DateTime? today}) {
  final end = dateOnly(today ?? DateTime.now());
  var n = 0, total = 0;
  for (var i = days - 1; i >= 0; i--) {
    final day = DateTime(end.year, end.month, end.day - i);
    if (scheduled != null && !scheduled(day)) continue;
    final ok = done(day);
    if (day == end && !ok) continue;
    total++;
    if (ok) n++;
  }
  return Consistency(n, total);
}

/// [consistencyBy] for a predicate over the day's log, e.g.
/// `consistency(logs, prayersDone)` -> 28/30.
Consistency consistency(
  Map<String, DayLog> logs,
  bool Function(DayLog?) done, {
  int days = 30,
  DateTime? today,
  DayTest? scheduled,
}) =>
    consistencyBy(done: (d) => done(logs[dayKey(d)]), scheduled: scheduled, days: days, today: today);

DateTime _firstLogDay(Map<String, DayLog> logs, DateTime today) {
  DateTime? first;
  for (final k in logs.keys) {
    final d = DateTime.tryParse(k);
    if (d != null && (first == null || d.isBefore(first))) first = d;
  }
  final cap = DateTime(today.year - 3, today.month, today.day);
  if (first == null) return dateOnly(today);
  return first.isBefore(cap) ? cap : dateOnly(first);
}

/// Streak of a log predicate (wake, prayers…) with optional rule/freezes.
StreakInfo logStreak(
  Map<String, DayLog> logs,
  bool Function(DayLog?) done, {
  DateTime? today,
  StreakRule rule = StreakRule.strict,
  int freezesPerMonth = 0,
}) {
  final end = dateOnly(today ?? DateTime.now());
  return streakInfo(
    done: (d) => done(logs[dayKey(d)]),
    start: _firstLogDay(logs, end),
    today: end,
    rule: rule,
    freezesPerMonth: freezesPerMonth,
  );
}

/// Streak of [def] under its own [HabitDef.streakRule], over scheduled days.
StreakInfo habitStreak(Map<String, DayLog> logs, HabitDef def, {DateTime? today}) => streakInfo(
      done: (d) => habitDoneOn(logs, def, d),
      scheduled: def.isScheduledOn,
      start: def.createdAt,
      today: today,
      rule: def.streakRule,
    );

Consistency habitConsistency(Map<String, DayLog> logs, HabitDef def, {int days = 30, DateTime? today}) =>
    consistencyBy(done: (d) => habitDoneOn(logs, def, d), scheduled: def.isScheduledOn, days: days, today: today);

// ---------- Repeating tasks as habits ----------

/// Whether repeating task [t] is expected on [day] (scheduled, and the task
/// already existed). One-off tasks never count.
bool taskCountsOn(Task t, DateTime day) =>
    t.isRepeating && t.isScheduledOn(day) && !dateOnly(day).isBefore(dateOnly(t.createdAt));

StreakInfo taskStreak(Task t, {DateTime? today, StreakRule rule = StreakRule.neverMissTwice}) => streakInfo(
      done: t.isDoneOn,
      scheduled: (d) => taskCountsOn(t, d),
      start: t.createdAt,
      today: today,
      rule: rule,
    );

Consistency taskConsistency(Task t, {int days = 30, DateTime? today}) =>
    consistencyBy(done: t.isDoneOn, scheduled: (d) => taskCountsOn(t, d), days: days, today: today);

// ---------- Daily score ----------

class DayScore {
  final int done;
  final int total;
  const DayScore(this.done, this.total);

  double get fraction => total == 0 ? 0 : done / total;
  bool get perfect => total > 0 && done == total;

  @override
  String toString() => '$done/$total';
}

/// Done / total over the items scheduled on [day]: wake (on time), the five
/// prayers, every non-archived habit scheduled that day and every repeating
/// task scheduled that day.
DayScore dayScore(
  DateTime day,
  Settings s,
  Map<String, DayLog> logs, {
  List<HabitDef> habits = const [],
  List<Task> tasks = const [],
  List<Goal> goals = const [],
}) {
  final log = logs[dayKey(day)];
  final wake = s.tracksOn('wake', day);
  final prayers = s.tracksOn('prayers', day);
  var done = wake && wakeDone(log, s) ? 1 : 0;
  if (prayers) done += prayerNames.where((p) => log?.prayers.contains(p) ?? false).length;
  var total = (wake ? 1 : 0) + (prayers ? prayerNames.length : 0);
  for (final h in habits) {
    if (h.archived || !tracksItem(s, goals, h.id) || !h.isScheduledOn(day)) continue;
    total++;
    if (habitDone(log?.habits[h.id], h)) done++;
  }
  for (final t in tasks) {
    if (!tracksItem(s, goals, t.id, task: true) || !taskCountsOn(t, day)) continue;
    total++;
    if (t.isDoneOn(day)) done++;
  }
  return DayScore(done, total);
}

/// Streak of perfect days ([DayScore.perfect]) with `Settings.freezesPerMonth`
/// forgiven misses per calendar month.
StreakInfo perfectDayStreak(
  Settings s,
  Map<String, DayLog> logs, {
  List<HabitDef> habits = const [],
  List<Task> tasks = const [],
  List<Goal> goals = const [],
  DateTime? today,
}) {
  final end = dateOnly(today ?? DateTime.now());
  return streakInfo(
    done: (d) => dayScore(d, s, logs, habits: habits, tasks: tasks, goals: goals).perfect,
    scheduled: (d) => dayScore(d, s, logs, habits: habits, tasks: tasks, goals: goals).total > 0,
    start: _firstLogDay(logs, end),
    today: end,
    freezesPerMonth: s.freezesPerMonth,
  );
}

// ---------- Simple streak helpers (strict, no schedule) ----------

/// Consecutive days ending today (or yesterday, if today isn't done yet)
/// for which [done] holds.
int streak(Map<String, DayLog> logs, bool Function(DayLog?) done, {DateTime? today}) {
  var day = dateOnly(today ?? DateTime.now());
  if (!done(logs[dayKey(day)])) day = _prevDay(day);
  var n = 0;
  while (done(logs[dayKey(day)])) {
    n++;
    day = _prevDay(day);
  }
  return n;
}

/// Longest run of consecutive days for which [done] holds.
int bestStreak(Map<String, DayLog> logs, bool Function(DayLog?) done) {
  final days = logs.keys.where((k) => done(logs[k])).map(DateTime.parse).toList()..sort();
  var best = 0, cur = 0;
  DateTime? prev;
  for (final d in days) {
    cur = (prev != null && DateTime(prev.year, prev.month, prev.day + 1) == d) ? cur + 1 : 1;
    if (cur > best) best = cur;
    prev = d;
  }
  return best;
}
