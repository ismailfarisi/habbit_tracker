import 'package:flutter/material.dart';

/// The titled card every Today section is drawn in.
class SectionCard extends StatelessWidget {
  final String title;

  /// Shown in a tinted tile before the title.
  final String? emoji;
  final Widget? trailing;
  final VoidCallback? onTitleTap;
  final List<Widget> children;
  const SectionCard({
    super.key,
    required this.title,
    this.emoji,
    this.trailing,
    this.onTitleTap,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final heading = Row(children: [
      if (emoji != null) ...[
        Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: t.colorScheme.primaryContainer.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(emoji!, style: const TextStyle(fontSize: 20)),
        ),
        const SizedBox(width: 12),
      ],
      Flexible(child: Text(title, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
    ]);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(child: onTitleTap == null ? heading : InkWell(onTap: onTitleTap, child: heading)),
              ?trailing,
            ]),
            const SizedBox(height: 14),
            ...children,
          ],
        ),
      ),
    );
  }
}
