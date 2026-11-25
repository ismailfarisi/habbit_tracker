import 'package:flutter/material.dart';

import '../app_state.dart';
import '../logic/tasks.dart';
import '../models.dart';
import '../widgets/task_editor.dart';

/// The task lists shown on the Plan tab: Today, Upcoming, Routines and
/// Completed.
class TaskSections extends StatelessWidget {
  final AppState state;
  const TaskSections({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final now = DateTime.now();
        final tasks = state.tasks.where((t) => state.goalFor(t.id) == null).toList();
        final today = tasksForDay(tasks, now);
        final upcoming = upcomingTasks(tasks, now);
        final repeating = tasks.where((x) => x.isRepeating).toList()
          ..sort((a, b) => (a.time ?? '99').compareTo(b.time ?? '99'));
        final completed = tasks.where((x) => x.isOneOffDone && !today.contains(x)).toList()
          ..sort((a, b) => (b.doneDates.first).compareTo(a.doneDates.first));
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _section(context, "Today's tasks", today, now, empty: 'Nothing planned. Add a task or ask the coach.'),
            if (upcoming.isNotEmpty) _section(context, 'Upcoming', upcoming, now, useOwnDate: true),
            if (repeating.isNotEmpty) _section(context, 'Routines', repeating, now),
            if (completed.isNotEmpty) _section(context, 'Completed', completed.take(20).toList(), now),
          ],
        );
      },
    );
  }

  Widget _section(
    BuildContext context,
    String title,
    List<Task> tasks,
    DateTime now, {
    String? empty,
    bool useOwnDate = false,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$title${tasks.isEmpty ? '' : ' · ${tasks.length}'}',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            if (tasks.isEmpty && empty != null)
              Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(empty))
            else
              for (final x in tasks)
                TaskTile(state: state, task: x, day: useOwnDate && x.date != null ? DateTime.parse(x.date!) : now),
          ],
        ),
      ),
    );
  }
}
