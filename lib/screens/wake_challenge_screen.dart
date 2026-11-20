import 'dart:math';

import 'package:flutter/material.dart';

import '../agent/speech_engine.dart';
import '../app_state.dart';
import '../logic/wake_challenge.dart';
import '../models.dart';
import '../widgets/adaptive.dart';

/// Marks today's wake-up, through the anti-snooze challenge when it is on.
/// Returns whether the wake-up was logged.
Future<bool> openWakeChallenge(BuildContext context, AppState state, {Random? rng}) async {
  if (state.settings.wakeChallenge == WakeChallenge.off) {
    await state.markWake();
    return true;
  }
  final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => WakeChallengeScreen(state: state, mode: state.settings.wakeChallenge, rng: rng),
  ));
  return ok ?? false;
}

/// "Prove you're up": read a phrase aloud or solve math problems; only then
/// is the wake-up logged.
class WakeChallengeScreen extends StatefulWidget {
  final AppState state;
  final WakeChallenge mode;
  final Random? rng;

  /// Try the challenge (e.g. from Settings) without logging a wake-up.
  final bool practice;
  const WakeChallengeScreen({super.key, required this.state, required this.mode, this.rng, this.practice = false});

  @override
  State<WakeChallengeScreen> createState() => _WakeChallengeScreenState();
}

class _WakeChallengeScreenState extends State<WakeChallengeScreen> {
  late final Random _rng = widget.rng ?? Random();
  late WakeChallenge _mode = widget.mode == WakeChallenge.off ? WakeChallenge.math : widget.mode;
  bool _done = false;

  late String _phrase = randomWakePhrase(_rng);
  SpeechEngine? _speech;
  bool _listening = false;
  String _heard = '';
  String? _speechError;

  late MathProblem _problem = mathProblem(_rng);
  int _solved = 0;
  final _answer = TextEditingController();
  String? _mathHint;

  @override
  void dispose() {
    _speech?.dispose();
    _answer.dispose();
    super.dispose();
  }

  Future<void> _succeed() async {
    if (_done) return;
    setState(() => _done = true);
    await _speech?.stop();
    if (!widget.practice) await widget.state.markWake();
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text(widget.practice ? 'Challenge passed. It will be ready tomorrow morning.' : "☀️ You're up! Wake-up logged."),
    ));
    Navigator.of(context).pop(true);
  }

  Future<void> _listen() async {
    if (_listening) {
      await _speech?.stop();
      setState(() => _listening = false);
      return;
    }
    setState(() {
      _speechError = null;
      _heard = '';
    });
    var speech = _speech;
    if (speech == null) {
      speech = _speech = speechEngineFactory();
      final ok = await speech.init(
        onStopped: () {
          if (mounted) setState(() => _listening = false);
        },
        onError: (m) {
          if (mounted) setState(() => _speechError = m);
        },
      );
      if (!ok) {
        if (mounted) setState(() => _speechError = 'Speech recognition is not available on this device.');
        return;
      }
    }
    if (!mounted) return;
    setState(() => _listening = true);
    await speech.listen(
      localeId: widget.state.settings.speechLocale,
      onWords: (w) {
        if (!mounted || _done) return;
        setState(() => _heard = w);
        if (phraseMatches(_phrase, w)) _succeed();
      },
    );
  }

  void _newPhrase() {
    _speech?.stop();
    setState(() {
      _phrase = randomWakePhrase(_rng, not: _phrase);
      _heard = '';
      _listening = false;
    });
  }

  void _check() {
    final v = int.tryParse(_answer.text.trim());
    if (v == null) return;
    _answer.clear();
    if (v != _problem.answer) {
      setState(() => _mathHint = 'Not quite. Try again.');
      return;
    }
    _solved++;
    if (_solved >= wakeChallengeMathCount) {
      _succeed();
      return;
    }
    setState(() {
      _mathHint = null;
      _problem = mathProblem(_rng);
    });
  }

  void _switchToMath() {
    _speech?.stop();
    setState(() {
      _listening = false;
      _mode = WakeChallenge.math;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text("Prove you're up")),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              _mode == WakeChallenge.readAloud
                  ? 'Read this sentence out loud, clearly:'
                  : 'Solve $wakeChallengeMathCount quick problems to log your wake-up.',
              style: t.titleMedium,
            ),
            const SizedBox(height: 24),
            ...(_mode == WakeChallenge.readAloud ? _readAloud(context) : _math(context)),
          ],
        ),
      ),
    );
  }

  List<Widget> _readAloud(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final score = _heard.isEmpty ? 0.0 : phraseMatchScore(_phrase, _heard);
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text('“$_phrase”', key: const Key('wakePhrase'), style: t.headlineSmall),
        ),
      ),
      const SizedBox(height: 16),
      FilledButton.icon(
        style: primaryButton,
        onPressed: _done ? null : _listen,
        icon: Icon(_listening ? Icons.stop : Icons.mic),
        label: Text(_listening ? 'Stop' : 'Start reading'),
      ),
      const SizedBox(height: 16),
      if (_heard.isNotEmpty) ...[
        Text('Heard: $_heard', style: t.bodyMedium),
        const SizedBox(height: 8),
        LinearProgressIndicator(value: score),
        const SizedBox(height: 4),
        Text('${(score * 100).round()}% matched (80% needed)', style: t.bodySmall),
      ],
      if (_speechError != null) ...[
        const SizedBox(height: 8),
        Text(_speechError!, style: t.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.error)),
      ],
      const SizedBox(height: 16),
      Wrap(spacing: 8, children: [
        TextButton(onPressed: _done ? null : _newPhrase, child: const Text('Different sentence')),
        TextButton(onPressed: _done ? null : _switchToMath, child: const Text("Can't speak now? Solve math instead")),
      ]),
    ];
  }

  List<Widget> _math(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return [
      Text('Problem ${_solved + 1} of $wakeChallengeMathCount', style: t.labelLarge),
      const SizedBox(height: 8),
      Text('${_problem.question} = ?', key: const Key('mathQuestion'), style: t.displaySmall),
      const SizedBox(height: 16),
      TextField(
        key: const Key('mathAnswer'),
        controller: _answer,
        autofocus: true,
        enabled: !_done,
        keyboardType: TextInputType.number,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _check(),
        decoration: InputDecoration(labelText: 'Answer', border: const OutlineInputBorder(), errorText: _mathHint),
      ),
      const SizedBox(height: 12),
      FilledButton(style: primaryButton, onPressed: _done ? null : _check, child: const Text('Check')),
    ];
  }
}
