import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../logic/stats.dart';
import '../models.dart';
import '../services/prayer_service.dart';
import '../services/reminders.dart';
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
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _checkNotifications() async {
    final on = await widget.state.notifications.enabled();
    if (mounted) setState(() => _notifOn = on);
  }

  Future<void> _enableNotifications() async {
    await widget.state.notifications.requestPermissions();
    await widget.state.notifications.reschedule(widget.state.settings, widget.state.logs);
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
        final score = dailyScore(log, s);
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
            _WakeCard(state: widget.state, log: log),
            _PrayerCard(state: widget.state, log: log, now: now),
            _TrainingCard(state: widget.state, log: log, onStart: () => widget.onNavigate(HomeScreen.trainTab)),
            _UpcomingCard(state: widget.state, now: now),
          ],
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  final DateTime now;
  final int score;
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
                value: score / maxDailyScore,
                strokeWidth: 6,
                backgroundColor: t.colorScheme.surfaceContainerHighest,
              ),
              Center(child: Text('$score/$maxDailyScore', style: const TextStyle(fontWeight: FontWeight.bold))),
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

class _SectionCard extends StatelessWidget {
  final String title;
  final Widget? trailing;
  final List<Widget> children;
  const _SectionCard({required this.title, this.trailing, required this.children});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
              ?trailing,
            ]),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _WakeCard extends StatelessWidget {
  final AppState state;
  final DayLog log;
  const _WakeCard({required this.state, required this.log});

  @override
  Widget build(BuildContext context) {
    final s = state.settings;
    final result = wakeResult(log, s);
    final target = DateFormat.jm().format(DateTime(2000, 1, 1, s.wakeTime.hour, s.wakeTime.minute));
    final status = switch (result) {
      WakeResult.none => 'Goal: up by $target (+${s.wakeGraceMin} min grace). Tap when you get out of bed.',
      WakeResult.onTime => '✅ Up at ${DateFormat.jm().format(log.wakeAt!)}. Great start!',
      WakeResult.late => '⏰ Up at ${DateFormat.jm().format(log.wakeAt!)}, later than your goal. Tomorrow is a new chance.',
    };
    return _SectionCard(
      title: '☀️  Wake up early',
      trailing: Chip(label: Text(target), visualDensity: VisualDensity.compact),
      children: [
        Text(status),
        const SizedBox(height: 12),
        if (result == WakeResult.none)
          FilledButton.icon(onPressed: state.markWake, icon: const Icon(Icons.wb_sunny_outlined), label: const Text("I'm up!"))
        else
          TextButton(onPressed: state.undoWake, child: const Text('Undo')),
      ],
    );
  }
}

class _PrayerCard extends StatelessWidget {
  final AppState state;
  final DayLog log;
  final DateTime now;
  const _PrayerCard({required this.state, required this.log, required this.now});

  @override
  Widget build(BuildContext context) {
    final s = state.settings;
    final day = prayerTimesFor(s, now);
    final next = nextPrayer(s, now);
    final mins = next.value.difference(now).inMinutes;
    final inText = mins >= 60 ? '${mins ~/ 60} h ${mins % 60} min' : '$mins min';
    final done = prayerNames.where(log.prayers.contains).length;
    final c = Theme.of(context).colorScheme;
    return _SectionCard(
      title: '🕌  Five daily prayers',
      trailing: Chip(label: Text('$done/5'), visualDensity: VisualDensity.compact),
      children: [
        Text('Next: ${next.key} in $inText', style: TextStyle(color: c.onSurfaceVariant)),
        for (final p in prayerNames)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: log.prayers.contains(p),
            onChanged: (v) => state.setPrayer(now, p, v ?? false),
            title: Text(p, style: TextStyle(fontWeight: next.key == p ? FontWeight.bold : FontWeight.normal)),
            secondary: Text(DateFormat.jm().format(day.times[p]!), style: TextStyle(color: c.onSurfaceVariant)),
          ),
        Text(
          day.calculated
              ? 'Calculated for ${s.locationName.isEmpty ? 'your location' : s.locationName} · ${calcMethodLabels[s.calcMethod]}'
              : 'Using manual times',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: c.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _TrainingCard extends StatelessWidget {
  final AppState state;
  final DayLog log;
  final VoidCallback onStart;
  const _TrainingCard({required this.state, required this.log, required this.onStart});

  @override
  Widget build(BuildContext context) {
    final goal = state.settings.trainingGoalMin;
    final m = log.trainingMinutes;
    return _SectionCard(
      title: '🗣️  Articulation training',
      trailing: Chip(label: Text('$m/$goal min'), visualDensity: VisualDensity.compact),
      children: [
        LinearProgressIndicator(value: (m / goal).clamp(0, 1).toDouble(), minHeight: 8, borderRadius: BorderRadius.circular(8)),
        const SizedBox(height: 12),
        Wrap(spacing: 8, children: [
          FilledButton.icon(onPressed: onStart, icon: const Icon(Icons.mic_none), label: const Text('Train with AI coach')),
          OutlinedButton(onPressed: () => state.addTraining(5), child: const Text('+5 min')),
        ]),
      ],
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
    final upcoming = planReminders(s, state.logs, now, days: 2).take(4).toList();
    return _SectionCard(
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
                ReminderKind.training => Icons.record_voice_over_outlined,
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
