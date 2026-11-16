import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Opt-in local diagnostics (off by default). Nothing leaves the device
/// unless the user shares a [report] from Settings › Diagnostics.
///
/// * Counters ([count]): each counter is its own preference key so the
///   background notification isolate and the UI isolate never overwrite
///   each other's values.
/// * Errors ([recordError]): the last [maxErrors] uncaught errors, captured
///   by [installErrorHandlers] from `FlutterError.onError` and
///   `PlatformDispatcher.instance.onError`.
///
/// While disabled every write is a no-op; turning it off deletes the data.
class Diagnostics {
  static const maxErrors = 50;
  static const _enabledKey = 'diagnostics.enabled';
  static const _sinceKey = 'diagnostics.since';
  static const _errorsKey = 'diagnostics.errors.v1';
  static const _counterPrefix = 'diagnostics.count.';

  static const appOpens = 'app_opens';
  static const reschedules = 'reschedules';
  static const remindersScheduled = 'reminders_scheduled';
  static const remindersFailed = 'reminders_failed';
  static const notificationActions = 'notification_actions';
  static const backgroundActions = 'notification_actions_background';
  static const opensFromNotification = 'opens_from_notification';

  static const counterLabels = {
    appOpens: 'App starts',
    reschedules: 'Reminder plans rebuilt',
    remindersScheduled: 'Reminders scheduled',
    remindersFailed: 'Reminders that failed to schedule',
    notificationActions: 'Notification actions (app open)',
    backgroundActions: 'Notification actions (in background)',
    opensFromNotification: 'App opened from a notification',
  };

  /// The instance used by app code that has no [SharedPreferences] at hand
  /// (set in `main`); null in tests unless set.
  static Diagnostics? global;

  final SharedPreferences prefs;
  final DateTime Function() _clock;
  Diagnostics(this.prefs, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  bool get enabled => prefs.getBool(_enabledKey) ?? false;

  DateTime? get since => DateTime.tryParse(prefs.getString(_sinceKey) ?? '');

  /// Turning diagnostics on or off starts from empty counters and errors.
  Future<void> setEnabled(bool on) async {
    if (on == enabled) return;
    await prefs.setBool(_enabledKey, on);
    await clear();
  }

  /// Re-reads values written by the background isolate.
  Future<void> reload() => prefs.reload();

  int counter(String name) => prefs.getInt('$_counterPrefix$name') ?? 0;

  /// Every counter, known ones first (zeros included).
  Map<String, int> get counters {
    final extra = prefs.getKeys().where((k) => k.startsWith(_counterPrefix)).map((k) => k.substring(_counterPrefix.length));
    return {
      for (final n in counterLabels.keys) n: counter(n),
      for (final n in extra.toList()..sort()) n: counter(n),
    };
  }

  Future<void> count(String name, [int by = 1]) async {
    if (!enabled || by == 0) return;
    await prefs.setInt('$_counterPrefix$name', counter(name) + by);
  }

  /// Newest last.
  List<ErrorRecord> get errors {
    try {
      final raw = jsonDecode(prefs.getString(_errorsKey) ?? '[]') as List;
      return raw.map((e) => ErrorRecord.fromJson((e as Map).cast<String, dynamic>())).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> recordError(Object error, StackTrace? stack, {String source = 'app'}) async {
    if (!enabled) return;
    final record = ErrorRecord(at: _clock(), source: source, message: _clip('$error', 2000), stack: _clipStack(stack));
    final list = ringPush(errors, record, maxErrors);
    await prefs.setString(_errorsKey, jsonEncode([for (final e in list) e.toJson()]));
  }

  Future<void> clear() async {
    for (final k in prefs.getKeys().where((k) => k.startsWith(_counterPrefix)).toList()) {
      await prefs.remove(k);
    }
    await prefs.remove(_errorsKey);
    enabled ? await prefs.setString(_sinceKey, _clock().toIso8601String()) : await prefs.remove(_sinceKey);
  }

  /// Records uncaught errors (while [enabled]); keeps the previous handlers
  /// running so errors still show up in the console.
  void installErrorHandlers() {
    final previousFlutter = FlutterError.onError;
    FlutterError.onError = (details) {
      recordError(details.exception, details.stack, source: details.library ?? 'flutter');
      (previousFlutter ?? FlutterError.presentError)(details);
    };
    final dispatcher = PlatformDispatcher.instance;
    final previousPlatform = dispatcher.onError;
    dispatcher.onError = (error, stack) {
      recordError(error, stack, source: 'platform');
      return previousPlatform?.call(error, stack) ?? false;
    };
  }

  /// Plain-text report for the share sheet: counters and errors only, no
  /// habit, prayer or task data.
  String report() {
    final b = StringBuffer()
      ..writeln('Daily Discipline diagnostics report')
      ..writeln('Generated: ${_clock().toIso8601String()}')
      ..writeln('Collecting since: ${since?.toIso8601String() ?? '-'}')
      ..writeln('Platform: ${_platform()}')
      ..writeln()
      ..writeln('Counters');
    for (final e in counters.entries) {
      b.writeln('  ${counterLabels[e.key] ?? e.key}: ${e.value}');
    }
    final errs = errors;
    b
      ..writeln()
      ..writeln('Errors (${errs.length}, newest first)');
    for (final e in errs.reversed) {
      b
        ..writeln('- ${e.at.toIso8601String()} [${e.source}] ${e.message}')
        ..writeln(e.stack.split('\n').map((l) => '    $l').join('\n'));
    }
    return b.toString();
  }

  static String _platform() {
    if (kIsWeb) return 'web';
    try {
      return '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    } catch (_) {
      return defaultTargetPlatform.name;
    }
  }

  static String _clip(String s, int max) => s.length <= max ? s : '${s.substring(0, max)}…';

  static String _clipStack(StackTrace? st) {
    if (st == null) return '';
    final lines = st.toString().trimRight().split('\n');
    return _clip(lines.take(20).join('\n'), 4000);
  }
}

/// Appends [item] to [buffer], dropping the oldest items beyond [capacity].
List<T> ringPush<T>(List<T> buffer, T item, int capacity) {
  final out = [...buffer, item];
  return out.length <= capacity ? out : out.sublist(out.length - capacity);
}

class ErrorRecord {
  final DateTime at;
  final String source;
  final String message;
  final String stack;
  const ErrorRecord({required this.at, required this.source, required this.message, this.stack = ''});

  Map<String, dynamic> toJson() => {'at': at.toIso8601String(), 'source': source, 'message': message, 'stack': stack};

  factory ErrorRecord.fromJson(Map<String, dynamic> j) => ErrorRecord(
        at: DateTime.tryParse('${j['at']}') ?? DateTime.fromMillisecondsSinceEpoch(0),
        source: '${j['source'] ?? ''}',
        message: '${j['message'] ?? ''}',
        stack: '${j['stack'] ?? ''}',
      );
}
