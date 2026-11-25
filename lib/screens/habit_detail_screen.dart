import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../agent/habit_surface.dart';
import '../app_state.dart';
import '../habits/habit.dart';
import '../logic/stats.dart';
import '../models.dart';
import '../widgets/charts.dart';
import 'habit_screen_editor.dart';
import 'progress_screen.dart' show ruleLabel;
import '../widgets/ask_chat.dart';

/// A habit's own screen: its A2UI surface for [day] (today by default),
/// streak and consistency, charts of its metrics over time (per practice
/// session where sessions exist), the list of sessions, and the archive /
/// coach actions.
class HabitDetailScreen extends StatelessWidget {
  final AppState state;
  final String habitId;
  final DateTime? day;
  const HabitDetailScreen({super.key, required this.state, required this.habitId, this.day});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final habit = state.habitById(habitId);
        if (habit == null) {
          return Scaffold(appBar: AppBar(), body: const Center(child: Text('This habit was removed.')));
        }
        final d = day ?? DateTime.now();
        final t = Theme.of(context);
        final s = habitStreak(state.logs, habit);
        final c = habitConsistency(state.logs, habit);
        final sessions = habitSessions(state.logs, habit.id);
        final metrics = habitMetricKeys(state.logs, habit);
        final daily = switch (habit.kind) {
          HabitKind.duration || HabitKind.practice => ('Minutes per day', 'minutes'),
          HabitKind.count => ('${habit.unit.isEmpty ? 'Count' : _capitalise(habit.unit)} per day', 'value'),
          _ => null,
        };
        return Scaffold(
          appBar: AppBar(
            title: Text('${habit.emoji}  ${habit.title}'),
            actions: [
              IconButton(
                tooltip: 'Ask coach',
                icon: const Icon(Icons.auto_awesome),
                onPressed: () => askChat(
                  state,
                  'Coach me on my "${habit.title}" habit (id ${habit.id}): how am I doing and what should I adjust?',
                  display: 'Coach me on ${habit.title}',
                  context: context,
                ),
              ),
              PopupMenuButton<String>(
                onSelected: (v) async {
                  final nav = Navigator.of(context);
                  if (v == 'edit') {
                    await nav.push(MaterialPageRoute<void>(
                      builder: (_) => HabitScreenEditor(state: state, habit: habit, day: d),
                    ));
                    return;
                  }
                  await state.archiveHabit(habit.id, archived: !habit.archived);
                  if (v == 'archive') nav.pop();
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'edit', child: Text('Edit habit screen')),
                  PopupMenuItem(
                    value: habit.archived ? 'restore' : 'archive',
                    child: Text(habit.archived ? 'Restore habit' : 'Archive habit'),
                  ),
                ],
              ),
            ],
          ),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  '${DateFormat('EEEE, d MMMM').format(d)} · ${habit.describeSchedule()}',
                  style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 4),
                Text(
                  'Streak ${s.current} ${s.current == 1 ? 'day' : 'days'} (best ${s.best}, ${ruleLabel(habit.streakRule).toLowerCase()})'
                  ' · ${c.done} of last ${c.total} days',
                  style: t.textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: HabitSurface(state, habit, d),
                  ),
                ),
                if (daily != null) ...[
                  _heading(context, daily.$1),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        DailyBarChart(values: metricHistory(state.logs, habit, daily.$2, end: d), target: habit.target,
                            end: d, unit: daily.$2 == 'minutes' ? 'minutes' : habit.unit),
                        const SizedBox(height: 4),
                        Text('Last 30 days · dashed line is the target of ${formatChartValue(habit.target)}',
                            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                      ]),
                    ),
                  ),
                ],
                if (metrics.isNotEmpty) ...[
                  _heading(context, sessions.isEmpty ? 'Metrics' : 'Metrics per session'),
                  for (final m in metrics) MetricChartCard(field: m, points: habitMetricSeries(state.logs, habit, m.key)),
                ],
                if (sessions.isNotEmpty) ...[
                  _heading(context, 'Sessions (${sessions.length})'),
                  Card(
                    clipBehavior: Clip.antiAlias,
                    child: Column(children: [
                      for (final s in sessions.take(30)) SessionTile(session: s, fields: habit.metricFields),
                    ]),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _heading(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
      );
}

String _capitalise(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

/// Every session logged for [habitId], newest first.
List<HabitSession> habitSessions(Map<String, DayLog> logs, String habitId) => [
      for (final l in logs.values) ...?l.habits[habitId]?.sessions,
    ]..sort((a, b) => b.at.compareTo(a.at));

/// The habit's declared metric fields followed by any other metric keys
/// that were logged for it.
List<MetricField> habitMetricKeys(Map<String, DayLog> logs, HabitDef habit) {
  final known = {for (final f in habit.metricFields) f.key};
  final extra = <String>{};
  for (final l in logs.values) {
    final e = l.habits[habit.id];
    if (e == null) continue;
    for (final k in [...e.metrics.keys, for (final s in e.sessions) ...s.metrics.keys]) {
      if (!known.contains(k)) extra.add(k);
    }
  }
  return [...habit.metricFields, for (final k in extra.toList()..sort()) MetricField(key: k, label: _capitalise(k))];
}

/// Values of metric [key] over time, oldest first: one point per practice
/// session, plus the day's value for days that have it but no session
/// with it.
List<ChartPoint> habitMetricSeries(Map<String, DayLog> logs, HabitDef habit, String key) {
  final points = <ChartPoint>[];
  for (final MapEntry(key: day, value: log) in logs.entries) {
    final e = log.habits[habit.id];
    if (e == null) continue;
    final fromSessions = [
      for (final s in e.sessions)
        if (s.metrics[key] != null) ChartPoint(s.at, s.metrics[key]!),
    ];
    if (fromSessions.isNotEmpty) {
      points.addAll(fromSessions);
    } else if (e.metrics[key] != null) {
      final d = DateTime.tryParse(day);
      if (d != null) points.add(ChartPoint(DateTime(d.year, d.month, d.day, 12), e.metrics[key]!));
    }
  }
  return points..sort((a, b) => a.at.compareTo(b.at));
}

class MetricChartCard extends StatelessWidget {
  final MetricField field;
  final List<ChartPoint> points;
  const MetricChartCard({super.key, required this.field, required this.points});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final last = points.isEmpty ? null : points.last.value;
    final delta = points.length < 2 ? null : points.last.value - points.first.value;
    final good = delta == null || delta == 0 ? null : (delta > 0) != (field.better == 'down');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Expanded(child: Text(field.label, style: t.textTheme.titleSmall)),
            if (last != null) Text('${formatChartValue(last)} ${field.unit}'.trim(), style: t.textTheme.titleSmall),
          ]),
          if (delta != null && delta != 0)
            Text(
              '${delta > 0 ? '+' : ''}${formatChartValue(delta)} since the first of ${points.length} '
              '(${field.better == 'down' ? 'lower' : 'higher'} is better)',
              style: muted?.copyWith(color: good! ? Colors.green.shade700 : t.colorScheme.error),
            ),
          const SizedBox(height: 8),
          if (points.isEmpty)
            Text('No data yet', style: muted)
          else
            LineChart(points: points, unit: field.unit),
        ]),
      ),
    );
  }
}

class SessionTile extends StatelessWidget {
  final HabitSession session;
  final List<MetricField> fields;
  const SessionTile({super.key, required this.session, this.fields = const []});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = session;
    final labels = {for (final f in fields) f.key: f};
    final metrics = s.metrics.entries.map((e) {
      final f = labels[e.key];
      return '${f?.label ?? _capitalise(e.key)} ${formatChartValue(e.value)}${f == null || f.unit.isEmpty ? '' : ' ${f.unit}'}';
    }).join(' · ');
    final dur = s.durationSec >= 60 ? '${s.durationSec ~/ 60} min ${s.durationSec % 60} s' : '${s.durationSec} s';
    final details = [
      if (s.transcript != null && s.transcript!.trim().isNotEmpty) ('Transcript', s.transcript!),
      if (s.aiFeedback != null && s.aiFeedback!.trim().isNotEmpty) ('Coach feedback', s.aiFeedback!),
    ];
    final title = Text('${DateFormat('EEE d MMM, HH:mm').format(s.at)}${s.durationSec > 0 ? ' · $dur' : ''}');
    final subtitle = metrics.isEmpty ? null : Text(metrics);
    if (details.isEmpty) return ListTile(dense: true, title: title, subtitle: subtitle);
    return ExpansionTile(
      dense: true,
      title: title,
      subtitle: subtitle,
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      children: [
        for (final (label, text) in details) ...[
          Text(label, style: t.textTheme.labelMedium),
          Padding(padding: const EdgeInsets.only(top: 2, bottom: 8), child: Text(text)),
        ],
      ],
    );
  }
}
