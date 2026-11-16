import 'package:hijri/hijri_calendar.dart';

/// Hijri (Islamic) dates.
///
/// [hijriOf] uses the Umm al-Qura calendar (via the `hijri` package) for
/// 1356–1500 AH (1937–2077 CE) and the tabular Islamic calendar
/// ([tabularHijri]) outside that range. `offsetDays` shifts the result so
/// users can match local moon sighting (e.g. the UAE announcement).

const hijriMonthNames = [
  'Muharram',
  'Safar',
  "Rabi' al-Awwal",
  "Rabi' al-Thani",
  'Jumada al-Ula',
  'Jumada al-Akhirah',
  'Rajab',
  "Sha'ban",
  'Ramadan',
  'Shawwal',
  "Dhu al-Qa'dah",
  'Dhu al-Hijjah',
];

const ramadanMonth = 9;

class HijriDate {
  final int year, month, day;
  const HijriDate(this.year, this.month, this.day);

  String get monthName => hijriMonthNames[month - 1];
  bool get isRamadan => month == ramadanMonth;

  /// e.g. "12 Ramadan 1447 AH".
  @override
  String toString() => '$day $monthName $year AH';

  @override
  bool operator ==(Object other) =>
      other is HijriDate && other.year == year && other.month == month && other.day == day;

  @override
  int get hashCode => Object.hash(year, month, day);
}

HijriDate hijriOf(DateTime date, {int offsetDays = 0}) {
  final d = DateTime(date.year, date.month, date.day + offsetDays);
  try {
    final h = HijriCalendar.fromDate(d);
    if (h.hMonth >= 1 && h.hMonth <= 12 && h.hDay >= 1 && h.hDay <= 30) return HijriDate(h.hYear, h.hMonth, h.hDay);
  } catch (_) {
    // Outside the Umm al-Qura table.
  }
  return tabularHijri(d);
}

/// The arithmetic (civil) Islamic calendar; epoch 16 July 622 Julian.
HijriDate tabularHijri(DateTime date) {
  final jd = DateTime.utc(date.year, date.month, date.day).millisecondsSinceEpoch ~/ 86400000 + 2440588;
  var l = jd - 1948440 + 10632;
  final n = (l - 1) ~/ 10631;
  l = l - 10631 * n + 354;
  final j = ((10985 - l) ~/ 5316) * ((50 * l) ~/ 17719) + (l ~/ 5670) * ((43 * l) ~/ 15238);
  l = l - ((30 - j) ~/ 15) * ((17719 * j) ~/ 50) - (j ~/ 16) * ((15238 * j) ~/ 43) + 29;
  final m = (24 * l) ~/ 709;
  final d = l - (709 * m) ~/ 24;
  return HijriDate(30 * n + j - 30, m, d);
}
