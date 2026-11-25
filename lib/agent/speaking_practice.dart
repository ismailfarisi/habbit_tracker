import 'dart:async';

import 'package:a2ui_core/a2ui_core.dart';
import 'package:a2ui_flutter/a2ui_flutter.dart';
import 'package:flutter/material.dart';

import '../habits/habit.dart';
import '../logic/speech_metrics.dart';
import '../widgets/adaptive.dart';
import 'habit_components.dart';
import 'habit_surface.dart';

Widget buildSpeakingPractice(
  BuildContext context,
  ComponentNode<ComponentImplementation> node,
  ComponentProps props,
  ChildWidgetBuilder buildChild,
) {
  final scope = HabitScope.maybeOf(context)!;
  final surface = A2uiSurface.maybeOf(context);
  final draftKey = 'speakingPractice-${node.componentId}';
  final existing = scope.readEntry().data[draftKey];
  final target = scope.habit.target;
  final minutes = target % 1 == 0 ? target.toInt().toString() : target.toString();
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      FilledButton.icon(
        style: primaryButton,
        icon: const Icon(Icons.play_arrow),
        label: Text(existing is Map ? 'Resume practice' : 'Start $minutes-minute practice'),
        onPressed: () {
          final entry = scope.readEntry().copy();
          final previous = entry.data[draftKey];
          final draft = previous is Map
              ? Map<String, dynamic>.from(previous)
              : <String, dynamic>{'id': DateTime.now().microsecondsSinceEpoch.toString(), 'stage': 0};
          entry.data[draftKey] = draft;
          scope.savePractice(entry, finished: false);
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => _PracticePage(
                scope: scope,
                draftKey: draftKey,
                draft: Map.of(draft),
                warmupTitle: props.string('warmupTitle') ?? 'Warm-up',
                steps: props.list('steps').whereType<String>().toList(),
                title: props.string('title') ?? 'Read aloud',
                passage: props.string('text') ?? '',
                words: props.list('targetWords').whereType<String>().toList(),
                listen: props.value('listen') != false,
                askCoach: !scope.preview && surface != null
                    ? (m, transcript, text) {
                        if (!surface.isDisposed) {
                          unawaited(
                            surface.dispatchAction({
                              'event': {
                                'name': 'askCoach',
                                'context': {'exercise': text, 'transcript': transcript, 'measured': m.describe()},
                              },
                            }, node.componentId),
                          );
                        }
                      }
                    : null,
              ),
            ),
          );
        },
      ),
      const SizedBox(height: 8),
      Text('Warm up, read aloud, then record or type what you said.', style: Theme.of(context).textTheme.bodyMedium),
    ],
  );
}

class _PracticePage extends StatefulWidget {
  final HabitScope scope;
  final String draftKey;
  final Map<String, dynamic> draft;
  final String warmupTitle;
  final List<String> steps;
  final String title;
  final String passage;
  final List<String> words;
  final bool listen;
  final void Function(SpeechMetrics, String, String)? askCoach;

  const _PracticePage({
    required this.scope,
    required this.draftKey,
    required this.draft,
    required this.warmupTitle,
    required this.steps,
    required this.title,
    required this.passage,
    required this.words,
    required this.listen,
    required this.askCoach,
  });

  @override
  State<_PracticePage> createState() => _PracticePageState();
}

class _PracticePageState extends State<_PracticePage> with WidgetsBindingObserver {
  final _watch = Stopwatch();
  Timer? _tick;
  bool _finished = false;
  bool _finishing = false;
  final _drill = GlobalKey<ReadAloudDrillState>();
  late int _stage = ((widget.draft['stage'] as num?)?.toInt() ?? 0).clamp(widget.steps.isEmpty ? 1 : 0, 2);
  late final Duration _prior = Duration(milliseconds: (widget.draft['elapsedMs'] as num?)?.toInt() ?? 0);
  late String _transcript = widget.draft['transcript'] as String? ?? '';
  late Duration _sample = Duration(milliseconds: (widget.draft['sampleMs'] as num?)?.toInt() ?? 0);

  Duration get _elapsed => _prior + _watch.elapsed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  void _start() {
    if (_watch.isRunning) return;
    _watch.start();
    _tick = Timer.periodic(const Duration(seconds: 1), (t) {
      setState(() {});
      // A hard process kill can skip lifecycle notifications. Keep a recent
      // checkpoint, without scheduling reminders or counting time away.
      if (t.tick % 5 == 0) _checkpoint();
    });
  }

  HabitEntry? _entry() {
    final entry = widget.scope.readEntry();
    final current = entry.data[widget.draftKey];
    if (_finished || current is! Map || current['id'] != widget.draft['id']) return null;
    return entry.copy();
  }

  void _checkpoint() {
    final entry = _entry();
    if (entry == null) return;
    entry.data[widget.draftKey] = {
      ...widget.draft,
      'stage': _stage,
      'elapsedMs': _elapsed.inMilliseconds,
      'transcript': _transcript,
      'sampleMs': _sample.inMilliseconds,
    };
    widget.scope.savePractice(entry, finished: false);
  }

  void _pause() {
    if (!_watch.isRunning) return;
    _drill.currentState?.interrupt();
    _watch.stop();
    _tick?.cancel();
    _checkpoint();
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) _pause();
  }

  @override
  void dispose() {
    _tick?.cancel();
    _watch.stop();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _changeStage(int next) {
    _drill.currentState?.interrupt();
    setState(() => _stage = next);
    _checkpoint();
  }

  void _capture(String text, Duration duration) {
    if (_finished || !_watch.isRunning) return;
    _transcript = text;
    _sample = duration;
    _checkpoint();
  }

  Future<void> _finish() async {
    if (_finishing) return;
    _finishing = true;
    await _drill.currentState?.stopRecording();
    if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? false)) return;
    final entry = _entry();
    if (entry == null) return;
    _finished = true;
    _drill.currentState?.interrupt();
    _watch.stop();
    _tick?.cancel();
    final said = _transcript.trim();
    final result = analyzeSpeech(said, _sample, target: widget.passage);
    final metrics = <String, num>{
      if (said.isNotEmpty) ...{
        'wpm': ?result.wordsPerMinute?.round(),
        'fillers': result.fillerCount,
        'accuracy': ?(result.accuracy == null ? null : (100 * result.accuracy!).round()),
      },
    };
    entry.data.remove(widget.draftKey);
    widget.scope.savePractice(
      applyFinishSession(entry, {
        'addMinutes': (_elapsed.inSeconds / 60).round().clamp(1, 1440),
        'durationSec': _elapsed.inSeconds,
        'transcript': said.isEmpty ? null : said,
        'metrics': metrics,
      }, DateTime.now()),
      finished: true,
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    const stages = ['Warm-up', 'Reading', 'Recording'];
    final running = _watch.isRunning;
    final elapsed = _elapsed;
    final clock = '${elapsed.inMinutes}:${(elapsed.inSeconds % 60).toString().padLeft(2, '0')}';
    return PopScope(
      onPopInvokedWithResult: (popped, _) {
        if (popped && !_finished) _pause();
      },
      child: Scaffold(
        appBar: AppBar(title: Text(widget.scope.habit.title)),
        bottomNavigationBar: SafeArea(
          minimum: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 8,
            alignment: WrapAlignment.center,
            children: [
              OutlinedButton.icon(
                icon: Icon(running ? Icons.pause : Icons.play_arrow),
                label: Text(running ? 'Pause' : 'Resume'),
                onPressed: running ? _pause : () => setState(_start),
              ),
              FilledButton(onPressed: _finish, child: const Text('Finish & log')),
            ],
          ),
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text('${stages[_stage]} · $clock', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              if (!running)
                const Text('Practice paused. Resume when you’re ready.')
              else ...[
                if (_stage == 0) ...[
                  Text(widget.warmupTitle, style: Theme.of(context).textTheme.titleMedium),
                  for (final (i, step) in widget.steps.indexed)
                    Padding(padding: const EdgeInsets.only(top: 8), child: Text('${i + 1}. $step')),
                ] else
                  ReadAloudDrillView(
                    key: _drill,
                    title: widget.title,
                    text: widget.passage,
                    targetWords: widget.words,
                    listen: widget.listen,
                    readingOnly: _stage == 1,
                    allowAudio: !widget.scope.preview,
                    speechLocale: widget.scope.speechLocale,
                    initialTranscript: _transcript,
                    initialSampleDuration: _sample,
                    onTranscript: _capture,
                    onResult: (_, duration, transcript) => _capture(transcript, duration),
                    onAskCoach: widget.askCoach == null
                        ? null
                        : (m, transcript, text) {
                            _pause();
                            widget.askCoach!(m, transcript, text);
                          },
                  ),
                const SizedBox(height: 16),
                if (_stage < 2)
                  FilledButton.tonal(
                    onPressed: () => _changeStage(_stage + 1),
                    child: Text(_stage == 0 ? 'Continue to reading' : 'Continue to recording'),
                  ),
                if (_stage > (widget.steps.isEmpty ? 1 : 0))
                  TextButton(
                    onPressed: () => _changeStage(_stage - 1),
                    child: Text('Back to ${stages[_stage - 1].toLowerCase()}'),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
