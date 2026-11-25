import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_tracker/logic/spoken_task.dart';
import 'package:habit_tracker/models.dart';
import 'package:habit_tracker/screens/plan_screen.dart';
import 'package:habit_tracker/services/voice_input.dart';
import 'package:habit_tracker/widgets/voice_input_button.dart';
import 'package:habit_tracker/widgets/voice_settings.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support.dart';

/// "Hears" [words] word by word, then finishes.
class FakeDictation implements Dictation {
  final String words;
  final bool finishOnStart;
  bool started = false;
  void Function()? _done;
  void Function(String)? _text;
  FakeDictation(this.words, {this.finishOnStart = true});

  @override
  String get name => 'Fake';

  @override
  Future<void> start({
    required void Function(String text) onText,
    required void Function() onDone,
    required void Function(String message) onError,
    String locale = '',
  }) async {
    started = true;
    _done = onDone;
    _text = onText;
    final w = words.split(' ');
    for (var i = 1; i <= w.length; i++) {
      onText(w.take(i).join(' '));
    }
    if (finishOnStart) onDone();
  }

  @override
  Future<void> stop() async {
    _text?.call(words);
    _done?.call();
  }

  @override
  void dispose() {}
}

class _Broken extends FakeDictation {
  _Broken() : super('');
  @override
  Future<void> start({
    required void Function(String text) onText,
    required void Function() onDone,
    required void Function(String message) onError,
    String locale = '',
  }) async => throw DictationUnavailable('no model');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(mockPlugins);
  final spoken = <String>[];
  setUp(() {
    spoken.clear();
    speakAloud = (t) async => spoken.add(t);
  });
  tearDown(() => dictationFactory = defaultDictation);

  group('parseSpokenTask', () {
    final now = DateTime(2026, 11, 17, 11); // Tuesday
    test('tomorrow at 5 pm', () {
      final p = parseSpokenTask('Remind me to call mum tomorrow at 5 p.m.', now);
      expect(p.title, 'Call mum');
      expect(p.date, '2026-11-18');
      expect(p.time, '17:00');
      expect(p.repeat, Repeat.none);
    });
    test('every day after a time without am/pm', () {
      final p = parseSpokenTask('Read Quran every day at 6:30', now);
      expect(p.title, 'Read Quran');
      expect(p.repeat, Repeat.daily);
      expect(p.time, '18:30');
      expect(p.date, isNull);
    });
    test('morning hint keeps am', () {
      final p = parseSpokenTask('go for a run every morning at 6', now);
      expect(p.title, 'Go for a run');
      expect(p.time, '06:00');
      expect(p.repeat, Repeat.daily);
    });
    test('weekly on named days', () {
      final p = parseSpokenTask('Gym every Monday and Thursday at 7 pm', now);
      expect(p.title, 'Gym');
      expect(p.repeat, Repeat.weekly);
      expect(p.weekdays, [1, 4]);
      expect(p.time, '19:00');
    });
    test('on a weekday picks the next one', () {
      final p = parseSpokenTask('Pay rent on Tuesday', now);
      expect(p.title, 'Pay rent');
      expect(p.date, '2026-11-24');
      expect(parseSpokenTask('dentist friday 10am', now).date, '2026-11-20');
      expect(parseSpokenTask('dentist friday 10am', now).time, '10:00');
    });
    test('tonight and 24h times', () {
      expect(parseSpokenTask('call Ali tonight at 9', now).time, '21:00');
      expect(parseSpokenTask('call Ali tonight at 9', now).date, '2026-11-17');
      expect(parseSpokenTask('standup at 14:15', now).time, '14:15');
    });
    test('plain text has no schedule', () {
      final p = parseSpokenTask('buy milk', now);
      expect(p.title, 'Buy milk');
      expect(p.hasSchedule, isFalse);
    });
  });

  testWidgets('mic button appends dictation to typed text', (tester) async {
    dictationFactory = () async => FakeDictation('and eggs');
    final c = TextEditingController(text: 'buy milk');
    String? finished;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextField(
            controller: c,
            decoration: InputDecoration(
              suffixIcon: VoiceInputButton(controller: c, onFinished: (t) => finished = t),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Speak'));
    await tester.pumpAndSettle();
    expect(c.text, 'buy milk and eggs');
    expect(finished, 'buy milk and eggs');
    expect(find.byTooltip('Speak'), findsOneWidget, reason: 'back to idle');
  });

  testWidgets('tapping again stops listening', (tester) async {
    final d = FakeDictation('hello there', finishOnStart: false);
    dictationFactory = () async => d;
    final c = TextEditingController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: VoiceInputButton(controller: c)),
      ),
    );
    await tester.tap(find.byTooltip('Speak'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Stop dictation'), findsOneWidget);
    await tester.tap(find.byTooltip('Stop dictation'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Speak'), findsOneWidget);
    expect(c.text, 'hello there');
  });

  testWidgets('Speak a task on Plan fills title, date and time, then says it back', (tester) async {
    tester.view.physicalSize = const Size(420, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = await tester.runAsync(
      () => loadState({
        'settings.v1': jsonEncode({'onboarded': true}),
        'habits.v1': '[]',
      }),
    );
    dictationFactory = () async => FakeDictation('Remind me to call mum tomorrow at 5 pm');
    await tester.pumpWidget(MaterialApp(home: PlanScreen(state: state!)));
    await tester.tap(find.byKey(const Key('voice-task')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Call mum'), findsOneWidget);
    expect(find.textContaining(RegExp(r'5:00\s?PM')), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final t = state.tasks.single;
    expect(t.title, 'Call mum');
    expect(t.time, '17:00');
    expect(DateTime.parse(t.date!).difference(DateTime.now()).inHours, inInclusiveRange(0, 48));
    expect(spoken.single, 'Added Call mum, tomorrow, at 5:00 PM');
  });

  test('FallbackDictation uses the phone when Whisper cannot start', () async {
    final fallback = FakeDictation('hi');
    final d = FallbackDictation(_Broken(), () => fallback);
    String? got;
    await d.start(onText: (t) => got = t, onDone: () {}, onError: (_) {});
    expect(fallback.started, isTrue);
    expect(got, 'hi');
    expect(d.name, 'Fake');
  });

  test('whisperLang maps locales', () {
    expect(whisperLang('ar_AE'), 'ar');
    expect(whisperLang('en-US'), 'en');
    expect(whisperLang(''), 'auto');
  });

  group('WhisperModels', () {
    late Directory dir;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('whisper');
      WhisperModels.modelDir = () async => dir.path;
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('download writes the model and reports progress; delete removes it', () async {
      final m = WhisperModels();
      final seen = <double>[];
      m.addListener(() {
        final p = m.progressOf('tiny');
        if (p != null) seen.add(p);
      });
      final client = MockClient.streaming((req, _) async {
        expect(req.url.toString(), contains('ggml-tiny.bin'));
        return http.StreamedResponse(
          Stream.fromIterable([List.filled(50, 1), List.filled(50, 2)]),
          200,
          contentLength: 100,
        );
      });
      await m.download('tiny', client: client);
      expect(m.isReady('tiny'), isTrue);
      expect(File('${dir.path}/ggml-tiny.bin').lengthSync(), 100);
      expect(seen, contains(0.5));
      expect(m.progressOf('tiny'), isNull);
      await m.delete('tiny');
      expect(m.isReady('tiny'), isFalse);
    });

    test('a failed download leaves no partial file', () async {
      final m = WhisperModels();
      await m.download('base', client: MockClient((_) async => http.Response('nope', 404)));
      expect(m.isReady('base'), isFalse);
      expect(m.error, contains('404'));
      expect(dir.listSync(), isEmpty);
    });

    test('cancelled download never installs a partial model', () async {
      final m = WhisperModels();
      final client = MockClient.streaming((req, _) async {
        m.cancel('tiny');
        return http.StreamedResponse(Stream.value([1, 2]), 200, contentLength: 2);
      });
      await m.download('tiny', client: client);
      expect(m.error, contains('cancelled'));
      expect(m.isReady('tiny'), isFalse);
      expect(dir.listSync(), isEmpty);
    });

    test('private voice fails closed even if system recognition was selected', () async {
      final settings = Settings(privateVoice: true, voiceEngine: 'system');
      voiceSettings = () => Settings.fromJson(settings.toJson());
      addTearDown(() => voiceSettings = Settings.new);
      await expectLater(defaultDictation(), throwsA(isA<DictationUnavailable>()));
      File('${dir.path}/ggml-base.bin').writeAsBytesSync([1]);
      expect(await defaultDictation(), isA<WhisperDictation>());
    });

    test('default engine: phone until the model exists, then Whisper', () async {
      voiceSettings = () => Settings(voiceEngine: 'whisper', whisperModel: 'tiny');
      expect(await defaultDictation(), isA<SystemDictation>());
      File('${dir.path}/ggml-tiny.bin').writeAsBytesSync([0]);
      expect(await defaultDictation(), isA<FallbackDictation>());
      voiceSettings = () => Settings(voiceEngine: 'system', whisperModel: 'tiny');
      expect(await defaultDictation(), isA<SystemDictation>());
      voiceSettings = Settings.new;
    });
  });

  test('voice settings round-trip', () {
    final s = Settings.fromJson(
      Settings(voiceEngine: 'system', whisperModel: 'tiny', speakConfirmations: false, readCoachReplies: true).toJson(),
    );
    expect([s.voiceEngine, s.whisperModel, s.speakConfirmations, s.readCoachReplies], ['system', 'tiny', false, true]);
    final d = Settings.fromJson({});
    expect([d.voiceEngine, d.whisperModel, d.speakConfirmations, d.readCoachReplies], ['whisper', 'base', true, false]);
  });

  testWidgets('Voice settings: engine switch hides the Whisper download', (tester) async {
    final dir = Directory.systemTemp.createTempSync('whisper');
    addTearDown(() => dir.deleteSync(recursive: true));
    WhisperModels.modelDir = () async => dir.path;
    final state = await tester.runAsync(
      () => loadState({
        'settings.v1': jsonEncode({'onboarded': true}),
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: VoiceSettingsSection(state: state!)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Download Whisper model'), findsOneWidget);
    expect(find.textContaining('142 MB'), findsWidgets);
    await tester.tap(find.text("Phone's built-in"));
    await tester.pumpAndSettle();
    expect(state.settings.voiceEngine, 'system');
    expect(find.text('Download Whisper model'), findsNothing);
  });
}
