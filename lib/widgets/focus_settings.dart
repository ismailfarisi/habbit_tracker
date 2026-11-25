import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../models.dart';
import '../services/focus_guard.dart';
import 'adaptive.dart';

const focusLimitChoices = [0, 5, 10, 15, 20, 30, 45, 60, 90, 120];

String focusLimitLabel(int min) => min == 0 ? 'Sleep time only' : '${fmtUsage(Duration(minutes: min))} a day';

/// All Focus surfaces query the same native service state, including on return
/// from Accessibility settings. A grant can precede the actual service bind.
class FocusDeviceStatus extends StatefulWidget {
  final Widget Function(FocusReadiness?) builder;
  const FocusDeviceStatus({super.key, required this.builder});

  @override
  State<FocusDeviceStatus> createState() => _FocusDeviceStatusState();
}

class _FocusDeviceStatusState extends State<FocusDeviceStatus> with WidgetsBindingObserver {
  FocusReadiness? _current;
  Timer? _retry;
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    FocusGuard.configRevision.addListener(_refresh);
    _refresh();
  }

  @override
  void dispose() {
    _retry?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    FocusGuard.configRevision.removeListener(_refresh);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) {
      setState(() => _current = null);
      _refresh();
    } else {
      _revision++;
      _retry?.cancel();
    }
  }

  Future<void> _refresh() async {
    final revision = ++_revision;
    _retry?.cancel();
    FocusReadiness? result;
    try {
      result = await FocusGuard.instance.readiness();
    } on PlatformException {
      // Leave protection unconfirmed when Android cannot report it.
    }
    if (!mounted || revision != _revision) return;
    setState(() => _current = result);
    if (result != null && result.permission && !result.running) {
      _retry = Timer(const Duration(seconds: 3), _refresh);
    }
  }

  @override
  Widget build(BuildContext context) => widget.builder(_current);
}

/// Settings → Focus & screen time: turning on the Accessibility service,
/// the chosen apps and their daily limits, the sleep-time block and strict mode.
class FocusSettingsSection extends StatefulWidget {
  final AppState state;
  const FocusSettingsSection({super.key, required this.state});

  @override
  State<FocusSettingsSection> createState() => _FocusSettingsSectionState();
}

class _FocusSettingsSectionState extends State<FocusSettingsSection> with WidgetsBindingObserver {
  FocusGuard get _guard => FocusGuard.instance;
  Map<String, AppUsage> _usage = const {};
  Map<String, InstalledApp> _installed = const {};

  AppState get state => widget.state;
  Settings get s => state.settings;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    _guard.apps().then((a) {
      if (mounted) setState(() => _installed = {for (final x in a) x.package: x});
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final u = await _guard.usage();
    if (mounted) {
      setState(() {
        _usage = u;
      });
    }
  }

  Future<void> _setApps(List<FocusApp> apps) => state.updateSettings((x) => x.focusApps = apps);

  Future<void> _turnOn() async {
    final ok = await confirmDialog(
      context,
      title: 'Allow app pausing?',
      message:
          'Daily Discipline uses Android\'s Accessibility permission to see which app is open, so it can '
          'pause the apps you chose. It never reads what is on the screen, and nothing leaves your phone.\n\n'
          'On the next screen, tap "Daily Discipline app pause" and switch it on.',
      confirm: 'Open settings',
    );
    if (ok) await _guard.openAccessibilitySettings();
  }

  Future<void> _restricted() async {
    final ok = await confirmDialog(
      context,
      title: 'Switch greyed out?',
      message:
          'Android blocks this switch for apps installed from a file until you allow it:\n\n'
          '1. Tap "Open app info".\n'
          '2. Tap ⋮ at the top right, then "Allow restricted settings".\n'
          '3. Come back and tap "Turn on" again.',
      confirm: 'Open app info',
    );
    if (ok) await _guard.openAppInfo();
  }

  Future<void> _pickLimit(FocusApp app) async {
    final v = await showDialog<int>(
      context: context,
      builder: (c) => SimpleDialog(
        title: Text('${app.name}: daily limit'),
        children: [
          RadioGroup<int>(
            groupValue: app.limitMin,
            onChanged: (v) => Navigator.pop(c, v),
            child: Column(
              children: [
                for (final m in focusLimitChoices)
                  RadioListTile<int>(
                    value: m,
                    title: Text(m == 0 ? 'No daily limit (sleep time only)' : fmtUsage(Duration(minutes: m))),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (v == null) return;
    await _setApps([for (final a in s.focusApps) a.package == app.package ? a.withLimit(v) : a]);
  }

  Future<void> _addApps() async {
    final all = await _guard.apps();
    if (!mounted) return;
    final chosen = {for (final a in s.focusApps) a.package};
    final picked = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => _AppPicker(apps: all, initial: chosen),
    );
    if (picked == null) return;
    await _setApps([
      for (final a in s.focusApps)
        if (picked.contains(a.package)) a,
      for (final a in all)
        if (picked.contains(a.package) && !chosen.contains(a.package)) FocusApp(a.package, a.name),
    ]);
  }

  Widget _icon(String pkg) {
    final icon = _installed[pkg]?.icon;
    return icon == null ? const Icon(Icons.apps) : Image.memory(icon, width: 32, height: 32);
  }

  Widget _header(String t) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(
      t,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (!_guard.supported) {
      return const ListTile(
        leading: Icon(Icons.phone_iphone),
        title: Text('Set up Screen Time on iPhone'),
        subtitle: Text('Open Settings → Screen Time → App & Website Activity. Use App Limits for daily limits, '
            'Downtime for sleep hours, and Always Allowed for essential apps.'),
      );
    }
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => FocusDeviceStatus(builder: (device) {
        final t = Theme.of(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                'Choose the apps you lose time in. Once an app\'s daily limit is used up, or at sleep time, '
                'opening it shows a short pause with a reminder instead.',
                style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.shield_outlined),
              title: Text(focusStatus(s, device)),
              subtitle: Text(s.focusSleep
                  ? 'Tonight: ${focusSleepWindow(s, use24Hour: MediaQuery.alwaysUse24HourFormatOf(context))} · from your wake-up time and sleep goal'
                  : 'Sleep-time pausing is off'),
            ),
            if (device != null && (!device.permission || !device.running))
              Card(
                key: const Key('focus-setup'),
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                color: t.colorScheme.tertiaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(device.permission ? 'Accessibility service stopped' : 'Turn on app pausing', style: t.textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text(
                        device.permission ? 'Open Accessibility settings and restart Daily Discipline app pause.' : 'Needs Android\'s Accessibility permission. It only sees which app is open, '
                        'never what\'s on the screen.',
                        style: t.textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        children: [
                          FilledButton(style: compactButton, onPressed: _turnOn, child: const Text('Turn on')),
                          TextButton(
                            style: compactButton,
                            onPressed: _restricted,
                            child: const Text('Switch greyed out?'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              )
            else if (device != null && device.running && device.permission)
              ListTile(
                leading: const Icon(Icons.verified_user_outlined),
                title: const Text('Accessibility service running'),
                subtitle: const Text('Android Accessibility → Daily Discipline app pause'),
                onTap: _guard.openAccessibilitySettings,
              ),
            if (s.focusEnabled && device != null && s.focusApps.any(device.protects))
              Builder(builder: (context) {
                final app = s.focusApps.firstWhere(device.protects);
                return ListTile(
                  leading: const Icon(Icons.pause_circle_outline),
                  title: const Text('Test pause'),
                  subtitle: Text('Open ${app.name} for one pause. Its limit and extra minutes stay the same.'),
                  onTap: () async {
                    final opened = await _guard.testPause(app.package);
                    if (!opened && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('Could not start the test. Check the app and Accessibility service.'),
                      ));
                    }
                  },
                );
              }),
            SwitchListTile.adaptive(
              secondary: const Icon(Icons.hourglass_bottom),
              title: const Text('Pause chosen apps'),
              value: s.focusEnabled,
              onChanged: (v) => state.updateSettings((x) => x.focusEnabled = v),
            ),
            _header('Apps'),
            if (s.focusApps.isEmpty) const ListTile(title: Text('No apps chosen yet')),
            for (final a in s.focusApps)
              ListTile(
                key: ValueKey('focus-app-${a.package}'),
                leading: _icon(a.package),
                title: Text(a.name),
                subtitle: Text(
                  '${focusLimitLabel(a.limitMin)} · ${fmtUsage((_usage[a.package] ?? AppUsage.none).time)} used today',
                ),
                onTap: () => _pickLimit(a),
                trailing: IconButton(
                  tooltip: 'Remove ${a.name}',
                  icon: const Icon(Icons.close),
                  onPressed: () => _setApps([...s.focusApps.where((x) => x.package != a.package)]),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  style: compactButton,
                  onPressed: _addApps,
                  icon: const Icon(Icons.add),
                  label: const Text('Choose apps'),
                ),
              ),
            ),
            _header('Sleep time'),
            SwitchListTile.adaptive(
              secondary: const Icon(Icons.bedtime_outlined),
              title: const Text('Pause them during sleep time'),
              subtitle: const Text('Apply the sleep window to every selected app, including apps without a daily limit.'),
              value: s.focusSleep,
              onChanged: (v) => state.updateSettings((x) => x.focusSleep = v),
            ),
            _header('Pause screen'),
            SwitchListTile.adaptive(
              secondary: const Icon(Icons.lock_clock_outlined),
              title: const Text('Strict mode'),
              subtitle: const Text('No "5 more minutes". Without it, you get 5 more minutes once a day per app.'),
              value: s.focusStrict,
              onChanged: (v) => state.updateSettings((x) => x.focusStrict = v),
            ),
          ],
        );
      }),
    );
  }
}

class _AppPicker extends StatefulWidget {
  final List<InstalledApp> apps;
  final Set<String> initial;
  const _AppPicker({required this.apps, required this.initial});

  @override
  State<_AppPicker> createState() => _AppPickerState();
}

class _AppPickerState extends State<_AppPicker> {
  late final _picked = {...widget.initial};
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final shown = widget.apps.where((a) => a.name.toLowerCase().contains(_q.toLowerCase())).toList();
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.8,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search apps',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _q = v),
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                for (final a in shown)
                  CheckboxListTile(
                    key: ValueKey('pick-${a.package}'),
                    secondary: a.icon == null ? const Icon(Icons.apps) : Image.memory(a.icon!, width: 32, height: 32),
                    title: Text(a.name),
                    value: _picked.contains(a.package),
                    onChanged: (v) => setState(() => v == true ? _picked.add(a.package) : _picked.remove(a.package)),
                  ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton(
                style: primaryButton,
                onPressed: () => Navigator.pop(context, _picked),
                child: Text('Done · ${_picked.length} chosen'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Progress → Screen time today: minutes in each chosen app against its
/// limit, and how often it was opened.
class ScreenTimeCard extends StatefulWidget {
  final AppState state;
  const ScreenTimeCard({super.key, required this.state});

  @override
  State<ScreenTimeCard> createState() => _ScreenTimeCardState();
}

class _ScreenTimeCardState extends State<ScreenTimeCard> with WidgetsBindingObserver {
  Map<String, AppUsage> _usage = const {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final u = await FocusGuard.instance.usage();
    if (mounted) setState(() => _usage = u);
  }

  @override
  Widget build(BuildContext context) {
    final apps = widget.state.settings.focusApps;
    if (!FocusGuard.instance.supported || apps.isEmpty) return const SizedBox.shrink();
    final t = Theme.of(context);
    return FocusDeviceStatus(builder: (device) => Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Screen time today', style: t.textTheme.titleMedium),
            Text(focusStatus(widget.state.settings, device)),
            for (final a in apps) ...[
              const SizedBox(height: 12),
              Builder(
                builder: (context) {
                  final u = _usage[a.package] ?? AppUsage.none;
                  final limit = Duration(minutes: a.limitMin);
                  final over = a.limitMin > 0 && u.time >= limit;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(child: Text(a.name, style: t.textTheme.bodyLarge)),
                          CountBadge(a.limitMin == 0 ? fmtUsage(u.time) : '${fmtUsage(u.time)} / ${fmtUsage(limit)}'),
                        ],
                      ),
                      const SizedBox(height: 6),
                      if (a.limitMin > 0)
                        LinearProgressIndicator(
                          value: (u.time.inSeconds / limit.inSeconds).clamp(0.0, 1.0),
                          color: over ? t.colorScheme.tertiary : null,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      const SizedBox(height: 4),
                      Text(
                        'Opened ${u.opens} ${u.opens == 1 ? 'time' : 'times'}${over ? ' · daily limit reached' : ''}',
                        style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  );
                },
              ),
            ],
          ],
        ),
      ),
    ));
  }
}
