import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../app_state.dart';
import '../goals/goals_card.dart';
import '../logic/stats.dart';
import '../logic/tasks.dart';
import '../models.dart';
import '../widgets/adaptive.dart';
import '../widgets/task_editor.dart';
import 'quran_practice.dart';

export 'quran_practice.dart' show QuranPractice, QuranPassageView;

/// A task's or goal habit's instructions: steps to tick, what counts as
/// done, and for Quran practice the verified passage (a habit's next daily
/// portion) with translation and recitation.
class TaskGuideScreen extends StatelessWidget {
  final AppState state;
  final String? taskId;
  final String? habitId;
  final DateTime? day, today;
  const TaskGuideScreen({super.key, required this.state, this.taskId, this.habitId, this.day, this.today});

  static Route<void> route(AppState state, {String? taskId, String? habitId, DateTime? day, DateTime? today}) => MaterialPageRoute<void>(
    builder: (_) => TaskGuideScreen(state: state, taskId: taskId, habitId: habitId, day: day, today: today),
  );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final asOf = today ?? DateTime.now();
        final now = day ?? asOf;
        final key = dayKey(now);
        final isToday = DateUtils.isSameDay(now, asOf);
        final task = taskId == null ? null : state.taskById(taskId!);
        final habit = habitId == null ? null : state.habitById(habitId!);
        if (task == null && habit == null) {
          return Scaffold(appBar: AppBar(), body: const Center(child: Text('This was removed.')));
        }
        final entry = habit == null ? null : state.habitEntry(now, habit.id);
        final g = task?.guide ?? habit?.guide ?? const TaskGuide();
        final quran = habit != null ? state.quranFor(habit, now, today: asOf) : state.quranForTask(task!, now, today: asOf);
        final t = Theme.of(context);
        final ticked = task != null
            ? task.stepsDone[key] ?? <int>{}
            : {for (final v in (entry!.data['steps'] as List?) ?? const []) if (v is num) v.toInt()};
        final done = task != null ? task.isDoneOn(now) : habitDone(entry, habit!);
        final goal = state.goalFor(task?.id ?? habit!.id);
        final future = isForecastDay(now, today: asOf);
        final dateLabel = DateFormat.MMMEd().format(now);
        final notes = task?.notes ?? '';
        void tick(int i, bool on) {
          if (task != null) {
            state.updateTask(task, (x) {
              final set = x.stepsDone[key] ??= <int>{};
              on ? set.add(i) : set.remove(i);
            });
          } else {
            final set = {...ticked};
            on ? set.add(i) : set.remove(i);
            state.logHabit(now, habit!.id, entry!.copy()..data['steps'] = (set.toList()..sort()));
          }
        }

        void markDone() => task != null
            ? state.updateTask(task, (x) => x.doneDates.add(key))
            : state.logHabit(now, habit!.id, entry!.copy()..done = true);

        return Scaffold(
          appBar: AppBar(
            title: Text(task?.title ?? '${habit!.emoji} ${habit.title}'),
            actions: [
              if (task != null)
                IconButton(
                  tooltip: 'Edit plan',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => showTaskEditor(context, state, task: task),
                ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              if (!isToday)
                Text('${future ? 'Forecast' : 'Log'} · ${DateFormat.yMMMMEEEEd().format(now)}',
                    style: t.textTheme.titleMedium),
              if (goal != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: ActionChip(
                    key: const Key('guide-goal'),
                    avatar: Text(goal.emoji),
                    label: Text('Goal: ${goal.title}'),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => GoalScreen(state: state, goalId: goal.id)),
                    ),
                  ),
                ),
              if (g.minutes != null || notes.isNotEmpty || habit != null)
                Text(
                  [
                    if (habit != null) habit.describeSchedule(),
                    if (g.minutes != null) 'About ${g.minutes} min',
                    if (notes.isNotEmpty) notes,
                  ].join(' · '),
                  style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
              if ((habit != null ? state.sessionForHabit(habit, now, today: asOf) : state.sessionForTask(task!, now, today: asOf)) case final s?) ...[
                const SizedBox(height: 12),
                Container(
                  key: const Key('guide-session'),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: t.colorScheme.secondaryContainer.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${isToday ? 'Today' : dateLabel} · session ${s.$1} of ${s.$2}',
                        style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSecondaryContainer),
                      ),
                      const SizedBox(height: 4),
                      Text(s.$3, style: t.textTheme.titleMedium),
                    ],
                  ),
                ),
              ],
              if (g.steps.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('Steps', style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                for (final (i, s) in g.steps.indexed)
                  CheckboxListTile.adaptive(
                    key: ValueKey('step-$i'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: ticked.contains(i),
                    title: Text('${i + 1}. $s'),
                    onChanged: future ? null : (v) => tick(i, v == true),
                  ),
              ],
              if (g.doneWhen.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: t.colorScheme.primaryContainer.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.flag_outlined, size: 20, color: t.colorScheme.primary),
                      const SizedBox(width: 8),
                      Expanded(child: Text('Done when: ${g.doneWhen}')),
                    ],
                  ),
                ),
              ],
              if (quran != null) ...[
                const SizedBox(height: 16),
                if (habit != null || task!.isRepeating)
                  Text(
                    isToday ? "Today's portion" : 'Portion for $dateLabel',
                    style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                  ),
                if (habit != null || task!.isRepeating) const SizedBox(height: 6),
                QuranPractice(
                  portion: quran,
                  study: QuranStudySession(state, now, asOf, task != null ? 'task/${task.id}' : 'habit/${habit!.id}'),
                  onComplete: future || done ? null : markDone,
                  portionDone: done,
                  dayLabel: isToday ? 'Today' : dateLabel,
                  whole: habit != null ? habit.guide?.quran : state.quranPlanForTask(task!),
                  newLabel: isToday ? 'New today' : 'New on $dateLabel',
                ),
              ],
              const SizedBox(height: 20),
              if (future)
                Text(
                      'Planned for ${DateFormat.yMMMMEEEEd().format(now)}, if each day before it is done.',
                      style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                    )
              else if (done)
                Row(
                      children: [
                        Icon(Icons.check_circle, color: t.colorScheme.primary),
                        const SizedBox(width: 8),
                        Expanded(child: Text(isToday ? 'Done for today. Well done for showing up.' : 'Done on $dateLabel.')),
                      ],
                    )
              else if (quran == null)
                FilledButton.icon(
                      key: const Key('guide-done'),
                      style: primaryButton,
                      onPressed: markDone,
                      icon: const Icon(Icons.check),
                      label: const Text('Mark done'),
                    ),
            ],
          ),
        );
      },
    );
  }
}
