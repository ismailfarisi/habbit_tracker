import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../habits/habit.dart';
import '../hadith/hadith.dart';
import '../models.dart';
import 'diagnostics.dart';
import 'reminders.dart';
import 'storage.dart';

const _doneAction = 'done';

/// Wake action used while the wake challenge is on: opens the app to the
/// challenge instead of marking the wake-up in the background.
const wakeChallengeAction = 'wake_challenge';
enum ReminderAction {
  wake("I'm up", _doneAction),
  prayer('Prayed', _doneAction),
  habit('Open habit', 'open', foreground: true),
  task('Done', _doneAction),
  bedtime('Going to bed', _doneAction),
  dismiss('Dismiss', 'dismiss'),
  challenge('Start wake challenge', wakeChallengeAction, foreground: true);

  final String label, id;
  final bool foreground;
  const ReminderAction(this.label, this.id, {this.foreground = false});

  static ReminderAction? forReminder(ReminderKind kind, Settings s, String? payload) {
    if (payload == null) return null;
    if (payload.startsWith('suhoor|')) return dismiss;
    return switch (kind) {
      ReminderKind.wake => s.wakeChallenge == WakeChallenge.off ? wake : challenge,
      ReminderKind.prayer => prayer,
      ReminderKind.habit => habit,
      ReminderKind.task => task,
      ReminderKind.bedtime => bedtime,
    };
  }

  DarwinNotificationCategory get category => DarwinNotificationCategory('reminder_$name', actions: [
    DarwinNotificationAction.plain(id, label,
      options: {if (foreground) DarwinNotificationActionOption.foreground}),
  ]);
}

/// Runs in a background isolate when the user taps "Mark done" / "I'm up"
/// on a notification without opening the app.
@pragma('vm:entry-point')
Future<void> notificationActionBackground(NotificationResponse r) async {
  if (r.actionId != _doneAction || r.payload == null) return;
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  final storage = await Storage.open();
  await Diagnostics(storage.prefs).count(Diagnostics.backgroundActions);
  if (r.payload!.startsWith('task:')) {
    final tasks = storage.loadTasks();
    if (applyTaskDoneAction(r.payload!, tasks)) await storage.saveTasks(tasks);
    return;
  }
  if (r.payload!.startsWith('wake|') && storage.loadSettings().wakeChallenge != WakeChallenge.off) return;
  final logs = storage.loadLogs();
  if (applyDoneAction(r.payload!, logs, DateTime.now())) {
    await storage.saveLogs(logs);
  }
}

/// The portion of the last schedule still reported pending on this device.
class ReminderDelivery {
  final List<PlannedReminder> pending;
  final bool allowed;
  final bool? exact;
  final int missing, beyondLimit;
  final List<String> blockedChannels;
  final Set<int> muted;
  const ReminderDelivery({
    required this.pending, required this.allowed, this.exact, this.missing = 0,
    this.beyondLimit = 0, this.blockedChannels = const [], this.muted = const {},
  });
}

class NotificationService {
  NotificationService._();
  static final instance = NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  Future<void>? _work;
  final scheduleRevision = ValueNotifier(0);
  List<PlannedReminder> _lastPlan = const [];
  final _accepted = <int, PlannedReminder>{};
  final _channelIds = <int, String>{};
  bool _scheduleReadable = true;

  /// Called for notification taps / actions while the app is running.
  void Function(NotificationResponse)? onResponse;

  /// Set to the day key of a wake notification the user tapped (or answered
  /// with [wakeChallengeAction]); the wake card opens the challenge for it
  /// and clears it.
  final ValueNotifier<String?> wakeChallengeRequest = ValueNotifier(null);

  void _noteWakeTap(NotificationResponse r) {
    final payload = r.payload ?? '';
    if (!payload.startsWith('wake|')) return;
    if (r.actionId == null || r.actionId == wakeChallengeAction) {
      wakeChallengeRequest.value = payload.substring(5);
    }
  }

  bool get _supported =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  IOSFlutterLocalNotificationsPlugin? get _ios =>
      _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();

  Future<void> init() async {
    if (!_supported || _ready) return;
    tzdata.initializeTimeZones();
    await _updateTimezone();

    await _plugin.initialize(
      settings: InitializationSettings(
        android: const AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
          notificationCategories: [for (final action in ReminderAction.values) action.category],
        ),
      ),
      onDidReceiveNotificationResponse: (r) {
        _noteWakeTap(r);
        onResponse?.call(r);
      },
      onDidReceiveBackgroundNotificationResponse: notificationActionBackground,
    );
    _ready = true;
  }

  Future<void> _updateTimezone() async {
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
  }

  /// If the app was launched by tapping a notification, returns that response.
  Future<NotificationResponse?> launchResponse() async {
    if (!_ready) return null;
    final d = await _plugin.getNotificationAppLaunchDetails();
    final r = (d?.didNotificationLaunchApp ?? false) ? d!.notificationResponse : null;
    if (r != null) _noteWakeTap(r);
    return r;
  }

  /// Ordinary notification consent, including requests from onboarding and Today.
  Future<bool> requestPermissions() async {
    if (!_ready) return false;
    if (_android != null) return await _android!.requestNotificationsPermission() ?? false;
    return await _ios?.requestPermissions(alert: true, badge: true, sound: true) ?? false;
  }

  Future<bool> requestExactAlarms() async =>
      _ready && (await _android?.requestExactAlarmsPermission() ?? false);

  Future<bool> requestFullScreenWake() async =>
      _ready && (await _android?.requestFullScreenIntentPermission() ?? false);

  static const _device = MethodChannel('daily_discipline/reminders');

  Future<bool?> fullScreenAllowed() async =>
      _ready && _android != null ? _device.invokeMethod<bool>('fullScreenAllowed') : null;

  Future<bool> enabled() async {
    if (!_ready) return false;
    if (_android != null) return await _android!.areNotificationsEnabled() ?? false;
    final p = await _ios?.checkPermissions();
    return p?.isEnabled ?? false;
  }

  NotificationDetails _details(ReminderKind kind, Settings s, {String? body, String? payload}) {
    final action = ReminderAction.forReminder(kind, s, payload);
    final actions = [
      if (action != null) AndroidNotificationAction(action.id, action.label, showsUserInterface: action.foreground),
    ];
    final ios = DarwinNotificationDetails(
      categoryIdentifier: action?.category.identifier,
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
      ReminderKind.habit => ('habits', 'Habit reminders'),
      ReminderKind.task => ('tasks', 'Task reminders'),
      ReminderKind.bedtime => ('bedtime', 'Bedtime reminder'),
    };
    return NotificationDetails(
      android: AndroidNotificationDetails(
        channel,
        name,
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.reminder,
        styleInformation: body == null ? null : BigTextStyleInformation(body),
        actions: actions,
      ),
      iOS: ios,
    );
  }

  /// Replaces all pending reminders with a fresh plan.
  Future<void> reschedule(
    Settings s,
    Map<String, DayLog> logs,
    List<Task> tasks, {
    List<HabitDef> habits = const [],
  }) async {
    if (!_ready) return;
    // A resume and a settings edit can request replacements concurrently.
    // Keep cancellation, insertion and queue verification in the same order.
    _work = (_work ?? Future<void>.value()).then((_) async {
      try {
        await _replace(s, logs, tasks, habits);
        _scheduleReadable = true;
      } catch (e) {
        _scheduleReadable = false;
        debugPrint('Could not replace reminder schedule: ${e.runtimeType}');
      } finally {
        scheduleRevision.value++;
      }
    });
    await _work;
  }

  Future<void> _replace(Settings s, Map<String, DayLog> logs, List<Task> tasks, List<HabitDef> habits) async {
    await _plugin.cancelAllPendingNotifications();
    _accepted.clear();
    _channelIds.clear();
    _lastPlan = const [];
    if (!s.remindersEnabled || !await enabled()) return;
    await _updateTimezone();
    _lastPlan = planReminders(s, logs, DateTime.now(), tasks: tasks, habits: habits);
    final exact = _android == null || (await _android!.canScheduleExactNotifications() ?? false);
    var scheduled = 0, failed = 0;
    for (final r in _lastPlan.take(maxPending)) {
      final mode = !exact
          ? AndroidScheduleMode.inexactAllowWhileIdle
          : r.kind == ReminderKind.wake
              ? AndroidScheduleMode.alarmClock
              : AndroidScheduleMode.exactAllowWhileIdle;
      try {
        final details = _details(r.kind, s, body: r.body, payload: r.payload);
        await _plugin.zonedSchedule(
          id: r.id,
          scheduledDate: tz.TZDateTime.from(r.when, tz.local),
          notificationDetails: details,
          androidScheduleMode: mode,
          title: r.title,
          body: r.body,
          payload: r.payload,
        );
        _accepted[r.id] = r;
        if (details.android != null) _channelIds[r.id] = details.android!.channelId;
        scheduled++;
      } catch (e) {
        failed++;
        debugPrint('Failed to schedule ${r.payload}: $e');
      }
    }
    await Diagnostics.global?.count(Diagnostics.reschedules);
    await Diagnostics.global?.count(Diagnostics.remindersScheduled, scheduled);
    await Diagnostics.global?.count(Diagnostics.remindersFailed, failed);
  }

  Future<ReminderDelivery?> delivery({DateTime? now}) async {
    if (!_ready) return null;
    await _work;
    if (!_scheduleReadable) return null;
    final allowed = await enabled();
    final requests = await _plugin.pendingNotificationRequests();
    final ids = {for (final r in requests) if (_accepted[r.id]?.payload == r.payload) r.id};
    final android = _android;
    final exact = await android?.canScheduleExactNotifications();
    var blocked = const <String, String>{};
    if (android != null) {
      // The plugin's Android pending list is a disk cache. Cross-check the
      // broadcast PendingIntent tokens without creating or updating them.
      final live = await _device.invokeListMethod<int>('pendingIds', ids.toList()) ?? [];
      ids.retainAll(live);
      blocked = await _device.invokeMapMethod<String, String>('blockedChannels') ?? {};
    }
    final at = now ?? DateTime.now();
    final pending = _accepted.values.where((r) => ids.contains(r.id) && r.when.isAfter(at)).toList();
    return ReminderDelivery(
      allowed: allowed, exact: exact, pending: pending, blockedChannels: blocked.values.toList(),
      muted: {for (final r in pending) if (blocked.containsKey(_channelIds[r.id])) r.id},
      missing: _lastPlan.take(maxPending).where((r) => r.when.isAfter(at)).length - pending.length,
      beyondLimit: _lastPlan.skip(maxPending).where((r) => r.when.isAfter(at)).length,
    );
  }

  Future<void> cancel(int id) async {
    if (!_ready) return;
    await _plugin.cancel(id: id);
    scheduleRevision.value++;
  }

  Future<void> showTest(Settings s) async {
    if (!_ready) return;
    final h = s.prayerHadith && (s.useManualPrayer || s.hasLocation) ? weeklyPrayerHadith(DateTime.now())['Dhuhr'] : null;
    final body = h == null
        ? 'This immediate test checks that a notification can appear on this phone.'
        : 'This week with your prayer reminders: ${h.quote} — ${h.ref}';
    await _plugin.show(
      id: 1,
      title: 'Test notification',
      body: body,
      notificationDetails: _details(ReminderKind.prayer, s, body: body),
    );
  }
}
