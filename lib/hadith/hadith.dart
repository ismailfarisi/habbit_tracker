import 'prayer_hadith.dart';

/// A hadith excerpt quoted word for word from its published translation.
class Hadith {
  final String ref, source, quote, text, grade;

  /// Prayers this hadith is about; empty = suits any prayer.
  final Set<String> prayers;

  const Hadith({
    required this.ref,
    required this.source,
    required this.quote,
    required this.text,
    this.grade = '',
    this.prayers = const {},
  });
}

/// Weeks since Monday 1 Jan 2024, so the set changes every Monday.
int hadithWeek(DateTime day) => DateTime.utc(day.year, day.month, day.day).difference(DateTime.utc(2024)).inDays ~/ 7;

/// The hadith shown with each prayer's reminder during the week of [day].
/// The general hadith advance five a week, so each prayer gets a new one
/// every week; on alternate weeks Fajr, Asr and Isha get one about
/// themselves instead.
Map<String, Hadith> weeklyPrayerHadith(DateTime day, {List<Hadith> pool = prayerHadith}) {
  final week = hadithWeek(day);
  final general = pool.where((h) => h.prayers.isEmpty).toList();
  final used = <Hadith>{};
  final out = <String, Hadith>{};
  const names = ['Fajr', 'Dhuhr', 'Asr', 'Maghrib', 'Isha'];
  for (var i = 0; i < names.length; i++) {
    final own = pool.where((h) => h.prayers.contains(names[i])).toList();
    Hadith? pick;
    if (week.isEven) {
      for (var k = 0; k < own.length && pick == null; k++) {
        final h = own[(week ~/ 2 + k) % own.length];
        if (!used.contains(h)) pick = h;
      }
    }
    if (pick == null && general.isNotEmpty) pick = general[(week * names.length + i) % general.length];
    if (pick == null) continue;
    used.add(pick);
    out[names[i]] = pick;
  }
  return out;
}
