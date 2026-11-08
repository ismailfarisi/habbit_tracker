import 'package:adhan/adhan.dart' as adhan;

import '../models.dart';

class PrayerDay {
  /// Prayer name -> local time, in [prayerNames] order.
  final Map<String, DateTime> times;
  final bool calculated;
  const PrayerDay(this.times, {required this.calculated});
}

/// Prayer times for [date], calculated offline from the saved location, or
/// the manual times when manual mode is on or no location is set.
PrayerDay prayerTimesFor(Settings s, DateTime date) {
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
    }, calculated: true);
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
