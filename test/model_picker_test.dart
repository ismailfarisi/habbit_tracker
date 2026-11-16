import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_tracker/screens/settings_screen.dart';
import 'package:habit_tracker/services/openrouter_models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

String _body() => jsonEncode({
  'data': [
    {
      'id': 'openai/gpt-4o-mini',
      'name': 'OpenAI: GPT-4o-mini',
      'context_length': 128000,
      'pricing': {'prompt': '0.00000015', 'completion': '0.0000006'},
      'supported_parameters': ['tools', 'temperature'],
      'architecture': {
        'output_modalities': ['text'],
      },
    },
    {
      'id': 'google/gemma-4-31b-it:free',
      'name': 'Google: Gemma 4 31B (free)',
      'context_length': 131072,
      'pricing': {'prompt': '0', 'completion': '0'},
      'supported_parameters': ['tools'],
      'architecture': {
        'output_modalities': ['text'],
      },
    },
    {
      'id': 'openrouter/free',
      'name': 'Free Models Router',
      'pricing': {'prompt': '0', 'completion': '0'},
      'supported_parameters': ['tools'],
    },
    {
      'id': 'liquid/lfm-tiny:free',
      'name': 'Liquid tiny',
      'pricing': {'prompt': '0', 'completion': '0'},
      'supported_parameters': ['temperature'],
      'architecture': {
        'output_modalities': ['text'],
      },
    },
    {
      'id': 'google/lyria-3-pro-preview',
      'name': 'Lyria (music)',
      'pricing': {'prompt': '0', 'completion': '0'},
      'architecture': {
        'output_modalities': ['audio'],
      },
    },
  ],
});

void main() {
  group('parseModels', () {
    test('keeps text models, flags free and tool support, sorts free first', () {
      final models = parseModels(_body());
      expect(models.map((m) => m.id), [
        'google/gemma-4-31b-it:free',
        'liquid/lfm-tiny:free',
        'openrouter/free',
        'openai/gpt-4o-mini',
      ]);
      expect(models.where((m) => m.free).length, 3);
      expect(models.firstWhere((m) => m.id == 'liquid/lfm-tiny:free').tools, isFalse);
      expect(models.last.contextLength, 128000);
    });

    test('search matches ID, name and the word "free"', () {
      final models = parseModels(_body());
      expect(models.where((m) => m.matches('gemma')).map((m) => m.id), ['google/gemma-4-31b-it:free']);
      expect(models.where((m) => m.matches('openai mini')).map((m) => m.id), ['openai/gpt-4o-mini']);
      expect(models.where((m) => m.matches('free')).length, 3);
    });

    test('fetch falls back to the built-in list when offline', () async {
      final down = MockClient((_) async => http.Response('nope', 503));
      expect(await fetchOpenRouterModels(client: down), fallbackModels);
      final up = MockClient((_) async => http.Response(_body(), 200));
      expect((await fetchOpenRouterModels(client: up)).length, 4);
    });
  });

  testWidgets('model field autocompletes and filters to free models', (tester) async {
    final controller = TextEditingController(text: 'openai/gpt-4o-mini');
    String? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelPicker(
            controller: controller,
            onSelected: (v) => saved = v,
            loadModels: () async => parseModels(_body()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('4 models, 3 free'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('model-field')), 'gemma');
    await tester.pumpAndSettle();
    expect(find.text('google/gemma-4-31b-it:free'), findsOneWidget);
    expect(find.text('Free'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('model-field')), '');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('free-only')));
    await tester.pumpAndSettle();
    expect(find.text('openai/gpt-4o-mini'), findsNothing);
    expect(find.text('openrouter/free'), findsOneWidget);
    expect(find.textContaining("no tools"), findsOneWidget);

    await tester.tap(find.text('openrouter/free'));
    await tester.pumpAndSettle();
    expect(saved, 'openrouter/free');
    expect(controller.text, 'openrouter/free');
  });
}
