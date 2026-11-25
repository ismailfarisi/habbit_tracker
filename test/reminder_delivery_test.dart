import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_tracker/models.dart';
import 'package:habit_tracker/app_state.dart';
import 'package:habit_tracker/screens/reminders_screen.dart';
import 'package:habit_tracker/screens/settings_screen.dart';
import 'package:habit_tracker/services/notification_service.dart';
import 'package:habit_tracker/services/prayer_service.dart';
import 'package:habit_tracker/services/reminders.dart';

import 'support.dart';

class _Queue extends Fake implements NotificationService {
  @override
  final scheduleRevision = ValueNotifier(0);

  @override
  Future<ReminderDelivery> delivery({DateTime? now}) async {
    final times = planReminders(
      Settings(useManualPrayer: true),
      {},
      now!,
      days: 1,
    );
    return ReminderDelivery(
      pending: times
          .where((r) => r.kind == ReminderKind.prayer)
          .take(1)
          .toList(),
      allowed: true,
      exact: false,
      missing: 1,
      beyondLimit: 5,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('fallback timetables never authorize a prayer-derived alert', () {
    final s = Settings(ramadanMode: 'on');
    final friday = DateTime(2026, 1, 2);
    final task = Task(id: 'bins', seq: 23, title: 'Bins', time: '12:00');
    List<PlannedReminder> plan() =>
        planReminders(s, {}, friday, days: 1, tasks: [task]);
    expect(plan().any((r) => r.kind == ReminderKind.task), isTrue);
    expect(
      plan().where(
        (r) => r.kind == ReminderKind.prayer || r.payload.startsWith('suhoor|'),
      ),
      isEmpty,
    );
    expect(prayerTimeSource(s), contains('Example times'));

    s.latitude = 25.2048;
    s.longitude = 55.2708;
    s.locationName = 'Dubai';
    s.calcMethod = 'dubai';
    expect(prayerTimeSource(s), 'Dubai · Dubai / Gulf');
    expect(plan().where((r) => r.kind == ReminderKind.prayer), hasLength(6));
    expect(
      plan().singleWhere((r) => r.payload.startsWith('suhoor|')).when,
      prayerTimesFor(
        s,
        friday,
      ).times['Fajr']!.subtract(Duration(minutes: s.suhoorMinutes)),
    );
    s.latitude = s.longitude = null;
    s.useManualPrayer = true;
    expect(prayerTimesConfirmed(Settings.fromJson(s.toJson())), isTrue);
    expect(plan().where((r) => r.kind == ReminderKind.prayer), hasLength(6));
  });

  test(
    'iOS actions match the kind and open the challenge in the foreground',
    () {
      final s = Settings(wakeChallenge: WakeChallenge.math);
      final challenge = ReminderAction.forReminder(
        ReminderKind.wake,
        s,
        'wake|2026-01-01',
      )!.category.actions.single;
      expect(challenge.identifier, wakeChallengeAction);
      expect(challenge.title, 'Start wake challenge');
      expect(
        challenge.options,
        contains(DarwinNotificationActionOption.foreground),
      );
      expect(ReminderAction.prayer.category.actions.single.title, 'Prayed');
      expect(
        ReminderAction.bedtime.category.actions.single.title,
        'Going to bed',
      );
      expect(
        ReminderAction.forReminder(ReminderKind.wake, s, 'suhoor|2026-01-01'),
        ReminderAction.dismiss,
      );
      expect(ReminderAction.forReminder(ReminderKind.prayer, s, null), isNull);
    },
  );

  testWidgets(
    'Upcoming shows queue gaps and expands the full sourced reminder',
    (tester) async {
      mockPlugins();
      final base = await loadState();
      final state = await AppState.load(base.storage, _Queue());
      final day = DateTime(2026, 11, 25);
      final first = (await state.notifications.delivery(
        now: day,
      ))!.pending.single;
      tester.view.physicalSize = const Size(420, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: RemindersScreen(state: state, now: day),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Next alert · Today'), findsOneWidget);
      expect(find.textContaining('1 alert is missing'), findsOneWidget);
      expect(find.text('Allow exact alarms'), findsOneWidget);
      expect(find.text('Rebuild schedule'), findsOneWidget);
      expect(find.text(first.body), findsNothing);
      await tester.tap(find.widgetWithText(ExpansionTile, first.title));
      await tester.pumpAndSettle();
      expect(find.text(first.body), findsOneWidget);
      expect(first.body, contains(' — '));
    },
  );

  testWidgets(
    'city setup enables offline prayer alerts after location was skipped',
    (tester) async {
      mockPlugins();
      final state = await loadState();
      final day = DateTime(2026, 11, 25);
      expect(
        planReminders(
          state.settings,
          {},
          day,
        ).where((r) => r.kind == ReminderKind.prayer),
        isEmpty,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsScreen(
              state: state,
              section: SettingsSection.prayers,
            ),
          ),
        ),
      );
      await tester.tap(find.text('Choose a city'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dubai'));
      await tester.pumpAndSettle();
      expect(find.text('Dubai · Dubai / Gulf'), findsOneWidget);
      expect(state.storage.loadSettings().latitude, 25.2048);
      expect(
        planReminders(
          state.settings,
          {},
          day,
        ).any((r) => r.kind == ReminderKind.prayer),
        isTrue,
      );
    },
  );

  test(
    'coverage reflects bounded, accepted, pending requests and live Android tokens',
    () async {
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      const notifications = MethodChannel(
        'dexterous.com/flutter/local_notifications',
      );
      const device = MethodChannel('daily_discipline/reminders');
      const timezone = MethodChannel('flutter_timezone');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var zone = 'Etc/UTC', allowed = true;
      int? dropToken;
      final pending = <int, Map<dynamic, dynamic>>{};
      final modes = <String>{},
          zones = <String>{},
          permissionCalls = <String>[];
      messenger.setMockMethodCallHandler(timezone, (_) async => zone);
      messenger.setMockMethodCallHandler(
        device,
        (call) async => switch (call.method) {
          'pendingIds' =>
            (call.arguments as List).where((id) => id != dropToken).toList(),
          'blockedChannels' => {'prayer': 'Prayer reminders'},
          'fullScreenAllowed' => false,
          _ => throw MissingPluginException(),
        },
      );
      messenger.setMockMethodCallHandler(notifications, (call) async {
        switch (call.method) {
          case 'initialize':
            return true;
          case 'areNotificationsEnabled':
            return allowed;
          case 'canScheduleExactNotifications':
            return false;
          case 'cancelAllPendingNotifications':
            pending.clear();
            return null;
          case 'zonedSchedule':
            final row = call.arguments as Map;
            pending[row['id'] as int] = row;
            modes.add(row['platformSpecifics']['scheduleMode'] as String);
            zones.add(row['timeZoneName'] as String);
            return null;
          case 'pendingNotificationRequests':
            return pending.values.toList();
          case 'requestNotificationsPermission':
          case 'requestExactAlarmsPermission':
          case 'requestFullScreenIntentPermission':
            permissionCalls.add(call.method);
            return true;
          default:
            throw MissingPluginException(call.method);
        }
      });
      final n = NotificationService.instance;
      await n.init();
      expect(await n.requestPermissions(), isTrue);
      expect(permissionCalls, ['requestNotificationsPermission']);
      expect(await n.fullScreenAllowed(), isFalse);
      final s = Settings(useManualPrayer: true);
      final tasks = [
        for (var i = 0; i < 20; i++)
          Task(
            id: 'task-$i',
            seq: i,
            title: 'Task $i',
            repeat: Repeat.daily,
            time: '17:00',
          ),
      ];
      await n.reschedule(s, {}, tasks);
      expect(pending.length, maxPending);
      expect(modes, {'inexactAllowWhileIdle'});
      dropToken = pending.keys.first;
      pending.remove(pending.keys.last);
      var status = (await n.delivery())!;
      expect(status.pending.length, maxPending - 2);
      expect(status.pending.first.id, isNot(dropToken));
      expect(status.missing, 2);
      expect(status.beyondLimit, greaterThan(0));
      expect(status.exact, isFalse);
      expect(
        status.muted,
        status.pending
            .where((r) => r.kind == ReminderKind.prayer)
            .map((r) => r.id)
            .toSet(),
      );
      expect(zones, {'Etc/UTC'});
      zone = 'Europe/Paris';
      zones.clear();
      await n.reschedule(s, {}, tasks);
      expect(zones, {'Europe/Paris'});
      allowed = false;
      await n.reschedule(s, {}, tasks);
      status = (await n.delivery())!;
      expect(status.allowed, isFalse);
      expect(status.pending, isEmpty);
      expect(pending, isEmpty);
    },
  );
}
