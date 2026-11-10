import '../logic/stats.dart';
import '../logic/tasks.dart';
import '../models.dart';
import 'prayer_service.dart';

enum ReminderKind { wake, prayer, training, task }

class PlannedReminder {
  final int id;
  final DateTime when;
  final ReminderKind kind;
  final String title;
  final String body;

  /// "wake|2026-11-08", "prayer:Fajr|2026-11-08", "train|2026-11-08",
  /// "task:ID|2026-11-08"
  final String payload;

  const PlannedReminder({
    required this.id,
    required this.when,
    required this.kind,
    required this.title,
    required this.body,
    required this.payload,
  });
}

/// How many days ahead to plan.
const scheduleDays = 8;

/// iOS keeps at most 64 pending notifications, so only the soonest
/// [maxPending] reminders are scheduled at a time.
const maxPending = 60;

/// Stable notification id for a date and slot (0 = wake, 1-5 = prayers,
/// 6 = training), so a given day's reminder keeps its id across reschedules.
int reminderId(DateTime date, int slot) {
  final dayNumber = DateTime.utc(date.year, date.month, date.day).millisecondsSinceEpoch ~/ 86400000;
  return 100 + (dayNumber % 100000) * 10 + slot;
}

/// Stable notification id for a task on a date. Kept in a separate range
/// (>= 1e9) from habit reminders and below 2^31.
int taskReminderId(Task t, DateTime date) {
  final dayNumber = DateTime.utc(date.year, date.month, date.day).millisecondsSinceEpoch ~/ 86400000;
  return 1000000000 + (dayNumber % 1000) * 100000 + t.seq % 100000;
}

/// Every reminder from [now] through the next [days] days, skipping ones
/// that are in the past or for habits already completed.
List<PlannedReminder> planReminders(
  Settings s,
  Map<String, DayLog> logs,
  DateTime now, {
  int days = scheduleDays,
  List<Task> tasks = const [],
}) {
  final out = <PlannedReminder>[];
  for (var d = 0; d < days; d++) {
    final date = DateTime(now.year, now.month, now.day + d);
    final key = dayKey(date);
    final log = logs[key];

    if (log?.wakeAt == null) {
      out.add(PlannedReminder(
        id: reminderId(date, 0),
        when: DateTime(date.year, date.month, date.day, s.wakeTime.hour, s.wakeTime.minute),
        kind: ReminderKind.wake,
        title: '☀️ Time to wake up',
        body: 'Rise and shine! Tap "I\'m up" to log it.',
        payload: 'wake|$key',
      ));
    }

    final times = prayerTimesFor(s, date).times;
    for (var i = 0; i < prayerNames.length; i++) {
      final name = prayerNames[i];
      if (log?.prayers.contains(name) ?? false) continue;
      final at = times[name]!;
      final offset = s.prayerOffsetMin;
      out.add(PlannedReminder(
        id: reminderId(date, 1 + i),
        when: at.subtract(Duration(minutes: offset)),
        kind: ReminderKind.prayer,
        title: offset > 0 ? '🕌 $name in $offset min' : '🕌 Time for $name',
        body: 'Prayer time ${_hm(at)}. Tap "Prayed" once you\'re done.',
        payload: 'prayer:$name|$key',
      ));
    }

    if (!trainingDone(log, s)) {
      out.add(PlannedReminder(
        id: reminderId(date, 6),
        when: DateTime(date.year, date.month, date.day, s.trainingTime.hour, s.trainingTime.minute),
        kind: ReminderKind.training,
        title: '🗣️ Articulation training',
        body: '${s.trainingGoalMin} minutes with your AI speech coach. Let\'s go!',
        payload: 'train|$key',
      ));
    }

    for (final t in tasks) {
      if (!t.isScheduledOn(date) || t.isDoneOn(date)) continue;
      final when = t.reminderOn(date);
      if (when == null) continue;
      out.add(PlannedReminder(
        id: taskReminderId(t, date),
        when: when,
        kind: ReminderKind.task,
        title: '📝 ${t.title}',
        body: t.notes.isEmpty ? 'Task due now. Tap "Done" when finished.' : t.notes,
        payload: 'task:${t.id}|$key',
      ));
    }
  }
  out.removeWhere((r) => !r.when.isAfter(now));
  out.sort((a, b) => a.when.compareTo(b.when));
  return out;
}

/// Applies a "Done" action for a task notification. Returns false if the
/// payload isn't a task payload or the task no longer exists.
bool applyTaskDoneAction(String payload, List<Task> tasks) {
  final parts = payload.split('|');
  if (parts.length != 2 || !parts[0].startsWith('task:')) return false;
  final id = parts[0].substring(5);
  for (final t in tasks) {
    if (t.id == id) {
      t.doneDates.add(parts[1]);
      return true;
    }
  }
  return false;
}

/// Applies a "mark done" action from a notification payload to [logs].
/// Returns false if the payload was not understood.
bool applyDoneAction(String payload, Map<String, DayLog> logs, DateTime now) {
  final parts = payload.split('|');
  if (parts.length != 2) return false;
  final what = parts[0], key = parts[1];
  final log = logs.putIfAbsent(key, DayLog.new);
  if (what == 'wake') {
    log.wakeAt ??= now;
    return true;
  }
  if (what.startsWith('prayer:')) {
    final name = what.substring(7);
    if (!prayerNames.contains(name)) return false;
    log.prayers.add(name);
    return true;
  }
  return false;
}

String _hm(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
