import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Splits a leading YAML frontmatter block (`---` … `---`) from Markdown.
(Map<String, String>, String) splitFrontmatter(String text) {
  final m = RegExp(r'^\uFEFF?---\r?\n([\s\S]*?)\r?\n---\r?\n?').firstMatch(text);
  if (m == null) return (const {}, text);
  final fields = <String, String>{};
  for (final line in m.group(1)!.split(RegExp(r'\r?\n'))) {
    final i = line.indexOf(':');
    if (i <= 0 || line.startsWith(' ')) continue;
    var v = line.substring(i + 1).trim();
    if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) v = v.substring(1, v.length - 1).replaceAll(r'\"', '"');
    fields[line.substring(0, i).trim()] = v;
  }
  return (fields, text.substring(m.end));
}

bool looksLikeHtml(String name, String text) =>
    RegExp(r'\.html?$', caseSensitive: false).hasMatch(name) ||
    RegExp(r'^\s*(<!doctype html|<html)', caseSensitive: false).hasMatch(text);

/// Reads Markdown (with OKF/YAML frontmatter shown as a header) or HTML.
/// HTML is drawn as Flutter widgets, so scripts never run.
class DocumentViewer extends StatefulWidget {
  final String title;
  final String text;
  final String fileName;
  const DocumentViewer({super.key, required this.title, required this.text, required this.fileName});

  static Route<void> route({required String title, required String markdown, required String fileName}) =>
      MaterialPageRoute<void>(builder: (_) => DocumentViewer(title: title, text: markdown, fileName: fileName));

  /// Lets the user pick a `.md` or `.html` file and opens it.
  static Future<void> pickAndOpen(BuildContext context) async {
    final f = await FilePicker.pickFile(dialogTitle: 'Open a Markdown or HTML file');
    if (f == null || !context.mounted) return;
    final bytes = await f.xFile.readAsBytes();
    if (!context.mounted) return;
    final text = utf8.decode(bytes, allowMalformed: true);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => DocumentViewer(title: f.xFile.name, text: text, fileName: f.xFile.name)),
    );
  }

  @override
  State<DocumentViewer> createState() => _DocumentViewerState();
}

class _DocumentViewerState extends State<DocumentViewer> {
  bool _source = false;

  Future<void> _share() async {
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/${widget.fileName}');
    await f.writeAsString(widget.text);
    await SharePlus.instance.share(ShareParams(files: [XFile(f.path)], subject: widget.title));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final html = looksLikeHtml(widget.fileName, widget.text);
    final (front, body) = html ? (const <String, String>{}, widget.text) : splitFrontmatter(widget.text);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            key: const Key('doc-source'),
            tooltip: _source ? 'Show formatted' : 'Show source',
            icon: Icon(_source ? Icons.article_outlined : Icons.code),
            onPressed: () => setState(() => _source = !_source),
          ),
          IconButton(key: const Key('doc-share'), tooltip: 'Share file', icon: const Icon(Icons.ios_share), onPressed: _share),
        ],
      ),
      body: _source
          ? SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: SelectableText(widget.text, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                if (front.isNotEmpty)
                  Container(
                    key: const Key('doc-frontmatter'),
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: t.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final e in front.entries)
                          Chip(
                            visualDensity: VisualDensity.compact,
                            label: Text('${e.key}: ${e.value}', style: t.textTheme.labelSmall),
                          ),
                      ],
                    ),
                  ),
                if (html) HtmlWidget(body, key: const Key('doc-html')) else MarkdownBody(
                    key: const Key('doc-md'),
                    data: body,
                    selectable: true,
                    checkboxBuilder: (v) => Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Icon(
                        v ? Icons.check_box : Icons.check_box_outline_blank,
                        size: 18,
                        color: v ? t.colorScheme.primary : t.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
