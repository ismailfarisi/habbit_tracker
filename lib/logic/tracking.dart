import '../goals/goal.dart';
import '../models.dart';

/// Linked practices and tasks follow their goal card's visibility on Today.
bool tracksItem(
  Settings settings,
  Iterable<Goal> goals,
  String id, {
  bool task = false,
}) {
  for (final goal in goals) {
    if (!goal.archived && (task ? goal.taskIds : goal.habitIds).contains(id)) {
      return settings.tracks('goal-${goal.id}');
    }
  }
  return settings.tracks(task ? 'tasks' : id);
}
