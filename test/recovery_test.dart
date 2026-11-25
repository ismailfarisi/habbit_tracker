import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_tracker/app_state.dart';
import 'package:habit_tracker/services/backup_service.dart';
import 'package:habit_tracker/services/notification_service.dart';
import 'package:habit_tracker/services/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'support.dart';

const _chat = '[{"id":"one","title":"Shopping","messages":[{"role":"user","content":"List"}]}]';
const _tasks = '[{"id":"t1","title":"Existing task"}]';
const _goals = '[{"id":"g1","title":"Existing goal"}]';

Future<AppState> _relaunch() async {
  SharedPreferences.resetStatic();
  return AppState.load(await Storage.open(), NotificationService.instance);
}

class _FailOnce extends InMemorySharedPreferencesStore {
  _FailOnce() : super.withData({'flutter.tasks.v1': _tasks, 'flutter.goals.v1': _goals});

  bool failed = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (!failed && key == 'flutter.goals.v1') {
      failed = true;
      return false;
    }
    return super.setValue(valueType, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(mockPlugins);
  late Directory root, docs, cache;
  setUp(() {
    root = Directory.systemTemp.createTempSync('recovery_test');
    docs = Directory('${root.path}/docs')..createSync();
    cache = Directory('${root.path}/cache')..createSync();
  });
  tearDown(() => root.deleteSync(recursive: true));

  BackupService backups(AppState state) =>
      BackupService(state.storage, documents: () async => docs, temporary: () async => cache);

  test('invalid late domains leave every preference identical on relaunch', () async {
    final state = await loadState({'goals.v1': _goals, 'tasks.v1': _tasks, 'chat.threads.v1': _chat});
    final prefs = state.storage.prefs;
    final before = {for (final key in prefs.getKeys()) key: prefs.get(key)};
    for (final invalid in [
      {'goals': [42]},
      {'goals': [{'id': 'bad', 'habitIds': [3]}]},
      {'finance': []},
      {'finance': {'budgets': []}},
      {'habits': 'bad'},
      {'chat': {'threads': [{}]}},
    ]) {
      final raw = jsonEncode({'app': 'daily-discipline', 'version': 2, 'settings': {}, 'logs': {},
        'tasks': [], ...invalid});
      await expectLater(backups(state).restore(state, raw), throwsFormatException);
      final reopened = (await _relaunch()).storage.prefs;
      expect({for (final k in reopened.getKeys()) k: reopened.get(k)}, before);
      expect(await backups(state).automaticBackups(), isEmpty);
    }
  });

  test('a failed platform write rolls back values and absent keys', () async {
    final store = _FailOnce();
    SharedPreferencesStorePlatform.instance = store;
    final state = await _relaunch();
    final before = await store.getAll();
    final raw = jsonEncode({'app': 'daily-discipline', 'settings': {}, 'logs': {}, 'habits': []});
    await expectLater(state.importBackup(raw), throwsStateError);
    expect(store.failed, isTrue);
    expect((await _relaunch()).tasks.single.title, 'Existing task');
    expect(await store.getAll(), before);
  });

  test('a relaunch recovers an interrupted restore', () async {
    final state = await loadState({
      'tasks.v1': '[]',
      'finance.v1': '{}',
      'restore.undo.v1': jsonEncode({'tasks.v1': _tasks, 'finance.v1': null}),
    });
    expect(state.tasks.single.id, 't1');
    expect(state.storage.prefs.containsKey('finance.v1'), isFalse);
    expect(state.storage.prefs.containsKey('restore.undo.v1'), isFalse);
  });

  test('zakat-only Money gets a daily snapshot and a working Undo', () async {
    final state = await loadState({'finance.v1': '{"currency":"AED","zakat":{"cash":3200}}'});
    final svc = backups(state);
    final daily = await svc.runDailyIfDue();
    expect(daily, isNotNull);
    expect(Storage.describeBackup(await daily!.read()).money!.zakat.cash, 3200);
    final empty = jsonEncode({'app': 'daily-discipline', 'settings': {}, 'logs': {}, 'habits': []});
    await svc.restore(state, empty);
    expect(state.finance.zakat.cash, 0);
    final undo = (await svc.automaticBackups()).singleWhere((b) => b.beforeRestore);
    await svc.restore(state, await undo.read());
    expect((await _relaunch()).finance.zakat.cash, 3200);
  });

  test('reset keeps recoverable domains; erase also removes all local copies', () async {
    FlutterSecureStorage.setMockInitialValues({
      'openrouter_api_key': 'fixture-1', 'openai_api_key': 'fixture-2', 'xai_api_key': 'fixture-3',
    });
    final state = await loadState({
      'settings.v1': '{"locationName":"home"}',
      'logs.v1': '{"2026-05-01":{"prayers":["Fajr"]}}',
      'tasks.v1': _tasks, 'habits.v1': '[{"id":"h"}]', 'goals.v1': _goals,
      'chat.threads.v1': _chat, 'chat.current.v1': 'one', 'chat.v1': '[]',
      'finance.v1': '{"currency":"AED"}', 'diagnostics.enabled': true,
    });
    state.chatPrompt.value = const ChatRequest('pending request');
    final svc = backups(state);
    await svc.runDailyIfDue();
    File('${docs.path}/private.md').writeAsStringSync('notes');
    File('${cache.path}/goals-okf.zip').writeAsStringSync('archive');
    await svc.resetDevice(state, keepRecovery: true);
    expect(state.chatPrompt.value, isNull);
    expect(state.dataGeneration, 1);
    final fresh = await _relaunch();
    expect(fresh.storage.hasNoData, isTrue);
    expect(fresh.goals, isEmpty);
    expect(fresh.settings.locationName, isEmpty);
    expect(fresh.apiKey, isEmpty);
    expect(fresh.openaiKey, isEmpty);
    expect(fresh.xaiKey, isEmpty);
    expect(fresh.storage.prefs.getKeys(), {'habits.v1'});
    final copies = await svc.automaticBackups();
    final raw = await copies.singleWhere((b) => b.reason == BackupService.resetReason).read();
    final info = Storage.describeBackup(raw);
    expect(info.chats, 1);
    expect(info.goals, 1);
    expect(info.days, 1);
    expect(info.tasks, 1);
    expect(info.habits, 1);
    expect(info.money!.currency, 'AED');
    expect(raw, isNot(contains('fixture-')));
    expect(cache.listSync(), isEmpty);
    expect(File('${docs.path}/private.md').existsSync(), isFalse);

    final newSvc = backups(fresh);
    await newSvc.restore(fresh, raw);
    expect(fresh.storage.prefs.getString('chat.current.v1'), 'one');
    expect(fresh.goals.single.title, 'Existing goal');
    await Future.wait([newSvc.runDailyIfDue(), newSvc.resetDevice(fresh, keepRecovery: false)]);
    final erased = await _relaunch();
    expect(erased.storage.hasNoData, isTrue);
    expect(erased.storage.prefs.getKeys(), {'habits.v1'});
    expect(docs.listSync(), isEmpty);
  });
}
