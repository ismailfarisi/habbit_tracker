import 'package:flutter/material.dart';

import 'habits/habit.dart';

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

/// Anti-snooze check before "I'm up" counts.
enum WakeChallenge { off, readAloud, math }

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
  /// Legacy (v1): only read when migrating the old articulation trainer
  /// into the "Articulation practice" habit.
  TimeOfDay trainingTime;
  int trainingGoalMin;

  String model;
  String speechLocale;

  /// Missed days per calendar month that don't break the perfect-day streak.
  int freezesPerMonth;

  // Wake challenge and sleep goal.
  WakeChallenge wakeChallenge;
  double sleepHours;
  int windDownMinutes;
  bool bedtimeReminder;

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
    this.freezesPerMonth = 2,
    this.wakeChallenge = WakeChallenge.off,
    this.sleepHours = 7.5,
    this.windDownMinutes = 30,
    this.bedtimeReminder = true,
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
        'freezesPerMonth': freezesPerMonth,
        'wakeChallenge': wakeChallenge.name,
        'sleepHours': sleepHours,
        'windDownMinutes': windDownMinutes,
        'bedtimeReminder': bedtimeReminder,
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
      freezesPerMonth: (j['freezesPerMonth'] as num?)?.toInt() ?? d.freezesPerMonth,
      wakeChallenge: WakeChallenge.values.firstWhere((c) => c.name == j['wakeChallenge'], orElse: () => d.wakeChallenge),
      sleepHours: ((j['sleepHours'] as num?)?.toDouble() ?? d.sleepHours).clamp(3.0, 12.0),
      windDownMinutes: ((j['windDownMinutes'] as num?)?.toInt() ?? d.windDownMinutes).clamp(0, 180),
      bedtimeReminder: j['bedtimeReminder'] as bool? ?? d.bedtimeReminder,
    );
  }

  Settings copy() => Settings.fromJson(toJson());
}

/// Prayer statuses stored in [DayLog.prayerStatus].
const prayerOnTime = 'onTime', prayerLate = 'late', prayerQada = 'qada';
const prayerStatuses = [prayerOnTime, prayerLate, prayerQada];

/// What happened on a single day.
class DayLog {
  DateTime? wakeAt;

  /// Prayers done that day (whatever their status).
  Set<String> prayers;

  /// 'onTime' | 'late' | 'qada' per prayer in [prayers]. A prayer without a
  /// status counts as on time.
  Map<String, String> prayerStatus;
  DateTime? bedtimeAt;

  /// Entries keyed by `HabitDef.id`.
  Map<String, HabitEntry> habits;

  DayLog({
    this.wakeAt,
    Set<String>? prayers,
    Map<String, String>? prayerStatus,
    this.bedtimeAt,
    Map<String, HabitEntry>? habits,
  })  : prayers = prayers ?? <String>{},
        prayerStatus = prayerStatus ?? {},
        habits = habits ?? {};

  bool get isEmpty =>
      wakeAt == null && bedtimeAt == null && prayers.isEmpty && habits.values.every((e) => e.isEmpty);

  Map<String, dynamic> toJson() => {
        if (wakeAt != null) 'wakeAt': wakeAt!.toIso8601String(),
        if (bedtimeAt != null) 'bedtimeAt': bedtimeAt!.toIso8601String(),
        'prayers': prayers.toList(),
        if (prayerStatus.isNotEmpty) 'prayerStatus': prayerStatus,
        if (habits.isNotEmpty)
          'habits': {
            for (final e in habits.entries)
              if (!e.value.isEmpty) e.key: e.value.toJson(),
          },
      };

  /// Also reads v1 logs: `trainingMinutes` becomes the minutes of the
  /// [articulationHabitId] entry.
  factory DayLog.fromJson(Map<String, dynamic> j) {
    final prayers = ((j['prayers'] as List?) ?? const []).map((e) => e.toString()).toSet();
    final habits = <String, HabitEntry>{
      if (j['habits'] is Map)
        for (final e in (j['habits'] as Map).entries)
          if (e.value is Map) e.key.toString(): HabitEntry.fromJson((e.value as Map).cast<String, dynamic>()),
    };
    final training = (j['trainingMinutes'] as num?)?.toInt() ?? 0;
    if (training > 0 && !habits.containsKey(articulationHabitId)) {
      habits[articulationHabitId] = HabitEntry(minutes: training);
    }
    return DayLog(
      wakeAt: j['wakeAt'] == null ? null : DateTime.tryParse(j['wakeAt'].toString()),
      bedtimeAt: j['bedtimeAt'] == null ? null : DateTime.tryParse(j['bedtimeAt'].toString()),
      prayers: prayers,
      prayerStatus: {
        if (j['prayerStatus'] is Map)
          for (final e in (j['prayerStatus'] as Map).entries)
            if (prayers.contains(e.key) && prayerStatuses.contains(e.value)) e.key.toString(): e.value.toString(),
      },
      habits: habits,
    );
  }
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
