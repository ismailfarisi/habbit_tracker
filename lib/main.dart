import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'app_state.dart';
import 'screens/home_screen.dart';
import 'screens/onboarding_screen.dart';
import 'services/backup_service.dart';
import 'services/diagnostics.dart';
import 'services/notification_service.dart';
import 'services/storage.dart';
import 'services/tts.dart' show speakingEngine, stopSpeaking, voiceNotice;
import 'services/voice_input.dart' show confirmPhoneFallback, finishDictation, listeningEngine;

final _navigator = GlobalKey<NavigatorState>();

Future<bool> _confirmFallback() async {
  final context = _navigator.currentContext;
  if (context == null) return false;
  return await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Use phone recognition this time?'),
      content: const Text('Whisper is unavailable. Your phone’s speech provider may send audio off this device. You can keep typing instead.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep typing')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Use phone')),
      ],
    ),
  ) ?? false;
}

/// Routes a notification tap or action: a habit reminder opens that habit,
/// "done" actions are applied, a task reminder opens Plan, anything
/// else opens Today.
void routeNotification(AppState state, String payload, String? actionId) {
  if (payload.startsWith('habit:')) {
    state.requestedHabit.value = payload.substring(6).split('|').first;
    state.requestedTab.value = HomeScreen.todayTab;
  } else if (actionId == 'done') {
    state.applyNotificationAction(payload);
  } else if (payload.startsWith('task:')) {
    state.requestedTab.value = HomeScreen.planTab;
  } else {
    state.requestedTab.value = HomeScreen.todayTab;
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  confirmPhoneFallback = _confirmFallback;
  final notifications = NotificationService.instance;
  await notifications.init();
  final state = await AppState.load(await Storage.open(), notifications);
  final diagnostics = Diagnostics.global = Diagnostics(state.storage.prefs)..installErrorHandlers();
  await diagnostics.count(Diagnostics.appOpens);
  BackupService(state.storage).startAutomatic();

  void handle(NotificationResponse r) {
    diagnostics.count(r.actionId == null ? Diagnostics.opensFromNotification : Diagnostics.notificationActions);
    routeNotification(state, r.payload ?? '', r.actionId);
  }

  notifications.onResponse = handle;
  final launch = await notifications.launchResponse();
  if (launch != null) handle(launch);

  await state.rescheduleNow();
  runApp(DailyDisciplineApp(state: state));
}

class DailyDisciplineApp extends StatelessWidget {
  final AppState state;
  const DailyDisciplineApp({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => MaterialApp(
        title: 'Daily Discipline',
        navigatorKey: _navigator,
        builder: (_, navigator) => _VoiceActivity(child: navigator!),
        debugShowCheckedModeBanner: false,
        theme: appTheme(Brightness.light),
        darkTheme: appTheme(Brightness.dark),
        themeMode: switch (state.settings.themeMode) {
          'light' => ThemeMode.light,
          'dark' => ThemeMode.dark,
          _ => ThemeMode.system,
        },
        home: needsOnboarding(state) ? OnboardingScreen(state: state) : HomeScreen(state: state),
      ),
    );
  }
}

class _VoiceActivity extends StatelessWidget {
  final Widget child;
  const _VoiceActivity({required this.child});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([listeningEngine, speakingEngine, voiceNotice]),
    child: child,
    builder: (context, child) {
      final listening = listeningEngine.value;
      final speaking = speakingEngine.value;
      final notice = voiceNotice.value;
      return Column(children: [
        if (listening != null || speaking != null || notice != null)
          Material(
            color: Theme.of(context).colorScheme.secondaryContainer,
            child: SafeArea(bottom: false, child: Padding(
              padding: const EdgeInsetsDirectional.only(start: 16, end: 4),
              child: Row(children: [
                Expanded(child: Semantics(liveRegion: true, child: Text(
                  listening != null ? 'Listening with $listening' : speaking != null ? 'Speaking · $speaking' : notice!,
                ))),
                if (listening == null && speaking == null)
                  IconButton(onPressed: () => voiceNotice.value = null, icon: const Icon(Icons.close), tooltip: 'Dismiss')
                else
                TextButton.icon(
                  onPressed: listening != null ? finishDictation : stopSpeaking,
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop'),
                ),
              ]),
            )),
          ),
        Expanded(child: child!),
      ]);
    },
  );
}

/// Deep teal on a soft off-white, or on near-black in dark mode, with a
/// small amber accent (tertiary) for streaks and attention banners. Inter,
/// tight headings, borderless rounded cards and a floating navigation bar.
ThemeData appTheme(Brightness b) {
  final dark = b == Brightness.dark;
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF0F766E), brightness: b).copyWith(
    tertiary: dark ? const Color(0xFFFBBF24) : const Color(0xFFB45309),
    onTertiary: dark ? const Color(0xFF3A2400) : Colors.white,
    tertiaryContainer: dark ? const Color(0xFF3A2E14) : const Color(0xFFFEF3C7),
    onTertiaryContainer: dark ? const Color(0xFFFDE68A) : const Color(0xFF78350F),
    surface: dark ? const Color(0xFF0B0F0E) : const Color(0xFFF2F5F4),
    surfaceContainerLowest: dark ? const Color(0xFF070A09) : Colors.white,
    surfaceContainerLow: dark ? const Color(0xFF131A19) : Colors.white,
    surfaceContainer: dark ? const Color(0xFF182120) : const Color(0xFFEDF2F1),
    surfaceContainerHigh: dark ? const Color(0xFF1F2928) : const Color(0xFFE5ECEA),
    surfaceContainerHighest: dark ? const Color(0xFF283332) : const Color(0xFFDCE5E3),
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, fontFamily: 'Inter');
  final tt = base.textTheme;
  TextStyle? tight(TextStyle? s, FontWeight w, double spacing) => s?.copyWith(fontWeight: w, letterSpacing: spacing);
  final text = tt.copyWith(
    displaySmall: tight(tt.displaySmall, FontWeight.w800, -1.2),
    headlineLarge: tight(tt.headlineLarge, FontWeight.w800, -1),
    headlineMedium: tight(tt.headlineMedium, FontWeight.w800, -0.8),
    headlineSmall: tight(tt.headlineSmall, FontWeight.w800, -0.6),
    titleLarge: tight(tt.titleLarge, FontWeight.w700, -0.4),
    titleMedium: tight(tt.titleMedium, FontWeight.w600, -0.2),
    titleSmall: tight(tt.titleSmall, FontWeight.w600, -0.1),
    labelLarge: tight(tt.labelLarge, FontWeight.w600, 0),
    bodyLarge: tt.bodyLarge?.copyWith(letterSpacing: -0.1),
    bodyMedium: tt.bodyMedium?.copyWith(letterSpacing: -0.1),
  );
  final r14 = RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));
  const buttonSize = Size(64, 40);
  const buttonPadding = EdgeInsets.symmetric(horizontal: 20);
  return base.copyWith(
    textTheme: text,
    cupertinoOverrideTheme: CupertinoThemeData(primaryColor: scheme.primary, brightness: b),
    scaffoldBackgroundColor: scheme.surface,
    cardTheme: CardThemeData(
      margin: const EdgeInsets.only(bottom: 14),
      elevation: 0,
      color: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: dark ? BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.25)) : BorderSide.none,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: buttonSize,
        padding: buttonPadding,
        shape: r14,
        textStyle: text.labelLarge,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: buttonSize,
        padding: buttonPadding,
        shape: r14,
        textStyle: text.labelLarge,
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(shape: r14, textStyle: text.labelLarge)),
    chipTheme: ChipThemeData(
      shape: const StadiumBorder(),
      side: BorderSide.none,
      backgroundColor: scheme.surfaceContainerHigh,
      labelStyle: text.labelMedium?.copyWith(fontWeight: FontWeight.w600, color: scheme.onSurface),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHigh,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
    ),
    listTileTheme: ListTileThemeData(shape: r14),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      titleTextStyle: text.titleLarge?.copyWith(fontWeight: FontWeight.w800, color: scheme.onSurface),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: dark ? scheme.surfaceContainerHigh : Colors.white,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.primaryContainer,
      elevation: 0,
      height: 64,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => text.labelSmall?.copyWith(
          fontWeight: s.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
          color: s.contains(WidgetState.selected) ? scheme.onSurface : scheme.onSurfaceVariant,
        ),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
    ),
    snackBarTheme: SnackBarThemeData(behavior: SnackBarBehavior.floating, shape: r14),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant.withValues(alpha: 0.5)),
    progressIndicatorTheme: ProgressIndicatorThemeData(linearTrackColor: scheme.surfaceContainerHighest),
  );
}
