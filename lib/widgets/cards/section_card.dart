import 'package:flutter/material.dart';

/// The titled card every Today section is drawn in.
class SectionCard extends StatelessWidget {
  final String title;
  final Widget? trailing;
  final VoidCallback? onTitleTap;
  final List<Widget> children;
  const SectionCard({super.key, required this.title, this.trailing, this.onTitleTap, required this.children});

  @override
  Widget build(BuildContext context) {
    final heading = Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600));
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
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }
}
