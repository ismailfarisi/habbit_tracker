import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_tracker/agent/habit_templates.dart';
import 'package:habit_tracker/app_state.dart';
import 'package:habit_tracker/habits/habit.dart';
import 'package:habit_tracker/logic/prayer_status.dart';
import 'package:habit_tracker/logic/stats.dart';
import 'package:habit_tracker/logic/tasks.dart';
import 'package:habit_tracker/models.dart';
import 'package:habit_tracker/services/reminders.dart';
import 'package:habit_tracker/screens/reminders_screen.dart';
import 'package:habit_tracker/screens/settings_screen.dart';
import 'package:habit_tracker/screens/today_screen.dart';
import 'package:habit_tracker/widgets/day_editor.dart';
import 'package:habit_tracker/widgets/yesterday_prompt.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Tuesday 9:00; default manual prayer times (Fajr 05:00 .. Isha 19:45), wake goal 05:00.
  final now = DateTime(2026, 5, 5, 9);
  final yesterday = DateTime(2026, 5, 4);
  late AppState state;

  setUp(() async {
    mockPlugins();
    state = await loadState();
  });

  Future<HabitDef> add(HabitTemplate t, {String? reminder}) =>
      state.upsertHabit(habitFromTemplate(t, reminder: reminder, createdAt: DateTime(2026, 4, 1)));

  Future<Task> addRoutine(String title) async {
    final t = Task(id: title, seq: state.tasks.length + 1, title: title, repeat: Repeat.daily, createdAt: DateTime(2026, 4, 1));
    await state.restoreTask(t);
    return t;
  }

  void tallView(WidgetTester tester) {
    tester.view.physicalSize = const Size(420, 5000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> pumpToday(WidgetTester tester, DateTime at) async {
    tallView(tester);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: TodayScreen(state: state, onNavigate: (_) {}, clock: () => at)),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> openEditor(WidgetTester tester, DateTime day) async {
    tallView(tester);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(onPressed: () => showDayEditor(context, state, day), child: const Text('open')),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Finder inRow(String key, Finder f) => find.descendant(of: find.byKey(ValueKey(key)), matching: f);

  test('tracking choices survive backup and exclude paused dates without losing earlier days', () async {
    final today = dateOnly(DateTime.now());
    DateTime ago(int days) => DateTime(today.year, today.month, today.day - days);
    await state.setWake(ago(5), ago(5));
    await state.updateSettings((s) => s.todayHidden.add('wake'));
    expect(state.settings.tracksOn('wake', ago(5)), isFalse);
    await state.updateSettings((s) {
      // Simulate the opt-out having happened three days ago.
      final history = s.trackingHistory['wake']!;
      history.remove(dayKey(today));
      history[dayKey(ago(3))] = false;
      s.todayHidden.remove('wake');
    });
    final restored = Settings.fromJson(state.settings.toJson());
    expect(restored.tracksOn('wake', ago(5)), isTrue);
    expect(restored.tracksOn('wake', ago(2)), isFalse);
    expect(restored.tracksOn('wake', today), isTrue);
    expect(restored.tracksOn('prayers', ago(5)), isTrue);
  });

  group('todayItems ordering', () {
    test('wake comes back in the evening until bedtime is logged', () async {
      await state.setWake(now, DateTime(2026, 5, 5, 5));
      TodayItem wake(DateTime at) => todayItems(state, at).firstWhere((i) => i.kind == TodayKind.wake);
      expect(wake(now).done, isTrue);
      final evening = DateTime(2026, 5, 5, 21);
      expect(wake(evening).done, isFalse);
      await state.setBedtime(DateTime(2026, 5, 5), evening);
      expect(wake(evening).done, isTrue);
    });

    test('prayers stay open while an enabled optional prayer is unticked', () async {
      for (final p in prayerNames) {
        await state.setPrayerStatus(now, p, prayerOnTime);
      }
      TodayItem prayers() => todayItems(state, now).firstWhere((i) => i.kind == TodayKind.prayers);
      expect(prayers().done, isTrue);
      await state.updateSettings((x) => x.sunnahWitr = true);
      expect(prayers().done, isFalse);
      await state.logHabit(now, sunnahWitr.id, HabitEntry(done: true));
      expect(prayers().done, isTrue);
    });

    test('next due first, untimed after timed, done last', () async {
      state.settings.useManualPrayer = true;
      final water = await add(waterTemplate);
      final quran = await add(quranTemplate, reminder: '07:00');
      final exercise = await add(exerciseTemplate, reminder: '20:00');
      List<String> ids() => todayItems(state, now).map((i) => i.toString()).toList();

      expect(ids(), ['wake', 'prayers', quran.id, exercise.id, water.id, 'tasks']);

      await state.setWake(now, DateTime(2026, 5, 5, 5, 10));
      await state.setPrayerStatus(now, 'Fajr', prayerOnTime);
      // Prayers are now due at Dhuhr (12:30), after the 07:00 habit.
      expect(ids(), [quran.id, 'prayers', exercise.id, water.id, 'tasks', 'wake (done)']);

      await state.logHabit(now, quran.id, HabitEntry(done: true));
      await state.logHabit(now, water.id, HabitEntry(value: 8));
      expect(ids(), ['prayers', exercise.id, 'tasks', 'wake (done)', '${quran.id} (done)', '${water.id} (done)']);

      for (final p in prayerNames) {
        await state.setPrayerStatus(now, p, prayerLate);
      }
      expect(todayItems(state, now).firstWhere((i) => i.kind == TodayKind.prayers).done, isTrue);
    });

    test('tasks are due at the next unfinished timed task and done when all are', () async {
      final a = await state.addTask(title: 'Call mum', date: dayKey(now), time: '16:00');
      await state.addTask(title: 'Gym', date: dayKey(now), time: '18:00');
      TodayItem tasks() => todayItems(state, now).firstWhere((i) => i.kind == TodayKind.tasks);
      expect(tasks().due, DateTime(2026, 5, 5, 16));
      await state.setTaskDone(a, now, true);
      expect(tasks().due, DateTime(2026, 5, 5, 18));
      for (final t in state.tasks) {
        await state.setTaskDone(t, now, true);
      }
      expect(tasks().done, isTrue);
    });

    test('unscheduled and archived habits are left out', () async {
      final h = await state.upsertHabit(habitFromTemplate(quranTemplate, createdAt: DateTime(2026, 4, 1))..weekdays = [5]);
      final w = await add(waterTemplate);
      await state.archiveHabit(w.id);
      expect(todayItems(state, now).where((i) => i.habit != null), isEmpty, reason: '${h.title} is Fridays only');
    });
  });

  group('Today screen', () {
    testWidgets('cards follow the time of day, done ones collapse, no reminders card', (tester) async {
      state.settings.useManualPrayer = true;
      final quran = await add(quranTemplate, reminder: '07:00');
      await add(waterTemplate);
      await pumpToday(tester, now);

      expect(find.byKey(const ValueKey('today-prayers')), findsNothing);
      await tester.tap(find.text('Later'));
      await tester.pumpAndSettle();
      double top(String key) => tester.getTopLeft(find.byKey(ValueKey(key))).dy;
      expect(top('today-wake'), lessThan(top('today-prayers')));
      expect(top('today-prayers'), lessThan(top(quran.id)));
      expect(find.textContaining('Upcoming reminders'), findsNothing);
      expect(find.byKey(const ValueKey('today-done')), findsNothing);

      await state.setWake(now, DateTime(2026, 5, 5, 5, 20));
      await tester.pumpAndSettle();
      await tester.tap(find.text('I read Quran today'));
      await tester.pumpAndSettle();
      expect(find.text('Done (2)'), findsOneWidget);
      expect(find.byKey(const ValueKey('today-wake')), findsNothing);
      expect(find.byKey(ValueKey(quran.id)), findsNothing);

      await tester.tap(find.text('Done (2)'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('today-wake')), findsOneWidget);
      expect(top('today-done'), lessThan(top('today-wake')));
      expect(find.byKey(const ValueKey('today-tasks')), findsNothing, reason: 'No tasks are scheduled');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a featured prayer shows one action and Later contains only its siblings', (tester) async {
      await state.updateSettings((s) => s.todayHidden = ['wake']);
      await pumpToday(tester, now);
      expect(find.text('Fajr'), findsOneWidget);
      expect(find.text('Dhuhr'), findsNothing);
      await tester.tap(find.text('Later'));
      await tester.pumpAndSettle();
      expect(find.text('Fajr'), findsOneWidget);
      expect(find.text('Dhuhr'), findsOneWidget);
    });

    testWidgets('Customize hides, pins and restores cards with undo and persistent choices', (tester) async {
      final habit = await add(quranTemplate);
      await pumpToday(tester, now);
      await tester.tap(find.text('Customize'));
      await tester.pumpAndSettle();
      Finder checkbox(String label) => find.descendant(of: find.widgetWithText(ListTile, label), matching: find.byType(Checkbox));
      await tester.tap(checkbox('Wake & sleep'));
      await tester.tap(checkbox('Prayer tracking'));
      await tester.tap(find.byTooltip('Order Read Quran'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pin first'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore defaults'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Pinned ·'), findsNothing);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(state.storage.loadSettings().todayPinned, [habit.id]);
      expect(find.text('Set up'), findsNothing);
      expect(find.text('Enable'), findsNothing);
      expect(find.text('Read Quran'), findsOneWidget);
      expect(dayScore(now, state.settings, {}, habits: state.habits).total, 1);
      expect(planReminders(state.settings, {}, now), isEmpty);

      await tester.tap(find.text('Customize'));
      await tester.pumpAndSettle();
      await tester.tap(checkbox('Prayer tracking'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set up'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Prayer times'), findsOneWidget);
      await tester.tap(find.text('Choose a city'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dubai'));
      await tester.pumpAndSettle();
      expect(state.settings.locationName, 'Dubai');
    });

    testWidgets('agent-built timed habits render their surface on Today', (tester) async {
      final h = habitFromTemplate(exerciseTemplate, createdAt: DateTime(2026, 4, 1));
      await state.upsertHabit(HabitDef.fromJson({...h.toJson(), 'createdByAi': true}));
      await add(articulationTemplate);
      await pumpToday(tester, now);
      await tester.tap(find.text('Later'));
      await tester.pumpAndSettle();
      expect(find.text('How hard was it?'), findsOneWidget, reason: 'AI habit shows its own A2UI surface');
      expect(find.text('Practise'), findsOneWidget, reason: 'timed templates stay compact');
    });
  });

  group('yesterday prompt', () {
    Future<void> seedHistory() async {
      await state.setPrayerStatus(DateTime(2026, 5, 3), 'Fajr', prayerOnTime);
      await state.setWake(yesterday, DateTime(2026, 5, 4, 5));
      for (final p in prayerNames.take(4)) {
        await state.setPrayerStatus(yesterday, p, prayerOnTime);
      }
    }

    testWidgets('asks about the missed prayer and fixes it in one tap', (tester) async {
      await seedHistory();
      await pumpToday(tester, now);
      expect(find.text('Resume today'), findsOneWidget);
      expect(find.byKey(const ValueKey('yesterday-prompt')), findsNothing);
      await tester.tap(find.text('Edit yesterday’s log'));
      await tester.pumpAndSettle();
      expect(find.text('Yesterday: did you pray Isha?'), findsOneWidget);
      await tester.tap(inRow('missed-prayer:Isha', find.text('Prayed')));
      await tester.pumpAndSettle();
      expect(state.logFor(yesterday).prayerStatus['Isha'], prayerOnTime);
      expect(find.byKey(const ValueKey('yesterday-prompt')), findsNothing);
    });

    testWidgets('lists habits and routines, reviews yesterday and dismisses', (tester) async {
      await seedHistory();
      final quran = await add(quranTemplate);
      final gym = await addRoutine('Gym');
      expect(missedYesterday(state, now).map((i) => i.id), ['prayer:Isha', 'habit:${quran.id}', 'task:${gym.id}']);
      await pumpToday(tester, now);
      await tester.tap(find.text('Edit yesterday’s log'));
      await tester.pumpAndSettle();
      expect(find.text('Yesterday: 3 things not logged'), findsOneWidget);

      await tester.tap(inRow('missed-habit:${quran.id}', find.text('Done')));
      await tester.pumpAndSettle();
      expect(habitDone(state.habitEntry(yesterday, quran.id), quran), isTrue);
      await tester.tap(inRow('missed-task:${gym.id}', find.text('Done')));
      await tester.pumpAndSettle();
      expect(gym.isDoneOn(yesterday), isTrue);

      await tester.tap(find.text('Review yesterday'));
      await tester.pumpAndSettle();
      expect(find.text('Monday, 4 May'), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      await tester.tap(find.descendant(of: find.byKey(const ValueKey('yesterday-prompt')), matching: find.text('Dismiss')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('yesterday-prompt')), findsNothing);
      expect(state.storage.prefs.getString('yesterdayPrompt.dismissed'), '2026-05-05');
    });

    test('not shown on a fresh install, only habits that existed count', () async {
      expect(missedYesterday(state, now), isEmpty);
      await state.upsertHabit(habitFromTemplate(quranTemplate, createdAt: now));
      expect(missedYesterday(state, now), isEmpty);
    });

    testWidgets('only in the morning', (tester) async {
      await seedHistory();
      await pumpToday(tester, DateTime(2026, 5, 5, 13));
      expect(find.byKey(const ValueKey('yesterday-prompt')), findsNothing);
    });
  });

  group('day editor', () {
    testWidgets('prayer statuses, wake set and clear', (tester) async {
      await openEditor(tester, yesterday);
      expect(find.text('Monday, 4 May'), findsOneWidget);

      await tester.tap(inRow('prayer-Isha', find.text('Late')));
      await tester.pumpAndSettle();
      expect(state.logFor(yesterday).prayerStatus['Isha'], prayerLate);
      await tester.tap(inRow('prayer-Fajr', find.text('Qada')));
      await tester.pumpAndSettle();
      expect(state.logFor(yesterday).prayerStatus['Fajr'], prayerQada);
      await tester.tap(inRow('prayer-Isha', find.text('No')));
      await tester.pumpAndSettle();
      expect(state.logFor(yesterday).prayers, {'Fajr'});
      await tester.tap(inRow('prayer-Dhuhr', find.text('Dhuhr')));
      await tester.pumpAndSettle();
      expect(state.logFor(yesterday).prayerStatus['Dhuhr'], prayerOnTime);

      await tester.tap(find.byTooltip('Set wake time'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(state.logFor(yesterday).wakeAt, DateTime(2026, 5, 4, 5));
      expect(find.textContaining('Up at 5:00'), findsOneWidget);
      await tester.tap(find.byTooltip('Clear wake time'));
      await tester.pumpAndSettle();
      expect(state.logFor(yesterday).wakeAt, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('habits through their surface or minutes control, routines, day arrows', (tester) async {
      final water = await add(waterTemplate);
      final exercise = await add(exerciseTemplate);
      final gym = await addRoutine('Gym');
      await openEditor(tester, yesterday);

      await tester.tap(inRow('day-habit-${water.id}-2026-05-04', find.byTooltip('More')));
      await tester.pumpAndSettle();
      expect(state.habitEntry(yesterday, water.id).value, 1);
      expect(find.text('Glasses of water'), findsOneWidget, reason: 'the Counter surface');

      await tester.tap(inRow('day-habit-${exercise.id}-2026-05-04', find.byTooltip('More')));
      await tester.pumpAndSettle();
      expect(state.habitEntry(yesterday, exercise.id).minutes, 5);
      expect(find.text('Workout'), findsNothing, reason: 'no timer for a past day');

      await tester.tap(find.byKey(ValueKey('day-task-${gym.id}')));
      await tester.pumpAndSettle();
      expect(gym.isDoneOn(yesterday), isTrue);

      await tester.tap(find.byTooltip('Previous day'));
      await tester.pumpAndSettle();
      expect(find.text('Sunday, 3 May'), findsOneWidget);
      await tester.tap(inRow('day-habit-${water.id}-2026-05-03', find.byTooltip('More')));
      await tester.pumpAndSettle();
      expect(state.habitEntry(DateTime(2026, 5, 3), water.id).value, 1);
      expect(state.habitEntry(yesterday, water.id).value, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('cannot step past today', (tester) async {
      tallView(tester);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: DayEditor(state: state, day: now, today: now))));
      await tester.pump();
      final next = tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.chevron_right));
      expect(next.onPressed, isNull);
    });
  });

  testWidgets('Upcoming does not claim planned items are queued when the device queue is unavailable', (tester) async {
    tallView(tester);
    await add(quranTemplate, reminder: '21:00');
    await tester.pumpWidget(MaterialApp(home: RemindersScreen(state: state, now: now)));
    await tester.pump();
    expect(find.text('Could not read scheduled alerts on this device.'), findsOneWidget);
    expect(find.text('📖 Read Quran'), findsNothing);
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(state.settings.remindersEnabled, isFalse);
    expect(find.text('Reminders are turned off.'), findsOneWidget);
  });

  testWidgets('Settings lists sections and opens each as its own page', (tester) async {
    tallView(tester);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SettingsScreen(state: state))));
    await tester.pumpAndSettle();
    for (final x in SettingsSection.values) {
      expect(find.byKey(ValueKey('settings-${x.name}')), findsOneWidget);
    }
    expect(find.text('Target wake-up time'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('settings-backup')));
    await tester.pumpAndSettle();
    expect(find.text('Reset and keep a recovery copy'), findsOneWidget);
    expect(find.text('Erase this device'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wake-up & sleep'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Wake-up & sleep'), findsOneWidget);
    expect(find.text('Target wake-up time'), findsOneWidget);
    expect(find.text('Sleep goal'), findsOneWidget);
    expect(find.text('Calculation method'), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Appearance & streaks'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(state.settings.themeMode, 'dark');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.textContaining('Theme: Dark'), findsOneWidget);
  });

  testWidgets('Settings opens the Reminders page', (tester) async {
    tallView(tester);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SettingsScreen(state: state))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reminders'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Upcoming reminders'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Reminders'), findsOneWidget);
  });
}
