import 'dart:convert';

import 'package:http/http.dart' as http;

class ChatMessage {
  final String role; // system | user | assistant
  final String content;
  const ChatMessage(this.role, this.content);
  Map<String, String> toJson() => {'role': role, 'content': content};
}

class OpenRouterException implements Exception {
  final String message;
  OpenRouterException(this.message);
  @override
  String toString() => message;
}

/// Minimal streaming client for the OpenRouter chat completions API.
class OpenRouterClient {
  static final _endpoint = Uri.parse('https://openrouter.ai/api/v1/chat/completions');

  final String apiKey;
  final String model;
  final http.Client _http;

  OpenRouterClient({required this.apiKey, required this.model, http.Client? client})
      : _http = client ?? http.Client();

  /// Streams the assistant reply token by token.
  Stream<String> stream(List<ChatMessage> messages, {double temperature = 0.7}) async* {
    if (apiKey.trim().isEmpty) {
      throw OpenRouterException('Add your OpenRouter API key in Settings first.');
    }
    final req = http.Request('POST', _endpoint)
      ..headers.addAll({
        'Authorization': 'Bearer ${apiKey.trim()}',
        'Content-Type': 'application/json',
        'HTTP-Referer': 'https://github.com/ismailfarisi/habbit_tracker',
        'X-Title': 'Daily Discipline',
      })
      ..body = jsonEncode({
        'model': model,
        'stream': true,
        'temperature': temperature,
        'messages': messages.map((m) => m.toJson()).toList(),
      });

    final res = await _http.send(req);
    if (res.statusCode != 200) {
      final body = await res.stream.bytesToString();
      throw OpenRouterException(_errorMessage(res.statusCode, body));
    }

    var buffer = '';
    await for (final chunk in res.stream.transform(utf8.decoder)) {
      buffer += chunk;
      int nl;
      while ((nl = buffer.indexOf('\n')) >= 0) {
        final line = buffer.substring(0, nl).trim();
        buffer = buffer.substring(nl + 1);
        final token = parseSseLine(line);
        if (token != null && token.isNotEmpty) yield token;
      }
    }
  }

  /// Convenience: the full reply as one string.
  Future<String> complete(List<ChatMessage> messages, {double temperature = 0.7}) =>
      stream(messages, temperature: temperature).join();

  void close() => _http.close();
}

/// Extracts the content delta from one server-sent-events line, or null.
/// Throws [OpenRouterException] if the stream reports an error.
String? parseSseLine(String line) {
  if (!line.startsWith('data:')) return null; // comments like ": OPENROUTER PROCESSING"
  final data = line.substring(5).trim();
  if (data.isEmpty || data == '[DONE]') return null;
  try {
    final j = jsonDecode(data) as Map<String, dynamic>;
    if (j['error'] != null) {
      throw OpenRouterException((j['error'] as Map)['message']?.toString() ?? 'AI error');
    }
    final choices = j['choices'] as List?;
    if (choices == null || choices.isEmpty) return null;
    return ((choices.first as Map)['delta'] as Map?)?['content'] as String?;
  } on FormatException {
    return null;
  }
}

String _errorMessage(int status, String body) {
  String? detail;
  try {
    detail = ((jsonDecode(body) as Map)['error'] as Map?)?['message']?.toString();
  } catch (_) {}
  final hint = switch (status) {
    401 => 'Invalid API key. Check it in Settings.',
    402 => 'Your OpenRouter account is out of credits.',
    404 => 'Model not found. Check the model name in Settings.',
    429 => 'Rate limited. Wait a moment and try again.',
    _ => 'Request failed ($status).',
  };
  return detail == null ? hint : '$hint\n$detail';
}
