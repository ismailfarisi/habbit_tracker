import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:habit_tracker/finance/finance.dart';
import 'package:habit_tracker/finance/finance_agenda.dart';
import 'package:habit_tracker/logic/hijri.dart';

void main() {
  final jan = DateTime(2027, 1, 1);

  test('private debt reminders survive ledger switching, snooze and repayment', () {
    final d = Debt(person: 'Example lender', amount: 3400, due: DateTime(2027, 1, 5));
    final f = Finance(currency: 'AED', debts: [d]);
    expect(financeAgenda(f, d.due!), isEmpty);
    d.reminder.setEnabled(true, jan);
    final item = financeAgenda(f, d.due!).single;
    expect(item.privateTitle, 'Personal reminder');
    expect(item.detail, contains('Example lender'));
    final moved = DateTime(2027, 1, 9);
    item.snooze(moved);
    f.openLedger('KWD');
    final back = Finance.fromJson(jsonDecode(jsonEncode(f.toJson())));
    expect(financeAgenda(back, d.due!), isEmpty);
    expect(financeAgenda(back, moved).single.id, item.id);
    back.openLedger('AED');
    back.entries.add(MoneyEntry(at: moved, amount: 3400, category: 'Debt', debtId: d.id));
    expect(financeAgenda(back, moved), isEmpty);
    back.entries.clear();
    expect(financeAgenda(back, moved), hasLength(1));
    back.debts.single.reminder.setEnabled(false, moved);
    expect(financeAgenda(back, moved), isEmpty);
  });

  test('a pot reminds monthly through its target, including a short month', () {
    final p = SavingsPot(name: 'Example fund', target: 10000, by: DateTime(2027, 3, 31));
    final f = Finance(pots: [p]);
    p.reminder.setEnabled(true, jan);
    final due = DateTime(2027, 2, 28);
    expect(financeAgenda(f, due), hasLength(1));
    f.entries.add(MoneyEntry(at: DateTime(2027, 2, 2), amount: 1000, category: 'Savings', potId: p.id));
    expect(financeAgenda(f, due), isEmpty);
    expect(financeAgenda(f, p.by!), hasLength(1));
    expect(financeAgenda(f, DateTime(2027, 4, 30)), isEmpty);
    f.entries.add(MoneyEntry(at: p.by!, amount: 9000, category: 'Savings', potId: p.id));
    expect(financeAgenda(f, p.by!), isEmpty);
  });

  test('30th anniversary follows both month lengths and the selected Hijri offset', () {
    for (final length in [29, 30]) {
      final end = List.generate(365, (i) => DateTime(2027, 1, 1 + i)).firstWhere((d) =>
        hijriOf(d).day == length && hijriOf(DateTime(d.year, d.month, d.day + 1)).day == 1);
      final z = ZakatInfo(hijriMonth: hijriOf(end).month, hijriDay: 30);
      z.reminder.setEnabled(true, DateTime(2026));
      final f = Finance(zakat: z);
      expect(financeAgenda(f, end), hasLength(1));
      final shifted = DateTime(end.year, end.month, end.day - 1);
      expect(financeAgenda(f, shifted, hijriOffsetDays: 1), hasLength(1));
      expect(financeAgenda(f, end, hijriOffsetDays: 1), isEmpty);
      f.entries.add(MoneyEntry(at: shifted, amount: 1000, category: 'Zakat'));
      expect(financeAgenda(f, shifted, hijriOffsetDays: 1), isEmpty);
      f.entries.clear();
      expect(financeAgenda(f, shifted, hijriOffsetDays: 1), hasLength(1));
    }
  });

  test('monthly plan counts bills inside their budgets and deducts only remaining contributions', () {
    final p = SavingsPot(name: 'Hajj', target: 60000, by: DateTime(2027, 3, 10));
    final f = Finance(pots: [p], budgets: {'Housing': 24000, 'Food': 5000});
    f.customCategories.add('Housing');
    f.recurring.add(RecurringExpense(name: 'Rent', category: 'Housing', amount: 20000));
    f.entries.addAll([
      MoneyEntry(at: jan, amount: 60000, income: true, category: 'Salary'),
      MoneyEntry(at: jan, amount: 20000, category: 'Housing'),
      MoneyEntry(at: jan, amount: 10000, category: 'Savings', potId: p.id),
    ]);
    expect(f.month(jan).left, 30000);
    expect(f.afterPlannedExpenses(jan), 21000);
    expect(f.monthlyContribution(p, jan), 20000);
    expect(f.contributionLeftThisMonth(p, jan), 10000);
    p.by = DateTime(2027, 4, 10);
    expect(f.contributionLeftThisMonth(p, jan), 5000);
    expect(f.potSaved(p.id), 10000);
    final back = Finance.fromJson(jsonDecode(jsonEncode(f.toJson())));
    expect(back.expenseCategories, contains('Housing'));
    expect(back.recurring.single.name, 'Rent');
    expect(back.afterPlannedExpenses(jan), 21000);
  });
}
