import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
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
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

String reviewPrompt(Goal g) => 'Let\'s review my goal "${g.title}" (id ${g.id}). What went well, and what should I adjust?';

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
                  onPressed: () => askChat(state, 'Help me set a new goal'),
                  icon: const Icon(Icons.flag_outlined),
                  label: const Text('New goal'),
                ),
              ],
            ),
            if (goals.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  'Plan something bigger, a week or a few years long. The AI breaks it into milestones and tasks, '
                  'and looks back with you along the way.',
                  style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
              ),
            for (final g in goals) _GoalTile(state: state, goal: g, now: now),
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
String goalHabitSubtitle(AppState state, HabitDef h, DateTime day, {DateTime? today}) {
  final q = state.quranFor(h, day, today: today);
  final s = state.sessionForHabit(h, day, today: today);
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
        habits.where((h) => habitDone(state.habitEntry(now, h.id), h)).length + tasks.where((t) => t.isDoneOn(now)).length;
    return SectionCard(
      emoji: goal.emoji,
      title: goal.title,
      trailing: CountBadge('$done/${habits.length + tasks.length}'),
      onTitleTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => GoalScreen(state: state, goalId: goal.id))),
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
    final p = goal.progress(state.tasks);
    return InkWell(
      key: ValueKey('goal-${goal.id}'),
      borderRadius: BorderRadius.circular(12),
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => GoalScreen(state: state, goalId: goal.id))),
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
                    onPressed: () => askChat(state, reviewPrompt(goal)),
                    child: const Text('Review'),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(value: p, minHeight: 6),
            ),
            const SizedBox(height: 4),
            Text(
              '${goal.horizon} · ${goal.milestones.isEmpty ? '${(p * 100).round()}%' : '${goal.milestonesDone} of ${goal.milestones.length} milestones'}'
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
        if (g == null) return Scaffold(appBar: AppBar(), body: const Center(child: Text('This goal was removed.')));
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

        return Scaffold(
          appBar: AppBar(
            title: Text('${g.emoji} ${g.title}'),
            actions: [
              PopupMenuButton<String>(
                key: const Key('goal-menu'),
                onSelected: (v) => v == 'export' ? shareOkfBundle(state) : DocumentViewer.pickAndOpen(context),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'export', child: Text('Export all goals (OKF)')),
                  PopupMenuItem(value: 'open', child: Text('Open a Markdown or HTML file')),
                ],
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              if (g.why.isNotEmpty) Text('Why: ${g.why}', style: t.textTheme.bodyLarge),
              const SizedBox(height: 12),
              Text('${f.format(g.startDate)} → ${f.format(g.endDate)} · ${g.horizon}', style: muted),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(value: g.progress(state.tasks), minHeight: 8),
              ),
              const SizedBox(height: 4),
              Text(
                '${(g.progress(state.tasks) * 100).round()}% done · ${(g.elapsed(now) * 100).round()}% of the time passed',
                style: muted,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  FilledButton.tonalIcon(
                    key: const Key('review-goal'),
                    style: compactButton,
                    onPressed: review,
                    icon: const Icon(Icons.auto_awesome),
                    label: Text(g.reviewDue(now) ? 'Review is due' : 'Review with AI'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonalIcon(
                    key: const Key('goal-chat'),
                    style: compactButton,
                    onPressed: () => askChat(state, '', context: context, goalId: g.id),
                    icon: const Icon(Icons.chat_bubble_outline),
                    label: const Text('Chat'),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    key: const Key('goal-context'),
                    style: compactButton,
                    onPressed: () => Navigator.of(context).push(
                      DocumentViewer.route(title: '${g.title} · context', markdown: goalOkf(state, g, now), fileName: '${okfSlug(g)}.md'),
                    ),
                    icon: const Icon(Icons.description_outlined),
                    label: const Text('Context'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text('Looks back ${g.cadence.name}', style: muted),
              if (g.notes.trim().isNotEmpty) ...[
                heading('Notes'),
                MarkdownBody(data: g.notes),
              ],
              heading('Next 14 days'),
              GoalAgenda(state: state, goal: g, from: now),
              heading('Milestones'),
              if (g.milestones.isEmpty) Text('No milestones yet.', style: muted),
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
              if (habits.isNotEmpty) ...[
                heading('Daily practice'),
                for (final h in habits) GoalHabitTile(state: state, habit: h, day: now),
              ],
              heading('Tasks'),
              if (tasks.isEmpty) Text('No linked tasks.', style: muted),
              for (final x in tasks) TaskTile(state: state, task: x, day: now),
              heading('Reviews'),
              if (g.reviews.isEmpty) Text('Your first look back is ${f.format(g.lastLookBack.add(g.cadenceLength))}.', style: muted),
              for (final r in g.reviews.reversed) ...[
                const SizedBox(height: 8),
                Text(f.format(r.at), style: muted),
                Text(r.summary),
                for (final (i, s) in r.suggestions.indexed)
                  Row(
                    children: [
                      const Icon(Icons.lightbulb_outline, size: 16),
                      const SizedBox(width: 6),
                      Expanded(child: Text(s, style: t.textTheme.bodySmall)),
                      TextButton(
                        style: compactButton,
                        onPressed: r.applied.contains(i)
                            ? null
                            : () {
                                r.applied.add(i);
                                state.saveGoals();
                                askChat(
                                  state,
                                  'For my goal "${g.title}" (id ${g.id}), apply this suggestion: $s',
                                  display: 'Apply: $s',
                                  context: context,
                                );
                              },
                        child: Text(r.applied.contains(i) ? 'Applied' : 'Apply'),
                      ),
                    ],
                  ),
              ],
              const SizedBox(height: 24),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('archive-goal'),
                  onPressed: () {
                    g.archived = true;
                    state.saveGoals();
                    final messenger = ScaffoldMessenger.of(context);
                    Navigator.of(context).pop();
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text('Archived "${g.title}"'),
                        action: SnackBarAction(
                          label: 'Undo',
                          onPressed: () {
                            g.archived = false;
                            state.saveGoals();
                          },
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.archive_outlined),
                  label: const Text('Archive goal'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
