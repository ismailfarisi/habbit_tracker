import 'dart:convert';

import 'package:ag_ui/ag_ui.dart' as agui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_tracker/agent/agui_agent.dart';
import 'package:habit_tracker/agent/goal_tools.dart';
import 'package:habit_tracker/app_state.dart';
import 'package:habit_tracker/goals/goal.dart';
import 'package:habit_tracker/goals/goals_card.dart';
import 'package:habit_tracker/screens/home_screen.dart';
import 'package:habit_tracker/habits/habit.dart';
import 'package:habit_tracker/services/openrouter.dart';
import 'package:habit_tracker/services/task_tools.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(mockPlugins);

  final now = DateTime(2026, 11, 19, 9);
  Future<AppState> state() => loadState({'settings.v1': jsonEncode({'onboarded': true})});
  ToolCall call(String name, Map<String, dynamic> args) => ToolCall('c', name, jsonEncode(args));

  test('a goal round-trips through JSON', () {
    final g = Goal(
      id: 'g1',
      title: 'Memorise Juz Amma',
      why: 'To pray with it',
      start: '2026-11-19',
      end: '2027-05-19',
      cadence: ReviewCadence.monthly,
      milestones: [Milestone(id: 'm1', title: 'Last 10 surahs', due: '2026-12-31', done: true)],
      taskIds: ['t1'],
      habitIds: ['h1'],
      reviews: [GoalReview(at: now, summary: 'Good start', suggestions: ['Add Sunday revision'], applied: {0})],
    );
    final back = Goal.fromJson(jsonDecode(jsonEncode(g.toJson())) as Map<String, dynamic>);
    expect(back.toJson(), g.toJson());
    expect(back.horizon, '6 months');
    expect(back.progress(const []), 1.0);
  });

  test('cadence fits the length and reviews come due', () {
    expect(cadenceFor(7), ReviewCadence.weekly);
    expect(cadenceFor(180), ReviewCadence.monthly);
    expect(cadenceFor(730), ReviewCadence.quarterly);
    final g = Goal(id: 'g', title: 'x', start: '2026-11-01', end: '2026-11-08');
    expect(g.horizon, 'This week');
    expect(g.reviewDue(DateTime(2026, 11, 7)), isFalse);
    expect(g.reviewDue(DateTime(2026, 11, 8)), isTrue);
    g.reviews.add(GoalReview(at: DateTime(2026, 11, 8), summary: 'ok'));
    expect(g.reviewDue(DateTime(2026, 11, 9)), isFalse);
  });

  test('create_goal adds milestones and linked tasks, and undo removes them', () async {
    final s = await state();
    final acts = <ToolActivity>[];
    final tools = GoalTools(s, onActivity: acts.add, clock: () => now);
    final res = jsonDecode(
      await tools.execute(
        call('create_goal', {
          'title': 'Memorise Juz Amma',
          'why': 'Recite it in salah',
          'end_date': '2027-05-19',
          'milestones': [
            {'title': 'An-Nas to Al-Kawthar', 'due': '2026-12-31'},
            {'title': 'Up to Ad-Duha'},
          ],
          'tasks': [
            {'title': 'Learn 3 ayat after Fajr', 'repeat': 'daily', 'date': '2026-11-20', 'time': '6:00'},
          ],
        }),
      ),
    ) as Map<String, dynamic>;
    expect(res['ok'], isTrue);
    final g = s.goals.single;
    expect(g.cadence, ReviewCadence.monthly);
    expect(g.milestones.map((m) => m.title), ['An-Nas to Al-Kawthar', 'Up to Ad-Duha']);
    final t = s.taskById(g.taskIds.single)!;
    expect(t.time, '06:00');
    expect(t.createdByAi, isTrue);
    expect(s.storage.loadGoals().single.id, g.id);
    expect(goalsContext(s, now), contains('Memorise Juz Amma'));

    await acts.single.undo!();
    expect(s.goals, isEmpty);
    expect(s.tasks, isEmpty);
  });

  test('update_goal and save_goal_review, with undo restoring the goal', () async {
    final s = await state();
    final acts = <ToolActivity>[];
    final tools = GoalTools(s, onActivity: acts.add, clock: () => now);
    await tools.execute(
      call('create_goal', {
        'title': 'Walk daily',
        'end_date': '2026-11-26',
        'milestones': [
          {'title': 'Week one'},
        ],
      }),
    );
    final g = s.goals.single;
    expect(g.cadence, ReviewCadence.weekly);
    await tools.execute(
      call('update_goal', {
        'id': g.id,
        'end_date': '2026-12-03',
        'milestones_done': [g.milestones.single.id],
        'add_tasks': [
          {'title': 'Walk 20 min', 'repeat': 'daily'},
        ],
      }),
    );
    expect(g.end, '2026-12-03');
    expect(g.progress(s.tasks), 1.0);
    expect(g.taskIds, hasLength(1));

    await acts.last.undo!();
    final restored = s.goalById(g.id)!;
    expect(restored.end, '2026-11-26');
    expect(restored.milestones.single.done, isFalse);
    expect(s.tasks, isEmpty);

    await tools.execute(
      call('save_goal_review', {
        'id': g.id,
        'summary': 'You showed up 4 days, well done.',
        'suggestions': ['Walk after Asr instead', ''],
      }),
    );
    expect(s.goalById(g.id)!.reviews.single.suggestions, ['Walk after Asr instead']);
    final err = jsonDecode(await tools.execute(call('update_goal', {'id': 'nope'}))) as Map;
    expect(err['error'], contains('list_goals'));
  });

  test('goals are part of backups', () async {
    final s = await state();
    await s.upsertGoal(Goal(id: 'g1', title: 'Save 1000', start: '2026-11-19', end: '2027-11-19'));
    final backup = s.storage.exportJson();
    await s.deleteGoal('g1');
    await s.importBackup(backup);
    expect(s.goals.single.title, 'Save 1000');
  });

  test('the planner prompt knows about goals and avoids guilt', () {
    expect(plannerSystemPrompt, contains('personal Islamic'));
    expect(plannerSystemPrompt, contains('consistency, not'));
    expect(goalsPrompt, contains('create_goal'));
    expect(goalsPrompt, contains('save_goal_review'));
  });

  testWidgets('Goals card shows progress, and Review opens Chat with the prompt', (tester) async {
    final s = await state();
    await s.upsertGoal(
      Goal(
        id: 'g1',
        title: 'Read Seerah',
        start: '2026-01-01',
        end: '2026-12-31',
        milestones: [Milestone(id: 'm', title: 'Part 1', done: true), Milestone(id: 'n', title: 'Part 2')],
      ),
    );
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: GoalsCard(state: s)))));
    expect(find.text('Goals · 1'), findsOneWidget);
    expect(find.textContaining('1 of 2 milestones'), findsOneWidget);
    await tester.tap(find.text('Review'));
    expect(s.requestedTab.value, HomeScreen.chatTab);
    expect(s.chatPrompt.value!.text, contains('id g1'));

    await tester.tap(find.byKey(const ValueKey('goal-g1')));
    await tester.pumpAndSettle();
    expect(find.text('Part 2'), findsOneWidget);
    await tester.tap(find.text('Part 2'));
    await tester.pump();
    expect(s.goalById('g1')!.milestonesDone, 2);
  });

  testWidgets('empty Goals card invites a new goal', (tester) async {
    final s = await state();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: GoalsCard(state: s))));
    expect(find.textContaining('first practice'), findsOneWidget);
    await tester.tap(find.byKey(const Key('new-goal')));
    await tester.pumpAndSettle();
    expect(s.chatPrompt.value, isNull);
    expect(s.goals, isEmpty);
    await tester.enterText(find.byKey(const Key('goal-outcome')), 'Launch the shop');
    await tester.enterText(find.byKey(const Key('goal-practice')), 'List one product');
    final save = find.widgetWithText(FilledButton, 'Create goal');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    final goal = s.goals.single;
    final (habits, _) = GoalTodayCard.itemsFor(s, goal, DateTime.now());
    expect(habits.single.title, 'List one product');
    expect(s.goalFor(habits.single.id)?.id, goal.id);
    await s.logHabit(DateTime.now(), habits.single.id, HabitEntry(done: true));
    expect(s.chatPrompt.value, isNull);
    expect(s.storage.loadGoals().single.habitIds, goal.habitIds);
  });

  test('chat creates a goal through the AG-UI agent', () async {
    final s = await state();
    var calls = 0;
    String sse(Map<String, dynamic> d) => 'data: ${jsonEncode({'choices': [{'delta': d}]})}\n\ndata: [DONE]\n\n';
    final client = MockClient.streaming((req, body) async {
      final text = calls++ == 0
          ? sse({
              'tool_calls': [
                {
                  'index': 0,
                  'id': 'g1',
                  'function': {
                    'name': 'create_goal',
                    'arguments': jsonEncode({'title': 'Lose 5 kg', 'end_date': '2027-02-01'}),
                  },
                },
              ],
            })
          : sse({'content': 'Your goal is set.'});
      return http.StreamedResponse(Stream.value(utf8.encode(text)), 200);
    });
    final agent = LocalAgUiAgent(s, client: () => OpenRouterClient(apiKey: 'sk-or-v1-synthetic-test-key-0001', model: 'm', client: client));
    final events = await agent
        .run(threadId: 't', history: [const ChatMessage('user', 'Lose 5 kg by Ramadan')], system: 'sys')
        .toList();
    final start = events.whereType<agui.ToolCallStartEvent>().single;
    expect(start.toolCallName, 'create_goal');
    expect(events.whereType<agui.ToolCallResultEvent>().single.content, contains('"ok":true'));
    expect(s.goals.single.title, 'Lose 5 kg');
    expect(agent.activities['g1'], isNotNull);
  });
}
