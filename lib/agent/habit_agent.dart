/// The habit coach: lets the model build and manage habits through tools.
///
/// * [habitAgentPrompt] — system-prompt part: coach instructions plus the
///   `A2uiGenerator` prompt snippet that teaches the model our catalogs.
/// * [habitToolDefinitions] / [HabitTools] — `create_habit`, `update_habit`,
///   `archive_habit`, `log_habit`, `list_habits`, `get_habit_history`,
///   `set_habit_ui`. Any UI payload is run through `normalizeHabitSurface`
///   (a2ui_agent `validatePayload`) and rejected with an error the model can
///   act on when invalid; nothing invalid is ever stored.
/// * [HabitAgent] — runs a conversation turn over the existing OpenRouter
///   client with the habit tools and the existing task tools.
///
/// `create_habit` yields a [HabitProposal] when [HabitTools.onProposal] is
/// set (the chat shows an inline A2UI preview with an "Add habit" button);
/// without a handler the habit is created straight away.
library;

import 'dart:convert';

import 'package:a2ui_agent/a2ui_agent.dart';
import 'package:a2ui_core/a2ui_core.dart';

import '../app_state.dart';
import '../habits/habit.dart';
import '../logic/stats.dart';
import '../logic/tasks.dart';
import '../models.dart';
import '../services/openrouter.dart';
import '../services/task_tools.dart';
import 'habit_catalog.dart';
import 'habit_templates.dart';
import 'app_tools.dart';
import 'goal_tools.dart';
import 'finance_tools.dart';
import 'coach_access.dart';

const habitToolNames = {
  'create_habit',
  'update_habit',
  'archive_habit',
  'log_habit',
  'list_habits',
  'get_habit_history',
  'set_habit_ui',
};

const _coachInstructions = '''
You are also the user's habit coach. The user tells you what they need ("I
mumble in meetings", "read Quran after Fajr", "drink 2L of water") and you
build a habit for it with its own small logging / practice screen.

Habit tools: create_habit, update_habit, set_habit_ui, archive_habit,
log_habit, list_habits, get_habit_history.

Rules for habits:
- Something recurring that the user wants to build or track is a HABIT
  (create_habit). A one-off or a plain reminder is a TASK (create_task).
- Wake-up and the five daily prayers are built in. Never create habits for them.
- Pick kind: "check" (did it or not), "count" (glasses, pages; set target and
  unit), "duration" (minutes; target = minutes), "practice" (timed practice
  with drills; target = minutes), "metric" (record a number).
- Design the habit's screen in the "ui" argument as {"components": [...]}: a
  flat A2UI v1.0 component list with one component whose id is "root". Do NOT
  write A2UI in your reply text and do not wrap it in tags; it only goes in
  the tool argument. Keep it small: 2 to 6 components.
- For speaking, reading or pronunciation habits use ReadAloudDrill with a text
  you write for the user's exact problem, plus PracticeTimer and MetricTrend
  for "wpm" and "fillers", and list those in metric_fields.
- If a tool returns an error about the UI, fix the components and call it again.
- create_habit shows the user a preview with an "Add habit" button; tell them
  to tap it. Call list_habits before changing, logging or archiving a habit.
- Use get_habit_history before giving feedback on progress.
''';

A2uiRequestProcessor? _processor;

/// Basic-catalog components the model is taught (to keep the prompt small).
/// Stored surfaces are still validated against the full catalogs.
const promptBasicComponents = ['Column', 'Row', 'Card', 'Text', 'Divider', 'Button', 'TextField'];

A2uiRequestProcessor _agentProcessor() => _processor ??= A2uiGenerator(
      catalogs: [
        CatalogConfig(
          habitCatalogs().first,
          transformers: [ComponentPruningTransformer(promptBasicComponents), FunctionPruningTransformer()],
        ),
        CatalogConfig(habitCatalog()),
      ],
      inferenceFormatFactory: const DirectJsonFormatFactory(allowedMessages: ['createSurface']),
    ).createProcessor(
      A2uiRendererCapabilities.forCatalogIds(
        [basicCatalogId, habitCatalogId],
        version: A2uiProtocolVersion.v1_0,
      ),
    );

/// What `a2ui_agent` generates to teach the model A2UI v1.0 and both
/// catalogs (components, properties, data binding).
String a2uiPromptSnippet() => _agentProcessor().promptSnippet;

/// The habit part of the system prompt, including the user's current habits.
String habitAgentPrompt() {
  return '$_coachInstructions\n'
      'Reference for the "ui" argument (A2UI format and component catalogs):\n${a2uiPromptSnippet()}\n'
      'Reminder: in this app the component list goes in the "ui" tool argument as {"components": [...]}. '
      'Do not put <a2ui-json> blocks in your reply.';
}

/// Splits model text into plain text and any A2UI surfaces it wrote inline
/// (despite the instructions), using a2ui_agent's `parseResponse`. Returns
/// the text without the blocks and each surface's component list.
(String text, List<List<Map<String, Object?>>> surfaces) splitInlineA2ui(String reply) {
  if (!reply.contains('<a2ui')) return (reply, const []);
  try {
    final text = StringBuffer();
    final surfaces = <List<Map<String, Object?>>>[];
    for (final part in _agentProcessor().parseResponse(reply)) {
      switch (part) {
        case TextPart(text: final t):
          text.write(t);
        case A2uiPart(:final a2ui):
          for (final m in a2ui) {
            if (m is CreateSurfaceMessage && m.components != null) surfaces.add(m.components!);
            if (m is UpdateComponentsMessage) surfaces.add(m.components);
          }
      }
    }
    return (text.toString().trim(), surfaces);
  } catch (_) {
    return (reply.replaceAll(RegExp(r'<a2ui[^>]*>[\s\S]*?(</a2ui[^>]*>|$)'), '').trim(), const []);
  }
}

const _habitProps = {
  'title': {'type': 'string', 'description': 'Short habit title, e.g. "Speak clearly"'},
  'emoji': {'type': 'string', 'description': 'One emoji for the habit'},
  'kind': {
    'type': 'string',
    'enum': ['check', 'count', 'duration', 'metric', 'practice'],
  },
  'target': {'type': 'number', 'description': 'Daily goal: a count (kind count) or minutes (duration, practice)'},
  'unit': {'type': 'string', 'description': 'Unit of the count, e.g. "glasses", "pages"'},
  'weekdays': {
    'type': 'array',
    'items': {'type': 'string', 'enum': weekdayShort},
    'description': 'Days it is scheduled. Omit or leave empty for every day.',
  },
  'reminder': {'type': 'string', 'description': '24h HH:MM reminder time. Omit for no reminder.'},
  'streak_rule': {
    'type': 'string',
    'enum': ['strict', 'neverMissTwice'],
    'description': 'neverMissTwice (default) forgives a single missed day.',
  },
  'metric_fields': {
    'type': 'array',
    'description': 'Numbers this habit records under /metrics/<key>, charted in Progress.',
    'items': {
      'type': 'object',
      'properties': {
        'key': {'type': 'string'},
        'label': {'type': 'string'},
        'unit': {'type': 'string'},
        'better': {'type': 'string', 'enum': ['up', 'down']},
      },
      'required': ['key', 'label'],
    },
  },
  'ui': {
    'type': 'object',
    'description': 'The habit screen: {"components": [...]} in A2UI v1.0, one component with id "root".',
    'properties': {
      'components': {'type': 'array', 'items': {'type': 'object'}},
    },
    'required': ['components'],
  },
};

Map<String, dynamic> _fn(String name, String description, Map<String, dynamic> props, List<String> required) => {
      'type': 'function',
      'function': {
        'name': name,
        'description': description,
        'parameters': {'type': 'object', 'properties': props, 'required': required},
      },
    };

final habitToolDefinitions = <Map<String, dynamic>>[
  _fn('create_habit', 'Propose a new habit with its own logging / practice UI. The user confirms it.', _habitProps,
      ['title', 'kind']),
  _fn('update_habit', 'Change an existing habit. Only pass fields that should change.', {
    'id': {'type': 'string'},
    ..._habitProps,
  }, ['id']),
  _fn('set_habit_ui', 'Replace the logging / practice UI of an existing habit.', {
    'id': {'type': 'string'},
    'ui': _habitProps['ui'],
  }, ['id', 'ui']),
  _fn('archive_habit', 'Archive a habit (hide it, keep its history), or restore it.', {
    'id': {'type': 'string'},
    'archived': {'type': 'boolean', 'description': 'Default true. false restores the habit.'},
  }, ['id']),
  _fn('log_habit', 'Record progress on a habit for a day.', {
    'id': {'type': 'string'},
    'date': {'type': 'string', 'description': 'YYYY-MM-DD, defaults to today'},
    'done': {'type': 'boolean'},
    'value': {'type': 'number', 'description': 'Set the count'},
    'add_value': {'type': 'number', 'description': 'Add to the count'},
    'minutes': {'type': 'number', 'description': 'Set the minutes'},
    'add_minutes': {'type': 'number', 'description': 'Add minutes'},
    'metrics': {'type': 'object', 'description': 'Metric values by key'},
    'notes': {'type': 'string'},
  }, ['id']),
  _fn('list_habits', 'List the user\'s habits with ids, schedule, today\'s status and streaks.', {
    'include_archived': {'type': 'boolean'},
  }, []),
  _fn('get_habit_history', 'Day-by-day entries of one habit, with streak and consistency.', {
    'id': {'type': 'string'},
    'days': {'type': 'integer', 'description': 'How many days back (default 14, max 90)'},
  }, ['id']),
];

/// A habit the model wants to create, waiting for the user's "Add habit".
class HabitProposal {
  final HabitDef habit;
  bool accepted = false;
  HabitProposal(this.habit);
}

class HabitTools {
  final AppState state;
  final DateTime Function() clock;
  final void Function(ToolActivity activity)? onActivity;

  /// When set, `create_habit` reports a proposal here instead of creating
  /// the habit; call [accept] once the user confirms.
  final void Function(HabitProposal proposal)? onProposal;

  final bool Function(String id)? visible;

  HabitTools(this.state, {this.onActivity, this.onProposal, this.visible, DateTime Function()? clock})
      : clock = clock ?? DateTime.now;

  Future<String> execute(ToolCall call) async {
    Map<String, dynamic> args;
    try {
      final decoded = jsonDecode(call.arguments.isEmpty ? '{}' : call.arguments);
      args = decoded is Map ? decoded.cast<String, dynamic>() : {};
    } on FormatException {
      return _err('Arguments were not valid JSON.');
    }
    try {
      return switch (call.name) {
        'create_habit' => await _create(args),
        'update_habit' => await _update(args),
        'set_habit_ui' => await _setUi(args),
        'archive_habit' => await _archive(args),
        'log_habit' => await _log(args),
        'list_habits' => _list(args),
        'get_habit_history' => _history(args),
        _ => _err('Unknown tool ${call.name}.'),
      };
    } on HabitSurfaceError catch (e) {
      return _err('${e.message} Nothing was saved. Fix the "ui" components and call the tool again.');
    }
  }

  /// Stores an accepted proposal.
  Future<HabitDef> accept(HabitProposal p) async {
    final stored = await state.upsertHabit(p.habit);
    p.accepted = true;
    return stored;
  }

  String _err(String m) => jsonEncode({'ok': false, 'error': m});

  HabitDef? _find(Map<String, dynamic> a) => a['id'] is String ? state.habitById(a['id'] as String) : null;

  /// Applies the shared habit fields of [a] to [h]; returns an error or null.
  String? _apply(HabitDef h, Map<String, dynamic> a) {
    if (a['title'] is String && (a['title'] as String).trim().isNotEmpty) h.title = (a['title'] as String).trim();
    if (a['emoji'] is String && (a['emoji'] as String).trim().isNotEmpty) h.emoji = (a['emoji'] as String).trim();
    if (a.containsKey('kind')) {
      final kind = HabitKind.values.where((k) => k.name == a['kind']).firstOrNull;
      if (kind == null) return 'kind must be one of check, count, duration, metric, practice.';
      h.kind = kind;
    }
    if (a.containsKey('target')) {
      final t = a['target'];
      if (t is! num || t <= 0) return 'target must be a positive number.';
      h.target = t;
    }
    if (a['unit'] is String) h.unit = a['unit'] as String;
    if (a.containsKey('weekdays')) {
      final raw = a['weekdays'];
      if (raw is! List) return 'weekdays must be a list like ["mon","wed"].';
      final days = <int>[];
      for (final d in raw) {
        final i = weekdayShort.indexOf('$d'.toLowerCase());
        if (i < 0) return 'Unknown weekday "$d". Use mon..sun.';
        days.add(i + 1);
      }
      h.weekdays = days.toSet().toList()..sort();
    }
    if (a.containsKey('reminder')) {
      final r = a['reminder'];
      if (r == null || r == '') {
        h.reminder = null;
      } else {
        final t = normalizeTime('$r');
        if (t == null) return 'reminder must be 24h HH:MM.';
        h.reminder = t;
      }
    }
    if (a.containsKey('streak_rule')) {
      final rule = StreakRule.values.where((r) => r.name == a['streak_rule']).firstOrNull;
      if (rule == null) return 'streak_rule must be strict or neverMissTwice.';
      h.streakRule = rule;
    }
    if (a['metric_fields'] is List) {
      h.metricFields = [
        for (final m in a['metric_fields'] as List)
          if (m is Map && '${m['key'] ?? ''}'.isNotEmpty) MetricField.fromJson(m.cast<String, dynamic>()),
      ];
    }
    return null;
  }

  Map<String, dynamic> _summary(HabitDef h) {
    final today = clock();
    final entry = state.habitEntry(today, h.id);
    final s = habitStreak(state.logs, h, today: today);
    return {
      'id': h.id,
      'title': h.title,
      'kind': h.kind.name,
      'target': h.target,
      'unit': h.unit,
      'schedule': h.describeSchedule(),
      'streak_rule': h.streakRule.name,
      if (h.archived) 'archived': true,
      'done_today': habitDone(entry, h),
      'streak': s.current,
      'best_streak': s.best,
      'last_30_days': habitConsistency(state.logs, h, today: today).toString(),
    };
  }

  Future<String> _create(Map<String, dynamic> a) async {
    final title = (a['title'] as String?)?.trim() ?? '';
    if (title.isEmpty) return _err('title is required.');
    if (!a.containsKey('kind')) return _err('kind is required.');
    final h = HabitDef(id: newHabitId(), title: title, createdByAi: true, createdAt: clock());
    final problem = _apply(h, a);
    if (problem != null) return _err(problem);
    h.uiSurface = normalizeHabitSurface(
      a['ui'] ?? {'components': defaultHabitComponents(h.kind, title: h.title, unit: h.unit)},
    );
    if (onProposal != null) {
      onProposal!(HabitProposal(h));
      return jsonEncode({
        'ok': true,
        'status': 'proposed',
        'note': 'A preview with an "Add habit" button is shown to the user. It is not saved until they tap it.',
        'habit': {'title': h.title, 'kind': h.kind.name, 'schedule': h.describeSchedule()},
      });
    }
    final stored = await state.upsertHabit(h);
    onActivity?.call(ToolActivity('Added habit “${stored.title}” · ${stored.describeSchedule()}',
        undo: () => state.deleteHabit(stored.id)));
    return jsonEncode({'ok': true, 'status': 'created', 'habit': _summary(stored)});
  }

  Future<String> _update(Map<String, dynamic> a) async {
    final current = _find(a);
    if (current == null) return _err('No habit with that id. Call list_habits.');
    final before = current.copy();
    final next = current.copy();
    final problem = _apply(next, a);
    if (problem != null) return _err(problem);
    if (a.containsKey('ui')) next.uiSurface = normalizeHabitSurface(a['ui']);
    await state.upsertHabit(next);
    onActivity?.call(ToolActivity('Updated habit “${next.title}” · ${next.describeSchedule()}',
        undo: () => state.upsertHabit(before)));
    return jsonEncode({'ok': true, 'habit': _summary(next)});
  }

  Future<String> _setUi(Map<String, dynamic> a) async {
    final current = _find(a);
    if (current == null) return _err('No habit with that id. Call list_habits.');
    final before = current.copy();
    final next = current.copy()..uiSurface = normalizeHabitSurface(a['ui']);
    await state.upsertHabit(next);
    onActivity?.call(ToolActivity('New screen for “${next.title}”', undo: () => state.upsertHabit(before)));
    return jsonEncode({'ok': true, 'habit': _summary(next)});
  }

  Future<String> _archive(Map<String, dynamic> a) async {
    final h = _find(a);
    if (h == null) return _err('No habit with that id. Call list_habits.');
    final archived = a['archived'] != false;
    await state.archiveHabit(h.id, archived: archived);
    onActivity?.call(ToolActivity('${archived ? 'Archived' : 'Restored'} habit “${h.title}”',
        undo: () => state.archiveHabit(h.id, archived: !archived)));
    return jsonEncode({'ok': true, 'archived': archived, 'id': h.id});
  }

  Future<String> _log(Map<String, dynamic> a) async {
    final h = _find(a);
    if (h == null) return _err('No habit with that id. Call list_habits.');
    var day = clock();
    if (a['date'] is String) {
      if (!isValidDate(a['date'] as String)) return _err('date must be YYYY-MM-DD.');
      day = DateTime.parse(a['date'] as String);
    }
    final before = state.habitEntry(day, h.id).copy();
    final next = before.copy();
    num? n(String k) => a[k] is num ? a[k] as num : null;
    if (a['done'] is bool) next.done = a['done'] as bool;
    if (n('value') != null) next.value = n('value');
    if (n('add_value') != null) next.value = (next.value ?? 0) + n('add_value')!;
    if (n('minutes') != null) next.minutes = n('minutes')!.round();
    if (n('add_minutes') != null) next.minutes = (next.minutes ?? 0) + n('add_minutes')!.round();
    if (a['metrics'] is Map) {
      for (final e in (a['metrics'] as Map).entries) {
        if (e.value is num) next.metrics['${e.key}'] = e.value as num;
      }
    }
    if (a['notes'] is String) next.notes = a['notes'] as String;
    await state.logHabit(day, h.id, next);
    onActivity?.call(ToolActivity('Logged “${h.title}” for ${dayKey(day)}',
        undo: () => state.logHabit(day, h.id, before)));
    return jsonEncode({'ok': true, 'date': dayKey(day), 'done': habitDone(next, h), 'entry': _entryJson(next)});
  }

  Map<String, dynamic> _entryJson(HabitEntry e) => {
        'done': e.done,
        if (e.value != null) 'value': e.value,
        if (e.minutes != null) 'minutes': e.minutes,
        if (e.metrics.isNotEmpty) 'metrics': e.metrics,
        if (e.notes.isNotEmpty) 'notes': e.notes,
        if (e.sessions.isNotEmpty) 'sessions': e.sessions.length,
      };

  String _list(Map<String, dynamic> a) {
    final all = a['include_archived'] == true ? state.habits : state.activeHabits;
    return jsonEncode({'ok': true, 'today': dayKey(clock()), 'habits': all.where((h) => visible?.call(h.id) ?? true).map(_summary).toList()});
  }

  String _history(Map<String, dynamic> a) {
    final h = _find(a);
    if (h == null) return _err('No habit with that id. Call list_habits.');
    final days = ((a['days'] as num?)?.toInt() ?? 14).clamp(1, 90);
    final today = dateOnly(clock());
    return jsonEncode({
      'ok': true,
      'habit': _summary(h),
      'days': [
        for (var i = days - 1; i >= 0; i--)
          () {
            final d = DateTime(today.year, today.month, today.day - i);
            final e = state.logs[dayKey(d)]?.habits[h.id];
            return {
              'date': dayKey(d),
              'scheduled': h.isScheduledOn(d),
              'done': habitDone(e, h),
              if (e != null) ..._entryJson(e),
            };
          }(),
      ],
    });
  }
}

/// One conversation with the model that can manage tasks and habits.
class HabitAgent {
  final AppState state;
  final void Function(ToolActivity activity)? onActivity;
  final void Function(HabitProposal proposal)? onProposal;
  final OpenRouterClient Function() _client;
  final DateTime Function() clock;

  final CoachAccess? access;

  late final habitTools = HabitTools(state, visible: access?.habit, onActivity: onActivity, onProposal: onProposal, clock: clock);
  late final taskTools = TaskTools(state, visible: access?.task, onActivity: onActivity, clock: clock);
  late final appTools = AppTools(state, onActivity: onActivity, clock: clock);
  late final goalTools = GoalTools(state, onActivity: onActivity, clock: clock);
  late final financeTools = FinanceTools(state, onActivity: onActivity, clock: clock);

  HabitAgent(
    this.state, {
    this.access,
    this.onActivity,
    this.onProposal,
    OpenRouterClient Function()? client,
    DateTime Function()? clock,
  })  : clock = clock ?? DateTime.now,
        _client = client ?? (() => OpenRouterClient(apiKey: state.apiKey, model: state.settings.model));

  List<Map<String, dynamic>> get tools => [...taskToolDefinitions, ...habitToolDefinitions, ...appToolDefinitions, ...goalToolDefinitions, ...financeToolDefinitions];

  Future<String> execute(ToolCall call) => habitToolNames.contains(call.name)
      ? habitTools.execute(call)
      : appToolNames.contains(call.name)
      ? appTools.execute(call)
      : goalToolNames.contains(call.name)
      ? goalTools.execute(call)
      : financeToolNames.contains(call.name)
      ? financeTools.execute(call)
      : taskTools.execute(call);

  /// Runs the model on [history] (which gains every assistant and tool
  /// message) until it stops calling tools. [system] is the caller's prompt;
  /// the habit prompt is appended. Returns the final reply text.
  Future<String> run(
    List<ChatMessage> history, {
    required String system,
    void Function(String delta)? onText,
    void Function()? onToolCall,
    void Function(ToolCall call)? onToolStart,
    void Function(ToolCall call, String result)? onToolResult,
    ReviewChanges? review,
    void Function()? checkActive,
    bool replyOnly = false,
  }) async {
    final client = _client();
    final scope = access;
    var approved = <ToolCall>{};
    try {
      return await client.runAgent(
        history,
        system: '$system\n\n${habitAgentPrompt()}',
        tools: [for (final tool in tools) if (!replyOnly && (scope?.advertises(tool['function']['name'] as String) ?? true)) tool],
        checkActive: checkActive,
        beforeCalls: scope == null ? null : (calls) async {
          approved.clear();
          if (replyOnly) return;
          final changes = calls.where((c) => scope.allows(c) && scope.needsReview(c)).toList();
          if (changes.isNotEmpty && await review?.call(List.unmodifiable(changes)) == true) {
            approved = changes.toSet();
          }
        },
        execute: (call) async {
          onToolCall?.call();
          onToolStart?.call(call);
          String result;
          try {
            if (replyOnly || (scope != null && !scope.allows(call))) {
              result = jsonEncode({'error': 'Outside the shared context. No change made.'});
            } else if (scope != null && scope.needsReview(call) && !approved.remove(call)) {
              result = jsonEncode({'error': 'Change was not approved.'});
            } else if (scope != null && call.name == 'list_goals') {
              result = jsonEncode({'goals': scope.goals.map(goalTools.describe).toList()});
            } else if (scope?.money == CoachMoney.totals && call.name == 'money_summary') {
              result = jsonEncode({'summary': scope!.totals(clock())});
            } else {
              result = await execute(call);
              if (scope != null && call.name == 'customize_today' && jsonDecode(result)['ok'] == true) {
                result = '{"ok":true}';
              }
            }
            if (scope != null) result = scope.redactPeople(result);
          } catch (e) {
            result = jsonEncode({'error': e.toString()});
          }
          onToolResult?.call(call, result);
          return result;
        },
        onText: onText,
      );
    } finally {
      client.close();
    }
  }
}
