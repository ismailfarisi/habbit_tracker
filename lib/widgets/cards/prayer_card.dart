import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../app_state.dart';
import '../../models.dart';
import '../../services/prayer_service.dart';
import 'section_card.dart';

/// Today's five prayers with their times and tick boxes.
class PrayerCard extends StatelessWidget {
  final AppState state;
  final DayLog log;
  final DateTime now;
  const PrayerCard({super.key, required this.state, required this.log, required this.now});

  @override
  Widget build(BuildContext context) {
    final s = state.settings;
    final day = prayerTimesFor(s, now);
    final next = nextPrayer(s, now);
    final mins = next.value.difference(now).inMinutes;
    final inText = mins >= 60 ? '${mins ~/ 60} h ${mins % 60} min' : '$mins min';
    final done = prayerNames.where(log.prayers.contains).length;
    final c = Theme.of(context).colorScheme;
    return SectionCard(
      title: '🕌  Five daily prayers',
      trailing: Chip(label: Text('$done/5'), visualDensity: VisualDensity.compact),
      children: [
        Text('Next: ${next.key} in $inText', style: TextStyle(color: c.onSurfaceVariant)),
        for (final p in prayerNames)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: log.prayers.contains(p),
            onChanged: (v) => state.setPrayer(now, p, v ?? false),
            title: Text(p, style: TextStyle(fontWeight: next.key == p ? FontWeight.bold : FontWeight.normal)),
            secondary: Text(DateFormat.jm().format(day.times[p]!), style: TextStyle(color: c.onSurfaceVariant)),
          ),
        Text(
          day.calculated
              ? 'Calculated for ${s.locationName.isEmpty ? 'your location' : s.locationName} · ${calcMethodLabels[s.calcMethod]}'
              : 'Using manual times',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: c.onSurfaceVariant),
        ),
      ],
    );
  }
}
