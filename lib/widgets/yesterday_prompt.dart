import 'package:flutter/material.dart';

import '../app_state.dart';
import '../logic/stats.dart';
import '../logic/tasks.dart';
import '../models.dart';
import 'cards/section_card.dart';
import 'day_editor.dart';

const promptUntilHour = 12;
const _dismissedKey = 'yesterdayPrompt.dismissed';

/// One unfinished item from yesterday and how to fix it in one tap.
class MissedItem {
  final String id;
  final String emoji;
  final String label;
  final String fixLabel;
  final Future<void> Function(BuildContext context) fix;
  const MissedItem({required this.id, required this.emoji, required this.label, required this.fixLabel, required this.fix});
}

/// What was scheduled the day before [now] and not done: wake (not logged),
/// prayers, habits and repeating tasks. Wake and prayers only count once
/// the app has a log from before today, so a fresh install isn't nagged.
List<MissedItem> missedYesterday(AppState state, DateTime now) {
  final day = DateTime(now.year, now.month, now.day - 1);
  final log = state.logFor(day);
  final usedBefore = state.logs.keys.any((k) => k.compareTo(dayKey(now)) < 0);
  return [
    if (usedBefore && log.wakeAt == null)
      MissedItem(
        id: 'wake',
        emoji: '☀️',
        label: 'Wake-up time',
        fixLabel: 'Set time',
        fix: (context) async {
          final picked = await showTimePicker(context: context, initialTime: state.settings.wakeTime);
          if (picked != null) await state.setWake(day, DateTime(day.year, day.month, day.day, picked.hour, picked.minute));
        },
      ),
    if (usedBefore)
      for (final p in prayerNames)
        if (!log.prayers.contains(p))
          MissedItem(
            id: 'prayer:$p',
            emoji: '🕌',
            label: p,
            fixLabel: 'Prayed',
            fix: (_) => state.setPrayerStatus(day, p, prayerOnTime),
          ),
    for (final h in state.activeHabits)
      if (h.isScheduledOn(day) && !habitDone(log.habits[h.id], h))
        MissedItem(
          id: 'habit:${h.id}',
          emoji: h.emoji,
          label: h.title,
          fixLabel: 'Done',
          fix: (_) => state.logHabit(day, h.id, state.habitEntry(day, h.id).copy()..done = true),
        ),
    for (final t in state.tasks)
      if (taskCountsOn(t, day) && !t.isDoneOn(day))
        MissedItem(
          id: 'task:${t.id}',
          emoji: '📝',
          label: t.title,
          fixLabel: 'Done',
          fix: (_) => state.setTaskDone(t, day, true),
        ),
  ];
}

/// "Did you pray Isha?" for one missed prayer, otherwise a general question.
String yesterdayQuestion(List<MissedItem> items) {
  if (items.length == 1 && items.single.id.startsWith('prayer:')) return 'Yesterday: did you pray ${items.single.label}?';
  if (items.length == 1) return 'Yesterday: did you do ${items.single.label}?';
  return 'Yesterday: ${items.length} things not logged';
}

/// The morning "Yesterday: did you pray Isha?" card on Today: lists what was
/// left unlogged yesterday with a one-tap fix each, plus "Review yesterday"
/// (the day editor) and "Dismiss" (hidden until tomorrow).
///
/// Shown before [promptUntilHour] when [missedYesterday] is not empty.
class YesterdayPrompt extends StatefulWidget {
  final AppState state;
  final DateTime now;
  const YesterdayPrompt({super.key, required this.state, required this.now});

  @override
  State<YesterdayPrompt> createState() => _YesterdayPromptState();
}

class _YesterdayPromptState extends State<YesterdayPrompt> {
  static const _shown = 5;
  bool _all = false;

  AppState get state => widget.state;

  bool get _dismissed => state.storage.prefs.getString(_dismissedKey) == dayKey(widget.now);

  Future<void> _dismiss() async {
    await state.storage.prefs.setString(_dismissedKey, dayKey(widget.now));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final now = widget.now;
    if (now.hour >= promptUntilHour || _dismissed) return const SizedBox.shrink();
    final items = missedYesterday(state, now);
    if (items.isEmpty) return const SizedBox.shrink();
    final yesterday = DateTime(now.year, now.month, now.day - 1);
    final shown = _all ? items : items.take(_shown).toList();
    return SectionCard(
      key: const ValueKey('yesterday-prompt'),
      title: '🌙  ${yesterdayQuestion(items)}',
      children: [
        for (final i in shown)
          ListTile(
            key: ValueKey('missed-${i.id}'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Text(i.emoji, style: const TextStyle(fontSize: 20)),
            title: Text(i.label),
            trailing: FilledButton.tonal(onPressed: () => i.fix(context), child: Text(i.fixLabel)),
          ),
        if (!_all && items.length > _shown)
          TextButton(onPressed: () => setState(() => _all = true), child: Text('Show ${items.length - _shown} more')),
        const SizedBox(height: 4),
        Wrap(spacing: 8, children: [
          OutlinedButton.icon(
            onPressed: () => showDayEditor(context, state, yesterday),
            icon: const Icon(Icons.edit_calendar_outlined),
            label: const Text('Review yesterday'),
          ),
          TextButton(onPressed: _dismiss, child: const Text('Dismiss')),
        ]),
      ],
    );
  }
}
