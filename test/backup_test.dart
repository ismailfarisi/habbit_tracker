import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_tracker/agent/habit_templates.dart';
import 'package:habit_tracker/habits/habit.dart';
import 'package:habit_tracker/models.dart';
import 'package:habit_tracker/screens/settings_screen.dart';
import 'package:habit_tracker/services/backup_service.dart';
import 'package:habit_tracker/services/storage.dart';

import 'support.dart';

const _v1Logs = {
  '2026-03-01': {
    'wakeAt': '2026-03-01T04:55:00.000',
    'prayers': ['Fajr', 'Dhuhr'],
    'trainingMinutes': 20,
  },
  '2026-03-02': {
    'prayers': ['Fajr'],
    'trainingMinutes': 5,
  },
};

String _v1Backup() => jsonEncode({
  'app': 'daily-discipline',
  'version': 1,
  'settings': Settings(trainingGoalMin: 15).toJson(),
  'logs': _v1Logs,
  'tasks': [Task(id: 't1', seq: 1, title: 'Read', repeat: Repeat.daily).toJson()],
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(mockPlugins);

  late Directory docs;
  setUp(() => docs = Directory.systemTemp.createTempSync('dd_backup_'));
  tearDown(() => docs.deleteSync(recursive: true));

  group('backup format', () {
    test('a version 1 backup imports, exports as version 2 and round-trips', () async {
      final a = await loadState();
      await a.importBackup(_v1Backup());
      final v2 = a.storage.exportJson(at: DateTime(2026, 4, 2, 9));
      final j = jsonDecode(v2) as Map<String, dynamic>;
      expect(j['version'], Storage.backupVersion);
      expect(j['exportedAt'], '2026-04-02T09:00:00.000');
      expect((j['habits'] as List).single['id'], articulationHabitId);
      expect(j['logs']['2026-03-01']['habits'][articulationHabitId]['minutes'], 20);

      final b = await loadState();
      await b.importBackup(v2);
      expect(b.habits.single.id, articulationHabitId);
      expect(b.habits.single.target, 15);
      expect(b.tasks.single.title, 'Read');
      expect(b.habitEntry(DateTime(2026, 3, 2), articulationHabitId).minutes, 5);
      expect(b.logFor(DateTime(2026, 3, 1)).prayers, {'Fajr', 'Dhuhr'});
      expect(jsonDecode(b.storage.exportJson(at: DateTime(2026, 4, 2, 9))), j);
    });

    test('describeBackup summarises v1 and v2 and rejects bad input', () async {
      final v1 = Storage.describeBackup(_v1Backup());
      expect(v1.version, 1);
      expect(v1.days, 2);
      expect(v1.tasks, 1);
      expect(v1.habits, isNull);
      expect(v1.describe(), '2 days of history, 1 task');

      final state = await loadState();
      await state.upsertHabit(habitFromTemplate(waterTemplate));
      final v2 = Storage.describeBackup(state.storage.exportJson(at: DateTime(2026, 4, 2)));
      expect(v2.version, 2);
      expect(v2.habits, 1);
      expect(v2.exportedAt, DateTime(2026, 4, 2));

      expect(() => Storage.describeBackup('not json'), throwsFormatException);
      expect(() => Storage.describeBackup('{"app":"other"}'), throwsFormatException);
      expect(() => Storage.describeBackup('{"app":"daily-discipline","version":1}'), throwsFormatException);
      expect(
        () =>
            Storage.describeBackup(jsonEncode({'app': 'daily-discipline', 'version': 99, 'settings': {}, 'logs': {}})),
        throwsFormatException,
      );
    });

    test('a newer-version backup is rejected and nothing changes', () async {
      final state = await loadState();
      await state.upsertHabit(habitFromTemplate(waterTemplate));
      final newer = jsonEncode({'app': 'daily-discipline', 'version': 3, 'settings': {}, 'logs': {}, 'habits': []});
      await expectLater(state.importBackup(newer), throwsFormatException);
      expect(state.storage.loadHabits(), hasLength(1));
    });
  });

  group('automatic backups', () {
    test('one daily backup per day, none without data, none when unchanged', () async {
      final state = await loadState();
      var now = DateTime(2026, 5, 1, 8);
      final svc = BackupService(state.storage, documents: () async => docs, clock: () => now);

      expect(await svc.runDailyIfDue(), isNull, reason: 'no data yet');
      final water = await state.upsertHabit(habitFromTemplate(waterTemplate));
      final first = await svc.runDailyIfDue();
      expect(first, isNotNull);
      expect(first!.file.path, endsWith('backups/backup-20260501-080000-daily.json'));
      expect(Storage.describeBackup(await first.read()).habits, 1);

      now = DateTime(2026, 5, 1, 20);
      await state.logHabit(now, water.id, HabitEntry(value: 3));
      expect(await svc.runDailyIfDue(), isNull, reason: 'already backed up today');

      now = DateTime(2026, 5, 2, 7);
      expect(await svc.runDailyIfDue(), isNotNull);
      now = DateTime(2026, 5, 3, 7);
      expect(await svc.runDailyIfDue(), isNull, reason: 'nothing changed since yesterday');
      expect((await svc.automaticBackups()).map((b) => b.at), [DateTime(2026, 5, 2, 7), DateTime(2026, 5, 1, 8)]);
    });

    test('keeps the newest 7 daily backups', () async {
      final state = await loadState();
      var now = DateTime(2026, 5, 1, 8);
      final svc = BackupService(state.storage, documents: () async => docs, clock: () => now);
      final water = await state.upsertHabit(habitFromTemplate(waterTemplate));
      for (var i = 0; i < 10; i++) {
        now = DateTime(2026, 5, 1 + i, 8);
        await state.logHabit(now, water.id, HabitEntry(value: i + 1));
        expect(await svc.runDailyIfDue(), isNotNull);
      }
      final kept = await svc.automaticBackups();
      expect(kept, hasLength(BackupService.keepDaily));
      expect(kept.first.at, DateTime(2026, 5, 10, 8));
      expect(kept.last.at, DateTime(2026, 5, 4, 8));
      File('${docs.path}/backups/notes.txt').writeAsStringSync('ignored');
      expect(await svc.automaticBackups(), hasLength(BackupService.keepDaily));
    });

    test('restore saves the current data first and can be undone', () async {
      final state = await loadState();
      var now = DateTime(2026, 5, 1, 8);
      final svc = BackupService(state.storage, documents: () async => docs, clock: () => now);
      await state.upsertHabit(habitFromTemplate(waterTemplate));

      now = DateTime(2026, 5, 1, 9);
      await svc.restore(state, _v1Backup());
      expect(state.habits.single.id, articulationHabitId);
      final saved = (await svc.automaticBackups()).single;
      expect(saved.beforeRestore, isTrue);

      now = DateTime(2026, 5, 1, 10);
      await svc.restore(state, await saved.read());
      expect(state.habits.single.title, 'Drink water');

      await expectLater(svc.restore(state, '{"app":"other"}'), throwsFormatException);
      expect(state.habits.single.title, 'Drink water');
      expect((await svc.automaticBackups()).where((b) => b.beforeRestore), hasLength(2));
    });

    test('keeps the newest 3 before-restore copies, apart from daily ones', () async {
      final state = await loadState();
      var now = DateTime(2026, 5, 1, 8);
      final svc = BackupService(state.storage, documents: () async => docs, clock: () => now);
      await state.upsertHabit(habitFromTemplate(waterTemplate));
      await svc.runDailyIfDue();
      for (var i = 1; i <= 5; i++) {
        now = DateTime(2026, 5, 1, 8, i);
        await svc.snapshot();
      }
      final all = await svc.automaticBackups();
      expect(all.where((b) => b.beforeRestore), hasLength(BackupService.keepSafety));
      expect(all.where((b) => !b.beforeRestore), hasLength(1));
    });

    test('export file is a dated version 2 backup', () async {
      final state = await loadState();
      final svc = BackupService(state.storage, documents: () async => docs, clock: () => DateTime(2026, 5, 1, 8));
      final f = await svc.writeExportFile(dir: docs);
      expect(f.path, endsWith('daily-discipline-backup-20260501.json'));
      expect(Storage.describeBackup(f.readAsStringSync()).version, 2);
    });

    test('AutoBackup.parse reads only its own file names', () {
      final b = AutoBackup.parse(File('/x/backup-20261116-073005-daily.json'))!;
      expect(b.at, DateTime(2026, 11, 16, 7, 30, 5));
      expect(b.reason, BackupService.dailyReason);
      expect(AutoBackup.parse(File('/x/daily-discipline-backup-20261116.json')), isNull);
    });
  });

  group('settings', () {
    testWidgets('import a backup file: confirm, restore, and the previous data is kept', (tester) async {
      final state = await loadState();
      await state.upsertHabit(habitFromTemplate(waterTemplate));
      final svc = BackupService(state.storage, documents: () async => docs, clock: () => DateTime(2026, 5, 1, 8));
      await tester.binding.setSurfaceSize(const Size(420, 4000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsScreen(state: state, backup: svc, pickBackupFile: () async => _v1Backup()),
          ),
        ),
      );

      await tester.scrollUntilVisible(find.text('Import backup file'), 300, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(find.text('Export backup file'), findsOneWidget);
      expect(find.text('Restore from automatic backup'), findsOneWidget);
      expect(find.text('Copy backup to clipboard'), findsOneWidget);
      expect(find.text('Paste backup'), findsOneWidget);

      await tester.tap(find.text('Import backup file'));
      await tester.pumpAndSettle();
      expect(find.text('Restore backup?'), findsOneWidget);
      expect(find.textContaining('2 days of history, 1 task'), findsOneWidget);

      await tester.tap(find.text('Restore'));
      for (var i = 0; i < 50 && state.habits.first.id != articulationHabitId; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.text('Backup restored.'), findsOneWidget);
      expect(state.habits.single.id, articulationHabitId);
      expect(state.tasks.single.title, 'Read');
      final saved = await tester.runAsync(svc.automaticBackups);
      expect(saved!.single.beforeRestore, isTrue);
    });

    testWidgets('a file that is not a backup shows an error and changes nothing', (tester) async {
      final state = await loadState();
      await state.upsertHabit(habitFromTemplate(waterTemplate));
      await tester.binding.setSurfaceSize(const Size(420, 4000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsScreen(state: state, pickBackupFile: () async => 'hello'),
          ),
        ),
      );
      await tester.scrollUntilVisible(find.text('Import backup file'), 300, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import backup file'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Not a Daily Discipline backup'), findsOneWidget);
      expect(find.text('Restore backup?'), findsNothing);
      expect(state.habits.single.title, 'Drink water');
    });
  });
}
