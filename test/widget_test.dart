import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  testWidgets('three tabs render and Settings opens from the gear on every tab', (tester) async {
    phone(tester);
    await pumpApp(tester);
    expect(find.textContaining('Wake up early'), findsOneWidget);
    expect(find.byType(NavigationDestination), findsNWidgets(3));
    for (final tab in ['Plan', 'Progress', 'Today']) {
      await tester.tap(find.text(tab).last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: tab);
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Target wake-up time'), findsOneWidget, reason: tab);
      await tester.pageBack();
      await tester.pumpAndSettle();
    }
    expect(find.text('Target wake-up time'), findsNothing);
  });

  testWidgets('requesting the settings tab opens the Settings page', (tester) async {
    phone(tester);
    final state = await pumpApp(tester);
    state.requestedTab.value = HomeScreen.settingsTab;
    await tester.pumpAndSettle();
    expect(find.text('Target wake-up time'), findsOneWidget);
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
    expect(find.text('What do I have today?'), findsOneWidget, reason: 'the chat appears once a key is set');
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
    testWidgets('a fresh install walks through every step and lands on Today', (tester) async {
      phone(tester);
      final state = await pumpApp(tester, prefs: {});
      expect(find.byType(OnboardingScreen), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);

      await tester.tap(find.text('Get started'));
      await tester.pumpAndSettle();
      expect(find.text('Where do you pray?'), findsOneWidget);
      await tester.tap(find.text('Choose my city'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Search city'), 'dub');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dubai'));
      await tester.pumpAndSettle();
      expect(state.settings.locationName, 'Dubai');
      expect(state.settings.calcMethod, 'dubai');
      expect(state.settings.latitude, closeTo(25.2, 0.1));

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Allow notifications and alarms'), findsOneWidget);
      expect(find.text('Open battery settings'), findsOneWidget);
      expect(find.text('Xiaomi / Redmi / POCO'), findsOneWidget);
      expect(find.text('Samsung'), findsOneWidget);
      expect(find.text('Huawei / Honor'), findsOneWidget);
      await tester.tap(find.text('Allow notifications and alarms'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Notifications are blocked'), findsOneWidget, reason: 'no plugin in tests');
      await tester.ensureVisible(find.text('Open battery settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open battery settings'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('When do you want to wake up?'), findsOneWidget);
      expect(find.text('Sleep goal: 7.5 hours'), findsOneWidget);
      expect(find.textContaining('be asleep by about 9:30'), findsOneWidget);
      await tester.drag(find.byType(Slider), const Offset(400, 0));
      await tester.pumpAndSettle();
      expect(state.settings.sleepHours, greaterThan(7.5));

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Drink water'));
      await tester.tap(find.text('Read Quran'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('AI coach (optional)'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'API key'), findsOneWidget);
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();

      expect(state.settings.onboarded, isTrue);
      expect(state.apiKey, isEmpty);
      expect(state.habits.map((h) => h.title), containsAll(['Drink water', 'Read Quran']));
      expect(find.byType(OnboardingScreen), findsNothing);
      expect(find.byType(NavigationBar), findsOneWidget);
    });

    testWidgets('denied location permission falls back to the city list', (tester) async {
      phone(tester);
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('flutter.baseflow.com/geolocator');
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => switch (call.method) {
          'isLocationServiceEnabled' => true,
          'checkPermission' || 'requestPermission' => 0, // LocationPermission.denied
          _ => null,
        },
      );
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final state = await pumpApp(tester, prefs: {});
      await tester.tap(find.text('Get started'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use my location'));
      await tester.pumpAndSettle();
      expect(find.text('Location permission was denied. Pick your city instead.'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Search city'), findsOneWidget);
      await tester.tap(find.text('Abu Dhabi'));
      await tester.pumpAndSettle();
      expect(state.settings.locationName, 'Abu Dhabi');
      expect(find.text('Abu Dhabi'), findsOneWidget, reason: 'shown as the chosen location');
    });

    testWidgets('an AI key entered during onboarding is saved', (tester) async {
      phone(tester);
      final state = await pumpApp(tester, prefs: {});
      await tester.tap(find.text('Get started'));
      await tester.pumpAndSettle();
      for (var i = 0; i < 4; i++) {
        await tester.tap(find.text(i < 2 ? 'Not now' : 'Continue'));
        await tester.pumpAndSettle();
      }
      await tester.enterText(find.widgetWithText(TextField, 'API key'), 'sk-or-abc');
      await tester.tap(find.text('Finish'));
      await tester.pumpAndSettle();
      expect(state.apiKey, 'sk-or-abc');
      expect(state.settings.onboarded, isTrue);
      expect(state.habits, isEmpty);
      expect(find.byType(NavigationBar), findsOneWidget);
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
