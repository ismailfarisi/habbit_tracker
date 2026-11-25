import 'dart:convert';

import '../app_state.dart';
import '../goals/goal.dart';
import '../goals/goal_okf.dart';
import '../services/openrouter.dart';

enum CoachMoney { none, totals, details }

typedef ReviewChanges = Future<bool> Function(List<ToolCall> changes);

/// The local records explicitly selected in one conversation. The same
/// object controls prompt construction, tool advertisement and dispatch.
class CoachAccess {
  final AppState state;
  final Set<String> goalIds;
  final CoachMoney money;
  final bool planner;

  CoachAccess(this.state, {Iterable<String> goals = const [], this.money = CoachMoney.none, this.planner = false})
      : goalIds = Set.unmodifiable(goals);

  Iterable<Goal> get goals => state.goals.where((g) => goalIds.contains(g.id));

  bool _record(String id, List<String> Function(Goal) ids) {
    final owners = state.goals.where((g) => ids(g).contains(id));
    return owners.isEmpty ? planner : owners.any((g) => goalIds.contains(g.id));
  }

  bool task(String id) => _record(id, (g) => g.taskIds);
  bool habit(String id) => _record(id, (g) => g.habitIds);

  String totals(DateTime now) {
    final finance = state.finance;
    final m = finance.month(now);
    return 'Money this month: income ${finance.fmt(m.income)}, spent ${finance.fmt(m.spent)}, '
        'saved ${finance.fmt(m.saved)}, sadaqah ${finance.fmt(m.sadaqah)}.';
  }

  String redactPeople(String text) {
    for (final debt in state.finance.ledgers.where((ledger) =>
        money != CoachMoney.details || ledger.currency != state.finance.currency).expand((ledger) => ledger.debts)) {
      final name = debt.person.trim();
      if (name.isNotEmpty) text = text.replaceAll(RegExp(RegExp.escape(name), caseSensitive: false), '[person]');
    }
    return text;
  }

  String toolResult(String result) {
    Object? redact(Object? value) => switch (value) {
      String s => redactPeople(s),
      List list => list.map(redact).toList(),
      Map map => {for (final e in map.entries) redactPeople(e.key as String): redact(e.value)},
      _ => value,
    };
    return jsonEncode(redact(jsonDecode(result)));
  }

  String context(DateTime now) => [
    for (final g in goals) redactPeople(goalOkf(state, g, now)),
    if (money == CoachMoney.totals) totals(now),
    if (money == CoachMoney.details) state.finance.summary(now),
  ].join('\n\n');

  static const readOnly = {'list_tasks', 'list_habits', 'get_habit_history', 'get_stats', 'list_goals', 'money_summary'};

  bool advertises(String name) => switch (name) {
    'money_summary' => money != CoachMoney.none,
    'add_debt' || 'update_zakat' || 'set_budget' || 'log_money' || 'create_savings_pot' || 'set_currency'
        => money == CoachMoney.details,
    'list_goals' || 'update_goal' || 'save_goal_review' => goals.isNotEmpty,
    'list_tasks' || 'list_habits' || 'get_habit_history' || 'update_habit' || 'log_habit' || 'set_habit_ui' ||
    'archive_habit' || 'complete_task' || 'update_task' || 'delete_task' => planner || goals.isNotEmpty,
    'get_stats' || 'customize_today' => planner,
    'create_goal' || 'create_task' || 'create_habit' || 'update_settings' || 'log_prayer' || 'log_wake' ||
    'set_wake_time' => true,
    _ => false,
  };

  bool _todayCard(String id) {
    if (id == 'money') return money != CoachMoney.none;
    if (id.startsWith('goal-')) return goalIds.contains(id.substring(5));
    return const {'wake', 'prayers', 'tasks'}.contains(id) || (state.habitById(id) != null && habit(id));
  }

  /// Verify even calls the provider made without an advertised definition.
  bool allows(ToolCall call) {
    if (!advertises(call.name)) return false;
    final Object? args;
    try {
      args = jsonDecode(call.arguments.isEmpty ? '{}' : call.arguments);
    } on FormatException {
      return false;
    }
    if (args is! Map) return false;
    final fields = args;
    bool allowedList(String key, bool Function(String) allowed) {
      final values = fields[key];
      return values == null || (values is List && values.every((v) => v is String && allowed(v)));
    }
    final id = args['id'];
    return switch (call.name) {
      'update_goal' || 'save_goal_review' =>
        goalIds.contains(id) && allowedList('link_task_ids', task) && allowedList('link_habit_ids', habit),
      'create_savings_pot' => args['goal_id'] == null || goalIds.contains(args['goal_id']),
      'update_task' || 'complete_task' || 'delete_task' => id is String && task(id),
      'update_habit' || 'archive_habit' || 'log_habit' || 'get_habit_history' || 'set_habit_ui' => id is String && habit(id),
      // Replacing the entire pin order also unpins omitted cards.
      'customize_today' => ['show', 'hide', 'pin'].every((k) => allowedList(k, _todayCard)) &&
          (args['pin'] == null || state.settings.todayPinned.every(_todayCard)),
      _ => true,
    };
  }

  bool needsReview(ToolCall call) => !readOnly.contains(call.name) && call.name != 'create_habit';
}
