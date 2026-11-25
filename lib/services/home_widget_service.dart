/// Android home-screen widget: the prayer to pray now (or the next one),
/// its time, today's score and a "Done" button.
///
/// [HomeWidgetService.publish] (called by AppState after every change)
/// writes a timeline of [WidgetSlot]s; the native `PrayerWidgetProvider`
/// shows the slot for the current time and is re-rendered at each slot start
/// (each prayer time and midnight) through `HomeWidget.scheduleWidgetUpdates`.
/// "Done" runs [homeWidgetCallback] in a background isolate, which marks the
/// prayer with the notification-action code path
/// ([notificationActionBackground]) and publishes again.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:home_widget/home_widget.dart';

import '../habits/habit.dart';
import '../goals/goal.dart';
import '../logic/prayer_status.dart';
import '../logic/stats.dart';
import '../models.dart';
import 'notification_service.dart';
import 'prayer_service.dart';
import 'storage.dart';

const homeWidgetProvider = 'com.ismailfarisi.habit_tracker.PrayerWidgetProvider';
const homeWidgetDataKey = 'prayer_widget';

/// What the widget shows from [from] until the next slot starts.
class WidgetSlot {
  final DateTime from;
  final String prayer;
  final DateTime at;

  /// The prayer has started and is not done yet, so "Done" is offered.
  final bool due;
  final DayScore score;

  const WidgetSlot({required this.from, required this.prayer, required this.at, required this.due, required this.score});

  bool get tomorrow => dateOnly(at).isAfter(dateOnly(from));

  /// Notification-action payload that marks [prayer] done, when [due].
  String? get payload => due ? 'prayer:$prayer|${dayKey(at)}' : null;

  Map<String, dynamic> toJson() => {
        'from': from.millisecondsSinceEpoch,
        'label': due ? 'Pray now' : (tomorrow ? 'Next prayer, tomorrow' : 'Next prayer'),
        'prayer': prayerLabel(prayer, at),
        'time': '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}',
        'score': 'Today $score',
        if (payload != null) 'payload': payload,
      };
}

/// The widget state at [at]: the latest started prayer of that day while it
/// is not done, otherwise the next prayer not done yet (tomorrow's Fajr after
/// the last one).
WidgetSlot widgetSlotAt(
  Settings s,
  Map<String, DayLog> logs,
  DateTime at, {
  List<HabitDef> habits = const [],
  List<Task> tasks = const [],
  List<Goal> goals = const [],
}) {
  final day = dateOnly(at);
  final score = dayScore(day, s, logs, habits: habits, tasks: tasks, goals: goals);
  final done = logs[dayKey(day)]?.prayers ?? const <String>{};
  final times = prayerTimesFor(s, day).times.entries.toList();
  final started = times.where((e) => !e.value.isAfter(at)).toList();
  if (started.isNotEmpty && !done.contains(started.last.key)) {
    return WidgetSlot(from: at, prayer: started.last.key, at: started.last.value, due: true, score: score);
  }
  for (final e in times) {
    if (e.value.isAfter(at) && !done.contains(e.key)) {
      return WidgetSlot(from: at, prayer: e.key, at: e.value, due: false, score: score);
    }
  }
  final fajr = prayerTimesFor(s, day.add(const Duration(days: 1))).times.entries.first;
  return WidgetSlot(from: at, prayer: fajr.key, at: fajr.value, due: false, score: score);
}

/// Slots from [now] to the end of tomorrow: one now, then one at every later
/// prayer time and at midnight, since the state only changes there (or when
/// the data changes, which publishes a new timeline).
List<WidgetSlot> widgetSlots(
  Settings s,
  Map<String, DayLog> logs,
  DateTime now, {
  List<HabitDef> habits = const [],
  List<Task> tasks = const [],
  List<Goal> goals = const [],
}) {
  final today = dateOnly(now), tomorrow = DateTime(now.year, now.month, now.day + 1);
  final starts = <DateTime>{
    now,
    ...prayerTimesFor(s, today).times.values,
    tomorrow,
    ...prayerTimesFor(s, tomorrow).times.values,
  }.where((t) => !t.isBefore(now)).toList()
    ..sort();
  return [for (final t in starts) widgetSlotAt(s, logs, t, habits: habits, tasks: tasks, goals: goals)];
}

/// The JSON the native widget reads: the slots plus when they run out.
String widgetJson(List<WidgetSlot> slots, DateTime now) => jsonEncode({
      'until': DateTime(now.year, now.month, now.day + 2).millisecondsSinceEpoch,
      'slots': [for (final s in slots) s.toJson()],
    });

class HomeWidgetService {
  HomeWidgetService._();

  /// Overrides the platform check in tests.
  @visibleForTesting
  static bool? debugEnabled;

  static bool get enabled => debugEnabled ?? (!kIsWeb && Platform.isAndroid);

  static Future<void> clear() async {
    if (!enabled) return;
    final canceled = await HomeWidget.cancelScheduledWidgetUpdates(qualifiedAndroidName: homeWidgetProvider);
    final removed = await HomeWidget.saveWidgetData<String>(homeWidgetDataKey, null, deleteFile: false);
    final redrawn = await HomeWidget.updateWidget(qualifiedAndroidName: homeWidgetProvider);
    if (canceled == false || removed == false || redrawn == false) {
      throw StateError('Could not clear the home widget');
    }
  }

  static bool _registered = false;

  /// Writes the widget timeline and redraws the widget. Never throws.
  static Future<void> publish(
    Settings s,
    Map<String, DayLog> logs, {
    List<HabitDef> habits = const [],
    List<Task> tasks = const [],
    List<Goal> goals = const [],
    DateTime? now,
  }) async {
    if (!enabled) return;
    final at = now ?? DateTime.now();
    final slots = widgetSlots(s, logs, at, habits: habits, tasks: tasks, goals: goals);
    try {
      if (!_registered) {
        await HomeWidget.registerInteractivityCallback(homeWidgetCallback);
        _registered = true;
      }
      await HomeWidget.saveWidgetData<String>(homeWidgetDataKey, widgetJson(slots, at));
      await HomeWidget.updateWidget(qualifiedAndroidName: homeWidgetProvider);
      await HomeWidget.scheduleWidgetUpdates(
        [for (final slot in slots.skip(1)) slot.from],
        qualifiedAndroidName: homeWidgetProvider,
      );
    } catch (e) {
      debugPrint('Home widget update failed: $e');
    }
  }
}

/// Runs in a background isolate when "Done" is tapped on the widget
/// (`dailydiscipline://done?payload=prayer:Asr|2026-11-16`).
@pragma('vm:entry-point')
Future<void> homeWidgetCallback(Uri? uri) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  final storage = await Storage.open();
  // This isolate may outlive app changes; drop its cached preferences.
  await storage.reload();
  final payload = uri?.queryParameters['payload'];
  if (uri?.host == 'done' && payload != null && payload.startsWith('prayer:')) {
    await notificationActionBackground(NotificationResponse(
      notificationResponseType: NotificationResponseType.selectedNotificationAction,
      actionId: 'done',
      payload: payload,
    ));
  }
  await HomeWidgetService.publish(
    storage.loadSettings(),
    storage.loadLogs(),
    habits: storage.loadHabits(),
    tasks: storage.loadTasks(),
    goals: storage.loadGoals(),
  );
}
