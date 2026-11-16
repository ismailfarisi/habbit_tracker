import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'app_state.dart';
import 'screens/home_screen.dart';
import 'screens/onboarding_screen.dart';
import 'services/backup_service.dart';
import 'services/diagnostics.dart';
import 'services/notification_service.dart';
import 'services/storage.dart';

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

/// Deep teal on near-white, or on near-black in dark mode, with a small
/// amber accent (tertiary) for streaks and highlights.
ThemeData appTheme(Brightness b) {
  final dark = b == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF0F766E),
    brightness: b,
    dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot,
  ).copyWith(
    tertiary: dark ? const Color(0xFFFBBF24) : const Color(0xFFB45309),
    onTertiary: dark ? const Color(0xFF3A2400) : Colors.white,
    tertiaryContainer: dark ? const Color(0xFF3A2E14) : const Color(0xFFFEF3C7),
    onTertiaryContainer: dark ? const Color(0xFFFDE68A) : const Color(0xFF78350F),
    surface: dark ? const Color(0xFF0E1413) : const Color(0xFFF8FAF9),
    surfaceContainerLowest: dark ? const Color(0xFF090D0C) : Colors.white,
    surfaceContainerLow: dark ? const Color(0xFF141B1A) : const Color(0xFFF1F5F4),
    surfaceContainer: dark ? const Color(0xFF18201F) : const Color(0xFFEBF1EF),
    surfaceContainerHigh: dark ? const Color(0xFF1E2726) : const Color(0xFFE4ECEA),
    surfaceContainerHighest: dark ? const Color(0xFF253030) : const Color(0xFFDDE6E4),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    cardTheme: CardThemeData(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      color: dark ? scheme.surfaceContainerLow : scheme.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: dark ? 0.4 : 0.6)),
      ),
    ),
    appBarTheme: AppBarTheme(backgroundColor: scheme.surface, surfaceTintColor: Colors.transparent),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      indicatorColor: scheme.primaryContainer,
    ),
  );
}
