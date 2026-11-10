import 'package:flutter/material.dart';

import '../app_state.dart';
import '../logic/tasks.dart';
import '../models.dart';
import '../services/task_tools.dart';
import '../widgets/assistant_chat.dart';
import '../widgets/task_editor.dart';

class TasksScreen extends StatefulWidget {
  final AppState state;
  const TasksScreen({super.key, required this.state});

  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends State<TasksScreen> {
  late final _chat = AssistantChat(
    widget.state,
    systemPrompt: () => '$plannerSystemPrompt\n${plannerContext(widget.state.settings, DateTime.now())}',
  );

  @override
  void dispose() {
    _chat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      floatingActionButton: FloatingActionButton(
        tooltip: 'New task',
        onPressed: () => showTaskEditor(context, widget.state),
        child: const Icon(Icons.add),
      ),
      body: ListenableBuilder(
        listenable: widget.state,
        builder: (context, _) {
          final now = DateTime.now();
          final tasks = widget.state.tasks;
          final today = tasksForDay(tasks, now);
          final upcoming = upcomingTasks(tasks, now);
          final repeating = tasks.where((x) => x.isRepeating).toList()
            ..sort((a, b) => (a.time ?? '99').compareTo(b.time ?? '99'));
          final completed = tasks.where((x) => x.isOneOffDone && !today.contains(x)).toList()
            ..sort((a, b) => (b.doneDates.first).compareTo(a.doneDates.first));

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            children: [
              Text('Tasks', style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Row(children: [
                      Icon(Icons.auto_awesome, color: t.colorScheme.primary),
                      const SizedBox(width: 8),
                      Expanded(child: Text('Plan with AI', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
                      ListenableBuilder(
                        listenable: _chat,
                        builder: (_, _) => _chat.isEmpty
                            ? const SizedBox.shrink()
                            : IconButton(tooltip: 'Clear chat', icon: const Icon(Icons.delete_sweep_outlined), onPressed: _chat.clear),
                      ),
                    ]),
                    const SizedBox(height: 4),
                    Text(
                      'Tell the AI what you want to do and it creates the tasks and reminders for you.',
                      style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 12),
                    AssistantChatView(
                      chat: _chat,
                      hint: 'e.g. Read Quran 20 min after Fajr every day',
                      suggestions: const [
                        'Read Quran for 20 minutes after Fajr every day',
                        'Remind me to call my mother tomorrow at 8pm',
                        'Plan a 7-day articulation practice schedule',
                        'Gym Monday, Wednesday and Friday at 6pm',
                        'What do I have today?',
                      ],
                    ),
                  ]),
                ),
              ),
              _section(context, 'Today', today, now, empty: 'Nothing planned. Add a task or ask the AI.'),
              if (upcoming.isNotEmpty) _section(context, 'Upcoming', upcoming, now, useOwnDate: true),
              if (repeating.isNotEmpty) _section(context, 'Routines', repeating, now),
              if (completed.isNotEmpty) _section(context, 'Completed', completed.take(20).toList(), now),
            ],
          );
        },
      ),
    );
  }

  Widget _section(BuildContext context, String title, List<Task> tasks, DateTime now, {String? empty, bool useOwnDate = false}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$title${tasks.isEmpty ? '' : ' · ${tasks.length}'}',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          if (tasks.isEmpty && empty != null)
            Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(empty))
          else
            for (final x in tasks)
              TaskTile(
                state: widget.state,
                task: x,
                day: useOwnDate && x.date != null ? DateTime.parse(x.date!) : now,
              ),
        ]),
      ),
    );
  }
}
