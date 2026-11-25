import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../widgets/ask_chat.dart';

Future<void> showLocalGoalEditor(BuildContext context, AppState state) =>
    Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => _LocalGoalEditor(state)));

class _LocalGoalEditor extends StatefulWidget {
  final AppState state;
  const _LocalGoalEditor(this.state);
  @override
  State<_LocalGoalEditor> createState() => _LocalGoalEditorState();
}

class _LocalGoalEditorState extends State<_LocalGoalEditor> {
  String outcome = '', practice = '';
  final days = <int>{};
  late DateTime end = DateTime.now().add(const Duration(days: 30));
  TimeOfDay? reminder;
  String? error;
  bool busy = false;

  String get schedule => days.isEmpty || days.length == 7
      ? 'Every day'
      : (days.toList()..sort()).map((d) => DateFormat.E().format(DateTime(2024, 1, d))).join(', ');

  Future<void> save() async {
    if (practice.trim().isEmpty || outcome.trim().isEmpty) {
      setState(() => error = 'Enter an outcome and a first practice.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final time = reminder;
      await widget.state.createLocalGoal(
        outcome: outcome,
        practice: practice,
        weekdays: days.toList(),
        end: end,
        reminder: time == null
            ? null
            : '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
      );
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          busy = false;
          error = 'Could not save this goal. Try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('New goal')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            key: const Key('goal-outcome'),
            decoration: const InputDecoration(labelText: 'Outcome'),
            onChanged: (s) => outcome = s,
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('goal-practice'),
            decoration: const InputDecoration(labelText: 'First practice'),
            onChanged: (s) => practice = s,
          ),
          const SizedBox(height: 18),
          Text('Schedule · $schedule', style: Theme.of(context).textTheme.titleSmall),
          Wrap(
            spacing: 6,
            children: [
              for (var d = 1; d <= 7; d++)
                FilterChip(
                  label: Text(DateFormat.E().format(DateTime(2024, 1, d))),
                  selected: days.contains(d),
                  onSelected: (on) => setState(() {
                    on ? days.add(d) : days.remove(d);
                  }),
                ),
            ],
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Reminder'),
            subtitle: Text(reminder?.format(context) ?? 'Off'),
            trailing: reminder == null
                ? null
                : IconButton(
                    tooltip: 'Turn off reminder',
                    onPressed: () => setState(() => reminder = null),
                    icon: const Icon(Icons.close),
                  ),
            onTap: () async {
              final time = await showTimePicker(context: context, initialTime: reminder ?? TimeOfDay.now());
              if (time != null && mounted) setState(() => reminder = time);
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Target date'),
            subtitle: Text(DateFormat.yMMMd().format(end)),
            onTap: () async {
              final today = DateTime.now();
              final picked = await showDatePicker(
                context: context,
                initialDate: end,
                firstDate: today,
                lastDate: DateTime(today.year + 50),
              );
              if (picked != null && mounted) setState(() => end = picked);
            },
          ),
          if (error != null) Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          FilledButton(onPressed: busy ? null : save, child: const Text('Create goal')),
          TextButton(
            onPressed: busy
                ? null
                : () {
                    final draft = [
                      outcome.trim().isEmpty ? 'Help me set a new goal.' : 'Help me plan this goal: ${outcome.trim()}.',
                      if (practice.trim().isNotEmpty) 'First practice: ${practice.trim()}.',
                      'Schedule: $schedule${reminder == null ? '' : ' at ${reminder!.format(context)}'}.',
                      'Target: ${DateFormat.yMMMd().format(end)}.',
                    ].join('\n');
                    askChat(widget.state, draft, context: context);
                  },
            child: const Text('Build with coach'),
          ),
        ],
      ),
    ),
  );
}
