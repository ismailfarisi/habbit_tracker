import 'package:flutter/material.dart';

import '../app_state.dart';
import '../services/voice_input.dart';

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
