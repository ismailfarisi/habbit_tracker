import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// True when the app should follow iOS conventions (Cupertino controls,
/// tab bar, alerts); Material is used everywhere else.
bool isCupertino(BuildContext context) {
  final p = Theme.of(context).platform;
  return p == TargetPlatform.iOS || p == TargetPlatform.macOS;
}

/// Small action inside a card row or list item: 34 high visually, while
/// the padded tap target keeps 48dp (Android) / 44pt (iOS) for the finger.
const compactButton = ButtonStyle(
  minimumSize: WidgetStatePropertyAll(Size(0, 34)),
  padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
  iconSize: WidgetStatePropertyAll(16),
  shape: WidgetStatePropertyAll(StadiumBorder()),
);

/// Prominent full-width call to action (onboarding, wake challenge).
const primaryButton = ButtonStyle(minimumSize: WidgetStatePropertyAll(Size.fromHeight(50)));

/// Quiet pill for counts and times in a card header ("0/5", "5:00 AM").
class CountBadge extends StatelessWidget {
  final String text;
  const CountBadge(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(999)),
      child: Text(
        text,
        style: t.textTheme.labelMedium?.copyWith(
          color: t.colorScheme.onSurfaceVariant,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// A yes/no confirmation that is a Material dialog on Android and a
/// Cupertino alert on iOS. Returns true when [confirm] was chosen.
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirm,
  bool destructive = false,
}) async {
  final ok = await showAdaptiveDialog<bool>(
    context: context,
    builder: (c) => AlertDialog.adaptive(
      title: Text(title),
      content: Text(message),
      actions: isCupertino(c)
          ? [
              CupertinoDialogAction(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
              CupertinoDialogAction(
                isDefaultAction: !destructive,
                isDestructiveAction: destructive,
                onPressed: () => Navigator.pop(c, true),
                child: Text(confirm),
              ),
            ]
          : [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
              FilledButton(
                style: destructive
                    ? FilledButton.styleFrom(
                        backgroundColor: Theme.of(c).colorScheme.error,
                        foregroundColor: Theme.of(c).colorScheme.onError,
                      )
                    : null,
                onPressed: () => Navigator.pop(c, true),
                child: Text(confirm),
              ),
            ],
    ),
  );
  return ok == true;
}
