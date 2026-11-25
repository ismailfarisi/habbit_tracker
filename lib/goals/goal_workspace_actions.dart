import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../finance/finance.dart';
import '../logic/stats.dart';
import '../widgets/ask_chat.dart';
import '../widgets/adaptive.dart';
import 'goal.dart';

Future<void> chooseGoalArchive(BuildContext context, AppState state, Goal goal) async {
  final pause = await showModalBottomSheet<bool>(
    context: context,
    builder: (c) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(title: Text('Archive ${goal.title}?', style: Theme.of(c).textTheme.titleMedium)),
          ListTile(
            leading: const Icon(Icons.pause_circle_outline),
            title: const Text('Pause goal and its reminders'),
            subtitle: const Text('Hide its work from your schedule until you restore the goal.'),
            onTap: () => Navigator.pop(c, true),
          ),
          ListTile(
            leading: const Icon(Icons.event_repeat),
            title: const Text('Keep these as standalone'),
            subtitle: const Text(
              'Keep linked habits, tasks and reminders active. Restore the goal to group them again.',
            ),
            onTap: () => Navigator.pop(c, false),
          ),
        ],
      ),
    ),
  );
  if (pause == null || !context.mounted) return;
  await state.setGoalArchived(goal, archived: true, pauseWork: pause);
  if (context.mounted) Navigator.maybePop(context);
}

enum _LinkKind {
  habit('Habit'),
  task('Task'),
  pot('Savings pot');

  final String label;
  const _LinkKind(this.label);
}

Future<void> attachGoalWork(BuildContext context, AppState state, Goal goal) async {
  bool linked(String id) => state.goals.any((g) => g.owns(id));
  final items = <(String, String, _LinkKind)>[
    for (final h in state.activeHabits.where((h) => !linked(h.id))) (h.id, h.title, _LinkKind.habit),
    for (final t in state.tasks.where((t) => !linked(t.id))) (t.id, t.title, _LinkKind.task),
    for (final ledger in state.finance.ledgers)
      for (final p in ledger.pots.where((p) => p.goalId == null && !p.archived))
        ('${ledger.currency}:${p.id}', '${p.name} · ${ledger.currency}', _LinkKind.pot),
  ];
  final picked = await showModalBottomSheet<(String, String, _LinkKind)>(
    context: context,
    builder: (c) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          ListTile(title: Text('Attach existing work', style: Theme.of(c).textTheme.titleMedium)),
          if (items.isEmpty) const ListTile(title: Text('No unlinked habits, tasks or savings pots.')),
          for (final e in items)
            ListTile(title: Text(e.$2), subtitle: Text(e.$3.label), onTap: () => Navigator.pop(c, e)),
        ],
      ),
    ),
  );
  if (picked == null) return;
  final current = state.goalById(goal.id);
  if (current == null || current.archived) return;
  if (picked.$3 == _LinkKind.pot) {
    final currency = picked.$1.split(':').first;
    final pot = state.finance.ledgers.where((l) => l.currency == currency).firstOrNull?.pot(picked.$1.substring(currency.length + 1));
    if (pot == null || pot.goalId != null || pot.archived) return;
    await state.upsertPot(SavingsPot.fromJson(pot.toJson())..goalId = current.id, currency: currency);
    return;
  }
  if (linked(picked.$1)) return;
  final next = current.copy();
  (picked.$3 == _LinkKind.habit ? next.habitIds : next.taskIds).add(picked.$1);
  await state.upsertGoal(next, expected: current);
}

class GoalNotes extends StatelessWidget {
  final AppState state;
  final Goal goal;
  final VoidCallback preview;
  const GoalNotes({super.key, required this.state, required this.goal, required this.preview});

  Future<void> edit(BuildContext context, [GoalNote? note]) async {
    var text = note?.text ?? '';
    var shared = note?.shared ?? false;
    final entry = await showDialog<GoalNote>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          scrollable: true,
          title: Text(note == null ? 'Add note' : 'Edit note'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                initialValue: text,
                decoration: const InputDecoration(labelText: 'Note'),
                minLines: 2,
                maxLines: null,
                onChanged: (s) => update(() => text = s),
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Include in goal chat and export'),
                value: shared,
                onChanged: (v) => update(() => shared = v),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            FilledButton(
              onPressed: text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(c, GoalNote(text.trim(), shared: shared, changedOn: dayKey(DateTime.now()))),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (entry == null || state.goalById(goal.id) != goal) return;
    final next = goal.copy();
    if (note == null) {
      next.noteEntries.add(entry);
    } else {
      next.noteEntries[goal.noteEntries.indexOf(note)] = entry;
    }
    await state.upsertGoal(next);
  }

  Future<void> remove(BuildContext context, GoalNote n) async {
    if (!await confirmDialog(
      context,
      title: 'Remove this note?',
      message: n.text,
      confirm: 'Remove',
      destructive: true,
    )) {
      return;
    }
    if (state.goalById(goal.id) != goal) return;
    final next = goal.copy();
    next.noteEntries.removeAt(goal.noteEntries.indexOf(n));
    await state.upsertGoal(next);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final n in goal.noteEntries)
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(n.text),
          subtitle: Text(
            [
              n.shared ? 'Shared with goal chat' : 'Private',
              if (n.changedOn != null) 'Updated ${n.changedOn}',
            ].join(' · '),
          ),
          onTap: () => edit(context, n),
          trailing: IconButton(
            tooltip: 'Remove note',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => remove(context, n),
          ),
        ),
      Wrap(
        children: [
          TextButton.icon(onPressed: () => edit(context), icon: const Icon(Icons.add), label: const Text('Add note')),
          TextButton(onPressed: preview, child: const Text('Preview shared context')),
        ],
      ),
    ],
  );
}

class GoalSuggestion extends StatefulWidget {
  final AppState state;
  final Goal goal;
  final GoalReview review;
  final int index;
  const GoalSuggestion({super.key, required this.state, required this.goal, required this.review, required this.index});
  @override
  State<GoalSuggestion> createState() => _GoalSuggestionState();
}

class _GoalSuggestionState extends State<GoalSuggestion> {
  bool busy = false;
  String? error;

  Future<void> change({required bool undo}) async {
    final g = widget.goal, r = widget.review, index = widget.index;
    var title = r.suggestions[index];
    DateTime? due;
    if (!undo) {
      final action = await showDialog<String>(
        context: context,
        builder: (c) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
            scrollable: true,
            title: const Text('Preview change'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Add a milestone to ${g.title}. Edit the action before applying it.'),
                const SizedBox(height: 12),
                TextFormField(
                  initialValue: title,
                  maxLines: null,
                  decoration: const InputDecoration(labelText: 'Milestone'),
                  onChanged: (s) => update(() => title = s),
                ),
                TextButton(
                  onPressed: () async {
                    final now = DateTime.now();
                    final picked = await showDatePicker(
                      context: c,
                      firstDate: now,
                      lastDate: DateTime(now.year + 50),
                      initialDate: due ?? now,
                    );
                    if (picked != null && c.mounted) update(() => due = picked);
                  },
                  child: Text(due == null ? 'Add due date' : DateFormat.yMMMd().format(due!)),
                ),
                TextButton(onPressed: () => Navigator.pop(c, 'chat'), child: const Text('Discuss in goal chat')),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
              FilledButton(
                onPressed: title.trim().isEmpty ? null : () => Navigator.pop(c, 'apply'),
                child: const Text('Apply'),
              ),
            ],
          ),
        ),
      );
      if (action == null || !mounted) return;
      if (action == 'chat') {
        askChat(widget.state, 'Help me adjust this plan: ${r.suggestions[index]}', context: context, goalId: g.id);
        return;
      }
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (undo) {
        await widget.state.undoGoalSuggestion(g, r, index);
      } else {
        await widget.state.applyGoalSuggestion(g, r, index, title: title, due: due == null ? null : dayKey(due!));
      }
    } catch (_) {
      if (mounted) setState(() => error = 'Could not save the change.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.review, i = widget.index;
    final linked = widget.goal.milestones.where((m) => m.id == r.milestoneLinks[i]).firstOrNull;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(r.suggestions[i]),
      onTap: linked == null
          ? null
          : () async {
              final toggle = await confirmDialog(
                context,
                title: linked.title,
                message: [
                  widget.goal.title,
                  if (linked.due != null) 'Due ${linked.due}',
                  linked.done ? 'Completed' : 'Open',
                ].join(' · '),
                confirm: linked.done ? 'Mark incomplete' : 'Mark complete',
              );
              if (!toggle || !mounted) return;
              final current = widget.state.goalById(widget.goal.id);
              final milestone = current?.milestones.where((m) => m.id == linked.id).firstOrNull;
              if (milestone != null) {
                milestone.done = !linked.done;
                await widget.state.saveGoals();
              }
            },
      subtitle: error != null
          ? Text(error!)
          : linked != null
          ? Text('Applied · ${linked.title}')
          : r.applied.contains(i)
          ? const Text('Previously requested · no saved milestone')
          : null,
      trailing: TextButton(
        style: compactButton,
        onPressed: busy ? null : () => change(undo: linked != null),
        child: Text(
          error != null
              ? 'Retry'
              : linked != null
              ? 'Undo'
              : 'Preview',
        ),
      ),
    );
  }
}
