import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../habits/habit.dart';
import '../logic/stats.dart';
import '../logic/tasks.dart';
import '../logic/weekly_review.dart';
import '../models.dart';
import '../widgets/day_editor.dart';
import 'calendar_screen.dart';
import 'habit_detail_screen.dart';
import '../widgets/adaptive.dart';
import '../widgets/ask_chat.dart';
import '../widgets/focus_settings.dart';
import '../widgets/review_practice.dart';

/// Weekly practice and return history, with optional streak and grid views.
class ProgressScreen extends StatelessWidget {
  final AppState state;
  const ProgressScreen({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final today = dateOnly(DateTime.now());
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            WeeklyReviewCard(
              state: state,
              review: weeklyReview(settings: state.settings, logs: state.logs, habits: state.habits,
                tasks: state.tasks, goals: state.goals, today: today),
            ),
            _WeeklyList(state: state, today: today),
            ExpansionTile(title: const Text('Streak details'), children: [_StreakGrid(state: state, today: today)]),
            ExpansionTile(title: const Text('30-day overview'), children: [ProgressGrid(state: state, today: today)]),
            const SizedBox(height: 12),
            CalendarEntryCard(state: state),
            ScreenTimeCard(state: state),
          ],
        );
      },
    );
  }
}

String ruleLabel(StreakRule r) => switch (r) {
      StreakRule.strict => 'Strict',
      StreakRule.neverMissTwice => 'Never miss twice',
    };

class StreakTileData {
  final String label;
  final StreakInfo info;
  final String rule;
  final Consistency consistency;
  final int? freezesLeft;
  final VoidCallback? onTap;
  const StreakTileData(this.label, this.info, this.rule, this.consistency, {this.freezesLeft, this.onTap});
}

class _StreakGrid extends StatelessWidget {
  final AppState state;
  final DateTime today;
  const _StreakGrid({required this.state, required this.today});

  @override
  Widget build(BuildContext context) {
    final s = state.settings;
    final logs = state.logs;
    final first = firstLogDay(logs);
    bool builtIn(DateTime d) => first != null && !d.isBefore(first);
    bool wake(DayLog? l) => wakeDone(l, s);
    final perfect = perfectDayStreak(s, logs, habits: state.habits, tasks: state.tasks, goals: state.goals, today: today);
    final tiles = [
      if (s.tracks('wake')) StreakTileData('Early rising', logStreak(logs, wake, today: today), ruleLabel(StreakRule.strict),
          consistency(logs, wake, today: today, scheduled: (d) => builtIn(d) && s.tracksOn('wake', d))),
      if (s.tracks('prayers')) StreakTileData('All 5 prayers', logStreak(logs, prayersDone, today: today), ruleLabel(StreakRule.strict),
          consistency(logs, prayersDone, today: today, scheduled: (d) => builtIn(d) && s.tracksOn('prayers', d))),
      StreakTileData(
        'Perfect days',
        perfect,
        'Freezes',
        consistencyBy(
          done: (d) => dayScore(d, s, logs, habits: state.habits, tasks: state.tasks, goals: state.goals).perfect,
          scheduled: (d) => builtIn(d) && dayScore(d, s, logs, habits: state.habits, tasks: state.tasks, goals: state.goals).total > 0,
          today: today,
        ),
        freezesLeft: (s.freezesPerMonth - perfect.freezesUsedThisMonth).clamp(0, s.freezesPerMonth),
      ),
      for (final h in state.trackedHabits)
        StreakTileData(
          '${h.emoji} ${h.title}',
          habitStreak(logs, h, today: today),
          ruleLabel(h.streakRule),
          habitConsistency(logs, h, today: today),
          onTap: () => Navigator.of(context)
              .push(MaterialPageRoute<void>(builder: (_) => HabitDetailScreen(state: state, habitId: h.id))),
        ),
      for (final r in state.trackedTasks.where((x) => x.isRepeating))
        StreakTileData('📝 ${r.title}', taskStreak(r, today: today), ruleLabel(StreakRule.neverMissTwice),
            taskConsistency(r, today: today)),
    ];
    return GridView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        mainAxisExtent: MediaQuery.textScalerOf(context).scale(144),
      ),
      children: [for (final d in tiles) StreakTile(d)],
    );
  }
}

class StreakTile extends StatelessWidget {
  final StreakTileData data;
  const StreakTile(this.data, {super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final c = data.consistency;
    final n = data.info.current;
    final freezes = data.freezesLeft;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: data.onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(data.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.bodySmall),
            Text('$n ${n == 1 ? 'day' : 'days'}', style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
            Text(
              freezes == null ? data.rule : '$freezes ${freezes == 1 ? 'freeze' : 'freezes'} left',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: muted,
            ),
            Text(c.total == 0 ? 'No days yet' : '${c.done} of last ${c.total}', style: t.textTheme.bodySmall),
            Text('Best ${data.info.best}', maxLines: 1, overflow: TextOverflow.ellipsis, style: muted),
          ]),
        ),
      ),
    );
  }
}

// ---------- Weekly review ----------

class WeeklyReviewCard extends StatelessWidget {
  final AppState state;
  final WeeklyReview review;
  const WeeklyReviewCard({super.key, required this.state, required this.review});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final r = review;
    final f = DateFormat('d MMM');
    final habits = state.trackedHabits;
    final days = r.practiceDays;
    final date = DateFormat('EEEE');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Weekly review', style: t.textTheme.titleMedium),
          Text('${f.format(r.start)} – ${f.format(r.end)}', style: t.textTheme.bodySmall),
          const SizedBox(height: 12),
          Text(days.total == 0
            ? 'Your week starts with your next practice.'
            : 'You practised on ${days.done} of your ${days.total} planned ${days.total == 1 ? 'day' : 'days'}.',
            style: t.textTheme.headlineSmall),
          const SizedBox(height: 6),
          Text(r.returnedOn != null ? 'You returned on ${date.format(r.returnedOn!)} after a break.'
            : r.lastPractice != null ? 'Your most recent practice was on ${date.format(r.lastPractice!)}.'
            : 'A short session counts as practice.'),
          const SizedBox(height: 12),
          if (habits.isNotEmpty)
            OutlinedButton.icon(icon: const Icon(Icons.tune), label: const Text('Review a practice'),
              onPressed: () async {
                final habit = habits.length == 1 ? habits.single : await showModalBottomSheet<HabitDef>(
                  context: context, showDragHandle: true,
                  builder: (c) => SafeArea(child: ListView(shrinkWrap: true, children: [
                    for (final h in habits) ListTile(title: Text(h.title), onTap: () => Navigator.pop(c, h)),
                  ])),
                );
                if (context.mounted && habit != null) await reviewPractice(context, state, habit, r.end);
              }),
          if (state.apiKey.isNotEmpty)
            FilledButton.tonalIcon(
              style: compactButton,
              onPressed: r.isEmpty
                  ? null
                  : () => askChat(
                      state,
                      '$weeklyReviewCoachPrompt\n\n${r.toPrompt()}',
                      display: '📊 Review my week',
                      context: context,
                    ),
              icon: const Icon(Icons.auto_awesome),
              label: const Text('Ask coach'),
            ),
        ]),
      ),
    );
  }
}

/// The default history is a list with wrapping labels and day-sized edit
/// targets. The compact chart is available separately as an overview.
class _WeeklyList extends StatelessWidget {
  final AppState state;
  final DateTime today;
  const _WeeklyList({required this.state, required this.today});

  @override
  Widget build(BuildContext context) {
    final dates = [for (var i = 6; i >= 0; i--) DateTime(today.year, today.month, today.day - i)];
    final rows = progressGridRows(state, dates);
    if (rows.isEmpty) return const SizedBox.shrink();
    return Card(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text('This week by practice', style: Theme.of(context).textTheme.titleMedium)),
      for (final row in rows)
        Builder(builder: (context) {
          final planned = row.cells.where((cell) => cell != GridCell.off).length -
              (row.cells.last == GridCell.missed ? 1 : 0);
          final practised = row.cells.where((cell) => cell != GridCell.off && cell != GridCell.missed).length;
          return ExpansionTile(
            key: PageStorageKey('weekly-${row.id}'),
            title: Text(row.label),
            subtitle: Text(planned == 0 ? (row.cells.last == GridCell.missed ? 'Planned today' : 'No practice planned this week') : '$practised of $planned planned days'),
            children: [
              for (var i = 0; i < dates.length; i++)
                if (row.cells[i] != GridCell.off)
                  ListTile(title: Text(DateFormat('EEEE, d MMM').format(dates[i])),
                    subtitle: Text(switch (row.cells[i]) {
                      GridCell.done => 'Done', GridCell.partial => 'Practised', GridCell.late => 'Logged late',
                      GridCell.qada => 'Made up', _ => dates[i] == today ? 'Planned today' : 'No entry',
                    }),
                    trailing: const Icon(Icons.edit_outlined),
                    onTap: () => showDayEditor(context, state, dates[i])),
            ],
          );
        }),
    ]));
  }
}

// ---------- 30-day grid ----------

enum GridCell { done, partial, late, qada, missed, off }

class GridRow {
  final String id;
  final String label;
  final List<GridCell> cells;
  const GridRow(this.id, this.label, this.cells);
}

/// Rows of the 30-day grid for [days]: wake, each prayer (by status), every
/// active habit and repeating task. Unscheduled days are [GridCell.off].
List<GridRow> progressGridRows(AppState state, List<DateTime> days) {
  final s = state.settings;
  final logs = state.logs;
  final start = firstLogDay(logs);
  bool expected(String id, DateTime d) => s.tracksOn(id, d) && (start == null
      ? !d.isBefore(dateOnly(DateTime.now())) : !d.isBefore(start));
  return [
    if (s.tracks('wake')) GridRow('wake', 'Wake', [
      for (final d in days)
        if (!expected('wake', d)) GridCell.off else switch (wakeResult(logs[dayKey(d)], s)) {
          WakeResult.onTime => GridCell.done,
          WakeResult.late => GridCell.late,
          WakeResult.none => GridCell.missed,
        },
    ]),
    if (s.tracks('prayers')) for (final p in prayerNames)
      GridRow('prayer:$p', p, [
        for (final d in days)
          if (!expected('prayers', d)) GridCell.off else switch (logs[dayKey(d)]) {
            final l? when l.prayers.contains(p) => switch (l.prayerStatus[p]) {
                prayerLate => GridCell.late,
                prayerQada => GridCell.qada,
                _ => GridCell.done,
              },
            _ => GridCell.missed,
          },
      ]),
    for (final h in state.trackedHabits)
      GridRow('habit:${h.id}', h.title, [
        for (final d in days)
          if (!h.isScheduledOn(d))
            GridCell.off
          else
            switch (logs[dayKey(d)]?.habits[h.id]) {
              final e when habitDone(e, h) => GridCell.done,
              final e when practisedHabit(e, h) => GridCell.partial,
              _ => GridCell.missed,
            },
      ]),
    for (final r in state.trackedTasks.where((t) => t.isRepeating))
      GridRow('task:${r.id}', r.title, [
        for (final d in days) !taskCountsOn(r, d) ? GridCell.off : (r.isDoneOn(d) ? GridCell.done : GridCell.missed),
      ]),
  ];
}

class ProgressGrid extends StatelessWidget {
  final AppState state;
  final DateTime today;
  final int days;
  const ProgressGrid({super.key, required this.state, required this.today, this.days = 30});

  static Key cellKey(String rowId, DateTime day) => ValueKey('cell:$rowId:${dayKey(day)}');

  static Color color(BuildContext context, GridCell c) {
    final cs = Theme.of(context).colorScheme;
    return switch (c) {
      GridCell.done => Colors.green.shade500,
      GridCell.partial => Colors.green.shade200,
      GridCell.late => Colors.orange.shade400,
      GridCell.qada => Colors.deepPurple.shade300,
      GridCell.missed => cs.surfaceContainerHighest,
      GridCell.off => Colors.transparent,
    };
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dates = [for (var i = days - 1; i >= 0; i--) DateTime(today.year, today.month, today.day - i)];
    final rows = progressGridRows(state, dates);
    final planned = rows.expand((r) => r.cells).where((c) => c != GridCell.off);
    final practised = planned.where((c) => c != GridCell.missed).length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text('Last $days days', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            ),

          ]),
          const SizedBox(height: 4),
          Text('Practice logged for $practised of ${planned.length} planned items. Tap a day to edit it.', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 8),
          for (final r in rows) _row(context, r, dates),
          const SizedBox(height: 8),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Padding(
              padding: const EdgeInsets.only(left: 64),
              child: Text(DateFormat('d MMM').format(dates.first), style: t.textTheme.bodySmall),
            ),
            Text('Today', style: t.textTheme.bodySmall),
          ]),
          const SizedBox(height: 12),
          Wrap(spacing: 12, runSpacing: 4, children: [
            _legend(context, GridCell.done, 'Done / on time'),
            _legend(context, GridCell.partial, 'Partial'),
            _legend(context, GridCell.late, 'Late'),
            _legend(context, GridCell.qada, 'Qada'),
            _legend(context, GridCell.missed, 'Missed'),
            _legend(context, GridCell.off, 'Not scheduled'),
          ]),
        ]),
      ),
    );
  }

  Widget _row(BuildContext context, GridRow row, List<DateTime> dates) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          SizedBox(
            width: 64,
            child: Text(row.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
          ),
          for (var i = 0; i < dates.length; i++)
            Expanded(
              child: AspectRatio(
                aspectRatio: 1,
                child: Semantics(
                  button: true,
                  label: '${row.label}, ${DateFormat('d MMMM').format(dates[i])}',
                  child: GestureDetector(
                    key: cellKey(row.id, dates[i]),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => showDayEditor(context, state, dates[i]),
                    child: _cell(context, row.cells[i]),
                  ),
                ),
              ),
            ),
        ]),
      );

  Widget _cell(BuildContext context, GridCell c) => Container(
        margin: const EdgeInsets.all(1),
        decoration: BoxDecoration(
          color: color(context, c),
          borderRadius: BorderRadius.circular(2),
          border: c == GridCell.off ? Border.all(color: Theme.of(context).colorScheme.outlineVariant, width: 0.5) : null,
        ),
      );

  Widget _legend(BuildContext context, GridCell c, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(width: 12, height: 12, child: _cell(context, c)),
        const SizedBox(width: 4),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ]);
}
