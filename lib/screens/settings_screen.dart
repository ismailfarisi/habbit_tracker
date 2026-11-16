import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../logic/prayer_status.dart';
import '../models.dart';
import '../logic/sleep.dart';
import '../services/openrouter.dart';
import 'reminders_screen.dart';
import 'wake_challenge_screen.dart';

const _suggestedModels = [
  'openai/gpt-4o-mini',
  'anthropic/claude-sonnet-4.5',
  'google/gemini-2.5-flash',
  'deepseek/deepseek-chat',
  'meta-llama/llama-3.3-70b-instruct:free',
];

class SettingsScreen extends StatefulWidget {
  final AppState state;
  const SettingsScreen({super.key, required this.state});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final _lat = TextEditingController(text: widget.state.settings.latitude?.toStringAsFixed(4) ?? '');
  late final _lng = TextEditingController(text: widget.state.settings.longitude?.toStringAsFixed(4) ?? '');
  late final _locName = TextEditingController(text: widget.state.settings.locationName);
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

  Future<void> _import() async {
    final ctl = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Import backup'),
        content: TextField(
          controller: ctl,
          maxLines: 8,
          decoration: const InputDecoration(hintText: 'Paste backup JSON here'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, ctl.text), child: const Text('Import')),
        ],
      ),
    );
    ctl.dispose();
    if (raw == null || raw.trim().isEmpty) return;
    try {
      await state.importBackup(raw);
      _snack('Backup restored.');
      setState(() {});
    } catch (e) {
      _snack('Import failed: $e');
    }
  }

  Future<void> _reset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Reset everything?'),
        content: const Text('This deletes all your history, settings and API key.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Reset')),
        ],
      ),
    );
    if (ok != true) return;
    await state.resetAll();
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
              Slider(
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
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
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
          SwitchListTile(
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
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => RemindersScreen(state: state)),
            ),
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
                  onPressed: () => state.notifications.showTest(s),
                  child: const Text('Send test notification'),
                ),
              ],
            ),
          ),

          _header('AI coach (OpenRouter)'),
          AiKeySection(state: state),

          _header('Data'),
          ListTile(
            leading: const Icon(Icons.upload_outlined),
            title: const Text('Export backup'),
            subtitle: const Text('Copies your history and settings to the clipboard'),
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: state.storage.exportJson()));
              _snack('Backup copied to clipboard.');
            },
          ),
          ListTile(leading: const Icon(Icons.download_outlined), title: const Text('Import backup'), onTap: _import),
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
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(fmtSleepHours(v), style: Theme.of(c).textTheme.headlineMedium),
            Slider(value: v, min: 5, max: 10, divisions: 20, onChanged: (x) => set(() => v = x)),
          ]),
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
        subtitle: Text(s.wakeChallenge == WakeChallenge.off
            ? 'Off. "I\'m up" counts right away'
            : '${_challengeLabels[s.wakeChallenge]} before "I\'m up" counts'),
        onTap: () async {
          final v = await showDialog<WakeChallenge>(
            context: context,
            builder: (c) => SimpleDialog(
              title: const Text('Prove you\'re up'),
              children: [
                for (final e in _challengeLabels.entries)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(c, e.key),
                    child: Row(children: [
                      Icon(e.key == s.wakeChallenge ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                      const SizedBox(width: 12),
                      Text(e.value),
                    ]),
                  ),
              ],
            ),
          );
          if (v != null) await state.updateSettings((x) => x.wakeChallenge = v);
        },
        trailing: s.wakeChallenge == WakeChallenge.off
            ? null
            : TextButton(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => WakeChallengeScreen(state: state, mode: s.wakeChallenge, practice: true),
                )),
                child: const Text('Try it'),
              ),
      ),
      ListTile(
        leading: const Icon(Icons.bedtime_outlined),
        title: const Text('Sleep goal'),
        subtitle: Text('${fmtSleepHours(s.sleepHours)} a night, bed by ${_fmt(TimeOfDay.fromDateTime(bedtimeFor(s, night)))}'),
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
      SwitchListTile(
        secondary: const Icon(Icons.nights_stay_outlined),
        title: const Text('Bedtime reminder'),
        subtitle: Text('Every night at ${_fmt(TimeOfDay.fromDateTime(windDownFor(s, night)))} with a "Going to bed" button'),
        value: s.bedtimeReminder,
        onChanged: (v) => state.updateSettings((x) => x.bedtimeReminder = v),
      ),
    ];
  }

  // ---------- Ramadan, Jumu'ah & sunnah prayers ----------
  Future<void> _pickJumuahTime() async {
    final choice = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(title: const Text("Jumu'ah time"), children: [
        SimpleDialogOption(onPressed: () => Navigator.pop(c, ''), child: const Text('Same as Dhuhr')),
        SimpleDialogOption(onPressed: () => Navigator.pop(c, '13:15'), child: const Text('1:15 PM (UAE mosques)')),
        SimpleDialogOption(onPressed: () => Navigator.pop(c, 'pick'), child: const Text('Pick a time…')),
      ]),
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
        subtitle: Text('Today: ${hijriToday(s, now)}'
            '${s.hijriOffsetDays == 0 ? '' : ' (${s.hijriOffsetDays > 0 ? '+' : ''}${s.hijriOffsetDays} days)'}'),
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
      SwitchListTile(
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
      SwitchListTile(
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
      SwitchListTile(
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
      SwitchListTile(
        secondary: const Icon(Icons.wb_sunny_outlined),
        title: const Text('Duha prayer'),
        subtitle: const Text('Optional, not counted in the 5-prayer streak'),
        value: s.sunnahDuha,
        onChanged: (v) => state.updateSettings((x) => x.sunnahDuha = v),
      ),
      SwitchListTile(
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
  const AiKeySection({super.key, required this.state, this.showModel = true});

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
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton(onPressed: _test, child: const Text('Save & test')),
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
