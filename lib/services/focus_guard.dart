/// Focus (Android only): pauses apps the user chose once their daily limit
/// is used up, and during sleep time.
///
/// The native `FocusGuardService` (an Accessibility service that only sees
/// which app is in front) counts time in the chosen apps and shows
/// `PauseActivity` over them. This side writes its config ([focusConfig])
/// after every settings change and reads back the day's usage.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../logic/sleep.dart';
import '../logic/stats.dart';
import '../models.dart';

class InstalledApp {
  final String package, name;
  final Uint8List? icon;
  const InstalledApp(this.package, this.name, [this.icon]);
}

/// Time in front and times opened for one app on one day.
class AppUsage {
  final Duration time;
  final int opens;
  const AppUsage(this.time, this.opens);
  static const none = AppUsage(Duration.zero, 0);
}

/// The config the native service reads: the chosen apps and their limits,
/// and tonight's sleep window as minutes of the day.
Map<String, dynamic> focusConfig(Settings s, DateTime now) {
  final day = dateOnly(now);
  final bed = bedtimeFor(s, day);
  final wake = wakeGoalOn(s, day);
  return {
    'enabled': s.focusEnabled,
    'apps': {
      for (final a in s.focusApps) a.package: {'name': a.name, 'limit': a.limitMin},
    },
    'sleep': s.focusSleep,
    'bedMin': bed.hour * 60 + bed.minute,
    'wakeMin': wake.hour * 60 + wake.minute,
    'strict': s.focusStrict,
    'wakeLabel': DateFormat.jm().format(wake),
  };
}

/// "10:30 PM – 5:00 AM".
String focusSleepWindow(Settings s, {bool use24Hour = false}) {
  final day = dateOnly(DateTime.now());
  final fmt = use24Hour ? DateFormat.Hm() : DateFormat.jm();
  return '${fmt.format(bedtimeFor(s, day))} – ${fmt.format(wakeGoalOn(s, day))}';
}

/// "25 min", "1 h 5 min".
String fmtUsage(Duration d) {
  final m = d.inMinutes;
  return m < 60 ? '$m min' : '${m ~/ 60} h${m % 60 == 0 ? '' : ' ${m % 60} min'}';
}

/// Separates Android's saved accessibility grant from a bound service and
/// rules actually loaded by that service.
class FocusReadiness {
  final bool permission, running;
  final Set<String> protected;
  const FocusReadiness(this.permission, this.running, this.protected);

  bool protects(FocusApp app) => permission && running && protected.contains(app.package);
}

String focusStatus(Settings s, FocusReadiness? device) {
  final n = s.focusApps.length;
  if (n == 0) return 'Choose apps and set their limits';
  final selected = '$n ${n == 1 ? 'app' : 'apps'} selected';
  if (!s.focusEnabled) return '$selected · protection off';
  if (device == null) return '$selected · protection unconfirmed';
  if (!device.permission) return '$selected · permission needed';
  if (!device.running) return '$selected · service stopped';
  final active = s.focusApps.where(device.protects).length;
  if (active == 0) return '$selected · no active pause rules';
  return active == n ? '$selected · protection active' : '$active of $n selected apps protected';
}

abstract class FocusGuard {
  /// Replaced in tests.
  static FocusGuard instance = ChannelFocusGuard();

  static final configRevision = ValueNotifier(0);
  bool get supported;

  /// The Accessibility service is switched on in Android settings.
  Future<FocusReadiness> readiness();
  Future<bool> testPause(String package);
  Future<void> openAccessibilitySettings();

  /// App info, where "Allow restricted settings" is for sideloaded apps.
  Future<void> openAppInfo();
  Future<List<InstalledApp>> apps();
  Future<void> configure(Settings s);
  Future<Map<String, AppUsage>> usage([DateTime? day]);
}

class ChannelFocusGuard implements FocusGuard {
  static const _ch = MethodChannel('daily_discipline/focus');
  List<InstalledApp>? _apps;

  @override
  bool get supported => !kIsWeb && Platform.isAndroid;

  @override
  Future<FocusReadiness> readiness() async {
    if (!supported) return const FocusReadiness(false, false, {});
    final raw = await _ch.invokeMapMethod<String, dynamic>('readiness') ?? {};
    return FocusReadiness(raw['permission'] == true, raw['running'] == true,
        Set<String>.from(raw['protected'] as List? ?? []));
  }

  @override
  Future<bool> testPause(String package) async =>
      supported && (await _ch.invokeMethod<bool>('testPause', package) ?? false);

  @override
  Future<void> openAccessibilitySettings() => _ch.invokeMethod('openAccessibilitySettings');

  @override
  Future<void> openAppInfo() => _ch.invokeMethod('openAppInfo');

  @override
  Future<List<InstalledApp>> apps() async {
    if (!supported) return const [];
    return _apps ??= [
      for (final a in await _ch.invokeListMethod<Map>('apps') ?? const <Map>[])
        InstalledApp(a['package'] as String, a['name'] as String, a['icon'] as Uint8List?),
    ];
  }

  @override
  Future<void> configure(Settings s) async {
    if (!supported) return;
    await _ch.invokeMethod('configure', jsonEncode(focusConfig(s, DateTime.now())));
    FocusGuard.configRevision.value++;
  }

  @override
  Future<Map<String, AppUsage>> usage([DateTime? day]) async {
    if (!supported) return const {};
    final raw = await _ch.invokeMethod<String>('usage', DateFormat('yyyy-MM-dd').format(day ?? DateTime.now()));
    final j = jsonDecode(raw ?? '{}') as Map<String, dynamic>;
    return {
      for (final e in j.entries)
        e.key: AppUsage(
          Duration(milliseconds: ((e.value as Map)['ms'] as num?)?.toInt() ?? 0),
          ((e.value as Map)['o'] as num?)?.toInt() ?? 0,
        ),
    };
  }
}
