import 'package:flutter/material.dart';

/// The titled card every Today section is drawn in.
class SectionCard extends StatelessWidget {
  final String title;

  /// Shown in a tinted tile before the title.
  final String? emoji;

  /// Drawn icon for app sections; used instead of [emoji] when set.
  final IconData? icon;
  final Widget? trailing;
  final VoidCallback? onTitleTap;
  final List<Widget> children;
  const SectionCard({
    super.key,
    required this.title,
    this.emoji,
    this.icon,
    this.trailing,
    this.onTitleTap,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final heading = Row(children: [
      if (emoji != null || icon != null) ...[
        Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: t.colorScheme.primaryContainer.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(12),
          ),
          child: icon != null
              ? Icon(icon, size: 20, color: t.colorScheme.onPrimaryContainer)
              : Text(emoji!, style: const TextStyle(fontSize: 18)),
        ),
        const SizedBox(width: 12),
      ],
      Flexible(child: Text(title, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
    ]);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(child: onTitleTap == null ? heading : InkWell(onTap: onTitleTap, child: heading)),
              ?trailing,
            ]),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}
