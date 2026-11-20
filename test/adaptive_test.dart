import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_tracker/app_state.dart';
import 'package:habit_tracker/main.dart';
import 'package:habit_tracker/widgets/adaptive.dart';

import 'support.dart';

final _onboarded = {
  'settings.v1': jsonEncode({'onboarded': true}),
  'habits.v1': '[]',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(mockPlugins);

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    late AppState state;
    await tester.runAsync(() async {
      state = await loadState(_onboarded);
    });
    await tester.pumpWidget(DailyDisciplineApp(state: state));
    await tester.pumpAndSettle();
  }

  testWidgets('Android uses the floating Material navigation bar', (tester) async {
    await pumpApp(tester);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(CupertinoTabBar), findsNothing);
    expect(find.widgetWithText(AppBar, 'Today'), findsOneWidget);
  });

  testWidgets('iOS uses a Cupertino tab bar and the screen title', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await pumpApp(tester);
      expect(find.byType(CupertinoTabBar), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      await tester.tap(find.text('Progress').last);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Progress'), findsOneWidget);
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.byType(Switch), findsWidgets);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('compact buttons look small but keep a 48dp tap target', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(Brightness.light),
      home: Scaffold(
        body: Center(
          child: FilledButton.tonal(style: compactButton, onPressed: () {}, child: const Text('Done')),
        ),
      ),
    ));
    final tap = tester.getSize(find.byType(FilledButton));
    expect(tap.height, 48);
    final visual = tester.getSize(find.descendant(of: find.byType(FilledButton), matching: find.byType(Material)));
    expect(visual.height, 34);
  });

  testWidgets('confirmDialog is a Cupertino alert on iOS and returns the choice', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      bool? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (c) => TextButton(
            onPressed: () async =>
                result = await confirmDialog(c, title: 'Delete?', message: 'Gone.', confirm: 'Delete', destructive: true),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoAlertDialog), findsOneWidget);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(result, isTrue);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
