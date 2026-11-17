import 'package:app_settings/app_settings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';

import '../agent/habit_templates.dart';
import '../app_state.dart';
import 'settings_screen.dart';

/// True for a fresh install: onboarding not finished and nothing logged
/// yet. Existing installs (with settings, logs or tasks) skip it.
bool needsOnboarding(AppState state) => !state.settings.onboarded && state.logs.isEmpty && state.tasks.isEmpty;

/// A city for picking prayer times without location permission.
class City {
  final String name;
  final String country;
  final double lat, lng;
  final String calcMethod;
  const City(this.name, this.country, this.lat, this.lng, this.calcMethod);
}

const cities = [
  City('Dubai', 'UAE', 25.2048, 55.2708, 'dubai'),
  City('Abu Dhabi', 'UAE', 24.4539, 54.3773, 'dubai'),
  City('Sharjah', 'UAE', 25.3463, 55.4209, 'dubai'),
  City('Ajman', 'UAE', 25.4052, 55.5136, 'dubai'),
  City('Al Ain', 'UAE', 24.2075, 55.7447, 'dubai'),
  City('Ras Al Khaimah', 'UAE', 25.8007, 55.9762, 'dubai'),
  City('Fujairah', 'UAE', 25.1288, 56.3265, 'dubai'),
  City('Riyadh', 'Saudi Arabia', 24.7136, 46.6753, 'umm_al_qura'),
  City('Jeddah', 'Saudi Arabia', 21.4858, 39.1925, 'umm_al_qura'),
  City('Makkah', 'Saudi Arabia', 21.3891, 39.8579, 'umm_al_qura'),
  City('Madinah', 'Saudi Arabia', 24.5247, 39.5692, 'umm_al_qura'),
  City('Doha', 'Qatar', 25.2854, 51.5310, 'qatar'),
  City('Kuwait City', 'Kuwait', 29.3759, 47.9774, 'kuwait'),
  City('Manama', 'Bahrain', 26.2235, 50.5876, 'dubai'),
  City('Muscat', 'Oman', 23.5880, 58.3829, 'dubai'),
  City('Cairo', 'Egypt', 30.0444, 31.2357, 'egyptian'),
  City('Istanbul', 'Turkey', 41.0082, 28.9784, 'turkey'),
  City('Tehran', 'Iran', 35.6892, 51.3890, 'tehran'),
  City('Karachi', 'Pakistan', 24.8607, 67.0011, 'karachi'),
  City('Lahore', 'Pakistan', 31.5204, 74.3587, 'karachi'),
  City('Delhi', 'India', 28.6139, 77.2090, 'karachi'),
  City('Mumbai', 'India', 19.0760, 72.8777, 'karachi'),
  City('Kozhikode', 'India', 11.2588, 75.7804, 'karachi'),
  City('Hyderabad', 'India', 17.3850, 78.4867, 'karachi'),
  City('Dhaka', 'Bangladesh', 23.8103, 90.4125, 'karachi'),
  City('Kuala Lumpur', 'Malaysia', 3.1390, 101.6869, 'singapore'),
  City('Singapore', 'Singapore', 1.3521, 103.8198, 'singapore'),
  City('Jakarta', 'Indonesia', -6.2088, 106.8456, 'singapore'),
  City('London', 'UK', 51.5074, -0.1278, 'muslim_world_league'),
  City('Paris', 'France', 48.8566, 2.3522, 'muslim_world_league'),
  City('Berlin', 'Germany', 52.5200, 13.4050, 'muslim_world_league'),
  City('New York', 'USA', 40.7128, -74.0060, 'north_america'),
  City('Toronto', 'Canada', 43.6532, -79.3832, 'north_america'),
  City('Sydney', 'Australia', -33.8688, 151.2093, 'muslim_world_league'),
];

/// Battery-optimisation guidance for phone makers known to stop reminders.
const batteryTips = {
  'Xiaomi / Redmi / POCO':
      'Settings › Apps › Daily Discipline › Battery saver › No restrictions. Also turn on Autostart for the app.',
  'Samsung':
      'Settings › Apps › Daily Discipline › Battery › Unrestricted. Then make sure it is not in Battery › Background usage limits › Sleeping apps.',
  'Huawei / Honor':
      'Settings › Battery › App launch › Daily Discipline: turn off "Manage automatically" and allow Auto-launch, Secondary launch and Run in background.',
};

/// First-run setup: welcome, location, notifications (+ exact alarms and a
/// battery tip), wake time and sleep goal, starter habits, optional AI key.
/// Finishing sets `Settings.onboarded`.
class OnboardingScreen extends StatefulWidget {
  final AppState state;
  const OnboardingScreen({super.key, required this.state});

  static const steps = ['Welcome', 'Location', 'Reminders', 'Sleep', 'Habits', 'AI coach'];

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  int _step = 0;
  final _picked = <String>{};
  bool _finishing = false;

  AppState get state => widget.state;
  bool get _last => _step == OnboardingScreen.steps.length - 1;

  void _next() => _last ? _finish() : setState(() => _step++);
  void _back() => setState(() => _step--);

  Future<void> _finish() async {
    if (_finishing) return;
    setState(() => _finishing = true);
    for (final t in habitTemplates) {
      if (_picked.contains(t.id) && !state.habits.any((h) => h.templateId == t.id)) {
        await state.upsertHabit(habitFromTemplate(t));
      }
    }
    await state.updateSettings((s) => s.onboarded = true);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final optional = _step == 1 || _step == 2 || _last;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
              child: Row(
                children: [
                  for (var i = 0; i < OnboardingScreen.steps.length; i++)
                    Expanded(
                      child: Container(
                        height: 4,
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        decoration: BoxDecoration(
                          color: i <= _step ? t.colorScheme.primary : t.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: ListenableBuilder(
                listenable: state,
                builder: (context, _) => ListView(
                  key: ValueKey(_step),
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
                  children: switch (_step) {
                    0 => _welcome(t),
                    1 => [_LocationStep(state: state)],
                    2 => [_RemindersStep(state: state)],
                    3 => _sleep(t),
                    4 => _habits(t),
                    _ => _ai(t),
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(
                children: [
                  if (_step > 0) TextButton(onPressed: _finishing ? null : _back, child: const Text('Back')),
                  Expanded(
                    child: OverflowBar(
                      alignment: MainAxisAlignment.end,
                      overflowAlignment: OverflowBarAlignment.end,
                      spacing: 8,
                      children: [
                        if (optional)
                          TextButton(onPressed: _finishing ? null : _next, child: Text(_last ? 'Skip' : 'Not now')),
                        FilledButton(
                          style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
                          onPressed: _finishing ? null : _next,
                          child: Text(switch (_step) {
                            0 => 'Get started',
                            _ when _last => 'Finish',
                            _ => 'Continue',
                          }),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _welcome(ThemeData t) => [
    const SizedBox(height: 32),
    const Text('🌅', textAlign: TextAlign.center, style: TextStyle(fontSize: 72)),
    const SizedBox(height: 16),
    Text(
      'Daily Discipline',
      textAlign: TextAlign.center,
      style: t.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
    ),
    const SizedBox(height: 12),
    Text(
      'Wake up early, pray the five prayers on time and keep the habits that matter to you. '
      'Setup takes about a minute.',
      textAlign: TextAlign.center,
      style: t.textTheme.bodyLarge,
    ),
    const SizedBox(height: 24),
    for (final (icon, text) in [
      (Icons.alarm, 'A wake-up alarm you have to answer'),
      (Icons.mosque_outlined, 'Prayer times for where you are, with reminders'),
      (Icons.checklist, 'Habits and tasks with forgiving streaks'),
      (Icons.auto_awesome_outlined, 'An optional AI coach that builds habits for you'),
    ])
      ListTile(
        leading: Icon(icon, color: t.colorScheme.primary),
        title: Text(text),
      ),
  ];

  List<Widget> _sleep(ThemeData t) {
    final s = state.settings;
    final wake = DateTime(2000, 1, 2, s.wakeTime.hour, s.wakeTime.minute);
    final bed = wake.subtract(Duration(minutes: (s.sleepHours * 60).round()));
    String fmt(DateTime d) => DateFormat.jm().format(d);
    final hours = s.sleepHours == s.sleepHours.roundToDouble() ? '${s.sleepHours.toInt()}' : '${s.sleepHours}';
    return [
      _Title(
        'When do you want to wake up?',
        'Your wake-up alarm rings at this time. You can change it any time in Settings.',
      ),
      Card(
        child: ListTile(
          leading: const Icon(Icons.alarm),
          title: const Text('Wake-up time'),
          trailing: Text(fmt(wake), style: t.textTheme.titleLarge),
          onTap: () async {
            final v = await showTimePicker(context: context, initialTime: s.wakeTime);
            if (v != null) await state.updateSettings((x) => x.wakeTime = v);
          },
        ),
      ),
      const SizedBox(height: 16),
      Text('Sleep goal: $hours hours', style: t.textTheme.titleMedium),
      Slider.adaptive(
        value: s.sleepHours.clamp(5, 10),
        min: 5,
        max: 10,
        divisions: 10,
        label: '$hours h',
        onChanged: (v) => state.updateSettings((x) => x.sleepHours = v),
      ),
      Text('To wake at ${fmt(wake)} rested, be asleep by about ${fmt(bed)}.', style: t.textTheme.bodyMedium),
    ];
  }

  List<Widget> _habits(ThemeData t) => [
    _Title(
      'Pick a few starter habits',
      'They work offline, no AI needed. You can add, edit or archive habits later in Plan.',
    ),
    for (final h in habitTemplates)
      Card(
        child: CheckboxListTile.adaptive(
          value: _picked.contains(h.id),
          onChanged: (v) => setState(() => v == true ? _picked.add(h.id) : _picked.remove(h.id)),
          secondary: Text(h.emoji, style: const TextStyle(fontSize: 28)),
          title: Text(h.title),
          subtitle: Text(h.description),
        ),
      ),
  ];

  List<Widget> _ai(ThemeData t) => [
    _Title(
      'AI coach (optional)',
      'With your own OpenRouter key the coach can build habits with their own practice screens, '
          'review your sessions and plan tasks. Skip this and everything else still works; '
          'you can add a key later in Settings.',
    ),
    AiKeySection(state: state, showModel: false),
  ];
}

class _Title extends StatelessWidget {
  final String title, subtitle;
  const _Title(this.title, this.subtitle);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(subtitle, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _LocationStep extends StatefulWidget {
  final AppState state;
  const _LocationStep({required this.state});

  @override
  State<_LocationStep> createState() => _LocationStepState();
}

class _LocationStepState extends State<_LocationStep> {
  final _search = TextEditingController();
  bool _locating = false;
  bool _showCities = false;
  String _message = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _useLocation() async {
    setState(() {
      _locating = true;
      _message = '';
    });
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _fallback('Location services are off. Pick your city instead, or turn them on and try again.');
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        _fallback('Location permission was denied. Pick your city instead.');
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.low, timeLimit: Duration(seconds: 20)),
      );
      await widget.state.updateSettings((s) {
        s.latitude = pos.latitude;
        s.longitude = pos.longitude;
        s.locationName = 'My location';
      });
    } catch (_) {
      _fallback('Could not get your location. Pick your city instead.');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  void _fallback(String message) {
    if (mounted) {
      setState(() {
        _message = message;
        _showCities = true;
      });
    }
  }

  Future<void> _pick(City c) async {
    await widget.state.updateSettings((s) {
      s.latitude = c.lat;
      s.longitude = c.lng;
      s.locationName = c.name;
      s.calcMethod = c.calcMethod;
    });
    if (mounted) setState(() => _showCities = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = widget.state.settings;
    final q = _search.text.trim().toLowerCase();
    final matches = cities.where((c) => q.isEmpty || '${c.name} ${c.country}'.toLowerCase().contains(q)).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Title(
          'Where do you pray?',
          'Prayer times are calculated on your phone from your location. It never leaves the device.',
        ),
        if (s.hasLocation)
          Card(
            child: ListTile(
              leading: Icon(Icons.check_circle, color: t.colorScheme.primary),
              title: Text(s.locationName.isEmpty ? 'Location set' : s.locationName),
              subtitle: Text('${s.latitude!.toStringAsFixed(2)}, ${s.longitude!.toStringAsFixed(2)}'),
            ),
          ),
        FilledButton.tonalIcon(
          onPressed: _locating ? null : _useLocation,
          icon: _locating
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator.adaptive(strokeWidth: 2))
              : const Icon(Icons.my_location),
          label: const Text('Use my location'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => setState(() => _showCities = !_showCities),
          icon: const Icon(Icons.location_city),
          label: const Text('Choose my city'),
        ),
        if (_message.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_message, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.error)),
          ),
        if (_showCities) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search city',
              border: OutlineInputBorder(),
            ),
          ),
          for (final c in matches.take(12))
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(c.name),
              subtitle: Text(c.country),
              onTap: () => _pick(c),
            ),
          if (matches.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Not in the list? Enter your coordinates later in Settings › Prayer times.'),
            ),
        ],
      ],
    );
  }
}

class _RemindersStep extends StatefulWidget {
  final AppState state;
  const _RemindersStep({required this.state});

  @override
  State<_RemindersStep> createState() => _RemindersStepState();
}

class _RemindersStepState extends State<_RemindersStep> {
  bool? _allowed;

  Future<void> _allow() async {
    final n = widget.state.notifications;
    bool ok;
    try {
      ok = await n.requestPermissions();
      await widget.state.rescheduleNow();
    } catch (_) {
      ok = false;
    }
    if (mounted) setState(() => _allowed = ok);
  }

  Future<void> _openBattery() async {
    try {
      await AppSettings.openAppSettings(type: AppSettingsType.batteryOptimization);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Open your phone\'s Settings › Battery to change this.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final android = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Title(
          'Reminders that actually ring',
          'Allow notifications for the wake-up alarm, prayer and habit reminders. '
              'On Android you will also be asked to allow exact alarms, so the alarm rings on the minute.',
        ),
        FilledButton.icon(
          onPressed: _allow,
          icon: const Icon(Icons.notifications_active_outlined),
          label: const Text('Allow notifications and alarms'),
        ),
        if (_allowed != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _allowed!
                  ? '✅ Notifications allowed.'
                  : 'Notifications are blocked. You can allow them later in system settings.',
              style: t.textTheme.bodyMedium,
            ),
          ),
        if (android) ...[
          const SizedBox(height: 24),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(Icons.battery_alert_outlined, color: t.colorScheme.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Battery tip',
                          style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Some phones stop apps in the background to save battery, which can silence alarms. '
                    'Set Daily Discipline to "Unrestricted" / "Don\'t optimise".',
                  ),
                  for (final e in batteryTips.entries)
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: const EdgeInsets.only(bottom: 8),
                      title: Text(e.key),
                      children: [Text(e.value)],
                    ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _openBattery,
                    icon: const Icon(Icons.settings_outlined),
                    label: const Text('Open battery settings'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}
