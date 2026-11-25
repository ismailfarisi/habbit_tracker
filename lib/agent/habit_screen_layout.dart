import '../habits/habit.dart';
import 'habit_catalog.dart';

/// Upgrade the original articulation template in memory. Use the saved passage
/// and steps, and leave custom layouts and the backed-up definition intact.
Map<String, dynamic> editableHabitSurface(HabitDef habit) {
  final message = normalizeHabitSurface(habit.uiSurface);
  if (habit.templateId != 'articulation' && habit.id != articulationHabitId) return message;
  final nodes = (message['createSurface']['components'] as List).cast<Map<String, dynamic>>();
  final byId = {for (final n in nodes) n['id']: n};
  final root = byId['root'], warmup = byId['warmup'], drill = byId['drill'], timer = byId['timer'];
  if (root?['component'] != 'Column' ||
      warmup?['component'] != 'PromptCard' ||
      drill?['component'] != 'ReadAloudDrill' ||
      timer?['component'] != 'PracticeTimer' ||
      byId.containsKey('practice')) {
    return message;
  }
  final children = root!['children'];
  if (children is! List ||
      children.length < 3 ||
      children[0] != 'warmup' ||
      children[1] != 'drill' ||
      children[2] != 'timer') {
    return message;
  }
  final practice = {
    ...drill!,
    'id': 'practice',
    'component': 'SpeakingPractice',
    'warmupTitle': warmup!['title'] ?? 'Warm-up',
    'steps': [if (warmup['body'] is String) warmup['body'], ...?warmup['steps'] as List?],
  };
  try {
    return normalizeHabitSurface([
      {
        ...root,
        'children': ['practice', ...children.skip(3)],
      },
      practice,
      ...nodes.where((n) => !const {'root', 'warmup', 'drill', 'timer'}.contains(n['id'])),
    ]);
  } on HabitSurfaceError {
    // A custom branch can still refer to one of the original components.
    return message;
  }
}
