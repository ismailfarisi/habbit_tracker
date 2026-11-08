import 'package:flutter/foundation.dart';

import 'logic/stats.dart';
import 'models.dart';
import 'services/notification_service.dart';
import 'services/reminders.dart';
import 'services/storage.dart';

class AppState extends ChangeNotifier {
  final Storage storage;
  final NotificationService notifications;

  Settings settings;
  Map<String, DayLog> logs;
  String apiKey = '';

  /// Set when a notification asks the UI to open a tab (e.g. training).
  final ValueNotifier<int?> requestedTab = ValueNotifier(null);

  AppState._(this.storage, this.notifications, this.settings, this.logs);

  static Future<AppState> load(Storage storage, NotificationService n) async {
    final s = AppState._(storage, n, storage.loadSettings(), storage.loadLogs());
    s.apiKey = await storage.loadApiKey();
    return s;
  }

  DayLog dayLog(DateTime d) => logs[dayKey(d)] ?? DayLog();
  DayLog get today => dayLog(DateTime.now());

  DayLog _mutableDay(DateTime d) => logs.putIfAbsent(dayKey(d), DayLog.new);

  Future<void> _commit({bool reschedule = true}) async {
    notifyListeners();
    await storage.saveLogs(logs);
    if (reschedule) await notifications.reschedule(settings, logs);
  }

  /// Pick up changes made by the background notification isolate.
  Future<void> refreshFromDisk() async {
    await storage.reload();
    logs = storage.loadLogs();
    notifyListeners();
    await notifications.reschedule(settings, logs);
  }

  Future<void> markWake([DateTime? at]) async {
    final now = at ?? DateTime.now();
    _mutableDay(now).wakeAt = now;
    // Silence the wake alarm if it is still ringing.
    await notifications.cancel(reminderId(now, 0));
    await _commit();
  }

  Future<void> undoWake() async {
    _mutableDay(DateTime.now()).wakeAt = null;
    await _commit();
  }

  Future<void> setPrayer(DateTime day, String name, bool done) async {
    final log = _mutableDay(day);
    done ? log.prayers.add(name) : log.prayers.remove(name);
    await _commit();
  }

  Future<void> addTraining(int minutes) async {
    final log = _mutableDay(DateTime.now());
    log.trainingMinutes = (log.trainingMinutes + minutes).clamp(0, 24 * 60);
    await _commit();
  }

  Future<void> applyNotificationAction(String payload) async {
    if (applyDoneAction(payload, logs, DateTime.now())) {
      if (payload.startsWith('wake|')) await notifications.cancel(reminderId(DateTime.now(), 0));
      await _commit();
    }
  }

  Future<void> updateSettings(void Function(Settings s) change) async {
    change(settings);
    notifyListeners();
    await storage.saveSettings(settings);
    await notifications.reschedule(settings, logs);
  }

  Future<void> setApiKey(String key) async {
    apiKey = key.trim();
    notifyListeners();
    await storage.saveApiKey(apiKey);
  }

  Future<void> importBackup(String raw) async {
    await storage.importJson(raw);
    settings = storage.loadSettings();
    logs = storage.loadLogs();
    notifyListeners();
    await notifications.reschedule(settings, logs);
  }

  Future<void> resetAll() async {
    await storage.clearAll();
    settings = Settings();
    logs = {};
    apiKey = '';
    notifyListeners();
    await notifications.reschedule(settings, logs);
  }
}
