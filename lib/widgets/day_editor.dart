import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../agent/habit_surface.dart';
import '../app_state.dart';
import '../habits/habit.dart';
import '../logic/stats.dart';
import '../logic/tasks.dart';
import '../models.dart';
import '../services/prayer_service.dart';

/// `showDayEditor(context, state, day)` opens a bottom sheet to correct any
/// past day (or today): the wake time (pick or clear), each prayer's status
/// (on time / late / qada / not prayed), each habit scheduled that day (its
/// A2UI surface, or a simple minutes control for timed habits) and each
/// repeating task due that day. Arrows step to the previous / next day, up
/// to today. Every change is saved immediately.
Future<void> showDayEditor(BuildContext context, AppState state, DateTime day) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => DayEditor(state: state, day: day),
  );
}

/// Labels of the prayer status choices, `null` meaning not prayed.
const prayerStatusLabels = <String?, String>{
  null: 'No',
  prayerOnTime: 'On time',
  prayerLate: 'Late',
  prayerQada: 'Qada',
};

class DayEditor extends StatefulWidget {
  final AppState state;
  final DateTime day;

  /// Today, for limiting the forward arrow (defaults to now).
  final DateTime? today;
  const DayEditor({super.key, required this.state, required this.day, this.today});

  @override
  State<DayEditor> createState() => _DayEditorState();
}

class _DayEditorState extends State<DayEditor> {
  late DateTime _day = dateOnly(widget.day);

  AppState get state => widget.state;

  DateTime get _today => dateOnly(widget.today ?? DateTime.now());

  void _shift(int days) => setState(() => _day = DateTime(_day.year, _day.month, _day.day + days));

  String? _statusOf(DayLog log, String p) => log.prayers.contains(p) ? (log.prayerStatus[p] ?? prayerOnTime) : null;

  Future<void> _pickWake(DayLog log) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: log.wakeAt == null ? state.settings.wakeTime : TimeOfDay.fromDateTime(log.wakeAt!),
    );
    if (picked != null) {
      await state.setWake(_day, DateTime(_day.year, _day.month, _day.day, picked.hour, picked.minute));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final day = _day;
        final log = state.logFor(day);
        final habits = state.activeHabits.where((h) => h.isScheduledOn(day)).toList();
        final tasks = state.tasks.where((t) => taskCountsOn(t, day)).toList();
        final times = prayerTimesFor(state.settings, day).times;
        final score = dayScore(day, state.settings, state.logs, habits: state.habits, tasks: state.tasks, goals: state.goals);
        final wake = wakeResult(log, state.settings);
        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: 'Previous day',
                    icon: const Icon(Icons.chevron_left),
                    onPressed: () => _shift(-1),
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        Text(
                          DateFormat('EEEE, d MMMM').format(day),
                          textAlign: TextAlign.center,
                          style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          '$score done',
                          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Next day',
                    icon: const Icon(Icons.chevron_right),
                    onPressed: day.isBefore(_today) ? () => _shift(1) : null,
                  ),
                ],
              ),
              _Heading('Wake up'),
              ListTile(
                key: const ValueKey('day-wake'),
                contentPadding: EdgeInsets.zero,
                leading: const Text('☀️', style: TextStyle(fontSize: 22)),
                title: Text(log.wakeAt == null ? 'Not logged' : 'Up at ${DateFormat.jm().format(log.wakeAt!)}'),
                subtitle: Text(switch (wake) {
                  WakeResult.none => 'Goal ${state.settings.wakeTime.format(context)}',
                  WakeResult.onTime => 'On time',
                  WakeResult.late => 'Later than the goal',
                }),
                onTap: () => _pickWake(log),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (log.wakeAt != null)
                      IconButton(
                        tooltip: 'Clear wake time',
                        icon: const Icon(Icons.clear),
                        onPressed: () => state.setWake(day, null),
                      ),
                    IconButton(
                      tooltip: 'Set wake time',
                      icon: const Icon(Icons.schedule),
                      onPressed: () => _pickWake(log),
                    ),
                  ],
                ),
              ),
              _Heading('Prayers'),
              for (final p in prayerNames)
                _PrayerRow(
                  key: ValueKey('prayer-$p'),
                  name: p,
                  time: times[p],
                  status: _statusOf(log, p),
                  onChanged: (s) => state.setPrayerStatus(day, p, s),
                ),
              if (habits.isNotEmpty) _Heading('Habits'),
              for (final h in habits)
                _HabitEditor(key: ValueKey('day-habit-${h.id}-${dayKey(day)}'), state: state, habit: h, day: day),
              if (tasks.isNotEmpty) _Heading('Routines'),
              for (final task in tasks)
                CheckboxListTile.adaptive(
                  key: ValueKey('day-task-${task.id}'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: task.isDoneOn(day),
                  onChanged: (v) => state.setTaskDone(task, day, v ?? false),
                  title: Text(task.title),
                  subtitle: Text(task.describeSchedule()),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _Heading extends StatelessWidget {
  final String text;
  const _Heading(this.text);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 4),
      child: Text(
        text,
        style: t.textTheme.titleSmall?.copyWith(color: t.colorScheme.primary, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// A prayer with its time and a not prayed / on time / late / qada choice.
/// Tapping the name toggles between not prayed and on time.
class _PrayerRow extends StatelessWidget {
  final String name;
  final DateTime? time;
  final String? status;
  final ValueChanged<String?> onChanged;
  const _PrayerRow({super.key, required this.name, required this.time, required this.status, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => onChanged(status == null ? prayerOnTime : null),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  if (time != null)
                    Text(DateFormat.jm().format(time!), style: TextStyle(fontSize: 12, color: c.onSurfaceVariant)),
                ],
              ),
            ),
          ),
          SegmentedButton<String?>(
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 4)),
              textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 13)),
            ),
            segments: [
              for (final e in prayerStatusLabels.entries)
                ButtonSegment(
                  value: e.key,
                  label: Text(e.value, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
            ],
            selected: {status},
            onSelectionChanged: (s) => onChanged(s.first),
          ),
        ],
      ),
    );
  }
}

/// A habit for a past day: its A2UI surface for check, count and metric
/// habits; a minutes control for timed ones (timers make no sense later).
class _HabitEditor extends StatelessWidget {
  final AppState state;
  final HabitDef habit;
  final DateTime day;
  const _HabitEditor({super.key, required this.state, required this.habit, required this.day});

  @override
  Widget build(BuildContext context) {
    final timed = habit.kind == HabitKind.duration || habit.kind == HabitKind.practice;
    final entry = state.habitEntry(day, habit.id);
    return Card.outlined(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('${habit.emoji}  ${habit.title}', style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                Icon(
                  habitDone(entry, habit) ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: habitDone(entry, habit) ? Theme.of(context).colorScheme.primary : null,
                  size: 20,
                ),
              ],
            ),
            const SizedBox(height: 4),
            if (timed)
              HabitFallback(habit: habit, entry: entry, onChanged: (e) => state.logHabit(day, habit.id, e))
            else
              HabitSurface(state, habit, day),
          ],
        ),
      ),
    );
  }
}
