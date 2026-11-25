/// Offline seed habits, stored as A2UI v1.0 surface JSON so they render with
/// the same catalog as AI-built habits and need no API key.
///
/// `habitTemplates` lists them; `habitFromTemplate` turns one into a
/// [HabitDef] ready for `AppState.upsertHabit`. This file is plain Dart (no
/// Flutter imports) so storage and the background isolate can use it.
library;

import '../habits/habit.dart';

/// Id of the app-owned A2UI catalog (see habit_catalog.dart).
const habitCatalogId = 'https://dailydiscipline.app/catalog/habits.json';

/// Id of the A2UI v1.0 basic catalog (same value as `BasicCatalog.v1_0Id`).
const basicCatalogId = 'https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json';

class HabitTemplate {
  final String id;
  final String title;
  final String emoji;
  final String description;
  final HabitKind kind;
  final num target;
  final String unit;
  final List<MetricField> metricFields;
  final List<Map<String, dynamic>> components;

  /// Days of the week (1 = Monday) it is due; empty for every day.
  final List<int> weekdays;

  const HabitTemplate({
    this.weekdays = const [],
    required this.id,
    required this.title,
    required this.emoji,
    required this.description,
    required this.kind,
    this.target = 1,
    this.unit = '',
    this.metricFields = const [],
    required this.components,
  });
}

/// Wraps [components] (flat list, one with id `root`) into the stored
/// surface shape: one v1.0 `createSurface` message.
Map<String, dynamic> surfaceMessage(List<Map<String, dynamic>> components, {String surfaceId = 'habit'}) => {
      'version': '1.0',
      'createSurface': {
        'surfaceId': surfaceId,
        'catalogId': basicCatalogId,
        'components': components,
      },
    };

Map<String, dynamic> _h(String id, String component, [Map<String, dynamic> props = const {}]) =>
    {'id': id, 'component': component, 'catalogId': habitCatalogId, ...props};

Map<String, dynamic> _column(List<String> children) => {'id': 'root', 'component': 'Column', 'children': children};

const _path = '@path';

const articulationTemplate = HabitTemplate(
  id: 'articulation',
  title: 'Articulation practice',
  emoji: '🗣️',
  description: 'Read aloud, get your pace and filler words measured, and time your practice.',
  kind: HabitKind.practice,
  target: 15,
  unit: 'min',
  metricFields: [
    MetricField(key: 'wpm', label: 'Pace', unit: 'words/min'),
    MetricField(key: 'fillers', label: 'Filler words', better: 'down'),
    MetricField(key: 'accuracy', label: 'Clarity match', unit: '%'),
  ],
  components: _articulationComponents,
);

const _articulationComponents = <Map<String, dynamic>>[
  {
    'id': 'root',
    'component': 'Column',
    'children': ['warmup', 'drill', 'timer', 'pace', 'fillers'],
  },
  {
    'id': 'warmup',
    'component': 'PromptCard',
    'catalogId': habitCatalogId,
    'title': 'Warm-up (2 min)',
    'steps': [
      'Lip trills: blow air through relaxed lips ("brrr") for 15 seconds, sliding pitch up and down.',
      'Tongue stretch: tongue out and down, then up toward your nose, then side to side. 5 reps each.',
      'Jaw release: massage your jaw hinge, then open wide and say "yah-yah-yah" 10 times.',
      'Over-articulate: "pa-ta-ka" 10 times slowly, then 10 times quickly but crisply.',
      'Breath: inhale 4 s into your belly, then exhale on a steady "sss" for as long as you can.',
    ],
  },
  {
    'id': 'drill',
    'component': 'ReadAloudDrill',
    'catalogId': habitCatalogId,
    'title': 'Read aloud',
    'text': 'Red lorry, yellow lorry.\n'
        'She sells seashells by the seashore.\n'
        'Three thin thieves thought a thousand thoughts.\n'
        'A proper copper coffee pot.',
    'targetWords': ['lorry', 'seashells', 'thieves', 'thousand', 'copper'],
    'listen': true,
  },
  {
    'id': 'timer',
    'component': 'PracticeTimer',
    'catalogId': habitCatalogId,
    'label': 'Practice time',
    'minutes': {_path: '/minutes'},
    'targetMinutes': {_path: '/habit/target'},
  },
  {
    'id': 'pace',
    'component': 'MetricTrend',
    'catalogId': habitCatalogId,
    'metric': 'wpm',
    'label': 'Pace',
    'unit': 'words/min',
  },
  {
    'id': 'fillers',
    'component': 'MetricTrend',
    'catalogId': habitCatalogId,
    'metric': 'fillers',
    'label': 'Filler words',
  },
];

final quranTemplate = HabitTemplate(
  id: 'quran',
  title: 'Read Quran',
  emoji: '📖',
  description: 'Tick it off each day and count the pages you read.',
  kind: HabitKind.check,
  components: [
    _column(['check', 'pages']),
    _h('check', 'HabitCheck', {
      'label': 'I read Quran today',
      'done': {_path: '/done'},
    }),
    _h('pages', 'Counter', {
      'label': 'Pages',
      'unit': 'pages',
      'value': {_path: '/value'},
    }),
  ],
);

final waterTemplate = HabitTemplate(
  id: 'water',
  title: 'Drink water',
  emoji: '💧',
  description: 'Count glasses towards a daily goal.',
  kind: HabitKind.count,
  target: 8,
  unit: 'glasses',
  components: [
    _column(['glasses']),
    _h('glasses', 'Counter', {
      'label': 'Glasses of water',
      'unit': 'glasses',
      'value': {_path: '/value'},
      'target': {_path: '/habit/target'},
    }),
  ],
);

final exerciseTemplate = HabitTemplate(
  id: 'exercise',
  title: 'Exercise',
  emoji: '🏃',
  description: 'Time your workout and rate the effort.',
  kind: HabitKind.duration,
  target: 30,
  unit: 'min',
  metricFields: const [MetricField(key: 'effort', label: 'Effort', unit: '/5')],
  components: [
    _column(['timer', 'effort']),
    _h('timer', 'PracticeTimer', {
      'label': 'Workout',
      'minutes': {_path: '/minutes'},
      'targetMinutes': {_path: '/habit/target'},
    }),
    _h('effort', 'RatingInput', {
      'label': 'How hard was it?',
      'max': 5,
      'value': {_path: '/metrics/effort'},
    }),
  ],
);

final habitTemplates = <HabitTemplate>[articulationTemplate, quranTemplate, waterTemplate, exerciseTemplate];

final logSpendingTemplate = HabitTemplate(
  id: 'log-spending',
  title: "Log today's spending",
  emoji: '🧾',
  description: 'A minute each evening to write down what you spent.',
  kind: HabitKind.check,
  components: [
    _column(['check', 'log', 'budget']),
    _h('check', 'HabitCheck', {
      'label': "I wrote down today's spending",
      'done': {_path: '/done'},
    }),
    _h('log', 'MoneyLog', {
      'label': 'Add something you spent',
      'category': 'Other',
      'value': {_path: '/value'},
      'done': {_path: '/done'},
    }),
    _h('budget', 'BudgetBar', {}),
  ],
);

final noSpendTemplate = HabitTemplate(
  id: 'no-spend',
  title: 'No-spend day',
  emoji: '🌿',
  description: 'Only essentials today. Gratitude for what you already have.',
  kind: HabitKind.check,
  components: [
    _column(['check', 'tip', 'budget']),
    _h('check', 'HabitCheck', {
      'label': 'Nothing spent beyond essentials',
      'done': {_path: '/done'},
    }),
    _h('tip', 'PromptCard', {
      'title': 'Contentment',
      'body': 'Before buying, wait a day and ask: do I need it, or only want it?',
    }),
    _h('budget', 'BudgetBar', {}),
  ],
);

final weeklySadaqahTemplate = HabitTemplate(
  id: 'weekly-sadaqah',
  title: 'Weekly sadaqah',
  emoji: '🤲',
  description: 'Give something every Friday, however small.',
  kind: HabitKind.check,
  weekdays: const [5],
  components: [
    _column(['log', 'check']),
    _h('log', 'MoneyLog', {
      'label': 'How much did you give?',
      'category': 'Sadaqah',
      'value': {_path: '/value'},
      'done': {_path: '/done'},
    }),
    _h('check', 'HabitCheck', {
      'label': 'I gave sadaqah (time and kindness count too)',
      'done': {_path: '/done'},
    }),
  ],
);

final saveFirstTemplate = HabitTemplate(
  id: 'save-first',
  title: 'Save before you spend',
  emoji: '🏦',
  description: 'On payday, move your savings first, then spend what is left.',
  kind: HabitKind.check,
  components: [
    _column(['log', 'pot']),
    _h('log', 'MoneyLog', {
      'label': 'Amount set aside',
      'category': 'Savings',
      'value': {_path: '/value'},
      'done': {_path: '/done'},
    }),
    _h('pot', 'SavingsProgress', {}),
  ],
);

/// Money habits, offered in Add a habit and on the Money screen.
final moneyHabitTemplates = <HabitTemplate>[
  logSpendingTemplate,
  noSpendTemplate,
  weeklySadaqahTemplate,
  saveFirstTemplate,
];

HabitDef habitFromTemplate(
  HabitTemplate t, {
  String? id,
  int seq = 0,
  num? target,
  String? reminder,
  DateTime? createdAt,
}) =>
    HabitDef(
      id: id ?? newHabitId(),
      seq: seq,
      title: t.title,
      emoji: t.emoji,
      kind: t.kind,
      target: target ?? t.target,
      unit: t.unit,
      reminder: reminder,
      createdAt: createdAt,
      uiSurface: surfaceMessage(t.components),
      metricFields: List.of(t.metricFields),
      weekdays: List.of(t.weekdays),
      templateId: t.id,
    );

/// A minimal surface for a habit created without its own UI.
List<Map<String, dynamic>> defaultHabitComponents(HabitKind kind, {String title = '', String unit = ''}) => [
      _column(['main']),
      switch (kind) {
        HabitKind.count => _h('main', 'Counter', {
            'label': title,
            'unit': unit,
            'value': {_path: '/value'},
            'target': {_path: '/habit/target'},
          }),
        HabitKind.duration || HabitKind.practice => _h('main', 'PracticeTimer', {
            'label': title,
            'minutes': {_path: '/minutes'},
            'targetMinutes': {_path: '/habit/target'},
          }),
        _ => _h('main', 'HabitCheck', {
            'label': title.isEmpty ? 'Done today' : title,
            'done': {_path: '/done'},
          }),
      },
    ];
