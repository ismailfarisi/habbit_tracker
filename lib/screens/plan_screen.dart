import 'package:flutter/material.dart';

import '../finance/money_screen.dart';

import '../app_state.dart';
import '../habits/habit.dart';
import '../logic/stats.dart';
import '../models.dart';
import '../widgets/add_habit_sheet.dart';
import '../widgets/task_editor.dart';
import '../widgets/voice_input_button.dart';
import 'habit_detail_screen.dart';
import 'tasks_screen.dart';
import '../widgets/adaptive.dart';
import '../goals/goals_card.dart';
import 'calendar_screen.dart';
import 'home_screen.dart';

/// The Plan tab: the coach entry, the habit list (add from template, edit,
/// archive) and the task lists.
class PlanScreen extends StatefulWidget {
  final AppState state;
  const PlanScreen({super.key, required this.state});

  @override
  State<PlanScreen> createState() => _PlanScreenState();
}

class _PlanScreenState extends State<PlanScreen> {
  AppState get state => widget.state;

  void _openCoach() => state.requestedTab.value = HomeScreen.chatTab;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          FloatingActionButton.small(
            key: const Key('voice-task'),
            heroTag: 'voice-task',
            tooltip: 'Speak a task',
            onPressed: () => showTaskEditor(context, state, dictate: true),
            child: const Icon(Icons.mic),
          ),
          const SizedBox(width: 12),
          FloatingActionButton.extended(
            heroTag: 'new-task',
            tooltip: 'New task',
            onPressed: () => showTaskEditor(context, state),
            icon: const Icon(Icons.add),
            label: const Text('Task'),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          children: [
            _CoachCard(state: state, onOpen: _openCoach),
            GoalsCard(state: state),
            CalendarEntryCard(state: state),
            MoneyEntryCard(state: state),
            _HabitsCard(state: state),
            TaskSections(state: state),
          ],
        ),
      ),
    );
  }
}

class _CoachCard extends StatelessWidget {
  final AppState state;
  final VoidCallback onOpen;
  const _CoachCard({required this.state, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final on = state.apiKey.isNotEmpty;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: CircleAvatar(
          backgroundColor: t.colorScheme.primaryContainer,
          child: Icon(Icons.auto_awesome, color: t.colorScheme.onPrimaryContainer),
        ),
        title: Text('Coach', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
        subtitle: Text(
          on
              ? 'Chat with your coach: it plans goals, builds habits and adds tasks for you.'
              : 'Add an AI key to let the coach build habits and plan for you.',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: onOpen,
      ),
    );
  }
}

class _HabitsCard extends StatelessWidget {
  final AppState state;
  const _HabitsCard({required this.state});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final active = state.activeHabits.where((h) => state.goalFor(h.id) == null).toList();
    final archived = state.habits.where((h) => h.archived).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Habits${active.isEmpty ? '' : ' · ${active.length}'}',
                    style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => showAddHabitSheet(context, state),
                  icon: const Icon(Icons.add),
                  label: const Text('Add habit'),
                ),
              ],
            ),
            if (active.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('No habits yet. Add one from the templates or ask the coach.'),
              ),
            for (final h in active) _HabitTile(state: state, habit: h),
            if (archived.isNotEmpty)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text('Archived · ${archived.length}', style: t.textTheme.bodyMedium),
                children: [for (final h in archived) _HabitTile(state: state, habit: h)],
              ),
          ],
        ),
      ),
    );
  }
}

class _HabitTile extends StatelessWidget {
  final AppState state;
  final HabitDef habit;
  const _HabitTile({required this.state, required this.habit});

  Future<void> _delete(BuildContext context) async {
    final ok = await confirmDialog(
      context,
      title: 'Delete "${habit.title}"?',
      message: 'The habit is removed. Days you already logged stay in your history.',
      confirm: 'Delete',
      destructive: true,
    );
    if (ok) await state.deleteHabit(habit.id);
  }

  @override
  Widget build(BuildContext context) {
    final streak = habitStreak(state.logs, habit).current;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Text(habit.emoji, style: const TextStyle(fontSize: 26)),
      title: Text(habit.title),
      subtitle: Text([habit.describeSchedule(), if (!habit.archived && streak > 0) '🔥 $streak'].join(' · ')),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => HabitDetailScreen(state: state, habitId: habit.id),
        ),
      ),
      trailing: PopupMenuButton<String>(
        tooltip: 'Habit options',
        onSelected: (v) {
          switch (v) {
            case 'edit':
              showHabitEditor(context, state, habit);
            case 'archive':
              state.archiveHabit(habit.id);
            case 'restore':
              state.archiveHabit(habit.id, archived: false);
            case 'delete':
              _delete(context);
          }
        },
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'edit', child: Text('Edit')),
          if (habit.archived) ...[
            const PopupMenuItem(value: 'restore', child: Text('Restore')),
            const PopupMenuItem(value: 'delete', child: Text('Delete')),
          ] else
            const PopupMenuItem(value: 'archive', child: Text('Archive')),
        ],
      ),
    );
  }
}

/// Edits a habit's name, icon, target, schedule, reminder and streak rule.
Future<void> showHabitEditor(BuildContext context, AppState state, HabitDef habit) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: _HabitEditor(state: state, habit: habit),
    ),
  );
}

class _HabitEditor extends StatefulWidget {
  final AppState state;
  final HabitDef habit;
  const _HabitEditor({required this.state, required this.habit});

  @override
  State<_HabitEditor> createState() => _HabitEditorState();
}

class _HabitEditorState extends State<_HabitEditor> {
  late final _h = widget.habit.copy();
  late final _title = TextEditingController(text: _h.title);
  late final _emoji = TextEditingController(text: _h.emoji);
  late final _target = TextEditingController(text: _fmtNum(_h.target));
  late final _unit = TextEditingController(text: _h.unit);

  static String _fmtNum(num n) => n == n.roundToDouble() ? n.toInt().toString() : n.toString();

  bool get _hasTarget => _h.kind != HabitKind.check;

  @override
  void dispose() {
    for (final c in [_title, _emoji, _target, _unit]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickReminder() async {
    final t = await showTimePicker(
      context: context,
      initialTime: parseHm(_h.reminder ?? '', fallback: const TimeOfDay(hour: 8, minute: 0)),
    );
    if (t != null) setState(() => _h.reminder = fmtHm(t));
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) return;
    _h.title = title;
    if (_emoji.text.trim().isNotEmpty) _h.emoji = _emoji.text.trim();
    final target = num.tryParse(_target.text.trim());
    if (_hasTarget && target != null && target > 0) _h.target = target;
    if (_hasTarget) _h.unit = _unit.text.trim();
    if (_h.weekdays.length == 7) _h.weekdays = [];
    final nav = Navigator.of(context);
    await widget.state.upsertHabit(_h);
    nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final daily = _h.weekdays.isEmpty;
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          Text('Edit habit', style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Row(
            children: [
              SizedBox(
                width: 72,
                child: TextField(
                  controller: _emoji,
                  textAlign: TextAlign.center,
                  decoration: const InputDecoration(labelText: 'Icon', border: OutlineInputBorder()),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _title,
                  decoration: InputDecoration(
                    labelText: 'Name',
                    border: const OutlineInputBorder(),
                    suffixIcon: VoiceInputButton(key: const Key('habit-name-voice'), controller: _title),
                  ),
                ),
              ),
            ],
          ),
          if (_hasTarget) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _target,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Daily target', border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _unit,
                    decoration: const InputDecoration(labelText: 'Unit', border: OutlineInputBorder()),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          Text('Days', style: t.textTheme.titleSmall),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              FilterChip(
                label: const Text('Every day'),
                selected: daily,
                onSelected: (_) => setState(() => _h.weekdays = []),
              ),
              for (var d = 1; d <= 7; d++)
                FilterChip(
                  label: Text(weekdayShort[d - 1][0].toUpperCase() + weekdayShort[d - 1].substring(1)),
                  selected: !daily && _h.weekdays.contains(d),
                  onSelected: (on) => setState(() {
                    final days = daily ? <int>[] : List.of(_h.weekdays);
                    on ? days.add(d) : days.remove(d);
                    _h.weekdays = days..sort();
                  }),
                ),
            ],
          ),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.alarm),
            title: const Text('Reminder'),
            subtitle: Text(_h.reminder ?? 'None'),
            onTap: _pickReminder,
            trailing: _h.reminder == null
                ? null
                : IconButton(
                    tooltip: 'Remove reminder',
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() => _h.reminder = null),
                  ),
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Forgiving streak'),
            subtitle: const Text('One missed day keeps the streak; two in a row break it'),
            value: _h.streakRule == StreakRule.neverMissTwice,
            onChanged: (v) => setState(() => _h.streakRule = v ? StreakRule.neverMissTwice : StreakRule.strict),
          ),
          const SizedBox(height: 8),
          FilledButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
    );
  }
}
