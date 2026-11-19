import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../logic/tasks.dart';
import '../../models.dart';
import '../task_editor.dart';
import 'section_card.dart';
import '../adaptive.dart';

/// Today's tasks (unfinished first, in time order) with quick add and the
/// link to the planner.
class TasksCard extends StatelessWidget {
  final AppState state;
  final DateTime now;
  final VoidCallback onOpen;
  const TasksCard({super.key, required this.state, required this.now, required this.onOpen});

  /// Today's tasks that are not part of a goal (goals have their own card).
  static List<Task> _today(AppState state, DateTime now) =>
      tasksForDay(state.tasks, now, today: now).where((t) => state.goalFor(t.id) == null).toList();

  /// Today's tasks, unfinished ones first, each group in time order.
  static List<Task> ordered(AppState state, DateTime now) {
    final tasks = _today(state, now);
    return [...tasks.where((t) => !t.isDoneOn(now)), ...tasks.where((t) => t.isDoneOn(now))];
  }

  /// When the next unfinished task with a time is due, if any.
  static DateTime? nextDue(AppState state, DateTime now) {
    DateTime? best;
    for (final t in _today(state, now)) {
      if (t.isDoneOn(now)) continue;
      final at = t.reminderOn(now);
      if (at != null && (best == null || at.isBefore(best))) best = at;
    }
    return best;
  }

  /// Whether there are tasks today and all are done.
  static bool allDone(AppState state, DateTime now) {
    final tasks = _today(state, now);
    return tasks.isNotEmpty && tasks.every((t) => t.isDoneOn(now));
  }

  @override
  Widget build(BuildContext context) {
    final tasks = ordered(state, now);
    final done = tasks.where((t) => t.isDoneOn(now)).length;
    return SectionCard(
      icon: Icons.checklist_rounded,
      title: 'Tasks',
      trailing: CountBadge('$done/${tasks.length}'),
      children: [
        if (tasks.isEmpty) const Text('No tasks for today.'),
        for (final t in tasks.take(8)) TaskTile(state: state, task: t, day: now),
        if (tasks.length > 8) Text('+${tasks.length - 8} more'),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          FilledButton.tonalIcon(style: compactButton, onPressed: onOpen, icon: const Icon(Icons.auto_awesome), label: const Text('Plan with AI')),
          OutlinedButton.icon(
            style: compactButton,
            onPressed: () => showTaskEditor(context, state, initialDate: now),
            icon: const Icon(Icons.add),
            label: const Text('Add'),
          ),
        ]),
      ],
    );
  }
}
