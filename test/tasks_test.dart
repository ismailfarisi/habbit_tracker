import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:habit_tracker/logic/stats.dart';
import 'package:habit_tracker/logic/tasks.dart';
import 'package:habit_tracker/models.dart';
import 'package:habit_tracker/services/openrouter.dart';
import 'package:habit_tracker/services/reminders.dart';
import 'package:habit_tracker/services/task_tools.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// In-memory stand-in for AppState's task methods.
class FakeBackend implements TaskBackend {
  @override
  final List<Task> tasks = [];

  @override
  Future<Task> addTask({
    required String title,
    String notes = '',
    String? date,
    String? time,
    Repeat repeat = Repeat.none,
    List<int> weekdays = const [],
    bool byAi = false,
  }) async {
    final t = Task(
      id: 't${tasks.length + 1}',
      seq: nextTaskSeq(tasks),
      title: title,
      notes: notes,
      date: date,
      time: time,
      repeat: repeat,
      weekdays: List.of(weekdays),
      createdByAi: byAi,
    );
    tasks.add(t);
    return t;
  }

  @override
  Future<void> updateTask(Task t, void Function(Task t) change) async => change(t);

  @override
  Future<void> setTaskDone(Task t, DateTime day, bool done) async =>
      done ? t.doneDates.add(dayKey(day)) : t.doneDates.remove(dayKey(day));

  @override
  Future<void> deleteTask(Task t) async => tasks.removeWhere((x) => x.id == t.id);

  @override
  Future<void> restoreTask(Task t) async => tasks.add(t);
}

Task task(String id, {String? date, String? time, Repeat repeat = Repeat.none, List<int>? weekdays, int seq = 1}) =>
    Task(id: id, seq: seq, title: id, date: date, time: time, repeat: repeat, weekdays: weekdays);

void main() {
  final now = DateTime(2026, 11, 10, 9, 0); // a Tuesday

  group('task schedule', () {
    test('one-off, daily and weekly', () {
      expect(task('a', date: '2026-11-10').isScheduledOn(now), isTrue);
      expect(task('a', date: '2026-11-11').isScheduledOn(now), isFalse);
      expect(task('d', repeat: Repeat.daily).isScheduledOn(now), isTrue);
      expect(task('d', repeat: Repeat.daily, date: '2026-11-12').isScheduledOn(now), isFalse, reason: 'not started yet');
      expect(task('w', repeat: Repeat.weekly, weekdays: [2]).isScheduledOn(now), isTrue);
      expect(task('w', repeat: Repeat.weekly, weekdays: [1, 3]).isScheduledOn(now), isFalse);
    });

    test('today shows anytime, overdue and finished-today tasks', () {
      final tasks = [
        task('today', date: '2026-11-10', time: '18:00'),
        task('anytime'),
        task('overdue', date: '2026-11-08'),
        task('future', date: '2026-11-12'),
        task('doneEarlier', date: '2026-11-01')..doneDates.add('2026-11-01'),
        task('doneToday')..doneDates.add('2026-11-10'),
        task('daily', repeat: Repeat.daily, time: '06:00'),
      ];
      final ids = tasksForDay(tasks, now, today: now).map((t) => t.id).toList();
      expect(ids, ['daily', 'today', 'anytime', 'overdue', 'doneToday']);
      expect(isOverdue(tasks[2], now), isTrue);
      expect(upcomingTasks(tasks, now).map((t) => t.id), ['future']);
    });

    test('repeating completion is per day', () {
      final t = task('d', repeat: Repeat.daily)..doneDates.add('2026-11-10');
      expect(t.isDoneOn(now), isTrue);
      expect(t.isDoneOn(DateTime(2026, 11, 11)), isFalse);
    });

    test('json round trip', () {
      final t = task('x', date: '2026-11-10', time: '07:30', repeat: Repeat.weekly, weekdays: [1, 5])
        ..doneDates.add('2026-11-03');
      expect(Task.fromJson(jsonDecode(jsonEncode(t.toJson())) as Map<String, dynamic>).toJson(), t.toJson());
    });

    test('normalizeTime', () {
      expect(normalizeTime('7:5'), '07:05');
      expect(normalizeTime('24:00'), isNull);
      expect(normalizeTime('soon'), isNull);
    });
  });

  group('task reminders', () {
    test('scheduled for timed, unfinished tasks only', () {
      final s = Settings(useManualPrayer: true, remindersEnabled: true);
      final tasks = [
        task('timed', date: '2026-11-10', time: '20:00', seq: 1),
        task('untimed', date: '2026-11-10', seq: 2),
        task('done', date: '2026-11-10', time: '21:00', seq: 3)..doneDates.add('2026-11-10'),
        task('daily', repeat: Repeat.daily, time: '22:00', seq: 4),
      ];
      final plan = planReminders(s, {}, now, tasks: tasks).where((r) => r.kind == ReminderKind.task).toList();
      expect(plan.where((r) => r.payload.startsWith('task:timed')).length, 1);
      expect(plan.where((r) => r.payload.startsWith('task:untimed')), isEmpty);
      expect(plan.where((r) => r.payload.startsWith('task:done')), isEmpty);
      expect(plan.where((r) => r.payload.startsWith('task:daily')).length, scheduleDays);
      final ids = planReminders(s, {}, now, tasks: tasks).map((r) => r.id).toList();
      expect(ids.toSet().length, ids.length, reason: 'no id collisions with habit reminders');
      expect(ids.every((id) => id < (1 << 31)), isTrue);
    });

    test('done action from notification', () {
      final tasks = [task('abc')];
      expect(applyTaskDoneAction('task:abc|2026-11-10', tasks), isTrue);
      expect(tasks.first.isOneOffDone, isTrue);
      expect(applyTaskDoneAction('task:missing|2026-11-10', tasks), isFalse);
      expect(applyTaskDoneAction('prayer:Fajr|2026-11-10', tasks), isFalse);
    });
  });

  group('AI task tools', () {
    late FakeBackend backend;
    late List<ToolActivity> activity;
    late TaskTools tools;
    setUp(() {
      backend = FakeBackend();
      activity = [];
      tools = TaskTools(backend, onActivity: activity.add, clock: () => now);
    });
    Future<Map<String, dynamic>> run(String name, Map<String, dynamic> args) async =>
        jsonDecode(await tools.execute(ToolCall('c1', name, jsonEncode(args)))) as Map<String, dynamic>;

    test('create one-off task with reminder', () async {
      final r = await run('create_task', {'title': 'Call mom', 'date': '2026-11-11', 'time': '20:00'});
      expect(r['ok'], isTrue);
      final t = backend.tasks.single;
      expect([t.title, t.date, t.time, t.repeat, t.createdByAi], ['Call mom', '2026-11-11', '20:00', Repeat.none, true]);
      expect(activity.single.label, contains('Call mom'));
    });

    test('create weekly task from weekday names', () async {
      await run('create_task', {'title': 'Gym', 'repeat': 'weekly', 'weekdays': ['mon', 'Wednesday', 'fri'], 'time': '18:00'});
      expect(backend.tasks.single.weekdays, [1, 3, 5]);
    });

    test('weekly without weekdays defaults to today', () async {
      await run('create_task', {'title': 'Review', 'repeat': 'weekly'});
      expect(backend.tasks.single.weekdays, [DateTime.tuesday]);
    });

    test('rejects bad input with an error the model can read', () async {
      expect((await run('create_task', {'title': ''}))['ok'], isFalse);
      expect((await run('create_task', {'title': 'x', 'time': '25:00'}))['error'], contains('HH:MM'));
      expect((await run('create_task', {'title': 'x', 'date': 'tomorrow'}))['error'], contains('YYYY-MM-DD'));
      expect((await run('nope', {}))['ok'], isFalse);
      expect(jsonDecode(await tools.execute(const ToolCall('c', 'create_task', '{bad'))) ['ok'], isFalse);
      expect(backend.tasks, isEmpty);
    });

    test('list, update, complete, delete and undo', () async {
      await run('create_task', {'title': 'Read', 'time': '21:00'});
      final id = backend.tasks.single.id;
      final listed = await run('list_tasks', {});
      expect((listed['tasks'] as List).single['id'], id);

      await run('update_task', {'id': id, 'time': '21:30', 'repeat': 'daily'});
      expect([backend.tasks.single.time, backend.tasks.single.repeat], ['21:30', Repeat.daily]);
      await activity.last.undo!();
      expect([backend.tasks.single.time, backend.tasks.single.repeat], ['21:00', Repeat.none]);

      await run('complete_task', {'id': id});
      expect(backend.tasks.single.isDoneOn(now), isTrue);

      await run('delete_task', {'id': id});
      expect(backend.tasks, isEmpty);
      await activity.last.undo!();
      expect(backend.tasks.single.id, id);

      expect((await run('delete_task', {'id': 'missing'}))['error'], contains('list_tasks'));
    });
  });

  group('agent loop', () {
    http.StreamedResponse sse(List<Map<String, dynamic>> deltas) => http.StreamedResponse(
          Stream.fromIterable([
            for (final d in deltas)
              utf8.encode('data: ${jsonEncode({
                    'choices': [
                      {'delta': d},
                    ],
                  })}\n\n'),
            utf8.encode('data: [DONE]\n\n'),
          ]),
          200,
        );

    test('streams tool call arguments, executes them, then answers', () async {
      final bodies = <Map<String, dynamic>>[];
      final client = MockClient.streaming((req, body) async {
        bodies.add(jsonDecode(await body.bytesToString()) as Map<String, dynamic>);
        if (bodies.length == 1) {
          return sse([
            {
              'tool_calls': [
                {
                  'index': 0,
                  'id': 'call_1',
                  'type': 'function',
                  'function': {'name': 'create_task', 'arguments': '{"title":"Read Qu'},
                },
              ],
            },
            {
              'tool_calls': [
                {
                  'index': 0,
                  'function': {'arguments': 'ran","time":"06:15","repeat":"daily"}'},
                },
              ],
            },
          ]);
        }
        return sse([
          {'content': 'Done! '},
          {'content': 'Added a daily reminder.'},
        ]);
      });

      final backend = FakeBackend();
      final tools = TaskTools(backend, clock: () => now);
      final history = [const ChatMessage('user', 'Read Quran after Fajr daily')];
      final text = StringBuffer();
      final reply = await OpenRouterClient(apiKey: 'k', model: 'm', client: client).runAgent(
        history,
        system: 'sys',
        tools: taskToolDefinitions,
        execute: tools.execute,
        onText: text.write,
      );

      expect(reply, 'Done! Added a daily reminder.');
      expect(text.toString(), reply);
      final t = backend.tasks.single;
      expect([t.title, t.time, t.repeat], ['Read Quran', '06:15', Repeat.daily]);

      // First request offered the tools; second carried the tool result back.
      expect((bodies[0]['tools'] as List).length, taskToolDefinitions.length);
      final msgs = bodies[1]['messages'] as List;
      expect(msgs.first['role'], 'system');
      expect(msgs[2]['tool_calls'][0]['function']['name'], 'create_task');
      expect(msgs[2]['content'], isNull);
      expect(msgs[3]['role'], 'tool');
      expect(msgs[3]['tool_call_id'], 'call_1');
      expect(jsonDecode(msgs[3]['content'] as String)['ok'], isTrue);
      expect(history.map((m) => m.role), ['user', 'assistant', 'tool', 'assistant']);
    });

    test('explains when a model has no tool support', () {
      final msg = errorMessage(404, '{"error":{"message":"No endpoints found that support tool use"}}', usedTools: true);
      expect(msg, contains("can't create tasks"));
    });
  });
}
