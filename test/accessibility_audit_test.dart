import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_tracker/screens/home_screen.dart';
import 'package:habit_tracker/screens/settings_screen.dart';
import 'package:habit_tracker/widgets/charts.dart';
import 'support.dart';

void main() {
  setUp(mockPlugins);

  testWidgets('text alternative distinguishes missing data from a logged zero', (t) async {
    await t.pumpWidget(MaterialApp(home: Scaffold(body: DailyBarChart(
      values: const [null, 0, 3], target: 4, end: DateTime(2026, 11, 25), unit: 'minutes',
    ))));
    await t.tap(find.text('Chart values'));
    await t.pumpAndSettle();
    expect(find.textContaining('23, 2026: Not logged'), findsOneWidget);
    expect(find.textContaining('24, 2026: 0 minutes'), findsOneWidget);
    expect(find.textContaining('25, 2026: 3 minutes'), findsOneWidget);
  });

  testWidgets('search for a download reaches Voice settings and preserves the search on back', (t) async {
    final state = await loadState();
    await t.pumpWidget(MaterialApp(home: Scaffold(body: SettingsScreen(state: state))));
    await t.enterText(find.byType(TextField), 'whisper');
    await t.pumpAndSettle();
    await t.tap(find.text('Voice'));
    await t.pumpAndSettle();
    expect(find.text('Private voice only'), findsOneWidget);
    await t.pageBack();
    await t.pumpAndSettle();
    expect(find.text('whisper'), findsOneWidget);
  });

  testWidgets('split screen swaps the rail for phone navigation', (t) async {
    final state = await loadState();
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(1000, 768);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    await t.pumpWidget(MaterialApp(home: HomeScreen(state: state)));
    await t.pumpAndSettle();
    expect(find.byType(NavigationRail), findsOneWidget);
    t.view.physicalSize = const Size(390, 760);
    await t.pumpAndSettle();
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byType(NavigationBar), findsOneWidget);
  });
}
