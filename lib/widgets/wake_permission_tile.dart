import 'package:flutter/material.dart';

import '../services/notification_service.dart';

/// Full-screen access is separate from Android's exact alarm permission.
class WakePermissionTile extends StatefulWidget {
  final NotificationService notifications;
  const WakePermissionTile({super.key, required this.notifications});

  @override
  State<WakePermissionTile> createState() => _WakePermissionTileState();
}

class _WakePermissionTileState extends State<WakePermissionTile>
    with WidgetsBindingObserver {
  late Future<bool?> _access;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _access = widget.notifications.fullScreenAllowed();
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

  void _refresh() =>
      setState(() => _access = widget.notifications.fullScreenAllowed());

  @override
  Widget build(BuildContext context) => FutureBuilder<bool?>(
    future: _access,
    builder: (context, snapshot) {
      final allowed = snapshot.data;
      return ListTile(
        leading: const Icon(Icons.phonelink_ring),
        title: const Text('Full-screen wake access'),
        subtitle: Text(
          allowed == true
              ? 'Allowed by Android'
              : allowed == false
              ? 'Permission needed to show the alarm over the lock screen'
              : 'Check full-screen alarm permission in Android settings',
        ),
        trailing: allowed == true ? null : const Icon(Icons.open_in_new),
        onTap: allowed == true
            ? null
            : () async {
                await widget.notifications.requestFullScreenWake();
                if (mounted) _refresh();
              },
      );
    },
  );
}
