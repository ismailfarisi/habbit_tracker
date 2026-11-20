import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
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
  final int done, total, tasks;
  final List<Milestone> milestones;
  const CalendarDay(this.done, this.total, this.tasks, this.milestones);
  double get fraction => total == 0 ? 0 : done / total;
}

CalendarDay calendarDay(AppState s, DateTime day, DateTime today) {
  final d = dateOnly(day);
  final past = !d.isAfter(dateOnly(today));
  final log = s.logs[dayKey(d)];
  final tasks = tasksForDay(s.tasks, d, today: today);
  var done = 0, total = 0;
  if (past) {
    total += 1 + prayerNames.length;
    if (log?.wakeAt != null) done++;
    done += prayerNames.where((p) => log?.prayers.contains(p) ?? false).length;
    for (final h in s.habits.where((h) => !h.archived && h.isScheduledOn(d))) {
      total++;
      if (habitDone(log?.habits[h.id], h)) done++;
    }
    total += tasks.length;
    done += tasks.where((t) => t.isDoneOn(d)).length;
  }
  final key = dayKey(d);
  return CalendarDay(done, total, tasks.length, [
    for (final g in s.goals.where((g) => !g.archived))
      for (final m in g.milestones)
        if (m.due == key) m,
  ]);
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
  late DateTime _month = DateTime(_today.year, _today.month);
  late DateTime _selected = _today;

  void _shift(int months) => setState(() => _month = DateTime(_month.year, _month.month + months));

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
              _month = DateTime(_today.year, _today.month);
              _selected = _today;
            }),
            child: const Text('Today'),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final first = _month;
          final lead = (first.weekday - 1) % 7;
          final days = DateUtils.getDaysInMonth(first.year, first.month);
          const names = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
            children: [
              Row(
                children: [
                  IconButton(tooltip: 'Previous month', onPressed: () => _shift(-1), icon: const Icon(Icons.chevron_left)),
                  Expanded(
                    child: Text(
                      DateFormat.yMMMM().format(first),
                      textAlign: TextAlign.center,
                      style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(tooltip: 'Next month', onPressed: () => _shift(1), icon: const Icon(Icons.chevron_right)),
                ],
              ),
              Row(
                children: [
                  for (final n in names)
                    Expanded(
                      child: Center(child: Text(n, style: t.textTheme.labelSmall?.copyWith(color: c.onSurfaceVariant))),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              GridView.count(
                crossAxisCount: 7,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                childAspectRatio: 0.9,
                children: [
                  for (var i = 0; i < lead; i++) const SizedBox.shrink(),
                  for (var d = 1; d <= days; d++) _cell(context, DateTime(first.year, first.month, d)),
                ],
              ),
              const SizedBox(height: 12),
              _DayDetails(key: ValueKey(_selected), state: state, day: _selected, today: _today),
            ],
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
    final fill = info.total == 0 ? Colors.transparent : Color.lerp(c.surfaceContainerHighest, c.primary, info.fraction)!;
    final onFill = info.fraction > 0.55 ? c.onPrimary : c.onSurface;
    return Padding(
      padding: const EdgeInsets.all(2),
      child: InkWell(
        key: ValueKey('cal-${dayKey(d)}'),
        borderRadius: BorderRadius.circular(10),
        onTap: () => setState(() => _selected = d),
        child: Container(
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(10),
            border: selected
                ? Border.all(color: c.primary, width: 2)
                : isToday
                ? Border.all(color: c.outline)
                : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('${d.day}', style: TextStyle(color: onFill, fontWeight: isToday ? FontWeight.w700 : null)),
              const SizedBox(height: 2),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (info.tasks > 0)
                    Container(
                      width: 5,
                      height: 5,
                      margin: const EdgeInsets.symmetric(horizontal: 1),
                      decoration: BoxDecoration(color: info.fraction > 0.55 ? c.onPrimary : c.primary, shape: BoxShape.circle),
                    ),
                  if (info.milestones.isNotEmpty) Icon(Icons.flag, size: 10, color: c.tertiary),
                ],
              ),
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
    final tasks = tasksForDay(state.tasks, day, today: today);
    final habits = state.habits.where((h) => !h.archived && h.isScheduledOn(day)).toList();
    Widget heading(String s) => Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 2),
      child: Text(s, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
    );
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
            if (past && info.total > 0) Text('${info.done} of ${info.total} done', style: muted),
            for (final m in info.milestones)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    Icon(m.done ? Icons.flag : Icons.outlined_flag, size: 18, color: t.colorScheme.tertiary),
                    const SizedBox(width: 6),
                    Expanded(child: Text('Milestone: ${m.title}')),
                  ],
                ),
              ),
            if (past) ...[
              heading('Wake-up and prayers'),
              Text(
                [
                  log?.wakeAt == null ? 'Wake-up not logged' : 'Up at ${DateFormat.jm().format(log!.wakeAt!)}',
                  '${prayerNames.where((p) => log?.prayers.contains(p) ?? false).length} of ${prayerNames.length} prayers',
                ].join(' · '),
              ),
            ],
            if (habits.isNotEmpty) ...[
              heading('Habits'),
              for (final h in habits) _habitRow(context, h, log, past),
            ],
            heading('Tasks'),
            if (tasks.isEmpty) Text(past ? 'No tasks that day.' : 'Nothing planned yet.', style: muted),
            for (final x in tasks) TaskTile(state: state, task: x, day: day),
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
    final q = state.quranFor(h, day);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(
        !past ? Icons.schedule : (done ? Icons.check_circle : Icons.radio_button_unchecked),
        size: 20,
        color: done ? Theme.of(context).colorScheme.primary : null,
      ),
      title: Text('${h.emoji} ${h.title}'),
      subtitle: q == null || done ? null : Text(goalHabitSubtitle(state, h, day)),
      trailing: h.guide == null ? null : const Icon(Icons.chevron_right),
      onTap: h.guide == null ? null : () => Navigator.of(context).push(TaskGuideScreen.route(state, habitId: h.id, day: day)),
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
