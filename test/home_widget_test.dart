import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_tracker/logic/stats.dart';
import 'package:habit_tracker/models.dart';
import 'package:habit_tracker/services/home_widget_service.dart';
import 'package:habit_tracker/services/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final day = DateTime(2026, 11, 16);
  DateTime at(int h, int m, [int plusDays = 0]) => DateTime(day.year, day.month, day.day + plusDays, h, m);
  final s = Settings(); // manual times: Fajr 05:00, Dhuhr 12:30, Asr 15:45 ...

  late List<MethodCall> calls;
  setUp(() {
    mockPlugins();
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('home_widget'),
      (c) async {
        calls.add(c);
        return true;
      },
    );
    HomeWidgetService.debugEnabled = true;
  });
  tearDown(() => HomeWidgetService.debugEnabled = null);

  Map<String, dynamic> savedData() {
    final save = calls.lastWhere((c) => c.method == 'saveWidgetData');
    expect((save.arguments as Map)['id'], homeWidgetDataKey);
    return jsonDecode((save.arguments as Map)['data'] as String) as Map<String, dynamic>;
  }

  group('widgetSlotAt', () {
    test('before Fajr shows the next prayer without Done', () {
      final slot = widgetSlotAt(s, {}, at(4, 0));
      expect(slot.prayer, 'Fajr');
      expect(slot.at, at(5, 0));
      expect(slot.due, isFalse);
      expect(slot.payload, isNull);
      expect(slot.toJson()['label'], 'Next prayer');
    });

    test('a started prayer that is not done is due with a payload', () {
      final slot = widgetSlotAt(s, {}, at(16, 0));
      expect(slot.prayer, 'Asr');
      expect(slot.due, isTrue);
      expect(slot.payload, 'prayer:Asr|2026-11-16');
      expect(slot.toJson(), containsPair('label', 'Pray now'));
      expect(slot.toJson(), containsPair('time', '15:45'));
      expect(slot.toJson(), containsPair('payload', 'prayer:Asr|2026-11-16'));
    });

    test('once the current prayer is done the next one is shown', () {
      final logs = {dayKey(day): DayLog(prayers: {'Asr'})};
      final slot = widgetSlotAt(s, logs, at(16, 0));
      expect(slot.prayer, 'Maghrib');
      expect(slot.due, isFalse);
    });

    test('after the last prayer is done it shows tomorrow\'s Fajr', () {
      final logs = {dayKey(day): DayLog(prayers: {...prayerNames})};
      final slot = widgetSlotAt(s, logs, at(23, 0));
      expect(slot.prayer, 'Fajr');
      expect(slot.at, at(5, 0, 1));
      expect(slot.toJson()['label'], 'Next prayer, tomorrow');
    });

    test('carries the day score', () {
      final logs = {dayKey(day): DayLog(prayers: {'Fajr', 'Dhuhr'})};
      expect(widgetSlotAt(s, logs, at(13, 0)).toJson()['score'], 'Today 2/6');
    });
  });

  test('widgetSlots starts now and changes at each later prayer time and midnight', () {
    final now = at(16, 0);
    final slots = widgetSlots(s, {}, now);
    final times = prayerNames.map((p) => parseHm(defaultManualTimes[p]!)).toList();
    expect(slots.first.from, now);
    expect(slots.map((x) => x.from), [
      now,
      for (final t in times.skip(3)) at(t.hour, t.minute),
      at(0, 0, 1),
      for (final t in times) at(t.hour, t.minute, 1),
    ]);
    expect(slots.first.prayer, 'Asr');
    expect(slots[1].prayer, 'Maghrib');
    expect(slots[1].due, isTrue);
    expect(slots[3].prayer, 'Fajr');
    expect(slots[3].due, isFalse);
    final json = jsonDecode(widgetJson(slots, now)) as Map<String, dynamic>;
    expect(json['until'], at(0, 0, 2).millisecondsSinceEpoch);
    expect((json['slots'] as List).length, slots.length);
  });

  test('publish writes the data, redraws and schedules the next slots', () async {
    final now = at(16, 0);
    await HomeWidgetService.publish(s, {}, now: now);
    expect(calls.map((c) => c.method),
        containsAllInOrder(['registerBackgroundCallback', 'saveWidgetData', 'updateWidget', 'scheduleWidgetUpdates']));
    expect((calls.firstWhere((c) => c.method == 'updateWidget').arguments as Map)['qualifiedAndroidName'],
        homeWidgetProvider);
    final schedule = calls.firstWhere((c) => c.method == 'scheduleWidgetUpdates').arguments as Map;
    expect(schedule['updateTimes'], [
      for (final slot in widgetSlots(s, {}, now).skip(1)) slot.from.millisecondsSinceEpoch,
    ]);
    expect((savedData()['slots'] as List).first['prayer'], 'Asr');
  });

  test('clearing the device removes the timeline, cancels alarms and redraws the empty widget', () async {
    await HomeWidgetService.clear();
    expect(calls.map((c) => c.method), ['cancelScheduledWidgetUpdates', 'saveWidgetData', 'updateWidget']);
    expect(calls[1].arguments, containsPair('data', null));
    expect(calls[1].arguments, containsPair('id', homeWidgetDataKey));
  });

  test('publish is a no-op when disabled and survives plugin errors', () async {
    HomeWidgetService.debugEnabled = false;
    await HomeWidgetService.publish(s, {});
    expect(calls, isEmpty);
    HomeWidgetService.debugEnabled = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('home_widget'),
      (c) async => throw PlatformException(code: '-6'),
    );
    await HomeWidgetService.publish(s, {});
  });

  test('AppState commits publish the widget', () async {
    final state = await loadState();
    calls.clear();
    final now = DateTime.now();
    final shown = widgetSlotAt(state.settings, state.logs, now).prayer;
    await state.setPrayerStatus(now, shown, prayerOnTime);
    final first = (savedData()['slots'] as List).first as Map;
    expect(first['prayer'] == shown && first['payload'] != null, isFalse);
  });

  test('Done marks the prayer through the notification-action path and republishes', () async {
    SharedPreferences.setMockInitialValues({});
    final key = dayKey(DateTime.now());
    final uri = Uri(scheme: 'dailydiscipline', host: 'done', queryParameters: {'payload': 'prayer:Asr|$key'});
    expect(uri.toString(), contains('payload=prayer%3AAsr%7C'));
    await homeWidgetCallback(Uri.parse(uri.toString()));
    final storage = await Storage.open();
    final log = storage.loadLogs()[key]!;
    expect(log.prayers, contains('Asr'));
    expect(log.prayerStatus['Asr'] ?? prayerOnTime, prayerOnTime);
    expect(calls.map((c) => c.method), containsAllInOrder(['saveWidgetData', 'updateWidget']));
  });

  test('other widget URIs only republish', () async {
    SharedPreferences.setMockInitialValues({});
    await homeWidgetCallback(Uri.parse('dailydiscipline://open'));
    await homeWidgetCallback(Uri.parse('dailydiscipline://done?payload=task:x|2026-11-16'));
    expect((await Storage.open()).loadLogs(), isEmpty);
    expect(calls.where((c) => c.method == 'saveWidgetData').length, 2);
  });
}
