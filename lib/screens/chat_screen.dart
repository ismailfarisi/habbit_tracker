import 'dart:async';
import 'dart:convert';

import 'package:ag_ui/ag_ui.dart' as agui;
import 'package:flutter/material.dart';

import '../agent/agui_agent.dart';
import '../agent/goal_tools.dart';
import '../agent/habit_agent.dart';
import '../agent/habit_surface.dart';
import '../app_state.dart';
import '../services/openrouter.dart';
import '../services/task_tools.dart';
import '../services/voice_input.dart';
import '../widgets/adaptive.dart';
import '../widgets/ai_key_empty_state.dart';
import '../widgets/simple_markdown.dart';
import '../widgets/voice_input_button.dart';
import '../services/coach_prompts.dart';

const toolLabels = {
  'create_task': 'Creating a task',
  'update_task': 'Updating a task',
  'complete_task': 'Completing a task',
  'delete_task': 'Deleting a task',
  'list_tasks': 'Checking your tasks',
  'create_habit': 'Building a habit',
  'update_habit': 'Updating a habit',
  'set_habit_ui': 'Designing the habit screen',
  'log_habit': 'Logging a habit',
  'archive_habit': 'Archiving a habit',
  'list_habits': 'Checking your habits',
  'get_habit_history': 'Reading habit history',
  'log_prayer': 'Logging a prayer',
  'log_wake': 'Logging a wake-up',
  'set_wake_time': 'Changing the wake-up goal',
  'get_stats': 'Checking your progress',
  'create_goal': 'Planning your goal',
  'list_goals': 'Looking at your goals',
  'update_goal': 'Updating your goal',
  'save_goal_review': 'Saving the review',
};

/// One row in the chat: a user or assistant message, a tool call card or an error.
class ChatItem {
  final String kind; // user | assistant | tool | error
  final String id;
  String text;
  String? toolName;
  String args = '';
  String? result;
  bool running = false;
  List<ToolActivity> activities = const [];
  List<HabitProposal> proposals = const [];
  final Set<ToolActivity> undone = {};
  ChatItem(this.kind, this.id, this.text);
}

/// The Chat tab's conversation, driven by AG-UI events from [LocalAgUiAgent].
/// The model-facing history is saved on the phone.
class AgUiChat extends ChangeNotifier {
  static const _key = 'chat.v1';
  static const _maxMessages = 80;
  final AppState state;
  final OpenRouterClient Function()? client;
  final history = <ChatMessage>[];
  final items = <ChatItem>[];
  bool busy = false;
  String threadId = 'thread-${DateTime.now().millisecondsSinceEpoch}';
  late final agent = LocalAgUiAgent(state, client: client);

  AgUiChat(this.state, {this.client}) {
    _load();
  }

  String get systemPrompt {
    final now = DateTime.now();
    return '$plannerSystemPrompt\n$goalsPrompt\nWhen the user asks for feedback on speech practice:\n$coachSystemPrompt\n'
        '${plannerContext(state.settings, now)}\n${goalsContext(state, now)}';
  }

  void newChat() {
    history.clear();
    items.clear();
    threadId = 'thread-${DateTime.now().millisecondsSinceEpoch}';
    _save();
    notifyListeners();
  }

  Future<void> send(String text, {String? display}) async {
    if (busy || text.trim().isEmpty) return;
    items.add(ChatItem('user', 'u${items.length}', (display ?? text).trim()));
    if (state.apiKey.isEmpty) {
      items.add(ChatItem('error', 'e${items.length}', 'Add your OpenRouter API key in Settings to use the chat.'));
      notifyListeners();
      return;
    }
    final mark = history.length;
    history.add(ChatMessage('user', text.trim()));
    busy = true;
    notifyListeners();
    final spoken = StringBuffer();
    var failed = false;
    await for (final e in agent.run(threadId: threadId, history: history, system: systemPrompt)) {
      if (e is agui.TextMessageStartEvent) {
        items.add(ChatItem('assistant', e.messageId, ''));
      } else if (e is agui.TextMessageContentEvent) {
        _item(e.messageId)?.text += e.delta;
        spoken.write(e.delta);
      } else if (e is agui.ToolCallStartEvent) {
        items.add(ChatItem('tool', e.toolCallId, '')
          ..toolName = e.toolCallName
          ..running = true);
      } else if (e is agui.ToolCallArgsEvent) {
        _item(e.toolCallId)?.args += e.delta;
      } else if (e is agui.ToolCallResultEvent) {
        final it = _item(e.toolCallId);
        if (it != null) {
          it
            ..result = e.content
            ..running = false
            ..activities = agent.activities[e.toolCallId] ?? const []
            ..proposals = agent.proposals[e.toolCallId] ?? const [];
        }
      } else if (e is agui.RunErrorEvent) {
        failed = true;
        history.removeRange(mark, history.length);
        items.add(ChatItem('error', 'e${items.length}', e.message));
      }
      notifyListeners();
    }
    busy = false;
    for (final it in items) {
      it.running = false;
    }
    notifyListeners();
    if (!failed) {
      _save();
      if (state.settings.readCoachReplies && spoken.isNotEmpty) unawaited(speakAloud(spoken.toString()));
    }
  }

  ChatItem? _item(String id) {
    for (var i = items.length - 1; i >= 0; i--) {
      if (items[i].id == id) return items[i];
    }
    return null;
  }

  Future<void> undo(ChatItem it, ToolActivity a) async {
    if (a.undo == null || it.undone.contains(a)) return;
    await a.undo!();
    it.undone.add(a);
    notifyListeners();
  }

  Future<void> accept(HabitProposal p) async {
    if (p.accepted) return;
    await state.upsertHabit(p.habit);
    p.accepted = true;
    notifyListeners();
  }

  void _save() {
    var start = 0;
    if (history.length > _maxMessages) {
      start = history.length - _maxMessages;
      while (start < history.length && history[start].role != 'user') {
        start++;
      }
    }
    final keep = history.sublist(start);
    state.storage.prefs.setString(
      _key,
      jsonEncode([
        for (final m in keep)
          {
            'role': m.role,
            'content': m.content,
            if (m.toolCalls.isNotEmpty)
              'calls': [
                for (final c in m.toolCalls) {'id': c.id, 'name': c.name, 'args': c.arguments},
              ],
            if (m.toolCallId != null) 'callId': m.toolCallId,
          },
      ]),
    );
  }

  void _load() {
    final raw = state.storage.prefs.getString(_key);
    if (raw == null) return;
    try {
      for (final j in (jsonDecode(raw) as List).cast<Map<String, dynamic>>()) {
        final calls = [
          for (final c in (j['calls'] as List? ?? const []).cast<Map<String, dynamic>>())
            ToolCall(c['id'] as String, c['name'] as String, c['args'] as String? ?? ''),
        ];
        final m = ChatMessage(
          j['role'] as String,
          j['content'] as String? ?? '',
          toolCalls: calls,
          toolCallId: j['callId'] as String?,
        );
        history.add(m);
        if (m.role == 'user') items.add(ChatItem('user', 'u${items.length}', m.content));
        if (m.role == 'assistant' && m.content.isNotEmpty) items.add(ChatItem('assistant', 'a${items.length}', m.content));
        for (final c in calls) {
          items.add(ChatItem('tool', c.id, '')
            ..toolName = c.name
            ..args = c.arguments);
        }
        if (m.role == 'tool') _item(m.toolCallId ?? '')?.result = m.content;
      }
    } catch (_) {
      history.clear();
      items.clear();
    }
  }
}

/// The Chat tab: talk to the agent to create tasks, habits, reminders and
/// more. Tool calls appear as live cards with Undo; proposed habits show
/// their screen with an Add button.
class ChatScreen extends StatefulWidget {
  final AppState state;
  final AgUiChat? chat;
  const ChatScreen({super.key, required this.state, this.chat});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final AgUiChat _chat = widget.chat ?? AgUiChat(widget.state);
  final _input = TextEditingController();
  final _scroll = ScrollController();

  static const _suggestions = [
    'Help me memorise Juz Amma in 6 months',
    'Remind me to call my mother tomorrow at 8pm',
    'I mumble in meetings, build me a daily practice',
    'Drink 2L of water every day',
    'I prayed Fajr late yesterday',
    'How did my week go?',
  ];

  @override
  void initState() {
    super.initState();
    _chat.addListener(_toBottom);
    widget.state.chatPrompt.addListener(_onPrompt);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onPrompt());
  }

  void _onPrompt() {
    final p = widget.state.chatPrompt.value;
    if (p == null || _chat.busy) return;
    widget.state.chatPrompt.value = null;
    if (widget.state.apiKey.isNotEmpty) _chat.send(p.text, display: p.display);
  }

  @override
  void dispose() {
    _chat.removeListener(_toBottom);
    widget.state.chatPrompt.removeListener(_onPrompt);
    if (widget.chat == null) _chat.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _toBottom() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
  });

  void _send([String? text]) {
    final t = text ?? _input.text;
    if (t.trim().isEmpty) return;
    _input.clear();
    _chat.send(t);
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return ListenableBuilder(
      listenable: Listenable.merge([state, _chat]),
      builder: (context, _) {
        if (state.apiKey.isEmpty) {
          return Center(
            child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: AiKeyEmptyState(state: state)),
          );
        }
        final t = Theme.of(context);
        return Column(
          children: [
            if (_chat.busy) const LinearProgressIndicator(minHeight: 2) else const SizedBox(height: 2),
            Expanded(
              child: _chat.items.isEmpty
                  ? ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        Text('What should we set up?', style: t.textTheme.titleLarge),
                        const SizedBox(height: 4),
                        Text(
                          'Ask for a task, a habit with its own practice screen, a reminder, or a look at your progress.',
                          style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final s in _suggestions) ActionChip(label: Text(s), onPressed: () => _send(s)),
                          ],
                        ),
                      ],
                    )
                  : ListView.builder(
                      key: const Key('chat-list'),
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      itemCount: _chat.items.length + 1,
                      itemBuilder: (context, i) {
                        if (i == 0) {
                          return Align(
                            alignment: Alignment.centerRight,
                            child: TextButton.icon(
                              key: const Key('new-chat'),
                              onPressed: _chat.busy ? null : _chat.newChat,
                              icon: const Icon(Icons.add_comment_outlined, size: 18),
                              label: const Text('New chat'),
                            ),
                          );
                        }
                        return _ItemView(chat: _chat, item: _chat.items[i - 1]);
                      },
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('chat-input'),
                      controller: _input,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        hintText: 'Message your coach',
                        border: const OutlineInputBorder(),
                        suffixIcon: VoiceInputButton(key: const Key('chat-tab-voice'), controller: _input),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    key: const Key('chat-send'),
                    tooltip: 'Send',
                    onPressed: _chat.busy ? null : _send,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ItemView extends StatelessWidget {
  final AgUiChat chat;
  final ChatItem item;
  const _ItemView({required this.chat, required this.item});

  Widget _bubble(BuildContext context, {required bool user, required Color color, required Widget child, Key? key}) =>
      Align(
        key: key,
        alignment: user ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.82),
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(14)),
          child: child,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = t.colorScheme;
    switch (item.kind) {
      case 'user':
        return _bubble(
          context,
          user: true,
          color: c.primary,
          child: Text(item.text, style: TextStyle(color: c.onPrimary)),
        );
      case 'assistant':
        return _bubble(
          context,
          user: false,
          color: c.surfaceContainerHighest,
          child: item.text.isEmpty
              ? const SizedBox(width: 24, height: 16, child: LinearProgressIndicator())
              : SimpleMarkdown(item.text, style: TextStyle(color: c.onSurface)),
        );
      case 'error':
        return _bubble(
          context,
          user: false,
          color: c.errorContainer,
          child: Text(item.text, style: TextStyle(color: c.onErrorContainer)),
        );
    }
    final error = item.result == null ? null : LocalAgUiAgent.errorOf(item.result!);
    final label = toolLabels[item.toolName] ?? item.toolName ?? 'Working';
    final bold = TextStyle(color: c.onSurface, fontWeight: FontWeight.w600);
    return _bubble(
      context,
      key: ValueKey('tool-${item.id}'),
      user: false,
      color: c.surfaceContainerHighest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (item.activities.isEmpty)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox.square(
                  dimension: 18,
                  child: item.running
                      ? const CircularProgressIndicator.adaptive(strokeWidth: 2)
                      : Icon(
                          error != null ? Icons.error_outline : Icons.task_alt,
                          size: 18,
                          color: error != null ? c.error : c.primary,
                        ),
                ),
                const SizedBox(width: 6),
                Flexible(child: Text(item.running ? '$label…' : label, style: bold)),
              ],
            ),
          if (error != null) Text(error, style: t.textTheme.bodySmall?.copyWith(color: c.error)),
          for (final a in item.activities)
            Row(
              children: [
                Icon(item.undone.contains(a) ? Icons.undo : Icons.task_alt, size: 18, color: c.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    a.label,
                    style: bold.copyWith(decoration: item.undone.contains(a) ? TextDecoration.lineThrough : null),
                  ),
                ),
                if (a.undo != null)
                  TextButton(
                    style: compactButton,
                    onPressed: item.undone.contains(a) ? null : () => chat.undo(item, a),
                    child: Text(item.undone.contains(a) ? 'Undone' : 'Undo'),
                  ),
              ],
            ),
          for (final p in item.proposals)
            Card(
              margin: const EdgeInsets.only(top: 8),
              color: c.surface,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${p.habit.emoji}  ${p.habit.title}',
                      style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    Text(p.habit.describeSchedule(), style: t.textTheme.bodySmall?.copyWith(color: c.onSurfaceVariant)),
                    const Divider(),
                    if (!p.accepted) HabitSurface(chat.state, p.habit, DateTime.now(), persist: false),
                    const SizedBox(height: 8),
                    p.accepted
                        ? Row(
                            children: [
                              Icon(Icons.check_circle, color: c.primary, size: 20),
                              const SizedBox(width: 6),
                              const Expanded(child: Text('Added. You can find it on Today.')),
                            ],
                          )
                        : FilledButton.icon(
                            style: compactButton,
                            onPressed: () => chat.accept(p),
                            icon: const Icon(Icons.add),
                            label: const Text('Add habit'),
                          ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
