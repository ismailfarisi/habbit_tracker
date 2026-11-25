import 'package:flutter/material.dart';

import '../agent/habit_templates.dart';
import '../app_state.dart';

/// A returning user can have a plan or money records before their first log.
bool needsOnboarding(AppState state) =>
    !state.settings.onboarded &&
    state.logs.isEmpty &&
    state.tasks.isEmpty &&
    state.habits.isEmpty &&
    state.goals.isEmpty &&
    state.finance.isEmpty;

class OnboardingScreen extends StatefulWidget {
  final AppState state;
  const OnboardingScreen({super.key, required this.state});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  bool _saving = false;

  Future<void> _start([HabitTemplate? template]) async {
    if (_saving) return;
    setState(() => _saving = true);
    final state = widget.state;
    try {
      // Persist the domain choice first so creating the habit cannot schedule
      // unrelated wake or prayer alarms, even if notifications are allowed.
      await state.updateSettings((s) => s.todayHidden = ['wake', 'prayers']);
      if (template != null) {
        await state.upsertHabit(habitFromTemplate(template, target: 1));
      }
      await state.updateSettings((s) => s.onboarded = true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final choices = [
      (waterTemplate, Icons.water_drop_outlined, 'Drink one glass of water'),
      (quranTemplate, Icons.menu_book_outlined, 'Read one ayah'),
      (exerciseTemplate, Icons.directions_walk, 'Move for one minute'),
      (
        articulationTemplate,
        Icons.record_voice_over_outlined,
        'Read aloud for one minute',
      ),
    ];
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 40, 24, 24),
          children: [
            Text(
              'What would you like to work on?',
              style: theme.textTheme.headlineMedium,
            ),
            const SizedBox(height: 8),
            const Text(
              'Choose a small practice for today. You can change it later.',
            ),
            const SizedBox(height: 24),
            for (final (template, icon, description) in choices)
              ListTile(
                leading: Icon(icon),
                title: Text(template.title),
                subtitle: Text(description),
                trailing: const Icon(Icons.chevron_right),
                onTap: _saving ? null : () => _start(template),
              ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: _saving ? null : _start,
              child: const Text('Choose later'),
            ),
          ],
        ),
      ),
    );
  }
}
