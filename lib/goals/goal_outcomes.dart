import '../app_state.dart';
import '../finance/finance.dart';
import '../logic/tasks.dart';
import '../logic/stats.dart';
import '../models.dart';
import 'goal.dart';

/// Distinct measures stay in their own units instead of averaging unrelated targets.
class GoalOutcome {
  final String label;
  final double? fraction;
  final SavingsPot? pot;
  final Finance? ledger;
  const GoalOutcome(this.label, [this.fraction, this.pot, this.ledger]);
}

List<GoalOutcome> goalOutcomes(AppState state, Goal goal, DateTime at, {bool includeSavings = false}) {
  final outcomes = <GoalOutcome>[];
  void practice(String name, TaskGuide? guide, QuranRef? q, int done) {
    if (q != null) {
      final total = q.to - q.from + 1;
      if (total > 0) {
        final covered = q.covered(done);
        final verb = switch (q.mode) {
          'memorise' => 'learned',
          'revise' => 'revised',
          _ => 'read',
        };
        outcomes.add(GoalOutcome('$name · $covered of $total ayat $verb', covered / total));
      }
    }
    final sessions = guide?.sessions.length ?? 0;
    if (sessions > 0) {
      final finished = (done - guide!.sessionStart).clamp(0, sessions);
      outcomes.add(GoalOutcome('$name · $finished of $sessions sessions', finished / sessions));
    } else if (q == null) {
      outcomes.add(GoalOutcome('$name · $done practice ${done == 1 ? 'day' : 'days'}'));
    }
  }

  for (final h in state.habits.where((h) => goal.habitIds.contains(h.id))) {
    practice(h.title, h.guide, h.guide?.quran, state.habitDaysDoneBefore(h, DateTime(at.year, at.month, at.day + 1)));
  }
  final tasks = state.tasks.where((t) => goal.taskIds.contains(t.id));
  for (final task in tasks.where((t) => t.isRepeating || t.guide?.quran != null)) {
    practice(
      task.title,
      task.guide,
      state.quranPlanForTask(task),
      task.doneDates.where((day) => day.compareTo(dayKey(at)) <= 0).length,
    );
  }
  for (final ledger in state.finance.ledgers.where((_) => includeSavings)) {
    for (final pot in ledger.pots.where((p) => p.goalId == goal.id && !p.archived)) {
    final saved = ledger.potSaved(pot.id);
    final fmt = ledger.fmt;
    outcomes.add(
      GoalOutcome(
        '${pot.name} · ${fmt(saved)} of ${fmt(pot.target)} saved',
        pot.target <= 0 ? null : (saved / pot.target).clamp(0, 1),
        pot,
        ledger,
      ),
    );
    }
  }
  final oneOff = tasks.where((t) => !t.isRepeating);
  if (oneOff.isNotEmpty) {
    final done = oneOff.where((t) => t.doneDates.any((d) => d.compareTo(dayKey(at)) <= 0)).length;
    outcomes.add(GoalOutcome('$done of ${oneOff.length} tasks', done / oneOff.length));
  }
  if (goal.milestones.isNotEmpty) {
    outcomes.add(
      GoalOutcome(
        '${goal.milestonesDone} of ${goal.milestones.length} milestones',
        goal.milestonesDone / goal.milestones.length,
      ),
    );
  }
  return outcomes;
}
