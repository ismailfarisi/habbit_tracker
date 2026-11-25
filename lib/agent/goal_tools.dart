import 'dart:convert';

import '../app_state.dart';
import '../goals/goal.dart';
import '../goals/goal_outcomes.dart';
import '../logic/stats.dart';
import '../models.dart';
import '../services/openrouter.dart';
import '../services/task_tools.dart';
import '../quran/surahs.dart';
import '../habits/habit.dart';

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
    'steps': {
      'type': 'array',
      'items': {'type': 'string'},
      'description': '3-6 concrete numbered instructions for doing the task',
    },
    'done_when': {'type': 'string', 'description': 'What counts as done, observable'},
    'minutes': {'type': 'integer'},
    'sessions': {
      'type': 'array',
      'items': {'type': 'string'},
      'description': 'For repeating practice: what each session focuses on, in order (one short line each). The app shows the next one each day it is done',
    },
    'quran': {
      'type': 'object',
      'description': 'For Quran tasks: the passage. The app shows the verified text itself; never write verses.',
      'properties': {
        'surah': {'type': 'integer', 'description': '1-114'},
        'from': {'type': 'integer'},
        'to': {'type': 'integer'},
        'per_day': {'type': 'integer', 'description': 'For repeating tasks: ayat per day; the app moves on each day it is done'},
        'mode': {
          'type': 'string',
          'enum': ['memorise', 'revise', 'read'],
        },
      },
      'required': ['surah', 'from', 'to'],
    },
  },
  'required': ['title', 'steps', 'done_when'],
};

const _goalHabit = {
  'type': 'object',
  'description': 'A daily (or weekly) practice that moves the goal forward.',
  'properties': {
    'title': {'type': 'string'},
    'emoji': {'type': 'string'},
    'reminder': {'type': 'string', 'description': '24h HH:MM'},
    'weekdays': {
      'type': 'array',
      'items': {'type': 'integer'},
      'description': '1 = Monday .. 7 = Sunday. Omit for every day.',
    },
    'steps': {
      'type': 'array',
      'items': {'type': 'string'},
      'description': '3-6 concrete instructions for each session',
    },
    'done_when': {'type': 'string'},
    'minutes': {'type': 'integer'},
    'sessions': {
      'type': 'array',
      'items': {'type': 'string'},
      'description': 'For repeating practice: what each session focuses on, in order (one short line each). The app shows the next one each day it is done',
    },
    'quran': {
      'type': 'object',
      'description': 'For Quran practice: the whole passage and how many ayat per day. '
          'The app shows the next portion each day and the verified text.',
      'properties': {
        'surah': {'type': 'integer'},
        'from': {'type': 'integer'},
        'to': {'type': 'integer'},
        'per_day': {'type': 'integer'},
        'mode': {
          'type': 'string',
          'enum': ['memorise', 'revise', 'read'],
        },
      },
      'required': ['surah', 'from', 'to'],
    },
  },
  'required': ['title', 'steps', 'done_when'],
};

final goalToolDefinitions = <Map<String, dynamic>>[
  _fn(
    'create_goal',
    'Create a goal of any length (a week to years) with milestones, its daily practice habits and the first tasks. '
        'Everything for the goal goes here (not create_task / create_habit) so it is linked and shown together.',
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
      'habits': {'type': 'array', 'items': _goalHabit},
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
      'add_note': {
        'type': 'string',
        'description': "A short fact, decision or update to keep in the goal's notes (its context file)",
      },
      'milestones_done': {
        'type': 'array',
        'items': {'type': 'string'},
        'description': 'Milestone ids to mark done',
      },
      'add_tasks': {'type': 'array', 'items': _task},
      'add_habits': {'type': 'array', 'items': _goalHabit},
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

  Future<List<Task>> _tasks(Object? raw, String goalId, void Function() check) async {
    final out = <Task>[];
    for (final m in ((raw as List?) ?? const []).cast<Map>()) {
      check();
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
      check();
      final task = out.last;
      onActivity?.call(ToolActivity('Created task “${task.title}”', undo: () async {
        await state.deleteTask(task);
        final g = state.goalById(goalId);
        if (g != null && g.taskIds.remove(task.id)) await state.saveGoals();
      }));
      final guide = _guide(m);
      if (guide != null) await state.updateTask(out.last, (t) => t.guide = guide);
    }
    return out;
  }

  Future<List<HabitDef>> _habits(Object? raw, String goalId, void Function() check) async {
    final out = <HabitDef>[];
    for (final (i, m) in ((raw as List?) ?? const []).cast<Map>().indexed) {
      check();
      final title = '${m['title'] ?? ''}'.trim();
      if (title.isEmpty) continue;
      final reminder = '${m['reminder'] ?? ''}';
      out.add(
        await state.upsertHabit(
          HabitDef(
            id: '${newHabitId()}$i',
            title: title,
            emoji: '${m['emoji'] ?? ''}'.trim().isEmpty ? '📖' : '${m['emoji']}'.trim(),
            weekdays: [
              for (final d in (m['weekdays'] as List?) ?? const [])
                if (d is num && d >= 1 && d <= 7) d.toInt(),
            ],
            reminder: RegExp(r'^\d{1,2}:\d{2}$').hasMatch(reminder) ? reminder.padLeft(5, '0') : null,
            createdByAi: true,
            guide: _guide(m),
          ),
        ),
      );
      check();
      final habit = out.last;
      onActivity?.call(ToolActivity('Created habit “${habit.title}”', undo: () async {
        await state.deleteHabit(habit.id);
        final g = state.goalById(goalId);
        if (g != null && g.habitIds.remove(habit.id)) await state.saveGoals();
      }));
    }
    return out;
  }

  void _milestoneReceipts(Goal g, Iterable<Milestone> added) {
    for (final m in added) {
      onActivity?.call(ToolActivity('Added milestone “${m.title}”', undo: () async {
        state.goalById(g.id)?.milestones.removeWhere((item) => item.id == m.id);
        await state.saveGoals();
      }));
    }
  }

  TaskGuide? _guide(Map m) {
    QuranRef? q;
    final rq = m['quran'];
    if (rq is Map && rq['surah'] is num) {
      final surah = (rq['surah'] as num).toInt().clamp(1, surahInfo.length);
      final count = surahInfo[surah - 1].$3;
      final from = ((rq['from'] as num?)?.toInt() ?? 1).clamp(1, count);
      final to = ((rq['to'] as num?)?.toInt() ?? from).clamp(from, count);
      final perDay = (rq['per_day'] as num?)?.toInt();
      q = QuranRef(
        surah,
        from,
        to,
        mode: '${rq['mode'] ?? 'read'}',
        perDay: perDay == null || perDay <= 0 ? null : perDay,
      );
    }
    final g = TaskGuide(
      steps: ((m['steps'] as List?) ?? const []).map((e) => '$e'.trim()).where((e) => e.isNotEmpty).toList(),
      doneWhen: '${m['done_when'] ?? ''}'.trim(),
      minutes: (m['minutes'] as num?)?.toInt(),
      quran: q,
      sessions: ((m['sessions'] as List?) ?? const []).map((e) => '$e'.trim()).where((e) => e.isNotEmpty).toList(),
    );
    return g.isEmpty ? null : g;
  }

  Map<String, dynamic> describe(Goal g) {
    final now = clock();
    final linked = state.tasks.where((t) => g.taskIds.contains(t.id)).toList();
    final outcomes = goalOutcomes(state, g, now);
    return {
      'id': g.id,
      'title': g.title,
      'why': g.why,
      'start': g.start,
      'end': g.end,
      'review': g.cadence.name,
      'reviewDue': g.reviewDue(now),
      'timeElapsedPct': (g.elapsed(now) * 100).round(),
      'outcomes': [for (final o in outcomes) o.label],
      if (outcomes.singleOrNull?.fraction case final pct?) 'progressPct': (pct * 100).round(),
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
            if (state.quranFor(h, now) case final q?) 'todayQuran': q.toJson(),
            'doneLast7': [
              for (var i = 0; i < 7; i++) state.habitEntry(now.subtract(Duration(days: i)), h.id),
            ].where((e) => e.done).length,
          },
      ],
      'lastReview': g.reviews.isEmpty ? null : g.reviews.last.toJson(),
    };
  }

  // A plan can contain many records. Check every supplied field before
  // creating the first record so malformed later items cannot leave orphans.
  bool _matches(Object? value, Map schema) {
    return switch (schema['type']) {
      'object' => value is Map &&
          (!(schema['required'] as List? ?? const []).contains('title') || '${value['title'] ?? ''}'.trim().isNotEmpty) &&
          (schema['properties'] as Map).entries.every(
        (e) => !value.containsKey(e.key) || _matches(value[e.key], e.value as Map)),
      'array' => value is List && value.every((v) => _matches(v, schema['items'] as Map)),
      'string' => value is String,
      'integer' => value is int,
      _ => true,
    };
  }

  Future<String> execute(ToolCall call) async {
    final generation = state.dataGeneration;
    void check() {
      if (state.dataGeneration != generation) throw StateError('The local records have changed.');
    }
    final a = call.arguments.trim().isEmpty ? <String, dynamic>{} : jsonDecode(call.arguments) as Map<String, dynamic>;
    if (call.name == 'create_goal' || call.name == 'update_goal') {
      final schema = goalToolDefinitions.firstWhere((t) => t['function']['name'] == call.name)['function']['parameters'] as Map;
      if (!_matches(a, schema)) return jsonEncode({'error': 'Invalid plan fields. No items were changed.'});
    }
    switch (call.name) {
      case 'create_goal':
        final title = '${a['title'] ?? ''}'.trim();
        final end = _date(a['end_date']);
        if (title.isEmpty || end == null) return jsonEncode({'error': 'title and end_date (YYYY-MM-DD) are needed'});
        final start = dayKey(clock());
        final days = DateTime.parse(end).difference(DateTime.parse(start)).inDays;
        final id = _id('g');
        final tasks = await _tasks(a['tasks'], id, check);
        final habits = await _habits(a['habits'], id, check);
        final g = Goal(
          id: id,
          title: title,
          why: '${a['why'] ?? ''}'.trim(),
          emoji: '${a['emoji'] ?? ''}'.trim().isEmpty ? '🎯' : '${a['emoji']}'.trim(),
          start: start,
          end: end,
          cadence: ReviewCadence.values.firstWhere((c) => c.name == a['review'], orElse: () => cadenceFor(days)),
          milestones: _milestones(a['milestones']),
          taskIds: [for (final t in tasks) t.id],
          habitIds: [for (final h in habits) h.id],
        );
        check();
        await state.upsertGoal(g);
        _milestoneReceipts(g, g.milestones);
        onActivity?.call(ToolActivity('Created goal “${g.title}”', undo: () => state.deleteGoal(g.id)));
        return jsonEncode({'ok': true, 'goal': describe(g)});
      case 'list_goals':
        return jsonEncode({
          'goals': [for (final g in state.goals.where((g) => !g.archived)) describe(g)],
        });
      case 'update_goal':
        final g = state.goalById('${a['id']}');
        if (g == null) return jsonEncode({'error': 'unknown goal id; call list_goals first'});
        final before = g.copy();
        final previousTaskIds = {...g.taskIds}, previousHabitIds = {...g.habitIds};
        if (a['title'] is String) g.title = a['title'] as String;
        if (a['why'] is String) g.why = a['why'] as String;
        final end = _date(a['end_date']);
        if (end != null) g.end = end;
        if (a['review'] is String) {
          g.cadence = ReviewCadence.values.firstWhere((c) => c.name == a['review'], orElse: () => g.cadence);
        }
        final addedMilestones = _milestones(a['add_milestones']);
        g.milestones.addAll(addedMilestones);
        final note = '${a['add_note'] ?? ''}'.trim();
        final addedNote = note.isEmpty ? null : GoalNote(note, shared: true, changedOn: dayKey(clock()));
        if (addedNote != null) g.noteEntries.add(addedNote);
        for (final id in ((a['milestones_done'] as List?) ?? const []).cast<String>()) {
          for (final m in g.milestones.where((m) => m.id == id)) {
            m.done = true;
          }
        }
        final tasks = await _tasks(a['add_tasks'], g.id, check);
        g.taskIds.addAll(tasks.map((t) => t.id));
        final habits = await _habits(a['add_habits'], g.id, check);
        g.habitIds.addAll(habits.map((h) => h.id));
        for (final id in ((a['link_task_ids'] as List?) ?? const []).cast<String>()) {
          if (state.taskById(id) != null && !g.taskIds.contains(id)) g.taskIds.add(id);
        }
        for (final id in ((a['link_habit_ids'] as List?) ?? const []).cast<String>()) {
          if (state.habitById(id) != null && !g.habitIds.contains(id)) g.habitIds.add(id);
        }
        check();
        await state.upsertGoal(g);
        _milestoneReceipts(g, addedMilestones);
        final applied = g.copy();
        final linkedTasks = applied.taskIds.toSet().difference({...previousTaskIds, ...tasks.map((t) => t.id)});
        final linkedHabits = applied.habitIds.toSet().difference({...previousHabitIds, ...habits.map((h) => h.id)});
        onActivity?.call(ToolActivity('Updated goal “${g.title}”', undo: () async {
          final current = state.goalById(g.id);
          if (current == null) return;
          if (current.title == applied.title) current.title = before.title;
          if (current.why == applied.why) current.why = before.why;
          if (current.end == applied.end) current.end = before.end;
          if (current.cadence == applied.cadence) current.cadence = before.cadence;
          if (addedNote != null && addedNote.shared && addedNote.text == note) current.noteEntries.remove(addedNote);
          current.taskIds.removeWhere(linkedTasks.contains);
          current.habitIds.removeWhere(linkedHabits.contains);
          for (final m in current.milestones) {
            final prev = before.milestones.where((v) => v.id == m.id).firstOrNull;
            if (prev != null && applied.milestones.any((v) => v.id == m.id && v.done == m.done)) m.done = prev.done;
          }
          await state.saveGoals();
        }));
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
        check();
        await state.upsertGoal(g);
        onActivity?.call(
          ToolActivity(
            'Saved review of "${g.title}" with ${r.suggestions.length} suggestions',
            undo: () async {
              state.goalById(g.id)?.reviews.removeWhere((item) => item.at == r.at && item.summary == r.summary);
              await state.saveGoals();
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
      '- ${g.id}: ${g.title} (${g.start} → ${g.end}, ${goalOutcomes(state, g, now).map((o) => o.label).join(', ')}, '
          '${(g.elapsed(now) * 100).round()}% of time passed${g.reviewDue(now) ? ', review due' : ''})',
  ].join('\n')}';
}

const goalChatPrompt = '''
This conversation is about one goal. Its context file (Open Knowledge Format:
Markdown with YAML frontmatter) follows. Answer in that context and use its
id for update_goal. Add new tasks and habits through update_goal add_tasks /
add_habits so they stay linked to this goal. When the user shares a fact,
decision or update worth keeping, save it with update_goal add_note.''';

const goalsPrompt = '''
Goals: when the user describes something bigger than a single task (learn,
memorise, build, lose, save, finish, become), help them shape it into a goal:
- If the timeline or starting point is unclear, ask at most two short
  questions first. Otherwise act.
- Call create_goal once with everything: a realistic end date, 3-6
  milestones spread across the timeline, the daily practice as habits and
  only the first week or two of one-off tasks. Never call create_task or
  create_habit for a goal's items: they would not be linked or shown with
  the goal. Example: "memorise Surah Al-Mulk" is one habit with quran
  {surah: 67, from: 1, to: 30, per_day: 2, mode: memorise} (the app moves to
  the next ayat each day it is done) plus a weekly revision task. Always
  give the whole passage (from..to) with per_day, never only the first day's
  ayat. Every task needs clear steps (what exactly to do, in order),
  minutes and done_when, so the user never wonders what to do. For Quran
  tasks set quran {surah, from, to, mode}; the app shows the verified
  Uthmani text, translation and recitation, so never write verses yourself.
  Use well-known methods (e.g. listen, repeat each ayah, link ayat, recite
  from memory, revise the previous day's portion). To add practice to an
  existing goal use update_goal add_habits.
  Any goal (business, fitness, study, a project) is planned day by day the
  same way: put the recurring work in habits or repeating tasks with
  sessions, an ordered list of what each session focuses on, so every day
  shows its own work. Example: "launch my bakery's online shop in 6 weeks"
  is a weekday habit "Shop build" with sessions ["List 20 best sellers",
  "Photograph 5 products", "Write product descriptions", ...] plus dated
  one-off tasks (with a date) such as "Register the domain"; milestones mark
  the weeks.
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
