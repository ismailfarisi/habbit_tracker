import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_tracker/agent/habit_templates.dart';
import 'package:habit_tracker/app_state.dart';
import 'package:habit_tracker/habits/habit.dart';
import 'package:habit_tracker/logic/stats.dart';
import 'package:habit_tracker/logic/weekly_review.dart';
import 'package:habit_tracker/models.dart';
import 'package:habit_tracker/screens/habit_detail_screen.dart';
import 'package:habit_tracker/screens/stats_screen.dart';
import 'package:habit_tracker/services/openrouter.dart';
import 'package:habit_tracker/widgets/charts.dart';
import 'package:habit_tracker/widgets/day_editor.dart';
import 'package:intl/intl.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppState state;
  final today = dateOnly(DateTime.now());
  DateTime ago(int n) => DateTime(today.year, today.month, today.day - n);

  setUp(() async {
    mockPlugins();
    state = await loadState();
  });

  Future<void> pumpProgress(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: StatsScreen(state: state))));
    await tester.pump();
  }

  testWidgets('tapping a grid cell opens the day editor for that day and edits it', (tester) async {
    await state.setPrayerStatus(ago(3), 'Dhuhr', prayerOnTime);
    await pumpProgress(tester);

    final cell = find.byKey(ProgressGrid.cellKey('prayer:Fajr', ago(2)));
    expect(cell, findsOneWidget);
    await tester.tap(cell);
    await tester.pumpAndSettle();
    expect(find.byType(DayEditor), findsOneWidget);
    expect(find.text(DateFormat('EEEE, d MMMM').format(ago(2))), findsOneWidget);

    await tester.tap(find.widgetWithText(CheckboxListTile, 'Fajr'));
    await tester.pumpAndSettle();
    expect(state.logFor(ago(2)).prayers, contains('Fajr'));
    expect(state.logFor(ago(2)).prayerStatus['Fajr'], prayerOnTime);

    final rows = progressGridRows(state, [ago(2)]);
    expect(rows.firstWhere((r) => r.id == 'prayer:Fajr').cells.single, GridCell.done);
    expect(tester.takeException(), isNull);
  });

  testWidgets('every row has 30 tappable cells, habits and repeating tasks included', (tester) async {
    final water = await state.upsertHabit(habitFromTemplate(waterTemplate, createdAt: ago(40)));
    final walk = await state.addTask(title: 'Walk', repeat: Repeat.daily);
    await pumpProgress(tester);
    for (final id in ['wake', for (final p in prayerNames) 'prayer:$p', 'habit:${water.id}', 'task:${walk.id}']) {
      expect(find.byKey(ProgressGrid.cellKey(id, ago(29))), findsOneWidget, reason: id);
      expect(find.byKey(ProgressGrid.cellKey(id, today)), findsOneWidget, reason: id);
    }
    await tester.tap(find.byKey(ProgressGrid.cellKey('task:${walk.id}', ago(10))));
    await tester.pumpAndSettle();
    expect(find.text(DateFormat('EEEE, d MMMM').format(ago(10))), findsOneWidget);
  });

  test('grid cells: prayer status, wake late, habit partial, unscheduled off', () async {
    final s = state.settings;
    final day = ago(1);
    await state.setPrayerStatus(day, 'Fajr', prayerLate);
    await state.setPrayerStatus(day, 'Dhuhr', prayerQada);
    await state.setPrayerStatus(day, 'Asr', prayerOnTime);
    await state.setWake(day, DateTime(day.year, day.month, day.day, s.wakeTime.hour + 3));
    final water = await state.upsertHabit(habitFromTemplate(waterTemplate, createdAt: ago(5)));
    await state.logHabit(day, water.id, HabitEntry(value: 2));
    final rows = {for (final r in progressGridRows(state, [ago(10), day])) r.id: r.cells};
    expect(rows['prayer:Fajr'], [GridCell.missed, GridCell.late]);
    expect(rows['prayer:Dhuhr']![1], GridCell.qada);
    expect(rows['prayer:Asr']![1], GridCell.done);
    expect(rows['prayer:Isha']![1], GridCell.missed);
    expect(rows['wake']![1], GridCell.late);
    expect(rows['habit:${water.id}'], [GridCell.off, GridCell.partial]);
  });

  testWidgets('streak tiles show the rule, "N of last" and freezes left', (tester) async {
    final quran = await state.upsertHabit(habitFromTemplate(quranTemplate, createdAt: ago(9)));
    for (var i = 1; i <= 8; i++) {
      await state.logHabit(ago(i), quran.id, HabitEntry(done: true));
    }
    await pumpProgress(tester);
    final tile = find.ancestor(of: find.textContaining('Read Quran'), matching: find.byType(StreakTile)).first;
    expect(find.descendant(of: tile, matching: find.text('8 days')), findsOneWidget);
    expect(find.descendant(of: tile, matching: find.text('${ruleLabel(quran.streakRule)} · best 8')), findsOneWidget);
    expect(find.descendant(of: tile, matching: find.text('8 of last 9')), findsOneWidget);
    expect(find.textContaining('freezes left this month'), findsOneWidget);

    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.byType(HabitDetailScreen), findsOneWidget);
  });

  testWidgets('weekly review: hint without a key, Ask coach with one', (tester) async {
    final water = await state.upsertHabit(habitFromTemplate(waterTemplate, createdAt: ago(10)));
    await state.logHabit(ago(1), water.id, HabitEntry(value: 8));
    for (var i = 1; i < 7; i++) {
      for (final p in prayerNames) {
        await state.setPrayerStatus(ago(i), p, prayerOnTime);
      }
    }
    await pumpProgress(tester);
    expect(find.text('Weekly review'), findsOneWidget);
    expect(find.textContaining('Needs work:'), findsOneWidget);
    expect(find.textContaining('Add an OpenRouter API key'), findsOneWidget);
    expect(find.text('Ask coach'), findsNothing);

    await state.setApiKey('k');
    await tester.pump();
    expect(find.text('Ask coach'), findsOneWidget);
  });

  testWidgets('Ask coach sends the weekly review to the coach', (tester) async {
    tester.view.physicalSize = const Size(420, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await state.setApiKey('k');
    await state.setPrayerStatus(ago(1), 'Fajr', prayerOnTime);
    final review = weeklyReview(settings: state.settings, logs: state.logs, today: today);
    final requests = <Map<String, dynamic>>[];
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    }))));
    showWeeklyReviewCoach(
      ctx,
      state,
      review,
      client: () => OpenRouterClient(
        apiKey: 'k',
        model: 'm',
        client: fakeModel([
          [
            {'content': 'Fajr is strong. Fix Dhuhr first.'},
          ],
        ], requests),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.text('📊 Review my week'), findsOneWidget);
    expect(find.textContaining('Fix Dhuhr first'), findsOneWidget);
    final sent = requests.single.toString();
    expect(sent, contains('My weekly review'));
    expect(sent, contains('- Fajr: 1/1'));
    expect(sent, contains('discipline coach'));
  });

  group('habit detail', () {
    HabitSession session(DateTime at, num wpm, num fillers) =>
        HabitSession(at: at, durationSec: 95, metrics: {'wpm': wpm, 'fillers': fillers}, transcript: 'red lorry yellow lorry');

    Future<HabitDef> practised() async {
      final h = await state.upsertHabit(habitFromTemplate(articulationTemplate, createdAt: ago(20)));
      await state.logHabit(ago(5), h.id, HabitEntry(minutes: 10, metrics: {'wpm': 120}, sessions: [
        session(ago(5).add(const Duration(hours: 7)), 110, 4),
        session(ago(5).add(const Duration(hours: 19)), 120, 3),
      ]));
      await state.logHabit(ago(2), h.id, HabitEntry(minutes: 15, metrics: {'accuracy': 80, 'pauses': 2}));
      await state.logHabit(ago(1), h.id, HabitEntry(minutes: 5, sessions: [session(ago(1).add(const Duration(hours: 8)), 135, 1)]));
      return h;
    }

    test('metric series use sessions, falling back to the day value', () async {
      final h = await practised();
      final wpm = habitMetricSeries(state.logs, h, 'wpm');
      expect(wpm.map((p) => p.value), [110, 120, 135]);
      final acc = habitMetricSeries(state.logs, h, 'accuracy');
      expect(acc.single.value, 80);
      expect(dateOnly(acc.single.at), ago(2));
      expect(habitSessions(state.logs, h.id).map((s) => s.metrics['wpm']), [135, 120, 110]);
      expect(habitMetricKeys(state.logs, h).map((f) => f.key), ['wpm', 'fillers', 'accuracy', 'pauses']);
    });

    testWidgets('shows minutes per day, metric charts and the session list', (tester) async {
      final h = await practised();
      tester.view.physicalSize = const Size(420, 6000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: HabitDetailScreen(state: state, habitId: h.id)));
      await tester.pump();
      expect(find.text('Minutes per day'), findsOneWidget);
      expect(find.byType(DailyBarChart), findsOneWidget);
      expect(find.text('Metrics per session'), findsOneWidget);
      expect(find.byType(MetricChartCard), findsNWidgets(4));
      expect(find.byType(LineChart), findsNWidgets(4));
      expect(find.text('135 words/min'), findsOneWidget);
      expect(find.textContaining('+25 since the first of 3'), findsOneWidget);
      expect(find.textContaining('-3 since the first of 3 (lower is better)'), findsOneWidget);
      expect(find.text('Sessions (3)'), findsOneWidget);
      expect(find.byType(SessionTile), findsNWidgets(3));
      expect(find.textContaining('Pace 135 words/min · Filler words 1'), findsOneWidget);

      await tester.tap(find.byType(SessionTile).first);
      await tester.pumpAndSettle();
      expect(find.text('red lorry yellow lorry'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a habit without metrics or sessions shows no charts', (tester) async {
      final h = await state.upsertHabit(habitFromTemplate(quranTemplate, createdAt: ago(3)));
      await tester.pumpWidget(MaterialApp(home: HabitDetailScreen(state: state, habitId: h.id)));
      await tester.pump();
      expect(find.byType(LineChart), findsNothing);
      expect(find.byType(DailyBarChart), findsNothing);
      expect(find.textContaining('Sessions'), findsNothing);
    });
  });
}
