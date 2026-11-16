import 'dart:convert';

import 'package:http/http.dart' as http;

/// One entry from OpenRouter's public model list.
class OpenRouterModel {
  final String id;
  final String name;
  final int contextLength;
  final bool free;

  /// Whether the model accepts `tools`; the coach needs this to build habits.
  final bool tools;

  const OpenRouterModel({
    required this.id,
    this.name = '',
    this.contextLength = 0,
    this.free = false,
    this.tools = true,
  });

  factory OpenRouterModel.fromJson(Map<String, dynamic> j) {
    final id = j['id'] as String;
    final pricing = (j['pricing'] as Map?) ?? const {};
    bool zero(Object? v) => v != null && double.tryParse(v.toString()) == 0;
    final params = (j['supported_parameters'] as List?)?.cast<Object?>() ?? const [];
    return OpenRouterModel(
      id: id,
      name: (j['name'] as String?) ?? id,
      contextLength: (j['context_length'] as num?)?.toInt() ?? 0,
      free: id.endsWith(':free') || (zero(pricing['prompt']) && zero(pricing['completion'])),
      tools: params.contains('tools'),
    );
  }

  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    final hay = '$id $name ${free ? 'free' : ''}'.toLowerCase();
    return q.split(RegExp(r'\s+')).every(hay.contains);
  }
}

/// Parses `GET /api/v1/models`: text-output chat models only, free ones
/// first, then alphabetical by ID.
List<OpenRouterModel> parseModels(String body) {
  final data = (jsonDecode(body) as Map)['data'] as List;
  final models = <OpenRouterModel>[];
  for (final raw in data) {
    final j = (raw as Map).cast<String, dynamic>();
    final out = ((j['architecture'] as Map?)?['output_modalities'] as List?) ?? const ['text'];
    if (!out.contains('text')) continue;
    models.add(OpenRouterModel.fromJson(j));
  }
  models.sort((a, b) {
    if (a.free != b.free) return a.free ? -1 : 1;
    return a.id.compareTo(b.id);
  });
  return models;
}

/// Fallback when the list can't be fetched (offline, blocked).
const fallbackModels = [
  OpenRouterModel(id: 'openrouter/free', name: 'Free Models Router', free: true),
  OpenRouterModel(id: 'openai/gpt-4o-mini', name: 'OpenAI: GPT-4o-mini'),
  OpenRouterModel(id: 'google/gemini-2.5-flash', name: 'Google: Gemini 2.5 Flash'),
  OpenRouterModel(id: 'anthropic/claude-sonnet-4.5', name: 'Anthropic: Claude Sonnet 4.5'),
  OpenRouterModel(id: 'deepseek/deepseek-chat', name: 'DeepSeek: DeepSeek V3'),
];

final _endpoint = Uri.parse('https://openrouter.ai/api/v1/models');
Future<List<OpenRouterModel>>? _cache;

/// Fetches OpenRouter's model list (no key needed), once per app run.
/// Falls back to [fallbackModels] on any failure, and retries next call.
Future<List<OpenRouterModel>> fetchOpenRouterModels({http.Client? client}) {
  return _cache ??= () async {
    final c = client ?? http.Client();
    try {
      final res = await c.get(_endpoint).timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) throw http.ClientException('HTTP ${res.statusCode}');
      final models = parseModels(res.body);
      if (models.isEmpty) throw const FormatException('empty model list');
      return models;
    } catch (_) {
      _cache = null;
      return fallbackModels;
    } finally {
      if (client == null) c.close();
    }
  }();
}
