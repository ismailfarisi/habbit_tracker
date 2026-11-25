import 'package:flutter/material.dart';

import '../agent/habit_templates.dart';
import '../app_state.dart';
import 'ask_chat.dart';

/// Lets the user add a habit from the offline templates (no AI key needed)
/// or ask the coach to build one.
Future<void> showAddHabitSheet(BuildContext context, AppState state) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          Text('Add a habit', style: Theme.of(sheet).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          for (final t in [...habitTemplates, ...moneyHabitTemplates])
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Text(t.emoji, style: const TextStyle(fontSize: 28)),
              title: Text(t.title),
              subtitle: Text(t.description),
              trailing: const Icon(Icons.add),
              onTap: () async {
                Navigator.of(sheet).pop();
                await state.upsertHabit(habitFromTemplate(t));
              },
            ),
          const Divider(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.auto_awesome, size: 28),
            title: const Text('Build one with the AI coach'),
            subtitle: Text(state.apiKey.isEmpty
                ? 'Add your OpenRouter API key in Settings to use this.'
                : 'Describe what you need, e.g. "I mumble in meetings".'),
            onTap: () {
              Navigator.of(sheet).pop();
              askChat(state, 'Help me build a new habit', context: context);
            },
          ),
        ],
      ),
    ),
  );
}
