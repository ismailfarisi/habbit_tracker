import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'app_state.dart';
import 'screens/home_screen.dart';
import 'services/notification_service.dart';
import 'services/storage.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final notifications = NotificationService.instance;
  await notifications.init();
  final state = await AppState.load(await Storage.open(), notifications);

  void handle(NotificationResponse r) {
    final payload = r.payload ?? '';
    if (payload.startsWith('train|')) {
      state.requestedTab.value = HomeScreen.trainTab;
    } else if (r.actionId == 'done') {
      state.applyNotificationAction(payload);
    } else {
      state.requestedTab.value = HomeScreen.todayTab;
    }
  }

  notifications.onResponse = handle;
  final launch = await notifications.launchResponse();
  if (launch != null) handle(launch);

  await notifications.reschedule(state.settings, state.logs);
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
      home: HomeScreen(state: state),
    );
  }
}
