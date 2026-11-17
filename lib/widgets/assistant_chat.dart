import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../agent/habit_agent.dart';
import '../agent/habit_surface.dart';
import '../app_state.dart';
import '../services/openrouter.dart';
import '../services/task_tools.dart';
import '../services/voice_input.dart';
import 'simple_markdown.dart';
import 'voice_input_button.dart';

class ChatEntry {
  final String role; // user | assistant
  String text;
  final bool error;
  final List<ToolActivity> activities = [];
  final Set<ToolActivity> undone = {};

  /// Habits the model proposed in this reply, previewed inline.
  final List<HabitProposal> proposals = [];
  ChatEntry(this.role, this.text, {this.error = false});
}

/// A conversation with the AI that can manage tasks and habits through tool
/// calls. A habit the model proposes is previewed inline as an A2UI surface
/// with an "Add habit" button ([acceptProposal]).
class AssistantChat extends ChangeNotifier {
  final AppState state;
  final String Function() systemPrompt;

  /// Raw conversation sent to the model (including tool calls/results).
  final history = <ChatMessage>[];

  /// What the user sees.
  final entries = <ChatEntry>[];
  bool busy = false;

  /// Overrides the OpenRouter client (tests).
  final OpenRouterClient Function()? client;

  AssistantChat(this.state, {required this.systemPrompt, this.client});

  bool get isEmpty => entries.isEmpty;

  void clear() {
    history.clear();
    entries.clear();
    notifyListeners();
  }

  /// Adds assistant text to the conversation without calling the model
  /// (e.g. a generated exercise the user may ask about).
  void addAssistantNote(String text) {
    history.add(ChatMessage('assistant', text));
    entries.add(ChatEntry('assistant', text));
    notifyListeners();
  }

  /// Sends [text] to the model. [display] replaces it in the chat UI
  /// (for long generated prompts).
  Future<void> send(String text, {String? display}) async {
    if (busy || text.trim().isEmpty) return;
    entries.add(ChatEntry('user', display ?? text));
    if (state.apiKey.isEmpty) {
      entries.add(ChatEntry('assistant', 'Add your OpenRouter API key in Settings to use the AI.', error: true));
      notifyListeners();
      return;
    }
    final mark = history.length;
    history.add(ChatMessage('user', text));
    final reply = ChatEntry('assistant', '');
    entries.add(reply);
    busy = true;
    notifyListeners();

    var afterTools = false;
    final agent = HabitAgent(
      state,
      client: client,
      onActivity: (a) {
        reply.activities.add(a);
        notifyListeners();
      },
      onProposal: (p) {
        reply.proposals.add(p);
        notifyListeners();
      },
    );
    try {
      await agent.run(
        history,
        system: systemPrompt(),
        onToolCall: () => afterTools = true,
        onText: (delta) {
          if (afterTools && reply.text.isNotEmpty) reply.text += '\n\n';
          afterTools = false;
          reply.text += delta;
          notifyListeners();
        },
      );
      final (text, surfaces) = splitInlineA2ui(reply.text);
      reply.text = text;
      for (final components in surfaces) {
        final result = await agent.habitTools.execute(
          ToolCall(
            'inline',
            'create_habit',
            jsonEncode({
              'title': 'New habit',
              'kind': 'check',
              'ui': {'components': components},
            }),
          ),
        );
        debugPrint('Inline A2UI surface: $result');
      }
      if (reply.text.isEmpty && reply.activities.isEmpty && reply.proposals.isEmpty) reply.text = '(no reply)';
      if (state.settings.readCoachReplies && reply.text.isNotEmpty && reply.text != '(no reply)') {
        unawaited(speakAloud(reply.text));
      }
    } catch (e) {
      // Drop the partial exchange so the next request is well-formed.
      history.removeRange(mark, history.length);
      if (reply.text.isEmpty && reply.activities.isEmpty && reply.proposals.isEmpty) entries.remove(reply);
      entries.add(ChatEntry('assistant', e.toString(), error: true));
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Saves a proposed habit (the "Add habit" button).
  Future<void> acceptProposal(HabitProposal p) async {
    if (p.accepted) return;
    await state.upsertHabit(p.habit);
    p.accepted = true;
    notifyListeners();
  }

  Future<void> undo(ChatEntry e, ToolActivity a) async {
    if (a.undo == null || e.undone.contains(a)) return;
    await a.undo!();
    e.undone.add(a);
    notifyListeners();
  }
}

/// Renders an [AssistantChat]: message bubbles, task activity with undo,
/// a typing indicator and the input row.
class AssistantChatView extends StatefulWidget {
  final AssistantChat chat;
  final String hint;
  final List<String> suggestions;
  final double maxHeight;
  const AssistantChatView({
    super.key,
    required this.chat,
    required this.hint,
    this.suggestions = const [],
    this.maxHeight = 420,
  });

  @override
  State<AssistantChatView> createState() => _AssistantChatViewState();
}

class _AssistantChatViewState extends State<AssistantChatView> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.chat.addListener(_scrollToEnd);
  }

  @override
  void dispose() {
    widget.chat.removeListener(_scrollToEnd);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  void _send([String? preset]) {
    final text = (preset ?? _input.text).trim();
    if (text.isEmpty || widget.chat.busy) return;
    _input.clear();
    widget.chat.send(text);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.chat,
      builder: (context, _) {
        final chat = widget.chat;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (chat.isEmpty && widget.suggestions.isNotEmpty)
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [for (final s in widget.suggestions) ActionChip(label: Text(s), onPressed: () => _send(s))],
              ),
            if (!chat.isEmpty)
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: widget.maxHeight),
                child: ListView(
                  controller: _scroll,
                  shrinkWrap: true,
                  children: [for (final e in chat.entries) _Bubble(entry: e, chat: chat)],
                ),
              ),
            if (chat.busy) const Padding(padding: EdgeInsets.only(top: 4), child: LinearProgressIndicator()),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    decoration: InputDecoration(
                      hintText: widget.hint,
                      border: const OutlineInputBorder(),
                      suffixIcon: VoiceInputButton(key: const Key('chat-voice'), controller: _input),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(onPressed: chat.busy ? null : _send, icon: const Icon(Icons.send)),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _Bubble extends StatelessWidget {
  final ChatEntry entry;
  final AssistantChat chat;
  const _Bubble({required this.entry, required this.chat});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final user = entry.role == 'user';
    final fg = entry.error ? c.onErrorContainer : (user ? c.onPrimary : c.onSurface);
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.82),
        decoration: BoxDecoration(
          color: entry.error ? c.errorContainer : (user ? c.primary : c.surfaceContainerHighest),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final a in entry.activities)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Icon(entry.undone.contains(a) ? Icons.undo : Icons.task_alt, size: 18, color: c.primary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        a.label,
                        style: TextStyle(
                          color: fg,
                          fontWeight: FontWeight.w600,
                          decoration: entry.undone.contains(a) ? TextDecoration.lineThrough : null,
                        ),
                      ),
                    ),
                    if (a.undo != null && !entry.undone.contains(a))
                      TextButton(
                        style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                        onPressed: () => chat.undo(entry, a),
                        child: const Text('Undo'),
                      ),
                  ],
                ),
              ),
            for (final p in entry.proposals) _ProposalCard(proposal: p, chat: chat),
            if (entry.text.isNotEmpty)
              SimpleMarkdown(entry.text, style: TextStyle(color: fg))
            else if (entry.activities.isEmpty && entry.proposals.isEmpty)
              const SizedBox(width: 24, height: 16, child: LinearProgressIndicator()),
          ],
        ),
      ),
    );
  }
}

/// Inline preview of a habit the model proposed: its A2UI surface (not
/// saved while previewing) and an "Add habit" button.
class _ProposalCard extends StatelessWidget {
  final HabitProposal proposal;
  final AssistantChat chat;
  const _ProposalCard({required this.proposal, required this.chat});

  @override
  Widget build(BuildContext context) {
    final h = proposal.habit;
    final t = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: t.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${h.emoji}  ${h.title}', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            Text(h.describeSchedule(), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            const Divider(),
            if (!proposal.accepted) HabitSurface(chat.state, h, DateTime.now(), persist: false),
            const SizedBox(height: 8),
            proposal.accepted
                ? Row(
                    children: [
                      Icon(Icons.check_circle, color: t.colorScheme.primary, size: 20),
                      const SizedBox(width: 6),
                      const Expanded(child: Text('Added. You can find it on Today.')),
                    ],
                  )
                : FilledButton.icon(
                    onPressed: () => chat.acceptProposal(proposal),
                    icon: const Icon(Icons.add),
                    label: const Text('Add habit'),
                  ),
          ],
        ),
      ),
    );
  }
}
