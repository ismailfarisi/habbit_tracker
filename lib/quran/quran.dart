import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'surahs.dart';

/// Verified Quran text: the Tanzil Project's Uthmani text (tanzil.net),
/// bundled verbatim in assets.
class QuranText {
  static Map<int, List<String>>? _cache;

  @visibleForTesting
  static set cache(Map<int, List<String>> v) => _cache = v;
  static const attribution = 'Text: Tanzil Quran Text (Uthmani), tanzil.net';
  static const translationAttribution = 'Translation: Saheeh International, via Quran.com';
  static const recitationAttribution = 'Recitation: Mishary Alafasy, via EveryAyah';

  static Map<int, List<String>> parse(String raw) {
    final out = <int, List<String>>{};
    for (final line in const LineSplitter().convert(raw)) {
      if (line.isEmpty || line.startsWith('#')) continue;
      final parts = line.split('|');
      if (parts.length < 3) continue;
      (out[int.parse(parts[0])] ??= []).add(parts.sublist(2).join('|'));
    }
    return out;
  }

  static Future<Map<int, List<String>>> load([AssetBundle? bundle]) async =>
      _cache ??= parse(await (bundle ?? rootBundle).loadString('assets/quran/quran-uthmani.txt'));

  static Future<List<String>> verses(int surah, int from, int to, [AssetBundle? bundle]) async {
    final s = (await load(bundle))[surah] ?? const [];
    if (s.isEmpty) return const [];
    return s.sublist((from - 1).clamp(0, s.length), to.clamp(from, s.length));
  }
}

String surahName(int surah) => surah >= 1 && surah <= surahInfo.length ? surahInfo[surah - 1].$1 : 'Surah $surah';

String passageLabel(int surah, int from, int to) =>
    '${surahName(surah)} ${from == to ? '$from' : '$from–$to'}';

/// URL of one ayah's recitation (Mishary Alafasy, 128 kbps).
String ayahAudioUrl(int surah, int ayah) =>
    'https://everyayah.com/data/Alafasy_128kbps/${surah.toString().padLeft(3, '0')}${ayah.toString().padLeft(3, '0')}.mp3';

/// Saheeh International translation of a surah from the Quran.com API,
/// cached on the phone after the first load.
Future<List<String>> loadTranslation(int surah, {http.Client? client}) async {
  final prefs = await SharedPreferences.getInstance();
  final key = 'quran.tr20.$surah';
  final cached = prefs.getString(key);
  if (cached != null) return (jsonDecode(cached) as List).cast<String>();
  final c = client ?? http.Client();
  final res = await c.get(
    Uri.parse('https://api.quran.com/api/v4/quran/translations/20?chapter_number=$surah'),
  );
  if (res.statusCode != 200) throw Exception('Translation unavailable (${res.statusCode})');
  final list = [
    for (final t in (jsonDecode(res.body) as Map)['translations'] as List)
      '${(t as Map)['text']}'.replaceAll(RegExp(r'<sup[^>]*>.*?</sup>'), '').replaceAll(RegExp(r'<[^>]+>'), ''),
  ];
  await prefs.setString(key, jsonEncode(list));
  return list;
}
