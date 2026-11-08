import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../models.dart';
import 'reminders.dart';
import 'storage.dart';

const _doneAction = 'done';
const _habitCategory = 'habit';

/// Runs in a background isolate when the user taps "Mark done" / "I'm up"
/// on a notification without opening the app.
@pragma('vm:entry-point')
Future<void> notificationActionBackground(NotificationResponse r) async {
  if (r.actionId != _doneAction || r.payload == null) return;
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  final storage = await Storage.open();
  final logs = storage.loadLogs();
  if (applyDoneAction(r.payload!, logs, DateTime.now())) {
    await storage.saveLogs(logs);
  }
}

class NotificationService {
  NotificationService._();
  static final instance = NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  /// Called for notification taps / actions while the app is running.
  void Function(NotificationResponse)? onResponse;

  bool get _supported =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  IOSFlutterLocalNotificationsPlugin? get _ios =>
      _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();

  Future<void> init() async {
    if (!_supported || _ready) return;
    tzdata.initializeTimeZones();
    try {
      final info = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(info.identifier));
    } catch (_) {
      // Fall back to UTC offset matching if the device zone is unknown.
      final offset = DateTime.now().timeZoneOffset;
      final match = tz.timeZoneDatabase.locations.values.firstWhere(
        (l) => l.currentTimeZone.offset == offset.inMilliseconds,
        orElse: () => tz.UTC,
      );
      tz.setLocalLocation(match);
    }

    await _plugin.initialize(
      settings: InitializationSettings(
        android: const AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
          notificationCategories: [
            DarwinNotificationCategory(_habitCategory, actions: [
              DarwinNotificationAction.plain(_doneAction, 'Mark done'),
            ]),
          ],
        ),
      ),
      onDidReceiveNotificationResponse: (r) => onResponse?.call(r),
      onDidReceiveBackgroundNotificationResponse: notificationActionBackground,
    );
    _ready = true;
  }

  /// If the app was launched by tapping a notification, returns that response.
  Future<NotificationResponse?> launchResponse() async {
    if (!_ready) return null;
    final d = await _plugin.getNotificationAppLaunchDetails();
    return (d?.didNotificationLaunchApp ?? false) ? d!.notificationResponse : null;
  }

  /// Asks for notification, exact-alarm and full-screen permissions.
  Future<bool> requestPermissions() async {
    if (!_ready) return false;
    if (_android != null) {
      final ok = await _android!.requestNotificationsPermission() ?? false;
      if (!(await _android!.canScheduleExactNotifications() ?? true)) {
        await _android!.requestExactAlarmsPermission();
      }
      await _android!.requestFullScreenIntentPermission();
      return ok;
    }
    return await _ios?.requestPermissions(alert: true, badge: true, sound: true) ?? false;
  }

  Future<bool> enabled() async {
    if (!_ready) return false;
    if (_android != null) return await _android!.areNotificationsEnabled() ?? false;
    final p = await _ios?.checkPermissions();
    return p?.isEnabled ?? false;
  }

  NotificationDetails _details(ReminderKind kind, Settings s) {
    final doneLabel = switch (kind) {
      ReminderKind.wake => "I'm up",
      ReminderKind.prayer => 'Prayed',
      ReminderKind.training => 'Open coach',
    };
    final actions = [
      AndroidNotificationAction(
        _doneAction,
        doneLabel,
        showsUserInterface: kind == ReminderKind.training,
      ),
    ];
    final ios = DarwinNotificationDetails(
      categoryIdentifier: kind == ReminderKind.training ? null : _habitCategory,
      interruptionLevel: kind == ReminderKind.wake ? InterruptionLevel.timeSensitive : InterruptionLevel.active,
    );
    if (kind == ReminderKind.wake && s.wakeAlarmLoud) {
      return NotificationDetails(
        android: AndroidNotificationDetails(
          'wake_alarm',
          'Wake-up alarm',
          channelDescription: 'Loud alarm that keeps ringing until you get up',
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.alarm,
          audioAttributesUsage: AudioAttributesUsage.alarm,
          fullScreenIntent: true,
          ongoing: true,
          autoCancel: false,
          // FLAG_INSISTENT: repeat the sound until the user responds.
          additionalFlags: Int32List.fromList([4]),
          actions: actions,
        ),
        iOS: ios,
      );
    }
    final (channel, name) = switch (kind) {
      ReminderKind.wake => ('wake', 'Wake-up reminder'),
      ReminderKind.prayer => ('prayer', 'Prayer reminders'),
      ReminderKind.training => ('training', 'Training reminders'),
    };
    return NotificationDetails(
      android: AndroidNotificationDetails(
        channel,
        name,
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.reminder,
        actions: actions,
      ),
      iOS: ios,
    );
  }

  /// Replaces all pending reminders with a fresh plan.
  Future<void> reschedule(Settings s, Map<String, DayLog> logs) async {
    if (!_ready) return;
    await _plugin.cancelAllPendingNotifications();
    if (!s.remindersEnabled) return;

    final exact = _android == null || (await _android!.canScheduleExactNotifications() ?? false);
    for (final r in planReminders(s, logs, DateTime.now())) {
      final mode = !exact
          ? AndroidScheduleMode.inexactAllowWhileIdle
          : r.kind == ReminderKind.wake
              ? AndroidScheduleMode.alarmClock
              : AndroidScheduleMode.exactAllowWhileIdle;
      try {
        await _plugin.zonedSchedule(
          id: r.id,
          scheduledDate: tz.TZDateTime.from(r.when, tz.local),
          notificationDetails: _details(r.kind, s),
          androidScheduleMode: mode,
          title: r.title,
          body: r.body,
          payload: r.payload,
        );
      } catch (e) {
        debugPrint('Failed to schedule ${r.payload}: $e');
      }
    }
  }

  Future<void> cancel(int id) async {
    if (_ready) await _plugin.cancel(id: id);
  }

  Future<void> showTest(Settings s) async {
    if (!_ready) return;
    await _plugin.show(
      id: 1,
      title: '✅ Reminders are working',
      body: 'You will be reminded to wake up, pray and train.',
      notificationDetails: _details(ReminderKind.prayer, s),
    );
  }
}
