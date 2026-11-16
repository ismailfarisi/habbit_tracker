import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../logic/stats.dart';
import '../services/reminders.dart';
import '../widgets/add_habit_sheet.dart';
import '../widgets/cards/habit_card.dart';
import '../widgets/cards/prayer_card.dart';
import '../widgets/cards/section_card.dart';
import '../widgets/cards/tasks_card.dart';
import '../widgets/cards/wake_card.dart';
import 'habit_detail_screen.dart';
import 'home_screen.dart';

class TodayScreen extends StatefulWidget {
  final AppState state;
  final void Function(int tab) onNavigate;
  const TodayScreen({super.key, required this.state, required this.onNavigate});

  @override
  State<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends State<TodayScreen> {
  Timer? _tick;
  bool? _notifOn;

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
      MaterialPageRoute<void>(builder: (_) => HabitDetailScreen(state: widget.state, habitId: id)),
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

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final s = widget.state.settings;
        final now = DateTime.now();
        final log = widget.state.today;
        final score = dayScore(now, s, widget.state.logs, habits: widget.state.habits, tasks: widget.state.tasks);
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _Header(now: now, score: score),
            const SizedBox(height: 12),
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
            WakeCard(state: widget.state, log: log),
            PrayerCard(state: widget.state, log: log, now: now),
            for (final h in widget.state.activeHabits)
              if (h.isScheduledOn(now)) HabitCard(key: ValueKey(h.id), state: widget.state, habit: h, day: now),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: OutlinedButton.icon(
                onPressed: () => showAddHabitSheet(context, widget.state),
                icon: const Icon(Icons.add),
                label: const Text('Add habit'),
              ),
            ),
            TasksCard(state: widget.state, now: now, onOpen: () => widget.onNavigate(HomeScreen.tasksTab)),
            _UpcomingCard(state: widget.state, now: now),
          ],
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  final DateTime now;
  final DayScore score;
  const _Header({required this.now, required this.score});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final greeting = now.hour < 12 ? 'Good morning' : (now.hour < 17 ? 'Good afternoon' : 'Good evening');
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(greeting, style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
              Text(DateFormat('EEEE, d MMMM').format(now), style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
        SizedBox(
          width: 64,
          height: 64,
          child: Stack(
            fit: StackFit.expand,
            children: [
              CircularProgressIndicator(
                value: score.fraction,
                strokeWidth: 6,
                backgroundColor: t.colorScheme.surfaceContainerHighest,
              ),
              Center(child: Text('$score', style: const TextStyle(fontWeight: FontWeight.bold))),
            ],
          ),
        ),
      ],
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
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            Icon(icon, color: c.onTertiaryContainer),
            const SizedBox(width: 12),
            Expanded(child: Text(text, style: TextStyle(color: c.onTertiaryContainer))),
            TextButton(onPressed: onTap, child: Text(action)),
          ],
        ),
      ),
    );
  }
}

class _UpcomingCard extends StatelessWidget {
  final AppState state;
  final DateTime now;
  const _UpcomingCard({required this.state, required this.now});

  @override
  Widget build(BuildContext context) {
    final s = state.settings;
    final upcoming = planReminders(s, state.logs, now, days: 2, tasks: state.tasks, habits: state.habits).take(5).toList();
    return SectionCard(
      title: '⏰  Upcoming reminders',
      children: [
        if (!s.remindersEnabled)
          const Text('Reminders are turned off in Settings.')
        else if (upcoming.isEmpty)
          const Text('Nothing pending. All done!')
        else
          for (final r in upcoming)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: Icon(switch (r.kind) {
                ReminderKind.wake => Icons.alarm,
                ReminderKind.prayer => Icons.mosque_outlined,
                ReminderKind.habit => Icons.repeat,
                ReminderKind.task => Icons.task_alt,
              }),
              title: Text(r.title),
              trailing: Text(
                (dateOnly(r.when) == dateOnly(now) ? '' : 'Tomorrow ') + DateFormat.jm().format(r.when),
              ),
            ),
      ],
    );
  }
}
