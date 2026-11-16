import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../models.dart';
import '../services/backup_service.dart';
import '../services/diagnostics.dart';
import '../services/openrouter.dart';
import '../services/storage.dart';
import 'diagnostics_screen.dart';

const _suggestedModels = [
  'openai/gpt-4o-mini',
  'anthropic/claude-sonnet-4.5',
  'google/gemini-2.5-flash',
  'deepseek/deepseek-chat',
  'meta-llama/llama-3.3-70b-instruct:free',
];

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
  late final _apiKey = TextEditingController(text: widget.state.apiKey);
  late final _model = TextEditingController(text: widget.state.settings.model);
  late final _lat = TextEditingController(text: widget.state.settings.latitude?.toStringAsFixed(4) ?? '');
  late final _lng = TextEditingController(text: widget.state.settings.longitude?.toStringAsFixed(4) ?? '');
  late final _locName = TextEditingController(text: widget.state.settings.locationName);
  late final _backup = widget.backup ?? BackupService(widget.state.storage);
  late final _diagnostics = Diagnostics.global ?? Diagnostics(widget.state.storage.prefs);
  bool _locating = false;
  bool _hideKey = true;
  String _aiStatus = '';

  AppState get state => widget.state;
  Settings get s => state.settings;

  @override
  void dispose() {
    for (final c in [_apiKey, _model, _lat, _lng, _locName]) {
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

  Future<void> _testAi() async {
    await state.setApiKey(_apiKey.text);
    await state.updateSettings((x) => x.model = _model.text.trim().isEmpty ? 'openai/gpt-4o-mini' : _model.text.trim());
    setState(() => _aiStatus = 'Testing…');
    final client = OpenRouterClient(apiKey: state.apiKey, model: s.model);
    try {
      final reply = await client.complete([
        const ChatMessage('user', 'Reply with exactly: Coach ready!'),
      ], temperature: 0);
      setState(() => _aiStatus = '✅ ${reply.trim()}');
    } catch (e) {
      setState(() => _aiStatus = '❌ $e');
    } finally {
      client.close();
    }
  }

  // ---------- Backup ----------
  Future<void> _pasteBackup() async {
    final ctl = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Paste backup'),
        content: TextField(controller: ctl, maxLines: 8, decoration: const InputDecoration(hintText: 'Paste backup JSON here')),
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
        child: ListView(shrinkWrap: true, children: [
          const ListTile(
            title: Text('Restore from automatic backup'),
            subtitle: Text('A copy is saved on this phone once a day (last ${BackupService.keepDaily} kept), '
                'and before every restore.'),
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
        ]),
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
    final made = info.exportedAt == null ? '' : ' Made ${DateFormat.yMMMd().add_jm().format(info.exportedAt!.toLocal())}.';
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Restore backup?'),
        content: Text('Restore $what: ${info.describe()}.$made\n\n'
            'This replaces the data on this phone. A copy of your current data is saved first, so you can '
            'undo this from "Restore from automatic backup". Your API key is not part of backups.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Restore')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _backup.restore(state, raw);
      _syncFields();
      _snack('Backup restored.');
    } catch (e) {
      _snack(_errorText(e));
    }
  }

  void _syncFields() {
    _model.text = s.model;
    _lat.text = s.latitude?.toStringAsFixed(4) ?? '';
    _lng.text = s.longitude?.toStringAsFixed(4) ?? '';
    _locName.text = s.locationName;
    if (mounted) setState(() {});
  }

  Future<void> _reset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Reset everything?'),
        content: const Text('This deletes all your history, settings, API key and diagnostics. '
            'Automatic backups stay on this phone, so you can still restore one.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Reset')),
        ],
      ),
    );
    if (ok != true) return;
    await state.resetAll();
    await _diagnostics.clear();
    _apiKey.clear();
    _model.text = s.model;
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
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('$v $unit', style: Theme.of(c).textTheme.headlineMedium),
            Slider(value: v.toDouble(), min: min.toDouble(), max: max.toDouble(), divisions: max - min, onChanged: (x) => set(() => v = x.round())),
          ]),
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
            child: Text('Settings', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
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
          SwitchListTile(
            secondary: const Icon(Icons.volume_up_outlined),
            title: const Text('Loud alarm'),
            subtitle: const Text('Full-screen alarm that keeps ringing until you tap "I\'m up"'),
            value: s.wakeAlarmLoud,
            onChanged: (v) => state.updateSettings((x) => x.wakeAlarmLoud = v),
          ),

          _header('Prayer times'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              FilledButton.tonalIcon(
                onPressed: _locating ? null : _useMyLocation,
                icon: _locating
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.my_location),
                label: const Text('Use my current location'),
              ),
              const SizedBox(height: 12),
              TextField(controller: _locName, decoration: const InputDecoration(labelText: 'Place name (optional)', border: OutlineInputBorder())),
              const SizedBox(height: 8),
              Row(children: [
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
              ]),
              Align(alignment: Alignment.centerRight, child: TextButton(onPressed: _saveLocation, child: const Text('Save location'))),
              DropdownButtonFormField<String>(
                initialValue: s.calcMethod,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Calculation method', border: OutlineInputBorder()),
                items: [for (final e in calcMethodLabels.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
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
            ]),
          ),
          SwitchListTile(
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

          _header('Streaks'),
          ListTile(
            leading: const Icon(Icons.ac_unit),
            title: const Text('Streak freezes per month'),
            subtitle: Text('${s.freezesPerMonth} missed ${s.freezesPerMonth == 1 ? 'day' : 'days'} a month keep your perfect-day streak'),
            onTap: () async {
              final v = await _pickNumber('Streak freezes per month', s.freezesPerMonth, 0, 10);
              if (v != null) await state.updateSettings((x) => x.freezesPerMonth = v);
            },
          ),

          _header('Reminders'),
          SwitchListTile(
            secondary: const Icon(Icons.notifications_active_outlined),
            title: const Text('Reminders'),
            subtitle: const Text('Wake-up alarm, each prayer, habits and tasks'),
            value: s.remindersEnabled,
            onChanged: (v) => state.updateSettings((x) => x.remindersEnabled = v),
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
            child: Wrap(spacing: 8, children: [
              OutlinedButton(
                onPressed: () async {
                  final ok = await state.notifications.requestPermissions();
                  await state.rescheduleNow();
                  _snack(ok ? 'Notifications allowed.' : 'Notifications are blocked. Enable them in system settings.');
                },
                child: const Text('Grant permissions'),
              ),
              OutlinedButton(onPressed: () => state.notifications.showTest(s), child: const Text('Send test notification')),
            ]),
          ),

          _header('AI coach (OpenRouter)'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
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
                    icon: Icon(_hideKey ? Icons.visibility : Icons.visibility_off),
                    onPressed: () => setState(() => _hideKey = !_hideKey),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _model,
                autocorrect: false,
                onSubmitted: (v) => state.updateSettings((x) => x.model = v.trim().isEmpty ? x.model : v.trim()),
                decoration: InputDecoration(
                  labelText: 'Model',
                  helperText: 'Any model ID from openrouter.ai/models',
                  border: const OutlineInputBorder(),
                  suffixIcon: PopupMenuButton<String>(
                    icon: const Icon(Icons.arrow_drop_down),
                    onSelected: (v) {
                      _model.text = v;
                      state.updateSettings((x) => x.model = v);
                    },
                    itemBuilder: (_) => [for (final m in _suggestedModels) PopupMenuItem(value: m, child: Text(m))],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(children: [
                OutlinedButton(onPressed: _testAi, child: const Text('Save & test')),
                const SizedBox(width: 12),
                Expanded(child: Text(_aiStatus, style: Theme.of(context).textTheme.bodySmall)),
              ]),
            ]),
          ),

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
          SwitchListTile(
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
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => DiagnosticsScreen(diagnostics: _diagnostics)),
              );
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

  Widget _header(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 4),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );
}
