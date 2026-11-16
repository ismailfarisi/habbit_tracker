/// Sleep goal maths: bedtime and wind-down time from the wake goal, and how
/// long the user slept last night.
///
/// A bedtime is stored in the [DayLog] of the evening it starts (the night of
/// day D is logged on D, even when the user goes to bed after midnight), so
/// last night's sleep for D is `logs[D].wakeAt - logs[D - 1].bedtimeAt`.
library;

import '../models.dart';
import 'stats.dart';

/// The wake-up goal on [day].
DateTime wakeGoalOn(Settings s, DateTime day) => DateTime(day.year, day.month, day.day, s.wakeTime.hour, s.wakeTime.minute);

Duration sleepGoal(Settings s) => Duration(minutes: (s.sleepHours * 60).round());

/// When to be in bed on the night of [night] to wake up rested at the next
/// day's wake goal: next wake time - sleepHours.
DateTime bedtimeFor(Settings s, DateTime night) =>
    wakeGoalOn(s, DateTime(night.year, night.month, night.day + 1)).subtract(sleepGoal(s));

/// When to start winding down on the night of [night]: bedtime - windDownMinutes.
DateTime windDownFor(Settings s, DateTime night) => bedtimeFor(s, night).subtract(Duration(minutes: s.windDownMinutes));

/// The evening [at] belongs to: times before noon count as the previous night.
DateTime nightOf(DateTime at) => at.hour < 12 ? DateTime(at.year, at.month, at.day - 1) : DateTime(at.year, at.month, at.day);

/// How long the user slept before waking on [day], or null if the bedtime
/// the night before or the wake time on [day] is missing or implausible.
Duration? lastNightSleep(Map<String, DayLog> logs, DateTime day) {
  final wake = logs[dayKey(day)]?.wakeAt;
  final bed = logs[dayKey(DateTime(day.year, day.month, day.day - 1))]?.bedtimeAt;
  if (wake == null || bed == null) return null;
  final d = wake.difference(bed);
  if (d <= Duration.zero || d > const Duration(hours: 20)) return null;
  return d;
}

/// "7h 30m", "45m".
String fmtSleep(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60;
  if (h == 0) return '${m}m';
  return m == 0 ? '${h}h' : '${h}h ${m}m';
}

/// "7.5 h", "8 h".
String fmtSleepHours(double h) => '${h == h.roundToDouble() ? h.toInt() : h} h';

/// Whether [now] is in the evening window (from an hour before wind-down
/// until 6 hours after bedtime) of a night with no bedtime logged yet.
bool bedtimeCheckInDue(Settings s, Map<String, DayLog> logs, DateTime now) {
  final night = nightOf(now);
  if (logs[dayKey(night)]?.bedtimeAt != null) return false;
  return isBedtimeWindow(s, now);
}

bool isBedtimeWindow(Settings s, DateTime now) {
  final night = nightOf(now);
  return now.isAfter(windDownFor(s, night).subtract(const Duration(hours: 1))) &&
      now.isBefore(bedtimeFor(s, night).add(const Duration(hours: 6)));
}
