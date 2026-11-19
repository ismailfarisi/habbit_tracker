import '../logic/stats.dart';
import '../models.dart';
import '../logic/tasks.dart';

/// How often the AI looks back at a goal with the user.
enum ReviewCadence { weekly, monthly, quarterly }

class Milestone {
  final String id;
  String title;
  String? due; // yyyy-MM-dd
  bool done;
  Milestone({required this.id, required this.title, this.due, this.done = false});

  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'due': due, 'done': done};
  factory Milestone.fromJson(Map<String, dynamic> j) => Milestone(
    id: j['id'] as String,
    title: j['title'] as String? ?? '',
    due: j['due'] as String?,
    done: j['done'] as bool? ?? false,
  );
}

/// One look back at a goal: what went well, and gentle suggestions.
class GoalReview {
  final DateTime at;
  final String summary;
  final List<String> suggestions;
  final Set<int> applied;
  GoalReview({required this.at, required this.summary, this.suggestions = const [], Set<int>? applied})
    : applied = applied ?? <int>{};

  Map<String, dynamic> toJson() => {
    'at': at.toIso8601String(),
    'summary': summary,
    'suggestions': suggestions,
    'applied': applied.toList(),
  };
  factory GoalReview.fromJson(Map<String, dynamic> j) => GoalReview(
    at: DateTime.tryParse(j['at'] as String? ?? '') ?? DateTime.now(),
    summary: j['summary'] as String? ?? '',
    suggestions: ((j['suggestions'] as List?) ?? const []).cast<String>(),
    applied: ((j['applied'] as List?) ?? const []).map((e) => (e as num).toInt()).toSet(),
  );
}

/// A goal of any length (a week to several years), broken into milestones,
/// with the tasks and habits that move it forward.
class Goal {
  final String id;
  String title;
  String why;
  String emoji;
  final String start; // yyyy-MM-dd
  String end; // yyyy-MM-dd
  ReviewCadence cadence;
  List<Milestone> milestones;
  List<String> taskIds;
  List<String> habitIds;
  List<GoalReview> reviews;
  bool archived;

  Goal({
    required this.id,
    required this.title,
    this.why = '',
    this.emoji = '🎯',
    required this.start,
    required this.end,
    this.cadence = ReviewCadence.weekly,
    List<Milestone>? milestones,
    List<String>? taskIds,
    List<String>? habitIds,
    List<GoalReview>? reviews,
    this.archived = false,
  }) : milestones = milestones ?? [],
       taskIds = taskIds ?? [],
       habitIds = habitIds ?? [],
       reviews = reviews ?? [];

  DateTime get startDate => DateTime.tryParse(start) ?? DateTime.now();
  DateTime get endDate => DateTime.tryParse(end) ?? startDate;
  int get totalDays => endDate.difference(startDate).inDays.clamp(1, 100000);

  /// Fraction of the timeline that has passed.
  double elapsed(DateTime now) => (dateOnly(now).difference(startDate).inDays / totalDays).clamp(0.0, 1.0);

  int get milestonesDone => milestones.where((m) => m.done).length;

  /// Progress from milestones; without milestones, from finished linked one-off tasks.
  double progress(List<Task> tasks) {
    if (milestones.isNotEmpty) return milestonesDone / milestones.length;
    final linked = tasks.where((t) => taskIds.contains(t.id) && !t.isRepeating).toList();
    if (linked.isEmpty) return 0;
    return linked.where((t) => t.doneDates.isNotEmpty).length / linked.length;
  }

  Duration get cadenceLength => switch (cadence) {
    ReviewCadence.weekly => const Duration(days: 7),
    ReviewCadence.monthly => const Duration(days: 30),
    ReviewCadence.quarterly => const Duration(days: 91),
  };

  DateTime get lastLookBack => reviews.isEmpty ? startDate : reviews.last.at;

  bool reviewDue(DateTime now) => !archived && !now.isBefore(lastLookBack.add(cadenceLength));

  String get horizon {
    final d = totalDays;
    if (d <= 10) return 'This week';
    if (d <= 45) return '${(d / 7).round()} weeks';
    if (d <= 400) return '${(d / 30).round()} months';
    return '${(d / 365).toStringAsFixed(d % 365 < 30 ? 0 : 1)} years';
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'why': why,
    'emoji': emoji,
    'start': start,
    'end': end,
    'cadence': cadence.name,
    'milestones': milestones.map((m) => m.toJson()).toList(),
    'taskIds': taskIds,
    'habitIds': habitIds,
    'reviews': reviews.map((r) => r.toJson()).toList(),
    'archived': archived,
  };

  factory Goal.fromJson(Map<String, dynamic> j) => Goal(
    id: j['id'] as String,
    title: j['title'] as String? ?? '',
    why: j['why'] as String? ?? '',
    emoji: j['emoji'] as String? ?? '🎯',
    start: j['start'] as String? ?? dayKey(DateTime.now()),
    end: j['end'] as String? ?? dayKey(DateTime.now()),
    cadence: ReviewCadence.values.firstWhere((c) => c.name == j['cadence'], orElse: () => ReviewCadence.weekly),
    milestones: [for (final m in (j['milestones'] as List? ?? const [])) Milestone.fromJson((m as Map).cast())],
    taskIds: ((j['taskIds'] as List?) ?? const []).cast<String>(),
    habitIds: ((j['habitIds'] as List?) ?? const []).cast<String>(),
    reviews: [for (final r in (j['reviews'] as List? ?? const [])) GoalReview.fromJson((r as Map).cast())],
    archived: j['archived'] as bool? ?? false,
  );

  Goal copy() => Goal.fromJson(toJson());
}

/// The cadence that fits a goal's length: weekly up to ~3 months, monthly up
/// to ~a year, quarterly beyond.
ReviewCadence cadenceFor(int days) => days <= 100
    ? ReviewCadence.weekly
    : days <= 400
    ? ReviewCadence.monthly
    : ReviewCadence.quarterly;
