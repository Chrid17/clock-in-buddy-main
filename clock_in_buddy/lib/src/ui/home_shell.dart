import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/attendance_controller.dart';
import '../state/session.dart';
import 'admin_screens.dart';
import 'clock_tab.dart';
import 'history_tab.dart';
import 'profile_tab.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back in the app: refresh status and upload anything saved offline.
    if (state == AppLifecycleState.resumed) {
      context.read<AttendanceController>().refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = context.select<Session, bool>((s) => s.isAdmin);
    final pages = <Widget>[
      const ClockTab(),
      const HistoryTab(),
      if (isAdmin) const AdminTab(),
      const ProfileTab(),
    ];
    final destinations = <NavigationDestination>[
      const NavigationDestination(
          icon: Icon(Icons.fingerprint_outlined), selectedIcon: Icon(Icons.fingerprint), label: 'Clock'),
      const NavigationDestination(
          icon: Icon(Icons.history_outlined), selectedIcon: Icon(Icons.history), label: 'History'),
      if (isAdmin)
        const NavigationDestination(
            icon: Icon(Icons.groups_outlined), selectedIcon: Icon(Icons.groups), label: 'Team'),
      const NavigationDestination(
          icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Profile'),
    ];
    final index = _index >= pages.length ? 0 : _index;

    return Scaffold(
      body: IndexedStack(index: index, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: destinations,
      ),
    );
  }
}
