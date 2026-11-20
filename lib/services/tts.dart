/// Spoken output: the phone's text-to-speech, Kokoro on this phone (model
/// downloaded on demand), or OpenAI / Grok with the user's own key. Any
/// failure falls back to the phone's voice.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'voice_input.dart' show voiceSettings;

const ttsEngines = {
  'system': "Phone's voice",
  'kokoro': 'Kokoro (on this phone)',
  'openai': 'OpenAI',
  'grok': 'Grok (xAI)',
};

/// English speakers of Kokoro v1.0 (speaker id -> label); ids 20+ are British.
const kokoroVoices = {
  0: 'Alloy · US female', 1: 'Aoede · US female', 2: 'Bella · US female', 3: 'Heart · US female', //
  4: 'Jessica · US female', 5: 'Kore · US female', 6: 'Nicole · US female', 7: 'Nova · US female',
  8: 'River · US female', 9: 'Sarah · US female', 10: 'Sky · US female', 11: 'Adam · US male',
  12: 'Echo · US male', 13: 'Eric · US male', 14: 'Fenrir · US male', 15: 'Liam · US male',
  16: 'Michael · US male', 17: 'Onyx · US male', 18: 'Puck · US male', 20: 'Alice · UK female',
  21: 'Emma · UK female', 22: 'Isabella · UK female', 23: 'Lily · UK female', 24: 'Daniel · UK male',
  25: 'Fable · UK male', 26: 'George · UK male', 27: 'Lewis · UK male',
};

/// Voices of `gpt-audio-1.5` in Chat Completions.
const openAiVoices = ['alloy', 'ash', 'ballad', 'coral', 'echo', 'sage', 'shimmer', 'verse', 'marin', 'cedar'];
const grokVoices = ['eve', 'ara', 'rex', 'sal', 'leo'];

/// OpenAI's `/v1/audio/speech` models shut down on 2027-01-06, so speech
/// comes from this audio chat model instead, told to read verbatim.
const openAiTtsModel = 'gpt-audio-1.5';

class TtsKeys {
  final String openai;
  final String xai;
  const TtsKeys({this.openai = '', this.xai = ''});
}

/// The user's OpenAI / xAI keys; wired to AppState on load.
TtsKeys Function() ttsKeys = () => const TtsKeys();

/// Last cloud/Kokoro failure (shown in Settings); null after a success.
final lastTtsError = ValueNotifier<String?>(null);

class TtsException implements Exception {
  final String message;
  TtsException(this.message);
  @override
  String toString() => message;
}

/// Thrown for text an engine can't read (e.g. Arabic on Kokoro); the
/// phone's voice reads it instead, without reporting an error.
class UnsupportedTtsText implements Exception {}

abstract class Speaker {
  String get name;
  Future<void> speak(String text, {String locale = '', double rate = 0.5});
  Future<void> stop();
}

class SystemSpeaker implements Speaker {
  static final _tts = FlutterTts();

  @override
  String get name => "Phone's voice";

  @override
  Future<void> speak(String text, {String locale = '', double rate = 0.5}) async {
    if (locale.isNotEmpty) await _tts.setLanguage(locale.replaceAll('_', '-'));
    await _tts.setSpeechRate(rate);
    await _tts.awaitSpeakCompletion(true);
    await _tts.speak(text);
  }

  @override
  Future<void> stop() => _tts.stop();
}

/// Plays encoded audio ([ext] is 'mp3' or 'wav') and completes when it has
/// finished or was stopped. Replace in tests.
Future<void> Function(Uint8List bytes, String ext) playAudio = _playAudio;
Future<void> Function() stopAudio = () async => _player?.stop();

AudioPlayer? _player;

Future<void> _playAudio(Uint8List bytes, String ext) async {
  final dir = await getTemporaryDirectory();
  final f = File('${dir.path}/tts_${DateTime.now().microsecondsSinceEpoch}.$ext');
  await f.writeAsBytes(bytes);
  final p = _player ??= AudioPlayer();
  final done = p.onPlayerStateChanged.firstWhere((s) => s == PlayerState.completed || s == PlayerState.stopped);
  await p.play(DeviceFileSource(f.path));
  await done.timeout(const Duration(minutes: 10), onTimeout: () => PlayerState.stopped);
  try {
    await f.delete();
  } catch (_) {}
}

var _generation = 0;

/// Splits [text] into sentence-sized chunks (long ones at commas), so the
/// first one can play while the rest are still being made.
List<String> speechChunks(String text, {int max = 220}) {
  final parts = RegExp(r'[^.!?…\n]+[.!?…]*', unicode: true)
      .allMatches(text)
      .map((m) => m.group(0)!.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  final out = <String>[];
  for (final p in parts) {
    if (p.length <= max) {
      out.add(p);
      continue;
    }
    var cur = '';
    for (final piece in p.split(RegExp(r'(?<=,)\s+'))) {
      if (cur.isNotEmpty && cur.length + piece.length + 1 > max) {
        out.add(cur);
        cur = piece;
      } else {
        cur = cur.isEmpty ? piece : '$cur $piece';
      }
    }
    if (cur.isNotEmpty) out.add(cur);
  }
  // Very short fragments ("Hi!") are merged forward, except the first,
  // which starts playing almost at once.
  final merged = <String>[];
  for (final c in out) {
    if (merged.length > 1 && merged.last.length < 24) {
      merged[merged.length - 1] = '${merged.last} $c';
    } else {
      merged.add(c);
    }
  }
  return merged.isEmpty ? [text.trim()] : merged;
}

/// An engine that produces audio clips, played back to back: the next
/// chunk is synthesized while the current one plays.
abstract class ClipSpeaker implements Speaker {
  Future<(Uint8List, String)> synthesize(String text, String locale, double rate);

  @override
  Future<void> speak(String text, {String locale = '', double rate = 0.5}) async {
    final gen = ++_generation;
    final chunks = speechChunks(text);
    var next = synthesize(chunks.first, locale, rate);
    for (var i = 0; i < chunks.length; i++) {
      final (bytes, ext) = await next;
      if (gen != _generation) return;
      if (i + 1 < chunks.length) {
        next = synthesize(chunks[i + 1], locale, rate);
        // Errors surface when awaited; don't let an early one go unhandled.
        next.ignore();
      }
      await playAudio(bytes, ext);
      if (gen != _generation) return;
    }
  }

  @override
  Future<void> stop() async {
    _generation++;
    await stopAudio();
  }
}

String _errorOf(String who, http.Response res) {
  var detail = '';
  try {
    final e = (jsonDecode(res.body) as Map)['error'];
    detail = e is Map ? '${e['message'] ?? ''}' : '${e ?? ''}';
  } catch (_) {}
  return '$who: HTTP ${res.statusCode}${detail.isEmpty ? '' : ' $detail'}';
}

class OpenAiSpeaker extends ClipSpeaker {
  final String apiKey;
  final String voice;
  final http.Client client;
  OpenAiSpeaker(this.apiKey, this.voice, {http.Client? client}) : client = client ?? http.Client();

  @override
  String get name => 'OpenAI';

  @override
  Future<(Uint8List, String)> synthesize(String text, String locale, double rate) async {
    final res = await client.post(
      Uri.parse('https://api.openai.com/v1/chat/completions'),
      headers: {'Authorization': 'Bearer $apiKey', 'Content-Type': 'application/json'},
      body: jsonEncode({
        'model': openAiTtsModel,
        'modalities': ['text', 'audio'],
        'audio': {'voice': voice, 'format': 'mp3'},
        'messages': [
          {
            'role': 'system',
            'content':
                'You are a text-to-speech voice. Read the user message aloud exactly as written, word for word, '
                'in its own language. Do not answer it, add anything or leave anything out.',
          },
          {'role': 'user', 'content': text},
        ],
      }),
    );
    if (res.statusCode != 200) throw TtsException(_errorOf('OpenAI', res));
    final audio = (((jsonDecode(res.body) as Map)['choices'] as List).first as Map)['message']['audio'];
    final data = audio is Map ? audio['data'] as String? : null;
    if (data == null || data.isEmpty) throw TtsException('OpenAI: no audio in the reply');
    return (base64Decode(data), 'mp3');
  }
}

const _grokLanguages = {
  'en', 'ar-EG', 'ar-SA', 'ar-AE', 'bn', 'zh', 'fr', 'de', 'hi', 'id', 'it', 'ja', 'ko', //
  'pt-BR', 'pt-PT', 'ru', 'es-MX', 'es-ES', 'tr', 'vi',
};

/// BCP-47 code for xAI TTS from a speech locale ('ar_AE' -> 'ar-AE',
/// 'en_US' -> 'en', '' -> 'auto').
String grokLanguage(String locale) {
  if (locale.isEmpty) return 'auto';
  final code = locale.replaceAll('_', '-');
  if (_grokLanguages.contains(code)) return code;
  final lang = code.split('-').first;
  if (_grokLanguages.contains(lang)) return lang;
  if (lang == 'ar') return 'ar-AE';
  return 'auto';
}

class GrokSpeaker extends ClipSpeaker {
  final String apiKey;
  final String voice;
  final http.Client client;
  GrokSpeaker(this.apiKey, this.voice, {http.Client? client}) : client = client ?? http.Client();

  @override
  String get name => 'Grok';

  @override
  Future<(Uint8List, String)> synthesize(String text, String locale, double rate) async {
    final res = await client.post(
      Uri.parse('https://api.x.ai/v1/tts'),
      headers: {'Authorization': 'Bearer $apiKey', 'Content-Type': 'application/json'},
      body: jsonEncode({'text': text, 'voice_id': voice, 'language': grokLanguage(locale)}),
    );
    if (res.statusCode != 200) throw TtsException(_errorOf('Grok', res));
    return (res.bodyBytes, 'mp3');
  }
}

/// 16-bit mono PCM WAV from float samples in [-1, 1].
Uint8List wavBytes(Float32List samples, int sampleRate) {
  final data = ByteData(44 + samples.length * 2);
  void str(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      data.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  data.setUint32(4, 36 + samples.length * 2, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  str(36, 'data');
  data.setUint32(40, samples.length * 2, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(44 + i * 2, (samples[i].clamp(-1.0, 1.0) * 32767).round(), Endian.little);
  }
  return data.buffer.asUint8List();
}

/// Synthesizes with Kokoro and returns WAV bytes. Replace in tests.
Future<Uint8List> Function(String modelDir, String text, int sid, double speed) kokoroSynth = (dir, text, sid, speed) =>
    KokoroWorker.forModel(dir, british: sid >= 20).synth(text, sid, speed);

/// A background isolate that keeps one Kokoro model loaded, so only the
/// first sentence pays the model load.
class KokoroWorker {
  static KokoroWorker? _current;

  final String modelDir;
  final bool british;
  final Future<SendPort> _port;

  KokoroWorker._(this.modelDir, this.british) : _port = _spawn(modelDir, british);

  static KokoroWorker forModel(String dir, {required bool british}) {
    final c = _current;
    if (c != null && c.modelDir == dir && c.british == british) return c;
    c?.dispose();
    return _current = KokoroWorker._(dir, british);
  }

  /// Starts loading the model in the background (e.g. when Kokoro is picked).
  static void warmUp(String dir, int sid) => forModel(dir, british: sid >= 20);

  static void disposeCurrent() {
    _current?.dispose();
    _current = null;
  }

  static Future<SendPort> _spawn(String dir, bool british) async {
    final ready = ReceivePort();
    final threads = Platform.numberOfProcessors.clamp(2, 4);
    await Isolate.spawn(_main, [ready.sendPort, dir, british, threads]);
    return await ready.first as SendPort;
  }

  static void _main(List<Object> args) {
    final reply = args[0] as SendPort;
    final dir = args[1] as String;
    sherpa.initBindings();
    final tts = sherpa.OfflineTts(
      sherpa.OfflineTtsConfig(
        model: sherpa.OfflineTtsModelConfig(
          kokoro: sherpa.OfflineTtsKokoroModelConfig(
            model: '$dir/model.int8.onnx',
            voices: '$dir/voices.bin',
            tokens: '$dir/tokens.txt',
            dataDir: '$dir/espeak-ng-data',
            lexicon: args[2] as bool ? '$dir/lexicon-gb-en.txt' : '$dir/lexicon-us-en.txt',
          ),
          numThreads: args[3] as int,
        ),
      ),
    );
    final inbox = ReceivePort();
    reply.send(inbox.sendPort);
    inbox.listen((msg) {
      final m = msg as List<Object?>;
      if (m.first == 'stop') {
        tts.free();
        inbox.close();
        return;
      }
      final out = m[4] as SendPort;
      try {
        final audio = tts.generate(text: m[1] as String, sid: m[2] as int, speed: m[3] as double);
        if (audio.samples.isEmpty) {
          out.send('Kokoro produced no audio');
        } else {
          out.send(TransferableTypedData.fromList([wavBytes(audio.samples, audio.sampleRate)]));
        }
      } catch (e) {
        out.send('Kokoro: $e');
      }
    });
  }

  Future<Uint8List> synth(String text, int sid, double speed) async {
    final port = await _port;
    final rp = ReceivePort();
    port.send(['synth', text, sid, speed, rp.sendPort]);
    final r = await rp.first;
    if (r is String) throw TtsException(r);
    return (r as TransferableTypedData).materialize().asUint8List();
  }

  void dispose() {
    _port.then((p) => p.send(const ['stop']), onError: (_) {});
  }
}

final _arabic = RegExp(r'[\u0600-\u06FF\u0750-\u077F\uFB50-\uFDFF\uFE70-\uFEFF]');

class KokoroSpeaker extends ClipSpeaker {
  final String modelDir;
  final int voice;
  KokoroSpeaker(this.modelDir, this.voice);

  @override
  String get name => 'Kokoro';

  @override
  Future<(Uint8List, String)> synthesize(String text, String locale, double rate) async {
    if (_arabic.hasMatch(text) || locale.startsWith('ar')) throw UnsupportedTtsText();
    final speed = (rate / 0.5).clamp(0.6, 1.5).toDouble();
    return (await kokoroSynth(modelDir, text, voice, speed), 'wav');
  }
}

/// Tries [primary]; on any failure the phone's voice reads the text.
class FallbackSpeaker implements Speaker {
  final Speaker primary;
  final Speaker fallback;
  FallbackSpeaker(this.primary, this.fallback);

  @override
  String get name => primary.name;

  @override
  Future<void> speak(String text, {String locale = '', double rate = 0.5}) async {
    try {
      await primary.speak(text, locale: locale, rate: rate);
      lastTtsError.value = null;
    } on UnsupportedTtsText {
      await fallback.speak(text, locale: locale, rate: rate);
    } catch (e) {
      lastTtsError.value = '$e';
      await fallback.speak(text, locale: locale, rate: rate);
    }
  }

  @override
  Future<void> stop() async {
    await primary.stop();
    await fallback.stop();
  }
}

/// The engine picked in Settings, or the phone's voice when it isn't usable
/// yet (no key, Kokoro not downloaded).
Future<Speaker> defaultSpeaker() async {
  final s = voiceSettings();
  final keys = ttsKeys();
  final system = SystemSpeaker();
  switch (s.ttsEngine) {
    case 'kokoro':
      final k = KokoroModel.instance;
      await k.refresh();
      if (k.ready) return FallbackSpeaker(KokoroSpeaker(await k.modelDir(), s.kokoroVoice), system);
    case 'openai':
      if (keys.openai.isNotEmpty) return FallbackSpeaker(OpenAiSpeaker(keys.openai, s.openaiVoice), system);
    case 'grok':
      if (keys.xai.isNotEmpty) return FallbackSpeaker(GrokSpeaker(keys.xai, s.grokVoice), system);
  }
  return system;
}

Future<Speaker> Function() speakerFactory = defaultSpeaker;

Speaker? _current;

/// Reads [text] with the chosen engine and completes when it has finished.
Future<void> speakText(String text, {double rate = 0.5}) async {
  await stopSpeaking();
  final clean = text.replaceAll(RegExp(r'[*#_`]'), '').trim();
  if (clean.isEmpty) return;
  final sp = _current = await speakerFactory();
  try {
    await sp.speak(clean, locale: voiceSettings().speechLocale, rate: rate);
  } catch (e) {
    lastTtsError.value = '$e';
  }
}

/// Reads [text] aloud. Replace in tests.
Future<void> Function(String text) speakAloud = speakText;

Future<void> stopSpeaking() async {
  final sp = _current;
  _current = null;
  try {
    await sp?.stop();
  } catch (_) {}
}

/// The downloadable Kokoro v1.0 model (int8; English voices are used).
class KokoroModel extends ChangeNotifier {
  static final instance = KokoroModel();
  static const id = 'kokoro-int8-multi-lang-v1_0';
  static const sizeMb = 132;
  static final url = Uri.parse('https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/$id.tar.bz2');

  /// Overridable for tests.
  static Future<String> Function() baseDir = () async => '${(await getApplicationSupportDirectory()).path}/tts';
  static Future<void> Function(String archive, String outDir) extract = (archive, outDir) =>
      Isolate.run(() => extractFileToDisk(archive, outDir, throwOnError: true));

  bool ready = false;
  bool unpacking = false;

  /// 0..1 while downloading, null otherwise.
  double? progress;
  String? error;

  bool get busy => progress != null || unpacking;

  Future<String> modelDir() async => '${await baseDir()}/$id';

  Future<void> refresh() async {
    bool ok;
    try {
      final dir = await modelDir();
      ok =
          await File('$dir/model.int8.onnx').exists() &&
          await File('$dir/voices.bin').exists() &&
          await File('$dir/lexicon-us-en.txt').exists();
    } catch (_) {
      ok = false;
    }
    if (ok != ready) {
      ready = ok;
      notifyListeners();
    }
  }

  Future<void> download({http.Client? client}) async {
    if (busy || ready) return;
    final base = await baseDir();
    final archive = File('$base/$id.tar.bz2');
    final part = File('${archive.path}.part');
    final c = client ?? http.Client();
    error = null;
    progress = 0;
    notifyListeners();
    IOSink? sink;
    try {
      final res = await c.send(http.Request('GET', url));
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
      final total = res.contentLength ?? sizeMb * 1000 * 1000;
      await part.parent.create(recursive: true);
      sink = part.openWrite();
      var got = 0;
      var shown = 0.0;
      await for (final chunk in res.stream) {
        sink.add(chunk);
        got += chunk.length;
        final p = (got / total).clamp(0.0, 1.0);
        if (p - shown >= 0.01) {
          progress = shown = p;
          notifyListeners();
        }
      }
      await sink.close();
      sink = null;
      await part.rename(archive.path);
      progress = null;
      unpacking = true;
      notifyListeners();
      await extract(archive.path, base);
      await refresh();
      if (!ready) throw const FileSystemException('model files missing after unpacking');
    } catch (e) {
      error = 'Download failed: $e';
      await sink?.close();
    } finally {
      for (final f in [part, archive]) {
        try {
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
      progress = null;
      unpacking = false;
      if (client == null) c.close();
      notifyListeners();
    }
  }

  Future<void> delete() async {
    KokoroWorker.disposeCurrent();
    final dir = Directory(await modelDir());
    if (await dir.exists()) await dir.delete(recursive: true);
    ready = false;
    notifyListeners();
  }
}
