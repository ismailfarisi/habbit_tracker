import 'package:flutter/material.dart';

import '../app_state.dart';
import '../habits/habit.dart';
import '../logic/tasks.dart';
import '../models.dart';
import '../quran/surahs.dart';

class GoalGuideEditor extends StatefulWidget {
  final AppState state;
  final HabitDef? habit;
  final Task? task;
  const GoalGuideEditor({super.key, required this.state, this.habit, this.task})
    : assert((habit == null) != (task == null));
  @override
  State<GoalGuideEditor> createState() => _GoalGuideEditorState();
}

class _GoalGuideEditorState extends State<GoalGuideEditor> {
  late final guide = widget.habit?.guide ?? widget.task?.guide ?? const TaskGuide();
  late String steps = guide.steps.join('\n'), doneWhen = guide.doneWhen, minutes = guide.minutes?.toString() ?? '';
  late final sessions = List.of(guide.sessions);
  late final loggedDays = widget.habit != null
      ? widget.state.habitDaysDoneBefore(widget.habit!, DateUtils.dateOnly(DateTime.now()).add(const Duration(days: 1)))
      : widget.task!.doneDates.length;
  late final completed = (loggedDays - guide.sessionStart).clamp(0, guide.sessions.length);
  late bool hasQuran = guide.quran != null;
  late int surah = guide.quran?.surah ?? 1;
  late String from = '${guide.quran?.from ?? 1}',
      to = '${guide.quran?.to ?? 1}',
      pace = guide.quran?.perDay?.toString() ?? '',
      mode = guide.quran?.mode ?? 'read';
  bool saving = false;
  String? error;

  Future<void> save() async {
    final length = int.tryParse(minutes.trim());
    if (minutes.trim().isNotEmpty && (length == null || length <= 0)) {
      setState(() => error = 'Enter minutes as a positive whole number.');
      return;
    }
    QuranRef? ref;
    if (hasQuran) {
      final start = int.tryParse(from), end = int.tryParse(to), per = int.tryParse(pace);
      if (start == null ||
          end == null ||
          start <= 0 ||
          end < start ||
          end > surahInfo[surah - 1].$3 ||
          (pace.isNotEmpty && (per == null || per <= 0))) {
        setState(() => error = 'Check the ayah range and daily pace.');
        return;
      }
      final old = widget.task == null ? guide.quran : widget.state.quranPlanForTask(widget.task!);
      ref = QuranRef(surah, start, end, mode: mode, perDay: per);
      if (widget.task?.isRepeating == true && per == null && mode != 'revise') {
        ref = QuranRef(surah, start, surahInfo[surah - 1].$3, mode: mode, perDay: end - start + 1);
      }
      ref = ref.replan(old, loggedDays);
    }
    final next = TaskGuide(
      steps: steps.split('\n').map((x) => x.trim()).where((x) => x.isNotEmpty).toList(),
      doneWhen: doneWhen.trim(),
      minutes: length,
      quran: ref,
      sessions: List.of(sessions),
      sessionStart: guide.sessions.isEmpty ? loggedDays : guide.sessionStart,
    );
    setState(() {
      saving = true;
      error = null;
    });
    try {
      if (widget.habit != null) {
        final h = widget.state.habitById(widget.habit!.id);
        if (h == null) throw StateError('Practice removed');
        await widget.state.upsertHabit(h.copy()..guide = next);
      } else {
        final t = widget.state.taskById(widget.task!.id);
        if (t == null) throw StateError('Task removed');
        await widget.state.updateTask(t, (task) => task.guide = next);
      }
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          saving = false;
          error = 'Could not save the instructions. Try again.';
        });
      }
    }
  }

  Widget field(String label, String value, ValueChanged<String> changed, {bool multi = false, bool number = false}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextFormField(
          initialValue: value,
          decoration: InputDecoration(labelText: label, alignLabelWithHint: multi),
          minLines: multi ? 2 : 1,
          maxLines: multi ? null : 1,
          keyboardType: number ? TextInputType.number : null,
          onChanged: changed,
        ),
      );

  Future<void> editSession([int? index]) async {
    var value = index == null ? '' : sessions[index];
    final result = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(index == null ? 'Add session' : 'Edit session'),
        content: TextFormField(
          initialValue: value,
          decoration: const InputDecoration(labelText: 'Session instructions'),
          maxLines: null,
          onChanged: (s) => value = s,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              if (value.trim().isNotEmpty) Navigator.pop(c, value.trim());
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result != null && mounted) {
      setState(() {
        if (index == null) {
          sessions.add(result);
        } else {
          sessions[index] = result;
        }
      });
    }
  }

  void move(int index, int to) => setState(() => sessions.insert(to, sessions.removeAt(index)));

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.habit?.title ?? widget.task!.title)),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          field('Steps (one per line)', steps, (s) => steps = s, multi: true),
          field('Done when', doneWhen, (s) => doneWhen = s),
          field('Minutes', minutes, (s) => minutes = s, number: true),
          if (widget.habit != null || widget.task!.isRepeating) ...[
            Text('Session order', style: Theme.of(context).textTheme.titleMedium),
            for (final (i, s) in sessions.indexed)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(s),
                subtitle: i < completed ? const Text('Completed') : null,
                onTap: i < completed ? null : () => editSession(i),
                trailing: i < completed
                    ? null
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Move up',
                            icon: const Icon(Icons.arrow_upward),
                            onPressed: i > completed ? () => move(i, i - 1) : null,
                          ),
                          IconButton(
                            tooltip: 'Move down',
                            icon: const Icon(Icons.arrow_downward),
                            onPressed: i + 1 < sessions.length ? () => move(i, i + 1) : null,
                          ),
                        ],
                      ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => editSession(),
                icon: const Icon(Icons.add),
                label: const Text('Add session'),
              ),
            ),
          ],
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Quran reference'),
            value: hasQuran,
            onChanged: (on) => setState(() => hasQuran = on),
          ),
          if (hasQuran) ...[
            DropdownButtonFormField<int>(
              initialValue: surah,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Surah'),
              items: [
                for (final (i, info) in surahInfo.indexed)
                  DropdownMenuItem(value: i + 1, child: Text('${i + 1}. ${info.$1}')),
              ],
              onChanged: (v) {
                if (v != null) setState(() => surah = v);
              },
            ),
            const SizedBox(height: 12),
            field('First ayah', from, (s) => from = s, number: true),
            field('Last ayah', to, (s) => to = s, number: true),
            if (widget.habit != null || widget.task!.isRepeating)
              field('Ayat per practice', pace, (s) => pace = s, number: true),
            DropdownButtonFormField<String>(
              initialValue: mode,
              decoration: const InputDecoration(labelText: 'Practice'),
              items: [
                for (final m in ['read', 'memorise', 'revise']) DropdownMenuItem(value: m, child: Text(m)),
              ],
              onChanged: (v) {
                if (v != null) mode = v;
              },
            ),
          ],
          if (error != null) Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          const SizedBox(height: 16),
          FilledButton(onPressed: saving ? null : save, child: const Text('Save instructions')),
        ],
      ),
    ),
  );
}
