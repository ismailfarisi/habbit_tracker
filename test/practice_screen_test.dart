import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_tracker/agent/habit_surface.dart';
import 'package:habit_tracker/agent/habit_templates.dart';
import 'package:habit_tracker/agent/speech_engine.dart';
import 'package:habit_tracker/app_state.dart';
import 'package:habit_tracker/finance/finance.dart';
import 'package:habit_tracker/habits/habit.dart';
import 'package:habit_tracker/screens/habit_detail_screen.dart';

import 'support.dart';

class _Mic extends FakeSpeechEngine {
  final Completer<bool>? permission;
  int starts = 0;
  _Mic({this.permission}) : super('red lorry yellow lorry');

  @override
  Future<bool> init({required void Function() onStopped, required void Function(String message) onError}) =>
      permission?.future ?? Future.value(true);

  @override
  Future<void> listen({required void Function(String) onWords, String? localeId}) {
    starts++;
    return super.listen(onWords: onWords);
  }

  @override
  void dispose() => listening = false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final day = DateTime(2026, 10, 2);
  late AppState state;
  setUp(() async {
    mockPlugins();
    state = await loadState();
  });
  tearDown(() => speechEngineFactory = PluginSpeechEngine.new);

  Future<void> detail(WidgetTester t, HabitDef habit, {Size size = const Size(420, 1500)}) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = size;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        home: HabitDetailScreen(state: state, habitId: habit.id, day: day),
      ),
    );
    await t.pumpAndSettle();
  }

  Future<void> tap(WidgetTester t, String text) async {
    final f = find.text(text).last;
    await t.ensureVisible(f);
    await t.tap(f);
    await t.pumpAndSettle();
  }

  Future<void> edit(WidgetTester t) async {
    await t.tap(find.byType(PopupMenuButton<String>));
    await t.pumpAndSettle();
    await tap(t, 'Edit habit screen');
  }

  Future<void> type(WidgetTester t, String field, String value) async {
    final f = find.widgetWithText(TextFormField, field);
    await t.ensureVisible(f);
    await t.enterText(f, value);
    await t.pump();
  }

  Future<void> recording(WidgetTester t) async {
    await tap(t, 'Start 15-minute practice');
    await tap(t, 'Continue to reading');
    expect(find.text('Record'), findsNothing);
    await tap(t, 'Continue to recording');
  }

  testWidgets('320dp: old articulation layout starts above the fold and resumes at recording after leaving', (t) async {
    final mic = _Mic();
    speechEngineFactory = () => mic;
    final h = await state.upsertHabit(
      habitFromTemplate(articulationTemplate)
        ..uiSurface = surfaceMessage([
          {
            'id': 'root',
            'component': 'Column',
            'children': ['warmup', 'drill', 'timer'],
          },
          {
            'id': 'warmup',
            'component': 'PromptCard',
            'steps': ['Relax your jaw'],
          },
          {'id': 'drill', 'component': 'ReadAloudDrill', 'text': 'Red lorry, yellow lorry'},
          {'id': 'timer', 'component': 'PracticeTimer'},
        ]),
    );
    await detail(t, h, size: const Size(320, 568));
    expect(find.text('Start 15-minute practice').hitTestable(), findsOneWidget);
    expect(find.textContaining('Relax your jaw'), findsNothing);
    await recording(t);
    expect(mic.starts, 0);
    await tap(t, 'Record');
    expect(mic.listening, isTrue);
    await t.pageBack();
    await t.pumpAndSettle();
    expect(mic.listening, isFalse);
    final stored = state.storage.loadLogs().values.single.habits[h.id]!;
    expect(stored.sessions, isEmpty);
    expect(stored.data.values.whereType<Map>().single['stage'], 2);

    await tap(t, 'Resume practice');
    expect(find.text('Record'), findsOneWidget);
    expect(find.text('red lorry yellow lorry'), findsOneWidget);
    expect(mic.starts, 1);
    await tap(t, 'Pause');
    expect(find.text('Resume').hitTestable(), findsOneWidget);
    expect(find.text('Finish & log').hitTestable(), findsOneWidget);
    await tap(t, 'Resume');
    await tap(t, 'Finish & log');
    final e = state.habitEntry(day, h.id);
    expect(e.data, isEmpty);
    expect(e.sessions.single.transcript, 'red lorry yellow lorry');
    expect(e.metrics['accuracy'], 100);
    expect(mic.starts, 1);
    expect(t.takeException(), isNull);
  });

  testWidgets('a pending microphone request cannot begin listening after backgrounding', (t) async {
    final permission = Completer<bool>();
    final mic = _Mic(permission: permission);
    speechEngineFactory = () => mic;
    final h = await state.upsertHabit(habitFromTemplate(articulationTemplate));
    await detail(t, h);
    await recording(t);
    await tap(t, 'Record');
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    permission.complete(true);
    await t.pump();
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpAndSettle();
    expect(mic.starts, 0);
    await tap(t, 'Resume');
    expect(mic.starts, 0);
    await tap(t, 'Finish & log');
    expect(state.habitEntry(day, h.id).sessions, hasLength(1));
    expect(t.takeException(), isNull);
  });

  testWidgets('edit speech steps and target, preview in isolation, log with plain tracker and restore', (t) async {
    final h = await state.upsertHabit(habitFromTemplate(articulationTemplate));
    final prior = HabitEntry(
      minutes: 6,
      metrics: {'wpm': 130},
      notes: 'morning',
      sessions: [
        HabitSession(at: day, durationSec: 360, metrics: {'wpm': 130}, transcript: 'original recording'),
      ],
    );
    await state.logHabit(day, h.id, prior);
    await detail(t, h);
    await edit(t);
    await type(t, 'Daily target', '8');
    await type(t, 'Practice steps', 'Relax your jaw\nRead slowly');
    await type(t, 'Reading passage', 'We speak clearly.');
    await tap(t, 'Preview screen');
    await tap(t, 'Start 8-minute practice');
    expect(find.textContaining('Relax your jaw'), findsOneWidget);
    await tap(t, 'Continue to reading');
    expect(find.text('We speak clearly.'), findsOneWidget);
    await tap(t, 'Finish & log');
    expect(state.habitEntry(day, h.id).toJson(), prior.toJson());
    await t.pageBack();
    await t.pumpAndSettle();
    await tap(t, 'Save');
    expect(state.habitById(h.id)!.target, 8);

    await edit(t);
    await tap(t, 'Plain tracker');
    await tap(t, 'Save');
    await tap(t, 'Log session');
    await type(t, 'Minutes', '3');
    await tap(t, 'Save session');
    expect(state.habitEntry(day, h.id).minutes, 9);
    expect(state.habitEntry(day, h.id).sessions, hasLength(2));

    await edit(t);
    await tap(t, 'Restore previous version');
    await tap(t, 'Save');
    expect(find.text('Start 8-minute practice'), findsOneWidget);
    final e = state.storage.loadLogs().values.single.habits[h.id]!;
    expect(e.sessions.first.toJson(), prior.sessions.single.toJson());
    expect(e.sessions.last.durationSec, 180);
    expect(e.notes, 'morning');
    expect(e.metrics, {'wpm': 130});
    expect(state.storage.loadHabits().single.previousScreen?['usePlainTracker'], true);
    expect(t.takeException(), isNull);
  });

  testWidgets('finance habit preview, plain logging and restore preserve dated ledger entries and custom steps', (
    t,
  ) async {
    final h = await state.upsertHabit(habitFromTemplate(logSpendingTemplate));
    await state.updateFinance((f) => f.currency = 'AED');
    await state.addMoney(MoneyEntry(at: day, amount: 700, category: 'Other', note: h.title));
    await state.addMoney(MoneyEntry(at: day, amount: 2000, category: 'Other', note: h.title, habitId: 'different'));
    await state.logHabit(day, h.id, HabitEntry(value: 99));
    await detail(t, h);
    expect(find.text('AED 7 today · Other'), findsOneWidget);
    await edit(t);
    await type(t, 'Completion target', 'Reviewed my receipts');
    await type(t, 'Tracker steps', 'Keep the receipt');
    await tap(t, 'Preview screen');
    await tap(t, 'Reviewed my receipts');
    expect(state.habitEntry(day, h.id).done, isFalse);
    expect(state.finance.entries, hasLength(2));
    await t.pageBack();
    await t.pumpAndSettle();
    await tap(t, 'Save');

    await edit(t);
    await tap(t, 'Plain tracker');
    await tap(t, 'Save');
    expect(find.byType(HabitFallback), findsOneWidget);
    await tap(t, 'Done today');
    expect(state.habitEntry(day, h.id).done, isTrue);
    expect(state.habitEntry(day, h.id).value, 99);
    await edit(t);
    await tap(t, 'Restore previous version');
    await tap(t, 'Save');
    expect(find.text('Reviewed my receipts'), findsOneWidget);
    expect(find.textContaining('Keep the receipt'), findsOneWidget);
    await t.enterText(find.byType(TextField), '2');
    await tap(t, 'Add');
    expect(state.habitEntry(day, h.id).value, 9);
    expect(state.finance.entries.map((e) => e.amount), [700, 2000, 200]);
    expect(state.finance.entries.last.habitId, h.id);
    expect(t.takeException(), isNull);
  });
}
