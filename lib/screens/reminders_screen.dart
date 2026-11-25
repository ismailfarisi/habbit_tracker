import 'dart:async';

import 'package:app_settings/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../logic/stats.dart';
import '../services/notification_service.dart';
import '../services/reminders.dart';
import '../widgets/adaptive.dart';

/// Upcoming alerts reported pending by the notification service.
class RemindersScreen extends StatefulWidget {
  final AppState state;
  final DateTime? now;
  const RemindersScreen({super.key, required this.state, this.now});

  static IconData iconFor(ReminderKind k) => switch (k) {
        ReminderKind.wake => Icons.alarm,
        ReminderKind.prayer => Icons.mosque_outlined,
        ReminderKind.habit => Icons.repeat,
        ReminderKind.task => Icons.task_alt,
        ReminderKind.bedtime => Icons.bedtime_outlined,
      };

  @override
  State<RemindersScreen> createState() => _RemindersScreenState();
}

class _RemindersScreenState extends State<RemindersScreen> with WidgetsBindingObserver {
  AppState get state => widget.state;
  late Future<ReminderDelivery?> _status;
  Timer? _nextAlert;
  bool _repairing = false;
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    state.notifications.scheduleRevision.addListener(_refresh);
    _status = _read();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    state.notifications.scheduleRevision.removeListener(_refresh);
    _nextAlert?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _refresh();
  }

  Future<ReminderDelivery?> _read() async {
    final revision = ++_revision;
    _nextAlert?.cancel();
    final data = await state.notifications.delivery(now: widget.now);
    if (mounted && revision == _revision && widget.now == null && data != null && data.pending.isNotEmpty) {
      final delay = data.pending.first.when.difference(DateTime.now());
      _nextAlert = Timer(delay + const Duration(seconds: 1), _refresh);
    }
    return data;
  }

  void _refresh() => setState(() => _status = _read());

  Future<void> _repair() async {
    setState(() => _repairing = true);
    try {
      await state.rescheduleNow();
    } finally {
      if (mounted) {
        setState(() {
          _repairing = false;
          _status = _read();
        });
      }
    }
  }

  String _dayLabel(DateTime day) {
    final today = widget.now ?? DateTime.now();
    if (DateUtils.isSameDay(day, today)) return 'Today';
    if (DateUtils.isSameDay(day, DateTime(today.year, today.month, today.day + 1))) return 'Tomorrow';
    return DateFormat('EEEE, d MMMM').format(day);
  }

  String _time(DateTime at) => '${_dayLabel(at)}, ${DateFormat.jm().format(at)}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Reminders')),
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) => FutureBuilder<ReminderDelivery?>(
          future: _status,
          builder: (context, snapshot) {
            final data = snapshot.data;
            final pending = data?.pending ?? const [];
            final next = data?.allowed == true ? pending.where((r) => !data!.muted.contains(r.id)).firstOrNull : null;
            final byDay = <String, List<PlannedReminder>>{};
            for (final r in pending) {
              byDay.putIfAbsent(dayKey(r.when), () => []).add(r);
            }
            return ListView(children: [
              SwitchListTile.adaptive(
                secondary: const Icon(Icons.notifications_active_outlined),
                title: const Text('Reminders'),
                value: state.settings.remindersEnabled,
                onChanged: (v) async {
                  if (v) await state.notifications.requestPermissions();
                  await state.updateSettings((s) => s.remindersEnabled = v);
                },
              ),
              if (!state.settings.remindersEnabled)
                const ListTile(title: Text('Reminders are turned off.'))
              else ...[
                if (snapshot.connectionState == ConnectionState.waiting && data == null)
                  const LinearProgressIndicator()
                else if (data == null)
                  const ListTile(title: Text('Could not read scheduled alerts on this device.'))
                else ...[
                  ListTile(
                    leading: const Icon(Icons.notifications_outlined),
                    title: Text(data.allowed ? 'Notifications allowed' : 'Notifications blocked'),
                    subtitle: Text([
                      if (data.exact != null) data.exact! ? 'Exact alarm access allowed' : 'Inexact alarms · may arrive late',
                      if (data.blockedChannels.isNotEmpty) 'Muted in settings: ${data.blockedChannels.join(', ')}',
                    ].join('\n')),
                  ),
                  if (!data.allowed || data.blockedChannels.isNotEmpty)
                    ListTile(
                      title: const Text('Open notification settings'),
                      trailing: const Icon(Icons.open_in_new),
                      onTap: () => AppSettings.openAppSettings(type: AppSettingsType.notification),
                    ),
                  if (data.exact == false)
                    ListTile(
                      title: const Text('Allow exact alarms'),
                      subtitle: const Text('Schedule alerts on the minute'),
                      trailing: const Icon(Icons.open_in_new),
                      onTap: () async {
                        await state.notifications.requestExactAlarms();
                        if (mounted) await _repair();
                      },
                    ),
                  ListTile(
                    title: Text(next != null ? 'Next alert · ${_time(next.when)}'
                        : pending.isEmpty ? 'No alerts queued' : 'Queued alerts are blocked'),
                    subtitle: Text([
                      if (next != null) next.title,
                      if (pending.isNotEmpty) '${pending.length} queued · last ${_time(pending.last.when)}.',
                      if (data.missing > 0)
                        '${data.missing} ${data.missing == 1 ? 'alert is' : 'alerts are'} missing. Rebuild the schedule to retry.',
                      if (data.beyondLimit > 0) '${data.beyondLimit} more fall beyond the $maxPending-alert limit.',
                      'Open the app to schedule the next $scheduleDays days and update times after a time zone change. '
                          'Once the queue runs out, alerts stop until you reopen.',
                    ].join('\n')),
                  ),
                ],
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    style: compactButton,
                    onPressed: _repairing ? null : _repair,
                    icon: const Icon(Icons.refresh),
                    label: Text(_repairing ? 'Rebuilding…' : 'Rebuild schedule'),
                  ),
                ),
                for (final group in byDay.values) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text(_dayLabel(group.first.when), style: Theme.of(context).textTheme.titleSmall),
                  ),
                  for (final r in group)
                    ExpansionTile(
                      leading: Icon(RemindersScreen.iconFor(r.kind)),
                      title: Text(r.title),
                      subtitle: Text('${DateFormat.jm().format(r.when)}${data!.muted.contains(r.id) ? ' · muted' : ''}'),
                      expandedCrossAxisAlignment: CrossAxisAlignment.start,
                      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      children: [Align(alignment: AlignmentDirectional.centerStart, child: Text(r.body))],
                    ),
                ],
              ],
            ]);
          },
        ),
      ),
    );
  }
}
