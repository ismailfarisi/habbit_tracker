import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../logic/stats.dart';
import '../logic/tasks.dart';
import '../models.dart';

/// `showDayEditor(context, state, day)` opens a sheet to correct any day:
/// wake time, each prayer, each scheduled habit and repeating task.
///
/// This is the foundation's basic version (tick boxes and a wake time
/// picker); the Today feature completes it (prayer status, habit values).
Future<void> showDayEditor(BuildContext context, AppState state, DateTime day) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => DayEditor(state: state, day: day),
  );
}

class DayEditor extends StatelessWidget {
  final AppState state;
  final DateTime day;
  const DayEditor({super.key, required this.state, required this.day});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final log = state.logFor(day);
        final habits = state.activeHabits.where((h) => h.isScheduledOn(day)).toList();
        final tasks = state.tasks.where((t) => taskCountsOn(t, day)).toList();
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              Text(DateFormat('EEEE, d MMMM').format(day),
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Text('☀️', style: TextStyle(fontSize: 22)),
                title: const Text('Woke up'),
                subtitle: Text(log.wakeAt == null ? 'Not logged' : DateFormat.jm().format(log.wakeAt!)),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (log.wakeAt != null)
                    IconButton(
                      tooltip: 'Clear wake time',
                      icon: const Icon(Icons.clear),
                      onPressed: () => state.setWake(day, null),
                    ),
                  IconButton(
                    tooltip: 'Set wake time',
                    icon: const Icon(Icons.schedule),
                    onPressed: () async {
                      final picked = await showTimePicker(
                        context: context,
                        initialTime: log.wakeAt == null ? state.settings.wakeTime : TimeOfDay.fromDateTime(log.wakeAt!),
                      );
                      if (picked != null) {
                        await state.setWake(day, DateTime(day.year, day.month, day.day, picked.hour, picked.minute));
                      }
                    },
                  ),
                ]),
              ),
              for (final p in prayerNames)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: log.prayers.contains(p),
                  onChanged: (v) => state.setPrayerStatus(day, p, v == true ? prayerOnTime : null),
                  title: Text(p),
                ),
              for (final h in habits)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: habitDone(log.habits[h.id], h),
                  onChanged: (v) => state.logHabit(day, h.id, state.habitEntry(day, h.id).copy()..done = v ?? false),
                  title: Text('${h.emoji}  ${h.title}'),
                ),
              for (final t in tasks)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: t.isDoneOn(day),
                  onChanged: (v) => state.setTaskDone(t, day, v ?? false),
                  title: Text('📝  ${t.title}'),
                ),
            ],
          ),
        );
      },
    );
  }
}
