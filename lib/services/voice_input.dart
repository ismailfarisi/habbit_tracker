/// Voice dictation: on-device Whisper (whisper.cpp) by default, the phone's
/// built-in recognizer as fallback while the model isn't downloaded or if
/// Whisper fails to start. Tests swap [dictationFactory].
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:record/record.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:whisper_ggml/whisper_ggml.dart';

import '../models.dart';

export 'tts.dart' show speakAloud, speakText, stopSpeaking;

/// A single listen-until-stopped dictation.
abstract class Dictation {
  /// Shown while listening, e.g. "Whisper" or "Phone".
  String get name;

  /// Starts listening. [onText] receives the whole transcript so far and
  /// [onDone] fires exactly once when listening ends (after [stop], on
  /// silence, or after an error reported via [onError]).
  Future<void> start({
    required void Function(String text) onText,
    required void Function() onDone,
    required void Function(String message) onError,
    String locale = '',
  });

  Future<void> stop();
  void dispose();
}

/// The current voice settings; [AppState] points this at its settings.
Settings Function() voiceSettings = Settings.new;

final listeningEngine = ValueNotifier<String?>(null);
Dictation? _listening;
Future<bool> Function() confirmPhoneFallback = () async => false;
Future<void> finishDictation() async => _listening?.stop();

void _listeningStarted(Dictation d, String locale) {
  _listening = d;
  listeningEngine.value = '${d.name} · ${locale.isEmpty ? 'Automatic language' : locale.replaceAll('_', '-')}';
}

void _listeningEnded(Dictation d) {
  if (_listening != d) return;
  _listening = null;
  listeningEngine.value = null;
}

/// Picks the engine for the current settings. Replace in tests.
Future<Dictation> Function() dictationFactory = defaultDictation;

Future<Dictation> defaultDictation() async {
  final s = voiceSettings();
  if (s.privateVoice || s.voiceEngine == 'whisper') {
    final models = WhisperModels.instance;
    await models.refresh();
    if (models.isReady(s.whisperModel)) {
      final local = WhisperDictation(await models.pathFor(s.whisperModel));
      return s.privateVoice ? local : FallbackDictation(local, () => SystemDictation(fallback: true));
    }
    if (s.privateVoice) throw DictationUnavailable('Private voice needs the Whisper model. Type instead or download it in Settings → Voice.');
    return SystemDictation(fallback: true);
  }
  return SystemDictation();
}

/// Whisper's language code for a `speech_to_text` locale such as `ar_AE`.
String whisperLang(String locale) {
  final code = locale.split(RegExp('[_-]')).first.toLowerCase();
  return code.isEmpty ? 'auto' : code;
}

/// Tries [primary]; if it fails to start, runs a fresh [fallback] instead.
class FallbackDictation implements Dictation {
  final Dictation primary;
  final Dictation Function() fallback;
  Dictation? _active;
  bool _disposed = false;
  FallbackDictation(this.primary, this.fallback);

  @override
  String get name => (_active ?? primary).name;

  @override
  Future<void> start({
    required void Function(String text) onText,
    required void Function() onDone,
    required void Function(String message) onError,
    String locale = '',
  }) async {
    try {
      _active = primary;
      await primary.start(onText: onText, onDone: onDone, onError: onError, locale: locale);
    } on DictationUnavailable catch (e) {
      if (_disposed) return;
      debugPrint('Whisper unavailable, using system dictation: ${e.message}');
      primary.dispose();
      final f = _active = fallback();
      await f.start(onText: onText, onDone: onDone, onError: onError, locale: locale);
    }
  }

  @override
  Future<void> stop() async => _active?.stop();

  @override
  void dispose() {
    _disposed = true;
    _active?.dispose();
  }
}

/// Thrown by [Dictation.start] when the engine can't run at all, so a
/// fallback can take over.
class DictationUnavailable implements Exception {
  final String message;
  DictationUnavailable(this.message);
  @override
  String toString() => message;
}

/// Streams 16 kHz microphone audio into a live whisper.cpp session.
class WhisperDictation implements Dictation {
  static const finalPassWait = Duration(milliseconds: 1200);

  final String modelPath;
  AudioRecorder? _rec;
  AudioRecorder get _recorder => _rec ??= AudioRecorder();
  WhisperLiveSession? _session;
  StreamSubscription<String>? _partials;
  Timer? _limit;
  void Function()? _onDone;
  void Function(String)? _onText;
  bool _finished = false;
  bool _stopping = false;
  String _last = '';

  WhisperDictation(this.modelPath);

  @override
  String get name => 'Whisper';

  @override
  Future<void> start({
    required void Function(String text) onText,
    required void Function() onDone,
    required void Function(String message) onError,
    String locale = '',
  }) async {
    _onDone = onDone;
    _onText = onText;
    if (!await _recorder.hasPermission()) {
      onError('Microphone permission is needed for voice input.');
      _finish();
      return;
    }
    if (_finished) return;
    _listeningStarted(this, locale);
    final Stream<Uint8List> pcm;
    try {
      pcm = await _recorder.startStream(
        const RecordConfig(encoder: AudioEncoder.pcm16bits, sampleRate: 16000, numChannels: 1),
      );
      if (_finished) {
        await _recorder.stop();
        return;
      }
      final session = await WhisperController().transcribeLive(
        modelPath: modelPath,
        pcm16Stream: pcm,
        lang: whisperLang(locale),
        suppressNonSpeechTokens: true,
        keepModelLoaded: true,
      );
      if (_finished) {
        await session.stop();
        return;
      }
      _session = session;
    } catch (e) {
      if (_finished) return;
      _listeningEnded(this);
      await _recorder.stop().catchError((_) => null);
      throw DictationUnavailable('$e');
    }
    _partials = _session!.partials.listen(
      (t) => onText(_last = _clean(t)),
      onError: (Object e) => onError('Whisper: $e'),
    );
    _limit = Timer(const Duration(minutes: 3), stop);
  }

  @override
  Future<void> stop() async {
    if (_finished || _stopping) return;
    _stopping = true;
    _limit?.cancel();
    final session = _session;
    if (session == null) _finish();
    try {
      await _recorder.stop();
      if (session != null) {
        final text = await session.stop().timeout(finalPassWait, onTimeout: () => _last);
        final clean = _clean(text);
        if (!_finished && clean.isNotEmpty) _onText?.call(clean);
      }
    } finally {
      _finish();
    }
  }

  void _finish() {
    if (_finished) return;
    _finished = true;
    _listeningEnded(this);
    _onDone?.call();
  }

  /// Drops whisper's non-speech markers like "[BLANK_AUDIO]" or "(music)".
  static String _clean(String t) =>
      t.replaceAll(RegExp(r'\[[^\]]*\]|\([^)]*\)'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

  @override
  void dispose() {
    _listeningEnded(this);
    _limit?.cancel();
    _partials?.cancel();
    final running = !_finished;
    _finished = true;
    unawaited(_shutdown(running));
  }

  Future<void> _shutdown(bool running) async {
    if (_rec == null) return;
    if (running) {
      try {
        await _recorder.stop();
      } catch (_) {}
      await _session?.stop();
    }
    await _recorder.dispose();
  }
}

/// The phone's speech recognizer (`speech_to_text`). The plugin instance
/// is a singleton that keeps its first listeners, so status and errors are
/// routed to whichever dictation is currently active.
class SystemDictation implements Dictation {
  final bool fallback;
  SystemDictation({this.fallback = false});
  static final _stt = SpeechToText();
  static SystemDictation? _active;
  static bool? _available;

  void Function()? _onDone;
  void Function(String)? _onError;
  bool _finished = false;

  @override
  String get name => 'Phone';

  static Future<bool> _init() async => _available ??= await _stt
      .initialize(
        onStatus: (s) {
          if (s == 'done' || s == 'notListening') _active?._finish();
        },
        onError: (e) {
          _active?._onError?.call(e.errorMsg);
          if (e.permanent) _active?._finish();
        },
      )
      .catchError((_) => false);

  @override
  Future<void> start({
    required void Function(String text) onText,
    required void Function() onDone,
    required void Function(String message) onError,
    String locale = '',
  }) async {
    _onDone = onDone;
    _onError = onError;
    if (fallback && !voiceSettings().privateVoice && !await confirmPhoneFallback()) {
      _finish();
      return;
    }
    if (voiceSettings().privateVoice) {
      _finish();
      return;
    }
    if (_finished) return;
    _active = this;
    if (!await _init()) {
      _available = null;
      onError('Speech recognition is not available on this device.');
      _finish();
      return;
    }
    if (_finished) return;
    _listeningStarted(this, locale);
    try {
      await _stt.listen(
      onResult: (r) => onText(r.recognizedWords),
      listenOptions: SpeechListenOptions(
        listenFor: const Duration(minutes: 3),
        pauseFor: const Duration(seconds: 5),
        partialResults: true,
        listenMode: ListenMode.dictation,
        localeId: locale.isEmpty ? null : locale,
      ),
      );
    } catch (_) {
      _finish();
      rethrow;
    }
  }

  void _finish() {
    if (_finished) return;
    _finished = true;
    _listeningEnded(this);
    if (_active == this) _active = null;
    _onDone?.call();
  }

  @override
  Future<void> stop() async {
    await _stt.stop();
    _finish();
  }

  @override
  void dispose() {
    _listeningEnded(this);
    if (_active == this) {
      _stt.cancel();
      _active = null;
    }
    _finished = true;
  }
}

/// Downloaded Whisper models and download progress.
class WhisperModels extends ChangeNotifier {
  static final instance = WhisperModels();

  /// Model id -> approximate download size in MB.
  static const sizesMb = {'tiny': 75, 'base': 142};

  /// Overridable for tests.
  static Future<String> Function() modelDir = WhisperController.getModelDir;

  final _ready = <String>{};
  final _progress = <String, double>{};
  final _abort = <String, Completer<void>>{};
  void cancel(String id) {
    final signal = _abort[id];
    if (signal != null && !signal.isCompleted) signal.complete();
  }
  String? error;

  bool isReady(String id) => _ready.contains(id);

  /// 0..1 while [id] downloads, null otherwise.
  double? progressOf(String id) => _progress[id];

  Future<String> pathFor(String id) async => '${await modelDir()}/ggml-$id.bin';

  Future<void> refresh() async {
    var changed = false;
    for (final id in sizesMb.keys) {
      bool exists;
      try {
        exists = await File(await pathFor(id)).exists();
      } catch (_) {
        exists = false;
      }
      if (exists != _ready.contains(id)) {
        exists ? _ready.add(id) : _ready.remove(id);
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  Future<void> download(String id, {http.Client? client}) async {
    if (_progress.containsKey(id) || isReady(id)) return;
    final model = WhisperModel.values.firstWhere((m) => m.modelName == id);
    File? part;
    final c = client ?? http.Client();
    error = null;
    _progress[id] = 0;
    final signal = _abort[id] = Completer<void>();
    notifyListeners();
    IOSink? sink;
    try {
      final path = await pathFor(id);
      part = File('$path.part');
      final res = await c.send(http.AbortableRequest('GET', model.modelUri, abortTrigger: signal.future));
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
      final total = res.contentLength ?? sizesMb[id]! * 1024 * 1024;
      await part.parent.create(recursive: true);
      sink = part.openWrite();
      var got = 0;
      var shown = 0.0;
      await for (final chunk in res.stream) {
        sink.add(chunk);
        got += chunk.length;
        final p = (got / total).clamp(0.0, 1.0);
        if (p - shown >= 0.01) {
          _progress[id] = shown = p;
          notifyListeners();
        }
      }
      await sink.close();
      sink = null;
      if (signal.isCompleted) throw const FileSystemException('Cancelled');
      if (res.contentLength != null && got != res.contentLength) throw const FileSystemException('Incomplete download');
      await part.rename(path);
      _ready.add(id);
    } catch (e) {
      error = signal.isCompleted ? 'Download cancelled. You can retry any time.' : 'Download failed: $e';
      await sink?.close();
      if (part != null && await part.exists()) await part.delete();
    } finally {
      _progress.remove(id);
      _abort.remove(id);
      if (client == null) c.close();
      notifyListeners();
    }
  }

  Future<void> delete(String id) async {
    final f = File(await pathFor(id));
    if (await f.exists()) await f.delete();
    _ready.remove(id);
    notifyListeners();
  }
}
