import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_tracker/agent/habit_agent.dart';
import 'package:habit_tracker/agent/habit_catalog.dart';
import 'package:habit_tracker/agent/habit_surface.dart';
import 'package:habit_tracker/agent/habit_templates.dart';
import 'package:habit_tracker/app_state.dart';
import 'package:habit_tracker/habits/habit.dart';
import 'package:habit_tracker/logic/stats.dart';
import 'package:habit_tracker/services/openrouter.dart';
import 'package:habit_tracker/services/task_tools.dart';
import 'package:habit_tracker/widgets/assistant_chat.dart';

import 'support.dart';

const _validUi = {
  'components': [
    {'id': 'root', 'component': 'Column', 'children': ['tip', 'drill', 'timer', 'pace']},
    {'id': 'tip', 'component': 'PromptCard', 'title': 'Slow down', 'steps': ['Breathe in', 'Open your mouth wider']},
    {
      'id': 'drill',
      'component': 'ReadAloudDrill',
      'title': 'Meeting opener',
      'text': 'Good morning everyone, here is my update.',
      'targetWords': ['morning', 'update'],
    },
    {'id': 'timer', 'component': 'PracticeTimer', 'label': 'Practice', 'targetMinutes': {'@path': '/habit/target'}},
    {'id': 'pace', 'component': 'MetricTrend', 'metric': 'wpm', 'label': 'Pace'},
  ],
};

const _invalidUi = {
  'components': [
    {'id': 'root', 'component': 'Column', 'children': ['magic']},
    {'id': 'magic', 'component': 'HologramProjector', 'intensity': 11},
  ],
};

Map<String, dynamic> _createArgs(Map<String, dynamic> ui) => {
      'title': 'Speak clearly in meetings',
      'emoji': '🗣️',
      'kind': 'practice',
      'target': 10,
      'reminder': '8:30',
      'weekdays': ['mon', 'tue', 'wed', 'thu', 'fri'],
      'metric_fields': [
        {'key': 'wpm', 'label': 'Pace', 'unit': 'words/min'},
        {'key': 'fillers', 'label': 'Fillers', 'better': 'down'},
      ],
      'ui': ui,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime(2026, 5, 4, 9); // Monday
  late AppState state;

  setUp(() async {
    mockPlugins();
    state = await loadState();
  });

  HabitAgent agent(List<List<Map<String, dynamic>>> turns,
          {List<Map<String, dynamic>>? requests, List<HabitProposal>? proposals, List<ToolActivity>? activity}) =>
      HabitAgent(
        state,
        client: () => OpenRouterClient(apiKey: 'k', model: 'm', client: fakeModel(turns, requests)),
        clock: () => now,
        onProposal: proposals?.add,
        onActivity: activity?.add,
      );

  Map<String, dynamic> toolResult(List<ChatMessage> history, [int index = 0]) =>
      jsonDecode(history.where((m) => m.role == 'tool').elementAt(index).content) as Map<String, dynamic>;

  group('agent run with a fake model', () {
    test('a create_habit call with a valid surface creates the habit', () async {
      final requests = <Map<String, dynamic>>[];
      final history = [const ChatMessage('user', 'I mumble in meetings')];
      final reply = await agent([
        [toolCallDelta('create_habit', _createArgs(_validUi))],
        [
          {'content': 'I built a practice habit for you.'},
        ],
      ], requests: requests)
          .run(history, system: 'sys');

      expect(reply, 'I built a practice habit for you.');
      final h = state.habits.single;
      expect(h.title, 'Speak clearly in meetings');
      expect(h.kind, HabitKind.practice);
      expect(h.target, 10);
      expect(h.reminder, '08:30');
      expect(h.weekdays, [1, 2, 3, 4, 5]);
      expect(h.createdByAi, isTrue);
      expect(h.seq, 1);
      expect(h.metricFields.map((m) => m.key), ['wpm', 'fillers']);
      expect(h.metricFields.last.better, 'down');
      expect(isValidHabitSurface(h.uiSurface), isTrue);
      final components = (h.uiSurface!['createSurface'] as Map)['components'] as List;
      expect(components.map((c) => (c as Map)['component']),
          ['Column', 'PromptCard', 'ReadAloudDrill', 'PracticeTimer', 'MetricTrend']);
      expect((components[3] as Map)['catalogId'], habitCatalogId);
      expect((components[3] as Map)['minutes'], {'@path': '/minutes'}, reason: 'default binding added');
      expect(toolResult(history)['status'], 'created');

      // The model was given the tools and the A2UI catalog prompt.
      final names = (requests.first['tools'] as List).map((t) => (t as Map)['function']['name']).toSet();
      expect(names, containsAll([...habitToolNames, 'create_task', 'list_tasks']));
      final system = (requests.first['messages'] as List).first['content'] as String;
      expect(system, startsWith('sys'));
      expect(system, contains(habitCatalogId));
      for (final c in ['HabitCheck', 'Counter', 'PracticeTimer', 'ReadAloudDrill', 'PromptCard', 'RatingInput', 'MetricTrend', 'ChoiceChips']) {
        expect(system, contains(c));
      }
      expect(system, contains('@path'));
    });

    test('an invalid surface is rejected, nothing is saved, and the model can retry', () async {
      final history = [const ChatMessage('user', 'I mumble in meetings')];
      await agent([
        [toolCallDelta('create_habit', _createArgs(_invalidUi))],
        [toolCallDelta('create_habit', _createArgs(_validUi), id: 'call_2')],
        [
          {'content': 'Done.'},
        ],
      ]).run(history, system: 'sys');

      final first = toolResult(history, 0);
      expect(first['ok'], isFalse);
      expect(first['error'], contains('HologramProjector'));
      expect(first['error'], contains('Nothing was saved'));
      expect(toolResult(history, 1)['ok'], isTrue);
      expect(state.habits, hasLength(1));
      expect(isValidHabitSurface(state.habits.single.uiSurface), isTrue);
    });

    test('an invalid surface alone leaves no habit behind', () async {
      final history = [const ChatMessage('user', 'x')];
      await agent([
        [toolCallDelta('create_habit', _createArgs(_invalidUi))],
        [
          {'content': 'Sorry.'},
        ],
      ]).run(history, system: 'sys');
      expect(state.habits, isEmpty);
    });

    test('with a proposal handler the habit waits for the user', () async {
      final proposals = <HabitProposal>[];
      final history = [const ChatMessage('user', 'drink 2L water')];
      final a = agent([
        [
          toolCallDelta('create_habit', {'title': 'Drink water', 'kind': 'count', 'target': 8, 'unit': 'glasses'}),
        ],
        [
          {'content': 'Tap Add habit.'},
        ],
      ], proposals: proposals);
      await a.run(history, system: 'sys');
      expect(state.habits, isEmpty);
      expect(toolResult(history)['status'], 'proposed');
      final p = proposals.single;
      expect(isValidHabitSurface(p.habit.uiSurface), isTrue, reason: 'a default surface is generated');
      await a.habitTools.accept(p);
      expect(p.accepted, isTrue);
      expect(state.habits.single.title, 'Drink water');
    });

    test('task tools still work through the same agent', () async {
      final history = [const ChatMessage('user', 'remind me to call mum at 8pm')];
      await agent([
        [
          toolCallDelta('create_task', {'title': 'Call mum', 'time': '20:00', 'date': '2026-05-04'}),
        ],
        [
          {'content': 'Ok'},
        ],
      ]).run(history, system: 'sys');
      expect(state.tasks.single.title, 'Call mum');
      expect(state.habits, isEmpty);
    });
  });

  group('habit tools', () {
    late HabitTools tools;
    late List<ToolActivity> activity;
    Future<Map<String, dynamic>> run(String name, Map<String, dynamic> args) async =>
        jsonDecode(await tools.execute(ToolCall('c', name, jsonEncode(args)))) as Map<String, dynamic>;

    setUp(() {
      activity = [];
      tools = HabitTools(state, onActivity: activity.add, clock: () => now);
    });

    test('create validates fields', () async {
      expect((await run('create_habit', {'kind': 'check'}))['error'], contains('title'));
      expect((await run('create_habit', {'title': 'A'}))['error'], contains('kind'));
      expect((await run('create_habit', {'title': 'A', 'kind': 'dance'}))['error'], contains('kind'));
      expect((await run('create_habit', {'title': 'A', 'kind': 'count', 'target': -1}))['error'], contains('target'));
      expect((await run('create_habit', {'title': 'A', 'kind': 'check', 'reminder': '25:00'}))['error'], contains('HH:MM'));
      expect((await run('create_habit', {'title': 'A', 'kind': 'check', 'weekdays': ['funday']}))['error'], contains('funday'));
      expect(state.habits, isEmpty);
      expect((await run('nope', {}))['error'], contains('Unknown tool'));
    });

    test('create, list, log, history, update, set ui, archive, with undo', () async {
      final created = await run('create_habit', {'title': 'Drink water', 'kind': 'count', 'target': 8, 'unit': 'glasses'});
      final id = created['habit']['id'] as String;
      expect(activity.single.label, contains('Drink water'));

      final listed = await run('list_habits', {});
      expect(listed['today'], '2026-05-04');
      expect((listed['habits'] as List).single['done_today'], isFalse);

      var logged = await run('log_habit', {'id': id, 'add_value': 5});
      expect(logged['done'], isFalse);
      logged = await run('log_habit', {'id': id, 'add_value': 3, 'notes': 'hot day'});
      expect(logged['done'], isTrue);
      expect(state.habitEntry(now, id).value, 8);
      await run('log_habit', {'id': id, 'date': '2026-05-03', 'done': true, 'metrics': {'ml': 2000}});
      expect(state.habitEntry(DateTime(2026, 5, 3), id).metrics['ml'], 2000);
      expect((await run('log_habit', {'id': id, 'date': 'yesterday'}))['error'], contains('YYYY-MM-DD'));
      await activity.last.undo!();
      expect(state.habitEntry(DateTime(2026, 5, 3), id).isEmpty, isTrue);

      final history = await run('get_habit_history', {'id': id, 'days': 3});
      expect((history['days'] as List).map((d) => d['date']), ['2026-05-02', '2026-05-03', '2026-05-04']);
      expect((history['days'] as List).last['value'], 8);
      expect(history['habit']['streak'], 1);

      await run('update_habit', {'id': id, 'target': 10, 'title': 'Hydrate', 'streak_rule': 'strict'});
      expect(state.habitById(id)!.target, 10);
      expect(state.habitById(id)!.title, 'Hydrate');
      expect(state.habitById(id)!.streakRule, StreakRule.strict);
      expect(habitDone(state.habitEntry(now, id), state.habitById(id)!), isFalse);
      await activity.last.undo!();
      expect(state.habitById(id)!.target, 8);

      final before = jsonEncode(state.habitById(id)!.uiSurface);
      final bad = await run('set_habit_ui', {'id': id, 'ui': _invalidUi});
      expect(bad['ok'], isFalse);
      expect(jsonEncode(state.habitById(id)!.uiSurface), before, reason: 'an invalid UI never replaces a valid one');
      final badUpdate = await run('update_habit', {'id': id, 'title': 'Nope', 'ui': _invalidUi});
      expect(badUpdate['ok'], isFalse);
      expect(state.habitById(id)!.title, 'Drink water');

      final good = await run('set_habit_ui', {
        'id': id,
        'ui': {
          'components': [
            {'id': 'root', 'component': 'Counter', 'label': 'Glasses', 'target': {'@path': '/habit/target'}},
          ],
        },
      });
      expect(good['ok'], isTrue);
      expect(jsonEncode(state.habitById(id)!.uiSurface), isNot(before));

      await run('archive_habit', {'id': id});
      expect(state.activeHabits, isEmpty);
      expect(((await run('list_habits', {'include_archived': true}))['habits'] as List).single['archived'], isTrue);
      await run('archive_habit', {'id': id, 'archived': false});
      expect(state.activeHabits, hasLength(1));

      for (final name in ['update_habit', 'set_habit_ui', 'archive_habit', 'log_habit', 'get_habit_history']) {
        expect((await run(name, {'id': 'missing', 'ui': _validUi}))['error'], contains('list_habits'), reason: name);
      }
    });
  });

  test('splitInlineA2ui pulls surfaces the model wrote into its reply', () {
    expect(splitInlineA2ui('Just text.').$1, 'Just text.');
    expect(splitInlineA2ui('Just text.').$2, isEmpty);
    final block = jsonEncode([surfaceMessage(waterTemplate.components, surfaceId: 's1')]);
    final (text, surfaces) = splitInlineA2ui('Here you go.\n<a2ui-json>$block</a2ui-json>');
    expect(text, 'Here you go.');
    expect(surfaces.single.first['component'], 'Column');
    final (broken, none) = splitInlineA2ui('Oops <a2ui-json>[{"nope":');
    expect(broken, 'Oops');
    expect(none, isEmpty);
  });

  testWidgets('the chat previews a proposed habit inline and "Add habit" saves it', (tester) async {
    tester.view.physicalSize = const Size(420, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await state.setApiKey('k');
    final chat = AssistantChat(
      state,
      systemPrompt: () => 'sys',
      client: () => OpenRouterClient(
        apiKey: 'k',
        model: 'm',
        client: fakeModel([
          [
            toolCallDelta('create_habit', {
              'title': 'Drink water',
              'emoji': '💧',
              'kind': 'count',
              'target': 8,
              'unit': 'glasses',
              'ui': {
                'components': [
                  {'id': 'root', 'component': 'Counter', 'label': 'Glasses', 'unit': 'glasses', 'target': {'@path': '/habit/target'}},
                ],
              },
            }),
          ],
          [
            {'content': 'Here is a water habit. Tap Add habit to keep it.'},
          ],
        ]),
      ),
    );
    addTearDown(chat.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: AssistantChatView(chat: chat, hint: 'Ask', maxHeight: 2000))),
    ));
    await tester.runAsync(() => chat.send('I want to drink 2L of water a day'));
    await tester.pump();

    expect(find.textContaining('Here is a water habit'), findsOneWidget);
    expect(find.text('💧  Drink water'), findsOneWidget);
    expect(find.byType(HabitSurface), findsOneWidget);
    expect(find.text('0 / 8 glasses'), findsOneWidget);
    expect(state.habits, isEmpty, reason: 'only a preview so far');

    await tester.tap(find.byTooltip('More'));
    await tester.pump();
    expect(find.text('1 / 8 glasses'), findsOneWidget, reason: 'the preview is interactive');
    expect(state.logs, isEmpty, reason: 'previews are not persisted');

    await tester.tap(find.text('Add habit'));
    await tester.pump();
    expect(state.habits.single.title, 'Drink water');
    expect(state.habits.single.createdByAi, isTrue);
    expect(find.textContaining('Added.'), findsOneWidget);
    expect(find.text('Add habit'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
