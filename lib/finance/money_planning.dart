part of 'money_screen.dart';

class _MonthlyPlan extends StatelessWidget {
  final AppState state;
  const _MonthlyPlan({required this.state});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      final f = state.finance;
      final today = DateTime.now(), m = f.month(today);
      final available = f.afterPlannedExpenses(today);
      final pots = f.pots.where((p) => !p.archived && p.by != null && p.target > f.potSaved(p.id));
      final contributions = pots.fold<int>(0, (s, p) => s + f.contributionLeftThisMonth(p, today));
      final after = available - contributions;
      return Scaffold(
        appBar: AppBar(title: Text(DateFormat.yMMMM().format(today))),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SectionCard(
              title: 'Monthly plan',
              icon: Icons.calendar_month_outlined,
              children: [
                Text('Logged net cash flow · ${f.fmt(m.left, sign: true)}'),
                Text('After remaining budgets and expected bills · ${f.fmt(available, sign: true)}'),
                if (pots.isNotEmpty)
                  Text(
                    after < 0
                        ? 'Short by ${f.fmt(-after)} after planned savings'
                        : '${f.fmt(after)} left after planned savings',
                  ),
                const _Hint('Uses income logged so far. Bills count toward their category budget.'),
                TextButton(
                  onPressed: () => _openResource(context, moneyResources.firstWhere((r) => r.id == 'budget')),
                  child: const Text('Build a simple budget'),
                ),
              ],
            ),
            SectionCard(
              title: 'Expected monthly expenses',
              trailing: TextButton(onPressed: () => _bill(context), child: const Text('Add')),
              children: [
                if (f.recurring.isEmpty) const _Hint('Plan regular bills here. Log the actual payment in the ledger.'),
                for (final r in f.recurring)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(r.name),
                    subtitle: Text('${r.category} · ${f.fmt(r.amount)}/month'),
                    trailing: const Icon(Icons.edit_outlined),
                    onTap: () => _bill(context, bill: r),
                  ),
              ],
            ),
            SectionCard(
              title: 'Savings contributions',
              children: [
                if (pots.isEmpty) const _Hint('Set a target date on a savings pot to plan its contributions.'),
                for (final p in pots)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(p.name),
                    subtitle: Text(
                      '${f.fmt(f.monthlyContribution(p, today))}/month through ${DateFormat.yMMM().format(p.by!)} · ${f.fmt(f.contributionLeftThisMonth(p, today))} left this month',
                    ),
                    trailing: const Icon(Icons.edit_outlined),
                    onTap: () => editPot(context, state, pot: p),
                  ),
              ],
            ),
            SectionCard(
              title: 'Spending categories',
              trailing: TextButton(onPressed: () => _category(context), child: const Text('Add')),
              children: [
                Text(
                  f.customCategories.isEmpty
                      ? 'Add a category to use in budgets, expenses and the ledger.'
                      : f.customCategories.join(' · '),
                ),
              ],
            ),
            ListTile(
              title: const Text('Personal reminders'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () =>
                  Navigator.push(context, MaterialPageRoute<void>(builder: (_) => _FinanceReminders(state: state))),
            ),
          ],
        ),
      );
    },
  );

  Future<void> _category(BuildContext context) async {
    var name = '', error = '';
    final f = state.finance;
    final result = await showDialog<String>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('New spending category'),
          content: TextField(
            autofocus: true,
            maxLength: 60,
            decoration: InputDecoration(labelText: 'Name', errorText: error.isEmpty ? null : error),
            onChanged: (s) => name = s.trim(),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                if (name.isEmpty ||
                    [...f.expenseCategories, ...incomeCategories].any((v) => v.toLowerCase() == name.toLowerCase())) {
                  set(() => error = 'Enter a new category name');
                } else {
                  Navigator.pop(c, name);
                }
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    if (result != null) {
      await state.updateFinance((f) => f.customCategories.add(result));
    }
  }

  Future<void> _bill(BuildContext context, {RecurringExpense? bill}) async {
    final f = state.finance;
    var name = bill?.name ?? '', category = bill?.category ?? 'Rent & bills';
    var amount = bill?.amount, showErrors = false;
    final action = await showDialog<String>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          scrollable: true,
          title: Text(bill == null ? 'Expected monthly expense' : 'Edit monthly expense'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                initialValue: name,
                autofocus: bill == null,
                maxLength: 100,
                decoration: InputDecoration(
                  labelText: 'Name',
                  errorText: showErrors && name.isEmpty ? 'Enter a name' : null,
                ),
                onChanged: (s) => name = s.trim(),
              ),
              TextFormField(
                initialValue: amount == null ? '' : toMajor(amount!, f.currency).toString(),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: 'Monthly amount',
                  suffixText: f.currency,
                  errorText: showErrors && amount == null ? 'Enter a positive amount' : null,
                ),
                onChanged: (s) => amount = parseMoney(s, f.currency),
              ),
              DropdownButtonFormField<String>(
                initialValue: category,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Category'),
                items: [
                  for (final v in f.expenseCategories.where((v) => v != 'Savings' && v != 'Debt'))
                    DropdownMenuItem(value: v, child: Text(v)),
                ],
                onChanged: (v) => category = v ?? category,
              ),
            ],
          ),
          actions: [
            if (bill != null) TextButton(onPressed: () => Navigator.pop(c, 'remove'), child: const Text('Remove')),
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                if (amount == null || name.isEmpty) {
                  set(() => showErrors = true);
                } else {
                  Navigator.pop(c, 'save');
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (action == null) return;
    await state.updateFinance((f) {
      f.recurring.removeWhere((r) => r.id == bill?.id);
      if (action == 'save') {
        f.recurring.add(RecurringExpense(id: bill?.id, name: name, category: category, amount: amount!));
      }
    });
  }
}

class _FinanceReminders extends StatelessWidget {
  final AppState state;
  const _FinanceReminders({required this.state});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      final today = DateTime.now();
      final plans = financePlans(state.finance, hijriOffsetDays: state.settings.hijriOffsetDays).toList();
      return Scaffold(
        appBar: AppBar(title: const Text('Personal reminders')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('Choose which dates appear in your calendar. With reminders enabled, your phone shows “Personal reminder” at 9:00 AM local time. Amounts and names stay inside the app.'),
            if (plans.isEmpty)
              const ListTile(title: Text('Add a dated debt, savings pot or zakat anniversary to get started.')),
            for (final plan in plans) ...[
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: Text(plan.detail),
                value: plan.reminder.enabled,
                onChanged: (v) => state.updateFinance((_) => plan.reminder.setEnabled(v, today)),
              ),
              if (plan.next(today) case final FinanceAgendaItem item)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(DateFormat.yMMMd().format(item.date)),
                  trailing: TextButton(
                    onPressed: () async {
                      final first = (item.date.isAfter(today) ? item.date : today).add(const Duration(days: 1));
                      final d = await showDatePicker(
                        context: context,
                        firstDate: first,
                        initialDate: first,
                        lastDate: DateTime(first.year + 5),
                      );
                      if (d != null) {
                        await state.updateFinance((_) => item.snooze(d));
                      }
                    },
                    child: const Text('Snooze'),
                  ),
                ),
            ],
          ],
        ),
      );
    },
  );
}
