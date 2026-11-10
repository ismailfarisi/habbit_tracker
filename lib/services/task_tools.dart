import 'dart:convert';

import 'package:intl/intl.dart';

import '../logic/stats.dart';
import '../logic/tasks.dart';
import '../models.dart';
import 'openrouter.dart';
import 'prayer_service.dart';

/// The task operations the AI is allowed to perform. Implemented by AppState.
abstract interface class TaskBackend {
  List<Task> get tasks;
  Future<Task> addTask({
    required String title,
    String notes,
    String? date,
    String? time,
    Repeat repeat,
    List<int> weekdays,
    bool byAi,
  });
  Future<void> updateTask(Task t, void Function(Task t) change);
  Future<void> setTaskDone(Task t, DateTime day, bool done);
  Future<void> deleteTask(Task t);
  Future<void> restoreTask(Task t);
}

/// Something the AI did, shown in the chat with an optional undo.
class ToolActivity {
  final String label;
  final Future<void> Function()? undo;
  ToolActivity(this.label, {this.undo});
}

const _taskProps = {
  'title': {'type': 'string', 'description': 'Short task title, e.g. "Read Quran"'},
  'notes': {'type': 'string', 'description': 'Optional details'},
  'date': {
    'type': 'string',
    'description': 'YYYY-MM-DD. For one-off tasks, the day it is due (omit for "anytime"). For repeating tasks, the start date (optional).',
  },
  'time': {'type': 'string', 'description': '24h HH:MM. A reminder notification fires at this time. Omit for no reminder.'},
  'repeat': {
    'type': 'string',
    'enum': ['none', 'daily', 'weekly'],
    'description': 'none = one-off (default)',
  },
  'weekdays': {
    'type': 'array',
    'items': {'type': 'string', 'enum': weekdayShort},
    'description': 'Required when repeat is weekly, e.g. ["mon","wed","fri"]',
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

final taskToolDefinitions = <Map<String, dynamic>>[
  _fn('create_task', 'Create a task in the user\'s planner. Use once per task.', _taskProps, ['title']),
  _fn('list_tasks', 'List the user\'s tasks with ids, schedules and completion status.', {
    'include_completed': {'type': 'boolean', 'description': 'Include finished one-off tasks (default false)'},
  }, []),
  _fn('update_task', 'Change an existing task. Only pass fields that should change.', {
    'id': {'type': 'string'},
    ..._taskProps,
  }, ['id']),
  _fn('complete_task', 'Mark a task done (for repeating tasks, done for the given date).', {
    'id': {'type': 'string'},
    'date': {'type': 'string', 'description': 'YYYY-MM-DD, defaults to today'},
  }, ['id']),
  _fn('delete_task', 'Delete a task permanently.', {
    'id': {'type': 'string'},
  }, ['id']),
];

class TaskTools {
  final TaskBackend backend;
  final DateTime Function() clock;

  /// Called for each change so the UI can show it (with undo).
  final void Function(ToolActivity activity)? onActivity;

  TaskTools(this.backend, {this.onActivity, DateTime Function()? clock}) : clock = clock ?? DateTime.now;

  Future<String> execute(ToolCall call) async {
    Map<String, dynamic> args;
    try {
      final decoded = jsonDecode(call.arguments.isEmpty ? '{}' : call.arguments);
      args = decoded is Map ? decoded.cast<String, dynamic>() : {};
    } on FormatException {
      return _err('Arguments were not valid JSON.');
    }
    switch (call.name) {
      case 'create_task':
        return _create(args);
      case 'list_tasks':
        return _list(args);
      case 'update_task':
        return _update(args);
      case 'complete_task':
        return _complete(args);
      case 'delete_task':
        return _delete(args);
      default:
        return _err('Unknown tool ${call.name}.');
    }
  }

  String _err(String m) => jsonEncode({'ok': false, 'error': m});

  Map<String, dynamic> _summary(Task t) => {
        'id': t.id,
        'title': t.title,
        if (t.notes.isNotEmpty) 'notes': t.notes,
        'schedule': t.describeSchedule(),
        'repeat': t.repeat.name,
        if (t.date != null) 'date': t.date,
        if (t.time != null) 'time': t.time,
        if (t.repeat == Repeat.weekly) 'weekdays': t.weekdays.map((d) => weekdayShort[d - 1]).toList(),
        'done_today': t.isDoneOn(clock()),
        if (!t.isRepeating) 'completed': t.isOneOffDone,
      };

  /// Validates schedule fields. Returns an error message, or null if valid.
  /// On success, fills [out] with normalized values for the keys present.
  String? _parseSchedule(Map<String, dynamic> a, Map<String, dynamic> out, {Repeat? existingRepeat}) {
    if (a.containsKey('date')) {
      final d = (a['date'] as String?)?.trim();
      if (d == null || d.isEmpty) {
        out['date'] = null;
      } else if (!isValidDate(d)) {
        return 'date must be YYYY-MM-DD';
      } else {
        out['date'] = d;
      }
    }
    if (a.containsKey('time')) {
      final raw = (a['time'] as String?)?.trim();
      if (raw == null || raw.isEmpty) {
        out['time'] = null;
      } else {
        final t = normalizeTime(raw);
        if (t == null) return 'time must be 24h HH:MM';
        out['time'] = t;
      }
    }
    if (a.containsKey('repeat')) {
      final r = Repeat.values.where((x) => x.name == a['repeat']).firstOrNull;
      if (r == null) return 'repeat must be none, daily or weekly';
      out['repeat'] = r;
    }
    if (a.containsKey('weekdays')) {
      final list = (a['weekdays'] as List? ?? const []).map((e) => e.toString().toLowerCase().trim()).toList();
      final days = <int>[];
      for (final w in list) {
        final i = weekdayShort.indexWhere((x) => w.startsWith(x));
        if (i < 0) return 'Unknown weekday "$w". Use mon..sun.';
        if (!days.contains(i + 1)) days.add(i + 1);
      }
      out['weekdays'] = days;
    }
    final repeat = out['repeat'] as Repeat? ?? existingRepeat ?? Repeat.none;
    if (repeat == Repeat.weekly && out.containsKey('weekdays') && (out['weekdays'] as List).isEmpty) {
      return 'weekdays must not be empty for weekly tasks';
    }
    return null;
  }

  Future<String> _create(Map<String, dynamic> a) async {
    final title = (a['title'] as String?)?.trim() ?? '';
    if (title.isEmpty) return _err('title is required');
    final f = <String, dynamic>{};
    final e = _parseSchedule(a, f);
    if (e != null) return _err(e);
    final repeat = f['repeat'] as Repeat? ?? Repeat.none;
    var weekdays = (f['weekdays'] as List<int>?) ?? <int>[];
    if (repeat == Repeat.weekly && weekdays.isEmpty) {
      // Default to the start date's weekday, or today's.
      final start = f['date'] == null ? clock() : DateTime.parse(f['date'] as String);
      weekdays = [start.weekday];
    }
    final t = await backend.addTask(
      title: title,
      notes: (a['notes'] as String?) ?? '',
      date: f['date'] as String?,
      time: f['time'] as String?,
      repeat: repeat,
      weekdays: repeat == Repeat.weekly ? weekdays : const [],
      byAi: true,
    );
    onActivity?.call(ToolActivity('Created “${t.title}” · ${t.describeSchedule()}', undo: () => backend.deleteTask(t)));
    return jsonEncode({'ok': true, 'task': _summary(t)});
  }

  Task? _find(Map<String, dynamic> a) {
    final id = a['id']?.toString();
    for (final t in backend.tasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  Future<String> _list(Map<String, dynamic> a) async {
    final includeDone = a['include_completed'] == true;
    final list = backend.tasks.where((t) => includeDone || !t.isOneOffDone).take(100).map(_summary).toList();
    return jsonEncode({'ok': true, 'count': list.length, 'tasks': list});
  }

  Future<String> _update(Map<String, dynamic> a) async {
    final t = _find(a);
    if (t == null) return _err('No task with id ${a['id']}. Call list_tasks to get ids.');
    final f = <String, dynamic>{};
    final e = _parseSchedule(a, f, existingRepeat: t.repeat);
    if (e != null) return _err(e);
    final before = t.copy();
    await backend.updateTask(t, (t) {
      final title = (a['title'] as String?)?.trim();
      if (title != null && title.isNotEmpty) t.title = title;
      if (a['notes'] is String) t.notes = (a['notes'] as String).trim();
      if (f.containsKey('date')) t.date = f['date'] as String?;
      if (f.containsKey('time')) t.time = f['time'] as String?;
      if (f.containsKey('repeat')) t.repeat = f['repeat'] as Repeat;
      if (f.containsKey('weekdays')) t.weekdays = f['weekdays'] as List<int>;
      if (t.repeat == Repeat.weekly && t.weekdays.isEmpty) t.weekdays = [clock().weekday];
    });
    onActivity?.call(ToolActivity('Updated “${t.title}” · ${t.describeSchedule()}', undo: () async {
      await backend.updateTask(t, (x) {
        x.title = before.title;
        x.notes = before.notes;
        x.date = before.date;
        x.time = before.time;
        x.repeat = before.repeat;
        x.weekdays = before.weekdays;
      });
    }));
    return jsonEncode({'ok': true, 'task': _summary(t)});
  }

  Future<String> _complete(Map<String, dynamic> a) async {
    final t = _find(a);
    if (t == null) return _err('No task with id ${a['id']}. Call list_tasks to get ids.');
    final d = (a['date'] as String?)?.trim();
    if (d != null && d.isNotEmpty && !isValidDate(d)) return _err('date must be YYYY-MM-DD');
    final day = (d == null || d.isEmpty) ? clock() : DateTime.parse(d);
    await backend.setTaskDone(t, day, true);
    onActivity?.call(ToolActivity('Completed “${t.title}”', undo: () => backend.setTaskDone(t, day, false)));
    return jsonEncode({'ok': true, 'task': _summary(t)});
  }

  Future<String> _delete(Map<String, dynamic> a) async {
    final t = _find(a);
    if (t == null) return _err('No task with id ${a['id']}. Call list_tasks to get ids.');
    await backend.deleteTask(t);
    onActivity?.call(ToolActivity('Deleted “${t.title}”', undo: () => backend.restoreTask(t)));
    return jsonEncode({'ok': true, 'deleted': t.id});
  }
}

/// Facts the planner needs to schedule sensibly: the current date and time,
/// the user's habit schedule and today's prayer times.
String plannerContext(Settings s, DateTime now) {
  final prayers = prayerTimesFor(s, now).times.entries.map((e) => '${e.key} ${DateFormat('HH:mm').format(e.value)}').join(', ');
  final tomorrow = DateTime(now.year, now.month, now.day + 1);
  final prayersTomorrow =
      prayerTimesFor(s, tomorrow).times.entries.map((e) => '${e.key} ${DateFormat('HH:mm').format(e.value)}').join(', ');
  return '''
Current local time: ${DateFormat('EEEE yyyy-MM-dd HH:mm').format(now)} (today is ${dayKey(now)}).
User's habits (tracked automatically, don't create tasks for these unless asked):
- Wake up by ${fmtHm(s.wakeTime)}
- Five daily prayers. Today: $prayers. Tomorrow: $prayersTomorrow.
- Articulation training ${s.trainingGoalMin} min/day, reminder at ${fmtHm(s.trainingTime)}.''';
}

const plannerSystemPrompt = '''
You are the planning assistant inside "Daily Discipline", a habit tracker
for someone building a disciplined routine: waking early, praying the five
daily prayers on time, and training their speech articulation.

You can manage the user's tasks with tools: create_task, list_tasks,
update_task, complete_task and delete_task.

Rules:
- When the user describes something to do, create the task(s) right away.
  Don't ask for confirmation. Ask a question only if something essential is
  truly ambiguous.
- Give a time whenever the user implies one, so they get a reminder. Resolve
  relative times ("tomorrow", "after Fajr", "before Maghrib", "tonight")
  using the context below. "After <prayer>" means about 15 minutes after that
  prayer's time.
- Use repeat "daily" or "weekly" for routines ("every morning", "on Mondays").
- To change, finish or delete a task, call list_tasks first to get its id.
- Before scheduling, consider prayer times and avoid clashing with them.
- Never invent task ids.
- After acting, reply with a short, friendly summary of what you did.
''';
