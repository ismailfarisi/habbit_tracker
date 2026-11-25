/// Local calendar days on which linked work is suspended. The restore day is
/// available again. Pause history lives on the goal, alongside its ownership.
class GoalPause {
  final String start;
  final String? end;
  const GoalPause(this.start, [this.end]);

  bool contains(DateTime day) {
    final date = DateTime(day.year, day.month, day.day);
    return !date.isBefore(DateTime.parse(start)) && (end == null || date.isBefore(DateTime.parse(end!)));
  }

  Map<String, dynamic> toJson() => {'start': start, if (end != null) 'end': end};
}
