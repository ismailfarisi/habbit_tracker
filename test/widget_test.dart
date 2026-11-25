import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_tracker/app_state.dart';
import 'package:habit_tracker/logic/stats.dart';
import 'package:habit_tracker/main.dart';
import 'package:habit_tracker/models.dart';
import 'package:habit_tracker/screens/home_screen.dart';
import 'package:habit_tracker/screens/onboarding_screen.dart';
import 'package:habit_tracker/widgets/ai_key_empty_state.dart';

import 'support.dart';

final _onboarded = {
  'settings.v1': jsonEncode({'onboarded': true}),
  'habits.v1': '[]',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(mockPlugins);

  Future<AppState> pumpApp(WidgetTester tester, {Map<String, Object>? prefs}) async {
    late AppState state;
    await tester.runAsync(() async {
      state = await loadState(prefs ?? _onboarded);
    });
    await tester.pumpWidget(DailyDisciplineApp(state: state));
    await tester.pumpAndSettle();
    return state;
  }

  void phone(WidgetTester tester, [Size size = const Size(1080, 2340), double ratio = 3]) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = ratio;
    addTearDown(tester.view.reset);
  }

  testWidgets('four tabs render and Settings opens from the gear on every tab', (tester) async {
    phone(tester);
    await pumpApp(tester);
    expect(find.textContaining('Wake up early'), findsOneWidget);
    expect(find.byType(NavigationDestination), findsNWidgets(4));
    for (final tab in ['Plan', 'Chat', 'Progress', 'Today']) {
      await tester.tap(find.text(tab).last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: tab);
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Wake-up & sleep'), findsOneWidget, reason: tab);
      await tester.pageBack();
      await tester.pumpAndSettle();
    }
    expect(find.text('Wake-up & sleep'), findsNothing);
  });

  testWidgets('requesting the settings tab opens the Settings page', (tester) async {
    phone(tester);
    final state = await pumpApp(tester);
    state.requestedTab.value = HomeScreen.settingsTab;
    await tester.pumpAndSettle();
    expect(find.text('Wake-up & sleep'), findsOneWidget);
  });

  testWidgets('create a task on Plan and tick it off', (tester) async {
    phone(tester, const Size(420, 3000), 1);
    final state = await pumpApp(tester);
    await tester.tap(find.text('Plan').last);
    await tester.pumpAndSettle();
    expect(find.text('Coach'), findsOneWidget);
    expect(find.text('Habits'), findsOneWidget);

    await tester.tap(find.byTooltip('New task'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Title'), 'Read Quran');
    await tester.tap(find.text('Daily'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(state.tasks.single.title, 'Read Quran');
    expect(state.tasks.single.repeat, Repeat.daily);
    final tile = find.widgetWithText(ListTile, 'Read Quran').first;
    await tester.tap(find.descendant(of: tile, matching: find.byType(Checkbox)));
    await tester.pumpAndSettle();
    expect(state.tasks.single.doneDates, isNotEmpty);
  });

  testWidgets('coach without an AI key shows the empty state; templates still work', (tester) async {
    phone(tester);
    final state = await pumpApp(tester);
    await tester.tap(find.text('Plan').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Coach'));
    await tester.pumpAndSettle();
    expect(find.text(AiKeyEmptyState.message), findsOneWidget);
    expect(find.byType(TextField), findsNothing, reason: 'no chat input without a key');

    await tester.tap(find.text('Browse templates'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Drink water'));
    await tester.pumpAndSettle();
    expect(state.habits.single.title, 'Drink water');

    await tester.tap(find.text('Add AI key'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'API key'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'API key'), 'sk-or-test');
    await tester.pumpAndSettle();
    expect(state.apiKey, 'sk-or-test');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text(AiKeyEmptyState.message), findsNothing);
    expect(find.text('How did my week go?'), findsOneWidget, reason: 'the chat appears once a key is set');
  });

  testWidgets('the coach sheet shows the empty state without a key', (tester) async {
    phone(tester, const Size(420, 4000), 1);
    await pumpApp(tester);
    await tester.tap(find.text('Add habit'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Build one with the AI coach'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Build one with the AI coach'));
    await tester.pumpAndSettle();
    expect(find.text(AiKeyEmptyState.message), findsOneWidget);
  });

  testWidgets('Plan lists habits: add from template, edit, archive, restore', (tester) async {
    phone(tester, const Size(420, 3000), 1);
    final state = await pumpApp(tester);
    await tester.tap(find.text('Plan').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('No habits yet'), findsOneWidget);

    await tester.tap(find.text('Add habit'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Drink water'));
    await tester.pumpAndSettle();
    expect(find.text('Habits · 1'), findsOneWidget);

    await tester.tap(find.byTooltip('Habit options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Water');
    await tester.enterText(find.widgetWithText(TextField, 'Daily target'), '10');
    await tester.tap(find.text('Mon'));
    await tester.ensureVisible(find.text('Forgiving streak'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Forgiving streak'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final h = state.habits.single;
    expect(h.title, 'Water');
    expect(h.target, 10);
    expect(h.weekdays, [1]);
    expect(h.streakRule.name, 'strict', reason: 'templates start forgiving; the switch turns it off');

    await tester.tap(find.byTooltip('Habit options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();
    expect(state.habits.single.archived, isTrue);
    expect(find.text('Archived · 1'), findsOneWidget);

    await tester.tap(find.text('Archived · 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Habit options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    expect(state.habits.single.archived, isFalse);
  });

  testWidgets('add habits from templates on Today and log them', (tester) async {
    phone(tester, const Size(420, 4000), 1);
    final state = await pumpApp(tester);
    expect(state.habits, isEmpty);

    await tester.tap(find.text('Add habit'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Drink water'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();
    final water = state.habits.single;
    expect(find.text('Drink water'), findsOneWidget);
    expect(find.text('0/8 glasses'), findsOneWidget);

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    expect(state.habitEntry(DateTime.now(), water.id).value, 1);
    expect(find.text('1/8 glasses'), findsOneWidget);

    await tester.tap(find.text('Progress').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('Drink water'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  group('onboarding', () {
    testWidgets('one choice opens a doable practice and it can be completed offline', (tester) async {
      phone(tester);
      final state = await pumpApp(tester, prefs: {});
      expect(find.text('What would you like to work on?'), findsOneWidget);
      await tester.tap(find.text('Drink water'));
      await tester.pumpAndSettle();
      expect(state.settings.onboarded, isTrue);
      expect(state.apiKey, isEmpty);
      expect(state.settings.hasLocation, isFalse);
      expect(find.text('Enable'), findsNothing);
      expect(find.text('Set up'), findsNothing);
      final habit = state.habits.single;
      expect(habit.target, 1);
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      expect(state.habitEntry(DateTime.now(), habit.id).value, 1);
      expect(dayScore(DateTime.now(), state.settings, state.logs, habits: state.habits).toString(), '1/1');
      expect(find.text('Done (1)'), findsOneWidget);
    });

    testWidgets('choosing later skips the practice and all setup', (tester) async {
      phone(tester);
      final state = await pumpApp(tester, prefs: {});
      await tester.tap(find.text('Choose later'));
      await tester.pumpAndSettle();
      expect(find.text('Choose a practice when you’re ready.'), findsOneWidget);
      expect(state.habits, isEmpty);
      expect(state.storage.loadSettings().todayHidden, containsAll(['wake', 'prayers']));
    });

    testWidgets('existing installs skip onboarding', (tester) async {
      phone(tester);
      final today = dayKey(DateTime.now());
      await pumpApp(
        tester,
        prefs: {
          'logs.v1': jsonEncode({
            today: {
              'prayers': ['Fajr'],
            },
          }),
        },
      );
      expect(find.byType(OnboardingScreen), findsNothing);
      expect(find.byType(NavigationBar), findsOneWidget);
    });

    test('settings saved before onboarding existed count as onboarded', () {
      expect(Settings().onboarded, isFalse);
      expect(Settings.fromJson({'wakeTime': '05:30'}).onboarded, isTrue);
      expect(Settings.fromJson({'onboarded': false}).onboarded, isFalse);
      final s = Settings(sleepHours: 8)..onboarded = true;
      final back = Settings.fromJson(s.toJson());
      expect(back.onboarded, isTrue);
      expect(back.sleepHours, 8);
    });
  });

  group('notification routing', () {
    late AppState state;
    setUp(() async => state = await loadState(_onboarded));

    test('a habit reminder opens the habit on Today', () {
      routeNotification(state, 'habit:h1|2026-11-16', null);
      expect(state.requestedHabit.value, 'h1');
      expect(state.requestedTab.value, HomeScreen.todayTab);
    });

    test('a task reminder opens Plan', () {
      routeNotification(state, 'task:t1|2026-11-16', null);
      expect(state.requestedTab.value, HomeScreen.planTab);
    });

    test('a prayer reminder tap opens Today; its done action marks the prayer', () async {
      routeNotification(state, 'prayer:Fajr|${dayKey(DateTime.now())}', null);
      expect(state.requestedTab.value, HomeScreen.todayTab);
      state.requestedTab.value = null;
      routeNotification(state, 'prayer:Fajr|${dayKey(DateTime.now())}', 'done');
      await Future<void>.delayed(Duration.zero);
      expect(state.today.prayers, contains('Fajr'));
      expect(state.requestedTab.value, isNull);
    });
  });
}
