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
import '../widgets/adaptive.dart';

enum TodayKind { wake, prayers, habit, tasks }

/// One card on Today: when it is next due (null = any time) and whether it
/// is finished for the day.
class TodayItem {
  final TodayKind kind;
  final DateTime? due;
  final bool done;
  final HabitDef? habit;
  const TodayItem(this.kind, {this.due, required this.done, this.habit});

  String get id => habit?.id ?? kind.name;

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
    for (final h in state.activeHabits)
      if (h.isScheduledOn(now))
        TodayItem(
          TodayKind.habit,
          habit: h,
          due: h.reminder == null ? null : at(parseHm(h.reminder!)),
          done: habitDone(log.habits[h.id], h),
        ),
    TodayItem(TodayKind.tasks, due: TasksCard.nextDue(state, now), done: TasksCard.allDone(state, now)),
  ];
  int byDue(TodayItem a, TodayItem b) {
    if (a.due == null || b.due == null) return (a.due == null ? 1 : 0) - (b.due == null ? 1 : 0);
    return a.due!.compareTo(b.due!);
  }

  final pending = items.where((i) => !i.done).toList();
  final done = items.where((i) => i.done).toList();
  stableSort(pending, byDue);
  stableSort(done, byDue);
  return [...pending, ...done];
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

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 30), (_) => setState(() {}));
    _checkNotifications();
    widget.state.requestedHabit.addListener(_openRequestedHabit);
    WidgetsBinding.instance.addPostFrameCallback((_) => _openRequestedHabit());
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
      TodayKind.wake => WakeCard(key: const ValueKey('today-wake'), state: state, log: state.logFor(now)),
      TodayKind.prayers => PrayerCard(
        key: const ValueKey('today-prayers'),
        state: state,
        log: state.logFor(now),
        now: now,
      ),
      TodayKind.habit => HabitCard(key: ValueKey(i.habit!.id), state: state, habit: i.habit!, day: now),
      TodayKind.tasks => TasksCard(
        key: const ValueKey('today-tasks'),
        state: state,
        now: now,
        onOpen: () => widget.onNavigate(HomeScreen.planTab),
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final s = widget.state.settings;
        final now = (widget.clock ?? DateTime.now)();
        final score = dayScore(now, s, widget.state.logs, habits: widget.state.habits, tasks: widget.state.tasks);
        final items = todayItems(widget.state, now);
        final pending = items.where((i) => !i.done).toList();
        final done = items.where((i) => i.done).toList();
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _Header(now: now, score: score, hijri: '${hijriToday(s, now)}'),
            const SizedBox(height: 16),
            if (_notifOn == false)
              _Banner(
                icon: Icons.notifications_off_outlined,
                text: 'Notifications are off, so reminders and the wake-up alarm can\'t ring.',
                action: 'Enable',
                onTap: _enableNotifications,
              ),
            if (!s.hasLocation && !s.useManualPrayer)
              _Banner(
                icon: Icons.location_off_outlined,
                text: 'Set your location for accurate prayer times. Using default times for now.',
                action: 'Set up',
                onTap: () => widget.onNavigate(HomeScreen.settingsTab),
              ),
            YesterdayPrompt(state: widget.state, now: now),
            for (final i in pending) _card(i, now),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Center(
                child: FilledButton.tonalIcon(
                  style: compactButton,
                  onPressed: () => showAddHabitSheet(context, widget.state),
                  icon: const Icon(Icons.add),
                  label: const Text('Add habit'),
                ),
              ),
            ),
            if (done.isNotEmpty) ...[
              ListTile(
                key: const ValueKey('today-done'),
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                leading: const Icon(Icons.check_circle_outline),
                title: Text('Done (${done.length})', style: const TextStyle(fontWeight: FontWeight.w600)),
                trailing: Icon(_showDone ? Icons.expand_less : Icons.expand_more),
                onTap: () => setState(() => _showDone = !_showDone),
              ),
              if (_showDone)
                for (final i in done) _card(i, now),
            ],
          ],
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  final DateTime now;
  final DayScore score;
  final String hijri;
  const _Header({required this.now, required this.score, required this.hijri});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark;
    final greeting = now.hour < 12 ? 'Good morning' : (now.hour < 17 ? 'Good afternoon' : 'Good evening');
    const fg = Colors.white;
    final dim = fg.withValues(alpha: 0.78);
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 16, 18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? const [Color(0xFF0F4F4A), Color(0xFF0F766E)]
              : const [Color(0xFF0F766E), Color(0xFF14B8A6)],
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0F766E).withValues(alpha: dark ? 0.25 : 0.3),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  greeting,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.textTheme.titleLarge?.copyWith(color: fg, fontSize: 22, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 2),
                Text(DateFormat('EEEE, d MMMM').format(now), style: t.textTheme.bodyMedium?.copyWith(color: dim)),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color: fg.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Text(
                    hijri,
                    key: const ValueKey('hijri-date'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.textTheme.labelSmall?.copyWith(color: fg, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 64,
            height: 64,
            child: Stack(
              fit: StackFit.expand,
              children: [
                CircularProgressIndicator(
                  value: score.fraction,
                  strokeWidth: 6,
                  strokeCap: StrokeCap.round,
                  color: fg,
                  backgroundColor: fg.withValues(alpha: 0.2),
                ),
                Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text('$score', style: t.textTheme.titleMedium?.copyWith(color: fg, fontWeight: FontWeight.w800)),
                    Text('today', style: t.textTheme.labelSmall?.copyWith(color: dim)),
                  ]),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  final IconData icon;
  final String text;
  final String action;
  final VoidCallback onTap;
  const _Banner({required this.icon, required this.text, required this.action, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Card(
      color: c.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
        child: Row(
          children: [
            Icon(icon, color: c.onTertiaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: c.onTertiaryContainer)),
            ),
            TextButton(onPressed: onTap, child: Text(action)),
          ],
        ),
      ),
    );
  }
}
