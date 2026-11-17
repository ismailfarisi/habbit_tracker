import 'dart:convert';

import 'package:flutter/material.dart';

import '../app_state.dart';
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

const _date = {'type': 'string', 'description': 'YYYY-MM-DD; default today. Past days are allowed.'};
const _time = {'type': 'string', 'description': '24-hour HH:mm'};

/// Tools for the core app (prayers, wake-up, progress), next to the task
/// and habit tools.
final appToolDefinitions = <Map<String, dynamic>>[
  _fn('log_prayer', 'Mark one of the five daily prayers for a day, including past days.', {
    'date': _date,
    'prayer': {'type': 'string', 'enum': prayerNames},
    'status': {
      'type': 'string',
      'enum': [...prayerStatuses, 'none'],
      'description': 'onTime, late, qada, or none to clear it',
    },
  }, ['prayer', 'status']),
  _fn('log_wake', 'Record when the user got up on a day.', {'date': _date, 'time': _time}, ['time']),
  _fn('set_wake_time', "Change the user's daily wake-up goal.", {'time': _time}, ['time']),
  _fn('get_stats', 'Summary of the last 7 and 30 days: wake-ups logged, prayers done and habits done.', {}, []),
];

final appToolNames = {for (final t in appToolDefinitions) (t['function'] as Map)['name'] as String};

class AppTools {
  final AppState state;
  final void Function(ToolActivity activity)? onActivity;
  final DateTime Function() clock;
  AppTools(this.state, {this.onActivity, DateTime Function()? clock}) : clock = clock ?? DateTime.now;

  DateTime _day(Object? s) {
    final d = s is String ? DateTime.tryParse(s) : null;
    return dateOnly(d ?? clock());
  }

  TimeOfDay? _tod(Object? s) {
    final m = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch('${s ?? ''}');
    if (m == null) return null;
    final h = int.parse(m.group(1)!), min = int.parse(m.group(2)!);
    return h < 24 && min < 60 ? TimeOfDay(hour: h, minute: min) : null;
  }

  Future<String> execute(ToolCall call) async {
    final a = call.arguments.trim().isEmpty ? <String, dynamic>{} : jsonDecode(call.arguments) as Map<String, dynamic>;
    switch (call.name) {
      case 'log_prayer':
        final p = a['prayer'] as String?;
        if (!prayerNames.contains(p)) return jsonEncode({'error': 'unknown prayer $p'});
        final day = _day(a['date']);
        final log = state.logFor(day);
        final prev = log.prayers.contains(p) ? (log.prayerStatus[p] ?? prayerOnTime) : null;
        final status = a['status'] == 'none' ? null : a['status'] as String?;
        await state.setPrayerStatus(day, p!, status);
        onActivity?.call(
          ToolActivity(
            status == null ? 'Cleared $p on ${dayKey(day)}' : 'Marked $p $status on ${dayKey(day)}',
            undo: () => state.setPrayerStatus(day, p, prev),
          ),
        );
        return jsonEncode({'ok': true});
      case 'log_wake':
        final t = _tod(a['time']);
        if (t == null) return jsonEncode({'error': 'time must be HH:mm'});
        final day = _day(a['date']);
        final prev = state.logFor(day).wakeAt;
        await state.setWake(day, DateTime(day.year, day.month, day.day, t.hour, t.minute));
        onActivity?.call(ToolActivity('Logged wake-up ${a['time']} on ${dayKey(day)}', undo: () => state.setWake(day, prev)));
        return jsonEncode({'ok': true});
      case 'set_wake_time':
        final t = _tod(a['time']);
        if (t == null) return jsonEncode({'error': 'time must be HH:mm'});
        final prev = state.settings.wakeTime;
        await state.updateSettings((s) => s.wakeTime = t);
        onActivity?.call(
          ToolActivity('Wake-up goal set to ${a['time']}', undo: () => state.updateSettings((s) => s.wakeTime = prev)),
        );
        return jsonEncode({'ok': true});
      case 'get_stats':
        Map<String, int> range(int days) {
          var wake = 0, prayers = 0, habits = 0;
          final today = dateOnly(clock());
          for (var i = 0; i < days; i++) {
            final log = state.logs[dayKey(today.subtract(Duration(days: i)))];
            if (log == null) continue;
            if (log.wakeAt != null) wake++;
            prayers += log.prayers.length;
            habits += log.habits.values.where((e) => e.done).length;
          }
          return {'days': days, 'wakeUpsLogged': wake, 'prayersDone': prayers, 'habitCheckIns': habits};
        }
        return jsonEncode({'last7': range(7), 'last30': range(30)});
    }
    return jsonEncode({'error': 'unknown tool ${call.name}'});
  }
}
