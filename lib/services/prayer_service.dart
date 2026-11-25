import 'package:adhan/adhan.dart' as adhan;

import '../models.dart';

class PrayerDay {
  /// Prayer name -> local time, in [prayerNames] order. On Fridays with a
  /// [Settings.jumuahTime] set, 'Dhuhr' is the local Jumu'ah time.
  final Map<String, DateTime> times;
  final bool calculated;

  /// Sunrise, the end of Fajr. Only known when [calculated].
  final DateTime? sunrise;
  const PrayerDay(this.times, {required this.calculated, this.sunrise});
}

/// Only these persisted choices authorize time-sensitive prayer reminders.
bool prayerTimesConfirmed(Settings s) => s.useManualPrayer || s.hasLocation;

String prayerTimeSource(Settings s) {
  if (s.useManualPrayer) return 'Manual timetable';
  if (!s.hasLocation) return 'Example times · prayer alerts off';
  final place = s.locationName.trim().isEmpty
      ? '${s.latitude!.toStringAsFixed(2)}, ${s.longitude!.toStringAsFixed(2)}'
      : s.locationName;
  return '$place · ${calcMethodLabels[s.calcMethod] ?? calcMethodLabels['muslim_world_league']}';
}

/// Prayer times for [date], calculated offline from the saved location, or
/// the manual times when manual mode is on or no location is set.
PrayerDay prayerTimesFor(Settings s, DateTime date) {
  final day = _baseTimes(s, date);
  final jumuah = s.jumuahTime.isEmpty || date.weekday != DateTime.friday ? null : parseHm(s.jumuahTime);
  if (jumuah == null) return day;
  return PrayerDay(
    {...day.times, 'Dhuhr': DateTime(date.year, date.month, date.day, jumuah.hour, jumuah.minute)},
    calculated: day.calculated,
    sunrise: day.sunrise,
  );
}

PrayerDay _baseTimes(Settings s, DateTime date) {
  if (!s.useManualPrayer && s.hasLocation) {
    final method = adhan.CalculationMethod.values.firstWhere(
      (m) => m.name == s.calcMethod,
      orElse: () => adhan.CalculationMethod.muslim_world_league,
    );
    final params = method.getParameters()
      ..madhab = s.madhab == 'hanafi' ? adhan.Madhab.hanafi : adhan.Madhab.shafi;
    final pt = adhan.PrayerTimes(
      adhan.Coordinates(s.latitude!, s.longitude!),
      adhan.DateComponents(date.year, date.month, date.day),
      params,
    );
    return PrayerDay({
      'Fajr': pt.fajr.toLocal(),
      'Dhuhr': pt.dhuhr.toLocal(),
      'Asr': pt.asr.toLocal(),
      'Maghrib': pt.maghrib.toLocal(),
      'Isha': pt.isha.toLocal(),
    }, calculated: true, sunrise: pt.sunrise.toLocal());
  }
  return PrayerDay({
    for (final p in prayerNames)
      p: () {
        final t = parseHm(s.manualTimes[p] ?? defaultManualTimes[p]!);
        return DateTime(date.year, date.month, date.day, t.hour, t.minute);
      }(),
  }, calculated: false);
}

/// The next prayer at or after [now], looking into tomorrow if needed.
MapEntry<String, DateTime> nextPrayer(Settings s, DateTime now) {
  for (final e in prayerTimesFor(s, now).times.entries) {
    if (!e.value.isBefore(now)) return e;
  }
  final tomorrow = DateTime(now.year, now.month, now.day + 1);
  return prayerTimesFor(s, tomorrow).times.entries.first;
}
