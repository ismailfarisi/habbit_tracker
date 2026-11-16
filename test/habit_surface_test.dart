import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_tracker/agent/habit_catalog.dart';
import 'package:habit_tracker/agent/habit_surface.dart';
import 'package:habit_tracker/agent/habit_templates.dart';
import 'package:habit_tracker/agent/speech_engine.dart';
import 'package:habit_tracker/app_state.dart';
import 'package:habit_tracker/habits/habit.dart';
import 'package:habit_tracker/logic/stats.dart';
import 'package:habit_tracker/screens/habit_detail_screen.dart';
import 'package:habit_tracker/widgets/day_editor.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final day = DateTime(2026, 5, 4);
  late AppState state;

  setUp(() async {
    mockPlugins();
    state = await loadState();
  });
  tearDown(() => speechEngineFactory = PluginSpeechEngine.new);

  Future<HabitDef> add(HabitTemplate t) => state.upsertHabit(habitFromTemplate(t, createdAt: DateTime(2026, 4, 1)));

  Future<void> pump(WidgetTester tester, HabitDef habit, {AskCoachHandler? onAskCoach}) async {
    tester.view.physicalSize = const Size(420, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ListenableBuilder(
            listenable: state,
            builder: (_, _) => HabitSurface(state, state.habitById(habit.id) ?? habit, day, onAskCoach: onAskCoach),
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  HabitSurfaceState surfaceState(WidgetTester tester) => tester.state(find.byType(HabitSurface));
  HabitEntry entry(HabitDef h) => state.habitEntry(day, h.id);

  test('every template is a valid surface', () {
    for (final t in habitTemplates) {
      expect(() => normalizeHabitSurface(surfaceMessage(t.components)), returnsNormally, reason: t.title);
    }
    expect(habitTemplates.map((t) => t.title),
        containsAll(['Articulation practice', 'Read Quran', 'Drink water', 'Exercise']));
  });

  testWidgets('Drink water: Counter + and - persist the value and complete the habit', (tester) async {
    final h = await add(waterTemplate);
    await pump(tester, h);
    expect(surfaceState(tester).usingFallback, isFalse);
    expect(find.text('Glasses of water'), findsOneWidget);
    expect(find.text('0 / 8 glasses'), findsOneWidget);

    await tester.tap(find.byTooltip('More'));
    await tester.pump();
    expect(entry(h).value, 1);
    expect(find.text('1 / 8 glasses'), findsOneWidget);

    for (var i = 0; i < 7; i++) {
      await tester.tap(find.byTooltip('More'));
      await tester.pump();
    }
    expect(entry(h).value, 8);
    expect(habitDone(entry(h), h), isTrue);

    await tester.tap(find.byTooltip('Less'));
    await tester.pump();
    expect(entry(h).value, 7);
    expect(habitDone(entry(h), h), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Read Quran: HabitCheck tap persists done, Counter counts pages', (tester) async {
    final h = await add(quranTemplate);
    await pump(tester, h);
    expect(surfaceState(tester).usingFallback, isFalse);

    await tester.tap(find.text('I read Quran today'));
    await tester.pump();
    expect(entry(h).done, isTrue);
    expect(habitDone(entry(h), h), isTrue);

    await tester.tap(find.byTooltip('More'));
    await tester.pump();
    await tester.tap(find.byTooltip('More'));
    await tester.pump();
    expect(entry(h).value, 2);
    expect(find.text('2 pages'), findsOneWidget);

    await tester.tap(find.text('I read Quran today'));
    await tester.pump();
    expect(entry(h).done, isFalse);
    expect(entry(h).value, 2, reason: 'unticking keeps the pages');
  });

  testWidgets('Exercise: PracticeTimer finish logs minutes and a session; RatingInput writes a metric', (tester) async {
    final h = await add(exerciseTemplate);
    await pump(tester, h);
    expect(surfaceState(tester).usingFallback, isFalse);
    expect(find.text('Today: 0 / 30 min'), findsOneWidget);

    await tester.tap(find.text('Start'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Pause'), findsOneWidget);
    await tester.tap(find.text('Finish & log'));
    await tester.pump();

    expect(entry(h).minutes, 1, reason: 'a short session rounds up to a minute');
    expect(entry(h).sessions, hasLength(1));
    expect(find.text('Today: 1 / 30 min'), findsOneWidget);

    await tester.tap(find.byTooltip('4'));
    await tester.pump();
    expect(entry(h).metrics['effort'], 4);
    expect(entry(h).minutes, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Articulation: ReadAloudDrill records, measures and saves metrics; timer and trends render',
      (tester) async {
    final engine = FakeSpeechEngine('red lorry yellow lorry um she sells seashells by the seashore');
    speechEngineFactory = () => engine;
    final h = await add(articulationTemplate);
    await state.logHabit(DateTime(2026, 5, 2), h.id, HabitEntry(minutes: 15, metrics: {'wpm': 110, 'fillers': 4}));
    Map<String, dynamic>? asked;
    await pump(tester, h, onAskCoach: (_, request) => asked = request);
    expect(surfaceState(tester).usingFallback, isFalse);
    expect(find.text('Warm-up (2 min)'), findsOneWidget);
    expect(find.textContaining('Red lorry, yellow lorry.'), findsOneWidget);
    expect(find.text('Practice time'), findsOneWidget);
    expect(find.text('Pace'), findsOneWidget);
    expect(find.text('110 words/min'), findsOneWidget, reason: 'MetricTrend shows the last logged value');

    await tester.tap(find.text('Hear it'));
    await tester.pump();
    expect(engine.spoken, contains('Red lorry'));

    await tester.tap(find.text('Record'));
    await tester.pump();
    expect(engine.listening, isTrue);
    await tester.tap(find.text('Stop'));
    await tester.pump();

    final e = entry(h);
    expect(e.metrics['fillers'], 1);
    expect(e.metrics['accuracy'], greaterThan(40));
    expect(e.sessions.single.transcript, contains('seashells'));
    expect(e.sessions.single.metrics['fillers'], 1);
    expect(find.text('fillers'), findsOneWidget);
    expect(find.text('target words'), findsOneWidget);
    expect(metricHistory(state.logs, h, 'fillers', days: 3, end: day), [4, null, 1]);

    await tester.tap(find.text('Ask coach for feedback'));
    await tester.pump();
    expect(asked!['transcript'], contains('seashells'));
    expect(asked!['habit'], 'Articulation practice');

    await tester.tap(find.text('Start'));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Finish & log'));
    await tester.pump();
    expect(entry(h).minutes, 1);
    expect(entry(h).sessions, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a typed transcript is scored without a microphone', (tester) async {
    speechEngineFactory = () => FakeSpeechEngine('');
    final h = await add(articulationTemplate);
    await pump(tester, h);
    await tester.enterText(find.widgetWithText(TextField, 'Transcript'), 'three thin thieves like um');
    await tester.tap(find.byTooltip('Save result'));
    await tester.pump();
    expect(entry(h).metrics['fillers'], 2);
    expect(entry(h).metrics.containsKey('wpm'), isFalse, reason: 'no duration, so no pace');
  });

  testWidgets('the surface is seeded from the stored entry and follows outside changes', (tester) async {
    final h = await add(waterTemplate);
    await state.logHabit(day, h.id, HabitEntry(value: 3));
    await pump(tester, h);
    expect(find.text('3 / 8 glasses'), findsOneWidget);

    await state.logHabit(day, h.id, HabitEntry(value: 5));
    await tester.pump();
    expect(find.text('5 / 8 glasses'), findsOneWidget);

    await state.upsertHabit(state.habitById(h.id)!.copy()..target = 10);
    await tester.pump();
    expect(find.text('5 / 10 glasses'), findsOneWidget, reason: '/habit/target follows the habit');
    expect(state.habitEntry(DateTime(2026, 5, 3), h.id).isEmpty, isTrue, reason: 'other days are untouched');
  });

  testWidgets('logEntry and finishSession actions from a basic Button are applied', (tester) async {
    final h = await state.upsertHabit(HabitDef(
      id: 'custom',
      title: 'Stretch',
      kind: HabitKind.duration,
      target: 10,
      createdAt: DateTime(2026, 4, 1),
      uiSurface: normalizeHabitSurface({
        'components': [
          {'id': 'root', 'component': 'Column', 'children': ['log', 'finish']},
          {
            'id': 'log',
            'component': 'Button',
            'child': 'logLabel',
            'action': {
              'event': {
                'name': 'logEntry',
                'context': {'done': true, 'addValue': 2, 'notes': 'morning'},
              },
            },
          },
          {'id': 'logLabel', 'component': 'Text', 'text': 'Log it'},
          {
            'id': 'finish',
            'component': 'Button',
            'child': 'finishLabel',
            'action': {
              'event': {
                'name': 'finishSession',
                'context': {'addMinutes': 10, 'durationSec': 600, 'metrics': {'reps': 12}},
              },
            },
          },
          {'id': 'finishLabel', 'component': 'Text', 'text': 'Finish 10 min'},
        ],
      }),
    ));
    await pump(tester, h);
    await tester.tap(find.text('Log it'));
    await tester.pump();
    expect(entry(h).done, isTrue);
    expect(entry(h).value, 2);
    expect(entry(h).notes, 'morning');

    await tester.tap(find.text('Finish 10 min'));
    await tester.pump();
    expect(entry(h).minutes, 10);
    expect(entry(h).metrics['reps'], 12);
    expect(entry(h).sessions.single.durationSec, 600);
    expect(tester.takeException(), isNull);
  });

  testWidgets('RatingInput and ChoiceChips bind to custom paths that are kept in the entry', (tester) async {
    final h = await state.upsertHabit(HabitDef(
      id: 'mood',
      title: 'Mood',
      kind: HabitKind.metric,
      createdAt: DateTime(2026, 4, 1),
      uiSurface: normalizeHabitSurface({
        'components': [
          {'id': 'root', 'component': 'Column', 'children': ['rate', 'where']},
          {'id': 'rate', 'component': 'RatingInput', 'label': 'Mood', 'value': {'@path': '/metrics/mood'}},
          {'id': 'where', 'component': 'ChoiceChips', 'label': 'Where', 'options': ['Home', 'Gym']},
        ],
      }),
    ));
    await pump(tester, h);
    await tester.tap(find.byTooltip('3'));
    await tester.pump();
    await tester.tap(find.text('Gym'));
    await tester.pump();
    expect(entry(h).metrics['mood'], 3);
    expect(entry(h).data['choice'], 'Gym');
    expect(habitDone(entry(h), h), isTrue);
  });

  group('fallback', () {
    testWidgets('an invalid stored surface degrades to a simple counter that still persists', (tester) async {
      final h = await state.upsertHabit(HabitDef(
        id: 'broken',
        title: 'Push-ups',
        kind: HabitKind.count,
        target: 20,
        unit: 'reps',
        createdAt: DateTime(2026, 4, 1),
        uiSurface: {
          'version': '1.0',
          'createSurface': {
            'surfaceId': 'x',
            'catalogId': basicCatalogId,
            'components': [
              {'id': 'root', 'component': 'NoSuchWidget', 'children': ['ghost']},
            ],
          },
        },
      ));
      await pump(tester, h);
      expect(surfaceState(tester).usingFallback, isTrue);
      expect(find.byType(HabitFallback), findsOneWidget);
      expect(find.text('0 / 20 reps'), findsOneWidget);

      await tester.tap(find.byTooltip('More'));
      await tester.pump();
      expect(entry(h).value, 1);
      await tester.tap(find.text('Done today'));
      await tester.pump();
      expect(entry(h).done, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a habit without a surface gets a check box', (tester) async {
      final h = await state.upsertHabit(HabitDef(id: 'plain', title: 'Journal', createdAt: DateTime(2026, 4, 1)));
      await pump(tester, h);
      expect(surfaceState(tester).usingFallback, isTrue);
      await tester.tap(find.text('Done today'));
      await tester.pump();
      expect(entry(h).done, isTrue);
    });

    testWidgets('a timed habit without a surface logs 5 minutes per tap', (tester) async {
      final h = await state.upsertHabit(
        HabitDef(id: 'walk', title: 'Walk', kind: HabitKind.duration, target: 10, createdAt: DateTime(2026, 4, 1)),
      );
      await pump(tester, h);
      await tester.tap(find.byTooltip('More'));
      await tester.pump();
      await tester.tap(find.byTooltip('More'));
      await tester.pump();
      expect(entry(h).minutes, 10);
      expect(habitDone(entry(h), h), isTrue);
    });
  });

  group('normalizeHabitSurface', () {
    test('accepts a bare component list and adds catalog ids and default bindings', () {
      final m = normalizeHabitSurface([
        {'id': 'root', 'component': 'Counter', 'label': 'Reps'},
      ]);
      final c = ((m['createSurface'] as Map)['components'] as List).single as Map;
      expect(c['catalogId'], habitCatalogId);
      expect(c['value'], {'@path': '/value'});
      expect(m['version'], '1.0');
    });
    test('accepts {messages: [createSurface, updateComponents]}', () {
      final m = normalizeHabitSurface({
        'messages': [
          {
            'version': '1.0',
            'createSurface': {'surfaceId': 's', 'catalogId': basicCatalogId},
          },
          {
            'version': '1.0',
            'updateComponents': {
              'surfaceId': 's',
              'components': [
                {'id': 'root', 'component': 'HabitCheck', 'label': 'Did it'},
              ],
            },
          },
        ],
      });
      expect(((m['createSurface'] as Map)['components'] as List), hasLength(1));
    });
    test('rejects unknown components, missing root, dangling children, wrong types and empty input', () {
      for (final bad in <Object?>[
        null,
        'nope',
        {'components': <Object>[]},
        {
          'components': [
            {'id': 'root', 'component': 'Sparkles'},
          ],
        },
        {
          'components': [
            {'id': 'main', 'component': 'HabitCheck'},
          ],
        },
        {
          'components': [
            {'id': 'root', 'component': 'Column', 'children': ['missing']},
          ],
        },
        {
          'components': [
            {'id': 'root', 'component': 'ReadAloudDrill'},
          ],
        },
        {
          'components': [
            {'id': 'root', 'component': 'MetricTrend', 'metric': 12},
          ],
        },
      ]) {
        expect(() => normalizeHabitSurface(bad), throwsA(isA<HabitSurfaceError>()), reason: '$bad');
        expect(isValidHabitSurface(bad), isFalse);
      }
    });
  });

  testWidgets('habit detail screen shows the surface, streak and consistency', (tester) async {
    final h = await state.upsertHabit(habitFromTemplate(waterTemplate, createdAt: DateTime.now()));
    await tester.pumpWidget(MaterialApp(home: HabitDetailScreen(state: state, habitId: h.id)));
    await tester.pump();
    expect(find.textContaining('Drink water'), findsOneWidget);
    expect(find.textContaining('Streak 0 days'), findsOneWidget);
    await tester.tap(find.byTooltip('More'));
    await tester.pump();
    expect(state.habitEntry(DateTime.now(), h.id).value, 1);
  });

  testWidgets('showDayEditor edits a past day: prayer, habit and wake', (tester) async {
    final h = await add(quranTemplate);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(onPressed: () => showDayEditor(context, state, day), child: const Text('open')),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Monday, 4 May'), findsOneWidget);

    await tester.tap(find.text('Isha'));
    await tester.pumpAndSettle();
    expect(state.logFor(day).prayers, {'Isha'});
    expect(state.logFor(day).prayerStatus['Isha'], 'onTime');

    await tester.tap(find.textContaining('Read Quran'));
    await tester.pumpAndSettle();
    expect(habitDone(entry(h), h), isTrue);

    await tester.tap(find.byTooltip('Set wake time'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(state.logFor(day).wakeAt, DateTime(2026, 5, 4, 5, 0));
  });
}
