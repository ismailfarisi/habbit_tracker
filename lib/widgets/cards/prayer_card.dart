import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../app_state.dart';
import '../../habits/habit.dart';
import '../../logic/prayer_status.dart';
import '../../logic/stats.dart';
import '../../models.dart';
import '../../services/prayer_service.dart';
import 'section_card.dart';
import '../adaptive.dart';

/// Today's five prayers with their times and status (on time / late /
/// qada). Tap marks a prayer (status from [autoPrayerStatus]) or un-marks
/// it; long-press chooses the status. Shows Jumu'ah on Fridays, Ramadan
/// suhoor/iftar times and the optional sunnah prayers enabled in Settings.
class PrayerCard extends StatelessWidget {
  final AppState state;
  final DayLog log;
  final DateTime now;
  const PrayerCard({super.key, required this.state, required this.log, required this.now});

  Future<void> _tap(BuildContext context, String name) async {
    if (!log.prayers.contains(name)) {
      final start = prayerTimesFor(state.settings, now).times[name]!;
      if (now.isBefore(start)) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text("${prayerLabel(name, now)} starts at ${DateFormat.jm().format(start)}. "
                'Long-press to set a status by hand.'),
          ));
        return;
      }
    }
    await state.setPrayerStatus(
      now,
      name,
      log.prayers.contains(name) ? null : autoPrayerStatus(state.settings, now, name, now),
    );
  }

  Future<void> _choose(BuildContext context, String name) async {
    final current = prayerStatusOf(log, name);
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(prayerLabel(name, now), style: Theme.of(c).textTheme.titleMedium)),
          for (final st in prayerStatuses)
            ListTile(
              leading: Icon(_icon(st), color: _color(c, st)),
              title: Text(prayerStatusLabels[st]!),
              subtitle: Text(_explain(st)),
              selected: current == st,
              onTap: () => Navigator.pop(c, st),
            ),
          ListTile(
            leading: const Icon(Icons.radio_button_unchecked),
            title: const Text('Not prayed'),
            selected: current == null,
            onTap: () => Navigator.pop(c, ''),
          ),
        ]),
      ),
    );
    if (picked == null) return;
    await state.setPrayerStatus(now, name, picked.isEmpty ? null : picked);
  }

  @override
  Widget build(BuildContext context) {
    final s = state.settings;
    final day = prayerTimesFor(s, now);
    final next = nextPrayer(s, now);
    final mins = next.value.difference(now).inMinutes;
    final inText = mins >= 60 ? '${mins ~/ 60} h ${mins % 60} min' : '$mins min';
    final done = prayerNames.where(log.prayers.contains).length;
    final onTime = prayerNames.where((p) => prayerStatusOf(log, p) == prayerOnTime).length;
    final ramadan = isRamadan(s, now);
    final hijri = hijriToday(s, now);
    final optional = optionalPrayersOn(s, now);
    final c = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.bodySmall?.copyWith(color: c.onSurfaceVariant);
    String hm(DateTime t) => DateFormat.jm().format(t);
    return SectionCard(
      icon: Icons.mosque_outlined,
      title: 'Five daily prayers',
      trailing: CountBadge(done > 0 && onTime < done ? '$done/5 · $onTime on time' : '$done/5'),
      children: [
        Text('Next: ${prayerLabel(next.key, next.value)} in $inText', style: TextStyle(color: c.onSurfaceVariant)),
        if (ramadan)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '🌙 ${hijri.isRamadan ? 'Ramadan ${hijri.day}' : 'Ramadan'} · '
              'Suhoor ends ${hm(day.times['Fajr']!)} · Iftar ${hm(day.times['Maghrib']!)}',
              key: const ValueKey('ramadan-line'),
              style: TextStyle(color: c.primary, fontWeight: FontWeight.w600),
            ),
          ),
        for (final p in prayerNames) ...[
          _PrayerRow(
            name: p,
            label: prayerLabel(p, now),
            time: hm(day.times[p]!),
            status: prayerStatusOf(log, p),
            isNext: next.key == p && dateOnly(next.value) == dateOnly(now),
            tag: ramadan && p == 'Maghrib'
                ? 'Iftar'
                : ramadan && p == 'Fajr'
                    ? 'Suhoor ends'
                    : null,
            onTap: () => _tap(context, p),
            onLongPress: () => _choose(context, p),
          ),
          for (final o in optional)
            if (o.after == p)
              CheckboxListTile.adaptive(
                key: ValueKey(o.id),
                contentPadding: const EdgeInsets.only(left: 8),
                dense: true,
                value: state.habitEntry(now, o.id).done,
                onChanged: (v) => state.logHabit(now, o.id, HabitEntry(done: v ?? false)),
                title: Text(o.name),
                subtitle: Text('Optional · ${o.hint}'),
                secondary: o == sunnahDuha && day.sunrise != null
                    ? Text('from ${hm(day.sunrise!.add(const Duration(minutes: 15)))}', style: small)
                    : null,
              ),
        ],
        Text(
          day.calculated
              ? 'Calculated for ${s.locationName.isEmpty ? 'your location' : s.locationName} · ${calcMethodLabels[s.calcMethod]}'
              : 'Using manual times',
          style: small,
        ),
        Text('Tap to mark · long-press for on time, late or qada', style: small),
      ],
    );
  }
}

IconData _icon(String? status) => switch (status) {
      prayerOnTime => Icons.check_circle,
      prayerLate => Icons.schedule,
      prayerQada => Icons.history,
      _ => Icons.radio_button_unchecked,
    };

Color _color(BuildContext context, String? status) {
  final c = Theme.of(context).colorScheme;
  return switch (status) {
    prayerOnTime => Colors.green.shade600,
    prayerLate => Colors.orange.shade700,
    prayerQada => c.error,
    _ => c.outline,
  };
}

String _explain(String status) => switch (status) {
      prayerOnTime => 'Prayed within its time',
      prayerLate => 'Prayed after its time ended, same day',
      _ => 'Made up later',
    };

class _PrayerRow extends StatelessWidget {
  final String name;
  final String label;
  final String time;
  final String? status;
  final bool isNext;
  final String? tag;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  const _PrayerRow({
    required this.name,
    required this.label,
    required this.time,
    required this.status,
    required this.isNext,
    required this.tag,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final sub = [if (status != null) prayerStatusLabels[status]!, ?tag].join(' · ');
    return ListTile(
      key: ValueKey('prayer-$name'),
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(_icon(status), color: _color(context, status), semanticLabel: status ?? 'not prayed'),
      title: Text(label, style: TextStyle(fontWeight: isNext ? FontWeight.bold : FontWeight.normal)),
      subtitle: sub.isEmpty ? null : Text(sub, style: TextStyle(color: status == null ? c.onSurfaceVariant : _color(context, status))),
      trailing: Text(time, style: TextStyle(color: c.onSurfaceVariant)),
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}
