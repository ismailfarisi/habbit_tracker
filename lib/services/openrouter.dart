import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class ToolCall {
  final String id;
  final String name;
  final String arguments; // JSON text
  const ToolCall(this.id, this.name, this.arguments);

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': 'function',
        'function': {'name': name, 'arguments': arguments},
      };
}

class ChatMessage {
  final String role; // system | user | assistant | tool
  final String content;
  final List<ToolCall> toolCalls;
  final String? toolCallId;

  const ChatMessage(this.role, this.content, {this.toolCalls = const [], this.toolCallId});

  Map<String, dynamic> toJson() => {
        'role': role,
        // Assistant turns that only call tools carry no text.
        'content': (role == 'assistant' && content.isEmpty && toolCalls.isNotEmpty) ? null : content,
        if (toolCalls.isNotEmpty) 'tool_calls': toolCalls.map((c) => c.toJson()).toList(),
        if (toolCallId != null) 'tool_call_id': toolCallId,
      };
}

class OpenRouterException implements Exception {
  final String message;
  OpenRouterException(this.message);
  @override
  String toString() => message;
}

/// Executes one tool call and returns the result (usually JSON) for the model.
typedef ToolExecutor = Future<String> Function(ToolCall call);

/// Streaming client for the OpenRouter chat completions API, with support
/// for function/tool calling.
class OpenRouterClient {
  static final _endpoint = Uri.parse('https://openrouter.ai/api/v1/chat/completions');

  final String apiKey;
  final String model;
  final http.Client _http;

  OpenRouterClient({required this.apiKey, required this.model, http.Client? client})
      : _http = client ?? http.Client();

  /// Streams one assistant turn. Text deltas go to [onText]; the returned
  /// message holds the full text and any tool calls the model made.
  Future<ChatMessage> turn(
    List<ChatMessage> messages, {
    List<Map<String, dynamic>>? tools,
    void Function(String delta)? onText,
    double temperature = 0.7,
  }) async {
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
        if (tools != null && tools.isNotEmpty) ...{'tools': tools, 'tool_choice': 'auto'},
      });

    final res = await _http.send(req);
    if (res.statusCode != 200) {
      final body = await res.stream.bytesToString();
      throw OpenRouterException(errorMessage(res.statusCode, body, usedTools: tools != null && tools.isNotEmpty));
    }

    final text = StringBuffer();
    final calls = <int, _PartialCall>{};
    var buffer = '';
    void handle(String line) {
      final delta = parseSseDelta(line);
      if (delta == null) return;
      final content = delta['content'];
      if (content is String && content.isNotEmpty) {
        text.write(content);
        onText?.call(content);
      }
      final tc = delta['tool_calls'];
      if (tc is List) {
        for (final raw in tc) {
          final c = raw as Map;
          final index = (c['index'] as num?)?.toInt() ?? calls.length;
          final p = calls.putIfAbsent(index, _PartialCall.new);
          if (c['id'] is String) p.id = c['id'] as String;
          final f = c['function'] as Map?;
          if (f?['name'] is String) p.name += f!['name'] as String;
          if (f?['arguments'] is String) p.arguments.write(f!['arguments'] as String);
        }
      }
    }

    await for (final chunk in res.stream.transform(utf8.decoder)) {
      buffer += chunk;
      int nl;
      while ((nl = buffer.indexOf('\n')) >= 0) {
        handle(buffer.substring(0, nl).trim());
        buffer = buffer.substring(nl + 1);
      }
    }
    if (buffer.trim().isNotEmpty) handle(buffer.trim());

    final keys = calls.keys.toList()..sort();
    return ChatMessage(
      'assistant',
      text.toString(),
      toolCalls: [
        for (final k in keys)
          if (calls[k]!.name.isNotEmpty)
            ToolCall(
              calls[k]!.id ?? 'call_$k',
              calls[k]!.name,
              calls[k]!.arguments.isEmpty ? '{}' : calls[k]!.arguments.toString(),
            ),
      ],
    );
  }

  /// Runs the model with [tools] until it stops calling them. Every
  /// assistant and tool message is appended to [history], so the caller
  /// keeps the full conversation. Returns the final reply text.
  Future<String> runAgent(
    List<ChatMessage> history, {
    required String system,
    required List<Map<String, dynamic>> tools,
    required ToolExecutor execute,
    void Function(String delta)? onText,
    int maxSteps = 8,
  }) async {
    for (var step = 0; step < maxSteps; step++) {
      final msg = await turn([ChatMessage('system', system), ...history], tools: tools, onText: onText);
      history.add(msg);
      if (msg.toolCalls.isEmpty) return msg.content;
      for (final call in msg.toolCalls) {
        String result;
        try {
          result = await execute(call);
        } catch (e) {
          result = jsonEncode({'error': e.toString()});
        }
        history.add(ChatMessage('tool', result, toolCallId: call.id));
      }
    }
    return '';
  }

  /// Streams plain text (no tools).
  Stream<String> stream(List<ChatMessage> messages, {double temperature = 0.7}) {
    final out = StreamController<String>();
    turn(messages, temperature: temperature, onText: out.add).then(
      (_) => out.close(),
      onError: (Object e, StackTrace st) {
        out.addError(e, st);
        out.close();
      },
    );
    return out.stream;
  }

  /// Convenience: the full reply as one string.
  Future<String> complete(List<ChatMessage> messages, {double temperature = 0.7}) async =>
      (await turn(messages, temperature: temperature)).content;

  void close() => _http.close();
}

class _PartialCall {
  String? id;
  String name = '';
  final arguments = StringBuffer();
}

/// Extracts the `delta` object from one server-sent-events line, or null.
/// Throws [OpenRouterException] if the stream reports an error.
Map<String, dynamic>? parseSseDelta(String line) {
  if (!line.startsWith('data:')) return null; // comments like ": OPENROUTER PROCESSING"
  final data = line.substring(5).trim();
  if (data.isEmpty || data == '[DONE]') return null;
  Map<String, dynamic> j;
  try {
    j = jsonDecode(data) as Map<String, dynamic>;
  } on FormatException {
    return null;
  }
  if (j['error'] != null) {
    throw OpenRouterException((j['error'] as Map)['message']?.toString() ?? 'AI error');
  }
  final choices = j['choices'] as List?;
  if (choices == null || choices.isEmpty) return null;
  return ((choices.first as Map)['delta'] as Map?)?.cast<String, dynamic>();
}

String errorMessage(int status, String body, {bool usedTools = false}) {
  String? detail;
  try {
    detail = ((jsonDecode(body) as Map)['error'] as Map?)?['message']?.toString();
  } catch (_) {}
  if (usedTools && status == 404 && (detail ?? body).toLowerCase().contains('tool')) {
    return "This model can't create tasks (no tool support). Pick another model in Settings, e.g. openai/gpt-4o-mini.";
  }
  final hint = switch (status) {
    401 => 'Invalid API key. Check it in Settings.',
    402 => 'Your OpenRouter account is out of credits.',
    404 => 'Model not found. Check the model name in Settings.',
    429 => 'Rate limited. Wait a moment and try again.',
    _ => 'Request failed ($status).',
  };
  return detail == null ? hint : '$hint\n$detail';
}
