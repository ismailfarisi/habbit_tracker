import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_tracker/agent/speech_engine.dart';
import 'package:habit_tracker/app_state.dart';
import 'package:habit_tracker/services/notification_service.dart';
import 'package:habit_tracker/services/storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Silences plugins that have no implementation in tests.
void mockPlugins() {
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final ch in ['flutter_tts', 'plugins.it_nomads.com/flutter_secure_storage', 'plugin.csdcorp.com/speech_to_text']) {
    messenger.setMockMethodCallHandler(MethodChannel(ch), (_) async => null);
  }
}

/// An [AppState] over in-memory preferences seeded with [prefs].
Future<AppState> loadState([Map<String, Object> prefs = const {}]) async {
  SharedPreferences.setMockInitialValues(prefs);
  return AppState.load(await Storage.open(), NotificationService.instance);
}

/// A speech engine that "hears" [words] as soon as listening starts.
class FakeSpeechEngine implements SpeechEngine {
  final String words;
  bool listening = false;
  String? spoken;
  FakeSpeechEngine(this.words);

  @override
  Future<bool> init({required void Function() onStopped, required void Function(String message) onError}) async => true;

  @override
  Future<void> listen({required void Function(String words) onWords, String? localeId}) async {
    listening = true;
    onWords(words);
  }

  @override
  Future<void> stop() async => listening = false;

  @override
  Future<void> speak(String text, {void Function()? onDone}) async {
    spoken = text;
    onDone?.call();
  }

  @override
  Future<void> stopSpeaking() async {}

  @override
  void dispose() {}
}

http.StreamedResponse sse(List<Map<String, dynamic>> deltas) => http.StreamedResponse(
      Stream.fromIterable([
        for (final d in deltas)
          utf8.encode('data: ${jsonEncode({
                'choices': [
                  {'delta': d},
                ],
              })}\n\n'),
        utf8.encode('data: [DONE]\n\n'),
      ]),
      200,
    );

Map<String, dynamic> toolCallDelta(String name, Map<String, dynamic> args, {String id = 'call_1'}) => {
      'tool_calls': [
        {
          'index': 0,
          'id': id,
          'type': 'function',
          'function': {'name': name, 'arguments': jsonEncode(args)},
        },
      ],
    };

/// A fake model: answers request N with `turns[N]` (a list of SSE deltas)
/// and records every request body in [requests].
MockClient fakeModel(List<List<Map<String, dynamic>>> turns, [List<Map<String, dynamic>>? requests]) {
  var i = 0;
  return MockClient.streaming((req, body) async {
    requests?.add(jsonDecode(await body.bytesToString()) as Map<String, dynamic>);
    return sse(turns[i < turns.length ? i++ : turns.length - 1]);
  });
}
