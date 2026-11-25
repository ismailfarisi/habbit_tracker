import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../habits/habit.dart';
import '../logic/stats.dart';
import '../models.dart';

Future<void> reviewPractice(
  BuildContext context,
  AppState state,
  HabitDef habit,
  DateTime today,
) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (_) => _ReviewPractice(state: state, habit: habit, today: today),
);

enum _Choice { keep, reduce, move }

class _ReviewPractice extends StatefulWidget {
  final AppState state;
  final HabitDef habit;
  final DateTime today;
  const _ReviewPractice({
    required this.state,
    required this.habit,
    required this.today,
  });
  @override
  State<_ReviewPractice> createState() => _ReviewPracticeState();
}

class _ReviewPracticeState extends State<_ReviewPractice> {
  _Choice choice = _Choice.keep;
  TimeOfDay? time;
  bool saving = false;

  DateTime? get next {
    final today = widget.today;
    for (var i = 1; i <= 7; i++) {
      final day = DateTime(today.year, today.month, today.day + i);
      if (widget.habit.isScheduledOn(day)) return day;
    }
    return null;
  }

  Future<void> save() async {
    if (saving) return;
    final current = widget.state.habitById(widget.habit.id);
    if (current != null && !current.archived && choice != _Choice.keep) {
      final updated = current.copy();
      if (choice == _Choice.reduce) {
        if (next == null) return;
        updated.restDates.add(dayKey(next!));
      } else {
        if (time == null) return;
        updated.reminder = fmtHm(time!);
      }
      setState(() => saving = true);
      await widget.state.upsertHabit(updated);
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final habit = widget.habit;
    final day = next;
    final date = day == null ? '' : DateFormat('EEEE, d MMMM').format(day);
    final description = switch (choice) {
      _Choice.keep =>
        '${habit.describeSchedule()}. ${day == null ? 'Nothing planned in the next seven days.' : 'Next practice on $date.'}',
      _Choice.reduce =>
        'Rest on $date. Your other practice days stay scheduled.',
      _Choice.move =>
        time == null
            ? 'Choose a new time for your practice reminder.'
            : '${habit.reminder == null ? 'Set the reminder' : 'Move the ${habit.reminder} reminder'} to ${time!.format(context)} on each practice day.',
    };
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        children: [
          Text(habit.title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              for (final (label, value) in [
                ('Keep', _Choice.keep),
                ('Reduce', _Choice.reduce),
                ('Move', _Choice.move),
              ])
                ChoiceChip(
                  label: Text(label),
                  selected: choice == value,
                  onSelected: saving || value == _Choice.reduce && day == null
                      ? null
                      : (_) => setState(() => choice = value),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(description),
          if (choice == _Choice.move)
            TextButton(
              onPressed: () async {
                final picked = await showTimePicker(
                  context: context,
                  initialTime: time ?? parseHm(habit.reminder ?? '09:00'),
                );
                if (mounted && picked != null) setState(() => time = picked);
              },
              child: Text(time == null ? 'Choose time' : 'Change time'),
            ),
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            children: [
              TextButton(
                onPressed: saving ? null : () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: saving || choice == _Choice.move && time == null
                    ? null
                    : save,
                child: Text(
                  choice == _Choice.keep ? 'Keep schedule' : 'Apply change',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
