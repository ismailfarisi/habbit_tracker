import 'package:flutter/material.dart';

import '../services/portable_backup.dart';
import '../services/storage.dart';

/// Captures one export so the manifest describes exactly what is shared.
Future<String?> previewPortableBackup(BuildContext context, Storage storage, {required bool copy}) {
  final raw = storage.exportJson();
  final manifest = Storage.describeBackup(raw).manifest();
  return showDialog<String>(
    context: context,
    builder: (_) => _TransferDialog(raw: raw, storage: storage, manifest: manifest, copy: copy),
  );
}

Future<String?> unlockPortableBackup(BuildContext context, String raw) => showDialog<String>(
  context: context,
  builder: (_) => _TransferDialog(raw: raw),
);

class _TransferDialog extends StatefulWidget {
  final String raw;
  final Storage? storage;
  final String? manifest;
  final bool copy;
  const _TransferDialog({required this.raw, this.storage, this.manifest, this.copy = false});

  @override
  State<_TransferDialog> createState() => _TransferDialogState();
}

class _TransferDialogState extends State<_TransferDialog> {
  final _password = TextEditingController();
  final _repeat = TextEditingController();
  bool _encrypted = true, _chat = false, _working = false;
  String? _error;
  bool get _exporting => widget.storage != null;
  late String _selected = widget.raw;
  late String? _manifest = widget.manifest;

  void _includeChats(bool include) {
    try {
      final raw = include ? widget.storage!.exportJson(includeChat: true) : widget.raw;
      final manifest = include ? Storage.describeBackup(raw).manifest() : widget.manifest;
      setState(() {
        _selected = raw;
        _manifest = manifest;
        _chat = include;
        _error = null;
      });
    } catch (_) {
      setState(() => _error = 'Could not include chats. You can still export the other data.');
    }
  }

  @override
  void dispose() {
    _password.dispose();
    _repeat.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final password = _password.text;
    if (_exporting && _encrypted) {
      if (password.trim().length < 10) {
        setState(() => _error = 'Use a password of at least 10 characters.');
        return;
      }
      if (password != _repeat.text) {
        setState(() => _error = 'Enter the same password in both fields.');
        return;
      }
    }
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final String result;
      if (!_exporting) {
        result = await PortableBackup.decrypt(widget.raw, password);
      } else {
        result = _encrypted ? await PortableBackup.encrypt(_selected, password) : _selected;
      }
      if (mounted) Navigator.pop(context, result);
    } catch (e) {
      if (mounted) {
        setState(() {
          _working = false;
          _error = e is FormatException ? e.message : 'Could not process this backup. Try again.';
        });
      }
    }
  }

  Widget _field(String label, TextEditingController controller) => TextField(
    controller: controller,
    enabled: !_working,
    obscureText: true,
    autocorrect: false,
    enableSuggestions: false,
    decoration: InputDecoration(labelText: label),
  );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: Text(_exporting ? 'Preview portable backup' : 'Unlock backup'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_exporting) ...[
            Text(_manifest!),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Include chat history'),
              value: _chat,
              onChanged: _working ? null : _includeChats,
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Password protection'),
              value: _encrypted,
              onChanged: _working
                  ? null
                  : (v) => setState(() {
                      _encrypted = v;
                      _error = null;
                    }),
            ),
            Text(
              _encrypted
                  ? 'Keep the password somewhere safe. You’ll need it to restore this backup.'
                  : 'Anyone who receives this JSON can read your data, including Money.',
            ),
          ] else
            const Text('Enter the backup password to preview its contents.'),
          if (_encrypted) ...[
            const SizedBox(height: 12),
            _field('Backup password', _password),
            if (_exporting) ...[const SizedBox(height: 8), _field('Confirm password', _repeat)],
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Semantics(
                liveRegion: true,
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            ),
          if (_working)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(semanticsLabel: 'Processing backup'),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _working ? null : _submit,
          child: Text(
            !_exporting
                ? 'Unlock'
                : widget.copy
                ? 'Copy'
                : 'Share',
          ),
        ),
      ],
    );
  }
}
