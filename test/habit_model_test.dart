import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_tracker/agent/habit_catalog.dart';
import 'package:habit_tracker/agent/habit_templates.dart';
import 'package:habit_tracker/habits/habit.dart';
import 'package:habit_tracker/logic/stats.dart';
import 'package:habit_tracker/models.dart';
import 'package:habit_tracker/services/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

const _v1Logs = {
  '2026-03-01': {
    'wakeAt': '2026-03-01T04:55:00.000',
    'prayers': ['Fajr', 'Dhuhr'],
    'trainingMinutes': 20,
  },
  '2026-03-02': {
    'prayers': ['Fajr'],
    'trainingMinutes': 5,
  },
  '2026-03-03': {'prayers': <String>[], 'trainingMinutes': 0},
};

Map<String, Object> _v1Prefs() => {
      'settings.v1': jsonEncode(Settings(trainingGoalMin: 20, trainingTime: const TimeOfDay(hour: 6, minute: 30)).toJson()),
      'logs.v1': jsonEncode(_v1Logs),
      'tasks.v1': '[]',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(mockPlugins);

  group('model', () {
    test('HabitDef round-trips through JSON', () {
      final h = HabitDef(
        id: 'h1',
        seq: 3,
        title: 'Water',
        emoji: '💧',
        kind: HabitKind.count,
        target: 8,
        unit: 'glasses',
        weekdays: [1, 3, 5],
        reminder: '09:00',
        streakRule: StreakRule.strict,
        createdByAi: true,
        createdAt: DateTime(2026, 1, 2),
        archived: true,
        uiSurface: surfaceMessage(waterTemplate.components),
        metricFields: [const MetricField(key: 'ml', label: 'Millilitres', unit: 'ml', better: 'up')],
      );
      final r = HabitDef.fromJson(jsonDecode(jsonEncode(h.toJson())) as Map<String, dynamic>);
      expect(r.toJson(), h.toJson());
      expect(r.kind, HabitKind.count);
      expect(r.streakRule, StreakRule.strict);
      expect(r.describeSchedule(), 'Every mon, wed, fri at 09:00');
    });

    test('unknown enum values and missing fields fall back to defaults', () {
      final r = HabitDef.fromJson({'id': 'x', 'kind': 'nonsense', 'streakRule': 'nope'});
      expect(r.kind, HabitKind.check);
      expect(r.streakRule, StreakRule.neverMissTwice);
      expect(r.target, 1);
      expect(r.isDaily, isTrue);
    });

    test('HabitEntry round-trips, keeps extra keys and knows when it is empty', () {
      final e = HabitEntry(
        done: true,
        value: 3,
        minutes: 12,
        metrics: {'wpm': 140},
        notes: 'ok',
        sessions: [HabitSession(at: DateTime(2026, 1, 1, 7), durationSec: 90, metrics: {'wpm': 140}, transcript: 'hi')],
        data: {'choice': 'Gym'},
      );
      final r = HabitEntry.fromJson(jsonDecode(jsonEncode(e.toJson())) as Map<String, dynamic>);
      expect(r.toJson(), e.toJson());
      expect(r.data, {'choice': 'Gym'});
      expect(r.sessions.single.transcript, 'hi');
      expect(HabitEntry().isEmpty, isTrue);
      expect(HabitEntry(value: 0).isEmpty, isTrue);
      expect(HabitEntry(minutes: 1).isEmpty, isFalse);
    });

    test('schedule respects weekdays and the creation date', () {
      final h = HabitDef(id: 'h', title: 'Gym', weekdays: [1], createdAt: DateTime(2026, 3, 4, 15));
      expect(h.isScheduledOn(DateTime(2026, 3, 9)), isTrue); // Monday
      expect(h.isScheduledOn(DateTime(2026, 3, 10)), isFalse);
      expect(h.isScheduledOn(DateTime(2026, 3, 2)), isFalse, reason: 'before it existed');
    });

    test('DayLog round-trips habits, prayer status and bedtime', () {
      final log = DayLog(
        wakeAt: DateTime(2026, 3, 1, 5),
        bedtimeAt: DateTime(2026, 3, 1, 22, 30),
        prayers: {'Fajr', 'Asr'},
        prayerStatus: {'Fajr': prayerOnTime, 'Asr': prayerQada},
        habits: {'water': HabitEntry(value: 4)},
      );
      final r = DayLog.fromJson(jsonDecode(jsonEncode(log.toJson())) as Map<String, dynamic>);
      expect(r.toJson(), log.toJson());
      expect(r.prayers, {'Fajr', 'Asr'});
      expect(r.prayerStatus['Asr'], prayerQada);
      expect(r.bedtimeAt, DateTime(2026, 3, 1, 22, 30));
      expect(r.habits['water']!.value, 4);
    });

    test('DayLog drops a status for a prayer that is not done or is unknown', () {
      final r = DayLog.fromJson({
        'prayers': ['Fajr'],
        'prayerStatus': {'Fajr': 'weird', 'Isha': 'late'},
      });
      expect(r.prayerStatus, isEmpty);
    });
  });

  group('migration', () {
    test('v1 logs load: prayers, wake and trainingMinutes become the Articulation entry', () {
      final logs = _v1Logs.map((k, v) => MapEntry(k, DayLog.fromJson(v.cast<String, dynamic>())));
      expect(logs['2026-03-01']!.wakeAt, DateTime(2026, 3, 1, 4, 55));
      expect(logs['2026-03-01']!.prayers, {'Fajr', 'Dhuhr'});
      expect(logs['2026-03-01']!.habits[articulationHabitId]!.minutes, 20);
      expect(logs['2026-03-02']!.habits[articulationHabitId]!.minutes, 5);
      expect(logs['2026-03-03']!.habits, isEmpty);
      expect(logs['2026-03-01']!.toJson().containsKey('trainingMinutes'), isFalse);
    });

    test('an existing v1 install gets the Articulation habit with its old goal and reminder', () async {
      final state = await loadState(_v1Prefs());
      final h = state.habits.single;
      expect(h.id, articulationHabitId);
      expect(h.title, 'Articulation practice');
      expect(h.kind, HabitKind.practice);
      expect(h.target, 20);
      expect(h.reminder, '06:30');
      expect(h.createdAt, DateTime(2026, 3, 1));
      expect(isValidHabitSurface(h.uiSurface), isTrue);

      expect(habitDoneOn(state.logs, h, DateTime(2026, 3, 1)), isTrue);
      expect(habitDoneOn(state.logs, h, DateTime(2026, 3, 2)), isFalse);
      expect(state.logFor(DateTime(2026, 3, 2)).habits[articulationHabitId]!.minutes, 5);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('habits.v1'), isNotNull, reason: 'the migration is saved once');
      expect(jsonDecode(prefs.getString('logs.v1')!), _v1Logs, reason: 'v1 logs stay readable until rewritten');
    });

    test('after a write, logs are stored in the new shape and still load', () async {
      final state = await loadState(_v1Prefs());
      await state.setPrayerStatus(DateTime(2026, 3, 2), 'Dhuhr', prayerLate);
      final prefs = await SharedPreferences.getInstance();
      final raw = jsonDecode(prefs.getString('logs.v1')!) as Map<String, dynamic>;
      expect((raw['2026-03-01'] as Map).containsKey('trainingMinutes'), isFalse);
      expect(((raw['2026-03-01'] as Map)['habits'] as Map)[articulationHabitId]['minutes'], 20);
      expect((raw['2026-03-02'] as Map)['prayerStatus'], {'Dhuhr': 'late'});

      final again = Storage.open();
      final logs = (await again).loadLogs();
      expect(logs['2026-03-01']!.habits[articulationHabitId]!.minutes, 20);
      expect(logs['2026-03-02']!.prayers, {'Fajr', 'Dhuhr'});
    });

    test('a fresh install starts with no habits', () async {
      final state = await loadState();
      expect(state.habits, isEmpty);
    });

    test('a deleted Articulation habit does not come back', () async {
      final state = await loadState(_v1Prefs());
      await state.deleteHabit(articulationHabitId);
      final storage = await Storage.open();
      expect(storage.loadHabits(), isEmpty);
    });
  });

  group('backup', () {
    test('export is version 2 and includes habits; it imports back', () async {
      final state = await loadState();
      final water = await state.upsertHabit(habitFromTemplate(waterTemplate));
      await state.logHabit(DateTime(2026, 4, 1), water.id, HabitEntry(value: 8));
      await state.setPrayerStatus(DateTime(2026, 4, 1), 'Fajr', prayerLate);

      final raw = state.storage.exportJson();
      final j = jsonDecode(raw) as Map<String, dynamic>;
      expect(j['version'], 2);
      expect((j['habits'] as List).single['title'], 'Drink water');
      expect(j['logs']['2026-04-01']['habits'][water.id]['value'], 8);

      final other = await loadState();
      await other.importBackup(raw);
      expect(other.habits.single.id, water.id);
      expect(other.habitEntry(DateTime(2026, 4, 1), water.id).value, 8);
      expect(other.logFor(DateTime(2026, 4, 1)).prayerStatus['Fajr'], prayerLate);
    });

    test('a version 1 backup imports and brings its training data with it', () async {
      final v1 = jsonEncode({
        'app': 'daily-discipline',
        'version': 1,
        'settings': Settings(trainingGoalMin: 10).toJson(),
        'logs': _v1Logs,
        'tasks': [
          Task(id: 't1', seq: 1, title: 'Read', repeat: Repeat.daily).toJson(),
        ],
      });
      final state = await loadState();
      await state.importBackup(v1);
      expect(state.tasks.single.title, 'Read');
      expect(state.habits.single.id, articulationHabitId);
      expect(state.habits.single.target, 10);
      expect(state.habitEntry(DateTime(2026, 3, 1), articulationHabitId).minutes, 20);
      expect(habitDoneOn(state.logs, state.habits.single, DateTime(2026, 3, 1)), isTrue);
    });

    test('rejects something that is not a backup', () async {
      final state = await loadState();
      expect(() => state.importBackup('{"app":"other"}'), throwsFormatException);
    });
  });

  group('AppState', () {
    test('upsertHabit assigns seq, replaces by id; archive hides, delete removes', () async {
      final state = await loadState();
      final a = await state.upsertHabit(habitFromTemplate(waterTemplate));
      final b = await state.upsertHabit(habitFromTemplate(quranTemplate));
      expect([a.seq, b.seq], [1, 2]);
      await state.upsertHabit(a.copy()..title = 'Hydrate');
      expect(state.habits.length, 2);
      expect(state.habitById(a.id)!.title, 'Hydrate');
      await state.archiveHabit(a.id);
      expect(state.activeHabits.map((h) => h.id), [b.id]);
      expect(state.habits.length, 2);
      await state.archiveHabit(a.id, archived: false);
      expect(state.activeHabits.length, 2);
      await state.deleteHabit(b.id);
      expect(state.habits.single.id, a.id);
    });

    test('logHabit, setWake and setPrayerStatus work for any day', () async {
      final state = await loadState();
      final past = DateTime(2026, 2, 10);
      await state.logHabit(past, 'h', HabitEntry(done: true));
      expect(state.logFor(past).habits['h']!.done, isTrue);
      await state.logHabit(past, 'h', HabitEntry());
      expect(state.logFor(past).habits, isEmpty, reason: 'an empty entry clears the log');

      await state.setWake(past, DateTime(2030, 1, 1, 5, 10));
      expect(state.logFor(past).wakeAt, DateTime(2026, 2, 10, 5, 10), reason: 'the date comes from the day');
      await state.setWake(past, null);
      expect(state.logFor(past).wakeAt, isNull);

      await state.setPrayerStatus(past, 'Asr', prayerQada);
      expect(state.logFor(past).prayers, {'Asr'});
      expect(state.logFor(past).prayerStatus, {'Asr': prayerQada});
      await state.setPrayer(past, 'Asr', true);
      expect(state.logFor(past).prayerStatus['Asr'], prayerQada, reason: 'ticking keeps the status');
      await state.setPrayerStatus(past, 'Asr', null);
      expect(state.logFor(past).prayers, isEmpty);
      expect(state.logFor(past).prayerStatus, isEmpty);
      expect(state.logFor(DateTime(1999, 1, 1)).isEmpty, isTrue);
    });
  });
}
