import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../services/tts.dart';
import '../services/voice_input.dart';
import 'adaptive.dart';

const voiceLanguages = {
  '': 'Auto (phone default)',
  'en_US': 'English',
  'ar_AE': 'Arabic',
  'ur_PK': 'Urdu',
  'hi_IN': 'Hindi',
  'ml_IN': 'Malayalam',
  'fr_FR': 'French',
};

/// Settings → Voice: dictation engine, Whisper model download and
/// text-to-speech options.
class VoiceSettingsSection extends StatefulWidget {
  final AppState state;
  const VoiceSettingsSection({super.key, required this.state});

  @override
  State<VoiceSettingsSection> createState() => _VoiceSettingsSectionState();
}

class _VoiceSettingsSectionState extends State<VoiceSettingsSection> {
  final _models = WhisperModels.instance;

  @override
  void initState() {
    super.initState();
    _models.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return ListenableBuilder(
      listenable: Listenable.merge([state, _models]),
      builder: (context, _) {
        final s = state.settings;
        final t = Theme.of(context);
        final model = s.whisperModel;
        final progress = _models.progressOf(model);
        final ready = _models.isReady(model);
        final languages = {
          ...voiceLanguages,
          if (!voiceLanguages.containsKey(s.speechLocale)) s.speechLocale: s.speechLocale,
        };
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: SegmentedButton<String>(
                key: const Key('voice-engine'),
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'whisper', label: Text('Whisper')),
                  ButtonSegment(value: 'system', label: Text("Phone's built-in")),
                ],
                selected: {s.voiceEngine},
                onSelectionChanged: (v) => state.updateSettings((x) => x.voiceEngine = v.first),
              ),
            ),
            if (s.voiceEngine == 'whisper') ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: SegmentedButton<String>(
                  key: const Key('whisper-model'),
                  showSelectedIcon: false,
                  segments: [
                    for (final e in WhisperModels.sizesMb.entries)
                      ButtonSegment(value: e.key, label: Text('${e.key == 'tiny' ? 'Fast' : 'Best'} · ${e.value} MB')),
                  ],
                  selected: {model},
                  onSelectionChanged: (v) => state.updateSettings((x) => x.whisperModel = v.first),
                ),
              ),
              ListTile(
                key: const Key('whisper-download'),
                leading: Icon(
                  ready ? Icons.offline_pin : Icons.download_for_offline_outlined,
                  color: ready ? t.colorScheme.primary : null,
                ),
                title: Text(
                  ready
                      ? 'Whisper model ready'
                      : progress != null
                      ? 'Downloading… ${(progress * 100).round()}%'
                      : 'Download Whisper model',
                ),
                subtitle: progress != null
                    ? Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: LinearProgressIndicator(value: progress),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            ready
                                ? 'Dictation runs fully on this phone and works offline.'
                                : "${WhisperModels.sizesMb[model]} MB, downloaded once. Until then the phone's voice input is used.",
                          ),
                          const SizedBox(height: 6),
                          ready
                              ? TextButton(onPressed: () => _models.delete(model), child: const Text('Delete model'))
                              : FilledButton.tonal(
                                  style: compactButton,
                                  onPressed: () => _models.download(model),
                                  child: const Text('Download'),
                                ),
                        ],
                      ),
              ),
              if (_models.error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(_models.error!, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error)),
                ),
            ],
            ListTile(
              leading: const Icon(Icons.translate),
              title: const Text('Voice language'),
              subtitle: DropdownButton<String>(
                key: const Key('voice-language'),
                value: s.speechLocale,
                isExpanded: true,
                underline: const SizedBox(),
                items: [for (final e in languages.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                onChanged: (v) => state.updateSettings((x) => x.speechLocale = v ?? ''),
              ),
            ),
            SpokenVoiceSection(state: state),
            SwitchListTile.adaptive(
              key: const Key('speak-confirmations'),
              secondary: const Icon(Icons.record_voice_over_outlined),
              title: const Text('Say tasks back'),
              subtitle: const Text('After you add a task by voice'),
              value: s.speakConfirmations,
              onChanged: (v) => state.updateSettings((x) => x.speakConfirmations = v),
            ),
            SwitchListTile.adaptive(
              key: const Key('read-coach-replies'),
              secondary: const Icon(Icons.volume_up_outlined),
              title: const Text('Read coach replies aloud'),
              value: s.readCoachReplies,
              onChanged: (v) => state.updateSettings((x) => x.readCoachReplies = v),
            ),
          ],
        );
      },
    );
  }
}

/// Which engine reads things aloud: the phone, Kokoro (downloaded only
/// when picked), or OpenAI / Grok with the user's key.
class SpokenVoiceSection extends StatefulWidget {
  final AppState state;
  const SpokenVoiceSection({super.key, required this.state});

  @override
  State<SpokenVoiceSection> createState() => _SpokenVoiceSectionState();
}

class _SpokenVoiceSectionState extends State<SpokenVoiceSection> {
  final _kokoro = KokoroModel.instance;
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    _kokoro.refresh();
  }

  Future<void> _pick(String engine) async {
    await widget.state.updateSettings((x) => x.ttsEngine = engine);
    lastTtsError.value = null;
    if (engine == 'kokoro') {
      await _kokoro.refresh();
      if (!_kokoro.ready) unawaited(_kokoro.download());
    }
  }

  Future<void> _sample() async {
    if (_playing) {
      await stopSpeaking();
      if (mounted) setState(() => _playing = false);
      return;
    }
    setState(() => _playing = true);
    await speakAloud('Hi! This is how your coach and reminders will sound.');
    if (mounted) setState(() => _playing = false);
  }

  Widget _dropdown<T>(Key key, T value, Map<T, String> items, void Function(T v) onChanged) => DropdownButton<T>(
    key: key,
    value: items.containsKey(value) ? value : items.keys.first,
    isExpanded: true,
    underline: const SizedBox(),
    items: [for (final e in items.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
    onChanged: (v) => v == null ? null : onChanged(v),
  );

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return ListenableBuilder(
      listenable: Listenable.merge([state, _kokoro, lastTtsError]),
      builder: (context, _) {
        final s = state.settings;
        final t = Theme.of(context);
        final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
        final engine = s.ttsEngine;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              leading: const Icon(Icons.graphic_eq),
              title: const Text('Spoken voice'),
              subtitle: _dropdown(const Key('tts-engine'), engine, ttsEngines, _pick),
            ),
            if (engine == 'kokoro') ...[
              ListTile(
                key: const Key('kokoro-download'),
                leading: Icon(
                  _kokoro.ready ? Icons.offline_pin : Icons.download_for_offline_outlined,
                  color: _kokoro.ready ? t.colorScheme.primary : null,
                ),
                title: Text(
                  _kokoro.ready
                      ? 'Kokoro voice ready'
                      : _kokoro.unpacking
                      ? 'Unpacking…'
                      : _kokoro.progress != null
                      ? 'Downloading… ${(_kokoro.progress! * 100).round()}%'
                      : 'Download Kokoro voice',
                ),
                subtitle: _kokoro.busy
                    ? Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: LinearProgressIndicator(value: _kokoro.unpacking ? null : _kokoro.progress),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _kokoro.ready
                                ? 'Runs on this phone, offline. English only; Arabic uses the phone\'s voice.'
                                : "${KokoroModel.sizeMb} MB, downloaded once. Until then the phone's voice is used.",
                          ),
                          const SizedBox(height: 6),
                          _kokoro.ready
                              ? TextButton(onPressed: _kokoro.delete, child: const Text('Delete voice'))
                              : FilledButton.tonal(
                                  style: compactButton,
                                  onPressed: () => _kokoro.download(),
                                  child: const Text('Download'),
                                ),
                        ],
                      ),
              ),
              if (_kokoro.error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(_kokoro.error!, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error)),
                ),
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: const Text('Voice'),
                subtitle: _dropdown(
                  const Key('kokoro-voice'),
                  s.kokoroVoice,
                  kokoroVoices,
                  (v) => state.updateSettings((x) => x.kokoroVoice = v),
                ),
              ),
            ],
            if (engine == 'openai' || engine == 'grok') ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: _KeyField(
                  key: ValueKey('tts-key-$engine'),
                  label: engine == 'openai' ? 'OpenAI API key' : 'xAI API key',
                  value: engine == 'openai' ? state.openaiKey : state.xaiKey,
                  onSave: (k) => state.setVoiceKey(engine, k),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: const Text('Voice'),
                subtitle: engine == 'openai'
                    ? _dropdown(
                        const Key('openai-voice'),
                        s.openaiVoice,
                        {for (final v in openAiVoices) v: v[0].toUpperCase() + v.substring(1)},
                        (v) => state.updateSettings((x) => x.openaiVoice = v),
                      )
                    : _dropdown(
                        const Key('grok-voice'),
                        s.grokVoice,
                        {for (final v in grokVoices) v: v[0].toUpperCase() + v.substring(1)},
                        (v) => state.updateSettings((x) => x.grokVoice = v),
                      ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  engine == 'openai'
                      ? 'Uses $openAiTtsModel, billed to your OpenAI account per reply read aloud. '
                            "Without a key or internet the phone's voice is used."
                      : "Billed to your xAI account. Speaks Arabic too. Without a key or internet the phone's voice is used.",
                  style: muted,
                ),
              ),
            ],
            if (lastTtsError.value != null && engine != 'system')
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  "${lastTtsError.value}. The phone's voice was used instead.",
                  key: const Key('tts-error'),
                  style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  key: const Key('tts-sample'),
                  style: compactButton,
                  onPressed: _sample,
                  icon: Icon(_playing ? Icons.stop : Icons.play_arrow),
                  label: Text(_playing ? 'Stop' : 'Play sample'),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _KeyField extends StatefulWidget {
  final String label;
  final String value;
  final Future<void> Function(String key) onSave;
  const _KeyField({super.key, required this.label, required this.value, required this.onSave});

  @override
  State<_KeyField> createState() => _KeyFieldState();
}

class _KeyFieldState extends State<_KeyField> {
  late final _ctl = TextEditingController(text: widget.value);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await widget.onSave(_ctl.text);
    if (!mounted) return;
    FocusScope.of(context).unfocus();
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(_ctl.text.trim().isEmpty ? 'Key removed.' : 'Key saved on this phone.')),
    );
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _ctl,
    obscureText: true,
    autocorrect: false,
    enableSuggestions: false,
    onSubmitted: (_) => _save(),
    decoration: InputDecoration(
      labelText: widget.label,
      helperText: widget.value.isEmpty ? 'Stored only on this phone, never in backups' : 'Saved',
      suffixIcon: IconButton(tooltip: 'Save key', icon: const Icon(Icons.check), onPressed: _save),
    ),
  );
}
