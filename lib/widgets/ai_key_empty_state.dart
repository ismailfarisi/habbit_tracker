import 'package:flutter/material.dart';

import '../app_state.dart';
import '../screens/settings_screen.dart';
import 'add_habit_sheet.dart';

/// Shown instead of an AI surface when no OpenRouter key is set. Habit
/// templates keep working without a key.
class AiKeyEmptyState extends StatelessWidget {
  static const message = 'Add an AI key in Settings to let the coach build habits for you';

  final AppState state;

  /// Shows a "Browse templates" button next to "Add AI key".
  final bool showTemplates;
  const AiKeyEmptyState({super.key, required this.state, this.showTemplates = true});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_awesome_outlined, size: 40, color: t.colorScheme.primary),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center, style: t.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'The coach uses your own OpenRouter key. Until then you can add habits from the ready-made templates.',
            textAlign: TextAlign.center,
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: () => openSettings(context, state, aiKeyOnly: true),
                icon: const Icon(Icons.key),
                label: const Text('Add AI key'),
              ),
              if (showTemplates)
                OutlinedButton.icon(
                  onPressed: () => showAddHabitSheet(context, state),
                  icon: const Icon(Icons.add),
                  label: const Text('Browse templates'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
