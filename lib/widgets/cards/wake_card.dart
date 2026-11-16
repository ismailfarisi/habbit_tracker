import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../app_state.dart';
import '../../logic/stats.dart';
import '../../models.dart';
import 'section_card.dart';

/// Today's wake-up card: goal, status and the "I'm up" button.
class WakeCard extends StatelessWidget {
  final AppState state;
  final DayLog log;
  const WakeCard({super.key, required this.state, required this.log});

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
    return SectionCard(
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
