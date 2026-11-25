import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../finance/finance_agenda.dart';
import '../goals/goal.dart';
import '../goals/goals_card.dart';
import '../habits/habit.dart';
import '../logic/stats.dart';
import '../logic/tasks.dart';
import '../models.dart';
import '../quran/task_guide_screen.dart';
import '../widgets/day_editor.dart';
import '../widgets/task_editor.dart';

/// What one calendar day holds: how much of the wake-up, prayers, habits and
/// tasks was done, and the goal milestones due.
class CalendarDay {
  final int done, total, tasks, habits;
  final List<Milestone> milestones;
  const CalendarDay(this.done, this.total, this.tasks, this.milestones, {this.habits = 0});
  double get fraction => total == 0 ? 0 : done / total;
}

CalendarDay calendarDay(AppState s, DateTime day, DateTime today) {
  final d = dateOnly(day);
  final past = !d.isAfter(dateOnly(today));
  final tasks = tasksForDay(s.trackedTasks, d, today: today);
  final habits = s.trackedHabits.where((h) => h.isScheduledOn(d)).toList();
  final score = past ? dayScore(d, s.settings, s.logs, habits: habits, tasks: tasks, goals: s.goals) : const DayScore(0, 0);
  // The shared habit score covers repeating tasks. The calendar also shows
  // completion for dated one-offs on the selected day.
  final oneOffs = past ? tasks.where((t) => !t.isRepeating) : const <Task>[];
  final done = score.done + oneOffs.where((t) => t.isDoneOn(d)).length;
  final key = dayKey(d);
  return CalendarDay(done, score.total + oneOffs.length, tasks.length, [
    for (final g in s.goals.where((g) => !g.archived))
      for (final m in g.milestones)
        if (m.due == key) m,
  ], habits: habits.length);
}

/// A month at a glance: each past day shaded by how much was done, dots for
/// planned tasks and flags for goal milestones. Tapping a day shows it below.
class CalendarScreen extends StatefulWidget {
  final AppState state;
  final DateTime Function()? clock;
  const CalendarScreen({super.key, required this.state, this.clock});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  late DateTime _today = dateOnly((widget.clock ?? DateTime.now)());
  late DateTime _selected = _today;
  bool? _agendaChoice;

  void _shift(int delta, bool agenda) => setState(() {
    if (agenda) {
      _selected = DateTime(_selected.year, _selected.month, _selected.day + delta);
    } else {
      final month = DateTime(_selected.year, _selected.month + delta);
      final day = math.min(_selected.day, DateUtils.getDaysInMonth(month.year, month.month));
      _selected = DateTime(month.year, month.month, day);
    }
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = t.colorScheme;
    final state = widget.state;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Calendar'),
        actions: [
          TextButton(
            onPressed: () => setState(() {
              _today = dateOnly((widget.clock ?? DateTime.now)());
              _selected = _today;
            }),
            child: const Text('Today'),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final first = DateTime(_selected.year, _selected.month);
          final scale = MediaQuery.textScalerOf(context);
          final agenda = _agendaChoice ?? (MediaQuery.sizeOf(context).width < 600 || scale.scale(14) > 20);
          final unit = agenda ? 'day' : 'month';
          final overview = Column(
            children: [
              Align(
                child: SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Month')),
                    ButtonSegment(value: true, label: Text('Agenda')),
                  ],
                  selected: {agenda},
                  onSelectionChanged: (v) => setState(() => _agendaChoice = v.single),
                ),
              ),
              Row(
                children: [
                  IconButton(tooltip: 'Previous $unit', onPressed: () => _shift(-1, agenda), icon: const Icon(Icons.chevron_left)),
                  Expanded(
                    child: Text(
                      agenda ? DateFormat.MMMEd().format(_selected) : DateFormat.yMMMM().format(first),
                      textAlign: TextAlign.center,
                      style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(tooltip: 'Next $unit', onPressed: () => _shift(1, agenda), icon: const Icon(Icons.chevron_right)),
                ],
              ),
              if (!agenda) ...[
                LayoutBuilder(builder: (context, constraints) {
                  final width = math.max(constraints.maxWidth, 7.0 * math.max(48.0, scale.scale(32)));
                  return SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: width,
                      child: Column(
                        children: [
                          Row(
                            children: [
                              for (final name in const ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'])
                                Expanded(child: Center(child: Text(name.substring(0, 3), semanticsLabel: name, style: t.textTheme.labelSmall))),
                            ],
                          ),
                          GridView.count(
                            crossAxisCount: 7,
                            shrinkWrap: true,
                            primary: false,
                            physics: const NeverScrollableScrollPhysics(),
                            mainAxisExtent: math.max(52, scale.scale(18) + 28),
                            children: [
                              for (var i = 1; i < first.weekday; i++) const SizedBox.shrink(),
                              for (var d = 1; d <= DateUtils.getDaysInMonth(first.year, first.month); d++)
                                _cell(context, DateTime(first.year, first.month, d)),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                }),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Wrap(
                    spacing: 12,
                    children: [
                      for (final (icon, label) in const [
                        (Icons.circle, 'Planned'), (Icons.flag, 'Milestone'), (Icons.check, 'Progress logged'),
                      ])
                        Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(icon, size: 12, color: c.onSurfaceVariant),
                          const SizedBox(width: 4),
                          Text(label, style: t.textTheme.bodySmall),
                        ]),
                    ],
                  ),
                ),
              ],
            ],
          );
          final details = _DayDetails(key: ValueKey(_selected), state: state, day: _selected, today: _today);
          final split = !agenda && MediaQuery.sizeOf(context).width >= 840 && scale.scale(14) <= 20;
          const padding = EdgeInsets.fromLTRB(12, 4, 12, 24);
          if (split) {
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1200),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: SingleChildScrollView(primary: false, padding: padding, child: overview)),
                  Expanded(child: SingleChildScrollView(primary: false, padding: padding, child: details)),
                ]),
              ),
            );
          }
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 800),
              child: ListView(padding: padding, children: [overview, details]),
            ),
          );
        },
      ),
    );
  }

  Widget _cell(BuildContext context, DateTime d) {
    final c = Theme.of(context).colorScheme;
    final info = calendarDay(widget.state, d, _today);
    final selected = DateUtils.isSameDay(d, _selected);
    final isToday = DateUtils.isSameDay(d, _today);
    final fill = selected ? c.primaryContainer : info.done > 0 ? c.secondaryContainer : c.surfaceContainerLow;
    final ink = selected ? c.onPrimaryContainer : info.done > 0 ? c.onSecondaryContainer : c.onSurface;
    final markers = [
      if (info.tasks + info.habits > 0) Icons.circle,
      if (info.milestones.isNotEmpty) Icons.flag,
      if (info.done > 0) Icons.check,
    ];
    void select() => setState(() => _selected = d);
    return Semantics(
      key: ValueKey('cal-${dayKey(d)}'),
      excludeSemantics: true,
      button: true,
      selected: selected,
      onTap: select,
      label: [
        DateFormat.yMMMMEEEEd().format(d),
        if (isToday) 'Today',
        '${info.tasks} planned tasks', '${info.habits} planned habits',
        '${info.milestones.length} milestones',
        if (isForecastDay(d, today: _today)) 'Forecast' else '${info.done} of ${info.total} tracked items done',
      ].join(', '),
      child: InkWell(
        onTap: select,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          margin: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(10),
            border: selected || isToday ? Border.all(color: selected ? c.primary : c.outline, width: selected ? 2 : 1) : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('${d.day}', style: TextStyle(color: ink, fontWeight: isToday ? FontWeight.w700 : null)),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                for (final icon in markers) Icon(icon, size: icon == Icons.circle ? 6 : 12, color: ink),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

class _DayDetails extends StatelessWidget {
  final AppState state;
  final DateTime day, today;
  const _DayDetails({super.key, required this.state, required this.day, required this.today});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final info = calendarDay(state, day, today);
    final past = !day.isAfter(today);
    final log = state.logs[dayKey(day)];
    final tasks = tasksForDay(state.trackedTasks, day, today: today);
    final habits = state.trackedHabits.where((h) => h.isScheduledOn(day)).toList();
    final finances = financeAgenda(state.finance, day, hijriOffsetDays: state.settings.hijriOffsetDays);
    final wake = state.settings.tracksOn('wake', day), prayers = state.settings.tracksOn('prayers', day);
    Widget heading(String s) => Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 2),
      child: Text(s, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
    );
    final groups = <Goal?, List<Widget>>{};
    for (final h in habits) {
      (groups[state.goalFor(h.id)] ??= []).add(_habitRow(context, h, log, past));
    }
    for (final task in tasks) {
      (groups[state.goalFor(task.id)] ??= []).add(TaskTile(state: state, task: task, day: day, today: today));
    }
    for (final g in state.goals.where((g) => !g.archived)) {
      for (final m in g.milestones.where((m) => m.due == dayKey(day))) {
        (groups[g] ??= []).add(ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(m.done ? Icons.flag : Icons.outlined_flag),
          title: Text('Milestone: ${m.title}'),
        ));
      }
    }
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    DateFormat.yMMMMEEEEd().format(day),
                    style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                if (past)
                  TextButton.icon(
                    key: const Key('cal-edit-day'),
                    onPressed: () => showDayEditor(context, state, day),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Edit day'),
                  ),
              ],
            ),
            if (past && info.total > 0) Text('${info.done} of ${info.total} tracked items done', style: muted),
            if (!past)
              Text('Forecast · A missed session moves later portions and sessions back.', style: muted),
            for (final g in [...groups.keys.whereType<Goal>(), if (groups.containsKey(null)) null]) ...[
              heading(g?.title ?? (groups.length == 1 ? 'Schedule' : 'Other plans')),
              ...groups[g]!,
            ],
            if (finances.isNotEmpty) heading('Personal reminders'),
            for (final item in finances) ListTile(
              contentPadding: EdgeInsets.zero, leading: const Icon(Icons.event_note), title: Text(item.detail),
            ),
            if (groups.isEmpty && finances.isEmpty) Text(past ? 'No tasks or habits scheduled.' : 'Nothing planned yet.', style: muted),
            if (past && (wake || prayers)) ...[
              heading(wake && prayers ? 'Wake-up and prayers' : wake ? 'Wake-up' : 'Prayers'),
              Text(
                [
                  if (wake) log?.wakeAt == null ? 'Wake-up not logged' : 'Up at ${DateFormat.jm().format(log!.wakeAt!)}',
                  if (prayers) '${prayerNames.where((p) => log?.prayers.contains(p) ?? false).length} of ${prayerNames.length} prayers',
                ].join(' · '),
              ),
            ],
            if (!past)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('cal-add-task'),
                  onPressed: () => showTaskEditor(context, state, initialDate: day),
                  icon: const Icon(Icons.add),
                  label: const Text('Add a task on this day'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _habitRow(BuildContext context, HabitDef h, DayLog? log, bool past) {
    final done = habitDone(log?.habits[h.id], h);
    final q = state.quranFor(h, day, today: today);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(
        !past ? Icons.schedule : (done ? Icons.check_circle : Icons.radio_button_unchecked),
        size: 20,
        color: done ? Theme.of(context).colorScheme.primary : null,
      ),
      title: Text('${h.emoji} ${h.title}'),
      subtitle: done || (q == null && state.sessionForHabit(h, day, today: today) == null) ? null : Text(goalHabitSubtitle(state, h, day, today: today)),
      trailing: h.guide == null ? null : const Icon(Icons.chevron_right),
      onTap: h.guide == null ? null : () => Navigator.of(context).push(TaskGuideScreen.route(state, habitId: h.id, day: day, today: today)),
    );
  }
}

/// Opens the calendar.
class CalendarEntryCard extends StatelessWidget {
  final AppState state;
  const CalendarEntryCard({super.key, required this.state});

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      key: const Key('open-calendar'),
      leading: const Icon(Icons.calendar_month_outlined),
      title: const Text('Calendar'),
      subtitle: const Text('Every day at a glance: what you did and what is planned'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CalendarScreen(state: state))),
    ),
  );
}
