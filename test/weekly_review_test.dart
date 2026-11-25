import 'package:flutter_test/flutter_test.dart';
import 'package:habit_tracker/habits/habit.dart';
import 'package:habit_tracker/logic/stats.dart';
import 'package:habit_tracker/logic/weekly_review.dart';
import 'package:habit_tracker/models.dart';

void main() {
  final today = DateTime(2026, 3, 20); // a Friday
  DateTime ago(int n) => DateTime(2026, 3, 20 - n);
  final s = Settings();

  DateTime onTime(DateTime d) => DateTime(d.year, d.month, d.day, s.wakeTime.hour, s.wakeTime.minute);

  /// [n] perfect built-in days ending today; [skip] decides which prayers
  /// are missed on a day.
  Map<String, DayLog> days(int n, {Set<String> Function(DateTime d)? skip, Map<String, HabitEntry> Function(DateTime d)? habits}) => {
        for (var i = 0; i < n; i++)
          dayKey(ago(i)): DayLog(
            wakeAt: onTime(ago(i)),
            prayers: prayerNames.toSet().difference(skip?.call(ago(i)) ?? {}),
            habits: habits?.call(ago(i)),
          ),
      };

  WeeklyReview review(Map<String, DayLog> logs, {List<HabitDef> habits = const [], List<Task> tasks = const []}) =>
      weeklyReview(settings: s, logs: logs, habits: habits, tasks: tasks, today: today);

  test('no logs: empty review without best, worst or suggestion', () {
    final r = review({});
    expect(r.isEmpty, isTrue);
    expect(r.best, isNull);
    expect(r.worst, isNull);
    expect(r.pattern, isNull);
    expect(r.suggestion, isNull);
    expect(r.start, ago(6));
    expect(r.end, today);
  });

  test('best and worst habit, and a smaller target for a struggling count habit', () {
    final water = HabitDef(id: 'w', title: 'Drink water', kind: HabitKind.count, target: 8, unit: 'glasses', createdAt: ago(6));
    final logs = days(7, habits: (d) => {'w': HabitEntry(value: d == ago(1) || d == ago(4) ? 8 : 3)});
    final r = review(logs, habits: [water]);
    expect(r.worst!.label, 'Drink water');
    expect(r.worst!.done, 2);
    expect(r.worst!.total, 6, reason: 'today does not count until it is done');
    expect(r.best!.fraction, 1);
    expect(r.best!.kind, isNot(ReviewItemKind.habit));
    expect(r.pattern, isNull);
    expect(r.suggestion, contains('target 4 glasses instead of 8'));
    expect(r.week.total, 7 * 6 + 6);
  });

  test('a weekday miss pattern: Fajr missed mostly on Saturdays', () {
    final logs = days(28, skip: (d) => d.weekday == DateTime.saturday ? {'Fajr'} : {});
    final r = review(logs);
    expect(r.pattern, isNotNull);
    expect(r.pattern!.item.label, 'Fajr');
    expect(r.pattern!.weekday, DateTime.saturday);
    expect(r.pattern!.count, 4);
    expect(r.pattern!.describe(), 'Fajr missed mostly on Saturdays (4 of 4 misses in 4 weeks)');
    expect(r.suggestion, contains('Friday nights'));
    expect(r.worst!.label, 'Fajr');
    expect(r.worst!.done, 6);
  });

  test('scattered single misses are not a pattern', () {
    final logs = days(28, skip: (d) => {if (d == ago(2) || d == ago(10) || d == ago(18)) 'Asr'});
    expect(review(logs).pattern, isNull);
  });

  test('wake pattern suggests an earlier bedtime the night before', () {
    final logs = days(28);
    for (final e in logs.entries) {
      final d = DateTime.parse(e.key);
      if (d.weekday == DateTime.monday) e.value.wakeAt = onTime(d).add(const Duration(hours: 2));
    }
    final r = review(logs);
    expect(r.pattern!.item.kind, ReviewItemKind.wake);
    expect(r.suggestion, 'Wake-up slips on Mondays: set an earlier bedtime on Sunday nights.');
  });

  test('late prayers are counted and suggested when nothing was missed', () {
    final logs = days(7);
    for (final i in [1, 2, 3]) {
      logs[dayKey(ago(i))]!.prayerStatus['Isha'] = i == 3 ? prayerQada : prayerLate;
    }
    final r = review(logs);
    expect(r.worst, isNull);
    expect(r.items.firstWhere((i) => i.label == 'Isha').late, 3);
    expect(r.suggestion, 'Isha was late 3 times: pray it as soon as the time starts.');
  });

  test('only scheduled days count; archived habits are left out; tasks count as habits', () {
    final monday = HabitDef(id: 'm', title: 'Gym', weekdays: [DateTime.monday], createdAt: ago(30));
    final old = HabitDef(id: 'o', title: 'Old', createdAt: ago(30), archived: true);
    final read = Task(id: 't', seq: 1, title: 'Read', repeat: Repeat.daily, createdAt: ago(3), doneDates: {dayKey(ago(1))});
    final r = review(days(7), habits: [monday, old], tasks: [read]);
    final gym = r.items.firstWhere((i) => i.label == 'Gym');
    expect(gym.total, 1);
    expect(gym.missesByWeekday, {DateTime.monday: 1});
    expect(r.items.any((i) => i.label == 'Old'), isFalse);
    final task = r.items.firstWhere((i) => i.kind == ReviewItemKind.task);
    expect(task.done, 1);
    expect(task.total, 3);
  });

  test('built-ins only count from the first logged day', () {
    final r = review(days(3));
    expect(r.items.firstWhere((i) => i.kind == ReviewItemKind.wake).total, 3);
    expect(r.previousWeek.total, 0);
  });

  test('previous week is compared', () {
    final logs = days(14, skip: (d) => d.isBefore(ago(6)) ? {'Fajr', 'Dhuhr'} : {});
    final r = review(logs);
    expect(r.week.fraction, 1);
    expect(r.previousWeek.done, 7 * 4);
    expect(r.previousWeek.total, 7 * 6);
    expect(r.suggestion, contains('Perfect week'));
  });

  test('toPrompt carries the numbers for the coach', () {
    final logs = days(28, skip: (d) => d.weekday == DateTime.saturday ? {'Fajr'} : {});
    final p = review(logs).toPrompt();
    expect(p, contains('My weekly review (Sat 14 Mar to Fri 20 Mar)'));
    expect(p, contains('- Fajr: 6/7'));
    expect(p, contains('Pattern: Fajr missed mostly on Saturdays'));
    expect(p, contains('Suggested adjustment:'));
  });

  test('partial sessions count once per planned day, including a return after missing practice', () {
    final practice = HabitDef(id: 'read', title: 'Read', kind: HabitKind.duration, target: 10,
      weekdays: [1, 3, 5], createdAt: ago(4));
    final review = weeklyReview(settings: Settings(todayHidden: ['wake', 'prayers']), today: today,
      habits: [practice], logs: {
        dayKey(ago(4)): DayLog(habits: {'read': HabitEntry(minutes: 10)}),
        dayKey(ago(1)): DayLog(habits: {'read': HabitEntry(minutes: 10)}), // Thursday is off-plan.
        dayKey(today): DayLog(habits: {'read': HabitEntry(minutes: 2)}),
      });
    expect(review.practiceDays.toString(), '2/3');
    expect(review.returnedOn, today);
    expect(review.lastPractice, today);
    expect(review.items.single.id, 'habit:read');
  });

  test('firstLogDay', () {
    expect(firstLogDay({}), isNull);
    expect(firstLogDay(days(5)), ago(4));
  });
}
