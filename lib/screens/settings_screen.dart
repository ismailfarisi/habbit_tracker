import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../logic/prayer_status.dart';
import '../models.dart';
import '../logic/sleep.dart';
import '../services/backup_service.dart';
import '../services/diagnostics.dart';
import '../services/openrouter.dart';
import '../services/openrouter_models.dart';
import 'reminders_screen.dart';
import 'wake_challenge_screen.dart';
import '../services/storage.dart';
import 'diagnostics_screen.dart';
import '../widgets/voice_settings.dart';
import '../widgets/adaptive.dart';

class SettingsScreen extends StatefulWidget {
  final AppState state;

  /// Overrides for tests; default to the real file-backed services.
  final BackupService? backup;
  final Future<String?> Function()? pickBackupFile;

  const SettingsScreen({super.key, required this.state, this.backup, this.pickBackupFile});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final _lat = TextEditingController(text: widget.state.settings.latitude?.toStringAsFixed(4) ?? '');
  late final _lng = TextEditingController(text: widget.state.settings.longitude?.toStringAsFixed(4) ?? '');
  late final _locName = TextEditingController(text: widget.state.settings.locationName);
  late final _backup = widget.backup ?? BackupService(widget.state.storage);
  late final _diagnostics = Diagnostics.global ?? Diagnostics(widget.state.storage.prefs);
  bool _locating = false;

  AppState get state => widget.state;
  Settings get s => state.settings;

  @override
  void dispose() {
    for (final c in [_lat, _lng, _locName]) {
      c.dispose();
    }
    super.dispose();
  }

  void _snack(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  String _fmt(TimeOfDay t) => DateFormat.jm().format(DateTime(2000, 1, 1, t.hour, t.minute));

  Future<TimeOfDay?> _pickTime(TimeOfDay initial) => showTimePicker(context: context, initialTime: initial);

  Future<void> _useMyLocation() async {
    setState(() => _locating = true);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _snack('Turn on location services, then try again.');
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        _snack('Location permission denied. You can enter coordinates manually.');
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.low, timeLimit: Duration(seconds: 20)),
      );
      _lat.text = pos.latitude.toStringAsFixed(4);
      _lng.text = pos.longitude.toStringAsFixed(4);
      if (_locName.text.isEmpty) _locName.text = 'My location';
      await _saveLocation();
    } catch (e) {
      _snack('Could not get location: $e');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _saveLocation() async {
    final lat = double.tryParse(_lat.text.trim());
    final lng = double.tryParse(_lng.text.trim());
    if (lat == null || lng == null || lat.abs() > 90 || lng.abs() > 180) {
      _snack('Enter a valid latitude (-90 to 90) and longitude (-180 to 180).');
      return;
    }
    await state.updateSettings((x) {
      x.latitude = lat;
      x.longitude = lng;
      x.locationName = _locName.text.trim();
    });
    _snack('Location saved. Prayer times updated.');
  }

  // ---------- Backup ----------
  Future<void> _pasteBackup() async {
    final ctl = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Paste backup'),
        content: TextField(
          controller: ctl,
          maxLines: 8,
          decoration: const InputDecoration(hintText: 'Paste backup JSON here'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, ctl.text), child: const Text('Continue')),
        ],
      ),
    );
    ctl.dispose();
    if (raw == null || raw.trim().isEmpty) return;
    await _confirmRestore(raw, 'the pasted backup');
  }

  Future<void> _importFile() async {
    try {
      final raw = await (widget.pickBackupFile ?? BackupService.pickBackupFile)();
      if (raw == null) return;
      await _confirmRestore(raw, 'this file');
    } catch (e) {
      _snack(_errorText(e));
    }
  }

  Future<void> _exportFile(BuildContext tileContext) async {
    final box = tileContext.findRenderObject() as RenderBox?;
    try {
      await _backup.shareExport(origin: box == null ? null : box.localToGlobal(Offset.zero) & box.size);
    } catch (e) {
      _snack('Could not share the backup: $e');
    }
  }

  Future<void> _copyBackup() async {
    await Clipboard.setData(ClipboardData(text: state.storage.exportJson()));
    _snack('Backup copied to clipboard.');
  }

  Future<void> _pickAutomaticBackup() async {
    final list = await _backup.automaticBackups();
    if (!mounted) return;
    final picked = await showModalBottomSheet<AutoBackup>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('Restore from automatic backup'),
              subtitle: Text(
                'A copy is saved on this phone once a day (last ${BackupService.keepDaily} kept), '
                'and before every restore.',
              ),
            ),
            if (list.isEmpty)
              const ListTile(leading: Icon(Icons.info_outline), title: Text('No automatic backups yet.'))
            else
              for (final b in list)
                ListTile(
                  leading: Icon(b.beforeRestore ? Icons.restore : Icons.event_available_outlined),
                  title: Text(DateFormat.yMMMEd().add_jm().format(b.at)),
                  subtitle: Text(b.beforeRestore ? 'Saved before a restore' : 'Daily backup'),
                  onTap: () => Navigator.pop(c, b),
                ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    try {
      await _confirmRestore(await picked.read(), 'the backup from ${DateFormat.yMMMEd().add_jm().format(picked.at)}');
    } catch (e) {
      _snack(_errorText(e));
    }
  }

  String _errorText(Object e) => e is FormatException ? 'Import failed: ${e.message}' : 'Import failed: $e';

  Future<void> _confirmRestore(String raw, String what) async {
    final BackupSummary info;
    try {
      info = Storage.describeBackup(raw);
    } catch (e) {
      _snack(_errorText(e));
      return;
    }
    if (!mounted) return;
    final made = info.exportedAt == null
        ? ''
        : ' Made ${DateFormat.yMMMd().add_jm().format(info.exportedAt!.toLocal())}.';
    final ok = await confirmDialog(
      context,
      title: 'Restore backup?',
      message:
          'Restore $what: ${info.describe()}.$made\n\n'
          'This replaces the data on this phone. A copy of your current data is saved first, so you can '
          'undo this from "Restore from automatic backup". Your API key is not part of backups.',
      confirm: 'Restore',
    );
    if (!ok) return;
    try {
      await _backup.restore(state, raw);
      _syncFields();
      _snack('Backup restored.');
    } catch (e) {
      _snack(_errorText(e));
    }
  }

  void _syncFields() {
    _lat.text = s.latitude?.toStringAsFixed(4) ?? '';
    _lng.text = s.longitude?.toStringAsFixed(4) ?? '';
    _locName.text = s.locationName;
    if (mounted) setState(() {});
  }

  Future<void> _reset() async {
    final ok = await confirmDialog(
      context,
      title: 'Reset everything?',
      message:
          'This deletes all your history, settings, API key and diagnostics. '
          'Automatic backups stay on this phone, so you can still restore one.',
      confirm: 'Reset',
      destructive: true,
    );
    if (!ok) return;
    await state.resetAll();
    await _diagnostics.clear();
    _lat.clear();
    _lng.clear();
    _locName.clear();
    _snack('All data cleared.');
  }

  Future<int?> _pickNumber(String title, int value, int min, int max, {String unit = 'min'}) async {
    var v = value;
    return showDialog<int>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('$v $unit', style: Theme.of(c).textTheme.headlineMedium),
              Slider.adaptive(
                value: v.toDouble(),
                min: min.toDouble(),
                max: max.toDouble(),
                divisions: max - min,
                onChanged: (x) => set(() => v = x.round()),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, v), child: const Text('Save')),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.symmetric(vertical: 16),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Settings',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          _header('Appearance'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: SegmentedButton<String>(
              key: const Key('theme-mode'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'system', label: Text('System')),
                ButtonSegment(value: 'light', label: Text('Light')),
                ButtonSegment(value: 'dark', label: Text('Dark')),
              ],
              selected: {s.themeMode},
              onSelectionChanged: (v) => state.updateSettings((x) => x.themeMode = v.first),
            ),
          ),
          _header('Wake up'),
          ListTile(
            leading: const Icon(Icons.alarm),
            title: const Text('Target wake-up time'),
            subtitle: Text(_fmt(s.wakeTime)),
            onTap: () async {
              final t = await _pickTime(s.wakeTime);
              if (t != null) await state.updateSettings((x) => x.wakeTime = t);
            },
          ),
          ListTile(
            leading: const Icon(Icons.timelapse),
            title: const Text('Grace period'),
            subtitle: Text('Counts as on time if you check in within ${s.wakeGraceMin} min'),
            onTap: () async {
              final v = await _pickNumber('Grace period', s.wakeGraceMin, 0, 120);
              if (v != null) await state.updateSettings((x) => x.wakeGraceMin = v);
            },
          ),
          SwitchListTile.adaptive(
            secondary: const Icon(Icons.volume_up_outlined),
            title: const Text('Loud alarm'),
            subtitle: const Text('Full-screen alarm that keeps ringing until you tap "I\'m up"'),
            value: s.wakeAlarmLoud,
            onChanged: (v) => state.updateSettings((x) => x.wakeAlarmLoud = v),
          ),
          ..._wakeChallengeAndSleep(),

          _header('Prayer times'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton.tonalIcon(
                  onPressed: _locating ? null : _useMyLocation,
                  icon: _locating
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator.adaptive(strokeWidth: 2))
                      : const Icon(Icons.my_location),
                  label: const Text('Use my current location'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _locName,
                  decoration: const InputDecoration(labelText: 'Place name (optional)', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _lat,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                        decoration: const InputDecoration(labelText: 'Latitude', border: OutlineInputBorder()),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _lng,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                        decoration: const InputDecoration(labelText: 'Longitude', border: OutlineInputBorder()),
                      ),
                    ),
                  ],
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(onPressed: _saveLocation, child: const Text('Save location')),
                ),
                DropdownButtonFormField<String>(
                  initialValue: s.calcMethod,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Calculation method', border: OutlineInputBorder()),
                  items: [
                    for (final e in calcMethodLabels.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ],
                  onChanged: (v) => state.updateSettings((x) => x.calcMethod = v ?? x.calcMethod),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: s.madhab,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Asr calculation', border: OutlineInputBorder()),
                  items: const [
                    DropdownMenuItem(value: 'shafi', child: Text("Standard (Shafi'i, Maliki, Hanbali)")),
                    DropdownMenuItem(value: 'hanafi', child: Text('Hanafi')),
                  ],
                  onChanged: (v) => state.updateSettings((x) => x.madhab = v ?? x.madhab),
                ),
              ],
            ),
          ),
          SwitchListTile.adaptive(
            title: const Text('Use manual prayer times'),
            subtitle: const Text('e.g. to match your local mosque timetable'),
            value: s.useManualPrayer,
            onChanged: (v) => state.updateSettings((x) => x.useManualPrayer = v),
          ),
          if (s.useManualPrayer)
            for (final p in prayerNames)
              ListTile(
                contentPadding: const EdgeInsets.only(left: 32, right: 16),
                title: Text(p),
                trailing: Text(_fmt(parseHm(s.manualTimes[p]!))),
                onTap: () async {
                  final t = await _pickTime(parseHm(s.manualTimes[p]!));
                  if (t != null) await state.updateSettings((x) => x.manualTimes[p] = fmtHm(t));
                },
              ),

          ..._muslimSection(),

          _header('Streaks'),
          ListTile(
            leading: const Icon(Icons.ac_unit),
            title: const Text('Streak freezes per month'),
            subtitle: Text(
              '${s.freezesPerMonth} missed ${s.freezesPerMonth == 1 ? 'day' : 'days'} a month keep your perfect-day streak',
            ),
            onTap: () async {
              final v = await _pickNumber('Streak freezes per month', s.freezesPerMonth, 0, 10);
              if (v != null) await state.updateSettings((x) => x.freezesPerMonth = v);
            },
          ),

          _header('Reminders'),
          SwitchListTile.adaptive(
            secondary: const Icon(Icons.notifications_active_outlined),
            title: const Text('Reminders'),
            subtitle: const Text('Wake-up alarm, each prayer, habits and tasks'),
            value: s.remindersEnabled,
            onChanged: (v) => state.updateSettings((x) => x.remindersEnabled = v),
          ),
          ListTile(
            leading: const Icon(Icons.schedule),
            title: const Text('Upcoming reminders'),
            subtitle: const Text('Everything planned for the next days'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () =>
                Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RemindersScreen(state: state))),
          ),
          ListTile(
            leading: const Icon(Icons.more_time),
            title: const Text('Prayer reminder'),
            subtitle: Text(s.prayerOffsetMin == 0 ? 'At prayer time' : '${s.prayerOffsetMin} min before prayer time'),
            onTap: () async {
              final v = await _pickNumber('Remind me before prayer', s.prayerOffsetMin, 0, 30);
              if (v != null) await state.updateSettings((x) => x.prayerOffsetMin = v);
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  style: compactButton,
                  onPressed: () async {
                    final ok = await state.notifications.requestPermissions();
                    await state.rescheduleNow();
                    _snack(
                      ok ? 'Notifications allowed.' : 'Notifications are blocked. Enable them in system settings.',
                    );
                  },
                  child: const Text('Grant permissions'),
                ),
                OutlinedButton(
                  style: compactButton,
                  onPressed: () => state.notifications.showTest(s),
                  child: const Text('Send test notification'),
                ),
              ],
            ),
          ),

          _header('Voice'),
          VoiceSettingsSection(state: state),

          _header('AI coach (OpenRouter)'),
          AiKeySection(state: state),

          _header('Backup'),
          Builder(
            builder: (tile) => ListTile(
              leading: const Icon(Icons.ios_share),
              title: const Text('Export backup file'),
              subtitle: const Text('Save or send your history, habits, tasks and settings as a file'),
              onTap: () => _exportFile(tile),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.file_open_outlined),
            title: const Text('Import backup file'),
            subtitle: const Text('Restore from a file you exported'),
            onTap: _importFile,
          ),
          ListTile(
            leading: const Icon(Icons.history),
            title: const Text('Restore from automatic backup'),
            subtitle: const Text('Saved on this phone once a day, last ${BackupService.keepDaily} kept'),
            onTap: _pickAutomaticBackup,
          ),
          ListTile(
            leading: const Icon(Icons.copy_outlined),
            title: const Text('Copy backup to clipboard'),
            onTap: _copyBackup,
          ),
          ListTile(
            leading: const Icon(Icons.content_paste_outlined),
            title: const Text('Paste backup'),
            onTap: _pasteBackup,
          ),

          _header('Diagnostics'),
          SwitchListTile.adaptive(
            secondary: const Icon(Icons.monitor_heart_outlined),
            title: const Text('Collect diagnostics on this phone'),
            subtitle: const Text(diagnosticsExplanation),
            isThreeLine: true,
            value: _diagnostics.enabled,
            onChanged: (v) async {
              await _diagnostics.setEnabled(v);
              setState(() {});
            },
          ),
          ListTile(
            leading: const Icon(Icons.bug_report_outlined),
            title: const Text('Diagnostics'),
            subtitle: const Text('Counters, error log and "Share report"'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => DiagnosticsScreen(diagnostics: _diagnostics)));
              if (mounted) setState(() {});
            },
          ),

          _header('Data'),
          ListTile(
            leading: Icon(Icons.delete_forever_outlined, color: Theme.of(context).colorScheme.error),
            title: Text('Reset all data', style: TextStyle(color: Theme.of(context).colorScheme.error)),
            onTap: _reset,
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  static const _challengeLabels = {
    WakeChallenge.off: 'Off',
    WakeChallenge.readAloud: 'Read a sentence aloud',
    WakeChallenge.math: 'Solve 2 math problems',
  };

  Future<double?> _pickHours(String title, double value) {
    var v = value;
    return showDialog<double>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(fmtSleepHours(v), style: Theme.of(c).textTheme.headlineMedium),
              Slider.adaptive(value: v, min: 5, max: 10, divisions: 20, onChanged: (x) => set(() => v = x)),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, v), child: const Text('Save')),
          ],
        ),
      ),
    );
  }

  List<Widget> _wakeChallengeAndSleep() {
    final night = DateTime.now();
    return [
      ListTile(
        leading: const Icon(Icons.verified_user_outlined),
        title: const Text('Wake challenge'),
        subtitle: Text(
          s.wakeChallenge == WakeChallenge.off
              ? 'Off. "I\'m up" counts right away'
              : '${_challengeLabels[s.wakeChallenge]} before "I\'m up" counts',
        ),
        onTap: () async {
          final v = await showDialog<WakeChallenge>(
            context: context,
            builder: (c) => SimpleDialog(
              title: const Text('Prove you\'re up'),
              children: [
                for (final e in _challengeLabels.entries)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(c, e.key),
                    child: Row(
                      children: [
                        Icon(e.key == s.wakeChallenge ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                        const SizedBox(width: 12),
                        Text(e.value),
                      ],
                    ),
                  ),
              ],
            ),
          );
          if (v != null) await state.updateSettings((x) => x.wakeChallenge = v);
        },
        trailing: s.wakeChallenge == WakeChallenge.off
            ? null
            : TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => WakeChallengeScreen(state: state, mode: s.wakeChallenge, practice: true),
                  ),
                ),
                child: const Text('Try it'),
              ),
      ),
      _header('Sleep & bedtime'),
      ListTile(
        leading: const Icon(Icons.bedtime_outlined),
        title: const Text('Sleep goal'),
        subtitle: Text(
          '${fmtSleepHours(s.sleepHours)} a night, bed by ${_fmt(TimeOfDay.fromDateTime(bedtimeFor(s, night)))}',
        ),
        onTap: () async {
          final v = await _pickHours('Sleep goal', s.sleepHours);
          if (v != null) await state.updateSettings((x) => x.sleepHours = v);
        },
      ),
      ListTile(
        leading: const Icon(Icons.self_improvement),
        title: const Text('Wind-down time'),
        subtitle: Text('${s.windDownMinutes} min before bed'),
        onTap: () async {
          final v = await _pickNumber('Wind down before bed', s.windDownMinutes, 0, 120);
          if (v != null) await state.updateSettings((x) => x.windDownMinutes = v);
        },
      ),
      SwitchListTile.adaptive(
        secondary: const Icon(Icons.nights_stay_outlined),
        title: const Text('Bedtime reminder'),
        subtitle: Text(
          'Every night at ${_fmt(TimeOfDay.fromDateTime(windDownFor(s, night)))} with a "Going to bed" button',
        ),
        value: s.bedtimeReminder,
        onChanged: (v) => state.updateSettings((x) => x.bedtimeReminder = v),
      ),
    ];
  }

  // ---------- Ramadan, Jumu'ah & sunnah prayers ----------
  Future<void> _pickJumuahTime() async {
    final choice = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text("Jumu'ah time"),
        children: [
          SimpleDialogOption(onPressed: () => Navigator.pop(c, ''), child: const Text('Same as Dhuhr')),
          SimpleDialogOption(onPressed: () => Navigator.pop(c, '13:15'), child: const Text('1:15 PM (UAE mosques)')),
          SimpleDialogOption(onPressed: () => Navigator.pop(c, 'pick'), child: const Text('Pick a time…')),
        ],
      ),
    );
    if (choice == null) return;
    var v = choice;
    if (choice == 'pick') {
      final t = await _pickTime(s.jumuahTime.isEmpty ? const TimeOfDay(hour: 13, minute: 0) : parseHm(s.jumuahTime));
      if (t == null) return;
      v = fmtHm(t);
    }
    await state.updateSettings((x) => x.jumuahTime = v);
  }

  List<Widget> _muslimSection() {
    final now = DateTime.now();
    final ramadanNow = isRamadan(s, now);
    return [
      _header("Ramadan, Jumu'ah & sunnah"),
      ListTile(
        leading: const Icon(Icons.calendar_month_outlined),
        title: const Text('Hijri date adjustment'),
        subtitle: Text(
          'Today: ${hijriToday(s, now)}'
          '${s.hijriOffsetDays == 0 ? '' : ' (${s.hijriOffsetDays > 0 ? '+' : ''}${s.hijriOffsetDays} days)'}',
        ),
        onTap: () async {
          final v = await _pickNumber('Hijri date adjustment', s.hijriOffsetDays, -2, 2, unit: 'days');
          if (v != null) await state.updateSettings((x) => x.hijriOffsetDays = v);
        },
      ),
      ListTile(
        leading: const Icon(Icons.nightlight_outlined),
        title: const Text('Ramadan mode'),
        subtitle: Text(switch (s.ramadanMode) {
          'on' => 'On',
          'off' => 'Off',
          _ => 'Automatic during Ramadan${ramadanNow ? ' (active now)' : ''}',
        }),
        trailing: DropdownButton<String>(
          value: s.ramadanMode,
          underline: const SizedBox.shrink(),
          items: const [
            DropdownMenuItem(value: 'auto', child: Text('Auto')),
            DropdownMenuItem(value: 'on', child: Text('On')),
            DropdownMenuItem(value: 'off', child: Text('Off')),
          ],
          onChanged: (v) => state.updateSettings((x) => x.ramadanMode = v ?? x.ramadanMode),
        ),
      ),
      SwitchListTile.adaptive(
        secondary: const Icon(Icons.alarm_on_outlined),
        title: const Text('Suhoor wake alarm'),
        subtitle: Text('In Ramadan, ${s.suhoorMinutes} min before Fajr'),
        value: s.suhoorReminder,
        onChanged: (v) => state.updateSettings((x) => x.suhoorReminder = v),
      ),
      if (s.suhoorReminder)
        ListTile(
          contentPadding: const EdgeInsets.only(left: 72, right: 16),
          title: const Text('Suhoor alarm before Fajr'),
          trailing: Text('${s.suhoorMinutes} min'),
          onTap: () async {
            final v = await _pickNumber('Suhoor alarm before Fajr', s.suhoorMinutes, 10, 120);
            if (v != null) await state.updateSettings((x) => x.suhoorMinutes = v);
          },
        ),
      SwitchListTile.adaptive(
        secondary: const Icon(Icons.star_outline),
        title: const Text('Taraweeh'),
        subtitle: const Text('Optional item after Isha in Ramadan'),
        value: s.taraweeh,
        onChanged: (v) => state.updateSettings((x) => x.taraweeh = v),
      ),
      ListTile(
        leading: const Icon(Icons.mosque_outlined),
        title: const Text("Jumu'ah time"),
        subtitle: Text(s.jumuahTime.isEmpty ? 'Same as Dhuhr' : _fmt(parseHm(s.jumuahTime))),
        onTap: _pickJumuahTime,
      ),
      SwitchListTile.adaptive(
        secondary: const Icon(Icons.notifications_outlined),
        title: const Text("Early Jumu'ah reminder"),
        subtitle: Text('Fridays, ${s.jumuahReminderMinutes} min before'),
        value: s.jumuahReminder,
        onChanged: (v) => state.updateSettings((x) => x.jumuahReminder = v),
      ),
      if (s.jumuahReminder)
        ListTile(
          contentPadding: const EdgeInsets.only(left: 72, right: 16),
          title: const Text("Remind me before Jumu'ah"),
          trailing: Text('${s.jumuahReminderMinutes} min'),
          onTap: () async {
            final v = await _pickNumber("Remind me before Jumu'ah", s.jumuahReminderMinutes, 10, 120);
            if (v != null) await state.updateSettings((x) => x.jumuahReminderMinutes = v);
          },
        ),
      SwitchListTile.adaptive(
        secondary: const Icon(Icons.wb_sunny_outlined),
        title: const Text('Duha prayer'),
        subtitle: const Text('Optional, not counted in the 5-prayer streak'),
        value: s.sunnahDuha,
        onChanged: (v) => state.updateSettings((x) => x.sunnahDuha = v),
      ),
      SwitchListTile.adaptive(
        secondary: const Icon(Icons.bedtime_outlined),
        title: const Text('Witr prayer'),
        subtitle: const Text('Optional, not counted in the 5-prayer streak'),
        value: s.sunnahWitr,
        onChanged: (v) => state.updateSettings((x) => x.sunnahWitr = v),
      ),
    ];
  }

  Widget _header(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}

/// Opens Settings as a page (the gear icon in the app bar). With
/// [aiKeyOnly] it opens just the AI key section.
Future<void> openSettings(BuildContext context, AppState state, {bool aiKeyOnly = false}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        appBar: AppBar(title: aiKeyOnly ? const Text('AI coach') : null),
        body: SafeArea(
          child: aiKeyOnly
              ? ListView(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  children: [AiKeySection(state: state)],
                )
              : SettingsScreen(state: state),
        ),
      ),
    ),
  );
}

/// The OpenRouter key and model fields with a "Save & test" check. Used in
/// Settings and in onboarding (with [showModel] false).
class AiKeySection extends StatefulWidget {
  final AppState state;
  final bool showModel;

  /// Overrides the OpenRouter model list fetch (tests).
  final Future<List<OpenRouterModel>> Function()? loadModels;
  const AiKeySection({super.key, required this.state, this.showModel = true, this.loadModels});

  @override
  State<AiKeySection> createState() => _AiKeySectionState();
}

class _AiKeySectionState extends State<AiKeySection> {
  late final _apiKey = TextEditingController(text: widget.state.apiKey);
  late final _model = TextEditingController(text: widget.state.settings.model);
  bool _hideKey = true;
  String _status = '';

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    state.addListener(_sync);
  }

  @override
  void dispose() {
    state.removeListener(_sync);
    _apiKey.dispose();
    _model.dispose();
    super.dispose();
  }

  /// Picks up outside changes (e.g. "Reset all data").
  void _sync() {
    if (state.apiKey != _apiKey.text.trim()) _apiKey.text = state.apiKey;
    if (state.settings.model != _model.text.trim() && _model.text.trim().isNotEmpty) _model.text = state.settings.model;
    if (mounted) setState(() {});
  }

  Future<void> _test() async {
    await state.setApiKey(_apiKey.text);
    await state.updateSettings((x) => x.model = _model.text.trim().isEmpty ? 'openai/gpt-4o-mini' : _model.text.trim());
    if (state.apiKey.isEmpty) {
      setState(() => _status = 'Paste your key first.');
      return;
    }
    setState(() => _status = 'Testing…');
    final client = OpenRouterClient(apiKey: state.apiKey, model: state.settings.model);
    try {
      final reply = await client.complete([
        const ChatMessage('user', 'Reply with exactly: Coach ready!'),
      ], temperature: 0);
      if (mounted) setState(() => _status = '✅ ${reply.trim()}');
    } catch (e) {
      if (mounted) setState(() => _status = '❌ $e');
    } finally {
      client.close();
    }
  }

  Future<void> _remove() async {
    _apiKey.clear();
    await state.setApiKey('');
    if (mounted) setState(() => _status = 'Key removed. Templates still work; the coach is off.');
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final on = state.apiKey.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                on ? Icons.check_circle : Icons.info_outline,
                size: 18,
                color: on ? t.colorScheme.primary : t.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  on
                      ? 'The coach is on: it can build habits and plan tasks for you.'
                      : 'Optional. Without a key everything works except the AI coach; habit templates are always available.',
                  style: t.textTheme.bodySmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _apiKey,
            obscureText: _hideKey,
            autocorrect: false,
            enableSuggestions: false,
            onChanged: state.setApiKey,
            decoration: InputDecoration(
              labelText: 'API key',
              hintText: 'sk-or-v1-…',
              helperText: 'Get one at openrouter.ai/keys. Stored encrypted on this device.',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: _hideKey ? 'Show key' : 'Hide key',
                icon: Icon(_hideKey ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _hideKey = !_hideKey),
              ),
            ),
          ),
          if (widget.showModel) ...[
            const SizedBox(height: 12),
            ModelPicker(
              controller: _model,
              loadModels: widget.loadModels,
              onSelected: (v) => state.updateSettings((x) => x.model = v.trim().isEmpty ? x.model : v.trim()),
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton(style: compactButton, onPressed: _test, child: const Text('Save & test')),
              if (on) TextButton(onPressed: _remove, child: const Text('Remove key')),
            ],
          ),
          if (_status.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_status, style: t.textTheme.bodySmall),
            ),
        ],
      ),
    );
  }
}

/// Model ID field that autocompletes from OpenRouter's live model list, with
/// free models first and a "Free only" filter. Any typed ID is still accepted.
class ModelPicker extends StatefulWidget {
  final TextEditingController controller;
  final ValueChanged<String> onSelected;
  final Future<List<OpenRouterModel>> Function()? loadModels;

  const ModelPicker({super.key, required this.controller, required this.onSelected, this.loadModels});

  @override
  State<ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends State<ModelPicker> {
  final _focus = FocusNode();
  List<OpenRouterModel> _models = fallbackModels;
  bool _loading = true;
  bool _freeOnly = false;

  @override
  void initState() {
    super.initState();
    (widget.loadModels ?? fetchOpenRouterModels)().then(
      (m) {
        if (!mounted) return;
        setState(() {
          _models = m;
          _loading = false;
        });
      },
      onError: (_) {
        if (mounted) setState(() => _loading = false);
      },
    );
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  Iterable<OpenRouterModel> _options(String query) {
    final pool = _freeOnly ? _models.where((m) => m.free) : _models;
    // Show everything when the field still holds the saved, unedited ID.
    final exact = _models.any((m) => m.id == query.trim());
    return pool.where((m) => exact || m.matches(query)).take(60);
  }

  void _pick(String id) {
    widget.controller.text = id;
    widget.onSelected(id);
  }

  void _toggleFree(bool v) {
    setState(() => _freeOnly = v);
    _focus.requestFocus();
    // Nudge RawAutocomplete to recompute options for the new filter.
    final c = widget.controller;
    final text = c.text;
    c.value = c.value.copyWith(text: '$text ');
    c.value = c.value.copyWith(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final freeCount = _models.where((m) => m.free).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          // Part of the field's tap region so tapping it keeps the list open.
          child: TextFieldTapRegion(
            child: FilterChip(
              key: const Key('free-only'),
              label: Text('Free only${freeCount > 0 ? ' ($freeCount)' : ''}'),
              selected: _freeOnly,
              onSelected: _toggleFree,
            ),
          ),
        ),
        const SizedBox(height: 8),
        RawAutocomplete<OpenRouterModel>(
          textEditingController: widget.controller,
          focusNode: _focus,
          displayStringForOption: (m) => m.id,
          optionsBuilder: (v) => _options(v.text),
          onSelected: (m) => _pick(m.id),
          fieldViewBuilder: (context, controller, focus, onSubmit) => TextField(
            key: const Key('model-field'),
            controller: controller,
            focusNode: focus,
            autocorrect: false,
            enableSuggestions: false,
            onSubmitted: (v) {
              onSubmit();
              widget.onSelected(v);
            },
            decoration: InputDecoration(
              labelText: 'Model',
              helperText: _loading
                  ? 'Loading models from OpenRouter…'
                  : '${_models.length} models, $freeCount free. Type to search, or paste any ID.',
              border: const OutlineInputBorder(),
              suffixIcon: _loading
                  ? const Padding(
                      padding: EdgeInsets.all(14),
                      child: SizedBox.square(dimension: 18, child: CircularProgressIndicator.adaptive(strokeWidth: 2)),
                    )
                  : IconButton(
                      tooltip: 'Show models',
                      icon: const Icon(Icons.arrow_drop_down),
                      onPressed: () {
                        controller.selection = TextSelection(baseOffset: 0, extentOffset: controller.text.length);
                        focus.requestFocus();
                      },
                    ),
            ),
          ),
          optionsViewBuilder: (context, onSelected, options) => Align(
            alignment: Alignment.topLeft,
            child: Material(
              elevation: 4,
              borderRadius: BorderRadius.circular(8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280, maxWidth: 520),
                child: ListView.builder(
                  padding: EdgeInsets.zero,
                  shrinkWrap: true,
                  itemCount: options.length,
                  itemBuilder: (context, i) {
                    final m = options.elementAt(i);
                    final highlighted = AutocompleteHighlightedOption.of(context) == i;
                    return ListTile(
                      dense: true,
                      selected: highlighted,
                      title: Text(m.id, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        [
                          if (m.name.isNotEmpty && m.name != m.id) m.name,
                          if (m.contextLength > 0) '${(m.contextLength / 1000).round()}k ctx',
                          if (!m.tools) "can't build habits (no tools)",
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: m.free
                          ? Chip(
                              label: const Text('Free'),
                              visualDensity: VisualDensity.compact,
                              backgroundColor: t.colorScheme.secondaryContainer,
                            )
                          : null,
                      onTap: () => onSelected(m),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
