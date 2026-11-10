import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../app_state.dart';
import '../logic/speech_metrics.dart';
import '../services/coach_prompts.dart';
import '../services/openrouter.dart';
import '../services/task_tools.dart';
import '../widgets/assistant_chat.dart';
import 'home_screen.dart';

const _warmups = [
  'Lip trills: blow air through relaxed lips ("brrr") for 15 seconds, sliding pitch up and down.',
  'Tongue stretch: tongue out and down, then up toward your nose, then side to side. 5 reps each.',
  'Jaw release: massage your jaw hinge, then open wide and say "yah-yah-yah" 10 times.',
  'Over-articulate: "pa-ta-ka" 10 times slowly, then 10 times quickly but crisply.',
  'Breath: inhale 4 s into your belly, then exhale on a steady "sss" for as long as you can.',
];

class TrainScreen extends StatefulWidget {
  final AppState state;
  final void Function(int tab) onNavigate;
  const TrainScreen({super.key, required this.state, required this.onNavigate});

  @override
  State<TrainScreen> createState() => _TrainScreenState();
}

class _TrainScreenState extends State<TrainScreen> {
  // Session timer
  Duration _sessionBanked = Duration.zero;
  DateTime? _sessionStartedAt;
  Timer? _ticker;

  // Exercise
  ExerciseType _type = ExerciseType.twister;
  String _level = 'intermediate';
  final _focus = TextEditingController();
  final _exercise = TextEditingController();
  bool _generating = false;

  // Recording
  final _speech = SpeechToText();
  final _tts = FlutterTts();
  bool _speechReady = false;
  bool _recording = false;
  bool _speaking = false;
  String _recStatus = '';
  String _transcriptBase = '';
  final _transcript = TextEditingController();
  final _recWatch = Stopwatch();
  SpeechMetrics? _metrics;

  // Chat
  late final _chat = AssistantChat(
    widget.state,
    systemPrompt: () => '$coachSystemPrompt\n$coachTaskPrompt\n${plannerContext(widget.state.settings, DateTime.now())}',
  );

  @override
  void initState() {
    super.initState();
    _tts.setCompletionHandler(() => setState(() => _speaking = false));
    _tts.setSpeechRate(0.42);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _speech.cancel();
    _tts.stop();
    _chat.dispose();
    for (final c in [_focus, _exercise, _transcript]) {
      c.dispose();
    }
    super.dispose();
  }

  // ---------- Session ----------
  Duration get _sessionElapsed =>
      _sessionBanked + (_sessionStartedAt == null ? Duration.zero : DateTime.now().difference(_sessionStartedAt!));

  bool get _sessionRunning => _sessionStartedAt != null;

  void _startSession() {
    if (_sessionRunning) return;
    setState(() => _sessionStartedAt = DateTime.now());
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  void _pauseSession() {
    _ticker?.cancel();
    setState(() {
      _sessionBanked = _sessionElapsed;
      _sessionStartedAt = null;
    });
  }

  Future<void> _finishSession() async {
    _pauseSession();
    final minutes = (_sessionBanked.inSeconds / 60).round().clamp(1, 600);
    await widget.state.addTraining(minutes);
    setState(() => _sessionBanked = Duration.zero);
    if (!mounted) return;
    final goal = widget.state.settings.trainingGoalMin;
    final total = widget.state.today.trainingMinutes;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(total >= goal
          ? '🎉 Logged $minutes min. Daily goal reached!'
          : 'Logged $minutes min. ${goal - total} min to go today.'),
    ));
  }

  // ---------- AI ----------
  OpenRouterClient? _client() {
    final key = widget.state.apiKey;
    if (key.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Add your OpenRouter API key in Settings to use the AI coach.'),
        action: SnackBarAction(label: 'Settings', onPressed: () => widget.onNavigate(HomeScreen.settingsTab)),
      ));
      return null;
    }
    return OpenRouterClient(apiKey: key, model: widget.state.settings.model);
  }

  Future<void> _generate() async {
    final client = _client();
    if (client == null) return;
    _startSession();
    setState(() {
      _generating = true;
      _exercise.text = '';
      _metrics = null;
    });
    try {
      final prompt = exercisePrompt(_type, _level, _focus.text);
      await for (final t in client.stream([
        const ChatMessage('system', coachSystemPrompt),
        ChatMessage('user', prompt),
      ], temperature: 0.9)) {
        setState(() => _exercise.text += t);
      }
      _chat.addAssistantNote('Here is your ${_type.label.toLowerCase()} exercise:\n\n${_exercise.text}');
    } catch (e) {
      _showError(e);
    } finally {
      client.close();
      if (mounted) setState(() => _generating = false);
    }
  }

  void _showError(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
  }

  // ---------- Speech ----------
  Future<void> _toggleRecording() async {
    if (_recording) {
      await _speech.stop();
      _onRecordingStopped();
      return;
    }
    if (!_speechReady) {
      _speechReady = await _speech.initialize(
        onStatus: (s) {
          if ((s == 'done' || s == 'notListening') && _recording) _onRecordingStopped();
        },
        onError: (e) {
          setState(() => _recStatus = 'Mic error: ${e.errorMsg}');
          if (_recording) _onRecordingStopped();
        },
      );
      if (!_speechReady) {
        setState(() => _recStatus = 'Speech recognition is unavailable. You can type the transcript instead.');
        return;
      }
    }
    _startSession();
    await _tts.stop();
    _transcriptBase = _transcript.text.trim();
    _recWatch
      ..reset()
      ..start();
    setState(() {
      _recording = true;
      _recStatus = 'Listening… speak clearly, tap Stop when done.';
      _metrics = null;
    });
    final locale = widget.state.settings.speechLocale;
    await _speech.listen(
      onResult: (r) => setState(() {
        _transcript.text = [_transcriptBase, r.recognizedWords].where((s) => s.isNotEmpty).join(' ');
      }),
      listenOptions: SpeechListenOptions(
        listenFor: const Duration(minutes: 3),
        pauseFor: const Duration(seconds: 6),
        partialResults: true,
        listenMode: ListenMode.dictation,
        localeId: locale.isEmpty ? null : locale,
      ),
    );
  }

  void _onRecordingStopped() {
    _recWatch.stop();
    setState(() {
      _recording = false;
      _recStatus = 'Recorded ${_recWatch.elapsed.inSeconds} s.';
      _updateMetrics();
    });
  }

  void _updateMetrics() {
    if (_transcript.text.trim().isEmpty) {
      _metrics = null;
      return;
    }
    _metrics = analyzeSpeech(
      _transcript.text,
      _recWatch.elapsed,
      target: _type.readAloud ? _exercise.text : null,
    );
  }

  Future<void> _getFeedback() async {
    if (_transcript.text.trim().isEmpty) {
      _showError('Record or type what you said first.');
      return;
    }
    setState(_updateMetrics);
    final prompt = feedbackPrompt(
      type: _type,
      exercise: _exercise.text,
      transcript: _transcript.text,
      metrics: _metrics!,
    );
    await _chat.send(prompt, display: '🎙️ Please review my practice (transcript + metrics sent)');
  }

  Future<void> _speak() async {
    if (_speaking) {
      await _tts.stop();
      setState(() => _speaking = false);
      return;
    }
    final text = _exercise.text.trim();
    if (text.isEmpty) return;
    setState(() => _speaking = true);
    await _tts.speak(text.replaceAll(RegExp(r'[*#_`]'), ''));
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final e = _sessionElapsed;
    final timer = '${e.inMinutes.toString().padLeft(2, '0')}:${(e.inSeconds % 60).toString().padLeft(2, '0')}';
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Articulation coach', style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          _card('Session', trailing: Text(timer, style: t.textTheme.titleLarge?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])), children: [
            Text('Today: ${widget.state.today.trainingMinutes} / ${widget.state.settings.trainingGoalMin} min',
                style: TextStyle(color: t.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              FilledButton.tonalIcon(
                onPressed: _sessionRunning ? _pauseSession : _startSession,
                icon: Icon(_sessionRunning ? Icons.pause : Icons.play_arrow),
                label: Text(_sessionRunning ? 'Pause' : 'Start session'),
              ),
              OutlinedButton(
                onPressed: e.inSeconds > 0 ? _finishSession : null,
                child: const Text('Finish & log'),
              ),
            ]),
          ]),
          ExpansionTileCard(
            title: '1. Warm-up (2 min)',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < _warmups.length; i++)
                  Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text('${i + 1}. ${_warmups[i]}')),
              ],
            ),
          ),
          _card('2. Exercise', children: [
            DropdownButtonFormField<ExerciseType>(
              initialValue: _type,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Type', border: OutlineInputBorder()),
              items: [for (final x in ExerciseType.values) DropdownMenuItem(value: x, child: Text(x.label))],
              onChanged: (v) => setState(() => _type = v ?? _type),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _level,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Level', border: OutlineInputBorder()),
                  items: const [
                    DropdownMenuItem(value: 'beginner', child: Text('Beginner')),
                    DropdownMenuItem(value: 'intermediate', child: Text('Intermediate')),
                    DropdownMenuItem(value: 'advanced', child: Text('Advanced')),
                  ],
                  onChanged: (v) => setState(() => _level = v ?? _level),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _focus,
                  decoration: const InputDecoration(labelText: 'Focus sounds', hintText: 'r, th, s', border: OutlineInputBorder()),
                ),
              ),
            ]),
            const SizedBox(height: 12),
            Wrap(spacing: 8, children: [
              FilledButton.icon(
                onPressed: _generating ? null : _generate,
                icon: _generating
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.auto_awesome),
                label: const Text('Generate with AI'),
              ),
              OutlinedButton.icon(
                onPressed: _exercise.text.trim().isEmpty ? null : _speak,
                icon: Icon(_speaking ? Icons.stop : Icons.volume_up_outlined),
                label: Text(_speaking ? 'Stop' : 'Listen'),
              ),
            ]),
            const SizedBox(height: 12),
            TextField(
              controller: _exercise,
              minLines: 3,
              maxLines: 12,
              onChanged: (_) => setState(() {}),
              style: t.textTheme.bodyLarge,
              decoration: const InputDecoration(
                hintText: 'Generate an exercise, or paste any text you want to practise reading aloud.',
                border: OutlineInputBorder(),
              ),
            ),
          ]),
          _card('3. Speak & get feedback', children: [
            Row(children: [
              FilledButton.icon(
                style: _recording ? FilledButton.styleFrom(backgroundColor: t.colorScheme.error) : null,
                onPressed: _toggleRecording,
                icon: Icon(_recording ? Icons.stop : Icons.mic),
                label: Text(_recording ? 'Stop' : 'Record'),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(_recStatus, style: t.textTheme.bodySmall)),
            ]),
            const SizedBox(height: 12),
            TextField(
              controller: _transcript,
              minLines: 2,
              maxLines: 8,
              decoration: InputDecoration(
                labelText: 'Transcript',
                hintText: 'What you said appears here. You can also type it.',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () => setState(() {
                    _transcript.clear();
                    _metrics = null;
                  }),
                ),
              ),
            ),
            if (_metrics != null) ...[
              const SizedBox(height: 12),
              _MetricsRow(metrics: _metrics!),
            ],
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _recording ? null : _getFeedback,
              icon: const Icon(Icons.rate_review_outlined),
              label: const Text('Get AI feedback'),
            ),
          ]),
          _card('4. Coach chat',
              trailing: ListenableBuilder(
                listenable: _chat,
                builder: (_, _) => _chat.isEmpty
                    ? const SizedBox.shrink()
                    : IconButton(icon: const Icon(Icons.delete_outline), onPressed: _chat.clear),
              ),
              children: [
                AssistantChatView(
                  chat: _chat,
                  hint: 'Message your coach',
                  suggestions: const [
                    'How do I stop mumbling?',
                    'Give me a drill for the R sound',
                    'Schedule a 10-minute drill every evening at 9pm',
                  ],
                ),
              ]),
        ],
      ),
    );
  }

  Widget _card(String title, {Widget? trailing, required List<Widget> children}) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
              ?trailing,
            ]),
            const SizedBox(height: 12),
            ...children,
          ]),
        ),
      );
}

class ExpansionTileCard extends StatelessWidget {
  final String title;
  final Widget child;
  const ExpansionTileCard({super.key, required this.title, required this.child});

  @override
  Widget build(BuildContext context) => Card(
        clipBehavior: Clip.antiAlias,
        child: ExpansionTile(
          title: Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          shape: const Border(),
          children: [child],
        ),
      );
}

class _MetricsRow extends StatelessWidget {
  final SpeechMetrics metrics;
  const _MetricsRow({required this.metrics});

  @override
  Widget build(BuildContext context) {
    final wpm = metrics.wordsPerMinute;
    Widget tile(String label, String value, {String? hint}) => Tooltip(
          message: hint ?? '',
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(value, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              Text(label, style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
        );
    return Wrap(spacing: 8, runSpacing: 8, children: [
      tile('words', '${metrics.wordCount}'),
      if (wpm != null) tile('words/min', '${wpm.round()}', hint: 'Clear conversational pace is about 130-160'),
      tile('fillers', '${metrics.fillerCount}'),
      if (metrics.accuracy != null)
        tile('clarity match', '${(metrics.accuracy! * 100).round()}%', hint: 'Share of the exercise words the recognizer understood'),
    ]);
  }
}
