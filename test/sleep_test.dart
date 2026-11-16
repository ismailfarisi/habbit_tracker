import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_tracker/logic/sleep.dart';
import 'package:habit_tracker/logic/stats.dart';
import 'package:habit_tracker/models.dart';
import 'package:habit_tracker/services/reminders.dart';

void main() {
  group('bedtime maths', () {
    test('bedtime = next wake - sleepHours, wind-down = bedtime - windDownMinutes', () {
      final s = Settings(wakeTime: const TimeOfDay(hour: 5, minute: 0));
      final night = DateTime(2026, 6, 1);
      expect(bedtimeFor(s, night), DateTime(2026, 6, 1, 21, 30));
      expect(windDownFor(s, night), DateTime(2026, 6, 1, 21, 0));
    });

    test('crosses midnight and month ends', () {
      final s = Settings(wakeTime: const TimeOfDay(hour: 7, minute: 15), sleepHours: 6, windDownMinutes: 45);
      final night = DateTime(2026, 6, 30);
      expect(bedtimeFor(s, night), DateTime(2026, 7, 1, 1, 15));
      expect(windDownFor(s, night), DateTime(2026, 7, 1, 0, 30));

      final early = Settings(wakeTime: const TimeOfDay(hour: 4, minute: 0), sleepHours: 8.25, windDownMinutes: 0);
      expect(bedtimeFor(early, DateTime(2026, 12, 31)), DateTime(2026, 12, 31, 19, 45));
      expect(windDownFor(early, DateTime(2026, 12, 31)), DateTime(2026, 12, 31, 19, 45));
    });

    test('nightOf puts after-midnight times on the previous evening', () {
      expect(nightOf(DateTime(2026, 6, 2, 0, 40)), DateTime(2026, 6, 1));
      expect(nightOf(DateTime(2026, 6, 1, 22, 10)), DateTime(2026, 6, 1));
      expect(nightOf(DateTime(2026, 6, 1, 13)), DateTime(2026, 6, 1));
    });

    test("last night's sleep uses yesterday's bedtime and today's wake", () {
      final logs = {
        '2026-06-01': DayLog(bedtimeAt: DateTime(2026, 6, 1, 22, 40)),
        '2026-06-02': DayLog(wakeAt: DateTime(2026, 6, 2, 5, 10)),
      };
      expect(lastNightSleep(logs, DateTime(2026, 6, 2, 9)), const Duration(hours: 6, minutes: 30));
      expect(lastNightSleep(logs, DateTime(2026, 6, 1)), isNull);
      expect(lastNightSleep({'2026-06-02': DayLog(wakeAt: DateTime(2026, 6, 2, 5))}, DateTime(2026, 6, 2)), isNull);
      final weird = {
        '2026-06-01': DayLog(bedtimeAt: DateTime(2026, 6, 2, 6)),
        '2026-06-02': DayLog(wakeAt: DateTime(2026, 6, 2, 5)),
      };
      expect(lastNightSleep(weird, DateTime(2026, 6, 2)), isNull);
    });

    test('formatting', () {
      expect(fmtSleep(const Duration(hours: 7, minutes: 30)), '7h 30m');
      expect(fmtSleep(const Duration(hours: 8)), '8h');
      expect(fmtSleep(const Duration(minutes: 45)), '45m');
      expect(fmtSleepHours(7.5), '7.5 h');
      expect(fmtSleepHours(8), '8 h');
    });
  });

  group('settings', () {
    test('wake challenge and sleep fields round-trip with defaults and clamping', () {
      final d = Settings();
      expect(d.wakeChallenge, WakeChallenge.off);
      expect(d.sleepHours, 7.5);
      expect(d.windDownMinutes, 30);
      expect(d.bedtimeReminder, isTrue);

      final s = Settings(wakeChallenge: WakeChallenge.readAloud, sleepHours: 8.25, windDownMinutes: 45, bedtimeReminder: false);
      final r = Settings.fromJson(s.toJson());
      expect(r.wakeChallenge, WakeChallenge.readAloud);
      expect(r.sleepHours, 8.25);
      expect(r.windDownMinutes, 45);
      expect(r.bedtimeReminder, isFalse);

      final old = Settings.fromJson({'wakeTime': '06:00'});
      expect(old.wakeChallenge, WakeChallenge.off);
      expect(old.sleepHours, 7.5);
      final bad = Settings.fromJson({'wakeChallenge': 'dance', 'sleepHours': 30, 'windDownMinutes': -5});
      expect(bad.wakeChallenge, WakeChallenge.off);
      expect(bad.sleepHours, 12);
      expect(bad.windDownMinutes, 0);
    });
  });

  group('bedtime reminder planning', () {
    final s = Settings(useManualPrayer: true, wakeTime: const TimeOfDay(hour: 5, minute: 0));
    List<PlannedReminder> beds(Settings s, Map<String, DayLog> logs, DateTime now, {int days = scheduleDays}) =>
        planReminders(s, logs, now, days: days).where((r) => r.kind == ReminderKind.bedtime).toList();

    test('one wind-down reminder per night at the computed time', () {
      final plan = beds(s, {}, DateTime(2026, 6, 1, 8));
      expect(plan.length, scheduleDays);
      expect(plan.first.when, DateTime(2026, 6, 1, 21, 0));
      expect(plan.first.payload, 'bed|2026-06-01');
      expect(plan.first.id, reminderId(DateTime(2026, 6, 1), bedtimeSlot));
      expect(plan.first.body, contains('21:30'));
      expect(plan[1].when, DateTime(2026, 6, 2, 21, 0));
    });

    test('ids are stable across reschedules and distinct from wake/prayer slots', () {
      final a = beds(s, {}, DateTime(2026, 6, 1, 8));
      final b = beds(s, {}, DateTime(2026, 6, 2, 8));
      int june3(List<PlannedReminder> p) => p.firstWhere((r) => r.payload == 'bed|2026-06-03').id;
      expect(june3(a), june3(b));
      final all = planReminders(s, {}, DateTime(2026, 6, 1, 0, 0));
      expect(all.map((r) => r.id).toSet().length, all.length);
      expect(all.take(maxPending).length, lessThanOrEqualTo(maxPending));
      expect(reminderId(DateTime(2026, 6, 3), bedtimeSlot), lessThan(1 << 31));
    });

    test('skipped when turned off, already in bed, or the time has passed', () {
      expect(beds(Settings(bedtimeReminder: false), {}, DateTime(2026, 6, 1, 8)), isEmpty);
      final logged = {'2026-06-01': DayLog(bedtimeAt: DateTime(2026, 6, 1, 20, 50))};
      expect(beds(s, logged, DateTime(2026, 6, 1, 8)).first.payload, 'bed|2026-06-02');
      expect(beds(s, {}, DateTime(2026, 6, 1, 21, 5)).first.payload, 'bed|2026-06-02');
    });

    test('a wind-down after midnight still belongs to its evening', () {
      final late = Settings(wakeTime: const TimeOfDay(hour: 8, minute: 0), sleepHours: 7, windDownMinutes: 0);
      final plan = beds(late, {}, DateTime(2026, 6, 1, 8), days: 2);
      expect(plan.first.when, DateTime(2026, 6, 2, 1, 0));
      expect(plan.first.payload, 'bed|2026-06-01');
    });

    test('"Going to bed" action logs bedtimeAt once on that evening', () {
      final logs = <String, DayLog>{};
      expect(applyDoneAction('bed|2026-06-01', logs, DateTime(2026, 6, 1, 22, 10)), isTrue);
      expect(logs['2026-06-01']!.bedtimeAt, DateTime(2026, 6, 1, 22, 10));
      applyDoneAction('bed|2026-06-01', logs, DateTime(2026, 6, 1, 23, 0));
      expect(logs['2026-06-01']!.bedtimeAt, DateTime(2026, 6, 1, 22, 10));
      expect(dayKey(DateTime(2026, 6, 1)), '2026-06-01');
    });
  });
}
