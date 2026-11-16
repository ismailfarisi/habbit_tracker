/// Speech recognition and text-to-speech behind one small interface, so the
/// `ReadAloudDrill` catalog component (and other features, e.g. the wake
/// challenge) can be driven by a fake in tests: set [speechEngineFactory].
library;

import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart';

abstract class SpeechEngine {
  /// Prepares the recognizer. [onStopped] fires when listening ends on its
  /// own (silence, error); [onError] carries a readable message.
  Future<bool> init({required void Function() onStopped, required void Function(String message) onError});

  /// Starts listening; [onWords] receives everything recognised so far.
  Future<void> listen({required void Function(String words) onWords, String? localeId});
  Future<void> stop();
  Future<void> speak(String text, {void Function()? onDone});
  Future<void> stopSpeaking();
  void dispose();
}

SpeechEngine Function() speechEngineFactory = PluginSpeechEngine.new;

class PluginSpeechEngine implements SpeechEngine {
  final _speech = SpeechToText();
  final _tts = FlutterTts();

  @override
  Future<bool> init({required void Function() onStopped, required void Function(String message) onError}) =>
      _speech.initialize(
        onStatus: (s) {
          if (s == 'done' || s == 'notListening') onStopped();
        },
        onError: (e) => onError(e.errorMsg),
      );

  @override
  Future<void> listen({required void Function(String words) onWords, String? localeId}) async {
    await _tts.stop();
    await _speech.listen(
      onResult: (r) => onWords(r.recognizedWords),
      listenOptions: SpeechListenOptions(
        listenFor: const Duration(minutes: 3),
        pauseFor: const Duration(seconds: 6),
        partialResults: true,
        listenMode: ListenMode.dictation,
        localeId: localeId == null || localeId.isEmpty ? null : localeId,
      ),
    );
  }

  @override
  Future<void> stop() => _speech.stop();

  @override
  Future<void> speak(String text, {void Function()? onDone}) async {
    _tts.setCompletionHandler(() => onDone?.call());
    await _tts.setSpeechRate(0.42);
    await _tts.speak(text.replaceAll(RegExp(r'[*#_`]'), ''));
  }

  @override
  Future<void> stopSpeaking() async {
    await _tts.stop();
  }

  @override
  void dispose() {
    _speech.cancel();
    _tts.stop();
  }
}
