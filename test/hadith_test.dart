import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_tracker/hadith/hadith.dart';
import 'package:habit_tracker/hadith/prayer_hadith.dart';
import 'package:habit_tracker/models.dart';
import 'package:habit_tracker/services/reminders.dart';

void main() {
  group('prayer hadith', () {
    test('each quote is an exact excerpt of its source text', () {
      expect(prayerHadith.length, greaterThanOrEqualTo(20));
      for (final h in prayerHadith) {
        expect(h.text, contains(h.quote), reason: h.ref);
        expect(h.quote.length, lessThan(400), reason: h.ref);
        if (!h.ref.startsWith('Sahih')) expect(h.grade, isNotEmpty, reason: h.ref);
      }
      expect(prayerHadith.map((h) => h.ref).toSet().length, prayerHadith.length);
    });

    test('five different hadith a week, a new set every week', () {
      final monday = DateTime(2026, 11, 23);
      final week = weeklyPrayerHadith(monday);
      expect(week.keys, ['Fajr', 'Dhuhr', 'Asr', 'Maghrib', 'Isha']);
      expect(week.values.toSet().length, 5);
      expect(weeklyPrayerHadith(monday.add(const Duration(days: 6))), week);
      for (var w = 1; w <= 2; w++) {
        final other = weeklyPrayerHadith(monday.add(Duration(days: 7 * w)));
        for (final name in week.keys) {
          expect(other[name], isNot(week[name]), reason: '$name, week +$w');
        }
      }
      final general = <Hadith>[];
      final weeks = prayerHadith.where((h) => h.prayers.isEmpty).length ~/ 5;
      for (var w = 0; w < weeks; w++) {
        general.addAll(weeklyPrayerHadith(monday.add(Duration(days: 7 * w))).values.where((h) => h.prayers.isEmpty));
      }
      expect(general.toSet().length, general.length, reason: 'no general hadith repeats for $weeks weeks');
    });

    test('a prayer only gets hadith about itself or about salah in general', () {
      for (var w = 0; w < 20; w++) {
        weeklyPrayerHadith(DateTime(2026, 1, 5).add(Duration(days: 7 * w))).forEach((name, h) {
          expect(h.prayers.isEmpty || h.prayers.contains(name), isTrue, reason: '$name ${h.ref}');
        });
      }
    });

    test('prayer reminders quote the week\'s hadith unless turned off', () {
      final s = Settings(useManualPrayer: true, wakeTime: const TimeOfDay(hour: 5, minute: 0));
      final now = DateTime(2026, 11, 25, 0, 0);
      final week = weeklyPrayerHadith(now);
      final fajr = planReminders(s, {}, now, days: 1).firstWhere((r) => r.payload.startsWith('prayer:Fajr'));
      expect(fajr.body, contains(week['Fajr']!.quote));
      expect(fajr.body, endsWith('— ${week['Fajr']!.ref}'));

      s.prayerHadith = false;
      final plain = planReminders(s, {}, now, days: 1).firstWhere((r) => r.payload.startsWith('prayer:Fajr'));
      expect(plain.body, startsWith('Prayer time'));
      expect(Settings.fromJson(s.toJson()).prayerHadith, isFalse);
    });
  });
}
