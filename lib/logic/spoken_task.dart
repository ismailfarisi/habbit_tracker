/// Pulls a date, time and repeat out of a dictated task like
/// "Remind me to call mum tomorrow at 5 pm" or "Read Quran every day at 6".
library;

import '../models.dart';
import 'stats.dart';

class SpokenTask {
  final String title;
  final String? date; // yyyy-MM-dd
  final String? time; // HH:mm
  final Repeat repeat;
  final List<int> weekdays;
  const SpokenTask({required this.title, this.date, this.time, this.repeat = Repeat.none, this.weekdays = const []});

  bool get hasSchedule => date != null || time != null || repeat != Repeat.none;
}

const _fullDays = 'monday|tuesday|wednesday|thursday|friday|saturday|sunday';
int _dayNum(String s) =>
    const {'mon': 1, 'tue': 2, 'wed': 3, 'thu': 4, 'fri': 5, 'sat': 6, 'sun': 7}[s.toLowerCase().substring(0, 3)]!;

RegExp _r(String p) => RegExp(p, caseSensitive: false);

SpokenTask parseSpokenTask(String input, DateTime now) {
  var s = ' ${input.trim()} ';
  Match? take(RegExp re) {
    final m = re.firstMatch(s);
    if (m != null) s = s.replaceRange(m.start, m.end, ' ');
    return m;
  }

  s = s.replaceFirst(
    _r(
      r'^\s*(?:please\s+)?(?:remind me to|remind me|i need to|i have to|i must|add (?:a )?task(?: to)?|new task|task)\b[:,]?',
    ),
    ' ',
  );

  var repeat = Repeat.none;
  final weekdays = <int>{};
  int? dayOffset;
  bool? hintPm;

  Match? m;
  if ((m = take(_r('\\b(?:every|each|on)\\s+((?:$_fullDays)s?(?:\\s*(?:,|and|&)\\s*(?:$_fullDays)s?)*)\\b'))) != null &&
      (m![0]!.toLowerCase().startsWith('every') ||
          m[0]!.toLowerCase().startsWith('each') ||
          m[1]!.toLowerCase().endsWith('s'))) {
    repeat = Repeat.weekly;
    weekdays.addAll(_r(_fullDays).allMatches(m[1]!).map((x) => _dayNum(x[0]!)));
  } else {
    if (m != null) s = s.replaceRange(m.start, m.start + 1, ' ${m[0]} ');
    if (take(_r(r'\b(?:every\s+weekdays?|on\s+weekdays)\b')) != null) {
      repeat = Repeat.weekly;
      weekdays.addAll([1, 2, 3, 4, 5]);
    } else if (take(_r(r'\b(?:every\s+weekends?|on\s+weekends)\b')) != null) {
      repeat = Repeat.weekly;
      weekdays.addAll([6, 7]);
    } else if ((m = take(_r(r'\b(?:every\s*day|daily|each day|every (morning|night|evening|afternoon))\b'))) != null) {
      repeat = Repeat.daily;
      if (m![1] != null) hintPm = m[1]!.toLowerCase() != 'morning';
    } else if (take(_r(r'\b(?:(?:every|each)\s+week|weekly)\b')) != null) {
      repeat = Repeat.weekly;
    }
  }

  if (take(_r(r'\b(?:the\s+)?day after tomorrow\b')) != null) {
    dayOffset = 2;
  } else if (take(_r(r'\btomorrow\b')) != null) {
    dayOffset = 1;
  } else if ((m = take(_r(r'\b(today|tonight|this evening)\b'))) != null) {
    dayOffset = 0;
    if (m![1]!.toLowerCase() != 'today') hintPm = true;
  } else if (repeat == Repeat.none &&
      (m = take(_r('\\b(?:on\\s+|next\\s+|this\\s+(?:coming\\s+)?)?($_fullDays)\\b'))) != null) {
    final d = _dayNum(m![1]!);
    dayOffset = (d - now.weekday) % 7;
    if (dayOffset == 0) dayOffset = 7;
  }

  if ((m = take(_r(r'\b(?:in the|this) (morning|afternoon|evening)\b|\bat night\b'))) != null) {
    hintPm = m![1]?.toLowerCase() != 'morning';
  }

  int? hour;
  var minute = 0;
  bool? pm;
  if ((m = take(_r(r'(?:\b(?:at|by)\s+|@\s*)?\b(\d{1,2})(?:[:.](\d{2}))?\s*([ap])\.?\s?m\b\.?'))) != null) {
    hour = int.parse(m![1]!);
    minute = int.tryParse(m[2] ?? '') ?? 0;
    pm = m[3]!.toLowerCase() == 'p';
  } else if ((m = take(_r(r"(?:\b(?:at|by)\s+|@\s*)(\d{1,2})(?:[:.](\d{2}))?(?:\s*o'?\s*clock)?\b"))) != null) {
    hour = int.parse(m![1]!);
    minute = int.tryParse(m[2] ?? '') ?? 0;
  } else if ((m = take(_r(r'\b(?:at\s+)?(noon|midday|midnight)\b'))) != null) {
    hour = m![1]!.toLowerCase() == 'midnight' ? 0 : 12;
    pm = hour == 12 ? null : false;
  }

  String? time;
  if (hour != null) {
    final isPm = pm ?? hintPm;
    if (hour <= 12) {
      if (isPm == true && hour < 12) hour += 12;
      if (isPm == false && hour == 12 && pm == false) hour = 0;
      if (isPm == null && hour >= 1 && hour <= 6) hour += 12;
    }
    if (hour < 24 && minute < 60) time = '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
  }

  final start = dayOffset == null ? null : DateTime(now.year, now.month, now.day + dayOffset);
  if (repeat == Repeat.weekly && weekdays.isEmpty) weekdays.add((start ?? now).weekday);

  var title = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  final junk = _r(r'^(?:to|and|that)\s+|^[\s,.;:!?-]+|[\s,.;:!?-]+$|\s+(?:at|on|by|for|and|to)$');
  for (var prev = ''; prev != title;) {
    prev = title;
    title = title.replaceAll(junk, '').trim();
  }
  if (title.isEmpty) title = input.trim();
  if (title.isNotEmpty) title = title[0].toUpperCase() + title.substring(1);

  return SpokenTask(
    title: title,
    date: start == null ? null : dayKey(start),
    time: time,
    repeat: repeat,
    weekdays: weekdays.toList()..sort(),
  );
}
