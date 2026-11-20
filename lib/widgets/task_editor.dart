import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../logic/stats.dart';
import '../logic/tasks.dart';
import '../logic/spoken_task.dart';
import '../models.dart';
import '../services/voice_input.dart';
import 'voice_input_button.dart';
import '../quran/quran.dart';
import '../quran/task_guide_screen.dart';

/// Opens a bottom sheet to create a task, or edit [task] if given. With
/// [dictate], the title starts listening right away and a spoken date,
/// time or repeat ("tomorrow at 5 pm", "every Monday") fills the fields.
Future<void> showTaskEditor(
  BuildContext context,
  AppState state, {
  Task? task,
  DateTime? initialDate,
  bool dictate = false,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: _TaskEditor(state: state, task: task, initialDate: initialDate, dictate: dictate),
    ),
  );
}

class _TaskEditor extends StatefulWidget {
  final AppState state;
  final Task? task;
  final DateTime? initialDate;
  final bool dictate;
  const _TaskEditor({required this.state, this.task, this.initialDate, this.dictate = false});

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
  bool _usedVoice = false;

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _applySpoken(String text) {
    final p = parseSpokenTask(text, DateTime.now());
    setState(() {
      _usedVoice = true;
      if (!p.hasSchedule) return;
      _title.text = p.title;
      if (p.date != null) _date = p.date;
      if (p.time != null) _time = p.time;
      if (p.repeat != Repeat.none) {
        _repeat = p.repeat;
        _weekdays
          ..clear()
          ..addAll(p.weekdays);
      }
    });
  }

  /// "Added Call mum, tomorrow at 5:00 PM".
  String _confirmation(String title, List<int> weekdays) {
    final parts = <String>['Added $title'];
    if (_repeat == Repeat.daily) {
      parts.add('every day');
    } else if (_repeat == Repeat.weekly) {
      parts.add('every ${weekdays.map((d) => DateFormat.EEEE().format(DateTime(2024, 1, d))).join(', ')}');
    } else if (_date != null) {
      final d = DateTime.parse(_date!);
      final today = dateOnly(DateTime.now());
      final diff = d.difference(today).inDays;
      parts.add(
        diff == 0
            ? 'today'
            : diff == 1
            ? 'tomorrow'
            : DateFormat('EEEE, d MMMM').format(d),
      );
    }
    if (_time != null) {
      final t = parseHm(_time!);
      parts.add('at ${DateFormat.jm().format(DateTime(2000, 1, 1, t.hour, t.minute))}');
    }
    return parts.join(', ').replaceAll('\u202f', ' ');
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) return;
    final weekdays =
        (_weekdays.isEmpty ? {(_date == null ? DateTime.now() : DateTime.parse(_date!)).weekday} : _weekdays).toList()
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
      if (_usedVoice && widget.state.settings.speakConfirmations) {
        unawaited(speakAloud(_confirmation(title, weekdays)));
      }
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.task == null ? 'New task' : 'Edit task', style: t.textTheme.titleLarge),
            if (widget.task?.createdByAi ?? false)
              Text('Created by AI', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.primary)),
            const SizedBox(height: 12),
            TextField(
              controller: _title,
              autofocus: widget.task == null && !widget.dictate,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: 'Title',
                hintText: 'e.g. Call mum tomorrow at 5 pm',
                border: const OutlineInputBorder(),
                suffixIcon: VoiceInputButton(
                  key: const Key('task-title-voice'),
                  controller: _title,
                  autoStart: widget.dictate,
                  onFinished: _applySpoken,
                ),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _notes,
              minLines: 1,
              maxLines: 4,
              decoration: InputDecoration(
                labelText: 'Notes (optional)',
                border: const OutlineInputBorder(),
                suffixIcon: VoiceInputButton(key: const Key('task-notes-voice'), controller: _notes),
              ),
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
              Wrap(
                spacing: 6,
                children: [
                  for (var d = 1; d <= 7; d++)
                    FilterChip(
                      label: Text(weekdayShort[d - 1][0].toUpperCase() + weekdayShort[d - 1].substring(1)),
                      selected: _weekdays.contains(d),
                      onSelected: (on) => setState(() => on ? _weekdays.add(d) : _weekdays.remove(d)),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 4),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.event_outlined),
              title: Text(_repeat == Repeat.none ? 'Date' : 'Start date'),
              subtitle: Text(dateLabel),
              trailing: _date == null
                  ? null
                  : IconButton(icon: const Icon(Icons.clear), onPressed: () => setState(() => _date = null)),
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
              subtitle: Text(
                _time == null
                    ? 'No reminder'
                    : DateFormat.jm().format(DateTime(2000, 1, 1, parseHm(_time!).hour, parseHm(_time!).minute)),
              ),
              trailing: _time == null
                  ? null
                  : IconButton(icon: const Icon(Icons.clear), onPressed: () => setState(() => _time = null)),
              onTap: () async {
                final tm = await showTimePicker(
                  context: context,
                  initialTime: _time == null ? TimeOfDay.now() : parseHm(_time!),
                );
                if (tm != null) setState(() => _time = fmtHm(tm));
              },
            ),
            const SizedBox(height: 8),
            Row(
              children: [
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
              ],
            ),
          ],
        ),
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
    final q = state.quranForTask(task, day);
    final subtitle = [
      if (q != null) passageLabel(q.surah, q.from, q.to),
      if (state.sessionForTask(task, day) case final s?) 'Session ${s.$1}/${s.$2}: ${s.$3}',
      if (overdue) 'Overdue · ${task.date}' else task.describeSchedule(),
      if (task.notes.isNotEmpty) task.notes,
    ].join(' · ');
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Checkbox.adaptive(value: done, onChanged: (v) => state.setTaskDone(task, day, v ?? false)),
      title: Text(
        task.title,
        style: TextStyle(
          decoration: done ? TextDecoration.lineThrough : null,
          color: done ? c.onSurfaceVariant : null,
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: Text(
        subtitle,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: overdue ? c.error : null),
      ),
      trailing: task.createdByAi ? Icon(Icons.auto_awesome, size: 16, color: c.primary) : null,
      onTap: () => task.guide == null
          ? showTaskEditor(context, state, task: task)
          : Navigator.of(context).push(TaskGuideScreen.route(state, taskId: task.id, day: day)),
    );
  }
}
