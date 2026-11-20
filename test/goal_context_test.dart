import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:habit_tracker/agent/goal_tools.dart';
import 'package:habit_tracker/app_state.dart';
import 'package:habit_tracker/goals/goal.dart';
import 'package:habit_tracker/goals/goal_okf.dart';
import 'package:habit_tracker/goals/goals_card.dart';
import 'package:habit_tracker/logic/stats.dart';
import 'package:habit_tracker/habits/habit.dart';
import 'package:habit_tracker/screens/chat_screen.dart';
import 'package:habit_tracker/services/openrouter.dart';
import 'package:habit_tracker/widgets/document_viewer.dart';

import 'support.dart';

Future<(AppState, Goal)> businessGoal() async {
  final s = await loadState({'settings.v1': jsonEncode({'onboarded': true})});
  final now = DateTime.now();
  final tools = GoalTools(s, clock: () => now);
  await tools.execute(
    ToolCall(
      'c',
      'create_goal',
      jsonEncode({
        'title': 'Launch the bakery shop',
        'why': 'More orders without the phone ringing all day',
        'end_date': dayKey(now.add(const Duration(days: 42))),
        'milestones': [
          {'title': 'Shop live', 'due': dayKey(now.add(const Duration(days: 3)))},
        ],
        'habits': [
          {
            'title': 'Shop build',
            'steps': ['Open the laptop', 'Do the session', 'Note what is next'],
            'done_when': 'The session item is finished',
            'minutes': 45,
            'sessions': ['List 20 best sellers', 'Photograph 5 products', 'Write descriptions'],
          },
        ],
        'tasks': [
          {
            'title': 'Register the domain',
            'date': dayKey(now.add(const Duration(days: 2))),
            'steps': ['Pick a name', 'Pay'],
            'done_when': 'The domain is yours',
          },
        ],
      }),
    ),
  );
  return (s, s.goals.single);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(mockPlugins);

  test('a business goal plans each day: sessions move on, dated tasks and milestones land on their day', () async {
    final (s, g) = await businessGoal();
    final today = dateOnly(DateTime.now());
    final h = s.habits.firstWhere((h) => h.title == 'Shop build');
    expect(h.guide!.sessions, hasLength(3));
    expect(g.habitIds, [h.id]);

    String plan(int days) => goalPlanFor(s, g, today.add(Duration(days: days))).map((i) => '${i.title}|${i.detail}').join(', ');
    expect(plan(0), 'Shop build|Session 1/3: List 20 best sellers');
    expect(plan(1), 'Shop build|Session 2/3: Photograph 5 products');
    expect(plan(2), contains('Register the domain'));
    expect(plan(2), contains('Session 3/3'));
    expect(plan(3), contains('Milestone: Shop live'));
    expect(plan(3), contains('All planned sessions covered'));

    await s.logHabit(today, h.id, HabitEntry(done: true));
    expect(goalPlanFor(s, g, today).single.done, isTrue);
    expect(plan(1), contains('Session 2/3'), reason: 'today done: tomorrow still the next one');
  });

  test('the goal context is an OKF document and the bundle has index, log and goal files', () async {
    final (s, g) = await businessGoal();
    final tools = GoalTools(s);
    await tools.execute(ToolCall('u', 'update_goal', jsonEncode({'id': g.id, 'add_note': 'Supplier is Al Noor flour'})));
    expect(g.notes, contains('Supplier is Al Noor flour'));
    expect(Goal.fromJson(g.toJson()).notes, g.notes);

    final doc = goalOkf(s, g, DateTime.now());
    expect(doc, startsWith('---\ntype: Goal\ntitle: "Launch the bakery shop"\n'));
    final (front, body) = splitFrontmatter(doc);
    expect(front['type'], 'Goal');
    expect(front['description'], contains('More orders'));
    expect(front['timestamp'], isNotEmpty);
    expect(body, contains('## Milestones'));
    expect(body, contains('- [ ] 1. List 20 best sellers ← today'));
    expect(body, contains('## Plan for the next 7 days'));
    expect(body, contains('Supplier is Al Noor flour'));

    final bundle = okfBundle(s, DateTime.now());
    expect(bundle.keys, containsAll(['index.md', 'log.md', 'goals/launch-the-bakery-shop.md']));
    expect(bundle['index.md'], contains('(goals/launch-the-bakery-shop.md)'));
  });

  test('each goal has its own chat with its context loaded', () async {
    final (s, g) = await businessGoal();
    final chat = AgUiChat(s);
    expect(chat.systemPrompt, isNot(contains(goalChatPrompt)));
    chat.openGoal(g.id);
    expect(chat.goal, g);
    expect(chat.systemPrompt, contains(goalChatPrompt));
    expect(chat.systemPrompt, contains('List 20 best sellers ← today'));
    chat.history.add(ChatMessage('user', 'What today?'));
    final goalThread = chat.threadId;
    chat.newChat();
    expect(chat.goal, isNull);
    expect(chat.threads.single.goalId, g.id);

    final reloaded = AgUiChat(s);
    reloaded.openGoal(g.id);
    expect(reloaded.threadId, goalThread);
    expect(reloaded.items.single.text, 'What today?');
  });

  testWidgets('goal page shows the next days and opens its context in the viewer', (tester) async {
    final (s, g) = await businessGoal();
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: GoalScreen(state: s, goalId: g.id)));
    await tester.pump();
    expect(find.text('Next 14 days'), findsOneWidget);
    expect(find.text('Session 2/3: Photograph 5 products'), findsOneWidget);
    expect(find.text('Milestone: Shop live'), findsOneWidget);

    await tester.tap(find.byKey(const Key('goal-context')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('doc-frontmatter')), findsOneWidget);
    expect(find.text('type: Goal'), findsOneWidget);
    expect(find.byKey(const Key('doc-md')), findsOneWidget);
    await tester.tap(find.byKey(const Key('doc-source')));
    await tester.pump();
    expect(find.textContaining('## Milestones'), findsOneWidget);
  });

  testWidgets('the viewer draws HTML without running scripts', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: DocumentViewer(title: 'Page', fileName: 'page.html', text: '<html><body><h1>Hello</h1><script>alert(1)</script></body></html>'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(HtmlWidget), findsOneWidget);
    expect(find.textContaining('Hello', findRichText: true), findsWidgets);
    expect(find.textContaining('alert', findRichText: true), findsNothing);
    expect(looksLikeHtml('notes.md', '# Hi'), isFalse);
  });
}
