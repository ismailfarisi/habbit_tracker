import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_tracker/app_state.dart';
import 'package:habit_tracker/main.dart';
import 'package:habit_tracker/screens/onboarding_screen.dart';
import 'package:habit_tracker/screens/settings_screen.dart';
import 'package:habit_tracker/services/backup_service.dart';
import 'package:habit_tracker/services/portable_backup.dart';
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
  late Directory root, docs, cache, support;
  setUp(() {
    root = Directory.systemTemp.createTempSync('recovery_test');
    docs = Directory('${root.path}/docs')..createSync();
    support = Directory('${root.path}/support')..createSync();
    cache = Directory('${root.path}/cache')..createSync();
  });
  tearDown(() => root.deleteSync(recursive: true));

  BackupService backups(AppState state) => BackupService(
    state.storage,
    documents: () async => docs,
    temporary: () async => cache,
    support: () async => support,
  );

  test('portable backups use fresh authenticated encryption and restore optional chat', () async {
    final original = await loadState({
      'chat.threads.v1': _chat,
      'chat.current.v1': 'one',
      'finance.v1': '{"currency":"AED","budgets":{"Food":7800}}',
    });
    final plain = original.storage.exportJson();
    expect(jsonDecode(plain), isNot(contains('chat')));
    final raw = original.storage.exportJson(includeChat: true);
    const password = 'example backup passphrase';
    await expectLater(PortableBackup.encrypt(raw, 'short'), throwsFormatException);
    final encrypted = await PortableBackup.encrypt(raw, password);
    final second = await PortableBackup.encrypt(raw, password);
    expect(PortableBackup.isEncrypted(encrypted), isTrue);
    expect(encrypted, isNot(contains('Food')));
    expect(encrypted, isNot(contains('Shopping')));
    expect(jsonDecode(second)['salt'], isNot(jsonDecode(encrypted)['salt']));
    expect(jsonDecode(second)['box'], isNot(jsonDecode(encrypted)['box']));
    final file = await backups(original).writeExportFile(dir: cache, contents: encrypted);
    expect(file.path, endsWith('.encrypted.json'));
    expect(await file.readAsString(), encrypted);
    await expectLater(PortableBackup.decrypt(encrypted, 'wrong password'), throwsFormatException);
    final tampered = jsonDecode(encrypted) as Map;
    final box = base64Decode(tampered['box'] as String);
    box[box.length ~/ 2] ^= 1;
    tampered['box'] = base64Encode(box);
    await expectLater(PortableBackup.decrypt(jsonEncode(tampered), password), throwsFormatException);
    final unlocked = await PortableBackup.decrypt(encrypted, password);
    expect(unlocked, raw);
    final target = await loadState();
    await backups(target).restore(target, unlocked);
    expect(target.storage.prefs.getString('chat.current.v1'), 'one');
    expect(target.finance.budgets['Food'], 7800);
    await backups(target).restore(target, plain);
    expect(target.storage.prefs.getString('chat.threads.v1'), _chat);
  });

  testWidgets('clipboard export previews domains and only includes chats on request', (tester) async {
    final state = await loadState({'chat.threads.v1': _chat});
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (c) async {
        if (c.method == 'Clipboard.setData') copied = (c.arguments as Map)['text'] as String;
        return null;
      },
    );
    await tester.binding.setSurfaceSize(const Size(420, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsScreen(state: state, section: SettingsSection.backup),
        ),
      ),
    );
    await tester.tap(find.text('Copy backup to clipboard'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Chat omitted'), findsOneWidget);
    expect(find.textContaining('Money ('), findsOneWidget);
    expect(find.textContaining('API keys, screen-time history'), findsOneWidget);
    expect(copied, isNull);
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(find.textContaining('at least 10 characters'), findsOneWidget);
    await tester.tap(find.text('Include chat history'));
    await tester.tap(find.text('Password protection'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Chat: 1 conversation'), findsOneWidget);
    expect(find.textContaining('Anyone who receives'), findsOneWidget);
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(jsonDecode(copied!)['chat']['threads'].single['id'], 'one');
  });

  testWidgets('bulk replacement disposes a live chat history route and reloads conversations', (tester) async {
    final state = await loadState({
      'settings.v1': '{"onboarded":true}',
      'chat.threads.v1': _chat,
      'chat.current.v1': 'one',
    });
    state.apiKey = 'sk-or-v1-synthetic-test-key-0001';
    await tester.pumpWidget(DailyDisciplineApp(state: state));
    await tester.tap(find.text('Chat').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-history')));
    await tester.pumpAndSettle();
    expect(find.text('Shopping'), findsOneWidget);

    final raw = jsonDecode(state.storage.exportJson(includeChat: true)) as Map;
    raw['chat']['threads'][0]['title'] = 'Restored conversation';
    raw['chat']['threads'][0]['messages'][0]['content'] = 'Restored message';
    await state.importBackup(jsonEncode(raw));
    await tester.pumpAndSettle();
    expect(find.text('Shopping'), findsNothing);
    await tester.tap(find.text('Chat').last);
    await tester.pumpAndSettle();
    expect(find.text('Restored message'), findsOneWidget);
    await state.resetAll();
    await tester.pumpAndSettle();
    expect(find.byType(OnboardingScreen), findsOneWidget);
    expect(find.text('Restored message'), findsNothing);
  });

  test('invalid late domains leave every preference identical on relaunch', () async {
    final state = await loadState({'goals.v1': _goals, 'tasks.v1': _tasks, 'chat.threads.v1': _chat});
    final prefs = state.storage.prefs;
    final before = {for (final key in prefs.getKeys()) key: prefs.get(key)};
    for (final invalid in [
      {
        'settings': {
          'focusApps': [false],
        },
      },
      {
        'logs': {
          '2026-05-01': {
            'habits': {
              'practice': {
                'sessions': ['lost session'],
              },
            },
          },
        },
      },
      {
        'logs': {
          '2026-05-01': {'wakeAt': 'broken timestamp'},
        },
      },
      {
        'goals': [42],
      },
      {
        'goals': [
          {
            'id': 'bad',
            'habitIds': [3],
          },
        ],
      },
      {'finance': []},
      {
        'finance': {'budgets': []},
      },
      {'habits': 'bad'},
      {
        'chat': {
          'threads': [{}],
        },
      },
    ]) {
      final raw = jsonEncode({
        'app': 'daily-discipline',
        'version': 2,
        'settings': {},
        'logs': {},
        'tasks': [],
        ...invalid,
      });
      await expectLater(backups(state).restore(state, raw), throwsFormatException);
      final reopened = (await _relaunch()).storage.prefs;
      expect({for (final k in reopened.getKeys()) k: reopened.get(k)}, before);
      expect(await backups(state).automaticBackups(), isEmpty);
    }
  });

  test('a damaged local record prevents a reset that promises a recoverable copy', () async {
    final state = await loadState({'goals.v1': '[false]'});
    final svc = backups(state);
    expect(state.storage.hasNoData, isFalse);
    await expectLater(svc.resetDevice(state, keepRecovery: true), throwsFormatException);
    expect((await _relaunch()).storage.prefs.getString('goals.v1'), '[false]');
    expect(await svc.automaticBackups(), isEmpty);
    await svc.resetDevice(state, keepRecovery: false);
    expect((await _relaunch()).storage.hasNoData, isTrue);
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

  test('backups preserve and preview each currency without combining amounts', () async {
    final data = {
      'currency': 'AED',
      'otherLedgers': [
        {
          'currency': 'USD',
          'budgets': {'Home': 14500},
          'customCategories': ['Home'],
          'recurring': [
            {'id': 'r1', 'name': 'Rent', 'category': 'Home', 'amount': 10000},
          ],
        },
      ],
    };
    final source = await loadState({'finance.v1': jsonEncode(data)});
    final raw = source.storage.exportJson();
    final summary = Storage.describeBackup(raw).manifest();
    expect(summary, contains('Money (AED): 0 entries, 0 budgets'));
    expect(summary, contains('Money (USD): 0 entries, 1 budget'));
    expect(summary, contains('1 recurring item, 1 custom category'));
    final destination = await loadState();
    await backups(destination).restore(destination, raw);
    expect(jsonDecode((await _relaunch()).storage.exportJson())['finance'], data);
  });

  test('zakat-only Money gets a daily snapshot and a working Undo', () async {
    final state = await loadState({'finance.v1': '{"currency":"AED","zakat":{"cash":3200}}'});
    final svc = backups(state);
    final daily = await svc.runDailyIfDue();
    expect(daily, isNotNull);
    expect(jsonDecode(await daily!.read())['finance']['zakat']['cash'], 3200);
    final empty = jsonEncode({'app': 'daily-discipline', 'settings': {}, 'logs': {}, 'habits': []});
    await svc.restore(state, empty);
    expect(state.finance.zakat.cash, 0);
    final undo = (await svc.automaticBackups()).singleWhere((b) => b.beforeRestore);
    await svc.restore(state, await undo.read());
    expect((await _relaunch()).finance.zakat.cash, 3200);
  });

  test('reset keeps recoverable domains; erase also removes all local copies', () async {
    FlutterSecureStorage.setMockInitialValues({
      'openrouter_api_key': 'fixture-1',
      'openai_api_key': 'fixture-2',
      'xai_api_key': 'fixture-3',
    });
    final state = await loadState({
      'settings.v1': '{"locationName":"home"}',
      'logs.v1': '{"2026-05-01":{"prayers":["Fajr"]}}',
      'tasks.v1': _tasks,
      'habits.v1': '[{"id":"h"}]',
      'goals.v1': _goals,
      'chat.threads.v1': _chat,
      'chat.current.v1': 'one',
      'chat.v1': '[]',
      'finance.v1': '{"currency":"AED"}',
      'diagnostics.enabled': true,
    });
    state.chatPrompt.value = const ChatRequest('pending request');
    final svc = backups(state);
    await svc.runDailyIfDue();
    Directory('${support.path}/quran-audio').createSync();
    File('${support.path}/quran-audio/chapter.mp3.part').writeAsStringSync('audio');
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
    expect(info.manifest(), contains('Money (AED)'));
    expect(raw, isNot(contains('fixture-')));
    expect(cache.listSync(), isEmpty);
    expect(support.listSync(), isEmpty);
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
