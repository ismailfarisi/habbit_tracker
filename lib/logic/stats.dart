import '../models.dart';

String dayKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

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
bool trainingDone(DayLog? log, Settings s) =>
    log != null && log.trainingMinutes >= s.trainingGoalMin;

/// Points for the day out of [maxDailyScore]: wake (1) + each prayer (5) + training (1).
const maxDailyScore = 7;
int dailyScore(DayLog? log, Settings s) {
  if (log == null) return 0;
  return (wakeDone(log, s) ? 1 : 0) +
      prayerNames.where(log.prayers.contains).length +
      (trainingDone(log, s) ? 1 : 0);
}

/// Consecutive days ending today (or yesterday, if today isn't done yet)
/// for which [done] holds.
int streak(Map<String, DayLog> logs, bool Function(DayLog?) done, {DateTime? today}) {
  var day = dateOnly(today ?? DateTime.now());
  if (!done(logs[dayKey(day)])) day = day.subtract(const Duration(days: 1));
  var n = 0;
  while (done(logs[dayKey(day)])) {
    n++;
    day = DateTime(day.year, day.month, day.day - 1);
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
