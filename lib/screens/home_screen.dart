import 'package:flutter/material.dart';

import '../app_state.dart';
import 'settings_screen.dart';
import 'stats_screen.dart';
import 'tasks_screen.dart';
import 'today_screen.dart';
import 'train_screen.dart';

class HomeScreen extends StatefulWidget {
  static const todayTab = 0, tasksTab = 1, trainTab = 2, statsTab = 3, settingsTab = 4;

  final AppState state;
  const HomeScreen({super.key, required this.state});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.state.requestedTab.addListener(_onTabRequest);
    _onTabRequest();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.state.requestedTab.removeListener(_onTabRequest);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    // Notification actions may have updated the log while we were away.
    if (s == AppLifecycleState.resumed) widget.state.refreshFromDisk();
  }

  void _onTabRequest() {
    final t = widget.state.requestedTab.value;
    if (t != null) {
      setState(() => _tab = t);
      widget.state.requestedTab.value = null;
    }
  }

  void goTo(int tab) => setState(() => _tab = tab);

  @override
  Widget build(BuildContext context) {
    final pages = [
      TodayScreen(state: widget.state, onNavigate: goTo),
      TasksScreen(state: widget.state),
      TrainScreen(state: widget.state, onNavigate: goTo),
      StatsScreen(state: widget.state),
      SettingsScreen(state: widget.state),
    ];
    return Scaffold(
      body: SafeArea(child: IndexedStack(index: _tab, children: pages)),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: goTo,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.today_outlined), selectedIcon: Icon(Icons.today), label: 'Today'),
          NavigationDestination(icon: Icon(Icons.checklist_outlined), selectedIcon: Icon(Icons.checklist), label: 'Tasks'),
          NavigationDestination(icon: Icon(Icons.record_voice_over_outlined), selectedIcon: Icon(Icons.record_voice_over), label: 'Train'),
          NavigationDestination(icon: Icon(Icons.insights_outlined), selectedIcon: Icon(Icons.insights), label: 'Stats'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }
}
