/// Speech recognition and text-to-speech behind one small interface, so the
/// `ReadAloudDrill` catalog component (and other features, e.g. the wake
/// challenge) can be driven by a fake in tests: set [speechEngineFactory].
library;

import 'dart:async';

import '../services/tts.dart' as tts show stopSpeaking;
import '../services/voice_input.dart';

Future<void> stopSpeakingAloud() => tts.stopSpeaking();

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
/// phone's recognizer, see [dictationFactory]) and speaks with the chosen
/// voice engine (see [speakText]).
class PluginSpeechEngine implements SpeechEngine {
  Dictation? _dictation;
  int _listenAttempt = 0;
  bool _starting = false;
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
    final attempt = ++_listenAttempt;
    await stopSpeakingAloud();
    if (attempt != _listenAttempt) return;
    _dictation?.dispose();
    _dictation = null;
    final d = await dictationFactory();
    if (attempt != _listenAttempt) {
      d.dispose();
      return;
    }
    _dictation = d;
    _starting = true;
    try {
      await d.start(
        locale: localeId ?? '',
        onText: onWords,
        onDone: () => _onStopped?.call(),
        onError: (m) => _onError?.call(m),
      );
    } finally {
      if (_dictation == d) _starting = false;
    }
  }

  @override
  Future<void> stop() async {
    _listenAttempt++;
    if (_starting) {
      _dictation?.dispose();
      _dictation = null;
      _starting = false;
    } else {
      await _dictation?.stop();
    }
  }

  @override
  Future<void> speak(String text, {void Function()? onDone}) async {
    unawaited(speakText(text, rate: 0.42).whenComplete(() => onDone?.call()));
  }

  @override
  Future<void> stopSpeaking() => stopSpeakingAloud();

  @override
  void dispose() {
    _listenAttempt++;
    _dictation?.dispose();
    _dictation = null;
    _starting = false;
    stopSpeakingAloud();
  }
}
