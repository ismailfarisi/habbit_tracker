import 'dart:convert';

import '../app_state.dart';
import '../goals/goal.dart';
import '../logic/stats.dart';
import '../models.dart';
import '../services/openrouter.dart';
import '../services/task_tools.dart';

Map<String, dynamic> _fn(String name, String description, Map<String, dynamic> props, List<String> required) => {
  'type': 'function',
  'function': {
    'name': name,
    'description': description,
    'parameters': {'type': 'object', 'properties': props, 'required': required},
  },
};

const _milestone = {
  'type': 'object',
  'properties': {
    'title': {'type': 'string'},
    'due': {'type': 'string', 'description': 'YYYY-MM-DD'},
  },
  'required': ['title'],
};

const _task = {
  'type': 'object',
  'properties': {
    'title': {'type': 'string'},
    'notes': {'type': 'string'},
    'date': {'type': 'string', 'description': 'YYYY-MM-DD (start date for repeating tasks)'},
    'time': {'type': 'string', 'description': 'HH:mm, gives a reminder'},
    'repeat': {
      'type': 'string',
      'enum': ['none', 'daily', 'weekly'],
    },
    'weekdays': {
      'type': 'array',
      'items': {'type': 'integer'},
      'description': '1 = Monday .. 7 = Sunday, for weekly',
    },
  },
  'required': ['title'],
};

final goalToolDefinitions = <Map<String, dynamic>>[
  _fn(
    'create_goal',
    'Create a goal of any length (a week to years) with milestones and the first tasks that move it forward. '
        'Create tasks here instead of with create_task so they are linked to the goal.',
    {
      'title': {'type': 'string'},
      'why': {'type': 'string', 'description': "The user's reason, in their words"},
      'emoji': {'type': 'string'},
      'end_date': {'type': 'string', 'description': 'YYYY-MM-DD target date'},
      'review': {
        'type': 'string',
        'enum': ReviewCadence.values.map((c) => c.name).toList(),
        'description': 'How often to look back together. Default fits the length.',
      },
      'milestones': {'type': 'array', 'items': _milestone},
      'tasks': {'type': 'array', 'items': _task},
    },
    ['title', 'end_date'],
  ),
  _fn('list_goals', 'List goals with ids, milestones, linked tasks/habits, progress and past reviews.', {}, []),
  _fn(
    'update_goal',
    'Change a goal. Only pass fields that should change. Can add milestones and tasks, or mark milestones done.',
    {
      'id': {'type': 'string'},
      'title': {'type': 'string'},
      'why': {'type': 'string'},
      'end_date': {'type': 'string'},
      'review': {
        'type': 'string',
        'enum': ReviewCadence.values.map((c) => c.name).toList(),
      },
      'add_milestones': {'type': 'array', 'items': _milestone},
      'milestones_done': {
        'type': 'array',
        'items': {'type': 'string'},
        'description': 'Milestone ids to mark done',
      },
      'add_tasks': {'type': 'array', 'items': _task},
      'link_task_ids': {
        'type': 'array',
        'items': {'type': 'string'},
      },
      'link_habit_ids': {
        'type': 'array',
        'items': {'type': 'string'},
      },
    },
    ['id'],
  ),
  _fn(
    'save_goal_review',
    'Record a look-back on a goal after discussing it: a short encouraging summary and 1-4 concrete suggestions '
        'the user can apply (lighten, reschedule, add a milestone, add a habit).',
    {
      'id': {'type': 'string'},
      'summary': {'type': 'string'},
      'suggestions': {
        'type': 'array',
        'items': {'type': 'string'},
      },
    },
    ['id', 'summary'],
  ),
];

final goalToolNames = {for (final t in goalToolDefinitions) (t['function'] as Map)['name'] as String};

class GoalTools {
  final AppState state;
  final void Function(ToolActivity activity)? onActivity;
  final DateTime Function() clock;
  GoalTools(this.state, {this.onActivity, DateTime Function()? clock}) : clock = clock ?? DateTime.now;

  String _id(String p) => '$p${clock().microsecondsSinceEpoch.toRadixString(36)}${state.goals.length}';

  List<Milestone> _milestones(Object? raw) => [
    for (final (i, m) in ((raw as List?) ?? const []).cast<Map>().indexed)
      if ('${m['title'] ?? ''}'.trim().isNotEmpty)
        Milestone(id: _id('m$i-'), title: '${m['title']}'.trim(), due: _date(m['due'])),
  ];

  String? _date(Object? s) {
    final d = s is String ? DateTime.tryParse(s) : null;
    return d == null ? null : dayKey(d);
  }

  Future<List<Task>> _tasks(Object? raw) async {
    final out = <Task>[];
    for (final m in ((raw as List?) ?? const []).cast<Map>()) {
      final title = '${m['title'] ?? ''}'.trim();
      if (title.isEmpty) continue;
      final time = '${m['time'] ?? ''}';
      out.add(
        await state.addTask(
          title: title,
          notes: '${m['notes'] ?? ''}',
          date: _date(m['date']),
          time: RegExp(r'^\d{1,2}:\d{2}$').hasMatch(time) ? time.padLeft(5, '0') : null,
          repeat: Repeat.values.firstWhere((r) => r.name == m['repeat'], orElse: () => Repeat.none),
          weekdays: ((m['weekdays'] as List?) ?? const []).map((e) => (e as num).toInt()).toList(),
          byAi: true,
        ),
      );
    }
    return out;
  }

  Map<String, dynamic> describe(Goal g) {
    final now = clock();
    final linked = state.tasks.where((t) => g.taskIds.contains(t.id)).toList();
    return {
      'id': g.id,
      'title': g.title,
      'why': g.why,
      'start': g.start,
      'end': g.end,
      'review': g.cadence.name,
      'reviewDue': g.reviewDue(now),
      'timeElapsedPct': (g.elapsed(now) * 100).round(),
      'progressPct': (g.progress(state.tasks) * 100).round(),
      'milestones': [for (final m in g.milestones) m.toJson()],
      'tasks': [
        for (final t in linked)
          {
            'id': t.id,
            'title': t.title,
            'repeat': t.repeat.name,
            'date': t.date,
            'timesDone': t.doneDates.length,
            'doneLast7': t.doneDates.where((d) => now.difference(DateTime.parse(d)).inDays < 7).length,
          },
      ],
      'habits': [
        for (final h in state.habits.where((h) => g.habitIds.contains(h.id)))
          {
            'id': h.id,
            'title': h.title,
            'doneLast7': [
              for (var i = 0; i < 7; i++) state.habitEntry(now.subtract(Duration(days: i)), h.id),
            ].where((e) => e.done).length,
          },
      ],
      'lastReview': g.reviews.isEmpty ? null : g.reviews.last.toJson(),
    };
  }

  Future<String> execute(ToolCall call) async {
    final a = call.arguments.trim().isEmpty ? <String, dynamic>{} : jsonDecode(call.arguments) as Map<String, dynamic>;
    switch (call.name) {
      case 'create_goal':
        final title = '${a['title'] ?? ''}'.trim();
        final end = _date(a['end_date']);
        if (title.isEmpty || end == null) return jsonEncode({'error': 'title and end_date (YYYY-MM-DD) are needed'});
        final start = dayKey(clock());
        final days = DateTime.parse(end).difference(DateTime.parse(start)).inDays;
        final tasks = await _tasks(a['tasks']);
        final g = Goal(
          id: _id('g'),
          title: title,
          why: '${a['why'] ?? ''}'.trim(),
          emoji: '${a['emoji'] ?? ''}'.trim().isEmpty ? '🎯' : '${a['emoji']}'.trim(),
          start: start,
          end: end,
          cadence: ReviewCadence.values.firstWhere((c) => c.name == a['review'], orElse: () => cadenceFor(days)),
          milestones: _milestones(a['milestones']),
          taskIds: [for (final t in tasks) t.id],
        );
        await state.upsertGoal(g);
        onActivity?.call(
          ToolActivity(
            'Goal "${g.title}": ${g.milestones.length} milestones, ${tasks.length} tasks, reviewed ${g.cadence.name}',
            undo: () async {
              for (final t in tasks) {
                await state.deleteTask(t);
              }
              await state.deleteGoal(g.id);
            },
          ),
        );
        return jsonEncode({'ok': true, 'goal': describe(g)});
      case 'list_goals':
        return jsonEncode({
          'goals': [for (final g in state.goals.where((g) => !g.archived)) describe(g)],
        });
      case 'update_goal':
        final g = state.goalById('${a['id']}');
        if (g == null) return jsonEncode({'error': 'unknown goal id; call list_goals first'});
        final before = g.copy();
        if (a['title'] is String) g.title = a['title'] as String;
        if (a['why'] is String) g.why = a['why'] as String;
        final end = _date(a['end_date']);
        if (end != null) g.end = end;
        if (a['review'] is String) {
          g.cadence = ReviewCadence.values.firstWhere((c) => c.name == a['review'], orElse: () => g.cadence);
        }
        g.milestones.addAll(_milestones(a['add_milestones']));
        for (final id in ((a['milestones_done'] as List?) ?? const []).cast<String>()) {
          for (final m in g.milestones.where((m) => m.id == id)) {
            m.done = true;
          }
        }
        final tasks = await _tasks(a['add_tasks']);
        g.taskIds.addAll(tasks.map((t) => t.id));
        for (final id in ((a['link_task_ids'] as List?) ?? const []).cast<String>()) {
          if (state.taskById(id) != null && !g.taskIds.contains(id)) g.taskIds.add(id);
        }
        for (final id in ((a['link_habit_ids'] as List?) ?? const []).cast<String>()) {
          if (state.habitById(id) != null && !g.habitIds.contains(id)) g.habitIds.add(id);
        }
        await state.upsertGoal(g);
        onActivity?.call(
          ToolActivity(
            'Updated goal "${g.title}"${tasks.isEmpty ? '' : ', added ${tasks.length} tasks'}',
            undo: () async {
              for (final t in tasks) {
                await state.deleteTask(t);
              }
              await state.upsertGoal(before);
            },
          ),
        );
        return jsonEncode({'ok': true, 'goal': describe(g)});
      case 'save_goal_review':
        final g = state.goalById('${a['id']}');
        if (g == null) return jsonEncode({'error': 'unknown goal id; call list_goals first'});
        final r = GoalReview(
          at: clock(),
          summary: '${a['summary'] ?? ''}'.trim(),
          suggestions: ((a['suggestions'] as List?) ?? const []).map((e) => '$e'.trim()).where((e) => e.isNotEmpty).toList(),
        );
        g.reviews.add(r);
        await state.upsertGoal(g);
        onActivity?.call(
          ToolActivity(
            'Saved review of "${g.title}" with ${r.suggestions.length} suggestions',
            undo: () async {
              g.reviews.remove(r);
              await state.upsertGoal(g);
            },
          ),
        );
        return jsonEncode({'ok': true});
    }
    return jsonEncode({'error': 'unknown tool ${call.name}'});
  }
}

/// Goals summary for the system prompt, so every conversation shares them.
String goalsContext(AppState state, DateTime now) {
  final active = state.goals.where((g) => !g.archived).toList();
  if (active.isEmpty) return 'The user has no goals yet.';
  return 'User\'s goals (use list_goals for details):\n${[
    for (final g in active)
      '- ${g.id}: ${g.title} (${g.start} → ${g.end}, ${(g.progress(state.tasks) * 100).round()}% done, '
          '${(g.elapsed(now) * 100).round()}% of time passed${g.reviewDue(now) ? ', review due' : ''})',
  ].join('\n')}';
}

const goalsPrompt = '''
Goals: when the user describes something bigger than a single task (learn,
memorise, build, lose, save, finish, become), help them shape it into a goal:
- If the timeline or starting point is unclear, ask at most two short
  questions first. Otherwise act.
- Call create_goal with a realistic end date, 3-6 milestones spread across the
  timeline and only the first week or two of tasks (prefer small repeating
  tasks). Suggest a habit with create_habit when daily practice helps, then
  link it with update_goal link_habit_ids.
- Plan in layers: the whole timeline as milestones, the current month as
  focus, this week as tasks. Fill in later weeks during reviews.
- For a review ("review my goal", or a review is due): call list_goals, look
  at what was done versus planned, celebrate what went well, then call
  save_goal_review with 1-4 concrete suggestions and apply only what the user
  agrees to.
Tone: this is a personal Islamic growth companion. Encourage consistency, not
perfection. Never guilt the user about missed days; suggest a lighter next
step instead. Keep religious references natural and respectful.
''';
