import 'package:flutter/material.dart';

import '../agent/habit_catalog.dart';
import '../agent/habit_screen_layout.dart';
import '../agent/habit_surface.dart';
import '../app_state.dart';
import '../habits/habit.dart';

/// Changes the screen on this habit. Preview and cancel operate on a local draft.
class HabitScreenEditor extends StatefulWidget {
  final AppState state;
  final HabitDef habit;
  final DateTime day;
  const HabitScreenEditor({super.key, required this.state, required this.habit, required this.day});

  @override
  State<HabitScreenEditor> createState() => _HabitScreenEditorState();
}

class _HabitScreenEditorState extends State<HabitScreenEditor> {
  final _form = GlobalKey<FormState>();
  late final _draft = widget.habit.copy();
  Map<String, dynamic>? _normalized;
  int _formVersion = 0;
  bool _saving = false;

  List<Map<String, dynamic>> get _components =>
      ((_normalized?['createSurface']?['components'] as List?) ?? []).cast<Map<String, dynamic>>();

  @override
  void initState() {
    super.initState();
    _readSurface();
  }

  void _readSurface() {
    try {
      _normalized = editableHabitSurface(_draft);
    } on HabitSurfaceError {
      _normalized = null;
    }
  }

  void _restore() {
    setState(() {
      _draft.applyScreen(widget.habit.previousScreen!);
      _readSurface();
      _formVersion++;
    });
  }

  void _preview() {
    if (!_form.currentState!.validate()) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Screen preview')),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text('Try this screen. Preview entries stay here.'),
                const SizedBox(height: 12),
                HabitSurface(widget.state, _draft, widget.day, persist: false),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    final current = widget.state.habitById(widget.habit.id);
    if (current == null) return;
    setState(() => _saving = true);
    try {
      await widget.state.upsertHabit(current.copy()..applyScreen(_draft.screenVersion));
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  static List<String> _lines(String text) => text.split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();

  Widget _field(Map<String, dynamic> node, String key, String label, {bool lines = false}) {
    final raw = node[key];
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: TextFormField(
        initialValue: raw is List ? raw.whereType<String>().join('\n') : raw?.toString() ?? '',
        decoration: InputDecoration(labelText: label, helperText: lines ? 'One per line' : null),
        minLines: 1,
        maxLines: lines || key == 'text' || key == 'body' ? 6 : 1,
        validator: (v) => key == 'text' && (v ?? '').trim().isEmpty ? 'Enter a passage to read.' : null,
        onChanged: (v) {
          node[key] = lines ? _lines(v) : v.trim();
          _draft.uiSurface = _normalized;
        },
      ),
    );
  }

  void _setTarget(String text) {
    final n = num.tryParse(text.trim());
    if (n == null || !n.isFinite || n <= 0) return;
    for (final c in _components) {
      final key = switch (c['component']) {
        'Counter' => 'target',
        'PracticeTimer' => 'targetMinutes',
        _ => null,
      };
      if (key != null && c[key] is num && c[key] == _draft.target) {
        c[key] = {'@path': '/habit/target'};
        _draft.uiSurface = _normalized;
      }
    }
    _draft.target = n;
  }

  @override
  Widget build(BuildContext context) {
    final plain = _draft.usePlainTracker || _normalized == null;
    final timed = _draft.kind == HabitKind.practice || _draft.kind == HabitKind.duration;
    final hasSteps = _components.any((n) => n['component'] == 'PromptCard' || n['component'] == 'SpeakingPractice');
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit habit screen'),
        actions: [TextButton(onPressed: _saving ? null : _save, child: const Text('Save'))],
      ),
      body: SafeArea(
        child: Form(
          key: _form,
          child: ListView(
            key: ValueKey(_formVersion),
            padding: const EdgeInsets.all(16),
            children: [
              Text(_draft.title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 16),
              SegmentedButton<bool>(
                segments: [
                  ButtonSegment(value: false, label: const Text('Generated screen'), enabled: _normalized != null),
                  const ButtonSegment(value: true, label: Text('Plain tracker')),
                ],
                selected: {plain},
                onSelectionChanged: (s) => setState(() => _draft.usePlainTracker = s.single),
              ),
              if (timed || _draft.kind == HabitKind.count)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: TextFormField(
                    initialValue: _draft.target.toString(),
                    decoration: InputDecoration(labelText: 'Daily target', suffixText: timed ? 'min' : _draft.unit),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: _setTarget,
                    validator: (v) {
                      final n = num.tryParse((v ?? '').trim());
                      return n == null || !n.isFinite || n <= 0 ? 'Enter a target greater than zero.' : null;
                    },
                  ),
                ),
              if (!plain)
                for (final node in _components) ...[
                  if (node['component'] == 'HabitCheck' && node['label'] is String)
                    _field(node, 'label', 'Completion target'),
                  if (node['component'] == 'PromptCard' || node['component'] == 'SpeakingPractice') ...[
                    if (node['body'] is String) _field(node, 'body', 'Instructions'),
                    _field(node, 'steps', 'Practice steps', lines: true),
                  ],
                  if (node['component'] == 'ReadAloudDrill' || node['component'] == 'SpeakingPractice') ...[
                    if (node['text'] is String) _field(node, 'text', 'Reading passage'),
                    _field(node, 'targetWords', 'Target words', lines: true),
                  ],
                ],
              if (plain || !hasSteps || _draft.screenSteps.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: TextFormField(
                    key: const ValueKey('additional-steps'),
                    initialValue: _draft.screenSteps.join('\n'),
                    decoration: const InputDecoration(labelText: 'Tracker steps', helperText: 'One per line'),
                    minLines: 1,
                    maxLines: 6,
                    onChanged: (v) => _draft.screenSteps = _lines(v),
                  ),
                ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: _preview,
                icon: const Icon(Icons.visibility_outlined),
                label: const Text('Preview screen'),
              ),
              if (widget.habit.previousScreen != null)
                TextButton.icon(
                  onPressed: _restore,
                  icon: const Icon(Icons.restore),
                  label: const Text('Restore previous version'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
