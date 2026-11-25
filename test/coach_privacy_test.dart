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
}
