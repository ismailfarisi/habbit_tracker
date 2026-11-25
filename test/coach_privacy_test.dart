import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_tracker/agent/coach_access.dart';
import 'package:habit_tracker/agent/finance_tools.dart';
import 'package:habit_tracker/app_state.dart';
import 'package:habit_tracker/finance/finance.dart';
import 'package:habit_tracker/goals/goal.dart';
import 'package:habit_tracker/habits/habit.dart';
import 'package:habit_tracker/screens/chat_screen.dart';
import 'package:habit_tracker/services/openrouter.dart';
import 'package:habit_tracker/services/task_tools.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support.dart';

const key = 'sk-or-v1-synthetic-test-key-0001';

Goal goal(String id, String title) =>
    Goal(id: id, title: title, start: '2026-11-01', end: '2026-12-31');

Future<AppState> seeded() async {
  final state = await loadState();
  state.apiKey = key;
  state.goals.addAll([goal('q', 'Quran plan'), goal('j', 'Private career plan')]);
  state.goals.last.habitIds.add('h');
  state.habits.add(HabitDef(id: 'h', title: 'Interview rehearsal'));
  state.finance.debts.add(Debt(person: 'Fictional Lender', amount: 12345));
  state.finance.zakat
    ..cash = 987654
    ..silverPricePerGram = 100;
  return state;
}

AgUiChat scripted(AppState state, List<List<Map<String, dynamic>>> turns, List<Map<String, dynamic>> requests) {
  final mock = fakeModel(turns, requests);
  return AgUiChat(state, client: () => OpenRouterClient(apiKey: key, model: 'mock', client: mock));
}

List<Map<String, dynamic>> reply(String text) => [{'content': text}];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(mockPlugins);

  test('the selected goal scopes both the outgoing prompt and provider tool calls', () async {
    final s = await seeded();
    final asks = <Map<String, dynamic>>[];
    final chat = scripted(s, [
      [toolCallDelta('money_summary', {})],
      [toolCallDelta('list_goals', {})],
      [toolCallDelta('list_habits', {})],
      [toolCallDelta('archive_habit', {'id': 'h'})],
      [toolCallDelta('update_goal', {'id': 'q', 'link_habit_ids': ['h']})],
      [toolCallDelta('add_debt', {'person': 'provider entry', 'amount': 500})],
      reply('Read your next passage.'),
    ], asks)..openGoal('q');
    await chat.send('Which passage today?', review: (_) => fail('unshared changes must be blocked before review'));
    expect(asks, hasLength(7));
    final bodies = jsonEncode(asks);
    expect(bodies, contains('Quran plan'));
    for (final secret in ['Fictional Lender', 'net wealth', 'Private career plan', 'Interview rehearsal']) {
      expect(bodies, isNot(contains(secret)));
    }
    expect(s.habits.single.archived, isFalse);
    expect(s.goals.first.habitIds, isEmpty);
    expect(s.finance.debts.length, 1);
    final advertised = (asks.first['tools'] as List).map((t) => t['function']['name']);
    expect(advertised, isNot(contains('money_summary')));
    expect(advertised, isNot(contains('update_zakat')));
  });

  test('Money totals are redacted on every call; sharing expires on switching and reopening', () async {
    final s = await seeded();
    final asks = <Map<String, dynamic>>[];
    final chat = scripted(s, [
      [toolCallDelta('money_summary', {})],
      reply('Summary for this month.'),
      reply('Next answer.'),
    ], asks)
      ..share(money: CoachMoney.totals, planner: false, otherGoals: {'j'});
    await chat.send('Summarise the month');
    final sent = jsonEncode(asks);
    expect(sent, contains('Money this month'));
    expect(sent, contains('Private career plan'));
    expect(sent, isNot(contains('Fictional Lender')));
    expect(sent, isNot(contains('net wealth')));
    final original = chat.threadId;
    chat.newChat();
    await chat.send('Quran question');
    expect(jsonEncode(asks.last), isNot(contains('Summarise the month')));
    chat.open(original);
    expect(chat.items.first.text, 'Summarise the month');
    await chat.send('Only this question');
    expect(jsonEncode(asks.last), isNot(contains('Private career plan')));
    expect(jsonEncode(asks.last), isNot(contains('Summary for this month')));
    expect(jsonEncode(asks.last), isNot(contains('Money this month')));
  });

  test('legacy transcripts stay local and named finance details require a separate choice', () async {
    final s = await seeded();
    await s.storage.prefs.setString('chat.v1', jsonEncode([
      {'role': 'user', 'content': 'Old conversation'},
      {'role': 'assistant', 'content': 'Fictional Lender secret in older reply'},
    ]));
    final asks = <Map<String, dynamic>>[];
    final chat = scripted(s, [reply('Answer')], asks);
    expect(chat.items.last.text, contains('Fictional Lender'));
    await chat.send('New question');
    expect(jsonEncode(asks.single), isNot(contains('Fictional Lender')));
    chat.share(money: CoachMoney.details, planner: false, otherGoals: {});
    await chat.send('Help with this debt');
    expect(jsonEncode(asks.last), contains('Fictional Lender'));
    chat.share(money: CoachMoney.none, planner: false, otherGoals: {});
    await chat.send('Return to my plan');
    expect(jsonEncode(asks.last), isNot(contains('Fictional Lender')));
    expect(jsonEncode(asks.last), isNot(contains('Help with this debt')));
  });

  test('planner sharing excludes unshared goal check-ins and cannot remove a private pin', () async {
    final s = await seeded();
    s.settings.todayPinned = ['goal-j'];
    await s.logHabit(DateTime.now(), 'h', HabitEntry(done: true));
    final requests = <Map<String, dynamic>>[];
    final chat = scripted(s, [
      [toolCallDelta('get_stats', {})],
      [toolCallDelta('customize_today', {'pin': ['wake']})],
      reply('Done.'),
    ], requests)..share(money: CoachMoney.none, planner: true, otherGoals: {});
    await chat.send('Show activity', review: (_) => fail('Private pins should be protected'));
    expect(s.settings.todayPinned, ['goal-j']);
    final stats = jsonDecode(chat.items.firstWhere((i) => i.toolName == 'get_stats').result!);
    expect(stats['last7']['habitCheckIns'], 0);
    expect(jsonEncode(requests), isNot(contains('goal-j')));
  });

  test('habit undo preserves concurrent field edits and expires when the record leaves scope', () async {
    final s = await seeded();
    final chat = scripted(s, [
      [toolCallDelta('update_habit', {'id': 'h', 'title': 'New title'})],
      reply('Updated.'),
      [toolCallDelta('update_habit', {'id': 'h', 'title': 'Later title'})],
      reply('Updated again.'),
    ], [])..openGoal('j');
    await chat.send('Rename practice', review: (_) async => true);
    await s.upsertHabit(s.habits.single.copy()..unit = 'local edit');
    final first = chat.items.singleWhere((i) => i.kind == 'tool');
    await chat.undo(first, first.activities.single);
    expect(s.habits.single.title, 'Interview rehearsal');
    expect(s.habits.single.unit, 'local edit');
    await chat.send('Rename again', review: (_) async => true);
    final last = chat.items.lastWhere((i) => i.kind == 'tool');
    s.goals.last.habitIds.clear();
    s.goals.first.habitIds.add('h');
    await chat.undo(last, last.activities.single);
    expect(s.habits.single.title, 'Later title');
  });

  test('undoing a logged metric preserves practice notes and later metrics', () async {
    final s = await seeded();
    final chat = scripted(s, [
      [toolCallDelta('log_habit', {'id': 'h', 'date': '2026-11-25', 'metrics': {'pages': 2}})],
      reply('Recorded.'),
    ], [])..openGoal('j');
    await chat.send('Record two pages', review: (_) async => true);
    final day = DateTime(2026, 11, 25);
    final entry = s.habitEntry(day, 'h').copy()..notes = 'Local note';
    entry.metrics['seconds'] = 30;
    await s.logHabit(day, 'h', entry);
    final receipt = chat.items.singleWhere((i) => i.kind == 'tool');
    await chat.undo(receipt, receipt.activities.single);
    expect(s.habitEntry(day, 'h').metrics, {'seconds': 30});
    expect(s.habitEntry(day, 'h').notes, 'Local note');
  });

  test('a malformed item in a reviewed plan is rejected before creating any tasks', () async {
    final s = await seeded();
    final chat = scripted(s, [
      [toolCallDelta('create_goal', {
        'title': 'Study', 'end_date': '2026-12-01',
        'tasks': [{'title': 'Read first'}, {'title': 'Read next', 'minutes': 'invalid'}],
      })],
      reply('Please correct the plan.'),
    ], []);
    await chat.send('Build my plan', review: (_) async => true);
    expect(s.tasks, isEmpty);
    expect(s.goals, hasLength(2));
    expect(chat.items.firstWhere((i) => i.kind == 'tool').result, contains('Invalid plan'));
  });

  test('a failed final reply retains the task receipt and retry is text-only after restart', () async {
    final s = await seeded();
    var step = 0;
    final provider = MockClient.streaming((req, body) async {
      if (step++ == 0) return sse([toolCallDelta('create_task', {'title': 'Study review'})]);
      return http.StreamedResponse(Stream.value(utf8.encode('{}')), 503);
    });
    final chat = AgUiChat(s, client: () => OpenRouterClient(apiKey: key, model: 'm', client: provider));
    await chat.send('Schedule study', review: (_) async => true);
    expect(s.tasks.single.title, 'Study review');
    expect(chat.failure, contains('503'));
    final asks = <Map<String, dynamic>>[];
    final reopened = scripted(s, [
      [toolCallDelta('create_task', {'title': 'Study review'}, id: 'repeat')],
      reply('The study task is saved.'),
    ], asks);
    expect(reopened.draft, 'Schedule study');
    final receipt = reopened.items.singleWhere((i) => i.kind == 'tool');
    expect(receipt.activities.single.label, contains('Study review'));
    await reopened.send(reopened.draft, review: (_) => fail('retry must not permit new changes'));
    expect(s.tasks, hasLength(1));
    expect(reopened.draft, isEmpty);
    expect(reopened.failure, isNull);
    expect(asks.first.containsKey('tools'), isFalse);
    expect(jsonEncode(asks.first['messages']), contains('Study review'));
  });

  test('a full batch is previewed before the first write, and cancellation leaves every item alone', () async {
    final s = await seeded();
    final chat = scripted(s, [
      [{'tool_calls': [
        {'index': 0, 'id': 'a', 'function': {'name': 'create_task', 'arguments': '{"title":"A"}'}},
        {'index': 1, 'id': 'b', 'function': {'name': 'create_task', 'arguments': '{"title":"B"}'}},
      ]}],
      reply('Cancelled.'),
    ], []);
    var previews = 0;
    await chat.send('Plan two tasks', review: (calls) async {
      previews++;
      expect(calls.map((c) => c.id), ['a', 'b']);
      expect(s.tasks, isEmpty);
      return false;
    });
    expect(previews, 1);
    expect(s.tasks, isEmpty);
    expect(chat.items.where((i) => i.result?.contains('not approved') == true), hasLength(2));
  });

  test('restore during review invalidates subsequent writes and prevents stale draft saves', () async {
    final s = await seeded();
    final chat = scripted(s, [[toolCallDelta('create_task', {'title': 'Old task'})]], []);
    final preview = Completer<void>();
    final decision = Completer<bool>();
    final pending = chat.send('Add task', review: (_) {
      preview.complete();
      return decision.future;
    });
    await preview.future;
    s.dataGeneration++;
    await s.storage.prefs.remove('chat.threads.v1');
    decision.complete(true);
    await pending;
    expect(s.tasks, isEmpty);
    expect(s.storage.prefs.getString('chat.threads.v1'), isNull);
  });

  test('Settings undo changes only the approved keys and preserves later edits', () async {
    final s = await seeded();
    final activities = <ToolActivity>[];
    final original = s.settings.themeMode;
    await FinanceTools(s, onActivity: activities.add).execute(
      const ToolCall('theme', 'update_settings', '{"changes":{"themeMode":"dark"}}'),
    );
    const later = TimeOfDay(hour: 9, minute: 15);
    await s.updateSettings((s) => s.wakeTime = later);
    await activities.single.undo!();
    expect(s.settings.themeMode, original);
    expect(s.settings.wakeTime, later);
  });
  testWidgets('cross-screen requests with a key stage editable drafts in their own threads', (tester) async {
    final s = await seeded();
    final asks = <Map<String, dynamic>>[];
    final chat = scripted(s, [reply('Got it.')], asks)..openGoal('j');
    chat.setDraft('Private earlier draft');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ChatScreen(state: s, chat: chat))));
    s.chatPrompt.value = const ChatRequest('Detailed source passage', display: 'Short label', goalId: 'q');
    await tester.pump();
    expect(chat.goalId, 'q');
    expect(asks, isEmpty);
    final input = find.byKey(const Key('chat-input'));
    expect(tester.widget<TextField>(input).controller!.text, 'Detailed source passage');
    await tester.enterText(input, 'Edited passage question');
    await tester.pump();
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pumpAndSettle();
    expect(asks, hasLength(1));
    expect(jsonEncode(asks.single), contains('Edited passage question'));
    expect(jsonEncode(asks.single), isNot(contains('Detailed source passage')));
    expect(jsonEncode(asks.single), isNot(contains('Private earlier draft')));
    s.chatPrompt.value = const ChatRequest('General question');
    await tester.pump();
    expect(chat.goalId, isNull);
    expect(chat.draft, 'General question');
    expect(chat.history, isEmpty);
    expect(asks, hasLength(1));
  });

  testWidgets('saved history and failed drafts can be opened, edited and deleted without credentials', (tester) async {
    final s = await seeded();
    final chat = scripted(s, [reply('Kept on this phone.')], [])..openGoal('q');
    await chat.send('First question');
    final id = chat.threadId;
    await s.setApiKey('');
    await chat.send('Unsent follow-up');
    chat.newChat();
    final offline = AgUiChat(s);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ChatScreen(state: s, chat: offline))));
    await tester.tap(find.byTooltip('History'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('thread-$id')));
    await tester.pumpAndSettle();
    expect(find.text('Quran plan'), findsOneWidget);
    expect(find.textContaining('Kept on this phone.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    final input = find.byKey(const Key('chat-input'));
    expect(tester.widget<TextField>(input).controller!.text, 'Unsent follow-up');
    await tester.enterText(input, 'Edited offline');
    await tester.pump();
    expect(AgUiChat(s).draft, 'Edited offline');
    await tester.tap(find.byTooltip('History'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Delete chat'));
    await tester.pumpAndSettle();
    expect(find.text('No past chats yet.'), findsOneWidget);
    expect(AgUiChat(s).threads, isEmpty);
  });

}
