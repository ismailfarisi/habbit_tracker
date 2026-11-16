import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../logic/stats.dart';
import '../services/reminders.dart';

/// Settings › Reminders: every reminder planned for the next
/// [scheduleDays] days, grouped by day, with the master on/off switch.
class RemindersScreen extends StatelessWidget {
  final AppState state;
  final DateTime? now;
  const RemindersScreen({super.key, required this.state, this.now});

  static IconData iconFor(ReminderKind k) => switch (k) {
        ReminderKind.wake => Icons.alarm,
        ReminderKind.prayer => Icons.mosque_outlined,
        ReminderKind.habit => Icons.repeat,
        ReminderKind.task => Icons.task_alt,
        ReminderKind.bedtime => Icons.bedtime_outlined,
      };

  String _dayLabel(DateTime day, DateTime today) {
    final diff = dateOnly(day).difference(dateOnly(today)).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Tomorrow';
    return DateFormat('EEEE, d MMMM').format(day);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Reminders')),
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final at = now ?? DateTime.now();
          final s = state.settings;
          final planned = planReminders(s, state.logs, at, tasks: state.tasks, habits: state.habits);
          final byDay = <String, List<PlannedReminder>>{};
          for (final r in planned) {
            byDay.putIfAbsent(dayKey(r.when), () => []).add(r);
          }
          final c = Theme.of(context).colorScheme;
          return ListView(
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.notifications_active_outlined),
                title: const Text('Reminders'),
                subtitle: const Text('Wake-up alarm, each prayer, habits and tasks'),
                value: s.remindersEnabled,
                onChanged: (v) => state.updateSettings((x) => x.remindersEnabled = v),
              ),
              const Divider(),
              if (!s.remindersEnabled)
                const ListTile(title: Text('Reminders are turned off.'))
              else if (planned.isEmpty)
                const ListTile(title: Text('Nothing pending. All done!'))
              else
                for (final group in byDay.values) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text(
                      _dayLabel(group.first.when, at),
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(color: c.primary, fontWeight: FontWeight.w600),
                    ),
                  ),
                  for (final r in group)
                    ListTile(
                      dense: true,
                      leading: Icon(iconFor(r.kind)),
                      title: Text(r.title),
                      subtitle: Text(r.body, maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: Text(DateFormat.jm().format(r.when)),
                    ),
                ],
            ],
          );
        },
      ),
    );
  }
}
