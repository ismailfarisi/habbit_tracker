/// Flutter widgets behind the habit catalog components (see
/// habit_catalog.dart for their schemas and the data-model contract), plus
/// [HabitScope], which `HabitSurface` puts above the surface so components
/// can read the habit, the day and metric history.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:a2ui_core/a2ui_core.dart';
import 'package:a2ui_flutter/a2ui_flutter.dart';
import 'package:flutter/material.dart';

import '../finance/finance.dart';
import '../finance/money_screen.dart' show BudgetBar;
import '../habits/habit.dart';
import '../logic/speech_metrics.dart';
import 'habit_catalog.dart';
import 'speech_engine.dart';
import '../widgets/adaptive.dart';
import '../widgets/charts.dart';

/// Context a habit surface is rendered in.
class HabitScope extends InheritedWidget {
  final HabitDef habit;
  final DateTime day;
  final String speechLocale;

  /// Values of [metric] (a metrics key, `minutes` or `value`) for the last
  /// [days] days ending at [day], oldest first; null where nothing was logged.
  final List<num?> Function(String metric, int days) history;

  /// The user's money data, for the money components; null in previews.
  final Finance? finance;

  /// Records a money entry (MoneyLog); null where it cannot be saved.
  final Future<void> Function(MoneyEntry entry)? addMoney;

  const HabitScope({
    super.key,
    required this.habit,
    required this.day,
    required this.history,
    this.speechLocale = '',
    this.finance,
    this.addMoney,
    required super.child,
  });

  static HabitScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<HabitScope>();

  @override
  bool updateShouldNotify(HabitScope old) => true;
}

num _tidy(num n) => n % 1 == 0 ? n.toInt() : n;

String _fmt(num n) => n % 1 == 0 ? '${n.toInt()}' : n.toStringAsFixed(1);

void _write(BuildContext context, WritableBinding<Object?>? binding, Object? value) {
  if (binding == null) return;
  try {
    binding.set(value);
  } on A2uiDataError catch (e) {
    debugPrint('Habit surface write failed: ${e.code} ${e.message}');
  }
}

void _dispatch(
  SurfaceModel<ComponentImplementation>? surface,
  String componentId,
  String name,
  Map<String, dynamic> eventContext,
) {
  if (surface == null || surface.isDisposed) return;
  unawaited(surface.dispatchAction({
    'event': {'name': name, 'context': eventContext},
  }, componentId));
}

Widget buildHabitCheck(
  BuildContext context,
  ComponentNode<ComponentImplementation> node,
  ComponentProps props,
  ChildWidgetBuilder buildChild,
) {
  final binding = props.writable('done');
  final done = props.boolean('done') ?? false;
  final c = Theme.of(context).colorScheme;
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Material(
      color: done ? c.primaryContainer : c.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: CheckboxListTile.adaptive(
        value: done,
        onChanged: binding == null
            ? null
            : (v) {
                _write(context, binding, v ?? false);
                unawaited(props.action('onChanged')?.call());
              },
        title: Text(props.string('label') ?? 'Done today'),
        controlAffinity: ListTileControlAffinity.leading,
      ),
    ),
  );
}

Widget buildCounter(
  BuildContext context,
  ComponentNode<ComponentImplementation> node,
  ComponentProps props,
  ChildWidgetBuilder buildChild,
) {
  final binding = props.writable('value');
  final value = props.number('value') ?? 0;
  final target = props.number('target');
  final step = switch (props.value('step')) { final num n when n > 0 => n, _ => 1 };
  final unit = props.string('unit') ?? '';
  final label = props.string('label') ?? '';
  final t = Theme.of(context);
  void set(num next) {
    _write(context, binding, _tidy(math.max(0, next)));
    unawaited(props.action('onChanged')?.call());
  }

  final reached = target != null && target > 0 && value >= target;
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      if (label.isNotEmpty) Text(label, style: t.textTheme.titleSmall),
      Row(children: [
        IconButton.filledTonal(
          tooltip: 'Less',
          onPressed: binding == null || value <= 0 ? null : () => set(value - step),
          icon: const Icon(Icons.remove),
        ),
        Expanded(
          child: Text(
            target != null && target > 0 ? '${_fmt(value)} / ${_fmt(target)} $unit' : '${_fmt(value)} $unit',
            textAlign: TextAlign.center,
            style: t.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: reached ? t.colorScheme.primary : null,
            ),
          ),
        ),
        IconButton.filled(
          tooltip: 'More',
          onPressed: binding == null ? null : () => set(value + step),
          icon: const Icon(Icons.add),
        ),
      ]),
      if (target != null && target > 0) ...[
        const SizedBox(height: 4),
        LinearProgressIndicator(
          value: (value / target).clamp(0, 1).toDouble(),
          minHeight: 8,
          borderRadius: BorderRadius.circular(8),
        ),
      ],
    ]),
  );
}

Widget buildPracticeTimer(
  BuildContext context,
  ComponentNode<ComponentImplementation> node,
  ComponentProps props,
  ChildWidgetBuilder buildChild,
) {
  final surface = A2uiSurface.maybeOf(context);
  return PracticeTimerView(
    label: props.string('label') ?? 'Practice',
    minutes: props.number('minutes') ?? 0,
    target: props.number('targetMinutes'),
    onFinish: (elapsed, added) {
      _write(context, props.writable('minutes'), ((props.number('minutes') ?? 0) + added).round());
      _dispatch(surface, node.componentId, finishSessionAction, {'durationSec': elapsed.inSeconds});
    },
  );
}

class PracticeTimerView extends StatefulWidget {
  final String label;
  final num minutes;
  final num? target;
  final void Function(Duration elapsed, int addedMinutes) onFinish;
  const PracticeTimerView({super.key, required this.label, required this.minutes, this.target, required this.onFinish});

  @override
  State<PracticeTimerView> createState() => _PracticeTimerViewState();
}

class _PracticeTimerViewState extends State<PracticeTimerView> {
  Duration _banked = Duration.zero;
  DateTime? _startedAt;
  Timer? _ticker;

  Duration get _elapsed => _banked + (_startedAt == null ? Duration.zero : DateTime.now().difference(_startedAt!));
  bool get _running => _startedAt != null;

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _start() {
    setState(() => _startedAt = DateTime.now());
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  void _pause() {
    _ticker?.cancel();
    setState(() {
      _banked = _elapsed;
      _startedAt = null;
    });
  }

  void _finish() {
    _pause();
    final elapsed = _banked;
    setState(() => _banked = Duration.zero);
    widget.onFinish(elapsed, (elapsed.inSeconds / 60).round().clamp(1, 600));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final e = _elapsed;
    final clock = '${e.inMinutes.toString().padLeft(2, '0')}:${(e.inSeconds % 60).toString().padLeft(2, '0')}';
    final target = widget.target;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Expanded(child: Text(widget.label, style: t.textTheme.titleSmall)),
          Text(clock, style: t.textTheme.titleLarge?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
        ]),
        Text(
          target != null && target > 0
              ? 'Today: ${_fmt(widget.minutes)} / ${_fmt(target)} min'
              : 'Today: ${_fmt(widget.minutes)} min',
          style: TextStyle(color: t.colorScheme.onSurfaceVariant),
        ),
        if (target != null && target > 0) ...[
          const SizedBox(height: 4),
          LinearProgressIndicator(
            value: (widget.minutes / target).clamp(0, 1).toDouble(),
            minHeight: 8,
            borderRadius: BorderRadius.circular(8),
          ),
        ],
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          FilledButton.tonalIcon(
            style: compactButton,
            onPressed: _running ? _pause : _start,
            icon: Icon(_running ? Icons.pause : Icons.play_arrow),
            label: Text(_running ? 'Pause' : (e > Duration.zero ? 'Resume' : 'Start')),
          ),
          OutlinedButton(
            style: compactButton,
            onPressed: e > Duration.zero ? _finish : null,
            child: const Text('Finish & log'),
          ),
        ]),
      ]),
    );
  }
}

Widget buildReadAloudDrill(
  BuildContext context,
  ComponentNode<ComponentImplementation> node,
  ComponentProps props,
  ChildWidgetBuilder buildChild,
) {
  final surface = A2uiSurface.maybeOf(context);
  return ReadAloudDrillView(
    title: props.string('title') ?? 'Read aloud',
    text: props.string('text') ?? '',
    targetWords: [for (final w in props.list('targetWords')) if (w != null) '$w'],
    listen: props.value('listen') != false,
    speechLocale: HabitScope.maybeOf(context)?.speechLocale ?? '',
    onResult: (metrics, duration, transcript) {
      final data = <String, num>{
        'wpm': ?metrics.wordsPerMinute?.round(),
        'fillers': metrics.fillerCount,
        'accuracy': ?(metrics.accuracy == null ? null : (metrics.accuracy! * 100).round()),
      };
      if (surface != null) {
        for (final e in data.entries) {
          try {
            surface.dataModel.set('/metrics/${e.key}', e.value);
          } on A2uiDataError catch (_) {}
        }
      }
      _dispatch(surface, node.componentId, finishSessionAction, {
        'durationSec': duration.inSeconds,
        'metrics': data,
        'transcript': transcript,
      });
    },
    onAskCoach: (metrics, transcript, text) => _dispatch(surface, node.componentId, askCoachAction, {
      'exercise': text,
      'transcript': transcript,
      'measured': metrics.describe(),
    }),
  );
}

/// The read-aloud recorder that used to live in the Train tab: shows a text,
/// records the user and measures pace, fillers and how much was recognised.
class ReadAloudDrillView extends StatefulWidget {
  final String title;
  final String text;
  final List<String> targetWords;
  final bool listen;
  final String speechLocale;
  final void Function(SpeechMetrics metrics, Duration duration, String transcript) onResult;
  final void Function(SpeechMetrics metrics, String transcript, String text)? onAskCoach;

  const ReadAloudDrillView({
    super.key,
    required this.title,
    required this.text,
    this.targetWords = const [],
    this.listen = true,
    this.speechLocale = '',
    required this.onResult,
    this.onAskCoach,
  });

  @override
  State<ReadAloudDrillView> createState() => _ReadAloudDrillViewState();
}

class _ReadAloudDrillViewState extends State<ReadAloudDrillView> {
  late final SpeechEngine _engine = speechEngineFactory();
  final _transcript = TextEditingController();
  final _watch = Stopwatch();
  bool _ready = false;
  bool _recording = false;
  bool _speaking = false;
  String _status = '';
  SpeechMetrics? _metrics;
  double? _hitRate;

  @override
  void dispose() {
    _engine.dispose();
    _transcript.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_recording) {
      await _engine.stop();
      _stopped();
      return;
    }
    if (!_ready) {
      _ready = await _engine.init(
        onStopped: () {
          if (_recording) _stopped();
        },
        onError: (m) {
          if (!mounted) return;
          setState(() => _status = 'Mic error: $m');
          if (_recording) _stopped();
        },
      );
      if (!_ready) {
        if (mounted) {
          setState(() => _status = 'Speech recognition is unavailable. Type what you said, then tap Save result.');
        }
        return;
      }
    }
    _watch
      ..reset()
      ..start();
    setState(() {
      _recording = true;
      _status = 'Listening… speak clearly, tap Stop when done.';
      _metrics = null;
      _transcript.clear();
    });
    await _engine.listen(
      onWords: (w) {
        if (mounted) setState(() => _transcript.text = w);
      },
      localeId: widget.speechLocale,
    );
  }

  void _stopped() {
    if (!mounted || !_recording) return;
    _watch.stop();
    setState(() {
      _recording = false;
      _status = 'Recorded ${_watch.elapsed.inSeconds} s.';
    });
    _score();
  }

  /// Measures the transcript and reports it. A typed transcript has no
  /// duration, so it yields no pace.
  void _score() {
    final said = _transcript.text.trim();
    if (said.isEmpty) return;
    final m = analyzeSpeech(said, _watch.elapsed, target: widget.text);
    final heard = tokenize(said).toSet();
    final targets = widget.targetWords.expand(tokenize).toSet();
    setState(() {
      _metrics = m;
      _hitRate = targets.isEmpty ? null : targets.where(heard.contains).length / targets.length;
    });
    widget.onResult(m, _watch.elapsed, said);
  }

  Future<void> _speak() async {
    if (_speaking) {
      await _engine.stopSpeaking();
      if (mounted) setState(() => _speaking = false);
      return;
    }
    setState(() => _speaking = true);
    await _engine.speak(widget.text, onDone: () {
      if (mounted) setState(() => _speaking = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final m = _metrics;
    final wpm = m?.wordsPerMinute;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Text(widget.title, style: t.textTheme.titleSmall),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: t.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(widget.text, style: t.textTheme.bodyLarge),
        ),
        if (widget.targetWords.isNotEmpty) ...[
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 4, children: [
            for (final w in widget.targetWords)
              Chip(
                label: Text(w),
                visualDensity: VisualDensity.compact,
                backgroundColor: m == null
                    ? null
                    : (tokenize(_transcript.text).toSet().containsAll(tokenize(w))
                        ? Colors.green.shade200
                        : t.colorScheme.errorContainer),
              ),
          ]),
        ],
        const SizedBox(height: 8),
        Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          FilledButton.icon(
            style: _recording ? compactButton.merge(FilledButton.styleFrom(backgroundColor: t.colorScheme.error)) : compactButton,
            onPressed: _toggle,
            icon: Icon(_recording ? Icons.stop : Icons.mic),
            label: Text(_recording ? 'Stop' : 'Record'),
          ),
          if (widget.listen)
            OutlinedButton.icon(
              style: compactButton,
              onPressed: widget.text.trim().isEmpty ? null : _speak,
              icon: Icon(_speaking ? Icons.stop : Icons.volume_up_outlined),
              label: Text(_speaking ? 'Stop' : 'Hear it'),
            ),
        ]),
        if (_status.isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 4), child: Text(_status, style: t.textTheme.bodySmall)),
        const SizedBox(height: 8),
        TextField(
          controller: _transcript,
          minLines: 1,
          maxLines: 6,
          decoration: InputDecoration(
            labelText: 'Transcript',
            hintText: 'What you said appears here. You can also type it.',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              tooltip: 'Save result',
              icon: const Icon(Icons.check),
              onPressed: _recording ? null : _score,
            ),
          ),
        ),
        if (m != null) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _MetricTile(label: 'words', value: '${m.wordCount}'),
            if (wpm != null) _MetricTile(label: 'words/min', value: '${wpm.round()}'),
            _MetricTile(label: 'fillers', value: '${m.fillerCount}'),
            if (m.accuracy != null) _MetricTile(label: 'clarity match', value: '${(m.accuracy! * 100).round()}%'),
            if (_hitRate != null) _MetricTile(label: 'target words', value: '${(_hitRate! * 100).round()}%'),
          ]),
          if (widget.onAskCoach != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => widget.onAskCoach!(m, _transcript.text.trim(), widget.text),
                icon: const Icon(Icons.rate_review_outlined),
                label: const Text('Ask coach for feedback'),
              ),
            ),
        ],
      ]),
    );
  }
}

class _MetricTile extends StatelessWidget {
  final String label;
  final String value;
  const _MetricTile({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ]),
      );
}

Widget buildPromptCard(
  BuildContext context,
  ComponentNode<ComponentImplementation> node,
  ComponentProps props,
  ChildWidgetBuilder buildChild,
) {
  final t = Theme.of(context);
  final title = props.string('title') ?? '';
  final body = props.string('body') ?? '';
  final steps = [for (final s in props.list('steps')) if (s != null) '$s'];
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: DefaultTextStyle.merge(
        style: TextStyle(color: t.colorScheme.onSecondaryContainer),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          if (title.isNotEmpty) Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          if (body.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(body)),
          for (var i = 0; i < steps.length; i++)
            Padding(padding: const EdgeInsets.only(top: 4), child: Text('${i + 1}. ${steps[i]}')),
        ]),
      ),
    ),
  );
}

Widget buildRatingInput(
  BuildContext context,
  ComponentNode<ComponentImplementation> node,
  ComponentProps props,
  ChildWidgetBuilder buildChild,
) {
  final binding = props.writable('value');
  final rating = props.number('value') ?? 0;
  final max = switch (props.value('max')) { final num n => n.toInt().clamp(3, 10), _ => 5 };
  final label = props.string('label') ?? '';
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      if (label.isNotEmpty) Text(label, style: Theme.of(context).textTheme.titleSmall),
      Wrap(children: [
        for (var star = 1; star <= max; star++)
          IconButton(
            tooltip: '$star',
            visualDensity: VisualDensity.compact,
            icon: Icon(star <= rating ? Icons.star : Icons.star_border, color: Colors.amber.shade700),
            onPressed: binding == null
                ? null
                : () {
                    _write(context, binding, star == rating ? 0 : star);
                    unawaited(props.action('onChanged')?.call());
                  },
          ),
      ]),
    ]),
  );
}

Widget buildChoiceChips(
  BuildContext context,
  ComponentNode<ComponentImplementation> node,
  ComponentProps props,
  ChildWidgetBuilder buildChild,
) {
  final binding = props.writable('value');
  final selected = props.string('value');
  final label = props.string('label') ?? '';
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      if (label.isNotEmpty) Text(label, style: Theme.of(context).textTheme.titleSmall),
      Wrap(spacing: 8, children: [
        for (final o in props.list('options'))
          if (o != null)
            ChoiceChip(
              label: Text('$o'),
              selected: selected == '$o',
              onSelected: binding == null
                  ? null
                  : (on) {
                      _write(context, binding, on ? '$o' : null);
                      unawaited(props.action('onChanged')?.call());
                    },
            ),
      ]),
    ]),
  );
}

Widget buildMetricTrend(
  BuildContext context,
  ComponentNode<ComponentImplementation> node,
  ComponentProps props,
  ChildWidgetBuilder buildChild,
) {
  final metric = props.string('metric') ?? '';
  final days = switch (props.value('days')) { final num n => n.toInt().clamp(2, 365), _ => 30 };
  final scope = HabitScope.maybeOf(context);
  final field = scope?.habit.metricFields.where((f) => f.key == metric).firstOrNull;
  return MetricTrendView(
    label: props.string('label') ?? field?.label ?? metric,
    unit: props.string('unit') ?? field?.unit ?? '',
    lowerIsBetter: field?.better == 'down',
    values: scope?.history(metric, days) ?? const [],
    days: days,
  );
}

/// A sparkline of one metric with its latest value and the change since the
/// first logged value in the window.
class MetricTrendView extends StatelessWidget {
  final String label;
  final String unit;
  final bool lowerIsBetter;
  final List<num?> values;
  final int days;
  const MetricTrendView({
    super.key,
    required this.label,
    this.unit = '',
    this.lowerIsBetter = false,
    required this.values,
    this.days = 30,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final points = values.whereType<num>().toList();
    final delta = points.length < 2 ? null : points.last - points.first;
    final good = delta == null || delta == 0 ? null : (delta > 0) != lowerIsBetter;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(children: [Row(children: [
        Expanded(
          flex: 3,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(label, style: t.textTheme.titleSmall),
            Text(
              points.isEmpty ? 'No data yet' : '${_fmt(points.last)} $unit'.trim(),
              style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
            if (delta != null && delta != 0)
              Text(
                '${delta > 0 ? '+' : ''}${_fmt(delta)} in $days days',
                style: t.textTheme.bodySmall?.copyWith(color: good! ? Colors.green.shade700 : t.colorScheme.error),
              ),
          ]),
        ),
        Expanded(
          flex: 4,
          child: SizedBox(
            height: 44,
            child: CustomPaint(painter: _SparklinePainter(values, t.colorScheme.primary)),
          ),
        ),
      ]), if (points.isNotEmpty) ChartValues.days(values, HabitScope.maybeOf(context)?.day ?? DateTime.now(), unit)]),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final List<num?> values;
  final Color color;
  _SparklinePainter(this.values, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final points = <Offset>[];
    final present = values.whereType<num>();
    if (present.isEmpty) return;
    final lo = present.reduce(math.min).toDouble(), hi = present.reduce(math.max).toDouble();
    final span = hi - lo == 0 ? 1.0 : hi - lo;
    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      if (v == null) continue;
      final x = values.length == 1 ? size.width : size.width * i / (values.length - 1);
      final y = hi == lo ? size.height / 2 : size.height - 4 - (size.height - 8) * (v - lo) / span;
      points.add(Offset(x, y));
    }
    final line = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    for (var i = 1; i < points.length; i++) {
      canvas.drawLine(points[i - 1], points[i], line);
    }
    for (final p in points) {
      canvas.drawCircle(p, 2.5, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_SparklinePainter old) => old.values != values || old.color != color;
}

Widget buildMoneyLog(
  BuildContext context,
  ComponentNode<ComponentImplementation> node,
  ComponentProps props,
  ChildWidgetBuilder buildChild,
) => MoneyLogView(
  label: props.string('label') ?? '',
  category: props.string('category') ?? 'Other',
  income: props.value('income') == true,
  value: props.number('value') ?? 0,
  onLogged: (major) {
    _write(context, props.writable('value'), _tidy((props.number('value') ?? 0) + major));
    _write(context, props.writable('done'), true);
    unawaited(props.action('onChanged')?.call());
  },
);

/// An amount field that records a spending (or income) entry in Money and
/// adds the amount to the habit's value for the day.
class MoneyLogView extends StatefulWidget {
  final String label, category;
  final bool income;
  final num value;
  final void Function(num major) onLogged;
  const MoneyLogView({
    super.key,
    required this.label,
    required this.category,
    required this.income,
    required this.value,
    required this.onLogged,
  });

  @override
  State<MoneyLogView> createState() => _MoneyLogViewState();
}

class _MoneyLogViewState extends State<MoneyLogView> {
  final _ctl = TextEditingController();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _add(HabitScope scope, Finance f) async {
    final minor = parseMoney(_ctl.text, f.currency);
    if (minor == null || minor <= 0) return;
    final day = scope.day, now = DateTime.now();
    final cats = widget.income ? incomeCategories : spendCategories;
    await scope.addMoney!(
      MoneyEntry(
        at: DateTime(day.year, day.month, day.day, now.hour, now.minute),
        amount: minor,
        income: widget.income,
        category: cats.contains(widget.category) ? widget.category : cats.last,
        note: scope.habit.title,
      ),
    );
    _ctl.clear();
    widget.onLogged(toMajor(minor, f.currency));
  }

  @override
  Widget build(BuildContext context) {
    final scope = HabitScope.maybeOf(context);
    final f = scope?.finance;
    final t = Theme.of(context);
    final canSave = f != null && scope?.addMoney != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.label.isNotEmpty) Text(widget.label, style: t.textTheme.titleSmall),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ctl,
                  enabled: canSave,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    hintText: '0',
                    suffixText: f?.currency ?? '',
                    helperText: widget.value > 0 && f != null
                        ? '${f.fmt(toMinor(widget.value, f.currency))} today · ${widget.category}'
                        : widget.category,
                  ),
                  onSubmitted: canSave ? (_) => _add(scope!, f) : null,
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(onPressed: canSave ? () => _add(scope!, f) : null, child: const Text('Add')),
            ],
          ),
        ],
      ),
    );
  }
}

Widget buildBudgetBar(
  BuildContext context,
  ComponentNode<ComponentImplementation> node,
  ComponentProps props,
  ChildWidgetBuilder buildChild,
) {
  final scope = HabitScope.maybeOf(context);
  final f = scope?.finance;
  if (f == null) return const SizedBox.shrink();
  final cat = props.string('category');
  final m = f.month(scope!.day);
  final limit = cat == null ? f.budgets.values.fold(0, (a, b) => a + b) : f.budgets[cat] ?? 0;
  final spent = cat == null ? f.budgets.keys.fold(0, (a, k) => a + (m.byCategory[k] ?? 0)) : m.byCategory[cat] ?? 0;
  final label = props.string('label') ?? (cat == null ? 'Budgets this month' : '$cat this month');
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: limit <= 0
        ? Text(
            '$label: ${f.fmt(cat == null ? m.spent : spent)} spent · no budget set',
            style: Theme.of(context).textTheme.bodyMedium,
          )
        : BudgetBar(spent: spent, limit: limit, label: label, f: f),
  );
}

Widget buildSavingsProgress(
  BuildContext context,
  ComponentNode<ComponentImplementation> node,
  ComponentProps props,
  ChildWidgetBuilder buildChild,
) {
  final f = HabitScope.maybeOf(context)?.finance;
  final want = props.string('pot')?.toLowerCase();
  final pots = f?.pots.where((p) => !p.archived).toList() ?? const <SavingsPot>[];
  final pot =
      pots.where((p) => want == null || p.id == want || p.name.toLowerCase() == want).firstOrNull ?? pots.firstOrNull;
  final t = Theme.of(context);
  if (f == null || pot == null) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text('Create a savings pot in Money to see its progress here.', style: t.textTheme.bodyMedium),
    );
  }
  final saved = f.potSaved(pot.id);
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('${pot.emoji} ${pot.name}', style: t.textTheme.titleSmall),
        const SizedBox(height: 4),
        LinearProgressIndicator(
          value: pot.target <= 0 ? 0 : (saved / pot.target).clamp(0, 1).toDouble(),
          minHeight: 8,
          borderRadius: BorderRadius.circular(8),
        ),
        const SizedBox(height: 4),
        Text('${f.fmt(saved)} of ${f.fmt(pot.target)}', style: t.textTheme.bodySmall),
      ],
    ),
  );
}
