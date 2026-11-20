import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_tracker/app_state.dart';
import 'package:habit_tracker/models.dart';
import 'package:habit_tracker/services/tts.dart';
import 'package:habit_tracker/services/voice_input.dart' show voiceSettings;
import 'package:habit_tracker/widgets/voice_settings.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support.dart';

class RecordingSpeaker implements Speaker {
  final List<String> said = [];
  @override
  String get name => 'Rec';
  @override
  Future<void> speak(String text, {String locale = '', double rate = 0.5}) async => said.add(text);
  @override
  Future<void> stop() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(mockPlugins);

  final played = <(int, String)>[];
  setUp(() {
    played.clear();
    playAudio = (bytes, ext) async => played.add((bytes.length, ext));
    stopAudio = () async {};
    lastTtsError.value = null;
  });
  tearDown(() {
    voiceSettings = Settings.new;
    ttsKeys = () => const TtsKeys();
    speakerFactory = defaultSpeaker;
  });

  test('settings: TTS fields default, round-trip and reject bad values', () {
    final d = Settings();
    expect([d.ttsEngine, d.kokoroVoice, d.openaiVoice, d.grokVoice], ['system', 3, 'coral', 'eve']);
    final s = Settings.fromJson(
      Settings(ttsEngine: 'grok', kokoroVoice: 9, openaiVoice: 'marin', grokVoice: 'ara').toJson(),
    );
    expect([s.ttsEngine, s.kokoroVoice, s.openaiVoice, s.grokVoice], ['grok', 9, 'marin', 'ara']);
    final bad = Settings.fromJson({'ttsEngine': 'elevenlabs', 'kokoroVoice': 99});
    expect([bad.ttsEngine, bad.kokoroVoice], ['system', 27]);
  });

  test('grokLanguage maps speech locales to xAI codes', () {
    expect(grokLanguage(''), 'auto');
    expect(grokLanguage('ar_AE'), 'ar-AE');
    expect(grokLanguage('en_US'), 'en');
    expect(grokLanguage('ar_QA'), 'ar-AE');
    expect(grokLanguage('ml_IN'), 'auto');
  });

  test('Grok posts text, voice and language to /v1/tts and plays the mp3', () async {
    late http.Request req;
    final client = MockClient((r) async {
      req = r;
      return http.Response.bytes(List.filled(10, 1), 200);
    });
    await GrokSpeaker('xai-key', 'ara', client: client).speak('Marhaba', locale: 'ar_AE');
    expect(req.url.toString(), 'https://api.x.ai/v1/tts');
    expect(req.headers['Authorization'], 'Bearer xai-key');
    expect(jsonDecode(req.body), {'text': 'Marhaba', 'voice_id': 'ara', 'language': 'ar-AE'});
    expect(played.single, (10, 'mp3'));
  });

  test('OpenAI asks gpt-audio-1.5 for mp3 and plays the decoded audio', () async {
    late Map body;
    final client = MockClient((r) async {
      body = jsonDecode(r.body) as Map;
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {
                'audio': {'data': base64Encode([1, 2, 3, 4])},
              },
            },
          ],
        }),
        200,
      );
    });
    await OpenAiSpeaker('sk', 'marin', client: client).speak('Call mum at 5');
    expect(body['model'], 'gpt-audio-1.5');
    expect(body['modalities'], ['text', 'audio']);
    expect(body['audio'], {'voice': 'marin', 'format': 'mp3'});
    expect((body['messages'] as List).last, {'role': 'user', 'content': 'Call mum at 5'});
    expect(played.single, (4, 'mp3'));
  });

  test('a failing cloud voice falls back to the phone and reports why', () async {
    final client = MockClient((_) async => http.Response(jsonEncode({'error': {'message': 'Invalid key'}}), 401));
    final phone = RecordingSpeaker();
    await FallbackSpeaker(GrokSpeaker('bad', 'eve', client: client), phone).speak('Hello');
    expect(phone.said, ['Hello']);
    expect(lastTtsError.value, 'Grok: HTTP 401 Invalid key');
    expect(played, isEmpty);
  });

  test('Kokoro hands Arabic to the phone silently and speaks English itself', () async {
    kokoroSynth = (dir, text, sid, speed) async => Uint8List(8);
    final phone = RecordingSpeaker();
    final sp = FallbackSpeaker(KokoroSpeaker('/m', 3), phone);
    await sp.speak('الحمد لله');
    expect(phone.said, ['الحمد لله']);
    expect(lastTtsError.value, isNull);
    await sp.speak('Good morning');
    expect(played.single, (8, 'wav'));
  });

  test('defaultSpeaker uses the phone until a key or the model exists', () async {
    voiceSettings = () => Settings(ttsEngine: 'openai');
    expect(await defaultSpeaker(), isA<SystemSpeaker>());
    ttsKeys = () => const TtsKeys(openai: 'sk');
    expect(((await defaultSpeaker()) as FallbackSpeaker).primary, isA<OpenAiSpeaker>());
    voiceSettings = () => Settings(ttsEngine: 'grok');
    expect(await defaultSpeaker(), isA<SystemSpeaker>());
    ttsKeys = () => const TtsKeys(xai: 'x');
    expect(((await defaultSpeaker()) as FallbackSpeaker).primary, isA<GrokSpeaker>());
  });

  test('speechChunks splits sentences, keeps a short first one, merges short later ones', () {
    expect(speechChunks('Hi! This is how your coach will sound.'), ['Hi!', 'This is how your coach will sound.']);
    expect(speechChunks('One. Two. Three is longer than the rest.'), ['One.', 'Two. Three is longer than the rest.']);
    expect(speechChunks('No punctuation here'), ['No punctuation here']);
    final long = List.filled(30, 'word,').join(' ');
    expect(speechChunks(long, max: 60).every((c) => c.length <= 60), isTrue);
  });

  test('clips play in order and the next chunk is made while one plays', () async {
    final events = <String>[];
    kokoroSynth = (dir, text, sid, speed) async {
      events.add('make $text');
      return Uint8List(1);
    };
    playAudio = (bytes, ext) async {
      events.add('play');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    };
    await KokoroSpeaker('/m', 3).speak('Hi! This is how your coach will sound.');
    expect(events, ['make Hi!', 'make This is how your coach will sound.', 'play', 'play']);
  });

  test('wavBytes writes a 16-bit mono RIFF header', () {
    final w = wavBytes(Float32List.fromList([0, 1, -1]), 24000);
    expect(ascii.decode(w.sublist(0, 4)), 'RIFF');
    expect(ascii.decode(w.sublist(8, 12)), 'WAVE');
    final b = ByteData.sublistView(w);
    expect(b.getUint32(24, Endian.little), 24000);
    expect(b.getInt16(46, Endian.little), 32767);
    expect(w.length, 44 + 6);
  });

  group('KokoroModel', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('kokoro');
      KokoroModel.baseDir = () async => tmp.path;
    });
    tearDown(() => tmp.delete(recursive: true));

    test('downloads, unpacks, reports ready and deletes', () async {
      final tar = Archive()
        ..add(ArchiveFile.bytes('${KokoroModel.id}/model.int8.onnx', [1, 2]))
        ..add(ArchiveFile.bytes('${KokoroModel.id}/voices.bin', [3]))
        ..add(ArchiveFile.bytes('${KokoroModel.id}/tokens.txt', [4]))
        ..add(ArchiveFile.bytes('${KokoroModel.id}/lexicon-us-en.txt', [5]));
      final bz = BZip2Encoder().encodeBytes(TarEncoder().encodeBytes(tar));
      Uri? asked;
      final client = MockClient((r) async {
        asked = r.url;
        return http.Response.bytes(bz, 200);
      });
      final m = KokoroModel();
      final seen = <String>[];
      m.addListener(() => seen.add(m.unpacking ? 'unpack' : m.progress == null ? 'idle' : 'dl'));
      await m.download(client: client);
      expect(asked, KokoroModel.url);
      expect(m.error, isNull);
      expect(m.ready, isTrue);
      expect(seen, containsAllInOrder(['dl', 'unpack', 'idle']));
      expect(File('${tmp.path}/${KokoroModel.id}.tar.bz2').existsSync(), isFalse);
      await m.delete();
      expect(m.ready, isFalse);
      expect(Directory(await m.modelDir()).existsSync(), isFalse);
    });

    test('a failed download leaves no files and shows the error', () async {
      final m = KokoroModel();
      await m.download(client: MockClient((_) async => http.Response('nope', 404)));
      expect(m.ready, isFalse);
      expect(m.error, contains('404'));
      expect(tmp.listSync(recursive: true), isEmpty);
    });
  });

  testWidgets('Settings: picking Kokoro starts the download; OpenAI shows a key field', (tester) async {
    late Directory tmp;
    late AppState state;
    await tester.runAsync(() async {
      tmp = await Directory.systemTemp.createTemp('kokoro-ui');
      state = await loadState({'settings.v1': jsonEncode({'onboarded': true})});
    });
    KokoroModel.baseDir = () async => tmp.path;
    var extracted = 0;
    KokoroModel.extract = (a, o) async => extracted++;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListView(children: [SpokenVoiceSection(state: state)]))));
    await tester.pump();
    expect(find.byKey(const Key('kokoro-download')), findsNothing);

    await tester.tap(find.byKey(const Key('tts-engine')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kokoro (on this phone)').last);
    await tester.pump();
    expect(state.settings.ttsEngine, 'kokoro');
    expect(find.byKey(const Key('kokoro-download')), findsOneWidget);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    expect(find.textContaining('Download failed').evaluate().isNotEmpty || extracted > 0 || KokoroModel.instance.busy, isTrue);

    await tester.tap(find.byKey(const Key('tts-engine')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OpenAI').last);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'OpenAI API key'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'sk-test');
    await tester.tap(find.byTooltip('Save key'));
    await tester.pumpAndSettle();
    expect(state.openaiKey, 'sk-test');
    expect(find.byKey(const Key('openai-voice')), findsOneWidget);
    await tester.runAsync(() => tmp.delete(recursive: true));
  });
}
