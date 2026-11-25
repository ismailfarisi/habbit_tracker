import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_tracker/logic/stats.dart';
import 'package:habit_tracker/habits/habit.dart';
import 'package:habit_tracker/models.dart';
import 'package:habit_tracker/quran/quran.dart';
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
    final oneOff = await s.addTask(title: 'Reviewed budget', date: dayKey(yesterday));
    await s.setTaskDone(oneOff, yesterday, true);
    expect(calendarDay(s, yesterday, today).done, 2);
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
  testWidgets('month navigation clamps selection and exposes one complete day label', (tester) async {
    final s = await loadState();
    final today = DateTime(2032, 1, 31);
    await tester.pumpWidget(MaterialApp(home: CalendarScreen(state: s, clock: () => today)));
    await tester.tap(find.byTooltip('Next month'));
    await tester.pumpAndSettle();
    final cell = find.byKey(const ValueKey('cal-2032-02-29'));
    final data = tester.getSemantics(cell).getSemanticsData();
    expect(data.label, contains('Sunday, February 29, 2032'));
    expect(data.label, contains('0 planned tasks'));
    expect(data.label, contains('Forecast'));
    expect(data.flagsCollection.isSelected, Tristate.isTrue);
    expect(tester.getSize(cell).shortestSide, greaterThanOrEqualTo(48));
    await tester.tap(find.text('Agenda'));
    await tester.pumpAndSettle();
    expect(find.text('Sunday, February 29, 2032'), findsOneWidget);
    await tester.tap(find.text('Today'));
    await tester.pumpAndSettle();
    expect(find.text('Saturday, January 31, 2032'), findsOneWidget);
  });

  testWidgets('wide calendar puts the selected agenda beside its month', (tester) async {
    final state = await loadState();
    tester.view.physicalSize = const Size(1024, 620);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: CalendarScreen(state: state, clock: () => DateTime(2026, 11, 19))));
    await tester.pumpAndSettle();
    final grid = tester.getRect(find.byType(GridView));
    final details = tester.getRect(find.text('Thursday, November 19, 2026'));
    expect(details.left, greaterThan(grid.right));
    expect(details.top, lessThan(grid.bottom));
    await tester.tap(find.byKey(const ValueKey('cal-2026-11-20')));
    await tester.pumpAndSettle();
    expect(find.text('Friday, November 20, 2026'), findsOneWidget);
    expect(find.byKey(const Key('cal-add-task')).hitTestable(), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    testWidgets('320dp $brightness agenda keeps future tasks and habit steps read-only', (tester) async {
      final s = await loadState();
      final day = DateTime(2032, 1, 31);
      QuranText.cache = QuranText.parse(File('assets/quran/quran-uthmani.txt').readAsStringSync());
      final task = await s.addTask(title: 'Business plan', repeat: Repeat.daily);
      await s.updateTask(task, (t) => t.guide = const TaskGuide(steps: ['Contact supplier'], sessions: ['Survey', 'Order']));
      final h = await s.upsertHabit(HabitDef(id: 'q', title: 'Al-Mulk', guide: const TaskGuide(
        steps: ['Recite'], quran: QuranRef(67, 1, 30, mode: 'memorise', perDay: 2),
      )));
      tester.view.physicalSize = const Size(320, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(1.4)), child: child!,
        ),
        home: CalendarScreen(state: s, clock: () => day),
      ));
      await tester.tap(find.byTooltip('Next day'));
      await tester.pumpAndSettle();
      expect(find.text('Business plan').hitTestable(), findsOneWidget);
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).onChanged, isNull);
      await tester.tap(find.text('Business plan'));
      await tester.pumpAndSettle();
      expect(find.text('Order'), findsOneWidget);
      expect(tester.widget<CheckboxListTile>(find.byKey(const ValueKey('step-0'))).onChanged, isNull);
      await tester.tap(find.text('1. Contact supplier'));
      expect(find.byKey(const Key('guide-done')), findsNothing);
      expect(s.storage.loadTasks().single.stepsDone, isEmpty);
      expect(s.storage.loadTasks().single.doneDates, isEmpty);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Al-Mulk').first);
      await tester.pumpAndSettle();
      expect(find.text('Al-Mulk 3–4'), findsOneWidget);
      await tester.tap(find.text('1. Recite'));
      expect(s.storage.loadLogs(), isEmpty);
      expect(s.quranFor(h, day, today: day)!.from, 1);
      expect(tester.takeException(), isNull);
    });
  }

}
