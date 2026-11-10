import 'package:flutter/foundation.dart';

import 'logic/stats.dart';
import 'logic/tasks.dart';
import 'models.dart';
import 'services/notification_service.dart';
import 'services/reminders.dart';
import 'services/storage.dart';
import 'services/task_tools.dart';

class AppState extends ChangeNotifier implements TaskBackend {
  final Storage storage;
  final NotificationService notifications;

  Settings settings;
  Map<String, DayLog> logs;
  @override
  List<Task> tasks;
  String apiKey = '';

  /// Set when a notification asks the UI to open a tab (e.g. training).
  final ValueNotifier<int?> requestedTab = ValueNotifier(null);

  AppState._(this.storage, this.notifications, this.settings, this.logs, this.tasks);

  static Future<AppState> load(Storage storage, NotificationService n) async {
    final s = AppState._(storage, n, storage.loadSettings(), storage.loadLogs(), storage.loadTasks());
    s.apiKey = await storage.loadApiKey();
    return s;
  }

  DayLog dayLog(DateTime d) => logs[dayKey(d)] ?? DayLog();
  DayLog get today => dayLog(DateTime.now());

  DayLog _mutableDay(DateTime d) => logs.putIfAbsent(dayKey(d), DayLog.new);

  Future<void> _commit({bool reschedule = true}) async {
    notifyListeners();
    await storage.saveLogs(logs);
    if (reschedule) await notifications.reschedule(settings, logs, tasks);
  }

  /// Pick up changes made by the background notification isolate.
  Future<void> refreshFromDisk() async {
    await storage.reload();
    logs = storage.loadLogs();
    tasks = storage.loadTasks();
    notifyListeners();
    await notifications.reschedule(settings, logs, tasks);
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
    if (applyTaskDoneAction(payload, tasks)) {
      await _commitTasks();
      return;
    }
    if (applyDoneAction(payload, logs, DateTime.now())) {
      if (payload.startsWith('wake|')) await notifications.cancel(reminderId(DateTime.now(), 0));
      await _commit();
    }
  }

  Future<void> rescheduleNow() => notifications.reschedule(settings, logs, tasks);

  // ---------- Tasks ----------
  Task? taskById(String id) {
    for (final t in tasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  Future<void> _commitTasks() async {
    notifyListeners();
    await storage.saveTasks(tasks);
    await notifications.reschedule(settings, logs, tasks);
  }

  /// Creates a task. [seq] and [id] are assigned here.
  @override
  Future<Task> addTask({
    required String title,
    String notes = '',
    String? date,
    String? time,
    Repeat repeat = Repeat.none,
    List<int> weekdays = const [],
    bool byAi = false,
  }) async {
    final t = Task(
      id: newTaskId(),
      seq: nextTaskSeq(tasks),
      title: title.trim(),
      notes: notes.trim(),
      date: date,
      time: time,
      repeat: repeat,
      weekdays: List.of(weekdays),
      createdByAi: byAi,
    );
    tasks.add(t);
    await _commitTasks();
    return t;
  }

  /// Re-inserts a previously deleted task (for undo).
  @override
  Future<void> restoreTask(Task t) async {
    if (taskById(t.id) == null) tasks.add(t);
    await _commitTasks();
  }

  @override
  Future<void> updateTask(Task t, void Function(Task t) change) async {
    change(t);
    await _commitTasks();
  }

  @override
  Future<void> setTaskDone(Task t, DateTime day, bool done) async {
    if (t.isRepeating) {
      done ? t.doneDates.add(dayKey(day)) : t.doneDates.remove(dayKey(day));
    } else {
      done ? t.doneDates.add(dayKey(day)) : t.doneDates.clear();
    }
    await _commitTasks();
  }

  @override
  Future<void> deleteTask(Task t) async {
    tasks.removeWhere((x) => x.id == t.id);
    await _commitTasks();
  }

  Future<void> updateSettings(void Function(Settings s) change) async {
    change(settings);
    notifyListeners();
    await storage.saveSettings(settings);
    await notifications.reschedule(settings, logs, tasks);
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
    tasks = storage.loadTasks();
    notifyListeners();
    await notifications.reschedule(settings, logs, tasks);
  }

  Future<void> resetAll() async {
    await storage.clearAll();
    settings = Settings();
    logs = {};
    tasks = [];
    apiKey = '';
    notifyListeners();
    await notifications.reschedule(settings, logs, tasks);
  }
}
