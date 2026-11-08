import 'package:flutter/material.dart';

/// Renders the small subset of Markdown that chat models usually emit:
/// headings, bullet/numbered lists and **bold** / *italic* text.
class SimpleMarkdown extends StatelessWidget {
  final String text;
  final TextStyle? style;
  const SimpleMarkdown(this.text, {super.key, this.style});

  @override
  Widget build(BuildContext context) {
    final base = style ?? DefaultTextStyle.of(context).style;
    final lines = text.trim().split('\n');
    final children = <Widget>[];
    for (final raw in lines) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) {
        children.add(const SizedBox(height: 6));
        continue;
      }
      final heading = RegExp(r'^#{1,6}\s+(.*)$').firstMatch(line);
      final bullet = RegExp(r'^\s*[-*•]\s+(.*)$').firstMatch(line);
      final numbered = RegExp(r'^\s*(\d+[.)])\s+(.*)$').firstMatch(line);
      if (heading != null) {
        children.add(Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 2),
          child: Text.rich(_inline(heading.group(1)!, base.copyWith(fontWeight: FontWeight.bold))),
        ));
      } else if (bullet != null || numbered != null) {
        final marker = bullet != null ? '•' : numbered!.group(1)!;
        final body = bullet != null ? bullet.group(1)! : numbered!.group(2)!;
        children.add(Padding(
          padding: const EdgeInsets.only(left: 4, top: 2, bottom: 2),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 22, child: Text(marker, style: base)),
            Expanded(child: Text.rich(_inline(body, base))),
          ]),
        ));
      } else {
        children.add(Text.rich(_inline(line, base)));
      }
    }
    return SelectionArea(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );
  }

  TextSpan _inline(String s, TextStyle base) {
    final spans = <TextSpan>[];
    final re = RegExp(r'\*\*(.+?)\*\*|__(.+?)__|\*(.+?)\*|`(.+?)`');
    var last = 0;
    for (final m in re.allMatches(s)) {
      if (m.start > last) spans.add(TextSpan(text: s.substring(last, m.start)));
      if (m.group(1) != null || m.group(2) != null) {
        spans.add(TextSpan(text: m.group(1) ?? m.group(2), style: const TextStyle(fontWeight: FontWeight.bold)));
      } else if (m.group(3) != null) {
        spans.add(TextSpan(text: m.group(3), style: const TextStyle(fontStyle: FontStyle.italic)));
      } else {
        spans.add(TextSpan(text: m.group(4), style: const TextStyle(fontFamily: 'monospace')));
      }
      last = m.end;
    }
    if (last < s.length) spans.add(TextSpan(text: s.substring(last)));
    return TextSpan(style: base, children: spans);
  }
}
