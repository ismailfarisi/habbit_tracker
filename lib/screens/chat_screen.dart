import 'dart:async';
import 'dart:convert';

import 'package:ag_ui/ag_ui.dart' as agui;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../agent/agui_agent.dart';
import '../agent/goal_tools.dart';
import '../agent/habit_agent.dart';
import '../agent/habit_surface.dart';
import '../app_state.dart';
import '../goals/goal.dart';
import '../agent/coach_access.dart';
import 'settings_screen.dart';
import '../services/openrouter.dart';
import '../services/task_tools.dart';
import '../services/voice_input.dart';
import '../widgets/adaptive.dart';
import '../widgets/ai_key_empty_state.dart';
import '../widgets/simple_markdown.dart';
import '../widgets/voice_input_button.dart';
import '../services/coach_prompts.dart';
import '../agent/finance_tools.dart';

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
  bool actionable = true;
  List<ToolActivity> activities = const [];
  List<HabitProposal> proposals = const [];
  final Set<ToolActivity> undone = {};
  ChatItem(this.kind, this.id, this.text);
}

/// One saved conversation in the chat history.
class ChatThread {
  final String id;
  String title;
  DateTime updatedAt;
  List<Map<String, dynamic>> messages;

  /// Set for a goal's own conversation.
  final String? goalId;
  final String draft;
  final String? failure;
  final bool replyOnly;
  // Missing on old backups: keep the entire old transcript local.
  final int? providerStart;
  ChatThread(this.id, this.title, this.updatedAt, this.messages,
      {this.goalId, this.draft = '', this.failure, this.replyOnly = false, this.providerStart});

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'updatedAt': updatedAt.toIso8601String(),
    'messages': messages,
    if (draft.isNotEmpty) 'draft': draft,
    if (failure != null) 'failure': failure,
    if (replyOnly) 'replyOnly': true,
    'providerStart': providerStart,
    if (goalId != null) 'goalId': goalId,
  };

  factory ChatThread.fromJson(Map<String, dynamic> j) => ChatThread(
    j['id'] as String,
    j['title'] as String? ?? 'Chat',
    DateTime.tryParse(j['updatedAt'] as String? ?? '') ?? DateTime.now(),
    ((j['messages'] as List?) ?? const []).cast<Map>().map((m) => m.cast<String, dynamic>()).toList(),
    goalId: j['goalId'] as String?,
    draft: j['draft'] as String? ?? '',
    failure: j['failure'] as String?,
    replyOnly: j['replyOnly'] == true,
    providerStart: j['providerStart'] as int?,
  );
}

/// The Chat tab's conversation, driven by AG-UI events from [LocalAgUiAgent].
/// Every conversation is saved on the phone in [threads]; "New chat" starts
/// another and past ones can be reopened.
class AgUiChat extends ChangeNotifier {
  static const _legacyKey = 'chat.v1';
  static const _threadsKey = 'chat.threads.v1';
  static const _currentKey = 'chat.current.v1';
  static const _maxMessages = 80;
  static const _maxThreads = 50;

  /// Saved conversations, newest first.
  final threads = <ChatThread>[];
  final AppState state;
  final OpenRouterClient Function()? client;
  final history = <ChatMessage>[];
  final items = <ChatItem>[];
  bool busy = false;
  static int _serial = 0;
  static String _id() => 'thread-${DateTime.now().microsecondsSinceEpoch}-${_serial++}';
  String threadId = _id();
  String draft = '';
  String? failure;
  bool _replyOnly = false;
  int _providerStart = 0;
  bool _disposed = false;
  late CoachAccess access;
  final int _generation;

  bool get _active => !_disposed && _generation == state.dataGeneration;
  String get scopeTitle => goal?.title ?? (goalId == null ? 'General chat' : 'Archived goal chat');
  String get sharedLabel => [
    'This chat',
    ...access.goals.map((g) => g.title),
    if (access.planner) 'planner',
    if (access.money == CoachMoney.totals) 'Money totals',
    if (access.money == CoachMoney.details) 'Money details and names',
  ].join(' · ');

  /// The goal this conversation is about, if any; its context file is loaded.
  String? goalId;
  Goal? get goal => goalId == null ? null : state.goalById(goalId!);
  late final agent = LocalAgUiAgent(state, client: client);

  AgUiChat(this.state, {this.client}) : _generation = state.dataGeneration {
    access = CoachAccess(state);
    _load();
  }

  String get systemPrompt {
    final now = DateTime.now();
    return '$plannerSystemPrompt\n$goalsPrompt\n$financePrompt\nWhen the user asks for feedback on speech practice:\n$coachSystemPrompt\n'
        'Current local time: ${DateFormat('EEEE yyyy-MM-dd HH:mm').format(now)}.\n'
        '${access.planner ? plannerContext(state.settings, now) : ''}\n'
        '${goal == null ? '' : goalChatPrompt}\n${access.context(now)}';
  }

  void share({required CoachMoney money, required bool planner, required Set<String> otherGoals}) {
    if (!_active || busy) return;
    final ids = {...otherGoals, ?goalId};
    if (money == access.money && planner == access.planner &&
        ids.length == access.goalIds.length && ids.containsAll(access.goalIds)) {
      return;
    }
    _providerStart = history.length;
    access = CoachAccess(state, money: money, planner: planner, goals: ids);
    for (final it in items) {
      it.actionable = false;
    }
    _save();
    notifyListeners();
  }

  void setDraft(String text) {
    if (!_active || busy || text == draft) return;
    draft = text;
    _save();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _reset(String id, {String? goalId}) {
    history.clear();
    items.clear();
    threadId = id;
    this.goalId = goalId;
    access = CoachAccess(state, goals: [ ?goalId ]);
    _providerStart = 0;
    draft = '';
    failure = null;
    _replyOnly = false;
    state.storage.prefs.setString(_currentKey, id);
  }

  void newChat() {
    if (!_active || busy) return;
    _save();
    _reset(_id());
    notifyListeners();
  }

  /// Reopens a saved conversation.
  void open(String id) {
    if (!_active || busy || id == threadId) return;
    final th = threads.where((t) => t.id == id).firstOrNull;
    if (th == null) return;
    _save();
    _reset(id, goalId: th.goalId);
    _restoreThread(th);
    notifyListeners();
  }

  /// Opens [id]'s own conversation, starting one if it has none yet.
  void openGoal(String id) {
    if (!_active || busy || goalId == id) return;
    final th = threads.where((t) => t.goalId == id).firstOrNull;
    if (th != null) return open(th.id);
    _save();
    _reset(_id(), goalId: id);
    notifyListeners();
  }

  void deleteThread(String id) {
    if (!_active || busy) return;
    threads.removeWhere((t) => t.id == id);
    if (id == threadId) _reset(_id());
    _persist();
    notifyListeners();
  }

  void _persist() => state.storage.prefs.setString(_threadsKey, jsonEncode([for (final t in threads) t.toJson()]));

  /// Cross-screen actions always stage the whole outbound text for review.
  void stage(ChatRequest request) {
    if (!_active || busy) return;
    if (request.goalId == null) {
      newChat();
    } else {
      openGoal(request.goalId!);
    }
    if (request.text.isEmpty) return;
    if (draft.isNotEmpty && draft != request.text) {
      _save();
      _reset(_id(), goalId: request.goalId);
    }
    setDraft(request.text);
  }

  Future<void> send(String text, {String? display, ReviewChanges? review}) async {
    if (!_active || busy || text.trim().isEmpty) return;
    final key = state.apiKey;
    draft = text;
    if (key.trim().isEmpty) {
      failure = 'Add your OpenRouter API key in Settings to send this draft.';
      _save();
      notifyListeners();
      return;
    }
    final continuing = _replyOnly && failure != null;
    final runHistory = history.sublist(_providerStart);
    int copied = runHistory.length;
    void copyNewMessages() {
      history.addAll(runHistory.skip(copied));
      copied = runHistory.length;
    }
    // After any recorded tool work, Retry can only request a text reply.
    // The model cannot recreate a task even if it repeats a tool call.
    final lastUser = runHistory.where((m) => m.role == 'user').lastOrNull;
    if (!continuing || lastUser?.content != text.trim()) {
      final user = ChatMessage('user', text.trim());
      runHistory.add(user);
      items.add(ChatItem('user', 'u${items.length}', user.content));
    }
    busy = true;
    failure = null;
    final scope = access;
    void checkActive() {
      if (!_active || state.apiKey != key || !identical(scope, access)) {
        throw StateError('Chat access changed. Review the draft before sending again.');
      }
    }
    final spoken = StringBuffer();
    String? error;
    _save();
    notifyListeners();
    await for (final e in agent.run(
      threadId: threadId,
      history: runHistory,
      system: systemPrompt,
      access: scope,
      review: (calls) async {
        checkActive();
        final approved = await review?.call(calls) ?? false;
        checkActive();
        if (approved) {
          _replyOnly = true;
          _save();
        }
        return approved;
      },
      replyOnly: continuing,
      checkActive: checkActive,
    )) {
      if (!_active) return;
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
        error = e.message.replaceAll(key, '[key]');
      }
      if (e is agui.ToolCallResultEvent) {
        copyNewMessages();
        _save();
      }
      notifyListeners();
    }
    if (!_active) return;
    copyNewMessages();
    busy = false;
    for (final it in items) {
      it.running = false;
    }
    if (error == null) {
      draft = '';
      _replyOnly = false;
      if (state.settings.readCoachReplies && spoken.isNotEmpty) unawaited(speakAloud(spoken.toString()));
    } else {
      failure = error;
      // A failed request with no tool work remains an editable draft.
      if (!_replyOnly && history.isNotEmpty && history.last.role == 'user') {
        history.removeLast();
        if (items.isNotEmpty && items.last.kind == 'user') items.removeLast();
      }
    }
    _save();
    notifyListeners();
  }

  ChatItem? _item(String id) {
    for (var i = items.length - 1; i >= 0; i--) {
      if (items[i].id == id) return items[i];
    }
    return null;
  }

  Future<void> undo(ChatItem it, ToolActivity a) async {
    if (!_active || busy || !items.contains(it) || !it.actionable || a.undo == null ||
        !access.allows(ToolCall(it.id, it.toolName ?? '', it.args)) ||
        !it.activities.contains(a) || !it.undone.add(a)) {
      return;
    }
    try {
      await a.undo!();
    } catch (_) {
      it.undone.remove(a);
      rethrow;
    }
    if (!_active) return;
    _save();
    notifyListeners();
  }

  Future<void> accept(HabitProposal p) async {
    if (!_active || busy || p.accepted || !items.any((it) => it.actionable && it.proposals.contains(p))) return;
    p.accepted = true;
    try {
      await state.upsertHabit(p.habit);
    } catch (_) {
      p.accepted = false;
      rethrow;
    }
    if (!_active) return;
    _save();
    notifyListeners();
  }

  void _save() {
    if (!_active) return;
    if (history.isEmpty && draft.isEmpty && failure == null) {
      threads.removeWhere((t) => t.id == threadId);
      _persist();
      return;
    }
    var start = 0;
    if (history.length > _maxMessages) {
      start = history.length - _maxMessages;
      while (start < history.length && history[start].role != 'user') {
        start++;
      }
    }
    final toolItems = items.where((it) => it.kind == 'tool').toList();
    final saved = <ChatMessage, ChatItem>{};
    var index = 0;
    for (final m in history.where((m) => m.role == 'tool')) {
      if (index < toolItems.length) saved[m] = toolItems[index++];
    }
    final messages = [
      for (final m in history.sublist(start))
        <String, dynamic>{
          'role': m.role,
          'content': m.content,
          if (m.toolCalls.isNotEmpty)
            'calls': [
              for (final c in m.toolCalls) {'id': c.id, 'name': c.name, 'args': c.arguments},
            ],
          if (m.toolCallId != null) 'callId': m.toolCallId,
          if (saved[m] case final item?) 'outcomes': [
            for (final a in item.activities) {'label': a.label, 'undone': item.undone.contains(a)},
            for (final p in item.proposals) {'label': '${p.accepted ? 'Added' : 'Proposed'} habit “${p.habit.title}”'},
          ],
        },
    ];
    final first = history.where((m) => m.role == 'user').firstOrNull?.content.trim() ?? draft.trim();
    final title = first.length > 60 ? '${first.substring(0, 57)}…' : first;
    threads.removeWhere((t) => t.id == threadId);
    threads.insert(0, ChatThread(threadId, title.isEmpty ? 'Chat' : title, DateTime.now(), messages,
      goalId: goalId, draft: draft,
      failure: failure ?? (busy ? 'The reply was interrupted. Review the saved changes before retrying.' : null),
      replyOnly: _replyOnly,
      // Extra permissions expire on leaving/reopening a thread.
      providerStart: access.money != CoachMoney.none || access.planner || access.goalIds.any((id) => id != goalId)
          ? messages.length : (_providerStart - start).clamp(0, messages.length)));
    if (threads.length > _maxThreads) threads.removeRange(_maxThreads, threads.length);
    _persist();
    state.storage.prefs.setString(_currentKey, threadId);
  }

  void _restoreThread(ChatThread th) {
    draft = th.draft;
    failure = th.failure;
    _replyOnly = th.replyOnly;
    access = CoachAccess(state, goals: [ ?goalId ]);
    _restore(th.messages);
    _providerStart = (th.providerStart ?? history.length).clamp(0, history.length);
    // A process can stop between a tool call and its result. Keep incomplete
    // protocol messages on the device; a retry remains text-only.
    if (_replyOnly && history.isNotEmpty && history.last.role != 'tool') {
      _providerStart = history.length;
    }
  }

  void _restore(List<Map<String, dynamic>> messages) {
    try {
      for (final j in messages) {
        final calls = [
          for (final c in (j['calls'] as List? ?? const []).cast<Map>())
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
        if (m.role == 'tool') {
          final item = _item(m.toolCallId ?? '');
          if (item != null) {
            item.result = m.content;
            item.activities = [
              for (final outcome in (j['outcomes'] as List? ?? const []).whereType<Map>())
                ToolActivity('${outcome['label']}'),
            ];
            for (final (n, outcome) in (j['outcomes'] as List? ?? const []).whereType<Map>().indexed) {
              if (outcome['undone'] == true) item.undone.add(item.activities[n]);
            }
          }
        }
      }
    } catch (_) {
      history.clear();
      items.clear();
    }
  }

  void _load() {
    final prefs = state.storage.prefs;
    try {
      final raw = prefs.getString(_threadsKey);
      if (raw != null) {
        threads.addAll((jsonDecode(raw) as List).cast<Map>().map((m) => ChatThread.fromJson(m.cast<String, dynamic>())));
      } else if (prefs.getString(_legacyKey) case final legacy?) {
        final messages = (jsonDecode(legacy) as List).cast<Map>().map((m) => m.cast<String, dynamic>()).toList();
        if (messages.isNotEmpty) {
          threads.add(ChatThread(threadId, '${messages.first['content'] ?? 'Chat'}', DateTime.now(), messages));
          prefs.setString(_currentKey, threadId);
          _persist();
        }
        prefs.remove(_legacyKey);
      }
    } catch (_) {
      threads.clear();
    }
    final current = threads.where((t) => t.id == prefs.getString(_currentKey)).firstOrNull;
    if (current != null) {
      threadId = current.id;
      goalId = current.goalId;
      _restoreThread(current);
    }
  }
}

/// Past conversations: tap to reopen, or delete.
class ChatHistoryScreen extends StatelessWidget {
  final AgUiChat chat;
  const ChatHistoryScreen({super.key, required this.chat});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Chat history')),
      body: ListenableBuilder(
        listenable: chat,
        builder: (context, _) {
          if (chat.threads.isEmpty) {
            return Center(
              child: Text('No past chats yet.', style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            );
          }
          return ListView(
            children: [
              for (final th in chat.threads)
                ListTile(
                  key: ValueKey('thread-${th.id}'),
                  leading: Icon(th.id == chat.threadId ? Icons.chat_bubble : Icons.chat_bubble_outline),
                  title: Text(th.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    '${th.goalId == null ? '' : '${chat.state.goalById(th.goalId!)?.title ?? 'Goal'} · '}'
                    '${DateFormat.yMMMd().add_jm().format(th.updatedAt)} · ${th.messages.where((m) => m['role'] == 'user').length} messages',
                  ),
                  trailing: IconButton(
                    tooltip: 'Delete chat',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => chat.deleteThread(th.id),
                  ),
                  onTap: () {
                    chat.open(th.id);
                    Navigator.of(context).pop();
                  },
                ),
            ],
          );
        },
      ),
    );
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

  static const _goalSuggestions = [
    'What should I focus on today?',
    'Plan my next week',
    'How am I doing so far?',
  ];
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
    _input.text = _chat.draft;
    _input.addListener(_draftChanged);
    _chat.addListener(_onChat);
    widget.state.chatPrompt.addListener(_onPrompt);
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _onPrompt(); });
  }

  void _onPrompt() {
    final p = widget.state.chatPrompt.value;
    if (p == null || _chat.busy) return;
    widget.state.chatPrompt.value = null;
    _chat.stage(p);
  }

  @override
  void dispose() {
    _chat.removeListener(_onChat);
    _input.removeListener(_draftChanged);
    widget.state.chatPrompt.removeListener(_onPrompt);
    if (widget.chat == null) _chat.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _draftChanged() => _chat.setDraft(_input.text);

  void _onChat() {
    if (_input.text != _chat.draft) {
      _input.value = TextEditingValue(text: _chat.draft, selection: TextSelection.collapsed(offset: _chat.draft.length));
    }
    if (!_chat.busy && widget.state.chatPrompt.value != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _onPrompt(); });
    }
    if (_chat.busy) _toBottom();
  }

  void _toBottom() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
  });

  void _openHistory() => Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => ChatHistoryScreen(chat: _chat)),
  );

  void _send() {
    if (_chat.busy || _input.text.trim().isEmpty) return;
    FocusScope.of(context).unfocus();
    _chat.send(_input.text, review: _review);
  }

  Future<bool> _review(List<ToolCall> calls) async {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return false;
    return await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog.adaptive(
        title: Text(calls.length == 1 ? 'Review change' : 'Review ${calls.length} changes'),
        content: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final call in calls) ...[
              Text(call.name.replaceAll('_', ' '), style: Theme.of(context).textTheme.titleSmall),
              SelectableText(_describeChange(jsonDecode(call.arguments.isEmpty ? '{}' : call.arguments))),
              const SizedBox(height: 12),
            ],
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Apply changes')),
        ],
      ),
    ) ?? false;
  }

  String _describeChange(Object? value, [String indent = '']) {
    if (value is Map) {
      return value.entries.map((e) {
        final field = '${e.key}'.replaceAll('_', ' ');
        final v = e.value;
        if (v is Map || v is List) return '$indent$field\n${_describeChange(v, '$indent  ')}';
        if (field == 'id' && v is String) {
          return '$indent$field: ${widget.state.taskById(v)?.title ?? widget.state.habitById(v)?.title ?? widget.state.goalById(v)?.title ?? v}';
        }
        return '$indent$field: $v';
      }).join('\n');
    }
    if (value is List) return value.map((v) => _describeChange(v, indent)).join('\n');
    return '$indent$value';
  }

  Future<void> _context() async {
    final chat = _chat;
    final state = widget.state;
    var money = chat.access.money;
    var planner = chat.access.planner;
    final ids = {...chat.access.goalIds};
    await showModalBottomSheet<void>(
      context: context, isScrollControlled: true, useSafeArea: true,
      builder: (context) => StatefulBuilder(builder: (context, change) {
        final preview = CoachAccess(state, goals: ids, money: money, planner: planner);
        final changed = money != chat.access.money || planner != chat.access.planner ||
            ids.length != chat.access.goalIds.length || !ids.containsAll(chat.access.goalIds);
        final sharedHistory = chat.history.skip(changed ? chat.history.length : chat._providerStart).toList();
        return SafeArea(child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(16), children: [
          Text('Shared with OpenRouter', style: Theme.of(context).textTheme.titleLarge),
          const Text('Send shares your draft and the selected context. Changes to records need your approval.'),
          if (sharedHistory.isNotEmpty)
            ExpansionTile(title: Text('Conversation (${sharedHistory.length} messages)'), children: [
              for (final m in sharedHistory) ListTile(title: Text(m.role), subtitle: Text(
                [m.content, for (final c in m.toolCalls) '${c.name} ${c.arguments}'].where((s) => s.isNotEmpty).join('\n'))),
            ]),
          CheckboxListTile(value: planner, title: const Text('Planner and progress'),
            subtitle: const Text('Unlinked tasks and habits, notes, history, wake and prayer schedule, and check-in totals.'),
            onChanged: (v) => change(() => planner = v == true)),
          CheckboxListTile(value: money != CoachMoney.none, title: const Text('Redacted Money summary'),
            subtitle: const Text('Monthly income, spending, savings and sadaqah totals.'),
            onChanged: (v) => change(() => money = v == true ? CoachMoney.totals : CoachMoney.none)),
          if (money != CoachMoney.none)
            CheckboxListTile(value: money == CoachMoney.details, title: const Text('Include private Money details'),
              subtitle: const Text('Names of people, debts, savings pots, transaction notes and zakat inputs. Enables Money changes.'),
              onChanged: (v) => change(() => money = v == true ? CoachMoney.details : CoachMoney.totals)),
          for (final g in state.goals.where((g) => !g.archived || g.id == chat.goalId))
            CheckboxListTile(value: ids.contains(g.id), title: Text(g.title),
              subtitle: Text(g.id == chat.goalId ? 'Selected goal · plan, notes and progress' : 'Share plan, notes and progress'),
              onChanged: g.id == chat.goalId ? null : (v) => change(() { v == true ? ids.add(g.id) : ids.remove(g.id); })),
          if (planner || ids.isNotEmpty || money != CoachMoney.none)
            ExpansionTile(title: const Text('Preview selected context'), children: [
              if (planner) SelectableText(plannerContext(state.settings, DateTime.now())),
              if (ids.isNotEmpty || money != CoachMoney.none) SelectableText(preview.context(DateTime.now())),
            ]),
          FilledButton(onPressed: () {
            chat.share(money: money, planner: planner, otherGoals: ids);
            Navigator.pop(context);
          }, child: const Text('Done')),
        ]));
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return ListenableBuilder(
      listenable: Listenable.merge([state, _chat]),
      builder: (context, _) {
        final t = Theme.of(context);
        final offline = state.apiKey.trim().isEmpty;
        return Column(
          children: [
            Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Row(children: [
              Expanded(child: Text(_chat.scopeTitle, key: const Key('chat-title'), maxLines: 2,
                overflow: TextOverflow.ellipsis, style: t.textTheme.titleMedium)),
              IconButton(key: const Key('chat-history'), tooltip: 'History', icon: const Icon(Icons.history),
                onPressed: _chat.busy ? null : _openHistory),
              IconButton(key: const Key('new-chat'), tooltip: 'New chat', icon: const Icon(Icons.add_comment_outlined),
                onPressed: _chat.busy ? null : _chat.newChat),
            ])),
            Align(alignment: Alignment.centerLeft, child: TextButton.icon(
              key: const Key('chat-context'), onPressed: _chat.busy ? null : _context,
              icon: const Icon(Icons.tune, size: 18),
              label: Text('OpenRouter · ${_chat.sharedLabel}', maxLines: 2, overflow: TextOverflow.ellipsis),
            )),
            if (_chat.busy) const LinearProgressIndicator(minHeight: 2),
            Expanded(child: ListView(
              key: const Key('chat-list'), controller: _scroll,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              children: [
                if (_chat.items.isEmpty && offline) AiKeyEmptyState(state: state),
                if (_chat.items.isEmpty && !offline) ...[
                  Text(_chat.goal == null ? 'What should we set up?' : 'Ask about your plan', style: t.textTheme.titleLarge),
                  const SizedBox(height: 12),
                  Wrap(spacing: 8, runSpacing: 4, children: [
                    for (final s in _chat.goal == null ? _suggestions : _goalSuggestions)
                      ActionChip(label: Text(s), onPressed: () => _chat.setDraft(s)),
                  ]),
                ],
                for (final it in _chat.items) _ItemView(chat: _chat, item: it),
                if (_chat.failure case final error?)
                  ListTile(contentPadding: EdgeInsets.zero, title: Text(error), subtitle: Wrap(spacing: 8, children: [
                    TextButton(onPressed: offline || _chat.busy ? null : _send,
                      child: Text(_chat._replyOnly ? 'Retry reply' : 'Retry')),
                    TextButton(onPressed: () => openSettings(context, state, aiKeyOnly: true), child: const Text('Settings')),
                  ])),
                if (offline && _chat.items.isNotEmpty && _chat.failure == null)
                  TextButton(onPressed: () => openSettings(context, state, aiKeyOnly: true), child: const Text('Add AI key')),
              ],
            )),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('chat-input'),
                      controller: _input,
                      readOnly: _chat.busy,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        hintText: 'Message your coach',
                        border: const OutlineInputBorder(),
                        suffixIcon: _chat.busy ? null : VoiceInputButton(key: const Key('chat-tab-voice'), controller: _input),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    key: const Key('chat-send'),
                    tooltip: 'Send',
                    onPressed: _chat.busy || offline || _input.text.trim().isEmpty ? null : _send,
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
                if (a.undo != null && item.actionable)
                  TextButton(
                    style: compactButton,
                    onPressed: chat.busy || item.undone.contains(a) ? null : () => chat.undo(item, a),
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
                            onPressed: chat.busy || !item.actionable ? null : () => chat.accept(p),
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
