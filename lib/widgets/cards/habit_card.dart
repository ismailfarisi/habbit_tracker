import 'package:flutter/material.dart';

import '../../agent/habit_surface.dart';
import '../../app_state.dart';
import '../../habits/habit.dart';
import '../../logic/stats.dart';
import '../../screens/habit_detail_screen.dart';
import 'section_card.dart';

/// One habit on Today for [day]. Check, count and metric habits show their
/// A2UI surface inline; timed habits (duration, practice) show progress and
/// open the habit screen to practise.
class HabitCard extends StatelessWidget {
  final AppState state;
  final HabitDef habit;
  final DateTime day;
  const HabitCard({super.key, required this.state, required this.habit, required this.day});

  /// Short progress label, e.g. "3/8 glasses", "5/15 min", "Done".
  static String progressLabel(HabitDef h, HabitEntry e) {
    String n(num v) => v % 1 == 0 ? '${v.toInt()}' : v.toStringAsFixed(1);
    return switch (h.kind) {
      HabitKind.count => '${n(e.value ?? 0)}/${n(h.target)} ${h.unit}'.trim(),
      HabitKind.duration || HabitKind.practice => '${e.minutes ?? 0}/${n(h.target)} min',
      _ => habitDone(e, h) ? 'Done' : 'To do',
    };
  }

  void _open(BuildContext context) => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => HabitDetailScreen(state: state, habitId: habit.id, day: day)),
      );

  @override
  Widget build(BuildContext context) {
    final entry = state.habitEntry(day, habit.id);
    final timed = habit.kind == HabitKind.duration || habit.kind == HabitKind.practice;
    return SectionCard(
      title: '${habit.emoji}  ${habit.title}',
      onTitleTap: () => _open(context),
      trailing: Chip(label: Text(progressLabel(habit, entry)), visualDensity: VisualDensity.compact),
      children: [
        if (timed) ...[
          LinearProgressIndicator(
            value: habitProgress(entry, habit),
            minHeight: 8,
            borderRadius: BorderRadius.circular(8),
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 8, children: [
            FilledButton.icon(
              onPressed: () => _open(context),
              icon: const Icon(Icons.play_arrow),
              label: Text(habit.kind == HabitKind.practice ? 'Practise' : 'Start'),
            ),
            OutlinedButton(
              onPressed: () => state.logHabit(
                day,
                habit.id,
                entry.copy()..minutes = ((entry.minutes ?? 0) + 5).clamp(0, 24 * 60),
              ),
              child: const Text('+5 min'),
            ),
          ]),
        ] else
          HabitSurface(state, habit, day, key: ValueKey('surface-${habit.id}')),
      ],
    );
  }
}
