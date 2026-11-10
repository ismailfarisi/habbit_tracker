import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_tracker/app_state.dart';
import 'package:habit_tracker/main.dart';
import 'package:habit_tracker/models.dart';
import 'package:habit_tracker/services/notification_service.dart';
import 'package:habit_tracker/services/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // Plugins that have no implementation in tests.
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final ch in ['flutter_tts', 'plugins.it_nomads.com/flutter_secure_storage']) {
      messenger.setMockMethodCallHandler(MethodChannel(ch), (_) async => null);
    }
  });

  Future<AppState> pumpApp(WidgetTester tester) async {
    late AppState state;
    await tester.runAsync(() async {
      state = await AppState.load(await Storage.open(), NotificationService.instance);
    });
    await tester.pumpWidget(DailyDisciplineApp(state: state));
    await tester.pumpAndSettle();
    return state;
  }

  testWidgets('all tabs render on a phone-sized screen', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(tester);
    expect(find.textContaining('Wake up early'), findsOneWidget);
    for (final tab in ['Tasks', 'Train', 'Stats', 'Settings', 'Today']) {
      await tester.tap(find.text(tab).last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: tab);
    }
  });

  testWidgets('create a task manually and tick it off', (tester) async {
    // Tall screen so the whole task list is built.
    tester.view.physicalSize = const Size(420, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = await pumpApp(tester);
    await tester.tap(find.text('Tasks').last);
    await tester.pumpAndSettle();
    expect(find.text('Plan with AI'), findsOneWidget);

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
    expect(tile, findsOneWidget); // Today section (it also appears under Routines)

    await tester.tap(find.descendant(of: tile, matching: find.byType(Checkbox)));
    await tester.pumpAndSettle();
    expect(state.tasks.single.doneDates, isNotEmpty);
  });

  testWidgets('AI chat asks for an API key when none is set', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Tasks').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('What do I have today?'));
    await tester.pumpAndSettle();
    expect(find.textContaining('OpenRouter API key'), findsOneWidget);
  });
}
