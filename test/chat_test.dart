import 'dart:convert';

import 'package:ag_ui/ag_ui.dart' as agui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_tracker/agent/agui_agent.dart';
import 'package:habit_tracker/app_state.dart';
import 'package:habit_tracker/screens/chat_screen.dart';
import 'package:habit_tracker/services/openrouter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support.dart';

String _sse(List<Map<String, dynamic>> deltas) =>
    '${deltas.map((d) => 'data: ${jsonEncode({'choices': [{'delta': d}]})}\n\n').join()}data: [DONE]\n\n';

/// First request: the model calls create_task; second: it replies in text.
OpenRouterClient Function() fakeModel() {
  var calls = 0;
  final client = MockClient.streaming((req, body) async {
    final first = calls++ == 0;
    final text = first
        ? _sse([
            {
              'tool_calls': [
                {
                  'index': 0,
                  'id': 'call1',
                  'function': {'name': 'create_task', 'arguments': '{"title":"Call mum","date":"2026-11-18","time":"20:00"}'},
                },
              ],
            },
          ])
        : _sse([
            {'content': 'Added '},
            {'content': 'it.'},
          ]);
    return http.StreamedResponse(Stream.value(utf8.encode(text)), 200);
  });
  return () => OpenRouterClient(apiKey: 'k', model: 'm', client: client);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(mockPlugins);

  Future<AppState> state() async {
    final s = await loadState({'settings.v1': jsonEncode({'onboarded': true})});
    s.apiKey = 'k';
    return s;
  }

  test('the local agent emits AG-UI run, tool call and text events', () async {
    final s = await state();
    final agent = LocalAgUiAgent(s, client: fakeModel());
    final events = await agent
        .run(threadId: 't', history: [const ChatMessage('user', 'Remind me to call mum tomorrow at 8pm')], system: 'sys')
        .toList();
    expect(events.map((e) => e.runtimeType), [
      agui.RunStartedEvent,
      agui.ToolCallStartEvent,
      agui.ToolCallArgsEvent,
      agui.ToolCallEndEvent,
      agui.ToolCallResultEvent,
      agui.TextMessageStartEvent,
      agui.TextMessageContentEvent,
      agui.TextMessageContentEvent,
      agui.TextMessageEndEvent,
      agui.RunFinishedEvent,
    ]);
    expect((events[1] as agui.ToolCallStartEvent).toolCallName, 'create_task');
    expect(s.tasks.single.title, 'Call mum');
    expect(agent.activities['call1'], isNotEmpty);
  });

  testWidgets('Chat tab: tool card with Undo, streamed reply, history saved', (tester) async {
    late AppState s;
    await tester.runAsync(() async => s = await state());
    final chat = AgUiChat(s, client: fakeModel());
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ChatScreen(state: s, chat: chat))));
    await tester.enterText(find.byKey(const Key('chat-input')), 'Remind me to call mum tomorrow at 8pm');
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('chat-send')));
      while (chat.busy || chat.items.length < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tool-call1')), findsOneWidget);
    expect(find.textContaining('Added it.'), findsOneWidget);
    expect(s.tasks, hasLength(1));
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(s.tasks, isEmpty);
    expect(find.text('Undone'), findsOneWidget);

    final reloaded = AgUiChat(s);
    expect(reloaded.items.map((i) => i.kind), ['user', 'tool', 'assistant']);
    expect(reloaded.history.length, chat.history.length);
    reloaded.newChat();
    expect(AgUiChat(s).items, isEmpty);
  });
}
