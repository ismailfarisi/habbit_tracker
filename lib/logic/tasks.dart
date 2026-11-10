import '../models.dart';
import 'stats.dart';

final _dateRe = RegExp(r'^\d{4}-\d{2}-\d{2}$');
final _timeRe = RegExp(r'^([01]?\d|2[0-3]):[0-5]\d$');

bool isValidDate(String s) => _dateRe.hasMatch(s) && DateTime.tryParse(s) != null;
bool isValidTime(String s) => _timeRe.hasMatch(s);

/// Normalizes "7:5" style input to "07:05"; returns null if invalid.
String? normalizeTime(String? s) {
  if (s == null || s.trim().isEmpty) return null;
  final m = RegExp(r'^(\d{1,2}):(\d{1,2})$').firstMatch(s.trim());
  if (m == null) return null;
  final h = int.parse(m.group(1)!), min = int.parse(m.group(2)!);
  if (h > 23 || min > 59) return null;
  return '${h.toString().padLeft(2, '0')}:${min.toString().padLeft(2, '0')}';
}

extension TaskSchedule on Task {
  bool get isRepeating => repeat != Repeat.none;

  /// One-off task finished (on any day).
  bool get isOneOffDone => !isRepeating && doneDates.isNotEmpty;

  bool isDoneOn(DateTime day) => isRepeating ? doneDates.contains(dayKey(day)) : doneDates.isNotEmpty;

  /// Whether the task is scheduled to happen on [day].
  bool isScheduledOn(DateTime day) {
    final key = dayKey(day);
    if (!isRepeating) return date == key;
    if (date != null && key.compareTo(date!) < 0) return false;
    if (repeat == Repeat.daily) return true;
    return weekdays.contains(day.weekday);
  }

  /// When the task's reminder fires on [day], if it has a time.
  DateTime? reminderOn(DateTime day) {
    if (time == null) return null;
    final t = parseHm(time!);
    return DateTime(day.year, day.month, day.day, t.hour, t.minute);
  }

  String describeSchedule() {
    final at = time == null ? '' : ' at $time';
    switch (repeat) {
      case Repeat.none:
        return date == null ? 'Anytime$at' : '$date$at';
      case Repeat.daily:
        return 'Every day$at';
      case Repeat.weekly:
        final days = (weekdays.toList()..sort()).map((d) => weekdayShort[d - 1]).join(', ');
        return 'Every $days$at';
    }
  }
}

/// Tasks to show for [day]. For today this also includes undated and
/// overdue unfinished one-off tasks, plus one-offs finished today.
List<Task> tasksForDay(List<Task> tasks, DateTime day, {DateTime? today}) {
  final todayKey = dayKey(today ?? DateTime.now());
  final key = dayKey(day);
  final isToday = key == todayKey;
  final out = tasks.where((t) {
    if (t.isScheduledOn(day)) return true;
    if (!isToday || t.isRepeating) return false;
    if (t.doneDates.contains(key)) return true; // finished today
    if (t.isOneOffDone) return false;
    return t.date == null || t.date!.compareTo(key) < 0; // anytime or overdue
  }).toList();
  out.sort(_byTime);
  return out;
}

int _byTime(Task a, Task b) {
  if (a.time == null && b.time == null) return a.createdAt.compareTo(b.createdAt);
  if (a.time == null) return 1;
  if (b.time == null) return -1;
  return a.time!.compareTo(b.time!);
}

bool isOverdue(Task t, DateTime today) =>
    !t.isRepeating && !t.isOneOffDone && t.date != null && t.date!.compareTo(dayKey(today)) < 0;

/// Future-dated one-off tasks, soonest first.
List<Task> upcomingTasks(List<Task> tasks, DateTime today) {
  final key = dayKey(today);
  return tasks.where((t) => !t.isRepeating && !t.isOneOffDone && t.date != null && t.date!.compareTo(key) > 0).toList()
    ..sort((a, b) => '${a.date} ${a.time ?? '99'}'.compareTo('${b.date} ${b.time ?? '99'}'));
}

int nextTaskSeq(List<Task> tasks) => tasks.fold(0, (m, t) => t.seq > m ? t.seq : m) + 1;

String newTaskId() => DateTime.now().microsecondsSinceEpoch.toRadixString(36);
