/// Speech recognition and text-to-speech behind one small interface, so the
/// `ReadAloudDrill` catalog component (and other features, e.g. the wake
/// challenge) can be driven by a fake in tests: set [speechEngineFactory].
library;

import 'package:flutter_tts/flutter_tts.dart';

import '../services/voice_input.dart';

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

/// Listens through the user's chosen dictation engine (Whisper or the
/// phone's recognizer, see [dictationFactory]) and speaks with the phone's
/// text-to-speech.
class PluginSpeechEngine implements SpeechEngine {
  final _tts = FlutterTts();
  Dictation? _dictation;
  void Function()? _onStopped;
  void Function(String message)? _onError;

  @override
  Future<bool> init({required void Function() onStopped, required void Function(String message) onError}) async {
    _onStopped = onStopped;
    _onError = onError;
    return true;
  }

  @override
  Future<void> listen({required void Function(String words) onWords, String? localeId}) async {
    await _tts.stop();
    _dictation?.dispose();
    final d = _dictation = await dictationFactory();
    await d.start(
      locale: localeId ?? '',
      onText: onWords,
      onDone: () => _onStopped?.call(),
      onError: (m) => _onError?.call(m),
    );
  }

  @override
  Future<void> stop() async => _dictation?.stop();

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
    _dictation?.dispose();
    _tts.stop();
  }
}
