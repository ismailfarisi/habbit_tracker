/// The app-owned A2UI catalog ([habitCatalogId], protocol v1.0) that habit
/// surfaces are built from, registered next to `basicCatalog()`.
///
/// Components (implemented in habit_components.dart): `HabitCheck`, `Counter`,
/// `PracticeTimer`, `ReadAloudDrill`, `PromptCard`, `RatingInput`,
/// `MetricTrend`, `ChoiceChips`. They bind to the surface data model, which
/// `HabitSurface` seeds from and saves to the day's `HabitEntry`:
/// `/done`, `/value`, `/minutes`, `/metrics/<key>`, `/notes`, `/sessions`,
/// and read-only `/habit/{title,target,unit}` and `/day`.
///
/// Event actions handled by `HabitSurface` ([habitActionNames]):
/// * `logEntry` — context `{done?, value?, addValue?, minutes?, addMinutes?, metrics?, notes?}`
/// * `finishSession` — context `{durationSec?, addMinutes?, metrics?, transcript?}`;
///   appends a `HabitSession`
/// * `askCoach` — context is sent to the coach for feedback
///
/// Use [habitCatalogs] wherever a `MessageProcessor` or `A2uiGenerator` is
/// built, and [normalizeHabitSurface] before storing any surface JSON.
library;

import 'dart:convert';

import 'package:a2ui_agent/a2ui_agent.dart';
import 'package:a2ui_core/a2ui_core.dart';
import 'package:a2ui_flutter/a2ui_flutter.dart';
import 'package:a2ui_flutter/basic_catalog.dart';
import 'package:json_schema_builder/json_schema_builder.dart';

import 'habit_components.dart';
import 'habit_templates.dart';

export 'habit_templates.dart' show habitCatalogId, basicCatalogId, surfaceMessage;

const logEntryAction = 'logEntry', finishSessionAction = 'finishSession', askCoachAction = 'askCoach';
const habitActionNames = [logEntryAction, finishSessionAction, askCoachAction];

const _instructions = '''
These components build the logging / practice UI of ONE habit for ONE day.
The surface data model is that day's entry: /done (bool), /value (number),
/minutes (number), /metrics/<key> (number), /notes (string). Read-only:
/habit/title, /habit/target, /habit/unit. Bind inputs to those paths, e.g.
"value": {"@path": "/value"} and "target": {"@path": "/habit/target"}.
Every component of this catalog needs "catalogId": "$habitCatalogId".
Lay them out with the basic catalog's Column, Row, Card, Text and Divider.
A Button may send these event actions: "logEntry" (context: done, value,
addValue, minutes, addMinutes, metrics, notes), "finishSession" (context:
durationSec, addMinutes, metrics, transcript) and "askCoach" (context: any
data the coach should review). Everything is saved automatically; never add
a submit button just to save.
''';

final Schema _action = Schema.fromMap({r'$ref': r'common_types.json#/$defs/Action'});

Schema _strings(String description) => Schema.list(items: Schema.string(), description: description);

ComponentImplementation _c(
  String name,
  String description,
  Map<String, Schema> properties,
  ComponentWidgetBuilder builder, {
  List<String> required = const [],
}) =>
    ComponentImplementation(
      name: name,
      schema: Schema.object(description: description, properties: properties, required: required),
      builder: builder,
    );

final CatalogImplementation _habitCatalog = CatalogImplementation(
  id: habitCatalogId,
  protocolVersion: A2uiProtocolVersion.v1_0,
  title: 'Daily Discipline habits',
  description: 'Logging and practice components for a habit tracker.',
  instructions: _instructions,
  components: [
    _c(
      'HabitCheck',
      'A big tick box that marks the habit done for the day.',
      {
        'label': CommonSchemasV1.dynamicString,
        'done': CommonSchemasV1.dynamicBoolean,
        'onChanged': _action,
      },
      buildHabitCheck,
    ),
    _c(
      'Counter',
      'A number with - and + buttons and a progress bar towards target (glasses, pages, reps).',
      {
        'label': CommonSchemasV1.dynamicString,
        'value': CommonSchemasV1.dynamicNumber,
        'target': CommonSchemasV1.dynamicNumber,
        'step': Schema.number(description: 'Amount added per tap. Default 1.'),
        'unit': Schema.string(),
        'onChanged': _action,
      },
      buildCounter,
    ),
    _c(
      'PracticeTimer',
      'A start / pause / finish stopwatch. Finish adds the elapsed minutes to "minutes" and records a session.',
      {
        'label': CommonSchemasV1.dynamicString,
        'minutes': CommonSchemasV1.dynamicNumber,
        'targetMinutes': CommonSchemasV1.dynamicNumber,
      },
      buildPracticeTimer,
    ),
    _c(
      'ReadAloudDrill',
      'Shows a text (tongue twister, passage, word list) to read aloud, records the user with speech '
          'recognition and writes /metrics/wpm (words per minute), /metrics/fillers (filler-word count) and '
          '/metrics/accuracy (percent of the text / target words recognised), then records a session.',
      {
        'title': CommonSchemasV1.dynamicString,
        'text': CommonSchemasV1.dynamicString,
        'targetWords': _strings('Words that must be heard clearly; the hit rate is shown.'),
        'listen': Schema.boolean(description: 'Show a "Hear it" text-to-speech button. Default true.'),
      },
      buildReadAloudDrill,
      required: ['text'],
    ),
    _c(
      'PromptCard',
      'An exercise card: a title, optional body text and numbered steps.',
      {
        'title': CommonSchemasV1.dynamicString,
        'body': CommonSchemasV1.dynamicString,
        'steps': _strings('Short instructions, shown as a numbered list.'),
      },
      buildPromptCard,
    ),
    _c(
      'RatingInput',
      'A 1..max rating (stars). Bind value to a metric, e.g. {"@path": "/metrics/mood"}.',
      {
        'label': CommonSchemasV1.dynamicString,
        'value': CommonSchemasV1.dynamicNumber,
        'max': Schema.integer(description: 'Highest rating, 3 to 10. Default 5.'),
        'onChanged': _action,
      },
      buildRatingInput,
    ),
    _c(
      'MetricTrend',
      'A mini chart of one metric of this habit over the last days. "metric" is a /metrics key, or '
          '"minutes" or "value".',
      {
        'metric': Schema.string(),
        'label': CommonSchemasV1.dynamicString,
        'unit': Schema.string(),
        'days': Schema.integer(description: 'How many days back. Default 30.'),
      },
      buildMetricTrend,
      required: ['metric'],
    ),
    _c(
      'ChoiceChips',
      'Pick one of a few options. Bind value to a string path, e.g. {"@path": "/choice"}.',
      {
        'label': CommonSchemasV1.dynamicString,
        'options': _strings('The choices.'),
        'value': CommonSchemasV1.dynamicString,
        'onChanged': _action,
      },
      buildChoiceChips,
      required: ['options'],
    ),
  ],
);

CatalogImplementation habitCatalog() => _habitCatalog;

final CatalogImplementation _basic = basicCatalog();

/// The catalogs every habit surface is rendered and validated with.
List<CatalogImplementation> habitCatalogs() => [_basic, _habitCatalog];

/// Where an input writes when the surface does not bind it.
const _defaultBindings = {
  'HabitCheck': ('done', '/done'),
  'Counter': ('value', '/value'),
  'PracticeTimer': ('minutes', '/minutes'),
  'RatingInput': ('value', '/metrics/rating'),
  'ChoiceChips': ('value', '/choice'),
};

class HabitSurfaceError implements Exception {
  final String message;
  HabitSurfaceError(this.message);
  @override
  String toString() => message;
}

List<Object?>? _components(Object? raw) {
  if (raw is List) {
    if (raw.isNotEmpty && raw.every((e) => e is Map && e.containsKey('component'))) return raw;
    return [for (final m in raw) ...?_components(m)];
  }
  if (raw is! Map) return null;
  for (final key in const ['createSurface', 'updateComponents', 'ui', 'surface']) {
    if (raw[key] is Map || raw[key] is List) return _components(raw[key]);
  }
  if (raw['messages'] is List) return _components(raw['messages']);
  if (raw['components'] is List) return raw['components'] as List;
  return null;
}

/// Turns surface JSON from a template, a backup or the model into the stored
/// shape — one v1.0 `createSurface` message with inline components — and
/// checks it against [habitCatalogs]. Accepts that message, a list of
/// messages, `{"messages": [...]}`, `{"components": [...]}` or a bare
/// component list. Habit components get their `catalogId` and a default data
/// binding when missing. Throws [HabitSurfaceError] if a renderer would
/// reject the result.
Map<String, dynamic> normalizeHabitSurface(Object? raw) {
  final List<Object?>? found;
  try {
    found = _components(jsonDecode(jsonEncode(raw)));
  } catch (e) {
    throw HabitSurfaceError('The UI is not valid JSON: $e');
  }
  if (found == null || found.isEmpty) {
    throw HabitSurfaceError('The UI has no components. Pass {"components": [...]} with one component whose id is "root".');
  }
  final components = <Map<String, dynamic>>[];
  for (final c in found) {
    if (c is! Map) throw HabitSurfaceError('Each component must be a JSON object.');
    final m = c.cast<String, dynamic>();
    final name = m['component'];
    if (_habitCatalog.components.containsKey(name)) {
      m['catalogId'] ??= habitCatalogId;
      final binding = _defaultBindings[name];
      if (binding != null && !(m[binding.$1] is Map && (m[binding.$1] as Map).containsKey('@path'))) {
        m[binding.$1] = {'@path': binding.$2};
      }
    }
    components.add(m);
  }
  final message = surfaceMessage(components);
  try {
    final payload = AgentToRendererMessagePayload.fromJson([message], protocolVersion: A2uiProtocolVersion.v1_0);
    validatePayload(habitCatalogs(), payload.messages);
  } on A2uiError catch (e) {
    throw HabitSurfaceError('Invalid habit UI: ${e.message}');
  } catch (e) {
    throw HabitSurfaceError('Invalid habit UI: $e');
  }
  return message;
}

/// Whether [surface] passes [normalizeHabitSurface].
bool isValidHabitSurface(Object? surface) {
  try {
    normalizeHabitSurface(surface);
    return true;
  } on HabitSurfaceError {
    return false;
  }
}
