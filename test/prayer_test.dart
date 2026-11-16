import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_tracker/app_state.dart';
import 'package:habit_tracker/habits/habit.dart';
import 'package:habit_tracker/logic/hijri.dart';
import 'package:habit_tracker/logic/prayer_status.dart';
import 'package:habit_tracker/logic/stats.dart';
import 'package:habit_tracker/models.dart';
import 'package:habit_tracker/services/prayer_service.dart';
import 'package:habit_tracker/services/reminders.dart';
import 'package:habit_tracker/widgets/cards/prayer_card.dart';

import 'support.dart';

/// Manual times: Fajr 05:00, Dhuhr 12:30, Asr 15:45, Maghrib 18:15, Isha 19:45.
Settings manual({String ramadanMode = 'off'}) => Settings(useManualPrayer: true, ramadanMode: ramadanMode);

void main() {
  group('hijri', () {
    test('Umm al-Qura dates', () {
      expect(hijriOf(DateTime(2025, 3, 1)), const HijriDate(1446, 9, 1));
      expect(hijriOf(DateTime(2025, 3, 30)), const HijriDate(1446, 10, 1));
      expect(hijriOf(DateTime(2025, 6, 26)), const HijriDate(1447, 1, 1));
      expect(hijriOf(DateTime(2026, 2, 17)), const HijriDate(1447, 8, 29));
      expect(hijriOf(DateTime(2026, 2, 18)), const HijriDate(1447, 9, 1));
      expect(hijriOf(DateTime(2026, 2, 18, 23, 59)).isRamadan, isTrue);
      expect('${hijriOf(DateTime(2026, 3, 20))}', '1 Shawwal 1447 AH');
    });
    test('offset matches local moon sighting', () {
      expect(hijriOf(DateTime(2026, 2, 17), offsetDays: 1), const HijriDate(1447, 9, 1));
      expect(hijriOf(DateTime(2026, 2, 18), offsetDays: -1), const HijriDate(1447, 8, 29));
    });
    test('tabular calendar and fallback outside the Umm al-Qura table', () {
      expect(tabularHijri(DateTime(622, 7, 19)), const HijriDate(1, 1, 1), reason: "16 July 622 Julian");
      expect(tabularHijri(DateTime(2026, 2, 18)), const HijriDate(1447, 9, 1));
      expect(hijriOf(DateTime(1900, 1, 1)), tabularHijri(DateTime(1900, 1, 1)));
      expect(hijriOf(DateTime(2100, 1, 1)), tabularHijri(DateTime(2100, 1, 1)));
    });
    test('days stay valid and increase over a long range', () {
      var prev = hijriOf(DateTime(2024, 1, 1));
      for (var i = 1; i < 2000; i++) {
        final h = hijriOf(DateTime(2024, 1, 1 + i));
        expect(h.day, inInclusiveRange(1, 30));
        if (h.day == 1) {
          expect(prev.day, inInclusiveRange(29, 30));
          expect(h.month, prev.month % 12 + 1);
        } else {
          expect(h.day, prev.day + 1);
        }
        prev = h;
      }
    });
  });

  group('prayer status', () {
    final day = DateTime(2026, 6, 1);
    test('window ends at the next prayer, Isha at next Fajr', () {
      final s = manual();
      expect(prayerWindowEnd(s, day, 'Fajr'), DateTime(2026, 6, 1, 12, 30));
      expect(prayerWindowEnd(s, day, 'Asr'), DateTime(2026, 6, 1, 18, 15));
      expect(prayerWindowEnd(s, day, 'Isha'), DateTime(2026, 6, 2, 5, 0));
    });
    test('Fajr ends at sunrise when times are calculated', () {
      final s = Settings(latitude: 25.2048, longitude: 55.2708, calcMethod: 'dubai');
      final pd = prayerTimesFor(s, day);
      expect(pd.sunrise, isNotNull);
      expect(prayerWindowEnd(s, day, 'Fajr'), pd.sunrise);
      expect(pd.sunrise!.isAfter(pd.times['Fajr']!) && pd.sunrise!.isBefore(pd.times['Dhuhr']!), isTrue);
    });
    test('tap marks on time, late or qada', () {
      final s = manual();
      expect(autoPrayerStatus(s, day, 'Dhuhr', DateTime(2026, 6, 1, 13, 0)), prayerOnTime);
      expect(autoPrayerStatus(s, day, 'Dhuhr', DateTime(2026, 6, 1, 15, 44)), prayerOnTime);
      expect(autoPrayerStatus(s, day, 'Dhuhr', DateTime(2026, 6, 1, 15, 45)), prayerLate);
      expect(autoPrayerStatus(s, day, 'Fajr', DateTime(2026, 6, 1, 9, 0)), prayerOnTime);
      expect(autoPrayerStatus(s, day, 'Isha', DateTime(2026, 6, 2, 0, 30)), prayerOnTime);
      expect(autoPrayerStatus(s, day, 'Isha', DateTime(2026, 6, 2, 6, 0)), prayerQada);
      expect(autoPrayerStatus(s, day, 'Asr', DateTime(2026, 6, 3, 10, 0)), prayerQada);
    });
    test('status of a logged prayer', () {
      final log = DayLog(prayers: {'Fajr', 'Asr'}, prayerStatus: {'Asr': prayerLate});
      expect(prayerStatusOf(log, 'Fajr'), prayerOnTime);
      expect(prayerStatusOf(log, 'Asr'), prayerLate);
      expect(prayerStatusOf(log, 'Isha'), isNull);
    });
    test('Friday Dhuhr is Jumu\'ah, optionally at the local time', () {
      final friday = DateTime(2026, 6, 5), thursday = DateTime(2026, 6, 4);
      expect(prayerLabel('Dhuhr', friday), "Jumu'ah");
      expect(prayerLabel('Dhuhr', thursday), 'Dhuhr');
      expect(prayerLabel('Asr', friday), 'Asr');
      final s = manual()..jumuahTime = '13:15';
      expect(prayerTimesFor(s, friday).times['Dhuhr'], DateTime(2026, 6, 5, 13, 15));
      expect(prayerTimesFor(s, thursday).times['Dhuhr'], DateTime(2026, 6, 4, 12, 30));
    });
    test('Ramadan mode: auto by Hijri month, or forced on/off', () {
      final ramadan = DateTime(2026, 2, 20), june = DateTime(2026, 6, 1);
      expect(isRamadan(manual(ramadanMode: 'auto'), ramadan), isTrue);
      expect(isRamadan(manual(ramadanMode: 'auto'), june), isFalse);
      expect(isRamadan(manual(ramadanMode: 'on'), june), isTrue);
      expect(isRamadan(manual(ramadanMode: 'off'), ramadan), isFalse);
      expect(isRamadan(manual(ramadanMode: 'auto')..hijriOffsetDays = 1, DateTime(2026, 2, 17)), isTrue);
    });
    test('optional sunnah prayers', () {
      final s = manual(ramadanMode: 'on');
      expect(optionalPrayersOn(s, DateTime(2026, 6, 1)), [sunnahTaraweeh]);
      s
        ..sunnahDuha = true
        ..sunnahWitr = true;
      expect(optionalPrayersOn(s, DateTime(2026, 6, 1)), [sunnahDuha, sunnahTaraweeh, sunnahWitr]);
      s.ramadanMode = 'off';
      expect(optionalPrayersOn(s, DateTime(2026, 6, 1)), [sunnahDuha, sunnahWitr]);
    });
    test('optional prayers are not counted in the 5-prayer streak or score', () {
      final s = manual()
        ..sunnahDuha = true
        ..sunnahWitr = true;
      final now = DateTime(2026, 6, 1, 23);
      final log = DayLog(
        prayers: {'Fajr', 'Dhuhr', 'Asr', 'Maghrib'},
        habits: {sunnahDuha.id: HabitEntry(done: true), sunnahWitr.id: HabitEntry(done: true)},
      );
      final logs = {dayKey(now): log};
      expect(prayersDone(log), isFalse);
      final score = dayScore(now, s, logs);
      expect(score.total, 6);
      expect(score.done, 4);
    });
    test('settings round-trip and defaults', () {
      final d = Settings.fromJson({});
      expect(d.ramadanMode, 'auto');
      expect(d.suhoorMinutes, 45);
      expect(d.jumuahReminderMinutes, 45);
      expect(d.jumuahReminder && d.suhoorReminder && d.taraweeh, isTrue);
      expect(d.sunnahDuha || d.sunnahWitr, isFalse);
      expect(d.jumuahTime, '');
      final s = Settings(
        ramadanMode: 'on',
        suhoorMinutes: 60,
        suhoorReminder: false,
        taraweeh: false,
        jumuahReminder: false,
        jumuahReminderMinutes: 30,
        jumuahTime: '13:15',
        sunnahDuha: true,
        sunnahWitr: true,
        hijriOffsetDays: -1,
      );
      expect(s.copy().toJson(), s.toJson());
      expect(Settings.fromJson({'ramadanMode': 'x', 'jumuahTime': 'bad', 'hijriOffsetDays': 9}).toJson(),
          containsPair('ramadanMode', 'auto'));
      expect(Settings.fromJson({'jumuahTime': 'bad', 'hijriOffsetDays': 9}).jumuahTime, '');
      expect(Settings.fromJson({'hijriOffsetDays': 9}).hijriOffsetDays, 2);
    });
  });

  group('Ramadan and Jumu\'ah reminders', () {
    List<PlannedReminder> plan(Settings s, DateTime now, [Map<String, DayLog> logs = const {}]) =>
        planReminders(s, logs, now, days: 1);

    test('suhoor wake alarm at Fajr minus suhoorMinutes in Ramadan', () {
      final now = DateTime(2026, 2, 20, 0, 0);
      final r = plan(manual(ramadanMode: 'auto'), now).where((r) => r.payload.startsWith('suhoor')).single;
      expect(r.when, DateTime(2026, 2, 20, 4, 15));
      expect(r.kind, ReminderKind.wake);
      expect(r.payload, 'suhoor|2026-02-20');
      expect(r.id, reminderId(now, 8));
      final s60 = manual(ramadanMode: 'on')..suhoorMinutes = 60;
      expect(plan(s60, DateTime(2026, 6, 1)).where((r) => r.payload.startsWith('suhoor')).single.when,
          DateTime(2026, 6, 1, 4, 0));
    });
    test('no suhoor alarm outside Ramadan, when off, or once up', () {
      expect(plan(manual(ramadanMode: 'auto'), DateTime(2026, 6, 1)).any((r) => r.payload.startsWith('suhoor')), isFalse);
      expect(plan(manual(ramadanMode: 'off'), DateTime(2026, 2, 20)).any((r) => r.payload.startsWith('suhoor')), isFalse);
      final off = manual(ramadanMode: 'on')..suhoorReminder = false;
      expect(plan(off, DateTime(2026, 2, 20)).any((r) => r.payload.startsWith('suhoor')), isFalse);
      final up = {'2026-02-20': DayLog(wakeAt: DateTime(2026, 2, 20, 3, 50))};
      expect(plan(manual(ramadanMode: 'on'), DateTime(2026, 2, 20), up).any((r) => r.payload.startsWith('suhoor')), isFalse);
    });
    test('Maghrib reminder says Iftar in Ramadan', () {
      final m = plan(manual(ramadanMode: 'on'), DateTime(2026, 2, 20)).firstWhere((r) => r.payload.startsWith('prayer:Maghrib'));
      expect(m.title, contains('Iftar'));
      final n = plan(manual(), DateTime(2026, 2, 20)).firstWhere((r) => r.payload.startsWith('prayer:Maghrib'));
      expect(n.title, '🕌 Time for Maghrib');
    });
    test('Friday: Jumu\'ah label and an earlier reminder', () {
      final friday = DateTime(2026, 6, 5);
      final p = plan(manual(), friday);
      final dhuhr = p.where((r) => r.payload == 'prayer:Dhuhr|2026-06-05').toList();
      expect(dhuhr.length, 2);
      expect(dhuhr.first.when, DateTime(2026, 6, 5, 11, 45));
      expect(dhuhr.first.title, "🕌 Jumu'ah in 45 min");
      expect(dhuhr.first.id, reminderId(friday, 9));
      expect(dhuhr.last.when, DateTime(2026, 6, 5, 12, 30));
      expect(dhuhr.last.title, "🕌 Time for Jumu'ah");
      expect(p.map((r) => r.id).toSet().length, p.length);

      final uae = manual()
        ..jumuahTime = '13:15'
        ..jumuahReminderMinutes = 30;
      final q = plan(uae, friday).where((r) => r.payload.startsWith('prayer:Dhuhr')).map((r) => r.when).toList();
      expect(q, [DateTime(2026, 6, 5, 12, 45), DateTime(2026, 6, 5, 13, 15)]);
    });
    test('no early Jumu\'ah reminder on other days, when off or once prayed', () {
      expect(plan(manual(), DateTime(2026, 6, 4)).where((r) => r.payload.startsWith('prayer:Dhuhr')).length, 1);
      expect(plan(manual()..jumuahReminder = false, DateTime(2026, 6, 5)).where((r) => r.payload.startsWith('prayer:Dhuhr')).length, 1);
      final prayed = {'2026-06-05': DayLog(prayers: {'Dhuhr'})};
      expect(plan(manual(), DateTime(2026, 6, 5), prayed).any((r) => r.payload.startsWith('prayer:Dhuhr')), isFalse);
    });
    test('8-day plan stays unique in Ramadan and the scheduled part covers a week', () {
      final now = DateTime(2026, 2, 18);
      final p = planReminders(manual(ramadanMode: 'on'), {}, now);
      expect(p.map((r) => r.id).toSet().length, p.length);
      final scheduled = p.take(maxPending).toList();
      expect(scheduled.length, lessThanOrEqualTo(64));
      expect(scheduled.last.when.isAfter(now.add(const Duration(days: 7))), isTrue);
    });
    test('notification done marks the prayer on time; suhoor logs nothing', () {
      final logs = <String, DayLog>{};
      final now = DateTime(2026, 6, 1, 17, 0);
      expect(applyDoneAction('prayer:Dhuhr|2026-06-01', logs, now), isTrue);
      expect(logs['2026-06-01']!.prayerStatus['Dhuhr'], prayerOnTime);
      expect(applyDoneAction('suhoor|2026-06-02', logs, now), isTrue);
      expect(logs.containsKey('2026-06-02'), isFalse);
    });
  });

  group('PrayerCard', () {
    late AppState state;
    setUp(() async {
      mockPlugins();
      state = await loadState();
      state.settings
        ..useManualPrayer = true
        ..ramadanMode = 'off';
    });

    Future<void> pump(WidgetTester tester, DateTime now) => tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ListenableBuilder(
                listenable: state,
                builder: (_, _) => PrayerCard(state: state, log: state.logFor(now), now: now),
              ),
            ),
          ),
        ));

    testWidgets('tap marks on time or late, tap again un-marks', (tester) async {
      final now = DateTime(2026, 6, 1, 16, 0);
      await pump(tester, now);
      await tester.tap(find.byKey(const ValueKey('prayer-Asr')));
      await tester.pumpAndSettle();
      expect(prayerStatusOf(state.logFor(now), 'Asr'), prayerOnTime);
      expect(find.text('On time'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('prayer-Fajr')));
      await tester.pumpAndSettle();
      expect(prayerStatusOf(state.logFor(now), 'Fajr'), prayerLate);
      expect(find.text('Late'), findsOneWidget);
      expect(find.text('2/5 · 1 on time'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('prayer-Asr')));
      await tester.pumpAndSettle();
      expect(prayerStatusOf(state.logFor(now), 'Asr'), isNull);
    });

    testWidgets('long-press chooses qada or not prayed', (tester) async {
      final now = DateTime(2026, 6, 1, 16, 0);
      await pump(tester, now);
      await tester.longPress(find.byKey(const ValueKey('prayer-Dhuhr')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Qada'));
      await tester.pumpAndSettle();
      expect(prayerStatusOf(state.logFor(now), 'Dhuhr'), prayerQada);

      await tester.longPress(find.byKey(const ValueKey('prayer-Dhuhr')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Not prayed'));
      await tester.pumpAndSettle();
      expect(state.logFor(now).prayers, isEmpty);
    });

    testWidgets('Friday shows Jumu\'ah; Ramadan shows suhoor, iftar and Taraweeh', (tester) async {
      final friday = DateTime(2026, 6, 5, 10, 0);
      await pump(tester, friday);
      expect(find.text("Jumu'ah"), findsOneWidget);
      expect(find.byKey(const ValueKey('ramadan-line')), findsNothing);
      expect(find.text('Taraweeh'), findsNothing);

      final ramadan = DateTime(2026, 2, 20, 10, 0);
      state.settings.ramadanMode = 'auto';
      await pump(tester, ramadan);
      expect(find.textContaining('Ramadan 3'), findsOneWidget);
      expect(find.textContaining('Iftar 6:15'), findsOneWidget);
      expect(find.text('Iftar'), findsOneWidget);
      expect(find.text('Taraweeh'), findsOneWidget);
    });

    testWidgets('optional Duha and Witr are logged as unscored entries', (tester) async {
      final now = DateTime(2026, 6, 1, 9, 0);
      state.settings
        ..sunnahDuha = true
        ..sunnahWitr = true;
      await pump(tester, now);
      expect(find.text('Duha'), findsOneWidget);
      expect(find.text('Witr'), findsOneWidget);
      await tester.tap(find.text('Duha'));
      await tester.pumpAndSettle();
      expect(state.habitEntry(now, sunnahDuha.id).done, isTrue);
      expect(state.logFor(now).prayers, isEmpty);
      expect(dayScore(now, state.settings, state.logs).done, 0);
    });
  });
}
