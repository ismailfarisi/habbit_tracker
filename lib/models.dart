import 'package:flutter/material.dart';

/// The five daily prayers, in order.
const prayerNames = ['Fajr', 'Dhuhr', 'Asr', 'Maghrib', 'Isha'];

/// Default prayer times used when no location is set and manual mode is on.
const defaultManualTimes = {
  'Fajr': '05:00',
  'Dhuhr': '12:30',
  'Asr': '15:45',
  'Maghrib': '18:15',
  'Isha': '19:45',
};

/// Calculation methods supported by the adhan package, with readable labels.
const calcMethodLabels = {
  'muslim_world_league': 'Muslim World League',
  'karachi': 'Karachi (Univ. of Islamic Sciences)',
  'north_america': 'ISNA (North America)',
  'egyptian': 'Egyptian General Authority',
  'umm_al_qura': 'Umm al-Qura, Makkah',
  'dubai': 'Dubai / Gulf',
  'kuwait': 'Kuwait',
  'qatar': 'Qatar',
  'singapore': 'Singapore',
  'turkey': 'Turkey (Diyanet)',
  'tehran': 'Tehran',
  'moon_sighting_committee': 'Moonsighting Committee',
};

String fmtHm(TimeOfDay t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

TimeOfDay parseHm(String s, {TimeOfDay fallback = const TimeOfDay(hour: 0, minute: 0)}) {
  final m = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(s.trim());
  if (m == null) return fallback;
  final h = int.parse(m.group(1)!), min = int.parse(m.group(2)!);
  if (h > 23 || min > 59) return fallback;
  return TimeOfDay(hour: h, minute: min);
}

class Settings {
  TimeOfDay wakeTime;
  int wakeGraceMin;

  double? latitude;
  double? longitude;
  String locationName;
  String calcMethod;
  String madhab; // 'shafi' | 'hanafi'
  bool useManualPrayer;
  Map<String, String> manualTimes;

  bool remindersEnabled;
  int prayerOffsetMin;
  bool wakeAlarmLoud;
  TimeOfDay trainingTime;
  int trainingGoalMin;

  String model;
  String speechLocale;

  Settings({
    this.wakeTime = const TimeOfDay(hour: 5, minute: 0),
    this.wakeGraceMin = 30,
    this.latitude,
    this.longitude,
    this.locationName = '',
    this.calcMethod = 'muslim_world_league',
    this.madhab = 'shafi',
    this.useManualPrayer = false,
    Map<String, String>? manualTimes,
    this.remindersEnabled = true,
    this.prayerOffsetMin = 0,
    this.wakeAlarmLoud = true,
    this.trainingTime = const TimeOfDay(hour: 7, minute: 0),
    this.trainingGoalMin = 15,
    this.model = 'openai/gpt-4o-mini',
    this.speechLocale = '',
  }) : manualTimes = manualTimes ?? Map.of(defaultManualTimes);

  bool get hasLocation => latitude != null && longitude != null;

  Map<String, dynamic> toJson() => {
        'wakeTime': fmtHm(wakeTime),
        'wakeGraceMin': wakeGraceMin,
        'latitude': latitude,
        'longitude': longitude,
        'locationName': locationName,
        'calcMethod': calcMethod,
        'madhab': madhab,
        'useManualPrayer': useManualPrayer,
        'manualTimes': manualTimes,
        'remindersEnabled': remindersEnabled,
        'prayerOffsetMin': prayerOffsetMin,
        'wakeAlarmLoud': wakeAlarmLoud,
        'trainingTime': fmtHm(trainingTime),
        'trainingGoalMin': trainingGoalMin,
        'model': model,
        'speechLocale': speechLocale,
      };

  factory Settings.fromJson(Map<String, dynamic> j) {
    final d = Settings();
    return Settings(
      wakeTime: parseHm(j['wakeTime'] as String? ?? '', fallback: d.wakeTime),
      wakeGraceMin: (j['wakeGraceMin'] as num?)?.toInt() ?? d.wakeGraceMin,
      latitude: (j['latitude'] as num?)?.toDouble(),
      longitude: (j['longitude'] as num?)?.toDouble(),
      locationName: j['locationName'] as String? ?? '',
      calcMethod: calcMethodLabels.containsKey(j['calcMethod']) ? j['calcMethod'] as String : d.calcMethod,
      madhab: j['madhab'] == 'hanafi' ? 'hanafi' : 'shafi',
      useManualPrayer: j['useManualPrayer'] as bool? ?? false,
      manualTimes: {
        ...defaultManualTimes,
        ...?(j['manualTimes'] as Map?)?.map((k, v) => MapEntry(k as String, v as String)),
      },
      remindersEnabled: j['remindersEnabled'] as bool? ?? true,
      prayerOffsetMin: (j['prayerOffsetMin'] as num?)?.toInt() ?? 0,
      wakeAlarmLoud: j['wakeAlarmLoud'] as bool? ?? true,
      trainingTime: parseHm(j['trainingTime'] as String? ?? '', fallback: d.trainingTime),
      trainingGoalMin: (j['trainingGoalMin'] as num?)?.toInt() ?? d.trainingGoalMin,
      model: (j['model'] as String?)?.trim().isNotEmpty == true ? j['model'] as String : d.model,
      speechLocale: j['speechLocale'] as String? ?? '',
    );
  }

  Settings copy() => Settings.fromJson(toJson());
}

/// What happened on a single day.
class DayLog {
  DateTime? wakeAt;
  Set<String> prayers;
  int trainingMinutes;

  DayLog({this.wakeAt, Set<String>? prayers, this.trainingMinutes = 0})
      : prayers = prayers ?? <String>{};

  bool get isEmpty => wakeAt == null && prayers.isEmpty && trainingMinutes == 0;

  Map<String, dynamic> toJson() => {
        if (wakeAt != null) 'wakeAt': wakeAt!.toIso8601String(),
        'prayers': prayers.toList(),
        'trainingMinutes': trainingMinutes,
      };

  factory DayLog.fromJson(Map<String, dynamic> j) => DayLog(
        wakeAt: j['wakeAt'] == null ? null : DateTime.tryParse(j['wakeAt'] as String),
        prayers: ((j['prayers'] as List?) ?? const []).cast<String>().toSet(),
        trainingMinutes: (j['trainingMinutes'] as num?)?.toInt() ?? 0,
      );
}

enum Repeat { none, daily, weekly }

const weekdayShort = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];

/// A user- or AI-created task. One-off tasks have an optional [date];
/// repeating tasks use [date] as an optional start date.
class Task {
  final String id;

  /// Small sequential number used to derive stable notification ids.
  final int seq;
  String title;
  String notes;
  String? date; // yyyy-MM-dd
  String? time; // HH:mm, enables a reminder
  Repeat repeat;
  List<int> weekdays; // 1 = Monday .. 7 = Sunday, for weekly
  Set<String> doneDates;
  final DateTime createdAt;
  final bool createdByAi;

  Task({
    required this.id,
    required this.seq,
    required this.title,
    this.notes = '',
    this.date,
    this.time,
    this.repeat = Repeat.none,
    List<int>? weekdays,
    Set<String>? doneDates,
    DateTime? createdAt,
    this.createdByAi = false,
  })  : weekdays = weekdays ?? [],
        doneDates = doneDates ?? <String>{},
        createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'seq': seq,
        'title': title,
        'notes': notes,
        'date': date,
        'time': time,
        'repeat': repeat.name,
        'weekdays': weekdays,
        'doneDates': doneDates.toList(),
        'createdAt': createdAt.toIso8601String(),
        'createdByAi': createdByAi,
      };

  factory Task.fromJson(Map<String, dynamic> j) => Task(
        id: j['id'] as String,
        seq: (j['seq'] as num?)?.toInt() ?? 0,
        title: j['title'] as String? ?? '',
        notes: j['notes'] as String? ?? '',
        date: j['date'] as String?,
        time: j['time'] as String?,
        repeat: Repeat.values.firstWhere((r) => r.name == j['repeat'], orElse: () => Repeat.none),
        weekdays: ((j['weekdays'] as List?) ?? const []).map((e) => (e as num).toInt()).toList(),
        doneDates: ((j['doneDates'] as List?) ?? const []).cast<String>().toSet(),
        createdAt: DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
        createdByAi: j['createdByAi'] as bool? ?? false,
      );

  Task copy() => Task.fromJson(toJson());
}
