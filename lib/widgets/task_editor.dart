import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../logic/stats.dart';
import '../logic/tasks.dart';
import '../models.dart';

/// Opens a bottom sheet to create a task, or edit [task] if given.
Future<void> showTaskEditor(BuildContext context, AppState state, {Task? task, DateTime? initialDate}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: _TaskEditor(state: state, task: task, initialDate: initialDate),
    ),
  );
}

class _TaskEditor extends StatefulWidget {
  final AppState state;
  final Task? task;
  final DateTime? initialDate;
  const _TaskEditor({required this.state, this.task, this.initialDate});

  @override
  State<_TaskEditor> createState() => _TaskEditorState();
}

class _TaskEditorState extends State<_TaskEditor> {
  late final _title = TextEditingController(text: widget.task?.title ?? '');
  late final _notes = TextEditingController(text: widget.task?.notes ?? '');
  late String? _date = widget.task?.date ?? (widget.initialDate == null ? null : dayKey(widget.initialDate!));
  late String? _time = widget.task?.time;
  late Repeat _repeat = widget.task?.repeat ?? Repeat.none;
  late final Set<int> _weekdays = {...?widget.task?.weekdays};

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) return;
    final weekdays = (_weekdays.isEmpty ? {(_date == null ? DateTime.now() : DateTime.parse(_date!)).weekday} : _weekdays)
        .toList()
      ..sort();
    final t = widget.task;
    if (t == null) {
      await widget.state.addTask(
        title: title,
        notes: _notes.text,
        date: _date,
        time: _time,
        repeat: _repeat,
        weekdays: _repeat == Repeat.weekly ? weekdays : const [],
      );
    } else {
      await widget.state.updateTask(t, (x) {
        x.title = title;
        x.notes = _notes.text.trim();
        x.date = _date;
        x.time = _time;
        x.repeat = _repeat;
        x.weekdays = _repeat == Repeat.weekly ? weekdays : [];
      });
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dateLabel = _date == null
        ? (_repeat == Repeat.none ? 'Anytime' : 'Starts today')
        : DateFormat('EEE, d MMM yyyy').format(DateTime.parse(_date!));
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(widget.task == null ? 'New task' : 'Edit task', style: t.textTheme.titleLarge),
          if (widget.task?.createdByAi ?? false)
            Text('Created by AI', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.primary)),
          const SizedBox(height: 12),
          TextField(
            controller: _title,
            autofocus: widget.task == null,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Title', border: OutlineInputBorder()),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _notes,
            minLines: 1,
            maxLines: 4,
            decoration: const InputDecoration(labelText: 'Notes (optional)', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          SegmentedButton<Repeat>(
            segments: const [
              ButtonSegment(value: Repeat.none, label: Text('Once')),
              ButtonSegment(value: Repeat.daily, label: Text('Daily')),
              ButtonSegment(value: Repeat.weekly, label: Text('Weekly')),
            ],
            selected: {_repeat},
            onSelectionChanged: (v) => setState(() => _repeat = v.first),
          ),
          if (_repeat == Repeat.weekly) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 6, children: [
              for (var d = 1; d <= 7; d++)
                FilterChip(
                  label: Text(weekdayShort[d - 1][0].toUpperCase() + weekdayShort[d - 1].substring(1)),
                  selected: _weekdays.contains(d),
                  onSelected: (on) => setState(() => on ? _weekdays.add(d) : _weekdays.remove(d)),
                ),
            ]),
          ],
          const SizedBox(height: 4),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.event_outlined),
            title: Text(_repeat == Repeat.none ? 'Date' : 'Start date'),
            subtitle: Text(dateLabel),
            trailing: _date == null ? null : IconButton(icon: const Icon(Icons.clear), onPressed: () => setState(() => _date = null)),
            onTap: () async {
              final now = DateTime.now();
              final d = await showDatePicker(
                context: context,
                initialDate: _date == null ? now : DateTime.parse(_date!),
                firstDate: DateTime(now.year - 1),
                lastDate: DateTime(now.year + 5),
              );
              if (d != null) setState(() => _date = dayKey(d));
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.notifications_outlined),
            title: const Text('Reminder time'),
            subtitle: Text(_time == null ? 'No reminder' : DateFormat.jm().format(DateTime(2000, 1, 1, parseHm(_time!).hour, parseHm(_time!).minute))),
            trailing: _time == null ? null : IconButton(icon: const Icon(Icons.clear), onPressed: () => setState(() => _time = null)),
            onTap: () async {
              final tm = await showTimePicker(
                context: context,
                initialTime: _time == null ? TimeOfDay.now() : parseHm(_time!),
              );
              if (tm != null) setState(() => _time = fmtHm(tm));
            },
          ),
          const SizedBox(height: 8),
          Row(children: [
            if (widget.task != null)
              TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: t.colorScheme.error),
                onPressed: () async {
                  await widget.state.deleteTask(widget.task!);
                  if (context.mounted) Navigator.pop(context);
                },
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete'),
              ),
            const Spacer(),
            FilledButton(onPressed: _title.text.trim().isEmpty ? null : _save, child: const Text('Save')),
          ]),
        ]),
      ),
    );
  }
}

/// A checkbox row for a task on [day].
class TaskTile extends StatelessWidget {
  final AppState state;
  final Task task;
  final DateTime day;
  const TaskTile({super.key, required this.state, required this.task, required this.day});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final done = task.isDoneOn(day);
    final overdue = isOverdue(task, day);
    final subtitle = [
      if (overdue) 'Overdue · ${task.date}' else task.describeSchedule(),
      if (task.notes.isNotEmpty) task.notes,
    ].join(' · ');
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Checkbox(value: done, onChanged: (v) => state.setTaskDone(task, day, v ?? false)),
      title: Text(
        task.title,
        style: TextStyle(
          decoration: done ? TextDecoration.lineThrough : null,
          color: done ? c.onSurfaceVariant : null,
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: overdue ? c.error : null)),
      trailing: task.createdByAi ? Icon(Icons.auto_awesome, size: 16, color: c.primary) : null,
      onTap: () => showTaskEditor(context, state, task: task),
    );
  }
}
