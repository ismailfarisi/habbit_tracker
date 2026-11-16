import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../habits/habit.dart';
import '../logic/stats.dart';
import '../logic/tasks.dart';
import '../logic/weekly_review.dart';
import '../models.dart';
import '../services/coach_prompts.dart';
import '../services/openrouter.dart';
import '../services/task_tools.dart';
import '../widgets/assistant_chat.dart';
import '../widgets/day_editor.dart';
import 'habit_detail_screen.dart';

/// The Progress tab: streak tiles (current streak, rule, "N of last 30",
/// freezes left), the weekly review and a 30-day grid of every tracked item
/// whose cells open the day editor.
class StatsScreen extends StatelessWidget {
  final AppState state;
  const StatsScreen({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final t = Theme.of(context);
        final today = dateOnly(DateTime.now());
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Progress', style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            _StreakGrid(state: state, today: today),
            const SizedBox(height: 12),
            WeeklyReviewCard(
              state: state,
              review: weeklyReview(
                settings: state.settings,
                logs: state.logs,
                habits: state.habits,
                tasks: state.tasks,
                today: today,
              ),
            ),
            const SizedBox(height: 12),
            ProgressGrid(state: state, today: today),
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
    final perfect = perfectDayStreak(s, logs, habits: state.habits, tasks: state.tasks, today: today);
    final tiles = [
      StreakTileData('☀️ Early rising', logStreak(logs, wake, today: today), ruleLabel(StreakRule.strict),
          consistency(logs, wake, today: today, scheduled: builtIn)),
      StreakTileData('🕌 All 5 prayers', logStreak(logs, prayersDone, today: today), ruleLabel(StreakRule.strict),
          consistency(logs, prayersDone, today: today, scheduled: builtIn)),
      StreakTileData(
        '⭐ Perfect days',
        perfect,
        'Freezes',
        consistencyBy(
          done: (d) => dayScore(d, s, logs, habits: state.habits, tasks: state.tasks).perfect,
          scheduled: builtIn,
          today: today,
        ),
        freezesLeft: (s.freezesPerMonth - perfect.freezesUsedThisMonth).clamp(0, s.freezesPerMonth),
      ),
      for (final h in state.activeHabits)
        StreakTileData(
          '${h.emoji} ${h.title}',
          habitStreak(logs, h, today: today),
          ruleLabel(h.streakRule),
          habitConsistency(logs, h, today: today),
          onTap: () => Navigator.of(context)
              .push(MaterialPageRoute<void>(builder: (_) => HabitDetailScreen(state: state, habitId: h.id))),
        ),
      for (final r in state.tasks.where((x) => x.isRepeating))
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
              freezes == null ? '${data.rule} · best ${data.info.best}' : 'Best ${data.info.best}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: muted,
            ),
            Text(c.total == 0 ? 'No days yet' : '${c.done} of last ${c.total}', style: t.textTheme.bodySmall),
            if (freezes != null)
              Text('❄️ $freezes ${freezes == 1 ? 'freeze' : 'freezes'} left this month', maxLines: 1, overflow: TextOverflow.ellipsis, style: muted),
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
    final pct = (r.week.fraction * 100).round();
    Widget line(String emoji, String text) => Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 26, child: Text(emoji)),
            Expanded(child: Text(text)),
          ]),
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text('Weekly review', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            ),
            Text('${f.format(r.start)} – ${f.format(r.end)}', style: t.textTheme.bodySmall),
          ]),
          if (r.isEmpty)
            line('📅', 'Log a few days to see your weekly review.')
          else ...[
            line(
              '📊',
              '${r.week.done} of ${r.week.total} done ($pct%)'
                  '${r.previousWeek.total == 0 ? '' : ' · last week ${(r.previousWeek.fraction * 100).round()}%'}',
            ),
            if (r.best != null) line('🏆', 'Best: ${r.best!.label} ${r.best!.done}/${r.best!.total}'),
            if (r.worst != null) line('⚠️', 'Needs work: ${r.worst!.label} ${r.worst!.done}/${r.worst!.total}'),
            if (r.pattern != null) line('📅', r.pattern!.describe()),
            if (r.suggestion != null) line('💡', r.suggestion!),
          ],
          const SizedBox(height: 12),
          if (state.apiKey.isNotEmpty)
            FilledButton.tonalIcon(
              onPressed: r.isEmpty ? null : () => showWeeklyReviewCoach(context, state, r),
              icon: const Icon(Icons.auto_awesome),
              label: const Text('Ask coach'),
            )
          else
            Text(
              'Add an OpenRouter API key in Settings to discuss your week with the coach.',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
        ]),
      ),
    );
  }
}

/// Opens the coach in a sheet and sends it [review] as context.
Future<void> showWeeklyReviewCoach(
  BuildContext context,
  AppState state,
  WeeklyReview review, {
  OpenRouterClient Function()? client,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: _ReviewCoachSheet(state: state, review: review, client: client),
    ),
  );
}

class _ReviewCoachSheet extends StatefulWidget {
  final AppState state;
  final WeeklyReview review;
  final OpenRouterClient Function()? client;
  const _ReviewCoachSheet({required this.state, required this.review, this.client});

  @override
  State<_ReviewCoachSheet> createState() => _ReviewCoachSheetState();
}

class _ReviewCoachSheetState extends State<_ReviewCoachSheet> {
  late final _chat = AssistantChat(
    widget.state,
    client: widget.client,
    systemPrompt: () =>
        '$weeklyReviewCoachPrompt\n$coachTaskPrompt\n${plannerContext(widget.state.settings, DateTime.now())}',
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _chat.send(widget.review.toPrompt(), display: '📊 Review my week');
    });
  }

  @override
  void dispose() {
    _chat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Coach · Weekly review', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        AssistantChatView(
          chat: _chat,
          hint: 'Message your coach',
          suggestions: const ['Make my plan easier', 'What should I fix first?'],
        ),
      ]),
    );
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
  return [
    GridRow('wake', 'Wake', [
      for (final d in days)
        switch (wakeResult(logs[dayKey(d)], s)) {
          WakeResult.onTime => GridCell.done,
          WakeResult.late => GridCell.late,
          WakeResult.none => GridCell.missed,
        },
    ]),
    for (final p in prayerNames)
      GridRow('prayer:$p', p, [
        for (final d in days)
          switch (logs[dayKey(d)]) {
            final l? when l.prayers.contains(p) => switch (l.prayerStatus[p]) {
                prayerLate => GridCell.late,
                prayerQada => GridCell.qada,
                _ => GridCell.done,
              },
            _ => GridCell.missed,
          },
      ]),
    for (final h in state.activeHabits)
      GridRow('habit:${h.id}', h.title, [
        for (final d in days)
          if (!h.isScheduledOn(d))
            GridCell.off
          else
            switch (logs[dayKey(d)]?.habits[h.id]) {
              final e when habitDone(e, h) => GridCell.done,
              final e when habitProgress(e, h) > 0 => GridCell.partial,
              _ => GridCell.missed,
            },
      ]),
    for (final r in state.tasks.where((t) => t.isRepeating))
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
    final s = state.settings;
    final dates = [for (var i = days - 1; i >= 0; i--) DateTime(today.year, today.month, today.day - i)];
    final rows = progressGridRows(state, dates);
    final scores = dates.map((d) => dayScore(d, s, state.logs, habits: state.habits, tasks: state.tasks)).toList();
    final total = scores.fold(0, (a, b) => a + b.total);
    final pct = total == 0 ? 0 : scores.fold(0, (a, b) => a + b.done) / total;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text('Last $days days', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            ),
            Text('${(pct * 100).round()}% complete'),
          ]),
          const SizedBox(height: 4),
          Text('Tap a day to edit it.', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
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
