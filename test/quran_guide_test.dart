import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_tracker/agent/goal_tools.dart';
import 'package:habit_tracker/logic/stats.dart';
import 'package:habit_tracker/models.dart';
import 'package:habit_tracker/quran/quran.dart';
import 'package:habit_tracker/quran/task_guide_screen.dart';
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
}
