import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_tracker/agent/goal_tools.dart';
import 'package:habit_tracker/logic/stats.dart';
import 'package:habit_tracker/models.dart';
import 'package:habit_tracker/habits/habit.dart';
import 'package:habit_tracker/quran/quran.dart';
import 'package:habit_tracker/quran/task_guide_screen.dart';
import 'package:habit_tracker/goals/goals_card.dart';
import 'package:habit_tracker/screens/today_screen.dart';
import 'package:habit_tracker/services/openrouter.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(mockPlugins);
  final raw = File('assets/quran/quran-uthmani.txt').readAsStringSync();

  test('the bundled Tanzil text has all 6236 ayat and its licence notice', () {
    final q = QuranText.parse(raw);
    expect(q.length, 114);
    expect(q.values.fold<int>(0, (n, s) => n + s.length), 6236);
    expect(q[112], hasLength(4));
    expect(q[2], hasLength(286));
    expect(raw, contains('Tanzil Project'));
    expect(passageLabel(78, 1, 5), 'An-Naba 1–5');
    expect(ayahAudioUrl(112, 1), 'https://everyayah.com/data/Alafasy_128kbps/112001.mp3');
  });

  test('a task guide round-trips through JSON', () {
    final t = Task(
      id: 't',
      seq: 1,
      title: 'Memorise An-Naba 1-5',
      guide: const TaskGuide(steps: ['Listen 3 times'], doneWhen: 'Recite from memory', minutes: 20, quran: QuranRef(78, 1, 5, mode: 'memorise')),
      stepsDone: {'2026-11-19': {0}},
    );
    final back = Task.fromJson(jsonDecode(jsonEncode(t.toJson())) as Map<String, dynamic>);
    expect(back.toJson(), t.toJson());
    expect(back.guide!.quran!.mode, 'memorise');
  });

  test('create_goal saves steps, done-when and a clamped Quran passage on each task', () async {
    final s = await loadState({'settings.v1': jsonEncode({'onboarded': true})});
    final tools = GoalTools(s, clock: () => DateTime(2026, 11, 19));
    await tools.execute(
      ToolCall(
        'c',
        'create_goal',
        jsonEncode({
          'title': 'Memorise Juz Amma',
          'end_date': '2027-05-19',
          'tasks': [
            {
              'title': 'Memorise An-Naba 1-5',
              'steps': ['Listen to each ayah 3 times', 'Repeat each ayah 5 times', 'Recite all five from memory'],
              'done_when': 'You can recite 1-5 without looking',
              'minutes': 20,
              'quran': {'surah': 78, 'from': 1, 'to': 99, 'mode': 'memorise'},
            },
          ],
        }),
      ),
    );
    final g = s.tasks.single.guide!;
    expect(g.steps, hasLength(3));
    expect(g.doneWhen, contains('without looking'));
    expect(g.quran!.to, 40, reason: 'An-Naba has 40 ayat');
    expect(s.storage.loadTasks().single.guide!.minutes, 20);
  });

  testWidgets('the guide screen shows steps, verified verses and test-myself mode', (tester) async {
    final s = await loadState({'settings.v1': jsonEncode({'onboarded': true})});
    final t = await s.addTask(title: 'Memorise Al-Ikhlas');
    await s.updateTask(
      t,
      (x) => x.guide = const TaskGuide(steps: ['Listen', 'Repeat'], doneWhen: 'Recite it', quran: QuranRef(112, 1, 4)),
    );
    QuranText.cache = QuranText.parse(raw);
    tester.view.physicalSize = const Size(600, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: TaskGuideScreen(state: s, taskId: t.id)));
    await tester.pump();
    await tester.pump();
    expect(find.text('1. Listen'), findsOneWidget);
    expect(find.text('Done when: Recite it'), findsOneWidget);
    expect(find.text('Al-Ikhlaas 1–4'), findsOneWidget);
    final second = QuranText.parse(raw)[112]![1];
    expect(find.textContaining(second), findsOneWidget);
    expect(find.textContaining('tanzil.net'), findsOneWidget);

    await tester.tap(find.text('1. Listen'));
    await tester.pump();
    expect(s.taskById(t.id)!.stepsDone[dayKey(DateTime.now())], {0});

    await tester.tap(find.byKey(const Key('quran-hide')));
    await tester.pump();
    expect(find.byKey(const ValueKey('hidden-2')), findsOneWidget);
    expect(find.textContaining(second), findsNothing);
    await tester.tap(find.byKey(const ValueKey('hidden-2')));
    await tester.pump();
    expect(find.textContaining(second), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('guide-done')));
    await tester.tap(find.byKey(const Key('guide-done')));
    await tester.pump();
    expect(s.taskById(t.id)!.doneDates, isNotEmpty);
  });

  test('a Quran goal is one goal: linked habit with a daily portion, nothing loose on Today', () async {
    final s = await loadState({'settings.v1': jsonEncode({'onboarded': true})});
    final now = DateTime.now();
    final tools = GoalTools(s);
    await tools.execute(
      ToolCall(
        'c',
        'create_goal',
        jsonEncode({
          'title': 'Memorise Surah Al-Mulk',
          'end_date': dayKey(now.add(const Duration(days: 30))),
          'habits': [
            {
              'title': 'Memorise Al-Mulk',
              'reminder': '05:30',
              'steps': ['Listen', 'Repeat each ayah 5 times', 'Recite from memory'],
              'done_when': 'Recite today\'s ayat from memory',
              'minutes': 15,
              'quran': {'surah': 67, 'from': 1, 'to': 30, 'per_day': 2, 'mode': 'memorise'},
            },
          ],
          'tasks': [
            {'title': 'Revise this week\'s ayat', 'date': dayKey(now), 'steps': ['Recite all'], 'done_when': 'No mistakes'},
          ],
        }),
      ),
    );
    final g = s.goals.single;
    final h = s.habits.firstWhere((x) => x.title == 'Memorise Al-Mulk');
    expect(g.habitIds, [h.id]);
    expect(g.taskIds, [s.tasks.single.id]);
    expect(s.goalFor(h.id), g);
    final q = s.quranFor(h, now)!;
    expect((q.surah, q.from, q.to), (67, 1, 2));

    await s.logHabit(now.subtract(const Duration(days: 1)), h.id, s.habitEntry(now, h.id).copy()..done = true);
    final next = s.quranFor(h, now)!;
    expect((next.from, next.to), (3, 4), reason: 'one day done moves to the next two ayat');
    expect(goalHabitSubtitle(s, h, now), startsWith('Memorise Al-Mulk 3–4 · 15 min'));

    final items = todayItems(s, now);
    expect(items.where((i) => i.kind == TodayKind.goal), hasLength(1));
    expect(items.where((i) => i.habit?.id == h.id), isEmpty, reason: 'the goal habit sits in the goal card');
  });

  testWidgets('a goal habit opens its steps and today\'s Quran portion', (tester) async {
    final s = await loadState({'settings.v1': jsonEncode({'onboarded': true})});
    final h = await s.upsertHabit(
      HabitDef(
        id: 'hm',
        title: 'Memorise Al-Mulk',
        guide: const TaskGuide(steps: ['Listen'], doneWhen: 'Recite', quran: QuranRef(67, 1, 30, mode: 'memorise', perDay: 2)),
      ),
    );
    QuranText.cache = QuranText.parse(raw);
    tester.view.physicalSize = const Size(600, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: TaskGuideScreen(state: s, habitId: h.id)));
    await tester.pump();
    await tester.pump();
    expect(find.text("Today's portion"), findsOneWidget);
    expect(find.text('Al-Mulk 1–2'), findsOneWidget);
    await tester.tap(find.text('1. Listen'));
    await tester.pump();
    expect(s.habitEntry(DateTime.now(), h.id).data['steps'], [0]);
    await tester.tap(find.byKey(const Key('guide-done')));
    await tester.pump();
    expect(s.habitEntry(DateTime.now(), h.id).done, isTrue);
  });

  test('a repeating Quran task moves on each day it is done', () async {
    final s = await loadState({'settings.v1': jsonEncode({'onboarded': true})});
    final t = await s.addTask(title: 'Memorise Al-Mulk', repeat: Repeat.daily);
    await s.updateTask(t, (x) => x.guide = const TaskGuide(steps: ['Repeat'], quran: QuranRef(67, 1, 3, mode: 'memorise')));
    final today = DateTime(2026, 11, 20);
    expect(s.quranForTask(t, today)!.to, 3);
    await s.updateTask(t, (x) => x.doneDates.addAll(['2026-11-18', '2026-11-19']));
    final q = s.quranForTask(t, today)!;
    expect((q.from, q.to), (7, 9), reason: 'two days of 3 ayat done');
    await s.updateTask(t, (x) => x.doneDates.add('2026-11-20'));
    expect(s.quranForTask(t, today)!.from, 7, reason: "today's own tick does not move today's portion");
    await s.updateTask(t, (x) => x.guide = const TaskGuide(quran: QuranRef(67, 1, 30, perDay: 5)));
    expect(s.quranForTask(t, today)!.from, 11);
  });

  test('a future day shows the portion planned for that day', () async {
    final s = await loadState({'settings.v1': jsonEncode({'onboarded': true})});
    final now = DateTime.now();
    final t = await s.addTask(title: 'Memorise Al-Mulk', repeat: Repeat.daily);
    await s.updateTask(t, (x) => x.guide = const TaskGuide(quran: QuranRef(67, 1, 30, mode: 'memorise', perDay: 3)));
    expect(s.quranForTask(t, now)!.from, 1);
    expect(s.quranForTask(t, now.add(const Duration(days: 2)))!.from, 7);
    await s.updateTask(t, (x) => x.doneDates.add(dayKey(now)));
    expect(s.quranForTask(t, now.add(const Duration(days: 2)))!.from, 7, reason: 'done today is not counted twice');
    final h = await s.upsertHabit(HabitDef(id: 'hf', title: 'Al-Mulk', guide: const TaskGuide(quran: QuranRef(67, 1, 30, perDay: 2))));
    expect(s.quranFor(h, now.add(const Duration(days: 3)))!.from, 7);
  });

  testWidgets('a memorise portion can be recited together with the ayat learned before it', (tester) async {
    final s = await loadState({'settings.v1': jsonEncode({'onboarded': true})});
    final h = await s.upsertHabit(
      HabitDef(id: 'hr', title: 'Memorise Al-Mulk', guide: const TaskGuide(quran: QuranRef(67, 1, 30, mode: 'memorise', perDay: 2))),
    );
    final now = DateTime.now();
    for (final d in [1, 2]) {
      final day = now.subtract(Duration(days: d));
      await s.logHabit(day, h.id, s.habitEntry(day, h.id).copy()..done = true);
    }
    final mulk = QuranText.parse(raw)[67]!;
    QuranText.cache = QuranText.parse(raw);
    tester.view.physicalSize = const Size(600, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: TaskGuideScreen(state: s, habitId: h.id)));
    await tester.pump();
    await tester.pump();
    expect(find.text('Al-Mulk 5–6'), findsOneWidget);
    expect(find.textContaining(mulk[2]), findsNothing);

    await tester.tap(find.text('Previous + today'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Al-Mulk 3–6'), findsOneWidget);
    expect(find.text('Learned · ayat 3–4'), findsOneWidget);
    expect(find.text('New today'), findsOneWidget);
    expect(find.textContaining(mulk[2]), findsOneWidget);
    expect(find.textContaining(mulk[0]), findsNothing);

    await tester.tap(find.text('All learned'));
    await tester.pumpAndSettle();
    await tester.pump();
    expect(find.text('Al-Mulk 1–4'), findsOneWidget);
    expect(find.byKey(const ValueKey('hidden-4')), findsOneWidget);
    expect(find.byKey(const ValueKey('hidden-5')), findsNothing);
    expect(find.byKey(const Key('guide-done')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('hidden-2')));
    await tester.pump();
    expect(find.textContaining(mulk[1]), findsOneWidget);
    await tester.tap(find.byKey(const Key('quran-rep')));
    await tester.tap(find.byTooltip('Bookmark ayah 2'));
    await tester.tap(find.byKey(const Key('quran-revision')));
    await tester.pump();
    expect(s.storage.loadSettings().quranBookmarks, {'67:2'});
    final saved = s.storage.loadLogs()[dayKey(now)]!.quranPractice.values.single;
    expect((saved.revised, saved.repetitions, saved.revealed.single), (true, 1, 2));
    expect(s.habitEntry(now, h.id).done, isFalse);
    expect(s.quranFor(h, now)!.from, 5);
    final nextDay = DateTime(now.year, now.month, now.day + 1);
    expect(s.quranFor(h, nextDay, today: nextDay)!.from, 5, reason: 'Revision alone does not advance tomorrow');

    await tester.tap(find.text('Today'));
    await tester.pump();
    await tester.tap(find.byTooltip('Review a bookmarked ayah'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ayah 2'));
    await tester.pumpAndSettle();
    expect(find.text('Al-Mulk 2'), findsOneWidget);
    expect(find.byKey(const Key('guide-done')), findsNothing);
    await tester.tap(find.text('All learned'));
    await tester.pumpAndSettle();
    expect(find.text('Revision saved · portion unchanged'), findsOneWidget);
    expect(find.text('Repetitions: 1'), findsOneWidget);
    expect(find.byKey(const ValueKey('hidden-2')), findsNothing);

    final backup = s.storage.exportJson();
    final restored = await loadState();
    await restored.storage.importJson(backup);
    expect(restored.storage.loadSettings().quranBookmarks, {'67:2'});
    expect(restored.storage.loadLogs()[dayKey(now)]!.quranPractice.values.single.toJson(), saved.toJson());
  });

  testWidgets('the first portion has nothing learned before it to add', (tester) async {
    final s = await loadState({'settings.v1': jsonEncode({'onboarded': true})});
    final h = await s.upsertHabit(
      HabitDef(id: 'h1', title: 'Memorise Al-Mulk', guide: const TaskGuide(quran: QuranRef(67, 1, 30, mode: 'memorise', perDay: 2))),
    );
    QuranText.cache = QuranText.parse(raw);
    await tester.pumpWidget(MaterialApp(home: TaskGuideScreen(state: s, habitId: h.id)));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('quran-scope')), findsNothing);
  });
}
