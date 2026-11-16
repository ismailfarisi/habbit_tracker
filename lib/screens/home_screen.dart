import 'package:flutter/material.dart';

import '../app_state.dart';
import 'settings_screen.dart';
import 'stats_screen.dart';
import 'tasks_screen.dart';
import 'today_screen.dart';

class HomeTab {
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final Widget Function(AppState state, void Function(int tab) goTo) build;
  const HomeTab(this.label, this.icon, this.selectedIcon, this.build);
}

/// The app shell. [tabs] is the one place that lists the bottom tabs; keep
/// the `*Tab` indexes in step with it.
class HomeScreen extends StatefulWidget {
  static const todayTab = 0, tasksTab = 1, statsTab = 2, settingsTab = 3;

  static final tabs = <HomeTab>[
    HomeTab('Today', Icons.today_outlined, Icons.today, (s, goTo) => TodayScreen(state: s, onNavigate: goTo)),
    HomeTab('Tasks', Icons.checklist_outlined, Icons.checklist, (s, _) => TasksScreen(state: s)),
    HomeTab('Progress', Icons.insights_outlined, Icons.insights, (s, _) => StatsScreen(state: s)),
    HomeTab('Settings', Icons.settings_outlined, Icons.settings, (s, _) => SettingsScreen(state: s)),
  ];

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
      setState(() => _tab = t.clamp(0, HomeScreen.tabs.length - 1));
      widget.state.requestedTab.value = null;
    }
  }

  void goTo(int tab) => setState(() => _tab = tab);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: IndexedStack(
          index: _tab,
          children: [for (final t in HomeScreen.tabs) t.build(widget.state, goTo)],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: goTo,
        destinations: [
          for (final t in HomeScreen.tabs)
            NavigationDestination(icon: Icon(t.icon), selectedIcon: Icon(t.selectedIcon), label: t.label),
        ],
      ),
    );
  }
}
