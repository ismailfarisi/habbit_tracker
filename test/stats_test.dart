import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_tracker/habits/habit.dart';
import 'package:habit_tracker/logic/stats.dart';
import 'package:habit_tracker/models.dart';
import 'package:habit_tracker/services/reminders.dart';

void main() {
  final today = DateTime(2026, 3, 20); // a Friday
  DateTime ago(int n) => DateTime(2026, 3, 20 - n);
  final start = ago(40);

  HabitDef habit({
    HabitKind kind = HabitKind.check,
    num target = 1,
    StreakRule rule = StreakRule.strict,
    List<int>? weekdays,
    DateTime? createdAt,
  }) =>
      HabitDef(
        id: 'h',
        title: 'H',
        kind: kind,
        target: target,
        streakRule: rule,
        weekdays: weekdays,
        createdAt: createdAt ?? start,
      );

  /// Logs with habit `h` ticked on the given days-ago.
  Map<String, DayLog> doneOn(Iterable<int> daysAgo) => {
        for (final d in daysAgo) dayKey(ago(d)): DayLog(habits: {'h': HabitEntry(done: true)}),
      };

  StreakInfo run(Iterable<int> daysAgo, {StreakRule rule = StreakRule.strict, int freezes = 0, DayTest? scheduled}) {
    final set = daysAgo.toSet();
    return streakInfo(
      done: (d) => set.contains(today.difference(d).inDays),
      scheduled: scheduled,
      start: start,
      today: today,
      rule: rule,
      freezesPerMonth: freezes,
    );
  }

  group('habitDone', () {
    test('check habits need the tick', () {
      final h = habit();
      expect(habitDone(null, h), isFalse);
      expect(habitDone(HabitEntry(value: 5, minutes: 50), h), isFalse);
      expect(habitDone(HabitEntry(done: true), h), isTrue);
    });
    test('count habits are done at the target, or when ticked', () {
      final h = habit(kind: HabitKind.count, target: 8);
      expect(habitDone(HabitEntry(value: 7), h), isFalse);
      expect(habitDone(HabitEntry(value: 8), h), isTrue);
      expect(habitDone(HabitEntry(value: 2, done: true), h), isTrue);
      expect(habitProgress(HabitEntry(value: 4), h), 0.5);
      expect(habitProgress(HabitEntry(value: 12), h), 1);
    });
    test('duration and practice habits are done at the target minutes', () {
      for (final kind in [HabitKind.duration, HabitKind.practice]) {
        final h = habit(kind: kind, target: 15);
        expect(habitDone(HabitEntry(minutes: 14), h), isFalse);
        expect(habitDone(HabitEntry(minutes: 15), h), isTrue);
        expect(habitProgress(HabitEntry(minutes: 5), h), closeTo(1 / 3, 1e-9));
      }
    });
    test('metric habits are done once a number is recorded', () {
      final h = habit(kind: HabitKind.metric);
      expect(habitDone(HabitEntry(), h), isFalse);
      expect(habitDone(HabitEntry(metrics: {'weight': 80}), h), isTrue);
    });
    test('a zero target behaves like 1', () {
      expect(habitDone(HabitEntry(value: 1), habit(kind: HabitKind.count, target: 0)), isTrue);
    });
  });

  group('strict streak', () {
    test('counts back from today', () {
      final s = run([0, 1, 2]);
      expect(s.current, 3);
      expect(s.best, 3);
    });
    test('today not done yet does not break it', () => expect(run([1, 2, 3]).current, 3));
    test('a missed day resets it', () {
      final s = run([0, 1, 3, 4, 5, 6]);
      expect(s.current, 2);
      expect(s.best, 4);
    });
    test('yesterday missed means zero', () => expect(run([2, 3, 4]).current, 0));
    test('nothing logged is zero', () {
      expect(run([]).current, 0);
      expect(run([]).best, 0);
    });
    test('crosses month boundaries', () => expect(run(List.generate(30, (i) => i)).current, 30));
  });

  group('neverMissTwice streak', () {
    const rule = StreakRule.neverMissTwice;
    test('a single missed day does not break the streak (and is not counted)', () {
      final s = run([0, 1, 3, 4, 5], rule: rule);
      expect(s.current, 5);
      expect(s.best, 5);
    });
    test('two consecutive misses break it', () {
      final s = run([0, 1, 4, 5, 6], rule: rule);
      expect(s.current, 2);
      expect(s.best, 3);
    });
    test('several single misses are all forgiven', () {
      expect(run([0, 2, 4, 6, 8], rule: rule).current, 5);
    });
    test('yesterday missed and today pending keeps the streak alive', () {
      expect(run([2, 3, 4], rule: rule).current, 3);
    });
    test('yesterday and the day before missed breaks it even with today pending', () {
      expect(run([3, 4, 5], rule: rule).current, 0);
    });
    test('doing it today after one miss continues the streak', () {
      expect(run([0, 2, 3], rule: rule).current, 3);
    });
  });

  group('schedule', () {
    bool weekdaysOnly(DateTime d) => d.weekday <= 5;
    test('unscheduled days neither extend nor break the streak', () {
      // Fri 20, Thu 19, Wed 18, Tue 17, Mon 16, (weekend 14-15 skipped), Fri 13.
      final s = run([0, 1, 2, 3, 4, 7], scheduled: weekdaysOnly);
      expect(s.current, 6);
    });
    test('done on an unscheduled day is ignored', () {
      // Saturday 14th (6 days ago) done, but only weekdays count.
      expect(run([6], scheduled: weekdaysOnly).best, 0);
    });
    test('a missed scheduled day still breaks a strict streak', () {
      // Mon 16 (4 days ago) missed.
      expect(run([0, 1, 2, 3, 7, 8], scheduled: weekdaysOnly).current, 4);
    });
    test('habitStreak uses the habit schedule, rule and creation date', () {
      final h = habit(weekdays: [1, 3, 5], rule: StreakRule.neverMissTwice, createdAt: ago(20));
      // Mon/Wed/Fri: 20(F) 18(W) 16(M) 13(F) 11(W) 9(M) -> days ago 0,2,4,7,9,11
      final logs = doneOn([0, 2, 7, 9, 11]); // Monday 16th missed once
      expect(habitStreak(logs, h, today: today).current, 5);
      final strict = habit(weekdays: [1, 3, 5], createdAt: ago(20));
      expect(habitStreak(logs, strict, today: today).current, 2);
      expect(habitStreak(doneOn([30, 31]), strict, today: today).best, 0, reason: 'before the habit existed');
    });
  });

  group('freezes', () {
    test('a freeze forgives a miss in a strict streak', () {
      final s = run([0, 1, 3, 4], freezes: 2);
      expect(s.current, 4);
      expect(s.freezesUsedThisMonth, 1);
    });
    test('two freezes cover two misses, the third miss in the month breaks it', () {
      expect(run([0, 2, 4, 5], freezes: 2).current, 4);
      // misses at 1, 3 and 5 days ago (all in March): the earliest two are
      // frozen, the miss 1 day ago is not.
      final s = run([0, 2, 4, 6, 7], freezes: 2);
      expect(s.current, 1);
      expect(s.best, 4);
      expect(s.freezesUsedThisMonth, 2);
    });
    test('freezes refill each calendar month', () {
      // today 20 Mar; 19 days ago = 1 Mar, 20 = 28 Feb, 21 = 27 Feb.
      // Miss on 27 Feb (21 ago) and on 2 Mar (18 ago), one freeze per month.
      final done = [for (var i = 0; i <= 25; i++) if (i != 21 && i != 18) i];
      final s = run(done, freezes: 1);
      expect(s.current, 24);
      expect(s.freezesUsedThisMonth, 1);
    });
    test('no freeze is spent while there is no streak to protect', () {
      final s = run([0], freezes: 2);
      expect(s.current, 1);
      expect(s.freezesUsedThisMonth, 0);
    });
    test('neverMissTwice uses its free miss first, then a freeze', () {
      // two misses in a row (1 and 2 days ago): first is free, second frozen.
      final s = run([0, 3, 4], rule: StreakRule.neverMissTwice, freezes: 1);
      expect(s.current, 3);
      expect(s.freezesUsedThisMonth, 1);
      expect(run([0, 4, 5], rule: StreakRule.neverMissTwice, freezes: 1).current, 1);
    });
  });

  group('consistency', () {
    test('counts done days among the last 30', () {
      final c = consistencyBy(done: (d) => today.difference(d).inDays >= 2, today: today);
      expect(c.done, 28);
      expect(c.total, 29, reason: 'today is not counted until it is done');
      expect(c.toString(), '28/29');
    });
    test('today counts once done', () {
      final c = consistencyBy(done: (d) => today.difference(d).inDays != 5 && today.difference(d).inDays != 9, today: today);
      expect(c.toString(), '28/30');
      expect(c.fraction, closeTo(28 / 30, 1e-9));
    });
    test('only scheduled days are scored', () {
      final h = habit(weekdays: [5], createdAt: ago(60)); // Fridays
      final logs = doneOn([0, 7, 21]);
      final c = habitConsistency(logs, h, today: today);
      expect(c.total, 5); // 20, 13, 6 Mar, 27, 20 Feb
      expect(c.done, 3);
    });
    test('days before the habit existed are not scored', () {
      final h = habit(createdAt: ago(9));
      final c = habitConsistency(doneOn([1, 2, 3]), h, today: today);
      expect(c.toString(), '3/9');
    });
    test('log predicate form', () {
      final logs = {
        for (var i = 0; i < 30; i++)
          if (i != 3 && i != 4) dayKey(ago(i)): DayLog(prayers: prayerNames.toSet()),
      };
      expect(consistency(logs, prayersDone, today: today).toString(), '28/30');
      expect(consistency(logs, prayersDone, days: 7, today: today).toString(), '5/7');
    });
  });

  group('repeating tasks as habits', () {
    Task task({Repeat repeat = Repeat.daily, List<int>? weekdays, Iterable<int> done = const []}) => Task(
          id: 't',
          seq: 1,
          title: 'Read',
          repeat: repeat,
          weekdays: weekdays,
          doneDates: {for (final d in done) dayKey(ago(d))},
          createdAt: ago(20),
        );
    test('one-off tasks never count', () {
      final t = Task(id: 'o', seq: 2, title: 'Call', date: dayKey(today), createdAt: ago(3));
      expect(taskCountsOn(t, today), isFalse);
    });
    test('a daily task has a streak and consistency', () {
      final t = task(done: [0, 1, 2, 4, 5]);
      expect(taskStreak(t, today: today).current, 5, reason: 'neverMissTwice by default');
      expect(taskStreak(t, today: today, rule: StreakRule.strict).current, 3);
      expect(taskConsistency(t, today: today).toString(), '5/21');
    });
    test('a weekly task is only scored on its weekdays, after it was created', () {
      final t = task(repeat: Repeat.weekly, weekdays: [5], done: [0, 7]);
      expect(taskCountsOn(t, ago(1)), isFalse);
      expect(taskCountsOn(t, ago(28)), isFalse, reason: 'before it existed');
      expect(taskStreak(t, today: today).current, 2);
      expect(taskConsistency(t, today: today).toString(), '2/3');
    });
  });

  group('daily score', () {
    final s = Settings(wakeTime: const TimeOfDay(hour: 5, minute: 0), wakeGraceMin: 30);
    test('wake and prayers only: out of 6', () {
      final logs = {
        dayKey(today): DayLog(wakeAt: DateTime(2026, 3, 20, 5, 10), prayers: {'Fajr', 'Dhuhr'}),
      };
      final score = dayScore(today, s, logs);
      expect(score.toString(), '3/6');
      expect(score.fraction, 0.5);
      expect(dayScore(ago(1), s, logs).toString(), '0/6');
    });
    test('a late wake does not score', () {
      final logs = {dayKey(today): DayLog(wakeAt: DateTime(2026, 3, 20, 6, 0))};
      expect(dayScore(today, s, logs).done, 0);
    });
    test('counts scheduled habits and repeating tasks, skips archived, unscheduled and one-off items', () {
      final water = HabitDef(id: 'water', title: 'Water', kind: HabitKind.count, target: 8, createdAt: start);
      final gym = HabitDef(id: 'gym', title: 'Gym', weekdays: [1], createdAt: start); // Mondays
      final old = HabitDef(id: 'old', title: 'Old', archived: true, createdAt: start);
      final read = Task(id: 'r', seq: 1, title: 'Read', repeat: Repeat.daily, createdAt: start, doneDates: {dayKey(today)});
      final call = Task(id: 'c', seq: 2, title: 'Call', date: dayKey(today), createdAt: start);
      final logs = {
        dayKey(today): DayLog(
          wakeAt: DateTime(2026, 3, 20, 5, 0),
          prayers: prayerNames.toSet(),
          habits: {'water': HabitEntry(value: 8)},
        ),
      };
      final score = dayScore(today, s, logs, habits: [water, gym, old], tasks: [read, call]);
      expect(score.toString(), '8/8');
      expect(score.perfect, isTrue);
      final monday = DateTime(2026, 3, 16);
      expect(dayScore(monday, s, logs, habits: [water, gym, old], tasks: [read, call]).total, 9);
    });
    test('perfect-day streak forgives Settings.freezesPerMonth misses', () {
      DayLog perfect(DateTime d) => DayLog(wakeAt: DateTime(d.year, d.month, d.day, 5), prayers: prayerNames.toSet());
      final logs = {
        for (var i = 0; i < 10; i++)
          if (i != 3 && i != 6) dayKey(ago(i)): perfect(ago(i)),
      };
      expect(perfectDayStreak(Settings(wakeTime: s.wakeTime, freezesPerMonth: 2), logs, today: today).current, 8);
      expect(perfectDayStreak(Settings(wakeTime: s.wakeTime, freezesPerMonth: 1), logs, today: today).current, 3,
          reason: 'the earlier miss takes the only freeze');
      expect(perfectDayStreak(Settings(wakeTime: s.wakeTime, freezesPerMonth: 0), logs, today: today).current, 3);
      expect(Settings().freezesPerMonth, 2);
    });
  });

  test('metricHistory lists a metric over the last days', () {
    final h = habit();
    final logs = {
      dayKey(ago(2)): DayLog(habits: {'h': HabitEntry(minutes: 10, metrics: {'wpm': 120})}),
      dayKey(today): DayLog(habits: {'h': HabitEntry(value: 3, metrics: {'wpm': 140})}),
    };
    expect(metricHistory(logs, h, 'wpm', days: 4, end: today), [null, 120, null, 140]);
    expect(metricHistory(logs, h, 'minutes', days: 3, end: today), [10, null, null]);
    expect(metricHistory(logs, h, 'value', days: 1, end: today), [3]);
  });

  group('habit reminders', () {
    final s = Settings(useManualPrayer: true);
    final now = DateTime(2026, 6, 1, 0, 0); // Monday
    HabitDef h({String? reminder = '09:00', List<int>? weekdays, bool archived = false}) => HabitDef(
          id: 'water',
          seq: 4,
          title: 'Water',
          emoji: '💧',
          kind: HabitKind.count,
          target: 8,
          unit: 'glasses',
          reminder: reminder,
          weekdays: weekdays,
          archived: archived,
          createdAt: DateTime(2026, 5, 1),
        );
    Iterable<PlannedReminder> habitPlan(HabitDef habit, [Map<String, DayLog> logs = const {}]) =>
        planReminders(s, logs, now, days: 3, habits: [habit]).where((r) => r.kind == ReminderKind.habit);

    test('planned at the reminder time on scheduled days, with stable unique ids', () {
      final plan = habitPlan(h()).toList();
      expect(plan.map((r) => r.when), [DateTime(2026, 6, 1, 9), DateTime(2026, 6, 2, 9), DateTime(2026, 6, 3, 9)]);
      expect(plan.first.payload, 'habit:water|2026-06-01');
      expect(plan.first.title, '💧 Water');
      expect(plan.map((r) => r.id).toSet().length, 3);
      expect(plan.first.id, habitReminderId(h(), DateTime(2026, 6, 1)));
      expect(plan.first.id, lessThan(1 << 31));
      final all = planReminders(s, {}, now, days: 3, habits: [h()]);
      expect(all.map((r) => r.id).toSet().length, all.length);
    });
    test('skipped when done, unscheduled, archived or without a time', () {
      final done = {'2026-06-01': DayLog(habits: {'water': HabitEntry(value: 8)})};
      expect(habitPlan(h(), done).map((r) => r.when.day), [2, 3]);
      expect(habitPlan(h(weekdays: [2])).map((r) => r.when.day), [2]);
      expect(habitPlan(h(archived: true)), isEmpty);
      expect(habitPlan(h(reminder: null)), isEmpty);
    });
  });
}
