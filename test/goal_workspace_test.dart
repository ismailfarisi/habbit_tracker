import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_tracker/app_state.dart';
import 'package:habit_tracker/finance/finance.dart';
import 'package:habit_tracker/goals/goal.dart';
import 'package:habit_tracker/goals/goal_okf.dart';
import 'package:habit_tracker/goals/goal_outcomes.dart';
import 'package:habit_tracker/goals/goals_card.dart';
import 'package:habit_tracker/habits/habit.dart';
import 'package:habit_tracker/logic/stats.dart';
import 'package:habit_tracker/logic/tasks.dart';
import 'package:habit_tracker/models.dart';
import 'package:habit_tracker/screens/calendar_screen.dart';
import 'package:habit_tracker/services/reminders.dart';

import 'package:habit_tracker/services/storage.dart';

import 'support.dart';

class _DelayedGoalStore extends Fake implements Storage {
  _DelayedGoalStore(this.base);
  final Storage base;
  final started = Completer<void>();
  final complete = Completer<void>();
  bool delay = true;

  @override
  Future<void> saveGoals(List<Goal> goals) async {
    if (delay) {
      delay = false;
      started.complete();
      await complete.future;
    }
    await base.saveGoals(goals);
  }

  @override
  Settings loadSettings() => base.loadSettings();
  @override
  Map<String, DayLog> loadLogs() => base.loadLogs();
  @override
  List<Task> loadTasks() => base.loadTasks();
  @override
  List<HabitDef> loadHabits() => base.loadHabits();
  @override
  bool get hasHabits => true;
  @override
  List<Goal> loadGoals() => base.loadGoals();
  @override
  bool get hasFinance => false;
  @override
  Future<String> loadApiKey() async => '';
  @override
  Future<String> loadSecret(String key) async => '';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(mockPlugins);

  final now = dateOnly(DateTime.now());
  Goal goal({List<String>? habits, List<String>? tasks}) => Goal(
    id: 'shop',
    title: 'Open shop',
    start: dayKey(now),
    end: dayKey(now.add(const Duration(days: 30))),
    habitIds: habits,
    taskIds: tasks,
  );

  test('outcomes use completed portions and keep earlier ayat when pace changes', () async {
    final s = await loadState();
    const passage = QuranRef(67, 1, 30, mode: 'memorise', perDay: 3);
    final habit = await s.upsertHabit(
      HabitDef(
        id: 'mulk',
        title: 'Al-Mulk',
        createdAt: now.subtract(const Duration(days: 4)),
        guide: const TaskGuide(quran: passage),
      ),
    );
    final g = goal(habits: [habit.id]);
    await s.upsertGoal(g);
    for (var i = 1; i <= 2; i++) {
      await s.logHabit(now.subtract(Duration(days: i)), habit.id, HabitEntry(done: true));
    }
    expect(goalOutcomes(s, g, now).single.label, 'Al-Mulk · 6 of 30 ayat learned');
    final slower = const QuranRef(67, 1, 30, mode: 'memorise', perDay: 1).replan(passage, 2);
    await s.upsertHabit(habit..guide = TaskGuide(quran: slower));
    expect(s.quranFor(habit, now.subtract(const Duration(days: 1)))!.to, 6);
    expect(s.quranFor(habit, now)!.from, 7);
    await s.logHabit(now, habit.id, HabitEntry(done: true));
    expect(goalOutcomes(s, g, now).single.label, contains('7 of 30 ayat learned'));
    expect(s.storage.loadHabits().singleWhere((h) => h.id == habit.id).guide!.quran!.covered(3), 7);
  });

  test('open practice counts days without a percentage and savings remain local', () async {
    final s = await loadState();
    final h = await s.upsertHabit(HabitDef(id: 'h', title: 'Offer samples'));
    final g = goal(habits: [h.id]);
    await s.upsertGoal(g);
    await s.logHabit(now, h.id, HabitEntry(done: true));
    final p = SavingsPot(name: 'Stall deposit', target: 100000, goalId: g.id);
    await s.upsertPot(p);
    await s.addMoney(MoneyEntry(at: now, amount: 25000, category: 'Savings', potId: p.id));
    final outcomes = goalOutcomes(s, g, now, includeSavings: true);
    expect(outcomes.first.label, contains('1 practice day'));
    expect(outcomes.first.fraction, isNull);
    expect(outcomes.last.label, contains('Stall deposit'));
    expect(outcomes.last.fraction, .25);
    expect(goalOkf(s, g, now), isNot(contains('Stall deposit')));
  });

  test('pause/standalone/restore preserve ownership, completion dates, schedule and reminders', () async {
    final s = await loadState();
    final old = now.subtract(const Duration(days: 2));
    final h = await s.upsertHabit(HabitDef(id: 'bake', title: 'Bake', reminder: '12:00', createdAt: old));
    final t = await s.addTask(title: 'Pack', time: '11:00', repeat: Repeat.daily);
    final g = goal(habits: [h.id], tasks: [t.id]);
    await s.upsertGoal(g);
    await s.logHabit(old, h.id, HabitEntry(done: true));
    await s.setTaskDone(t, old, true);
    List<PlannedReminder> ownReminders(AppState state, DateTime d) => planReminders(
      state.settings,
      state.logs,
      d,
      days: 1,
      habits: state.habits,
      tasks: state.tasks,
    ).where((r) => r.payload.startsWith('task:${t.id}|') || r.payload.startsWith('habit:${h.id}|')).toList();

    await s.setGoalArchived(g, archived: true, at: now);
    expect(s.goalFor(h.id)?.id, g.id);
    expect(s.activeHabits, isNot(contains(h)));
    expect(tasksForDay(s.tasks, now), isNot(contains(t)));
    expect(ownReminders(s, now), isEmpty);
    expect(h.isScheduledOn(old), isTrue);
    expect(s.storage.loadTasks().single.isScheduledOn(now), isFalse);
    expect(s.storage.loadHabits().singleWhere((x) => x.id == h.id).isScheduledOn(now), isFalse);
    await s.refreshFromDisk();
    expect(ownReminders(s, now), isEmpty);
    final restoreDay = now.add(const Duration(days: 1));
    await s.setGoalArchived(s.goals.single, archived: false, at: restoreDay);
    expect(ownReminders(s, restoreDay), hasLength(2));
    expect(s.goals.single.habitIds, [h.id]);
    expect(s.goalFor(t.id)?.id, g.id);
    expect(s.habitEntry(old, h.id).done, isTrue);
    expect(s.taskById(t.id)!.isDoneOn(old), isTrue);
    expect(calendarDay(s, now, restoreDay).tasks, 0);
    await s.setGoalArchived(s.goals.single, archived: true, pauseWork: false, at: restoreDay);
    expect(s.goalFor(t.id), isNull);
    expect(s.goals.single.owns(t.id), isTrue);
    expect(ownReminders(s, restoreDay), hasLength(2));
    await s.setGoalArchived(s.goals.single, archived: false, at: restoreDay);
    expect(s.goalFor(t.id)?.id, g.id);
  });

  test('old Markdown notes migrate and only selected current notes enter shared context', () async {
    final s = await loadState();
    final g = Goal.fromJson({...goal().toJson(), 'notes': '- Rent estimate\n- Call supplier'});
    expect(g.noteEntries, hasLength(2));
    g.noteEntries[0] = GoalNote('Rent confirmed at 500', shared: true, changedOn: '2026-11-25');
    g.noteEntries[1].shared = false;
    g.noteEntries.add(GoalNote('Family note'));
    await s.upsertGoal(g);
    final stored = s.storage.loadGoals().single;
    expect(stored.noteEntries, hasLength(3));
    final reviewed = goalOkf(s, stored, now);
    expect(reviewed, contains('2026-11-25 · Rent confirmed at 500'));
    for (final private in ['Rent estimate', 'Call supplier', 'Family note']) {
      expect(reviewed, isNot(contains(private)));
      expect(okfBundle(s, now).values.join(), isNot(contains(private)));
    }
  });

  test('a failed durable write does not mark a review applied, and a retry creates only one milestone', () async {
    final initial = await loadState();
    final g = goal()..reviews.add(GoalReview(at: now, summary: 'Review', suggestions: ['Book stall']));
    await initial.upsertGoal(g);
    final failing = _DelayedGoalStore(initial.storage);
    final state = await AppState.load(failing, initial.notifications);
    final original = state.goals.single;

    final save = state.applyGoalSuggestion(original, original.reviews.single, 0, title: 'Reserve a stall');
    await failing.started.future;
    expect(state.goals.single.milestones, isEmpty);
    expect(state.goals.single.reviews.single.applied, isEmpty);
    failing.complete.completeError(StateError('Write failed'));
    await expectLater(save, throwsStateError);
    expect(state.storage.loadGoals().single.reviews.single.applied, isEmpty);
    expect(state.goalById(g.id)!, same(original));

    await state.applyGoalSuggestion(original, original.reviews.single, 0, title: 'Reserve a stall');
    final persisted = state.storage.loadGoals().single;
    expect(persisted.reviews.single.milestoneLinks[0], persisted.milestones.single.id);
  });

  Future<void> largeView(WidgetTester tester) async {
    tester.view.physicalSize = const Size(680, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('cancel leaves suggestion available; apply links the edited milestone and undo removes it', (
    tester,
  ) async {
    await largeView(tester);
    final s = await loadState();
    final g = goal()..reviews.add(GoalReview(at: now, summary: 'Plan the stall', suggestions: ['Set a launch date']));
    await s.upsertGoal(g);
    await tester.pumpWidget(
      MaterialApp(
        home: GoalScreen(state: s, goalId: g.id),
      ),
    );
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(s.storage.loadGoals().single.reviews.single.applied, isEmpty);
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Book the stall');
    await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
    await tester.pumpAndSettle();
    final stored = s.storage.loadGoals().single;
    expect(stored.reviews.single.milestoneLinks[0], stored.milestones.single.id);
    expect(stored.milestones.single.title, 'Book the stall');
    expect(s.chatPrompt.value, isNull);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(s.storage.loadGoals().single.milestones, isEmpty);
    expect(s.goals.single.reviews.single.applied, isEmpty);
    expect(find.text('Preview'), findsOneWidget);
  });

  testWidgets('attach a savings pot, open its editor, and keep the balance out of the shared preview', (tester) async {
    await largeView(tester);
    final s = await loadState();
    final g = goal();
    await s.upsertGoal(g);
    await s.upsertPot(SavingsPot(id: 'shop-deposit', name: 'Stall deposit', target: 100000));
    await tester.pumpWidget(
      MaterialApp(
        home: GoalScreen(state: s, goalId: g.id),
      ),
    );
    await tester.tap(find.text('Attach existing work'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stall deposit'));
    await tester.pumpAndSettle();
    expect(s.finance.pot('shop-deposit')!.goalId, g.id);
    await tester.tap(find.textContaining('Stall deposit ·'));
    await tester.pumpAndSettle();
    expect(find.text('Edit pot'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preview shared context'));
    await tester.pumpAndSettle();
    expect(find.textContaining('shared with this chat'), findsOneWidget);
    await tester.tap(find.byKey(const Key('doc-source')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Stall deposit'), findsNothing);
  });

  testWidgets('edit an assumption, choose what to share, and remove a note', (tester) async {
    await largeView(tester);
    final s = await loadState();
    final g = goal()..noteEntries.addAll([GoalNote('Old supplier', shared: true), GoalNote('Home address')]);
    await s.upsertGoal(g);
    await tester.pumpWidget(
      MaterialApp(
        home: GoalScreen(state: s, goalId: g.id),
      ),
    );
    await tester.tap(find.text('Old supplier'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Supplier confirmed');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final markdown = goalOkf(s, s.goals.single, now);
    expect(markdown, contains('${dayKey(now)} · Supplier confirmed'));
    expect(markdown, isNot(contains('Home address')));
    await tester.tap(find.byTooltip('Remove note').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(s.storage.loadGoals().single.noteEntries.map((n) => n.text), ['Supplier confirmed']);
  });

  testWidgets('attach recurring work and reorder the shared plan without AI', (tester) async {
    await largeView(tester);
    final s = await loadState();
    final g = goal();
    final h = await s.upsertHabit(
      HabitDef(
        id: 'shop',
        title: 'Shop practice',
        guide: const TaskGuide(steps: ['Make samples'], sessions: ['Stock shelves', 'Price samples']),
      ),
    );
    await s.upsertGoal(g);
    await tester.pumpWidget(
      MaterialApp(
        home: GoalScreen(state: s, goalId: g.id),
      ),
    );
    await tester.tap(find.text('Attach existing work'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Shop practice'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Shop practice').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Move down').first);
    await tester.enterText(find.widgetWithText(TextFormField, 'Done when'), 'Three prices are posted');
    await tester.tap(find.text('Save instructions'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Session 1/2: Price samples'), findsOneWidget);
    final current = s.habitById(h.id)!;
    expect(current.guide!.doneWhen, 'Three prices are posted');
    expect(s.goalFor(h.id)?.id, g.id);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GoalTodayCard(state: s, goal: s.goals.single, now: now),
        ),
      ),
    );
    expect(find.textContaining('Session 1/2: Price samples'), findsOneWidget);
    await tester.pumpWidget(MaterialApp(home: CalendarScreen(state: s)));
    await tester.pumpAndSettle();
    expect(find.textContaining('Session 1/2: Price samples'), findsOneWidget);
  });
}
