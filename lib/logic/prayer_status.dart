import '../models.dart';
import '../services/prayer_service.dart';
import 'hijri.dart';
import 'stats.dart';

/// Prayer status rules and the Muslim calendar context of a day.
///
/// * [prayerWindowEnd]: a prayer is on time until the next prayer starts
///   (Fajr until sunrise when it is known, Isha until the next Fajr).
/// * [autoPrayerStatus]: what a tap marks: on time inside the window, late
///   after it on the same day, qada on a later day.
/// * [prayerLabel]: Dhuhr is shown as Jumu'ah on Fridays.
/// * [isRamadan], [hijriToday]; [optionalPrayersOn] lists the sunnah prayers
///   (Duha, Taraweeh, Witr) that are shown but never scored.

DateTime prayerWindowEnd(Settings s, DateTime day, String name) {
  final pd = prayerTimesFor(s, day);
  if (name == 'Fajr' && pd.sunrise != null) return pd.sunrise!;
  final i = prayerNames.indexOf(name);
  if (i >= 0 && i < prayerNames.length - 1) return pd.times[prayerNames[i + 1]]!;
  return prayerTimesFor(s, DateTime(day.year, day.month, day.day + 1)).times['Fajr']!;
}

String autoPrayerStatus(Settings s, DateTime day, String name, DateTime at) {
  if (at.isBefore(prayerWindowEnd(s, day, name))) return prayerOnTime;
  return dateOnly(at) == dateOnly(day) ? prayerLate : prayerQada;
}

/// The status a done prayer counts as (no status = on time).
String? prayerStatusOf(DayLog log, String name) =>
    log.prayers.contains(name) ? (log.prayerStatus[name] ?? prayerOnTime) : null;

const prayerStatusLabels = {prayerOnTime: 'On time', prayerLate: 'Late', prayerQada: 'Qada'};

bool isJumuah(DateTime day, String name) => name == 'Dhuhr' && day.weekday == DateTime.friday;

String prayerLabel(String name, DateTime day) => isJumuah(day, name) ? "Jumu'ah" : name;

HijriDate hijriToday(Settings s, DateTime day) => hijriOf(day, offsetDays: s.hijriOffsetDays);

bool isRamadan(Settings s, DateTime day) => switch (s.ramadanMode) {
      'on' => true,
      'off' => false,
      _ => hijriToday(s, day).isRamadan,
    };

class OptionalPrayer {
  /// Key of its entry in [DayLog.habits] (there is no HabitDef for it).
  final String id;
  final String name;
  final String hint;

  /// The obligatory prayer it is listed after.
  final String after;
  const OptionalPrayer(this.id, this.name, this.hint, this.after);
}

const sunnahDuha = OptionalPrayer('sunnah.duha', 'Duha', 'Sunnah · after sunrise', 'Fajr');
const sunnahTaraweeh = OptionalPrayer('sunnah.taraweeh', 'Taraweeh', 'Ramadan night prayer · after Isha', 'Isha');
const sunnahWitr = OptionalPrayer('sunnah.witr', 'Witr', 'Sunnah · after Isha', 'Isha');

List<OptionalPrayer> optionalPrayersOn(Settings s, DateTime day) => [
      if (s.sunnahDuha) sunnahDuha,
      if (s.taraweeh && isRamadan(s, day)) sunnahTaraweeh,
      if (s.sunnahWitr) sunnahWitr,
    ];
