import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'habits/habit.dart';
import 'logic/stats.dart';
import 'logic/tasks.dart';
import 'models.dart';
import 'services/focus_guard.dart';
import 'services/home_widget_service.dart';
import 'services/notification_service.dart';
import 'services/reminders.dart';
import 'services/storage.dart';
import 'services/task_tools.dart';
import 'services/tts.dart';
import 'services/voice_input.dart';
import 'goals/goal.dart';
import 'quran/surahs.dart';

/// App state and the only writer of persisted data.
///
/// Stable APIs for feature code:
/// * days: [logFor] (read), [setWake], [setPrayerStatus], [setPrayer],
///   [setBedtime], [logHabit]; all accept any day, past days included.
/// * habits: [habits] (all), [activeHabits], [habitById], [upsertHabit],
///   [archiveHabit], [deleteHabit], [habitEntry].
/// * tasks: the [TaskBackend] methods.
///
/// Every mutation notifies listeners, saves, and reschedules reminders.
class AppState extends ChangeNotifier implements TaskBackend {
  final Storage storage;
  final NotificationService notifications;

  Settings settings;
  Map<String, DayLog> logs;
  @override
  List<Task> tasks;

  /// Every habit, archived ones included. Mutate through [upsertHabit],
  /// [archiveHabit] and [deleteHabit].
  List<HabitDef> habits;
  List<Goal> goals = [];

  /// Text to send in the Chat tab (e.g. "review my goal"), set from other screens.
  final ValueNotifier<ChatRequest?> chatPrompt = ValueNotifier(null);
  String apiKey = '';

  /// Keys for OpenAI / xAI (Grok) voices; separate from the OpenRouter key.
  String openaiKey = '';
  String xaiKey = '';

  /// Set when a notification asks the UI to open a tab.
  final ValueNotifier<int?> requestedTab = ValueNotifier(null);

  /// Set to a habit id when a notification asks the UI to open that habit.
  final ValueNotifier<String?> requestedHabit = ValueNotifier(null);

  AppState._(this.storage, this.notifications, this.settings, this.logs, this.tasks, this.habits);

  static Future<AppState> load(Storage storage, NotificationService n) async {
    final s = AppState._(
      storage,
      n,
      storage.loadSettings(),
      storage.loadLogs(),
      storage.loadTasks(),
      storage.loadHabits(),
    );
    if (!storage.hasHabits) await storage.saveHabits(s.habits);
    s.goals = storage.loadGoals();
    s.apiKey = await storage.loadApiKey();
    s.openaiKey = await storage.loadSecret(Storage.openaiKeyName);
    s.xaiKey = await storage.loadSecret(Storage.xaiKeyName);
    voiceSettings = () => s.settings;
    ttsKeys = () => TtsKeys(openai: s.openaiKey, xai: s.xaiKey);
    return s;
  }

  /// The log of [day]; an empty one if nothing was logged. Read-only: use
  /// the setters below to change a day.
  DayLog logFor(DateTime day) => logs[dayKey(day)] ?? DayLog();
  DayLog dayLog(DateTime d) => logFor(d);
  DayLog get today => logFor(DateTime.now());

  DayLog _mutableDay(DateTime d) => logs.putIfAbsent(dayKey(d), DayLog.new);

  Future<void> _reschedule() async {
    await notifications.reschedule(settings, logs, tasks, habits: habits);
    await HomeWidgetService.publish(settings, logs, habits: habits, tasks: tasks);
    try {
      await FocusGuard.instance.configure(settings);
    } on PlatformException catch (e) {
      debugPrint('Focus config not saved: $e');
    }
  }

  Future<void> _commit({bool reschedule = true}) async {
    notifyListeners();
    await storage.saveLogs(logs);
    if (reschedule) await _reschedule();
  }

  /// Pick up changes made by the background notification isolate.
  Future<void> refreshFromDisk() async {
    await storage.reload();
    logs = storage.loadLogs();
    tasks = storage.loadTasks();
    habits = storage.loadHabits();
    goals = storage.loadGoals();
    notifyListeners();
    await _reschedule();
  }

  /// Sets (or with null clears) the wake time logged for [day]. The date
  /// part of [at] is replaced by [day].
  Future<void> setWake(DateTime day, DateTime? at) async {
    _mutableDay(day).wakeAt = at == null ? null : DateTime(day.year, day.month, day.day, at.hour, at.minute, at.second);
    // Silence the wake alarm if it is still ringing.
    if (at != null) await notifications.cancel(reminderId(day, 0));
    await _commit();
  }

  Future<void> markWake([DateTime? at]) {
    final now = at ?? DateTime.now();
    return setWake(now, now);
  }

  Future<void> undoWake() => setWake(DateTime.now(), null);

  Future<void> setBedtime(DateTime day, DateTime? at) async {
    _mutableDay(day).bedtimeAt = at;
    await _commit();
  }

  /// Marks prayer [name] on [day] with [status] ('onTime' | 'late' | 'qada'),
  /// or as not prayed when [status] is null.
  Future<void> setPrayerStatus(DateTime day, String name, String? status) async {
    if (!prayerNames.contains(name)) return;
    final log = _mutableDay(day);
    if (status == null) {
      log.prayers.remove(name);
      log.prayerStatus.remove(name);
    } else {
      log.prayers.add(name);
      log.prayerStatus[name] = prayerStatuses.contains(status) ? status : prayerOnTime;
    }
    await _commit();
  }

  /// Ticks a prayer on or off, keeping any status it already has.
  Future<void> setPrayer(DateTime day, String name, bool done) =>
      setPrayerStatus(day, name, done ? (logFor(day).prayerStatus[name] ?? prayerOnTime) : null);

  // ---------- Habits ----------
  List<HabitDef> get activeHabits => habits.where((h) => !h.archived).toList();

  HabitDef? habitById(String id) {
    for (final h in habits) {
      if (h.id == id) return h;
    }
    return null;
  }

  /// What was logged for [habitId] on [day] (an empty entry if nothing).
  HabitEntry habitEntry(DateTime day, String habitId) => logs[dayKey(day)]?.habits[habitId] ?? HabitEntry();

  Future<void> _commitHabits() async {
    notifyListeners();
    await storage.saveHabits(habits);
    await _reschedule();
  }

  /// Adds [habit], or replaces the habit with the same id. A new habit gets
  /// its notification `seq` here. Returns the stored habit.
  Future<HabitDef> upsertHabit(HabitDef habit) async {
    final i = habits.indexWhere((h) => h.id == habit.id);
    var stored = habit;
    if (i >= 0) {
      habits[i] = habit;
    } else {
      if (habit.seq == 0) {
        stored = HabitDef.fromJson({...habit.toJson(), 'seq': nextHabitSeq(habits)});
      }
      habits.add(stored);
    }
    await _commitHabits();
    return stored;
  }

  /// Hides a habit from Today and scoring but keeps its history.
  Future<void> archiveHabit(String id, {bool archived = true}) async {
    final h = habitById(id);
    if (h == null) return;
    h.archived = archived;
    await _commitHabits();
  }

  /// Removes a habit definition. Logged entries stay in the day logs.
  Future<void> deleteHabit(String id) async {
    habits.removeWhere((h) => h.id == id);
    await _commitHabits();
  }

  /// Replaces what is logged for [habitId] on [day].
  Future<void> logHabit(DateTime day, String habitId, HabitEntry entry) async {
    final log = _mutableDay(day);
    entry.isEmpty ? log.habits.remove(habitId) : log.habits[habitId] = entry;
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

  Future<void> rescheduleNow() => _reschedule();

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
    await _reschedule();
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

  /// The active goal a task or habit belongs to, if any.
  Goal? goalFor(String id) {
    for (final g in goals) {
      if (!g.archived && (g.taskIds.contains(id) || g.habitIds.contains(id))) return g;
    }
    return null;
  }

  /// Days before [day] on which [h] was done.
  int habitDaysDoneBefore(HabitDef h, DateTime day) {
    final before = dayKey(day);
    return logs.entries.where((e) => e.key.compareTo(before) < 0 && habitDone(e.value.habits[h.id], h)).length;
  }

  /// The Quran passage a task asks for on [day]. A repeating task moves on
  /// one portion per day it was done; a repeating memorise/read task without
  /// a per-day size uses its first passage's length as the daily portion and
  /// continues to the end of the surah.
  QuranRef? quranForTask(Task t, DateTime day) {
    final ref = quranPlanForTask(t);
    if (ref == null || !t.isRepeating) return ref;
    return ref.portion(taskSessionsBefore(t, day));
  }

  /// The whole passage a task works through, with its daily portion size.
  QuranRef? quranPlanForTask(Task t) {
    final q = t.guide?.quran;
    if (q == null || !t.isRepeating || q.perDay != null || q.mode == 'revise') return q;
    final end = q.surah >= 1 && q.surah <= surahInfo.length ? surahInfo[q.surah - 1].$3 : q.to;
    return QuranRef(q.surah, q.from, end, mode: q.mode, perDay: q.to - q.from + 1);
  }

  /// Sessions of a repeating task done before [day], plus those planned
  /// between today and a future [day].
  int taskSessionsBefore(Task t, DateTime day) {
    final before = dayKey(day);
    final planned = _plannedDays(day, (d) => t.isScheduledOn(d) && !t.doneDates.contains(dayKey(d)));
    return t.doneDates.where((d) => d.compareTo(before) < 0).length + planned;
  }

  /// Sessions of [h] done before [day], plus those planned until [day].
  int habitSessionsBefore(HabitDef h, DateTime day) =>
      habitDaysDoneBefore(h, day) + _plannedDays(day, (d) => h.isScheduledOn(d) && !habitDone(habitEntry(d, h.id), h));

  /// The planned session ([index], [count], [text]) for [day], if any.
  (int, int, String)? _session(List<String> s, int done) => s.isEmpty ? null : done < s.length ? (done + 1, s.length, s[done]) : null;

  (int, int, String)? sessionForHabit(HabitDef h, DateTime day) => _session(h.guide?.sessions ?? const [], habitSessionsBefore(h, day));

  (int, int, String)? sessionForTask(Task t, DateTime day) =>
      t.isRepeating ? _session(t.guide?.sessions ?? const [], taskSessionsBefore(t, day)) : null;

  /// Days from today up to (not including) a future [day] that [pending]
  /// says are still to do: their portions are assumed done by then.
  int _plannedDays(DateTime day, bool Function(DateTime d) pending) {
    var d = dateOnly(DateTime.now());
    final end = dateOnly(day);
    var n = 0;
    while (d.isBefore(end)) {
      if (pending(d)) n++;
      d = DateTime(d.year, d.month, d.day + 1);
    }
    return n;
  }

  /// The Quran passage [h] asks for on [day] (its next daily portion).
  QuranRef? quranFor(HabitDef h, DateTime day) => h.guide?.quran?.portion(habitSessionsBefore(h, day));

  Goal? goalById(String id) {
    for (final g in goals) {
      if (g.id == id) return g;
    }
    return null;
  }

  /// Adds [goal], or replaces the stored goal with the same id.
  Future<void> upsertGoal(Goal goal) async {
    final i = goals.indexWhere((g) => g.id == goal.id);
    i < 0 ? goals.add(goal) : goals[i] = goal;
    await saveGoals();
  }

  Future<void> deleteGoal(String id) async {
    goals.removeWhere((g) => g.id == id);
    await saveGoals();
  }

  Future<void> saveGoals() async {
    await storage.saveGoals(goals);
    notifyListeners();
  }

  Future<void> updateSettings(void Function(Settings s) change) async {
    change(settings);
    notifyListeners();
    await storage.saveSettings(settings);
    await _reschedule();
  }

  Future<void> setApiKey(String key) async {
    apiKey = key.trim();
    notifyListeners();
    await storage.saveApiKey(apiKey);
  }

  /// Saves the key for a cloud voice: [provider] is 'openai' or 'grok'.
  Future<void> setVoiceKey(String provider, String key) async {
    final k = key.trim();
    provider == 'openai' ? openaiKey = k : xaiKey = k;
    notifyListeners();
    await storage.saveSecret(provider == 'openai' ? Storage.openaiKeyName : Storage.xaiKeyName, k);
  }

  Future<void> importBackup(String raw) async {
    await storage.importJson(raw);
    settings = storage.loadSettings();
    logs = storage.loadLogs();
    tasks = storage.loadTasks();
    habits = storage.loadHabits();
    goals = storage.loadGoals();
    notifyListeners();
    await _reschedule();
  }

  Future<void> resetAll() async {
    await storage.clearAll();
    settings = Settings();
    logs = {};
    tasks = [];
    habits = [];
    goals = [];
    apiKey = '';
    openaiKey = '';
    xaiKey = '';
    notifyListeners();
    await _reschedule();
  }
}

/// A message for the Chat tab sent from another screen; [display] is shown
/// instead of [text] when the prompt is long.
class ChatRequest {
  final String text;
  final String? display;

  /// Opens (or starts) this goal's own conversation first.
  final String? goalId;
  const ChatRequest(this.text, {this.display, this.goalId});
}
