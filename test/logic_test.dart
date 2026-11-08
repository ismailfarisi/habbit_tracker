import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_tracker/logic/speech_metrics.dart';
import 'package:habit_tracker/logic/stats.dart';
import 'package:habit_tracker/models.dart';
import 'package:habit_tracker/services/openrouter.dart';
import 'package:habit_tracker/services/prayer_service.dart';
import 'package:habit_tracker/services/reminders.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('wake', () {
    final s = Settings(wakeTime: const TimeOfDay(hour: 5, minute: 0), wakeGraceMin: 30);
    test('within grace is on time, after is late', () {
      expect(wakeResult(DayLog(wakeAt: DateTime(2026, 1, 1, 5, 30)), s), WakeResult.onTime);
      expect(wakeResult(DayLog(wakeAt: DateTime(2026, 1, 1, 5, 31)), s), WakeResult.late);
      expect(wakeResult(DayLog(), s), WakeResult.none);
    });
  });

  group('streaks', () {
    final s = Settings(trainingGoalMin: 10);
    final today = DateTime(2026, 3, 10);
    Map<String, DayLog> logs(List<int> daysAgo) => {
          for (final d in daysAgo) dayKey(DateTime(2026, 3, 10 - d)): DayLog(trainingMinutes: 10),
        };
    bool done(DayLog? l) => trainingDone(l, s);

    test('counts back from today', () {
      expect(streak(logs([0, 1, 2]), done, today: today), 3);
    });
    test('today not done yet does not break the streak', () {
      expect(streak(logs([1, 2]), done, today: today), 2);
    });
    test('a gap breaks it', () {
      expect(streak(logs([0, 2, 3]), done, today: today), 1);
    });
    test('works across month boundaries', () {
      expect(streak(logs([0, 9, 10, 11]), done, today: today), 1);
      expect(streak(logs(List.generate(15, (i) => i)), done, today: today), 15);
    });
    test('best streak', () {
      expect(bestStreak(logs([0, 1, 5, 6, 7, 8]), done), 4);
    });
  });

  test('daily score', () {
    final s = Settings(wakeTime: const TimeOfDay(hour: 5, minute: 0), trainingGoalMin: 15);
    final log = DayLog(wakeAt: DateTime(2026, 1, 1, 4, 55), prayers: {'Fajr', 'Dhuhr'}, trainingMinutes: 15);
    expect(dailyScore(log, s), 4);
  });

  group('settings', () {
    test('round-trips through JSON', () {
      final s = Settings(latitude: 11.25, longitude: 75.78, calcMethod: 'karachi', madhab: 'hanafi', model: 'x/y');
      final r = Settings.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
      expect(r.toJson(), s.toJson());
    });
    test('tolerates junk', () {
      final r = Settings.fromJson({'wakeTime': 'nope', 'calcMethod': 'bogus'});
      expect(r.wakeTime, const TimeOfDay(hour: 5, minute: 0));
      expect(r.calcMethod, 'muslim_world_league');
    });
  });

  group('prayer times', () {
    test('calculated times are ordered and on the right day', () {
      final s = Settings(latitude: 21.4225, longitude: 39.8262, calcMethod: 'umm_al_qura');
      final day = prayerTimesFor(s, DateTime(2026, 6, 1));
      expect(day.calculated, isTrue);
      final times = prayerNames.map((p) => day.times[p]!).toList();
      for (var i = 1; i < times.length; i++) {
        expect(times[i].isAfter(times[i - 1]), isTrue, reason: '${prayerNames[i]} after ${prayerNames[i - 1]}');
      }
    });
    test('falls back to manual times without location', () {
      final day = prayerTimesFor(Settings(), DateTime(2026, 6, 1));
      expect(day.calculated, isFalse);
      expect(day.times['Fajr'], DateTime(2026, 6, 1, 5, 0));
    });
    test('next prayer rolls over to tomorrow after Isha', () {
      final s = Settings(useManualPrayer: true);
      final n = nextPrayer(s, DateTime(2026, 6, 1, 23, 0));
      expect(n.key, 'Fajr');
      expect(n.value, DateTime(2026, 6, 2, 5, 0));
    });
  });

  group('reminders', () {
    final s = Settings(useManualPrayer: true, wakeTime: const TimeOfDay(hour: 5, minute: 0), trainingGoalMin: 10);
    test('skips past and completed items, stays under the iOS limit', () {
      final now = DateTime(2026, 6, 1, 13, 0);
      final logs = {dayKey(now): DayLog(prayers: {'Asr'})};
      final plan = planReminders(s, logs, now);
      final today = plan.where((r) => dayKey(r.when) == dayKey(now)).map((r) => r.payload).toList();
      expect(today, ['prayer:Maghrib|2026-06-01', 'prayer:Isha|2026-06-01']);
      expect(plan.length, lessThanOrEqualTo(64));
      expect(plan.map((r) => r.id).toSet().length, plan.length, reason: 'ids are unique');
    });
    test('ids are stable across days and reschedules', () {
      final a = planReminders(s, {}, DateTime(2026, 6, 1, 0, 0));
      final b = planReminders(s, {}, DateTime(2026, 6, 2, 0, 0));
      final june3a = a.where((r) => r.payload.endsWith('2026-06-03')).map((r) => r.id).toList();
      final june3b = b.where((r) => r.payload.endsWith('2026-06-03')).map((r) => r.id).toList();
      expect(june3a, june3b);
      expect(reminderId(DateTime(2026, 6, 3), 0), lessThan(1 << 31));
    });
    test('applies offset', () {
      final s2 = Settings(useManualPrayer: true, prayerOffsetMin: 10);
      final plan = planReminders(s2, {}, DateTime(2026, 6, 1, 0, 0), days: 1);
      final fajr = plan.firstWhere((r) => r.payload.startsWith('prayer:Fajr'));
      expect(fajr.when, DateTime(2026, 6, 1, 4, 50));
      expect(fajr.title, contains('in 10 min'));
    });
    test('done action marks prayer and wake', () {
      final logs = <String, DayLog>{};
      final now = DateTime(2026, 6, 1, 5, 2);
      expect(applyDoneAction('prayer:Fajr|2026-06-01', logs, now), isTrue);
      expect(applyDoneAction('wake|2026-06-01', logs, now), isTrue);
      expect(applyDoneAction('prayer:Nope|2026-06-01', logs, now), isFalse);
      expect(logs['2026-06-01']!.prayers, {'Fajr'});
      expect(logs['2026-06-01']!.wakeAt, now);
    });
  });

  group('speech metrics', () {
    test('counts fillers and pace', () {
      final m = analyzeSpeech('Um so I mean like the the thing is uh basically good', const Duration(seconds: 30));
      expect(m.fillers['um'], 1);
      expect(m.fillers['uh'], 1);
      expect(m.fillers['like'], 1);
      expect(m.fillers['i mean'], 1);
      expect(m.wordsPerMinute, closeTo(m.wordCount * 2, 0.01));
    });
    test('accuracy against target text', () {
      final m = analyzeSpeech(
        'she sells sea shells by the shore',
        const Duration(seconds: 5),
        target: 'She sells seashells by the seashore.',
      );
      expect(m.accuracy, closeTo(4 / 6, 0.01));
      expect(m.missedWords, containsAll(['seashells', 'seashore']));
    });
  });

  group('openrouter', () {
    test('parses SSE lines', () {
      expect(parseSseLine(': OPENROUTER PROCESSING'), isNull);
      expect(parseSseLine('data: [DONE]'), isNull);
      expect(parseSseLine('data: {"choices":[{"delta":{"content":"Hi"}}]}'), 'Hi');
      expect(() => parseSseLine('data: {"error":{"message":"boom"}}'), throwsA(isA<OpenRouterException>()));
    });

    test('streams a reply and sends auth', () async {
      late http.BaseRequest seen;
      final client = MockClient.streaming((req, body) async {
        seen = req;
        final chunks = [
          ': OPENROUTER PROCESSING\n\n',
          'data: {"choices":[{"delta":{"content":"Hel"}}]}\n\ndata: {"choices":[{"del',
          'ta":{"content":"lo"}}]}\n\ndata: [DONE]\n\n',
        ];
        return http.StreamedResponse(Stream.fromIterable(chunks.map(utf8.encode)), 200);
      });
      final or = OpenRouterClient(apiKey: 'k', model: 'm', client: client);
      expect(await or.complete([const ChatMessage('user', 'hi')]), 'Hello');
      expect(seen.headers['Authorization'], 'Bearer k');
    });

    test('reports HTTP errors helpfully', () async {
      final client = MockClient((_) async => http.Response('{"error":{"message":"No auth"}}', 401));
      final or = OpenRouterClient(apiKey: 'bad', model: 'm', client: client);
      expect(
        () => or.complete([const ChatMessage('user', 'hi')]),
        throwsA(predicate((e) => e.toString().contains('Invalid API key'))),
      );
    });

    test('requires a key', () {
      final or = OpenRouterClient(apiKey: '', model: 'm');
      expect(() => or.complete([]), throwsA(isA<OpenRouterException>()));
    });
  });
}
