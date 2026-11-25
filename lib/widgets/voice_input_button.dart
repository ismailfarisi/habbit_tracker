import 'package:flutter/material.dart';

import '../services/voice_input.dart';

/// A mic button that dictates into [controller], appending to what's
/// already typed. Tap again to stop; [onFinished] gets the final text.
class VoiceInputButton extends StatefulWidget {
  final TextEditingController controller;
  final void Function(String text)? onFinished;

  /// Start listening as soon as the button appears.
  final bool autoStart;

  const VoiceInputButton({super.key, required this.controller, this.onFinished, this.autoStart = false});

  @override
  State<VoiceInputButton> createState() => _VoiceInputButtonState();
}

class _VoiceInputButtonState extends State<VoiceInputButton> {
  Dictation? _dictation;
  bool _listening = false;
  bool _starting = false;
  String _base = '';

  @override
  void initState() {
    super.initState();
    if (widget.autoStart) WidgetsBinding.instance.addPostFrameCallback((_) => _toggle());
  }

  @override
  void dispose() {
    _dictation?.dispose();
    super.dispose();
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _toggle() async {
    if (_starting) return;
    if (_listening) {
      await _dictation?.stop();
      return;
    }
    _starting = true;
    _base = widget.controller.text.trimRight();
    setState(() => _listening = true);
    _dictation?.dispose();
    try {
      final d = _dictation = await dictationFactory();
      if (!mounted) {
        d.dispose();
        return;
      }
      await d.start(
        locale: voiceSettings().speechLocale,
        onText: _insert,
        onError: _snack,
        onDone: () {
          if (!mounted) return;
          setState(() => _listening = false);
          widget.onFinished?.call(widget.controller.text);
        },
      );
    } catch (e) {
      _snack('Voice input failed: $e');
      if (mounted) setState(() => _listening = false);
    } finally {
      _starting = false;
    }
  }

  void _insert(String words) {
    if (!mounted) return;
    final t = words.trim();
    final text = _base.isEmpty ? t : (t.isEmpty ? _base : '$_base $t');
    widget.controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: _listening ? 'Stop dictation' : 'Speak',
      onPressed: _toggle,
      icon: _listening ? Icon(Icons.stop_circle, color: c.error) : const Icon(Icons.mic_none_outlined),
    );
  }
}
