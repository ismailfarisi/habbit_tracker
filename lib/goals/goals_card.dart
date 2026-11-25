import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../finance/money_screen.dart';
import '../logic/tasks.dart';
import '../widgets/ask_chat.dart';
import '../widgets/adaptive.dart';
import 'goal.dart';
import '../habits/habit.dart';
import '../logic/stats.dart';
import '../models.dart';
import '../quran/quran.dart';
import '../quran/task_guide_screen.dart';
import '../widgets/cards/section_card.dart';
import '../widgets/task_editor.dart';
import '../widgets/document_viewer.dart';
import 'goal_agenda.dart';
import 'goal_okf.dart';
import 'goal_outcomes.dart';
import 'goal_workspace_actions.dart';
import 'goal_guide_editor.dart';
import 'local_goal_editor.dart';

String reviewPrompt(Goal g) =>
    'Let\'s review my goal "${g.title}" (id ${g.id}). What went well, and what should I adjust?';

/// Plan's Goals section: each goal's timeline and progress, and a nudge when
/// a look-back is due.
class GoalsCard extends StatelessWidget {
  final AppState state;
  const GoalsCard({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final goals = state.goals.where((g) => !g.archived).toList();
    final now = DateTime.now();
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Goals${goals.isEmpty ? '' : ' · ${goals.length}'}',
                    style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                TextButton.icon(
                  key: const Key('new-goal'),
                  onPressed: () => showLocalGoalEditor(context, state),
                  icon: const Icon(Icons.flag_outlined),
                  label: const Text('New goal'),
                ),
              ],
            ),
            if (goals.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  'Choose an outcome and the first practice that will move it forward.',
                  style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
              ),
            for (final g in goals) _GoalTile(state: state, goal: g, now: now),
            if (state.goals.any((g) => g.archived))
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Archived goals'),
                children: [
                  for (final g in state.goals.where((g) => g.archived))
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(g.title),
                      subtitle: Text(g.workPaused ? 'Work and reminders paused' : 'Work kept standalone'),
                      trailing: TextButton(
                        onPressed: () => state.setGoalArchived(g, archived: false),
                        child: const Text('Restore'),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

String _modeLabel(String mode) => switch (mode) {
  'memorise' => 'Memorise',
  'revise' => 'Revise',
  _ => 'Read',
};

/// One line for a goal habit: e.g. "Memorise Al-Mulk 3–4 · 15 min · Every day at 05:30".
String goalHabitSubtitle(AppState state, HabitDef h, DateTime day) {
  final q = state.quranFor(h, day);
  final s = state.sessionForHabit(h, day);
  return [
    if (s != null) 'Session ${s.$1}/${s.$2}: ${s.$3}',
    if (q != null) '${_modeLabel(q.mode)} ${passageLabel(q.surah, q.from, q.to)}',
    if (h.guide?.minutes != null) '${h.guide!.minutes} min',
    h.describeSchedule(),
  ].join(' · ');
}

/// A goal habit row: tick to log, tap for its steps and Quran portion.
class GoalHabitTile extends StatelessWidget {
  final AppState state;
  final HabitDef habit;
  final DateTime day;
  const GoalHabitTile({super.key, required this.state, required this.habit, required this.day});

  @override
  Widget build(BuildContext context) {
    final entry = state.habitEntry(day, habit.id);
    final done = habitDone(entry, habit);
    final c = Theme.of(context).colorScheme;
    return ListTile(
      key: ValueKey('goal-habit-${habit.id}'),
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Checkbox.adaptive(
        value: done,
        onChanged: (v) => state.logHabit(day, habit.id, entry.copy()..done = v ?? false),
      ),
      title: Text(
        '${habit.emoji} ${habit.title}',
        style: TextStyle(
          fontWeight: FontWeight.w500,
          decoration: done ? TextDecoration.lineThrough : null,
          color: done ? c.onSurfaceVariant : null,
        ),
      ),
      subtitle: Text(goalHabitSubtitle(state, habit, day), maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push(TaskGuideScreen.route(state, habitId: habit.id, day: day)),
    );
  }
}

/// Today's card for one goal: its habits and tasks due today, together.
class GoalTodayCard extends StatelessWidget {
  final AppState state;
  final Goal goal;
  final DateTime now;
  const GoalTodayCard({super.key, required this.state, required this.goal, required this.now});

  /// The goal's habits scheduled on [now] and its tasks for that day.
  static (List<HabitDef>, List<Task>) itemsFor(AppState state, Goal g, DateTime now) => (
    state.activeHabits.where((h) => g.habitIds.contains(h.id) && h.isScheduledOn(now)).toList(),
    tasksForDay(state.tasks, now, today: now).where((t) => g.taskIds.contains(t.id)).toList(),
  );

  @override
  Widget build(BuildContext context) {
    final (habits, tasks) = itemsFor(state, goal, now);
    final done =
        habits.where((h) => habitDone(state.habitEntry(now, h.id), h)).length +
        tasks.where((t) => t.isDoneOn(now)).length;
    return SectionCard(
      emoji: goal.emoji,
      title: goal.title,
      trailing: CountBadge('$done/${habits.length + tasks.length}'),
      onTitleTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => GoalScreen(state: state, goalId: goal.id),
        ),
      ),
      children: [
        for (final h in habits) GoalHabitTile(state: state, habit: h, day: now),
        for (final t in tasks) TaskTile(state: state, task: t, day: now),
      ],
    );
  }
}

class _GoalTile extends StatelessWidget {
  final AppState state;
  final Goal goal;
  final DateTime now;
  const _GoalTile({required this.state, required this.goal, required this.now});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final outcomes = goalOutcomes(state, goal, now, includeSavings: true);
    final measure = outcomes.firstOrNull;
    return InkWell(
      key: ValueKey('goal-${goal.id}'),
      borderRadius: BorderRadius.circular(12),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => GoalScreen(state: state, goalId: goal.id),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(goal.emoji, style: const TextStyle(fontSize: 20)),
                const SizedBox(width: 8),
                Expanded(child: Text(goal.title, style: t.textTheme.titleSmall)),
                if (goal.reviewDue(now))
                  TextButton(
                    style: compactButton,
                    onPressed: () => askChat(state, reviewPrompt(goal), goalId: goal.id),
                    child: const Text('Review'),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            if (measure?.fraction case final value?)
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(value: value, minHeight: 6),
              ),
            const SizedBox(height: 4),
            Text(
              '${measure?.label ?? goal.horizon}'
              ' · until ${DateFormat('d MMM y').format(goal.endDate)}',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// One goal: why it matters, the timeline, milestones, linked tasks and
/// habits, and past reviews whose suggestions can be applied through Chat.
class GoalScreen extends StatelessWidget {
  final AppState state;
  final String goalId;
  const GoalScreen({super.key, required this.state, required this.goalId});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final g = state.goalById(goalId);
        if (g == null)
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('This goal was removed.')),
          );
        final t = Theme.of(context);
        final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
        final f = DateFormat('d MMM y');
        final now = DateTime.now();
        Widget heading(String s) => Padding(
          padding: const EdgeInsets.only(top: 20, bottom: 4),
          child: Text(s, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
        );
        final tasks = state.tasks.where((x) => g.taskIds.contains(x.id)).toList();
        final habits = state.habits.where((h) => g.habitIds.contains(h.id)).toList();
        void review() => askChat(state, reviewPrompt(g), context: context, goalId: g.id);

        final outcomes = goalOutcomes(state, g, now, includeSavings: true);
        void preview() => Navigator.of(context).push(
          DocumentViewer.route(
            title: '${g.title} · shared with this chat',
            markdown: goalOkf(state, g, now),
            fileName: '${okfSlug(g)}.md',
          ),
        );
        void edit({HabitDef? habit, Task? task}) => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => GoalGuideEditor(state: state, habit: habit, task: task),
          ),
        );
        return Scaffold(
          appBar: AppBar(
            title: Text('${g.emoji} ${g.title}'),
            actions: [
              PopupMenuButton<String>(
                key: const Key('goal-menu'),
                onSelected: (v) {
                  if (v == 'context') preview();
                  if (v == 'bundle') {
                    confirmDialog(
                      context,
                      title: 'Export all goals?',
                      message:
                          'Include the shared context of all ${state.goals.length} goals, including archived goals. Private notes stay on this device.',
                      confirm: 'Export',
                    ).then((ok) {
                      if (ok) shareOkfBundle(state);
                    });
                  }
                  if (v == 'open') DocumentViewer.pickAndOpen(context);
                  if (v == 'archive') chooseGoalArchive(context, state, g);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    key: Key('goal-context'),
                    value: 'context',
                    child: Text('View or export shared context'),
                  ),
                  PopupMenuItem(value: 'bundle', child: Text('Export all goals (OKF)')),
                  PopupMenuItem(value: 'open', child: Text('Open a Markdown or HTML file')),
                  PopupMenuItem(value: 'archive', child: Text('Archive goal')),
                ],
              ),
            ],
          ),
          body: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  _NextGoalSession(state: state, goal: g, now: now),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text('Next 14 days'),
                    children: [GoalAgenda(state: state, goal: g, from: now)],
                  ),
                  heading('Progress'),
                  if (g.why.isNotEmpty) Text(g.why, style: t.textTheme.bodyMedium),
                  for (final outcome in outcomes)
                    if (outcome.pot case final pot?)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(outcome.label),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => editPot(context, state, pot: pot),
                      )
                    else
                      Text(outcome.label),
                  Text(
                    '${f.format(g.startDate)} → ${f.format(g.endDate)} · ${(g.elapsed(now) * 100).round()}% of time passed',
                    style: muted,
                  ),
                  if (g.milestones.isNotEmpty) heading('Milestones'),
                  for (final m in g.milestones)
                    CheckboxListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: m.done,
                      title: Text(m.title),
                      subtitle: m.due == null ? null : Text('By ${f.format(DateTime.parse(m.due!))}'),
                      onChanged: (v) {
                        m.done = v ?? false;
                        state.saveGoals();
                      },
                    ),
                  if (habits.isNotEmpty || tasks.isNotEmpty) heading('Linked work'),
                  for (final h in habits)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.repeat),
                      title: Text(h.title),
                      subtitle: Text(h.describeSchedule()),
                      trailing: const Icon(Icons.edit_outlined),
                      onTap: () => edit(habit: h),
                    ),
                  for (final x in tasks)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.checklist),
                      title: Text(x.title),
                      subtitle: Text(x.describeSchedule()),
                      trailing: const Icon(Icons.edit_outlined),
                      onTap: () => edit(task: x),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => attachGoalWork(context, state, g),
                      icon: const Icon(Icons.link),
                      label: const Text('Attach existing work'),
                    ),
                  ),
                  heading('Notes'),
                  GoalNotes(state: state, goal: g, preview: preview),
                  heading('Reviews'),
                  Text('Looks back ${g.cadence.name}', style: muted),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton.tonalIcon(
                        key: const Key('review-goal'),
                        style: compactButton,
                        onPressed: review,
                        icon: const Icon(Icons.auto_awesome),
                        label: Text(g.reviewDue(now) ? 'Review is due' : 'Review with AI'),
                      ),
                      TextButton.icon(
                        key: const Key('goal-chat'),
                        style: compactButton,
                        onPressed: () => askChat(state, '', context: context, goalId: g.id),
                        icon: const Icon(Icons.chat_bubble_outline),
                        label: const Text('Chat'),
                      ),
                    ],
                  ),
                  if (g.reviews.isEmpty)
                    Text('Your first look back is ${f.format(g.lastLookBack.add(g.cadenceLength))}.', style: muted),
                  for (final r in g.reviews.reversed) ...[
                    const SizedBox(height: 8),
                    Text(f.format(r.at), style: muted),
                    Text(r.summary),
                    for (final (i, _) in r.suggestions.indexed)
                      GoalSuggestion(key: ValueKey('${r.at}-$i'), state: state, goal: g, review: r, index: i),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _NextGoalSession extends StatelessWidget {
  final AppState state;
  final Goal goal;
  final DateTime now;
  const _NextGoalSession({required this.state, required this.goal, required this.now});

  @override
  Widget build(BuildContext context) {
    final today = dateOnly(now);
    // Check the next weekly cycle, plus later start dates and dated work.
    final candidates = <DateTime>{
      for (var i = 0; i <= 7; i++) DateTime(today.year, today.month, today.day + i),
      for (final t in state.tasks.where((t) => goal.taskIds.contains(t.id) && t.date != null))
        for (var i = 0; i <= (t.isRepeating ? 6 : 0); i++) DateTime.parse(t.date!).add(Duration(days: i)),
    }.where((d) => !d.isBefore(today)).toList()..sort();
    for (final d in candidates) {
      final item = goalPlanFor(
        state,
        goal,
        d,
        today: today,
      ).where((i) => !i.done && (i.task != null || i.habit != null)).firstOrNull;
      if (item == null) continue;
      return ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(item.title, style: Theme.of(context).textTheme.titleLarge),
        subtitle: Text(
          [
            'Next session · ${d == today ? 'Today' : DateFormat.MMMEd().format(d)}',
            if (item.detail.isNotEmpty) item.detail,
          ].join('\n'),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(
          context,
        ).push(TaskGuideScreen.route(state, habitId: item.habit?.id, taskId: item.task?.id, day: d)),
      );
    }
    return const ListTile(contentPadding: EdgeInsets.zero, title: Text('No upcoming session'));
  }
}
