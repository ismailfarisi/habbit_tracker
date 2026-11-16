/// Local weekly review for the Progress screen: no AI needed.
///
/// [weeklyReview] scores every tracked item (wake, each prayer, active
/// habits, repeating tasks) over the last [WeeklyReview.days] days, picks the
/// best and worst item, looks for a weekday miss pattern over a longer window
/// ("Fajr missed mostly on Saturdays") and suggests one adjustment.
/// [WeeklyReview.toPrompt] turns it into context for the AI coach.
///
/// Like `consistencyBy` in stats.dart, today only counts once it is done,
/// built-ins only count from the first logged day, habits from their
/// creation and only on scheduled days.
library;

import 'package:intl/intl.dart';

import '../habits/habit.dart';
import '../models.dart';
import 'stats.dart';
import 'tasks.dart';

enum ReviewItemKind { wake, prayer, habit, task }

/// One tracked item scored over a window of days.
class ReviewItem {
  final String id;
  final String label;
  final ReviewItemKind kind;
  final int done;
  final int total;

  /// Prayers only: days prayed late or as qada.
  final int late;

  /// Missed scheduled days per weekday (1 = Monday .. 7 = Sunday).
  final Map<int, int> missesByWeekday;

  const ReviewItem({
    required this.id,
    required this.label,
    required this.kind,
    required this.done,
    required this.total,
    this.late = 0,
    this.missesByWeekday = const {},
  });

  int get missed => total - done;
  double get fraction => total == 0 ? 0 : done / total;

  @override
  String toString() => '$label $done/$total';
}

/// "[item] is missed mostly on [weekday]": [count] of its [missed] misses.
class MissPattern {
  final ReviewItem item;
  final int weekday;
  final int count;
  final int missed;
  final int weeks;
  const MissPattern(this.item, this.weekday, this.count, this.missed, this.weeks);

  String get weekdayName => weekdayNames[weekday - 1];

  String describe() => '${item.label} missed mostly on ${weekdayName}s ($count of $missed misses in $weeks weeks)';
}

const weekdayNames = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

class WeeklyReview {
  /// First and last day of the review window.
  final DateTime start;
  final DateTime end;
  final int days;
  final List<ReviewItem> items;
  final DayScore week;
  final DayScore previousWeek;
  final ReviewItem? best;

  /// Null when nothing was missed.
  final ReviewItem? worst;
  final MissPattern? pattern;
  final String? suggestion;

  const WeeklyReview({
    required this.start,
    required this.end,
    required this.days,
    required this.items,
    required this.week,
    required this.previousWeek,
    this.best,
    this.worst,
    this.pattern,
    this.suggestion,
  });

  bool get isEmpty => week.total == 0;

  /// The review as context for the AI coach.
  String toPrompt() {
    final f = DateFormat('EEE d MMM');
    final b = StringBuffer()
      ..writeln('My weekly review (${f.format(start)} to ${f.format(end)}):')
      ..writeln('- Overall: ${week.done} of ${week.total} scheduled items done (${_pct(week.fraction)})'
          '${previousWeek.total == 0 ? '' : ', previous week ${_pct(previousWeek.fraction)}'}.');
    for (final i in items.where((i) => i.total > 0)) {
      b.writeln('- ${i.label}: ${i.done}/${i.total}${i.late > 0 ? ' (${i.late} late or qada)' : ''}');
    }
    if (best != null) b.writeln('Best: ${best!.label}.');
    if (worst != null) b.writeln('Needs work: ${worst!.label}.');
    if (pattern != null) b.writeln('Pattern: ${pattern!.describe()}.');
    if (suggestion != null) b.writeln('Suggested adjustment: $suggestion');
    b
      ..writeln()
      ..writeln('Please review my week: what went well, what to fix first, and one or two concrete changes '
          '(you may update my habits or tasks with your tools if I agree).');
    return b.toString();
  }
}

/// System prompt for the coach when it is asked about a weekly review.
const weeklyReviewCoachPrompt = '''
You are a warm, practical discipline coach for a Muslim user who tracks waking
up early, the five daily prayers, their own habits and repeating tasks.
When given a weekly review, be concise: name what went well, the one thing to
fix first and why it probably slipped, and one or two small, concrete changes
(times, smaller targets, schedule tweaks). Offer to apply a change with your
tools, and only change habits or tasks after the user agrees.
''';

String _pct(double f) => '${(f * 100).round()}%';

/// Builds the review of the [days] days ending [today], with weekday
/// patterns looked for over the last [patternDays] days.
WeeklyReview weeklyReview({
  required Settings settings,
  required Map<String, DayLog> logs,
  List<HabitDef> habits = const [],
  List<Task> tasks = const [],
  DateTime? today,
  int days = 7,
  int patternDays = 28,
}) {
  final end = dateOnly(today ?? DateTime.now());
  final first = firstLogDay(logs);
  bool builtInOn(DateTime d) => first != null && !d.isBefore(first);
  final active = habits.where((h) => !h.archived).toList();
  final routines = tasks.where((t) => t.isRepeating).toList();

  final trackers = <_Tracker>[
    _Tracker('wake', 'Wake on time', ReviewItemKind.wake, builtInOn, (d) => wakeDone(logs[dayKey(d)], settings)),
    for (final p in prayerNames)
      _Tracker(
        'prayer:$p',
        p,
        ReviewItemKind.prayer,
        builtInOn,
        (d) => logs[dayKey(d)]?.prayers.contains(p) ?? false,
        late: (d) => switch (logs[dayKey(d)]?.prayerStatus[p]) { prayerLate || prayerQada => true, _ => false },
      ),
    for (final h in active)
      _Tracker('habit:${h.id}', h.title, ReviewItemKind.habit, h.isScheduledOn, (d) => habitDoneOn(logs, h, d)),
    for (final t in routines)
      _Tracker('task:${t.id}', t.title, ReviewItemKind.task, (d) => taskCountsOn(t, d), t.isDoneOn),
  ];

  final items = [for (final t in trackers) t.score(end, days)];
  final previous = [for (final t in trackers) t.score(DateTime(end.year, end.month, end.day - days), days, endIsToday: false)];
  DayScore sum(List<ReviewItem> xs) =>
      DayScore(xs.fold(0, (a, i) => a + i.done), xs.fold(0, (a, i) => a + i.total));

  final scored = items.where((i) => i.total > 0).toList();
  ReviewItem? best, worst;
  if (scored.isNotEmpty) {
    final byRate = [...scored]..sort((a, b) {
        final c = b.fraction.compareTo(a.fraction);
        return c != 0 ? c : b.total.compareTo(a.total);
      });
    best = byRate.first.done > 0 ? byRate.first : null;
    final missedAny = [...scored.where((i) => i.missed > 0)]..sort((a, b) {
        final c = a.fraction.compareTo(b.fraction);
        return c != 0 ? c : b.missed.compareTo(a.missed);
      });
    worst = missedAny.isEmpty ? null : missedAny.first;
    if (worst != null && identical(worst, best)) best = null;
  }

  final pattern = _findPattern(trackers, end, patternDays);
  return WeeklyReview(
    start: DateTime(end.year, end.month, end.day - days + 1),
    end: end,
    days: days,
    items: items,
    week: sum(items),
    previousWeek: sum(previous),
    best: best,
    worst: worst,
    pattern: pattern,
    suggestion: _suggest(items, best, worst, pattern, active, settings),
  );
}

class _Tracker {
  final String id;
  final String label;
  final ReviewItemKind kind;
  final DayTest scheduled;
  final DayTest done;
  final DayTest? late;
  _Tracker(this.id, this.label, this.kind, this.scheduled, this.done, {this.late});

  ReviewItem score(DateTime end, int days, {bool endIsToday = true}) {
    var n = 0, total = 0, lateDays = 0;
    final misses = <int, int>{};
    for (var i = days - 1; i >= 0; i--) {
      final day = DateTime(end.year, end.month, end.day - i);
      if (!scheduled(day)) continue;
      final ok = done(day);
      if (endIsToday && i == 0 && !ok) continue;
      total++;
      if (ok) {
        n++;
        if (late?.call(day) ?? false) lateDays++;
      } else {
        misses[day.weekday] = (misses[day.weekday] ?? 0) + 1;
      }
    }
    return ReviewItem(
      id: id,
      label: label,
      kind: kind,
      done: n,
      total: total,
      late: lateDays,
      missesByWeekday: misses,
    );
  }
}

/// The earliest day with a log, or null. Built-in items (wake, prayers)
/// are only scored from this day on.
DateTime? firstLogDay(Map<String, DayLog> logs) {
  DateTime? first;
  for (final k in logs.keys) {
    final d = DateTime.tryParse(k);
    if (d != null && (first == null || d.isBefore(first))) first = d;
  }
  return first == null ? null : dateOnly(first);
}

/// The item and weekday with the most misses, when that weekday holds at
/// least 2 misses and at least half of the item's misses.
MissPattern? _findPattern(List<_Tracker> trackers, DateTime end, int days) {
  MissPattern? found;
  for (final t in trackers) {
    final item = t.score(end, days);
    if (item.missed < 2) continue;
    for (final e in item.missesByWeekday.entries) {
      if (e.value < 2 || e.value * 2 < item.missed) continue;
      final share = e.value / item.missed;
      final better = found == null ||
          e.value > found.count ||
          (e.value == found.count && share > found.count / found.missed);
      if (better) found = MissPattern(item, e.key, e.value, item.missed, (days / 7).ceil());
    }
  }
  return found;
}

String? _suggest(
  List<ReviewItem> items,
  ReviewItem? best,
  ReviewItem? worst,
  MissPattern? pattern,
  List<HabitDef> habits,
  Settings settings,
) {
  if (pattern != null) {
    final day = pattern.weekdayName;
    final eve = weekdayNames[(pattern.weekday + 5) % 7];
    return switch (pattern.item.kind) {
      ReviewItemKind.wake => 'Wake-up slips on ${day}s: set an earlier bedtime on $eve nights.',
      ReviewItemKind.prayer when pattern.item.label == 'Fajr' =>
        'Fajr slips on ${day}s: sleep earlier on $eve nights and keep a second alarm for Fajr.',
      ReviewItemKind.prayer => 'Add a reminder for ${pattern.item.label} on ${day}s, when it slips most.',
      ReviewItemKind.habit || ReviewItemKind.task =>
        'Move "${pattern.item.label}" to another time on ${day}s, or drop it from that day\'s schedule.',
    };
  }
  if (worst != null && worst.fraction < 0.5) {
    final habit = worst.kind == ReviewItemKind.habit
        ? habits.where((h) => 'habit:${h.id}' == worst.id).firstOrNull
        : null;
    if (habit != null && habit.target > 1 && habit.kind != HabitKind.check && habit.kind != HabitKind.metric) {
      final smaller = (habit.target / 2).ceil();
      final unit = habit.kind == HabitKind.count ? habit.unit : 'min';
      return 'Make "${habit.title}" easier for a week: target $smaller $unit instead of ${_num(habit.target)}, then build back up.'
          .replaceAll('  ', ' ');
    }
    return switch (worst.kind) {
      ReviewItemKind.wake => 'Wake on time was ${worst.done}/${worst.total}: move your bedtime 30 minutes earlier.',
      ReviewItemKind.prayer => 'Focus on ${worst.label} this week: add a reminder at its start time.',
      _ => 'Tie "${worst.label}" to something you already do every day, like right after a prayer.',
    };
  }
  final late = items.where((i) => i.kind == ReviewItemKind.prayer && i.late >= 2).toList()
    ..sort((a, b) => b.late.compareTo(a.late));
  if (late.isNotEmpty) {
    return '${late.first.label} was late ${late.first.late} times: pray it as soon as the time starts.';
  }
  if (worst != null) return 'Good week. Keep an eye on ${worst.label}: it was your lowest at ${worst.done}/${worst.total}.';
  if (best != null && best.total > 0) return 'Perfect week. Consider raising one habit\'s target a little.';
  return null;
}

String _num(num n) => n == n.roundToDouble() ? n.round().toString() : n.toString();
