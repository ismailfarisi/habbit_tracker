import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../app_state.dart';
import '../../logic/sleep.dart';
import '../../logic/stats.dart';
import '../../models.dart';
import '../../screens/wake_challenge_screen.dart';
import 'section_card.dart';
import '../adaptive.dart';

/// Today's wake-up card: goal, status, last night's sleep, the "I'm up"
/// button (through the wake challenge when it is on) and, in the evening,
/// "Going to bed". Also opens the challenge when a wake notification asks.
class WakeCard extends StatefulWidget {
  final AppState state;
  final DayLog log;

  /// Clock override for tests.
  final DateTime? now;
  const WakeCard({super.key, required this.state, required this.log, this.now});

  @override
  State<WakeCard> createState() => _WakeCardState();
}

class _WakeCardState extends State<WakeCard> {
  AppState get state => widget.state;
  DateTime get _now => widget.now ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    state.notifications.wakeChallengeRequest.addListener(_onRequest);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onRequest());
  }

  @override
  void dispose() {
    state.notifications.wakeChallengeRequest.removeListener(_onRequest);
    super.dispose();
  }

  void _onRequest() {
    final req = state.notifications.wakeChallengeRequest;
    final day = req.value;
    if (day == null || !mounted) return;
    req.value = null;
    final today = _now;
    if (day != dayKey(today) || state.settings.wakeChallenge == WakeChallenge.off) return;
    if (state.logFor(today).wakeAt != null) return;
    openWakeChallenge(context, state);
  }

  String _jm(DateTime t) => DateFormat.jm().format(t);

  @override
  Widget build(BuildContext context) {
    final s = state.settings;
    final log = widget.log;
    final now = _now;
    final result = wakeResult(log, s);
    final target = _jm(DateTime(2000, 1, 1, s.wakeTime.hour, s.wakeTime.minute));
    final status = switch (result) {
      WakeResult.none => 'Goal: up by $target (+${s.wakeGraceMin} min grace). Tap when you get out of bed.',
      WakeResult.onTime => '✅ Up at ${_jm(log.wakeAt!)}. Great start!',
      WakeResult.late => '⏰ Up at ${_jm(log.wakeAt!)}, later than your goal. Tomorrow is a new chance.',
    };
    final slept = lastNightSleep(state.logs, now);
    final lastBed = state.logFor(DateTime(now.year, now.month, now.day - 1)).bedtimeAt;
    final sleepLine = slept != null
        ? '😴 Slept ${fmtSleep(slept)} (goal ${fmtSleepHours(s.sleepHours)})'
        : lastBed != null
            ? '😴 In bed at ${_jm(lastBed)} last night'
            : null;

    final night = nightOf(now);
    final bedAt = state.logFor(night).bedtimeAt;
    final evening = isBedtimeWindow(s, now);

    return SectionCard(
      icon: Icons.wb_sunny_outlined,
      title: 'Wake up early',
      trailing: CountBadge(target),
      children: [
        Text(status),
        if (sleepLine != null) ...[
          const SizedBox(height: 4),
          Text(sleepLine, key: const Key('sleepLine'), style: Theme.of(context).textTheme.bodyMedium),
        ],
        const SizedBox(height: 12),
        if (result == WakeResult.none)
          FilledButton.icon(
            onPressed: () => openWakeChallenge(context, state),
            icon: Icon(s.wakeChallenge == WakeChallenge.off ? Icons.wb_sunny_outlined : Icons.verified_user_outlined),
            label: const Text("I'm up!"),
          )
        else
          TextButton(onPressed: state.undoWake, child: const Text('Undo')),
        if (bedAt != null && evening) ...[
          const Divider(height: 24),
          Row(children: [
            Expanded(child: Text('🌙 In bed at ${_jm(bedAt)}. Sleep well!')),
            TextButton(onPressed: () => state.setBedtime(night, null), child: const Text('Undo')),
          ]),
        ] else if (evening) ...[
          const Divider(height: 24),
          Text('🌙 Bedtime ${_jm(bedtimeFor(s, night))} for ${fmtSleepHours(s.sleepHours)} of sleep.'),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            style: compactButton,
            onPressed: () => state.setBedtime(night, DateTime.now()),
            icon: const Icon(Icons.bedtime_outlined),
            label: const Text('Going to bed'),
          ),
        ],
      ],
    );
  }
}
