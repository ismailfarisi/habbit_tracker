import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../logic/stats.dart';
import '../quran/task_guide_screen.dart';
import 'goal.dart';
import 'goal_okf.dart';

/// What a goal has planned on each of the next [days] days, as of today.
class GoalAgenda extends StatelessWidget {
  final AppState state;
  final Goal goal;
  final DateTime from;
  final int days;
  const GoalAgenda({super.key, required this.state, required this.goal, required this.from, this.days = 14});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final today = dateOnly(from);
    final rows = <Widget>[];
    for (var i = 0; i < days; i++) {
      final d = DateTime(today.year, today.month, today.day + i);
      final items = goalPlanFor(state, goal, d, today: today);
      if (items.isEmpty) continue;
      rows.add(
        Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 2),
          child: Text(i == 0 ? 'Today' : DateFormat('EEE d MMM').format(d), style: t.textTheme.labelLarge),
        ),
      );
      for (final it in items) {
        final open = it.habit?.guide != null || it.task?.guide != null;
        rows.add(
          ListTile(
            key: ValueKey('agenda-${dayKey(d)}-${it.title}'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            leading: Icon(
              it.milestone != null ? Icons.flag_outlined : (it.done ? Icons.check_circle : Icons.radio_button_unchecked),
              size: 20,
              color: it.done ? t.colorScheme.primary : t.colorScheme.onSurfaceVariant,
            ),
            title: Text(it.title),
            subtitle: it.detail.isEmpty ? null : Text(it.detail),
            trailing: open ? const Icon(Icons.chevron_right, size: 18) : null,
            onTap: open
                ? () => Navigator.of(context).push(
                    TaskGuideScreen.route(state, habitId: it.habit?.id, taskId: it.habit == null ? it.task?.id : null, day: d, today: today),
                  )
                : null,
          ),
        );
      }
    }
    if (rows.isEmpty) return Text('Nothing planned in the next two weeks.', style: muted);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('As planned today. If a day is missed, later sessions move back.', style: muted),
        ...rows,
      ],
    );
  }
}
