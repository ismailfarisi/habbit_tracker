import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../logic/stats.dart';
import '../models.dart';

enum _Cell { done, partial, late, missed }

class StatsScreen extends StatelessWidget {
  final AppState state;
  const StatsScreen({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final s = state.settings;
        final logs = state.logs;
        final t = Theme.of(context);

        bool wake(DayLog? l) => wakeDone(l, s);
        bool train(DayLog? l) => trainingDone(l, s);
        bool perfect(DayLog? l) => dailyScore(l, s) == maxDailyScore;

        final today = dateOnly(DateTime.now());
        final days = [for (var i = 29; i >= 0; i--) DateTime(today.year, today.month, today.day - i)];
        final last30 = days.map((d) => logs[dayKey(d)]).toList();
        final pct = last30.map((l) => dailyScore(l, s)).fold(0, (a, b) => a + b) / (30 * maxDailyScore);

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Progress', style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            GridView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                mainAxisExtent: 112,
              ),
              children: [
                _StreakTile('☀️ Early rising', streak(logs, wake), bestStreak(logs, wake)),
                _StreakTile('🕌 All 5 prayers', streak(logs, prayersDone), bestStreak(logs, prayersDone)),
                _StreakTile('🗣️ Training goal', streak(logs, train), bestStreak(logs, train)),
                _StreakTile('⭐ Perfect days', streak(logs, perfect), bestStreak(logs, perfect)),
              ],
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text('Last 30 days', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
                    Text('${(pct * 100).round()}% complete'),
                  ]),
                  const SizedBox(height: 12),
                  _row(context, 'Wake', last30.map((l) => switch (wakeResult(l, s)) {
                        WakeResult.onTime => _Cell.done,
                        WakeResult.late => _Cell.late,
                        WakeResult.none => _Cell.missed,
                      })),
                  for (final p in prayerNames)
                    _row(context, p, last30.map((l) => (l?.prayers.contains(p) ?? false) ? _Cell.done : _Cell.missed)),
                  _row(context, 'Training', last30.map((l) {
                    final m = l?.trainingMinutes ?? 0;
                    return m >= s.trainingGoalMin ? _Cell.done : (m > 0 ? _Cell.partial : _Cell.missed);
                  })),
                  const SizedBox(height: 8),
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Text(DateFormat('d MMM').format(days.first), style: t.textTheme.bodySmall),
                    Text('Today', style: t.textTheme.bodySmall),
                  ]),
                  const SizedBox(height: 12),
                  Wrap(spacing: 12, runSpacing: 4, children: [
                    _legend(context, _Cell.done, 'Done'),
                    _legend(context, _Cell.partial, 'Partial'),
                    _legend(context, _Cell.late, 'Late'),
                    _legend(context, _Cell.missed, 'Missed'),
                  ]),
                ]),
              ),
            ),
          ],
        );
      },
    );
  }

  static Color _color(BuildContext context, _Cell c) {
    final cs = Theme.of(context).colorScheme;
    return switch (c) {
      _Cell.done => Colors.green.shade500,
      _Cell.partial => Colors.green.shade200,
      _Cell.late => Colors.orange.shade400,
      _Cell.missed => cs.surfaceContainerHighest,
    };
  }

  Widget _row(BuildContext context, String label, Iterable<_Cell> cells) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          SizedBox(width: 64, child: Text(label, style: Theme.of(context).textTheme.bodySmall)),
          for (final c in cells)
            Expanded(
              child: AspectRatio(
                aspectRatio: 1,
                child: Container(
                  margin: const EdgeInsets.all(1),
                  decoration: BoxDecoration(color: _color(context, c), borderRadius: BorderRadius.circular(2)),
                ),
              ),
            ),
        ]),
      );

  Widget _legend(BuildContext context, _Cell c, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 12, height: 12, decoration: BoxDecoration(color: _color(context, c), borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 4),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ]);
}

class _StreakTile extends StatelessWidget {
  final String label;
  final int current;
  final int best;
  const _StreakTile(this.label, this.current, this.best);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(label, style: t.textTheme.bodySmall),
          Text('$current ${current == 1 ? 'day' : 'days'}', style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
          Text('Best: $best', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}
