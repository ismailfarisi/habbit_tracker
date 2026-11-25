import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../app_state.dart';
import 'storage.dart';

/// Local snapshots and portable backups of everything [Storage.exportJson] holds (settings, logs, tasks,
/// habits, goals and Money; optionally Chat, never API keys).
///
/// * Export: a JSON file handed to the share sheet ([shareExport]).
/// * Import: a JSON file picked by the user ([pickBackupFile]) or pasted text,
///   restored with [restore].
/// * Automatic: once a day a copy is written to `<app documents>/backups`
///   ([runDailyIfDue], started by [startAutomatic]); the newest [keepDaily]
///   are kept. [restore] first saves a "before restore" copy (newest
///   [keepSafety] kept) so a wrong restore can be undone.
class BackupService {
  static const keepDaily = 7;
  static const keepSafety = 3;
  static const resetReason = 'before-reset';
  static const dailyReason = 'daily';
  static const safetyReason = 'before-restore';

  final Storage storage;
  final Future<Directory> Function() _documents;
  final Future<Directory> Function() _temporary;
  final bool _sandboxedPaths;
  final DateTime Function() _clock;

  BackupService(this.storage, {Future<Directory> Function()? documents, Future<Directory> Function()? temporary, DateTime Function()? clock})
      : _documents = documents ?? getApplicationDocumentsDirectory,
        _sandboxedPaths = (Platform.isAndroid || Platform.isIOS) || (documents != null && temporary != null),
        _temporary = temporary ?? getTemporaryDirectory,
        _clock = clock ?? DateTime.now;

  static AppLifecycleListener? _listener;

  // A resumed app may start an automatic copy while a Settings operation is
  // underway. Finish it before an erase, or take it from the new state after.
  static Future<void> _pending = Future.value();

  Future<T> _exclusive<T>(Future<T> Function() operation) {
    final result = _pending.then((_) => operation());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  /// Writes today's automatic backup now and whenever the app comes back to
  /// the foreground on a new day.
  void startAutomatic() {
    _listener?.dispose();
    _listener = AppLifecycleListener(onResume: () => unawaited(_runSafely()));
    unawaited(_runSafely());
  }

  Future<void> _runSafely() async {
    try {
      await runDailyIfDue();
    } catch (e) {
      debugPrint('Automatic backup failed: $e');
    }
  }

  Future<Directory> _dir() async {
    final d = Directory('${(await _documents()).path}/backups');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// Automatic and "before restore" backups, newest first.
  Future<List<AutoBackup>> automaticBackups() async {
    final d = await _dir();
    final out = <AutoBackup>[];
    await for (final f in d.list()) {
      if (f is! File) continue;
      final b = AutoBackup.parse(f);
      if (b != null) out.add(b);
    }
    out.sort((a, b) => b.at.compareTo(a.at));
    return out;
  }

  /// Writes today's backup unless there already is one, there is no data, or
  /// nothing changed since the last backup (so old copies are not pushed
  /// out by identical ones). Returns the new backup, if one was written.
  Future<AutoBackup?> runDailyIfDue() => _exclusive(() async {
    final now = _clock();
    final all = await automaticBackups();
    final daily = all.where((b) => b.reason == dailyReason).toList();
    if (daily.any((b) => _sameDay(b.at, now))) return null;
    if (storage.hasNoData) return null;
    final raw = storage.exportJson(at: now, includeChat: true);
    if (daily.isNotEmpty && _sameData(await daily.first.read(), raw)) return null;
    return _write(raw, now, dailyReason);
  });

  /// Saves the current data as a backup now (skipped when there is none).
  Future<AutoBackup?> snapshot({String reason = safetyReason}) => _exclusive(() => _snapshot(reason));

  Future<AutoBackup?> _snapshot(String reason) async {
    if (storage.hasNoData) return null;
    final now = _clock();
    return _write(storage.exportJson(at: now, includeChat: true), now, reason);
  }

  /// Replaces all data with the backup [raw], keeping a copy of the current
  /// data first. Throws [FormatException] for something that is not a backup;
  /// nothing changes in that case.
  Future<void> restore(AppState state, String raw) => _exclusive(() async {
    Storage.describeBackup(raw);
    await _snapshot(safetyReason);
    await state.importBackup(raw);
  });

  Future<AutoBackup> _write(String raw, DateTime at, String reason) async {
    final dir = await _dir();
    var f = File('${dir.path}/${AutoBackup.fileName(at, reason)}');
    while (await f.exists()) {
      at = at.add(const Duration(seconds: 1));
      f = File('${dir.path}/${AutoBackup.fileName(at, reason)}');
    }
    final part = File('${f.path}.part');
    await part.writeAsString(raw, flush: true);
    await part.rename(f.path);
    await _prune();
    return AutoBackup(f, at, reason);
  }

  Future<void> _prune() async {
    final all = await automaticBackups();
    for (final reason in [dailyReason, safetyReason, resetReason]) {
      final keep = reason == dailyReason ? keepDaily : keepSafety;
      for (final b in all.where((b) => b.reason == reason).skip(keep)) {
        await b.file.delete();
      }
    }
  }

  /// Reset retains the local recovery folder. Erase removes it as well.
  /// User-selected destinations outside the app and non-personal voice models
  /// in the support directory are outside both operations.
  Future<void> resetDevice(AppState state, {required bool keepRecovery}) => _exclusive(() async {
    if (!_sandboxedPaths) throw UnsupportedError('Device erasure requires a mobile app sandbox');
    if (keepRecovery) await _snapshot(resetReason);
    final docs = await _documents();
    if (await docs.exists()) {
      await for (final entry in docs.list(followLinks: false)) {
        if (keepRecovery && entry is Directory && entry.uri.pathSegments.where((s) => s.isNotEmpty).last == 'backups') {
          continue;
        }
        await entry.delete(recursive: true);
      }
    }
    final cache = await _temporary();
    if (await cache.exists()) {
      await for (final entry in cache.list(followLinks: false)) {
        await entry.delete(recursive: true);
      }
    }
    if (Platform.isIOS) await FilePicker.clearTemporaryFiles();
    await state.resetAll();
  });

  /// Writes an export file (to [dir], by default the temporary directory).
  Future<File> writeExportFile({Directory? dir}) async {
    final now = _clock();
    final d = dir ?? await getTemporaryDirectory();
    final f = File('${d.path}/${exportFileName(now)}');
    await f.writeAsString(storage.exportJson(at: now), flush: true);
    return f;
  }

  /// Opens the share sheet with a backup file. Returns false if dismissed.
  Future<bool> shareExport({Rect? origin}) async {
    final f = await writeExportFile();
    final r = await SharePlus.instance.share(ShareParams(
      files: [XFile(f.path, mimeType: 'application/json')],
      subject: 'Daily Discipline backup',
      sharePositionOrigin: origin,
    ));
    return r.status != ShareResultStatus.dismissed;
  }

  /// Lets the user pick a backup file and returns its text (null if cancelled).
  static Future<String?> pickBackupFile() async {
    final f = await FilePicker.pickFile(dialogTitle: 'Choose a Daily Discipline backup');
    if (f == null) return null;
    final bytes = await f.xFile.readAsBytes();
    try {
      return utf8.decode(bytes);
    } on FormatException {
      throw const FormatException('Not a Daily Discipline backup (the file is not text)');
    }
  }

  static String exportFileName(DateTime at) => 'daily-discipline-backup-${_stamp(at).substring(0, 8)}.json';

  static bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

  static bool _sameData(String a, String b) {
    Map strip(String raw) => (jsonDecode(raw) as Map)..remove('exportedAt');
    try {
      return jsonEncode(strip(a)) == jsonEncode(strip(b));
    } catch (_) {
      return false;
    }
  }
}

String _two(int v) => v.toString().padLeft(2, '0');
String _stamp(DateTime t) =>
    '${t.year}${_two(t.month)}${_two(t.day)}-${_two(t.hour)}${_two(t.minute)}${_two(t.second)}';

/// One automatic backup file: `backup-YYYYMMDD-HHmmss-<reason>.json`.
class AutoBackup {
  final File file;
  final DateTime at;
  final String reason;
  const AutoBackup(this.file, this.at, this.reason);

  static final _name = RegExp(r'^backup-(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})-([a-z-]+)\.json$');

  static String fileName(DateTime at, String reason) => 'backup-${_stamp(at)}-$reason.json';

  static AutoBackup? parse(File f) {
    final m = _name.firstMatch(f.uri.pathSegments.last);
    if (m == null) return null;
    final n = [for (var i = 1; i <= 6; i++) int.parse(m.group(i)!)];
    return AutoBackup(f, DateTime(n[0], n[1], n[2], n[3], n[4], n[5]), m.group(7)!);
  }

  bool get beforeRestore => reason == BackupService.safetyReason;

  Future<String> read() => file.readAsString();
}
