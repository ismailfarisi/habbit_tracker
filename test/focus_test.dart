import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_tracker/app_state.dart';
import 'package:habit_tracker/models.dart';
import 'package:habit_tracker/screens/progress_screen.dart';
import 'package:habit_tracker/screens/settings_screen.dart';
import 'package:habit_tracker/services/focus_guard.dart';
import 'package:intl/intl.dart';

import 'support.dart';

class FakeFocusGuard implements FocusGuard {
  bool enabled = false, running = false;
  String? testedPackage;
  int settingsOpened = 0, appInfoOpened = 0;
  Map<String, dynamic>? config;
  Map<String, AppUsage> today = {};

  @override
  bool get supported => true;

  @override
  Future<FocusReadiness> readiness() async => FocusReadiness(enabled, running,
      Set<String>.from((config?['apps'] as Map? ?? {}).keys));

  @override
  Future<bool> testPause(String package) async {
    testedPackage = package;
    return true;
  }

  @override
  Future<void> openAccessibilitySettings() async => settingsOpened++;

  @override
  Future<void> openAppInfo() async => appInfoOpened++;

  @override
  Future<List<InstalledApp>> apps() async => const [
    InstalledApp('com.instagram.android', 'Instagram'),
    InstalledApp('com.google.android.youtube', 'YouTube'),
  ];

  @override
  Future<void> configure(Settings s) async => config = jsonDecode(jsonEncode(focusConfig(s, DateTime.now())));

  @override
  Future<Map<String, AppUsage>> usage([DateTime? day]) async => today;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppState state;
  late FakeFocusGuard guard;

  setUp(() async {
    mockPlugins();
    guard = FakeFocusGuard();
    FocusGuard.instance = guard;
    state = await loadState();
  });

  tearDown(() => FocusGuard.instance = ChannelFocusGuard());

  test('Focus settings survive a save and give the native side tonight\'s sleep window', () async {
    await state.updateSettings((s) {
      s.wakeTime = const TimeOfDay(hour: 5, minute: 0);
      s.sleepHours = 7.5;
      s.focusEnabled = true;
      s.focusStrict = true;
      s.focusApps = [const FocusApp('com.google.android.youtube', 'YouTube', limitMin: 20)];
    });
    final back = Settings.fromJson(jsonDecode(jsonEncode(state.settings.toJson())));
    expect(back.focusApps.single.limitMin, 20);
    expect(back.focusStrict, isTrue);
    expect(Settings.fromJson({}).focusSleep, isTrue);
    expect(guard.config, {
      'enabled': true,
      'apps': {
        'com.google.android.youtube': {'name': 'YouTube', 'limit': 20},
      },
      'sleep': true,
      'bedMin': 21 * 60 + 30,
      'wakeMin': 5 * 60,
      'strict': true,
      'wakeLabel': DateFormat.jm().format(DateTime(2000, 1, 1, 5)),
    });
  });

  testWidgets('Focus page: allow pausing, choose apps, set a limit', (tester) async {
    tester.view.physicalSize = const Size(420, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    guard.today = {'com.instagram.android': const AppUsage(Duration(minutes: 12), 4)};
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SettingsScreen(state: state))));
    await tester.pumpAndSettle();
    expect(find.text('Choose apps and set their limits'), findsOneWidget);
    await tester.tap(find.text('Focus & screen time'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('focus-setup')), findsOneWidget);
    await tester.tap(find.text('Turn on'));
    await tester.pumpAndSettle();
    expect(find.textContaining('never reads what is on the screen'), findsOneWidget);
    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
    expect(guard.settingsOpened, 1);
    await tester.tap(find.text('Switch greyed out?'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open app info'));
    await tester.pumpAndSettle();
    expect(guard.appInfoOpened, 1);

    await tester.tap(find.text('Choose apps'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Instagram'));
    await tester.pump();
    await tester.tap(find.text('Done · 1 chosen'));
    await tester.pumpAndSettle();
    expect(state.settings.focusApps.single.package, 'com.instagram.android');
    expect(find.text('30 min a day · 12 min used today'), findsOneWidget);

    await tester.tap(find.text('Instagram'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('15 min'));
    await tester.pumpAndSettle();
    expect(state.settings.focusApps.single.limitMin, 15);

    await tester.tap(find.text('Pause chosen apps'));
    await tester.pumpAndSettle();
    expect(state.settings.focusEnabled, isTrue);
    expect(guard.config!['enabled'], isTrue);
    expect(guard.config!['apps'], {
      'com.instagram.android': {'name': 'Instagram', 'limit': 15},
    });
    expect(find.textContaining('from your wake-up time and sleep goal'), findsOneWidget);

    await tester.tap(find.byTooltip('Remove Instagram'));
    await tester.pumpAndSettle();
    expect(state.settings.focusApps, isEmpty);
  });

  testWidgets('Progress shows screen time for the chosen apps', (tester) async {
    tester.view.physicalSize = const Size(420, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await state.updateSettings(
      (s) => s.focusApps = [
        const FocusApp('com.google.android.youtube', 'YouTube', limitMin: 30),
        const FocusApp('com.instagram.android', 'Instagram', limitMin: 0),
      ],
    );
    guard.today = {
      'com.google.android.youtube': const AppUsage(Duration(minutes: 31), 6),
      'com.instagram.android': const AppUsage(Duration(minutes: 3), 1),
    };
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ProgressScreen(state: state))));
    await tester.pumpAndSettle();
    expect(find.text('Screen time today'), findsOneWidget);
    expect(find.text('31 min / 30 min'), findsOneWidget);
    expect(find.text('Opened 6 times · daily limit reached'), findsOneWidget);
    expect(find.text('3 min'), findsOneWidget);
    expect(find.text('Opened 1 time'), findsOneWidget);
  });

  testWidgets('Focus status follows a stopped service and an external revocation', (tester) async {
    tester.view.physicalSize = const Size(420, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await state.updateSettings((s) {
      s.focusEnabled = true;
      s.focusApps = [const FocusApp('com.instagram.android', 'Instagram')];
    });
    guard.enabled = true;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SettingsScreen(state: state))));
    await tester.pumpAndSettle();
    expect(find.text('1 app selected · service stopped'), findsOneWidget);
    guard.running = true;
    await tester.tap(find.text('Focus & screen time'));
    await tester.pumpAndSettle();
    expect(find.text('1 app selected · protection active'), findsOneWidget);
    await tester.tap(find.text('Test pause'));
    expect(guard.testedPackage, 'com.instagram.android');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    guard.enabled = false;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('1 app selected · permission needed'), findsOneWidget);
    expect(find.text('Test pause'), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('1 app selected · permission needed'), findsOneWidget);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ProgressScreen(state: state))));
    await tester.pumpAndSettle();
    expect(find.text('1 app selected · permission needed'), findsOneWidget);
  });

  test('fmtUsage', () {
    expect(fmtUsage(const Duration(minutes: 45)), '45 min');
    expect(fmtUsage(const Duration(minutes: 60)), '1 h');
    expect(fmtUsage(const Duration(minutes: 95)), '1 h 35 min');
  });
}
