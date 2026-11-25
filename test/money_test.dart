import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_tracker/agent/finance_tools.dart';
import 'package:habit_tracker/agent/habit_catalog.dart';
import 'package:habit_tracker/agent/habit_surface.dart';
import 'package:habit_tracker/agent/habit_templates.dart';
import 'package:habit_tracker/app_state.dart';
import 'package:habit_tracker/finance/finance.dart';
import 'package:habit_tracker/finance/money_screen.dart';
import 'package:habit_tracker/goals/goal.dart';
import 'package:habit_tracker/screens/settings_screen.dart';
import 'package:habit_tracker/screens/today_screen.dart';
import 'package:habit_tracker/services/openrouter.dart';
import 'package:habit_tracker/services/task_tools.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(mockPlugins);

  final now = DateTime(2026, 11, 25, 15);
  Future<AppState> state() => loadState({
    'settings.v1': jsonEncode({'onboarded': true}),
  });
  ToolCall call(String name, Map<String, dynamic> args) => ToolCall('c', name, jsonEncode(args));

  group('AI money tools', () {
    late AppState s;
    late FinanceTools tools;
    final acts = <ToolActivity>[];
    setUp(() async {
      acts.clear();
      s = await state();
      await s.updateFinance((f) => f.currency = 'AED');
      tools = FinanceTools(s, onActivity: acts.add, clock: () => now);
    });

    test('log_money records spending, and Undo removes it', () async {
      final r = jsonDecode(
        await tools.execute(call('log_money', {'amount': 12.5, 'category': 'food', 'note': 'Lunch'})),
      );
      expect(r['ok'], isTrue);
      final e = s.finance.entries.single;
      expect((e.amount, e.category, e.income, e.note), (1250, 'Food', false, 'Lunch'));
      expect(acts.single.label, 'Spent AED 12.50 · Food');
      await acts.single.undo!();
      expect(s.finance.entries, isEmpty);
    });

    test('rejects bad amounts and unknown pots', () async {
      expect(
        jsonDecode(await tools.execute(call('log_money', {'amount': -3, 'category': 'Food'})))['error'],
        isNotNull,
      );
      expect(
        jsonDecode(
          await tools.execute(call('log_money', {'amount': 3, 'category': 'Food', 'pot_id': 'nope'})),
        )['error'],
        contains('no pot'),
      );
      expect(s.finance.entries, isEmpty);
    });

    test('a savings pot linked to a goal, then money into it', () async {
      await s.upsertGoal(
        Goal(
          id: 'g1',
          title: 'Hajj 2027',
          why: 'Fard',
          start: '2026-11-25',
          end: '2027-05-01',
          cadence: ReviewCadence.monthly,
        ),
      );
      expect(
        jsonDecode(
          await tools.execute(call('create_savings_pot', {'name': 'Hajj', 'target': 20000, 'goal_id': 'x'})),
        )['error'],
        contains('no goal'),
      );
      final r = jsonDecode(
        await tools.execute(
          call('create_savings_pot', {'name': 'Hajj', 'target': 20000, 'by': '2027-05-01', 'goal_id': 'g1'}),
        ),
      );
      await tools.execute(call('log_money', {'amount': 500, 'category': 'Savings', 'pot_id': r['id']}));
      final pot = s.finance.potForGoal('g1')!;
      expect(pot.target, 2000000);
      expect(s.finance.potSaved(pot.id), 50000);
      expect(s.finance.entries.single.category, 'Savings');
    });

    test('budgets, debts and repayments', () async {
      await tools.execute(call('set_budget', {'category': 'Food', 'amount': 1000}));
      expect(s.finance.budgets, {'Food': 100000});
      await acts.last.undo!();
      expect(s.finance.budgets, isEmpty);

      final d = jsonDecode(await tools.execute(call('add_debt', {'person': 'Ahmed', 'amount': 300, 'i_owe': true})));
      await tools.execute(call('log_money', {'amount': 100, 'category': 'Debt', 'debt_id': d['id']}));
      expect(s.finance.debtLeft(s.finance.debts.single), 20000);
    });

    test('zakat asks for the metal price before giving a due amount', () async {
      var r = jsonDecode(await tools.execute(call('update_zakat', {'cash': 10000})));
      expect(r['nisab'], contains('ask'));
      r = jsonDecode(await tools.execute(call('update_zakat', {'silver_price_per_gram': 3})));
      expect(r['nisab'], 'AED 1,785');
      expect(r['zakat_due'], 'AED 250');
      expect(acts.last.label, 'Zakat: AED 250 due');
      await acts.last.undo!();
      expect(s.finance.zakat.silverPricePerGram, 0);
      expect(s.finance.zakat.cash, 1000000);
    });

    test('positive unpriced holding prevents a final coach estimate', () async {
      final r = jsonDecode(await tools.execute(call('update_zakat',
        {'cash': 10000, 'silver_price_per_gram': 3, 'gold_grams': 100})));
      expect(r['zakat_due'], isNull);
      expect(r['missing_prices'], ['gold']);
      expect(r['asset_values']['Gold (100.0 g)'], 'Unpriced');
      expect(s.finance.summary(now), contains('estimate incomplete'));
      final priced = jsonDecode(await tools.execute(call('update_zakat', {'gold_price_per_gram': 50})));
      expect(priced['zakat_due'], 'AED 375');
      expect(priced['valuation_date'], '2026-11-25');
    });

    test('Undo targets its original ledger after a switch', () async {
      await tools.execute(call('set_budget', {'category': 'Food', 'amount': 500}));
      await s.updateFinance((f) => f.openLedger('KWD'));
      await s.setBudget('Food', 1000);
      await acts.last.undo!();
      expect(s.finance.budgets['Food'], 1000);
      await s.updateFinance((f) => f.openLedger('AED'));
      expect(s.finance.budgets, isEmpty);
      expect(jsonDecode(await tools.execute(call('log_money',
        {'amount': 12, 'category': 'Food', 'currency': 'KWD'})))['error'], contains('AED'));
      expect(s.finance.entries, isEmpty);
    });

    test('money_summary and set_currency', () async {
      await tools.execute(call('log_money', {'amount': 20, 'category': 'Sadaqah'}));
      final r = jsonDecode(await tools.execute(call('money_summary', {})));
      expect(r['by_category'], {'Sadaqah': 'AED 20'});
      expect((r['recent'] as List).single, contains('Sadaqah'));
      expect(jsonDecode(await tools.execute(call('set_currency', {'code': 'eur'})))['error'], contains('separate ledger'));
      expect(s.finance.currency, 'AED');
      expect(jsonDecode(await tools.execute(call('set_currency', {'code': 'euro'})))['error'], isNotNull);
    });

    test('update_settings only changes allowed keys, with Undo', () async {
      expect(
        jsonDecode(
          await tools.execute(
            call('update_settings', {
              'changes': {'apiKey': 'x'},
            }),
          ),
        )['error'],
        contains('not allowed'),
      );
      expect(
        jsonDecode(
          await tools.execute(
            call('update_settings', {
              'changes': {'prayerHadith': 'yes'},
            }),
          ),
        )['error'],
        contains('wrong value'),
      );
      expect(
        jsonDecode(
          await tools.execute(
            call('update_settings', {
              'changes': {'themeMode': 'pink'},
            }),
          ),
        )['error'],
        isNotNull,
      );
      final r = jsonDecode(
        await tools.execute(
          call('update_settings', {
            'changes': {'prayerHadith': false, 'themeMode': 'dark'},
          }),
        ),
      );
      expect(r['now'], {'prayerHadith': false, 'themeMode': 'dark'});
      expect(s.settings.prayerHadith, isFalse);
      await acts.single.undo!();
      expect((s.settings.prayerHadith, s.settings.themeMode), (true, 'system'));
    });

    test('customize_today hides, shows and pins Today cards', () async {
      List<String> ids() => todayItems(s, now).map((i) => i.id).toList();
      expect(ids(), isNot(contains('money')));
      await tools.execute(
        call('customize_today', {
          'hide': ['wake'],
          'show': ['money'],
          'pin': ['money', 'tasks'],
        }),
      );
      expect(ids(), isNot(contains('wake')));
      expect(ids().take(2), ['money', 'tasks']);
      await acts.single.undo!();
      expect(ids(), contains('wake'));
      expect(ids(), isNot(contains('money')));
    });

    test('registered with the agent and described in its prompt', () {
      expect(financeToolNames, containsAll(['log_money', 'update_settings', 'customize_today', 'update_zakat']));
      for (final k in aiSettings.keys) {
        expect(s.settings.toJson().containsKey(k), isTrue, reason: k);
      }
      expect(financePrompt, contains('not a fatwa'));
    });
  });

  group('money habits', () {
    test('templates are valid surfaces; weekly sadaqah is on Fridays', () {
      for (final t in moneyHabitTemplates) {
        expect(() => normalizeHabitSurface(surfaceMessage(t.components)), returnsNormally, reason: t.title);
      }
      expect(habitFromTemplate(weeklySadaqahTemplate).weekdays, [5]);
    });

    testWidgets('MoneyLog records the amount in Money and completes the habit', (tester) async {
      final s = await tester.runAsync(state);
      await s!.updateFinance((f) => f.currency = 'AED');
      await s.setBudget('Other', 10000);
      final h = await s.upsertHabit(habitFromTemplate(logSpendingTemplate));
      final day = DateTime.now();
      tester.view.physicalSize = const Size(420, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ListenableBuilder(listenable: s, builder: (_, _) => HabitSurface(s, s.habitById(h.id)!, day)),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Budgets this month'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '25');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      final e = s.finance.entries.single;
      expect((e.amount, e.category, e.note), (2500, 'Other', "Log today's spending"));
      expect(s.habitEntry(day, h.id).done, isTrue);
      expect(s.habitEntry(day, h.id).value, 25);
      expect(find.text('AED 75 left'), findsOneWidget);
    });
  });

  group('Money screen', () {
    Future<void> pump(WidgetTester tester, Widget w) async {
      tester.view.physicalSize = const Size(420, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: w));
      await tester.pumpAndSettle();
    }

    testWidgets('log spending from the sheet, then add a money habit', (tester) async {
      final s = (await tester.runAsync(state))!;
      await s.updateFinance((f) => f.currency = 'AED');
      await pump(tester, MoneyScreen(state: s));
      await tester.tap(find.byKey(const Key('money-add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('money-amount')), '40');
      await tester.tap(find.textContaining('Transport'));
      await tester.enterText(find.byKey(const Key('money-note')), 'Taxi');
      await tester.tap(find.byKey(const Key('money-save')));
      await tester.pumpAndSettle();
      expect(s.finance.entries.single.category, 'Transport');
      expect(find.text('Taxi'), findsWidgets);

      await tester.scrollUntilVisible(find.byKey(const Key('money-habit-no-spend')), 300);
      await tester.tap(find.byKey(const Key('money-habit-no-spend')));
      await tester.pumpAndSettle();
      expect(s.habits.where((h) => h.templateId == 'no-spend'), hasLength(1));
      expect(find.byKey(const Key('money-habit-no-spend')), findsNothing);
    });

    testWidgets('correct the 31st entry from the ledger without changing its ID', (tester) async {
      final s = (await tester.runAsync(state))!;
      await s.updateFinance((f) {
        f.currency = 'AED';
        for (var i = 0; i < 31; i++) {
          f.entries.add(MoneyEntry(at: DateTime(2025, 1, i + 1), amount: 100, category: 'Food', note: 'Receipt ${i + 1}'));
        }
      });
      final id = s.finance.entries.first.id;
      await pump(tester, LedgerScreen(state: s));
      await tester.scrollUntilVisible(find.text('Receipt 1'), 350);
      await tester.tap(find.text('Receipt 1'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('money-amount')), '2.50');
      await tester.tap(find.byKey(const Key('money-save')));
      await tester.pumpAndSettle();
      expect(s.finance.entries, hasLength(31));
      expect(s.finance.entries.first.id, id);
      expect(s.finance.month(DateTime(2025, 1)).spent, 3250);
    });

    testWidgets('unpriced gold hides the paid shortcut even with silver nisab priced', (tester) async {
      final s = (await tester.runAsync(state))!;
      await s.updateFinance((f) => f.zakat = ZakatInfo(cash: 1000000, goldGrams: 100, silverPricePerGram: 300));
      await pump(tester, ZakatScreen(state: s));
      expect(find.text('Estimate incomplete'), findsOneWidget);
      expect(find.textContaining('Missing price per gram: gold'), findsOneWidget);
      expect(find.textContaining('I paid'), findsNothing);
      await tester.enterText(find.byKey(const Key('zakat-gold-price')), '50');
      await tester.pumpAndSettle();
      expect(find.textContaining('I paid'), findsOneWidget);
    });

    testWidgets('Today shows the Money card once money is logged', (tester) async {
      final s = (await tester.runAsync(state))!;
      expect(todayItems(s, now).any((i) => i.kind == TodayKind.money), isFalse);
      await s.addMoney(MoneyEntry(at: now, amount: 500, category: 'Food'));
      expect(todayItems(s, now).firstWhere((i) => i.kind == TodayKind.money).done, isTrue);
      await pump(
        tester,
        Scaffold(
          body: MoneyTodayCard(state: s, now: now),
        ),
      );
      expect(find.byKey(const Key('today-log-spend')), findsOneWidget);
    });

    testWidgets('Zakat keeps what you typed when you go back', (tester) async {
      final s = (await tester.runAsync(state))!;
      await pump(
        tester,
        Scaffold(
          body: Builder(
            builder: (c) => TextButton(
              onPressed: () => Navigator.of(c).push(MaterialPageRoute<void>(builder: (_) => ZakatScreen(state: s))),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.byKey(const Key('zakat-silver-price'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const Key('zakat-gold-price'))).dy),
      );
      await tester.enterText(find.byKey(const Key('zakat-silver-price')), '3.5');
      await tester.enterText(find.byKey(const Key('zakat-cash')), '10000');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(s.finance.zakat.cash, 1000000);
      expect(calculateZakat(s.finance.zakat).due, 25000);
    });

    testWidgets('the currency picker requires a separate ledger for a populated currency', (tester) async {
      final s = (await tester.runAsync(state))!;
      await s.updateFinance((f) => f.currency = 'AED');
      await s.addMoney(MoneyEntry(at: now, amount: 1250, category: 'Food'));
      await pump(tester, Scaffold(body: Builder(builder: (c) =>
        TextButton(onPressed: () => pickCurrency(c, s), child: const Text('Choose ledger')))));
      Future<void> select() async {
        await tester.tap(find.text('Choose ledger'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('KWD'));
        await tester.pumpAndSettle();
      }
      await select();
      expect(s.finance.currency, 'AED');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(s.finance.ledgerCurrencies, {'AED'});
      await select();
      await tester.tap(find.text('Create ledger'));
      await tester.pumpAndSettle();
      expect(s.finance.currency, 'KWD');
      expect(s.finance.entries, isEmpty);
      await s.updateFinance((f) => f.openLedger('AED'));
      expect(s.finance.fmt(s.finance.entries.single.amount), 'AED 12.50');
    });

    testWidgets('Settings → Money changes the currency', (tester) async {
      final s = (await tester.runAsync(state))!;
      await s.updateFinance((f) => f.currency = 'USD');
      await pump(tester, Scaffold(body: SettingsScreen(state: s)));
      await tester.tap(find.byKey(const ValueKey('settings-money')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-currency')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SAR'));
      await tester.pumpAndSettle();
      expect(s.finance.currency, 'SAR');
      expect(find.text('SAR'), findsOneWidget);
    });
  });
}
