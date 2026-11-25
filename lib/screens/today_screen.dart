import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../habits/habit.dart';
import '../logic/prayer_status.dart';
import '../logic/sleep.dart';
import '../logic/stats.dart';
import '../models.dart';
import '../services/prayer_service.dart';
import '../widgets/add_habit_sheet.dart';
import '../widgets/cards/habit_card.dart';
import '../widgets/cards/prayer_card.dart';
import '../widgets/cards/tasks_card.dart';
import '../widgets/cards/wake_card.dart';
import '../widgets/yesterday_prompt.dart';
import 'habit_detail_screen.dart';
import 'home_screen.dart';
import '../goals/goal.dart';
import '../finance/money_screen.dart';
import '../goals/goals_card.dart';
import '../logic/tasks.dart';
import '../widgets/customize_today.dart';
import '../widgets/task_editor.dart';
import 'settings_screen.dart';

enum TodayKind { wake, prayers, habit, goal, tasks, money }

/// One card on Today: when it is next due (null = any time) and whether it
/// is finished for the day.
class TodayItem {
  final TodayKind kind;
  final DateTime? due;
  final bool done;
  final HabitDef? habit;
  final Goal? goal;
  const TodayItem(this.kind, {this.due, required this.done, this.habit, this.goal});

  String get id => goal != null ? 'goal-${goal!.id}' : habit?.id ?? kind.name;

  @override
  String toString() => '$id${done ? ' (done)' : ''}';
}

/// Today's cards in time-of-day order: unfinished items first, the next due
/// first, untimed habits after the timed ones; finished items last (shown
/// collapsed under "Done"). Wake is due at the wake goal and comes back in
/// the evening until bedtime is logged; prayers stay open while an enabled
/// optional prayer is unticked. Prayers are due at the
/// first prayer not yet prayed, habits at their reminder and tasks at the
/// next unfinished timed task.
List<TodayItem> todayItems(AppState state, DateTime now) {
  final s = state.settings;
  final log = state.logFor(now);
  final times = prayerTimesFor(s, now).times;
  final nextPrayer = prayerNames.where((p) => !log.prayers.contains(p)).firstOrNull;
  DateTime at(TimeOfDay t) => DateTime(now.year, now.month, now.day, t.hour, t.minute);
  final items = [
    TodayItem(
      TodayKind.wake,
      due: log.wakeAt == null ? at(s.wakeTime) : windDownFor(s, nightOf(now)),
      done: log.wakeAt != null && !bedtimeCheckInDue(s, state.logs, now),
    ),
    TodayItem(
      TodayKind.prayers,
      due: nextPrayer == null ? times[prayerNames.last] : times[nextPrayer],
      done: nextPrayer == null && optionalPrayersOn(s, now).every((p) => log.habits[p.id]?.done ?? false),
    ),
    for (final g in state.goals.where((g) => !g.archived))
      if (GoalTodayCard.itemsFor(state, g, now) case (
        final habits,
        final tasks,
      ) when habits.isNotEmpty || tasks.isNotEmpty)
        TodayItem(
          TodayKind.goal,
          goal: g,
          due: [
            for (final h in habits)
              if (h.reminder != null && !habitDone(log.habits[h.id], h)) at(parseHm(h.reminder!)),
            for (final t in tasks)
              if (!t.isDoneOn(now) && t.reminderOn(now) != null) t.reminderOn(now)!,
          ].fold<DateTime?>(null, (a, b) => a == null || b.isBefore(a) ? b : a),
          done: habits.every((h) => habitDone(log.habits[h.id], h)) && tasks.every((t) => t.isDoneOn(now)),
        ),
    for (final h in state.activeHabits)
      if (h.isScheduledOn(now) && state.goalFor(h.id) == null)
        TodayItem(
          TodayKind.habit,
          habit: h,
          due: h.reminder == null ? null : at(parseHm(h.reminder!)),
          done: habitDone(log.habits[h.id], h),
        ),
    TodayItem(TodayKind.tasks, due: TasksCard.nextDue(state, now), done: TasksCard.allDone(state, now)),
    if (!state.finance.isEmpty || s.showMoneyShortcut || s.todayPinned.contains('money'))
      const TodayItem(TodayKind.money, done: false),
  ]..removeWhere((i) => s.todayHidden.contains(i.id));

  final pending = items.where((i) => !i.done).toList();
  final done = items.where((i) => i.done).toList();
  stableSort(pending, (a, b) => _byTime(a.due, b.due));
  stableSort(done, (a, b) => _byTime(a.due, b.due));
  int pin(TodayItem i) {
    final p = s.todayPinned.indexOf(i.id);
    return p < 0 ? s.todayPinned.length : p;
  }

  stableSort(pending, (a, b) => pin(a) - pin(b));
  return [...pending, ...done];
}

int _byTime(DateTime? a, DateTime? b) {
  if (a == null || b == null) return (a == null ? 1 : 0) - (b == null ? 1 : 0);
  return a.compareTo(b);
}

/// Insertion sort that keeps equal items in order.
void stableSort<T>(List<T> list, int Function(T a, T b) compare) {
  for (var i = 1; i < list.length; i++) {
    final v = list[i];
    var j = i - 1;
    while (j >= 0 && compare(list[j], v) > 0) {
      list[j + 1] = list[j];
      j--;
    }
    list[j + 1] = v;
  }
}

class TodayScreen extends StatefulWidget {
  final AppState state;
  final void Function(int tab) onNavigate;

  /// Current time; defaults to [DateTime.now] (tests pass a fixed clock).
  final DateTime Function()? clock;
  const TodayScreen({super.key, required this.state, required this.onNavigate, this.clock});

  @override
  State<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends State<TodayScreen> {
  Timer? _tick;
  bool? _notifOn;
  bool _showDone = false;
  bool _showLater = false;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 30), (_) => setState(() {}));
    _checkNotifications();
    widget.state.notifications.wakeChallengeRequest.addListener(_openWake);
    WidgetsBinding.instance.addPostFrameCallback((_) => _openWake());
    widget.state.requestedHabit.addListener(_openRequestedHabit);
    WidgetsBinding.instance.addPostFrameCallback((_) => _openRequestedHabit());
  }

  void _openWake() {
    if (mounted) openRequestedWake(context, widget.state, (widget.clock ?? DateTime.now)());
  }

  /// Opens the habit a notification asked for.
  void _openRequestedHabit() {
    final id = widget.state.requestedHabit.value;
    if (id == null || !mounted) return;
    widget.state.requestedHabit.value = null;
    if (widget.state.habitById(id) == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => HabitDetailScreen(state: widget.state, habitId: id),
      ),
    );
  }

  @override
  void dispose() {
    widget.state.notifications.wakeChallengeRequest.removeListener(_openWake);
    widget.state.requestedHabit.removeListener(_openRequestedHabit);
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _checkNotifications() async {
    final on = await widget.state.notifications.enabled();
    if (mounted) setState(() => _notifOn = on);
  }

  Future<void> _enableNotifications() async {
    await widget.state.notifications.requestPermissions();
    await widget.state.rescheduleNow();
    await _checkNotifications();
  }

  Widget _card(TodayItem i, DateTime now) {
    final state = widget.state;
    return switch (i.kind) {
      TodayKind.wake => WakeCard(key: const ValueKey('today-wake'), state: state, log: state.logFor(now), now: now),
      TodayKind.prayers => PrayerCard(
        key: const ValueKey('today-prayers'),
        state: state,
        log: state.logFor(now),
        now: now,
      ),
      TodayKind.habit => HabitCard(key: ValueKey(i.habit!.id), state: state, habit: i.habit!, day: now),
      TodayKind.goal => GoalTodayCard(key: ValueKey(i.id), state: state, goal: i.goal!, now: now),
      TodayKind.money => MoneyTodayCard(key: const ValueKey('today-money'), state: state, now: now),
      TodayKind.tasks => TasksCard(
        key: const ValueKey('today-tasks'),
        state: state,
        now: now,
        onOpen: () => widget.onNavigate(HomeScreen.planTab),
      ),
    };
  }

  /// Split grouped domains into individual actions so opening Later doesn't
  /// repeat the featured task or practice.
  List<Widget> _actions(TodayItem item, DateTime now) {
    final state = widget.state;
    if (item.kind == TodayKind.goal) {
      final (habits, tasks) = GoalTodayCard.itemsFor(state, item.goal!, now);
      final actions = <(DateTime?, Widget)>[];
      for (final h in habits.where((h) => !habitDone(state.habitEntry(now, h.id), h))) {
        final time = h.reminder == null ? null : parseHm(h.reminder!);
        actions.add((time == null ? null : DateTime(now.year, now.month, now.day, time.hour, time.minute),
          Card(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GoalHabitTile(state: state, habit: h, day: now)))));
      }
      for (final task in tasks.where((t) => !t.isDoneOn(now))) {
        actions.add((task.reminderOn(now), _task(task, now)));
      }
      stableSort(actions, (a, b) => _byTime(a.$1, b.$1));
      return [for (final a in actions) a.$2];
    }
    if (item.kind == TodayKind.tasks) {
      return [for (final t in TasksCard.ordered(state, now)) if (!t.isDoneOn(now)) _task(t, now)];
    }
    if (item.kind == TodayKind.prayers) {
      return [
        for (final section in [PrayerSection.next, PrayerSection.remaining])
          PrayerCard(key: ValueKey('today-prayers-${section.name}'),
            state: state, log: state.logFor(now), now: now, section: section),
      ];
    }
    return [_card(item, now)];
  }

  Widget _task(Task task, DateTime now) => Card(child: Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: TaskTile(state: widget.state, task: task, day: now),
  ));

  void _openPrayerSetup() => openSettings(context, widget.state, section: SettingsSection.prayers);

  Widget _setup(String id, String message, String action, VoidCallback onTap) => ListTile(
    title: Text(message),
    subtitle: Wrap(children: [
      TextButton(onPressed: onTap, child: Text(action)),
      TextButton(onPressed: () => widget.state.updateSettings((s) => s.dismissedTodaySetup.add(id)),
        child: const Text('Dismiss')),
    ]),
  );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final state = widget.state;
        final s = state.settings;
        final now = (widget.clock ?? DateTime.now)();
        final items = todayItems(state, now);
        final tasks = TasksCard.ordered(state, now);
        final pending = items.where((i) => !i.done && (i.kind != TodayKind.tasks || tasks.isNotEmpty)).toList();
        final first = pending.firstOrNull;
        final money = pending.where((i) => i.kind == TodayKind.money && i != first).firstOrNull;
        final actions = first == null ? <Widget>[] : _actions(first, now);
        final later = pending.skip(1).where((i) => i != money);
        final done = items.where((i) => i.done).toList();
        final resume = missedYesterday(state, now).isNotEmpty;
        final hasReminder = s.tracks('wake') || s.tracks('prayers') ||
            state.trackedHabits.any((h) => h.reminder != null) || state.trackedTasks.any((t) => t.time != null && !t.isOneOffDone);
        final theme = Theme.of(context);
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(children: [
              Expanded(child: Text(first == null ? 'Your day' : resume ? 'Resume today' : 'Up next',
                style: theme.textTheme.headlineSmall)),
              TextButton.icon(onPressed: () => customizeToday(context, state),
                icon: const Icon(Icons.tune), label: const Text('Customize')),
            ]),
            Padding(padding: const EdgeInsets.only(bottom: 12),
              child: Text([
                DateFormat('EEEE, d MMMM').format(now),
                if (s.tracks('prayers')) hijriToday(s, now).toString(),
              ].join(' · '), style: theme.textTheme.bodySmall)),
            if (actions.isNotEmpty) actions.first
            else Padding(padding: const EdgeInsets.only(bottom: 12),
              child: Text(done.isEmpty ? 'Choose a practice when you’re ready.' : 'Your planned actions are complete.')),
            if (money != null) _card(money, now),
            if (actions.length > 1 || later.isNotEmpty) ...[
              ListTile(title: const Text('Later'), trailing: Icon(_showLater ? Icons.expand_less : Icons.expand_more),
                onTap: () => setState(() => _showLater = !_showLater)),
              if (_showLater) ...[...actions.skip(1), for (final i in later) _card(i, now)],
            ],
            if (resume && now.hour < promptUntilHour)
              ExpansionTile(title: const Text('Edit yesterday’s log'), children: [
                YesterdayPrompt(state: state, now: now),
              ]),
            if (done.isNotEmpty) ...[
              ListTile(key: const ValueKey('today-done'), leading: const Icon(Icons.check_circle_outline),
                title: Text('Done (${done.length})'), trailing: Icon(_showDone ? Icons.expand_less : Icons.expand_more),
                onTap: () => setState(() => _showDone = !_showDone)),
              if (_showDone) for (final i in done) _card(i, now),
            ],
            Align(alignment: AlignmentDirectional.centerStart, child: TextButton.icon(
              onPressed: () => showAddHabitSheet(context, state), icon: const Icon(Icons.add),
              label: const Text('Add habit'),
            )),
            if (s.tracks('prayers') && !s.hasLocation && !s.useManualPrayer && !s.dismissedTodaySetup.contains('location'))
              _setup('location', 'Choose your location for local prayer times.', 'Set up', _openPrayerSetup),
            if (_notifOn == false && s.remindersEnabled && hasReminder && !s.dismissedTodaySetup.contains('notifications'))
              _setup('notifications', 'Enable notifications to hear your reminders.', 'Enable', _enableNotifications),
          ],
        );
      },
    );
  }
}
