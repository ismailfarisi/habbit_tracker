import 'package:flutter/material.dart';

import '../app_state.dart';
import '../habits/habit.dart';
import '../services/coach_prompts.dart';
import '../services/task_tools.dart';
import 'ai_key_empty_state.dart';
import 'assistant_chat.dart';

/// Opens the AI coach in a bottom sheet. With [request] (the context of an
/// `askCoach` action from a habit surface) the coach is asked for feedback
/// on that session straight away.
Future<void> showCoachSheet(
  BuildContext context,
  AppState state, {
  HabitDef? habit,
  Map<String, dynamic>? request,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: _CoachSheet(state: state, habit: habit, request: request),
    ),
  );
}

class _CoachSheet extends StatefulWidget {
  final AppState state;
  final HabitDef? habit;
  final Map<String, dynamic>? request;
  const _CoachSheet({required this.state, this.habit, this.request});

  @override
  State<_CoachSheet> createState() => _CoachSheetState();
}

class _CoachSheetState extends State<_CoachSheet> {
  late final _chat = AssistantChat(
    widget.state,
    systemPrompt: () => '$coachSystemPrompt\n$coachTaskPrompt\n${plannerContext(widget.state.settings, DateTime.now())}',
  );

  @override
  void initState() {
    super.initState();
    final r = widget.request;
    if (r != null && widget.state.apiKey.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _chat.send(sessionFeedbackPrompt(widget.habit?.title ?? 'my habit', r),
            display: '🎙️ Please review my practice');
      });
    }
  }

  @override
  void dispose() {
    _chat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.habit;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(h == null ? 'Coach' : 'Coach · ${h.title}',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        ListenableBuilder(
          listenable: widget.state,
          builder: (context, _) => widget.state.apiKey.isEmpty
              ? AiKeyEmptyState(state: widget.state)
              : AssistantChatView(
                  chat: _chat,
                  hint: 'Message your coach',
                  suggestions: const ['How am I doing?', 'Give me a harder drill', 'Build me a new habit'],
                ),
        ),
      ]),
    );
  }
}
