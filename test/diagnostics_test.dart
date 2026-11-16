import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_tracker/screens/diagnostics_screen.dart';
import 'package:habit_tracker/screens/settings_screen.dart';
import 'package:habit_tracker/services/diagnostics.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

Future<Diagnostics> _diag({bool on = true, DateTime? now}) async {
  SharedPreferences.setMockInitialValues({});
  final d = Diagnostics(await SharedPreferences.getInstance(), clock: () => now ?? DateTime(2026, 6, 1, 9));
  if (on) await d.setEnabled(true);
  return d;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(mockPlugins);

  group('ringPush', () {
    test('keeps the newest items up to capacity', () {
      var buf = <int>[];
      for (var i = 1; i <= 5; i++) {
        buf = ringPush(buf, i, 3);
      }
      expect(buf, [3, 4, 5]);
      expect(ringPush(<int>[], 1, 3), [1]);
    });
  });

  group('Diagnostics', () {
    test('off by default: nothing is recorded', () async {
      final d = await _diag(on: false);
      expect(d.enabled, isFalse);
      await d.count(Diagnostics.remindersScheduled, 5);
      await d.recordError(StateError('boom'), StackTrace.current);
      expect(d.counter(Diagnostics.remindersScheduled), 0);
      expect(d.errors, isEmpty);
      expect(d.prefs.getKeys().where((k) => k.startsWith('diagnostics.count.')), isEmpty);
    });

    test('counts while on; counters live in separate keys', () async {
      final d = await _diag();
      await d.count(Diagnostics.remindersScheduled, 12);
      await d.count(Diagnostics.remindersScheduled, 3);
      await d.count(Diagnostics.opensFromNotification);
      await d.count('custom_thing');
      expect(d.counter(Diagnostics.remindersScheduled), 15);
      expect(d.prefs.getInt('diagnostics.count.opens_from_notification'), 1);
      expect(d.counters.keys.first, Diagnostics.appOpens);
      expect(d.counters['custom_thing'], 1);
      expect(d.since, DateTime(2026, 6, 1, 9));
    });

    test('error log is a ring buffer of the last 50', () async {
      final d = await _diag();
      for (var i = 0; i < 60; i++) {
        await d.recordError('error $i', null, source: 'test');
      }
      final errors = d.errors;
      expect(errors, hasLength(Diagnostics.maxErrors));
      expect(errors.first.message, 'error 10');
      expect(errors.last.message, 'error 59');
      expect(errors.last.source, 'test');
    });

    test('long messages and stacks are clipped', () async {
      final d = await _diag();
      await d.recordError('x' * 5000, StackTrace.fromString(List.generate(100, (i) => '#$i frame').join('\n')));
      final e = d.errors.single;
      expect(e.message.length, lessThanOrEqualTo(2001));
      expect(e.stack.split('\n'), hasLength(20));
    });

    test('turning off deletes everything; clear keeps it on', () async {
      final d = await _diag();
      await d.count(Diagnostics.appOpens);
      await d.recordError('e', null);
      await d.clear();
      expect(d.enabled, isTrue);
      expect(d.counter(Diagnostics.appOpens), 0);
      expect(d.errors, isEmpty);

      await d.count(Diagnostics.appOpens);
      await d.setEnabled(false);
      expect(d.counter(Diagnostics.appOpens), 0);
      expect(d.since, isNull);
      expect(d.enabled, isFalse);
    });

    test('report lists counters and errors only', () async {
      final d = await _diag();
      await d.count(Diagnostics.remindersScheduled, 7);
      await d.recordError(FormatException('bad'), null, source: 'platform');
      final r = d.report();
      expect(r, contains('Reminders scheduled: 7'));
      expect(r, contains('[platform] FormatException: bad'));
      expect(r, contains('Errors (1, newest first)'));
    });

    test('installErrorHandlers records Flutter and platform errors and chains', () async {
      final d = await _diag();
      final oldFlutter = FlutterError.onError;
      final oldPlatform = PlatformDispatcher.instance.onError;
      final seen = <String>[];
      FlutterError.onError = (details) => seen.add('flutter');
      PlatformDispatcher.instance.onError = (e, st) {
        seen.add('platform');
        return true;
      };
      try {
        d.installErrorHandlers();
        FlutterError.onError!(FlutterErrorDetails(exception: StateError('widget'), library: 'widgets library'));
        expect(PlatformDispatcher.instance.onError!(StateError('async'), StackTrace.empty), isTrue);
        await Future<void>.delayed(Duration.zero);
      } finally {
        FlutterError.onError = oldFlutter;
        PlatformDispatcher.instance.onError = oldPlatform;
      }
      expect(seen, ['flutter', 'platform']);
      expect(d.errors.map((e) => e.source), ['widgets library', 'platform']);
    });
  });

  group('screens', () {
    testWidgets('Diagnostics screen: opt in, see counters and errors, share report', (tester) async {
      final d = await _diag(on: false);
      await tester.binding.setSurfaceSize(const Size(420, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      String? shared;
      await tester.pumpWidget(MaterialApp(
        home: DiagnosticsScreen(diagnostics: d, onShare: (r) async => shared = r),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Diagnostics are off. Nothing is being recorded.'), findsOneWidget);
      expect(find.text('Share report'), findsNothing);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(d.enabled, isTrue);
      await d.count(Diagnostics.remindersScheduled, 4);
      await d.recordError('Something broke', null, source: 'platform');
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.text('No errors recorded.'), findsOneWidget, reason: 'toggling off and on clears');

      await d.count(Diagnostics.remindersScheduled, 4);
      await d.recordError('Something broke', null, source: 'platform');
      await tester.pumpWidget(MaterialApp(
        home: DiagnosticsScreen(key: UniqueKey(), diagnostics: d, onShare: (r) async => shared = r),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Reminders scheduled'), findsOneWidget);
      expect(find.text('4'), findsOneWidget);
      expect(find.text('Something broke'), findsOneWidget);

      await tester.ensureVisible(find.text('Share report'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Share report'));
      await tester.pumpAndSettle();
      expect(shared, contains('Reminders scheduled: 4'));
      expect(shared, contains('Something broke'));
    });

    testWidgets('Settings has the diagnostics switch (off) and opens the screen', (tester) async {
      final state = await loadState();
      await tester.binding.setSurfaceSize(const Size(420, 4000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: SettingsScreen(state: state))));
      final tile = find.widgetWithText(SwitchListTile, 'Collect diagnostics on this phone');
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(tile).value, isFalse);
      expect(find.textContaining('Nothing is sent anywhere'), findsOneWidget);

      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(Diagnostics(state.storage.prefs).enabled, isTrue);

      await tester.ensureVisible(find.text('Counters, error log and "Share report"'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Counters, error log and "Share report"'));
      await tester.pumpAndSettle();
      expect(find.text('Counters'), findsOneWidget);
      expect(find.text('App starts'), findsOneWidget);
    });
  });
}
