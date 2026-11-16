import 'package:flutter/material.dart';

import '../app_state.dart';
import 'plan_screen.dart';
import 'settings_screen.dart';
import 'stats_screen.dart';
import 'today_screen.dart';

class HomeTab {
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final Widget Function(AppState state, void Function(int tab) goTo) build;
  const HomeTab(this.label, this.icon, this.selectedIcon, this.build);
}

/// The app shell. [tabs] is the one place that lists the bottom tabs; keep
/// the `*Tab` indexes in step with it. Settings is not a tab: it opens from
/// the gear in the app bar, and [settingsTab] (passed to `goTo` or
/// `AppState.requestedTab`) opens it too.
class HomeScreen extends StatefulWidget {
  static const todayTab = 0, planTab = 1, progressTab = 2;
  static const tasksTab = planTab, statsTab = progressTab;
  static const settingsTab = 3;

  static final tabs = <HomeTab>[
    HomeTab('Today', Icons.today_outlined, Icons.today, (s, goTo) => TodayScreen(state: s, onNavigate: goTo)),
    HomeTab('Plan', Icons.event_note_outlined, Icons.event_note, (s, _) => PlanScreen(state: s)),
    HomeTab('Progress', Icons.insights_outlined, Icons.insights, (s, _) => StatsScreen(state: s)),
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
    WidgetsBinding.instance.addPostFrameCallback((_) => _onTabRequest());
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
    if (t == null || !mounted) return;
    widget.state.requestedTab.value = null;
    goTo(t);
  }

  void goTo(int tab) {
    if (tab == HomeScreen.settingsTab) {
      openSettings(context, widget.state);
      return;
    }
    setState(() => _tab = tab.clamp(0, HomeScreen.tabs.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Daily Discipline'),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => openSettings(context, widget.state),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: IndexedStack(index: _tab, children: [for (final t in HomeScreen.tabs) t.build(widget.state, goTo)]),
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
