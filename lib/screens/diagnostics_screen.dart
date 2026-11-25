import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../services/diagnostics.dart';
import '../widgets/adaptive.dart';

/// Explains what opt-in diagnostics collect.
const diagnosticsExplanation =
    'Off by default. When on, this phone keeps counts of reminders scheduled, notification taps and '
    'notification actions, plus the last ${Diagnostics.maxErrors} app errors. Nothing is sent anywhere: '
    'it only leaves your phone if you tap "Share report". Reports never include your habits, prayers or tasks.';

/// Settings › Diagnostics: the opt-in switch, local counters, the error log
/// and a "Share report" button.
class DiagnosticsScreen extends StatefulWidget {
  final Diagnostics diagnostics;

  /// Shares the report text; defaults to the system share sheet.
  final Future<void> Function(String report)? onShare;

  const DiagnosticsScreen({super.key, required this.diagnostics, this.onShare});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  Diagnostics get d => widget.diagnostics;

  @override
  void initState() {
    super.initState();
    d.reload().then((_) {
      if (mounted) setState(() {});
    });
  }

  String _when(DateTime t) => DateFormat.yMMMd().add_jm().format(t);

  Future<void> _share() async {
    bool count = true;
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, update) {
        final preview = d.report(includeErrorCount: count);
        return AlertDialog(
          scrollable: true,
          title: const Text('Review diagnostics'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Only the text below will be shared. Error messages and stack traces stay on this phone.'),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Include error count'),
              value: count,
              onChanged: (v) => update(() => count = v == true),
            ),
            SelectableText(preview),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, preview), child: const Text('Share this report')),
          ],
        );
      }),
    );
    if (text == null) return;
    if (widget.onShare != null) return widget.onShare!(text);
    await SharePlus.instance.share(ShareParams(text: text, subject: 'Daily Discipline diagnostics'));
  }

  Future<void> _clear() async {
    await d.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final errors = d.errors.reversed.toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Diagnostics')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          SwitchListTile.adaptive(
            title: const Text('Collect diagnostics on this phone'),
            subtitle: const Text(diagnosticsExplanation),
            isThreeLine: true,
            value: d.enabled,
            onChanged: (v) async {
              await d.setEnabled(v);
              setState(() {});
            },
          ),
          if (!d.enabled)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Diagnostics are off. Nothing is being recorded.'),
            )
          else ...[
            ListTile(
              dense: true,
              title: Text('Collecting since ${d.since == null ? '-' : _when(d.since!)}'),
            ),
            _header(context, 'Counters'),
            for (final e in d.counters.entries)
              ListTile(
                dense: true,
                title: Text(Diagnostics.counterLabels[e.key] ?? e.key),
                trailing: Text('${e.value}', style: theme.textTheme.titleMedium),
              ),
            _header(context, 'Errors (${errors.length} of last ${Diagnostics.maxErrors})'),
            if (errors.isEmpty)
              const ListTile(dense: true, title: Text('No errors recorded.'))
            else
              for (final e in errors)
                ExpansionTile(
                  title: Text(e.message, maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${_when(e.at)} · ${e.source}'),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  expandedAlignment: Alignment.centerLeft,
                  children: [
                    SelectableText(
                      e.stack.isEmpty ? e.message : '${e.message}\n\n${e.stack}',
                      style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                    ),
                  ],
                ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                FilledButton.icon(style: compactButton, onPressed: _share, icon: const Icon(Icons.share_outlined), label: const Text('Share report')),
                OutlinedButton(style: compactButton, onPressed: _clear, child: const Text('Clear')),
              ]),
            ),
          ],
        ],
      ),
    );
  }

  Widget _header(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(text,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );
}
