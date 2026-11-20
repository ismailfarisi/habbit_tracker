import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_tracker/logic/stats.dart';
import 'package:habit_tracker/models.dart';
import 'package:habit_tracker/screens/calendar_screen.dart';
import 'package:habit_tracker/screens/chat_screen.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(mockPlugins);

  test('chat history: old chat migrates, New chat keeps it, it reopens and deletes', () async {
    final s = await loadState({
      'settings.v1': jsonEncode({'onboarded': true}),
      'chat.v1': jsonEncode([
        {'role': 'user', 'content': 'Plan my week'},
        {'role': 'assistant', 'content': 'Here is a plan.'},
      ]),
    });
    final chat = AgUiChat(s);
    expect(chat.threads, hasLength(1));
    expect(chat.items.map((i) => i.text), ['Plan my week', 'Here is a plan.']);
    final old = chat.threadId;

    chat.newChat();
    expect(chat.items, isEmpty);
    expect(chat.threads.single.title, 'Plan my week');

    final reloaded = AgUiChat(s);
    expect(reloaded.threads, hasLength(1));
    reloaded.open(old);
    expect(reloaded.items.first.text, 'Plan my week');
    reloaded.deleteThread(old);
    expect(reloaded.threads, isEmpty);
    expect(reloaded.items, isEmpty);
  });

  testWidgets('calendar shades done days and shows the selected day', (tester) async {
    final s = await loadState({'settings.v1': jsonEncode({'onboarded': true})});
    final today = DateTime(2026, 11, 19);
    final yesterday = today.subtract(const Duration(days: 1));
    await s.setPrayerStatus(yesterday, 'Fajr', prayerOnTime);
    await s.addTask(title: 'Call mum', date: dayKey(today.add(const Duration(days: 2))));
    final info = calendarDay(s, yesterday, today);
    expect(info.done, 1);
    expect(calendarDay(s, today.add(const Duration(days: 2)), today).tasks, 1);

    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: CalendarScreen(state: s, clock: () => today)));
    await tester.pump();
    expect(find.text('November 2026'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('cal-2026-11-21')));
    await tester.pump();
    expect(find.text('Call mum'), findsOneWidget);
    expect(find.byKey(const Key('cal-add-task')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('cal-2026-11-18')));
    await tester.pump();
    expect(find.textContaining('1 of 5 prayers'), findsOneWidget);
    expect(find.byKey(const Key('cal-edit-day')), findsOneWidget);
  });
}
