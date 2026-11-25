import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:habit_tracker/app_state.dart';
import 'package:habit_tracker/finance/finance.dart';
import 'package:habit_tracker/finance/money_resources.dart';
import 'package:habit_tracker/logic/hijri.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(mockPlugins);

  Future<AppState> state() => loadState({'settings.v1': jsonEncode({'onboarded': true})});
  final now = DateTime(2026, 11, 25, 15);

  group('money amounts', () {
    test('parse and format in minor units', () {
      expect(parseMoney('12.5', 'AED'), 1250);
      expect(parseMoney('1,200', 'USD'), 120000);
      expect(parseMoney('1.234', 'KWD'), 1234);
      expect(parseMoney('abc', 'USD'), isNull);
      expect(parseMoney('0', 'USD'), isNull);
      expect(formatMoney(125050, 'AED'), 'AED 1,250.50');
      expect(formatMoney(120000, 'USD'), 'USD 1,200');
      expect(formatMoney(-500, 'USD'), '−USD 5');
      expect(toMinor(19.99, 'USD'), 1999);
    });

    test('ledger selection keeps every amount and its minor units together in backups', () async {
      final s = await state();
      await s.updateFinance((f) => f.currency = 'AED');
      await s.addMoney(MoneyEntry(at: now, amount: 1250, category: 'Food'));
      await s.setBudget('Food', 7500);
      await s.updateFinance((f) => f.openLedger('KWD'));
      await s.addMoney(MoneyEntry(at: now, amount: 1250, category: 'Rent & bills'));
      final backup = s.storage.exportJson();
      await s.importBackup(backup);
      expect(s.finance.fmt(s.finance.entries.single.amount), 'KWD 1.250');
      expect(s.finance.budgets, isEmpty);
      await s.updateFinance((f) => f.openLedger('AED'));
      expect(s.finance.fmt(s.finance.entries.single.amount), 'AED 12.50');
      expect(s.finance.budgets['Food'], 7500);
      expect(() => s.finance.currency = 'KWD', throwsStateError);
    });

    test('all stored balance types guard against a currency change', () {
      for (final f in [
        Finance(budgets: {'Food': 1}),
        Finance(pots: [SavingsPot(name: 'Example', target: 1)]),
        Finance(debts: [Debt(person: 'Example', amount: 1)]),
        Finance(zakat: ZakatInfo(debtsDue: 1)), Finance(zakat: ZakatInfo(goldGrams: 1)),
        Finance(zakat: ZakatInfo(businessStock: 1)), Finance(zakat: ZakatInfo(silverPricePerGram: 1)),
      ]) {
        expect(() => f.currency = 'KWD', throwsStateError);
        expect(f.currency, 'USD');
      }
    });

    test('currency guess from locale', () {
      expect(currencyForLocale('en_AE'), 'AED');
      expect(currencyForLocale('ur-PK'), 'PKR');
      expect(currencyForLocale('en'), 'USD');
    });
  });

  group('zakat', () {
    test('2.5% of net wealth above the silver nisab', () {
      final z = ZakatInfo(silverPricePerGram: 300, cash: 500000, investments: 200000, debtsDue: 100000);
      final r = calculateZakat(z, potSavings: 100000);
      expect(r.nisab, 178500); // 595 g × 3.00
      expect(r.assets, 800000);
      expect(r.net, 700000);
      expect(r.due, 17500);
      expect(r.aboveNisab, isTrue);
    });

    test('nothing due below the nisab or without a price', () {
      final gold = ZakatInfo(nisabBasis: 'gold', goldPricePerGram: 30000, cash: 2000000);
      expect(calculateZakat(gold).nisab, 2550000);
      expect(calculateZakat(gold).due, 0);
      final noPrice = calculateZakat(ZakatInfo(cash: 9999999));
      expect(noPrice.hasNisab, isFalse);
      expect(noPrice.due, isNull);
    });

    test('gold and silver held are valued by weight; pots can be left out', () {
      final z = ZakatInfo(silverPricePerGram: 300, goldPricePerGram: 30000, goldGrams: 10, silverGrams: 100, includePots: false);
      final r = calculateZakat(z, potSavings: 999999);
      expect(r.assets, 300000 + 30000);
      expect(r.due, 8250);
    });

    test('next zakat date lands on the chosen Hijri day', () {
      final d = nextHijriDate(9, 1, now)!; // 1 Ramadan
      expect(hijriOf(d).month, 9);
      expect(hijriOf(d).day, 1);
      expect(d.isBefore(now), isFalse);
      expect(d.difference(now).inDays, lessThan(356));
    });

    test('ZakatInfo round-trips through JSON', () {
      final z = ZakatInfo(nisabBasis: 'gold', goldPricePerGram: 1, goldGrams: 2.5, hijriMonth: 9, hijriDay: 1, lastPaid: DateTime(2026, 3, 1));
      final back = ZakatInfo.fromJson(jsonDecode(jsonEncode(z.toJson())) as Map<String, dynamic>);
      expect(back.toJson(), z.toJson());
    });
  });

  group('finance', () {
    test('month summary keeps savings and pot moves out of spending', () {
      final f = Finance(currency: 'AED');
      final pot = SavingsPot(name: 'Hajj', target: 1000000);
      f.pots.add(pot);
      f.entries.addAll([
        MoneyEntry(at: now, amount: 1000000, income: true, category: 'Salary'),
        MoneyEntry(at: now, amount: 5000, category: 'Food'),
        MoneyEntry(at: now, amount: 2000, category: 'Sadaqah'),
        MoneyEntry(at: now, amount: 100000, category: 'Savings', potId: pot.id),
        MoneyEntry(at: now, amount: 10000, income: true, category: 'Savings', potId: pot.id),
        MoneyEntry(at: DateTime(2026, 10, 3), amount: 99900, category: 'Food'),
      ]);
      final m = f.month(now);
      expect(m.income, 1000000);
      expect(m.spent, 7000);
      expect(m.saved, 100000);
      expect(m.sadaqah, 2000);
      expect(m.byCategory, {'Food': 5000, 'Sadaqah': 2000});
      expect(f.potSaved(pot.id), 90000);
      expect(f.spentOn(now), 7000);
      expect(f.sadaqahInWeek(now), 2000);
    });

    test('debt repayments come from entries', () {
      final f = Finance();
      final d = Debt(person: 'Ahmed', amount: 50000, iOwe: true);
      final owed = Debt(person: 'Sara', amount: 20000, iOwe: false);
      f.debts.addAll([d, owed]);
      f.entries.add(MoneyEntry(at: now, amount: 15000, category: 'Debt', debtId: d.id));
      f.entries.add(MoneyEntry(at: now, amount: 30000, income: true, category: 'Other income', debtId: owed.id));
      expect(f.debtLeft(d), 35000);
      expect(f.totalIOwe, 35000);
      expect(f.totalOwedToMe, 0);
      expect(f.month(now).income, 0, reason: 'a repayment to you is not income');
    });

    test('saved, restored from backup, and cleared on reset', () async {
      final s = await state();
      await s.updateFinance((f) => f.currency = 'AED');
      await s.addMoney(MoneyEntry(at: now, amount: 1500, category: 'Food', note: 'Lunch'));
      await s.setBudget('Food', 100000);
      await s.upsertPot(SavingsPot(name: 'Hajj', target: 2000000, by: DateTime(2027, 5, 1), goalId: 'g1'));
      await s.upsertDebt(Debt(person: 'Ahmed', amount: 50000, due: DateTime(2027, 1, 1)));
      final backup = s.storage.exportJson();
      expect(s.storage.loadFinance().toJson(), s.finance.toJson());

      await s.resetAll();
      expect(s.finance.isEmpty, isTrue);
      await s.importBackup(backup);
      expect(s.finance.currency, 'AED');
      expect(s.finance.entries.single.note, 'Lunch');
      expect(s.finance.budgets, {'Food': 100000});
      expect(s.finance.potForGoal('g1')!.name, 'Hajj');
      expect(s.finance.debts.single.person, 'Ahmed');
    });

    test('an older backup without money restores to empty money', () async {
      final s = await state();
      await s.addMoney(MoneyEntry(at: now, amount: 1500, category: 'Food'));
      final j = jsonDecode(s.storage.exportJson()) as Map<String, dynamic>..remove('finance');
      await s.importBackup(jsonEncode(j));
      expect(s.finance.entries, isEmpty);
    });

    test('deleting a pot keeps its entries but unlinks them', () async {
      final s = await state();
      final p = SavingsPot(name: 'Umrah', target: 100);
      await s.upsertPot(p);
      await s.addMoney(MoneyEntry(at: now, amount: 50, category: 'Savings', potId: p.id));
      await s.deletePot(p.id);
      expect(s.finance.entries.single.potId, isNull);
    });
  });

  group('resources', () {
    final quran = {
      for (final l in File('assets/quran/quran-uthmani.txt').readAsLinesSync())
        if (l.split('|') case [final s, final a, final t]) '$s:$a': t,
    };

    test('every ayah quoted is the verbatim Tanzil text', () {
      final ayat = moneyResources.firstWhere((r) => r.id == 'ayat').markdown;
      final refs = RegExp(r'\((?:[^()]*) (\d+:\d+)\)').allMatches(ayat).map((m) => m.group(1)!).toSet();
      expect(refs.length, greaterThanOrEqualTo(10));
      for (final r in refs) {
        final ayah = r.split(':')[1];
        expect(ayat, contains('${quran[r]} ($ayah)'), reason: r);
      }
    });

    test('hadith cite their references and every guide carries the disclaimer', () {
      final hadith = moneyResources.firstWhere((r) => r.id == 'hadith').markdown;
      for (final ref in moneyHadithRefs) {
        expect(hadith, contains('— $ref'));
      }
      for (final r in moneyResources.where((r) => r.id != 'ayat' && r.id != 'hadith')) {
        expect(r.markdown, contains('not a fatwa'), reason: r.id);
      }
    });

    test('ayat quoted in the guides match the translation in the library', () {
      final ayat = moneyResources.firstWhere((r) => r.id == 'ayat').markdown;
      for (final r in moneyResources) {
        for (final m in RegExp(r'Quran \d+:\d+ (?:says|describes[^"]*) "([^"]+)"').allMatches(r.markdown)) {
          expect(ayat, contains(m.group(1)!.replaceAll(RegExp(r'\.$'), '')), reason: '${r.id}: ${m.group(1)}');
        }
      }
    });
  });
}
