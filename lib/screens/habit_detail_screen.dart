import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../agent/habit_surface.dart';
import '../app_state.dart';
import '../logic/stats.dart';
import '../widgets/coach_sheet.dart';

/// A habit's own screen: its A2UI surface for [day] (today by default),
/// streak and consistency, and the archive / coach actions.
class HabitDetailScreen extends StatelessWidget {
  final AppState state;
  final String habitId;
  final DateTime? day;
  const HabitDetailScreen({super.key, required this.state, required this.habitId, this.day});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final habit = state.habitById(habitId);
        if (habit == null) {
          return Scaffold(appBar: AppBar(), body: const Center(child: Text('This habit was removed.')));
        }
        final d = day ?? DateTime.now();
        final t = Theme.of(context);
        final s = habitStreak(state.logs, habit);
        final c = habitConsistency(state.logs, habit);
        return Scaffold(
          appBar: AppBar(
            title: Text('${habit.emoji}  ${habit.title}'),
            actions: [
              IconButton(
                tooltip: 'Ask coach',
                icon: const Icon(Icons.auto_awesome),
                onPressed: () => showCoachSheet(context, state, habit: habit),
              ),
              PopupMenuButton<String>(
                onSelected: (v) async {
                  final nav = Navigator.of(context);
                  await state.archiveHabit(habit.id, archived: !habit.archived);
                  if (v == 'archive') nav.pop();
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: habit.archived ? 'restore' : 'archive',
                    child: Text(habit.archived ? 'Restore habit' : 'Archive habit'),
                  ),
                ],
              ),
            ],
          ),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  '${DateFormat('EEEE, d MMMM').format(d)} · ${habit.describeSchedule()}',
                  style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 4),
                Text(
                  'Streak ${s.current} ${s.current == 1 ? 'day' : 'days'} (best ${s.best}) · ${c.done} of last ${c.total} days',
                  style: t.textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: HabitSurface(state, habit, d),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
