import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../logic/tasks.dart';
import '../task_editor.dart';
import 'section_card.dart';

/// Today's tasks with quick add and the link to the planner.
class TasksCard extends StatelessWidget {
  final AppState state;
  final DateTime now;
  final VoidCallback onOpen;
  const TasksCard({super.key, required this.state, required this.now, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final tasks = tasksForDay(state.tasks, now, today: now);
    final done = tasks.where((t) => t.isDoneOn(now)).length;
    return SectionCard(
      title: '📝  Tasks',
      trailing: Chip(label: Text('$done/${tasks.length}'), visualDensity: VisualDensity.compact),
      children: [
        if (tasks.isEmpty) const Text('No tasks for today.'),
        for (final t in tasks.take(8)) TaskTile(state: state, task: t, day: now),
        if (tasks.length > 8) Text('+${tasks.length - 8} more'),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          FilledButton.tonalIcon(onPressed: onOpen, icon: const Icon(Icons.auto_awesome), label: const Text('Plan with AI')),
          OutlinedButton.icon(
            onPressed: () => showTaskEditor(context, state, initialDate: now),
            icon: const Icon(Icons.add),
            label: const Text('Add'),
          ),
        ]),
      ],
    );
  }
}
