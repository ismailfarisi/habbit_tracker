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
    ThemeData theme(Brightness b) => ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFF5B942), brightness: b),
      cardTheme: const CardThemeData(margin: EdgeInsets.only(bottom: 12)),
    );
    return MaterialApp(
      title: 'Daily Discipline',
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      home: ListenableBuilder(
        listenable: state,
        builder: (context, _) => needsOnboarding(state) ? OnboardingScreen(state: state) : HomeScreen(state: state),
      ),
    );
  }
}
