import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../agent/habit_templates.dart';
import '../app_state.dart';
import '../logic/hijri.dart';
import '../widgets/adaptive.dart';
import '../widgets/ask_chat.dart';
import '../widgets/cards/section_card.dart';
import '../widgets/document_viewer.dart';
import 'finance.dart';
import 'finance_agenda.dart';
import 'money_resources.dart';
import 'ledger_csv.dart';

part 'ledger_screen.dart';
part 'money_planning.dart';

void openMoney(BuildContext context, AppState state) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => MoneyScreen(state: state)));

/// Plan's entry to the Money screen.
class MoneyEntryCard extends StatelessWidget {
  final AppState state;
  const MoneyEntryCard({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final f = state.finance;
    final m = f.month(DateTime.now());
    final budget = f.budgets.values.fold(0, (a, b) => a + b);
    return Card(
      child: ListTile(
        key: const Key('open-money'),
        leading: const Icon(Icons.account_balance_wallet_outlined),
        title: const Text('Money'),
        subtitle: Text(
          f.isEmpty
              ? 'Spending, budgets, savings pots, debts and zakat'
              : 'Spent ${f.fmt(m.spent)} this month${budget > 0 ? ' of ${f.fmt(budget)}' : ''}',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => openMoney(context, state),
      ),
    );
  }
}

/// Today's money card: what was spent today and a quick way to log.
class MoneyTodayCard extends StatelessWidget {
  final AppState state;
  final DateTime now;
  const MoneyTodayCard({super.key, required this.state, required this.now});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = state.finance;
    final m = f.month(now);
    final budget = f.budgets.values.fold(0, (a, b) => a + b);
    final logged = f.onDay(now).isNotEmpty;
    return SectionCard(
      title: 'Money',
      emoji: '💰',
      onTitleTap: () => openMoney(context, state),
      trailing: CountBadge(logged ? f.fmt(f.spentOn(now)) : 'Not logged'),
      children: [
        if (budget > 0) ...[
          BudgetBar(spent: m.spent, limit: budget, label: 'This month', f: f),
          const SizedBox(height: 8),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            FilledButton.tonalIcon(
              key: const Key('today-log-spend'),
              style: compactButton,
              onPressed: () => showMoneySheet(context, state),
              icon: const Icon(Icons.remove),
              label: const Text('Spent'),
            ),
            OutlinedButton.icon(
              style: compactButton,
              onPressed: () => showMoneySheet(context, state, income: true),
              icon: const Icon(Icons.add),
              label: const Text('Income'),
            ),
            if (!logged)
              TextButton(
                style: compactButton,
                onPressed: () =>
                    state.addMoney(MoneyEntry(at: now, amount: 0, category: 'Other', note: 'No spending today')),
                child: const Text('No spend today'),
              ),
          ],
        ),
        if (f.sadaqahInWeek(now) > 0)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '🤲 Sadaqah this week: ${f.fmt(f.sadaqahInWeek(now))}',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
          ),
      ],
    );
  }
}

class BudgetBar extends StatelessWidget {
  final int spent, limit;
  final String label;
  final Finance f;
  const BudgetBar({super.key, required this.spent, required this.limit, required this.label, required this.f});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final over = spent > limit;
    final left = limit - spent;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(label, style: t.textTheme.bodyMedium)),
            Text(
              over ? '${f.fmt(-left)} over' : '${f.fmt(left)} left',
              style: t.textTheme.bodySmall?.copyWith(
                color: over ? t.colorScheme.error : t.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            minHeight: 6,
            value: limit <= 0 ? 0 : (spent / limit).clamp(0, 1).toDouble(),
            color: over ? t.colorScheme.error : null,
          ),
        ),
      ],
    );
  }
}

class MoneyScreen extends StatelessWidget {
  final AppState state;
  const MoneyScreen({super.key, required this.state});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      final f = state.finance;
      final now = DateTime.now();
      return Scaffold(
        appBar: AppBar(
          title: const Text('Money'),
          actions: [
            IconButton(
              tooltip: 'Plan with the coach',
              icon: const Icon(Icons.auto_awesome_outlined),
              onPressed: () =>
                  askChat(state, 'Help me plan my money this month: a budget, savings and sadaqah.', context: context),
            ),
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'currency') {
                  pickCurrency(context, state);
                } else {
                  Navigator.push(context, MaterialPageRoute<void>(builder: (_) => _FinanceReminders(state: state)));
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'currency', child: Text('Currency · ${f.currency}')),
                const PopupMenuItem(value: 'reminders', child: Text('Personal reminders')),
              ],
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          key: const Key('money-add'),
          onPressed: () => showMoneySheet(context, state),
          icon: const Icon(Icons.add),
          label: const Text('Log'),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
          children: [
            _MonthCard(f: f, now: now),
            _BudgetsCard(state: state, now: now),
            _PotsCard(state: state),
            _DebtsCard(state: state),
            _ZakatCard(state: state),
            _RecentCard(state: state),
            _HabitsCard(state: state),
            const _ResourcesCard(),
          ],
        ),
      );
    },
  );
}

class _MonthCard extends StatelessWidget {
  final Finance f;
  final DateTime now;
  const _MonthCard({required this.f, required this.now});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final m = f.month(now);
    Widget stat(String label, int v) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 2),
          Text(f.fmt(v), style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
        ],
      ),
    );
    return SectionCard(
      title: DateFormat.yMMMM().format(now),
      icon: Icons.calendar_view_month_outlined,
      children: [
        Row(children: [stat('In', m.income), stat('Spent', m.spent), stat('To savings', m.saved)]),
        const SizedBox(height: 8),
        Text(
          'Today ${f.fmt(f.spentOn(now))} · Sadaqah this week ${f.fmt(f.sadaqahInWeek(now))}'
          ' · Net cash flow ${f.fmt(m.left, sign: true)}',
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _BudgetsCard extends StatelessWidget {
  final AppState state;
  final DateTime now;
  const _BudgetsCard({required this.state, required this.now});

  @override
  Widget build(BuildContext context) {
    final f = state.finance;
    final m = f.month(now);
    return SectionCard(
      title: 'Budgets',
      icon: Icons.pie_chart_outline,
      trailing: TextButton(style: compactButton, onPressed: () => _editBudget(context), child: const Text('Set')),
      children: [
        TextButton.icon(
          onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => _MonthlyPlan(state: state))),
          icon: const Icon(Icons.calendar_month_outlined), label: const Text('Plan this month'),
        ),
        if (f.budgets.isEmpty)
          const _Hint('Give a category a monthly limit, e.g. Food 1,200. A bar shows what is left.'),
        for (final e in f.budgets.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: InkWell(
              onTap: () => _editBudget(context, category: e.key),
              child: BudgetBar(
                spent: m.usedFor(e.key),
                limit: e.value,
                label: '${categoryEmoji[e.key] ?? ''} ${e.key}',
                f: f,
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _editBudget(BuildContext context, {String? category}) async {
    final f = state.finance;
    var cat = category ?? f.expenseCategories.firstWhere((c) => !f.budgets.containsKey(c), orElse: () => 'Food');
    final ctl = TextEditingController(text: f.budgets[cat] == null ? '' : '${toMajor(f.budgets[cat]!, f.currency)}');
    final res = await showDialog<int>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Monthly budget'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: cat,
                items: [for (final c in {...f.expenseCategories, cat}) DropdownMenuItem(value: c, child: Text(c))],
                onChanged: (v) => set(() => cat = v ?? cat),
              ),
              TextField(
                controller: ctl,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: 'Limit per month', suffixText: f.currency),
              ),
            ],
          ),
          actions: [
            if (f.budgets.containsKey(cat))
              TextButton(onPressed: () => Navigator.pop(c, 0), child: const Text('Remove')),
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(c, parseMoney(ctl.text, f.currency) ?? -1),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (res != null && res >= 0) await state.setBudget(cat, res);
  }
}

class _PotsCard extends StatelessWidget {
  final AppState state;
  const _PotsCard({required this.state});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = state.finance;
    final pots = f.pots.where((p) => !p.archived).toList();
    return SectionCard(
      title: 'Savings pots',
      icon: Icons.savings_outlined,
      trailing: TextButton(style: compactButton, onPressed: () => editPot(context, state), child: const Text('New')),
      children: [
        if (pots.isEmpty) const _Hint('Save towards something: Hajj, an emergency fund, Umrah, a wedding.'),
        for (final p in pots)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Text(p.emoji, style: const TextStyle(fontSize: 24)),
            title: Text(p.name),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                LinearProgressIndicator(
                  value: p.target <= 0 ? 0 : (f.potSaved(p.id) / p.target).clamp(0, 1).toDouble(),
                ),
                const SizedBox(height: 4),
                Text(
                  '${f.fmt(f.potSaved(p.id))} of ${f.fmt(p.target)}${p.by == null ? '' : ' · by ${DateFormat.yMMMd().format(p.by!)}'}'
                  '${_perMonth(f, p)}',
                  style: t.textTheme.bodySmall,
                ),
              ],
            ),
            trailing: IconButton(
              tooltip: 'Add to ${p.name}',
              icon: const Icon(Icons.add_circle_outline),
              onPressed: () => showMoneySheet(context, state, category: 'Savings', potId: p.id),
            ),
            onTap: () => editPot(context, state, pot: p),
          ),
      ],
    );
  }

  static String _perMonth(Finance f, SavingsPot p) {
    final left = p.target - f.potSaved(p.id);
    if (p.by == null || left <= 0) return left <= 0 ? ' · reached 🎉' : '';
    final now = DateTime.now();
    return ' · ${f.fmt(f.monthlyContribution(p, now))}/month';
  }
}

Future<void> editPot(BuildContext context, AppState state, {SavingsPot? pot}) async {
  final f = state.finance;
  final name = TextEditingController(text: pot?.name ?? '');
  final target = TextEditingController(text: pot == null ? '' : '${toMajor(pot.target, f.currency)}');
  var by = pot?.by;
  var goalId = pot?.goalId;
  final res = await showDialog<String>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        scrollable: true,
        title: Text(pot == null ? 'New savings pot' : 'Edit pot'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              autofocus: pot == null,
              decoration: const InputDecoration(labelText: 'Name, e.g. Hajj fund'),
            ),
            TextField(
              controller: target,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: 'Target', suffixText: f.currency),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(by == null ? 'No target date' : 'By ${DateFormat.yMMMd().format(by!)}'),
              trailing: const Icon(Icons.event_outlined),
              onTap: () async {
                final d = await showDatePicker(
                  context: c,
                  firstDate: by != null && by!.isBefore(DateTime.now()) ? by! : DateTime.now(),
                  lastDate: DateTime(DateTime.now().year + 30),
                  initialDate: by ?? DateTime.now().add(const Duration(days: 365)),
                );
                if (d != null) set(() => by = d);
              },
            ),
            if (state.goals.isNotEmpty || goalId != null)
              DropdownButtonFormField<String>(
                initialValue: goalId, isExpanded: true,
                decoration: const InputDecoration(labelText: 'Linked goal'),
                items: [
                  const DropdownMenuItem(child: Text('No goal')),
                  for (final g in state.goals) DropdownMenuItem(value: g.id, child: Text(g.title)),
                  if (goalId != null && state.goalById(goalId!) == null)
                    DropdownMenuItem(value: goalId, child: const Text('Previous goal')),
                ],
                onChanged: (v) => set(() => goalId = v),
              ),
          ],
        ),
        actions: [
          if (pot != null) TextButton(onPressed: () => Navigator.pop(c, 'delete'), child: const Text('Delete')),
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, 'save'), child: const Text('Save')),
        ],
      ),
    ),
  );
  if (res == 'delete' && pot != null) return state.deletePot(pot.id);
  final amount = parseMoney(target.text, f.currency);
  if (res != 'save' || name.text.trim().isEmpty || amount == null) return;
  await state.upsertPot(
    (pot ?? SavingsPot(name: '', target: 0))
      ..name = name.text.trim()
      ..target = amount
      ..by = by
      ..goalId = goalId,
  );
}

class _DebtsCard extends StatelessWidget {
  final AppState state;
  const _DebtsCard({required this.state});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = state.finance;
    final debts = f.debts.where((d) => !d.archived).toList();
    return SectionCard(
      title: 'Debts',
      icon: Icons.handshake_outlined,
      trailing: TextButton(style: compactButton, onPressed: () => editDebt(context, state), child: const Text('Add')),
      children: [
        if (debts.isEmpty) const _Hint('"When you contract a debt for a specified term, write it down" (2:282).'),
        if (debts.isNotEmpty)
          Text('You owe ${f.fmt(f.totalIOwe)} · owed to you ${f.fmt(f.totalOwedToMe)}', style: t.textTheme.bodySmall),
        for (final d in debts)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(d.iOwe ? Icons.call_made : Icons.call_received),
            title: Text(d.iOwe ? 'To ${d.person}' : 'From ${d.person}'),
            subtitle: Text(
              f.debtLeft(d) == 0
                  ? 'Settled ✓'
                  : '${f.fmt(f.debtLeft(d))} left of ${f.fmt(d.amount)}'
                        '${d.due == null ? '' : ' · due ${DateFormat.yMMMd().format(d.due!)}'}',
            ),
            trailing: f.debtLeft(d) == 0
                ? IconButton(
                    tooltip: 'Archive',
                    icon: const Icon(Icons.archive_outlined),
                    onPressed: () => state.upsertDebt(d..archived = true),
                  )
                : TextButton(
                    style: compactButton,
                    onPressed: () => showMoneySheet(
                      context,
                      state,
                      income: !d.iOwe,
                      category: d.iOwe ? 'Debt' : 'Other income',
                      debtId: d.id,
                    ),
                    child: Text(d.iOwe ? 'Pay' : 'Received'),
                  ),
            onTap: () => editDebt(context, state, debt: d),
          ),
      ],
    );
  }
}

Future<void> editDebt(BuildContext context, AppState state, {Debt? debt}) async {
  final f = state.finance;
  final person = TextEditingController(text: debt?.person ?? '');
  final amount = TextEditingController(text: debt == null ? '' : '${toMajor(debt.amount, f.currency)}');
  final note = TextEditingController(text: debt?.note ?? '');
  var iOwe = debt?.iOwe ?? true;
  var due = debt?.due;
  final res = await showDialog<String>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        title: Text(debt == null ? 'Write a debt down' : 'Edit debt'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('I owe')),
                  ButtonSegment(value: false, label: Text('Owed to me')),
                ],
                selected: {iOwe},
                onSelectionChanged: (v) => set(() => iOwe = v.first),
              ),
              TextField(
                controller: person,
                decoration: const InputDecoration(labelText: 'Who'),
              ),
              TextField(
                controller: amount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: 'Amount', suffixText: f.currency),
              ),
              TextField(
                controller: note,
                decoration: const InputDecoration(labelText: 'Note (optional)'),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(due == null ? 'No due date' : 'Due ${DateFormat.yMMMd().format(due!)}'),
                trailing: const Icon(Icons.event_outlined),
                onTap: () async {
                  final d = await showDatePicker(
                    context: c,
                    firstDate: DateTime(2000),
                    lastDate: DateTime(DateTime.now().year + 30),
                    initialDate: due ?? DateTime.now().add(const Duration(days: 30)),
                  );
                  if (d != null) set(() => due = d);
                },
              ),
            ],
          ),
        ),
        actions: [
          if (debt != null) TextButton(onPressed: () => Navigator.pop(c, 'delete'), child: const Text('Delete')),
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, 'save'), child: const Text('Save')),
        ],
      ),
    ),
  );
  if (res == 'delete' && debt != null) return state.deleteDebt(debt.id);
  final a = parseMoney(amount.text, f.currency);
  if (res != 'save' || person.text.trim().isEmpty || a == null) return;
  await state.upsertDebt(
    (debt ?? Debt(person: '', amount: 0))
      ..person = person.text.trim()
      ..amount = a
      ..iOwe = iOwe
      ..due = due
      ..note = note.text.trim(),
  );
}

class _ZakatCard extends StatelessWidget {
  final AppState state;
  const _ZakatCard({required this.state});

  @override
  Widget build(BuildContext context) {
    final f = state.finance;
    final z = f.zakatResult();
    final info = f.zakat;
    final next = info.hijriMonth == null
        ? null
        : nextHijriDate(
            info.hijriMonth!,
            info.hijriDay ?? 1,
            DateTime.now(),
            offsetDays: state.settings.hijriOffsetDays,
          );
    return SectionCard(
      title: 'Zakat',
      emoji: '🌙',
      onTitleTap: () => _open(context),
      trailing: TextButton(
        key: const Key('open-zakat'),
        style: compactButton,
        onPressed: () => _open(context),
        child: const Text('Calculate'),
      ),
      children: [
        Text(
          !z.complete
              ? 'Estimate incomplete · enter the ${z.missingPrices.join(' and ')} price per gram.'
              : z.aboveNisab
              ? 'Zakat due: ${f.fmt(z.due!)} (2.5% of ${f.fmt(z.net)})'
              : 'Below the nisab (${f.fmt(z.nisab)}): no zakat due.',
        ),
        if (next != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Your zakat date: ${hijriOf(next, offsetDays: state.settings.hijriOffsetDays)} · ${DateFormat.yMMMd().format(next)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  void _open(BuildContext context) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ZakatScreen(state: state)));
}

class ZakatScreen extends StatefulWidget {
  final AppState state;
  const ZakatScreen({super.key, required this.state});

  @override
  State<ZakatScreen> createState() => _ZakatScreenState();
}

class _ZakatScreenState extends State<ZakatScreen> {
  late final ZakatInfo z = ZakatInfo.fromJson(widget.state.finance.zakat.toJson());
  String get cur => widget.state.finance.currency;

  Widget _money(String label, int value, void Function(int v) set, {String? help, Key? key}) => TextFormField(
    key: key,
    initialValue: value == 0 ? '' : '${toMajor(value, cur)}'.replaceFirst(RegExp(r'\.0+$'), ''),
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    decoration: InputDecoration(labelText: label, suffixText: cur, helperText: help),
    onChanged: (s) => setState(() {
      set(parseMoney(s, cur) ?? 0);
      z.valuedOn = DateTime.now();
    }),
  );

  Widget _grams(String label, double value, void Function(double v) set) => TextFormField(
    initialValue: value == 0 ? '' : '$value',
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    decoration: InputDecoration(labelText: label, suffixText: 'g'),
    onChanged: (s) => setState(() {
      final grams = double.tryParse(s.trim());
      set(grams != null && grams.isFinite && grams >= 0 ? grams : 0);
      z.valuedOn = DateTime.now();
    }),
  );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = widget.state.finance;
    final r = calculateZakat(z, potSavings: f.totalSaved);
    final today = hijriOf(DateTime.now(), offsetDays: widget.state.settings.hijriOffsetDays);
    final year = z.hijriMonth == null ? null : today.year + (z.hijriMonth! < today.month ? 1 : 0);
    const gap = SizedBox(height: 8);
    final goldPrice = _money(
      'Gold price per gram today',
      z.goldPricePerGram,
      (v) => z.goldPricePerGram = v,
      key: const Key('zakat-gold-price'),
    );
    final silverPrice = _money(
      'Silver price per gram today',
      z.silverPricePerGram,
      (v) => z.silverPricePerGram = v,
      key: const Key('zakat-silver-price'),
    );
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && !_saved) _save(pop: false);
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Zakat calculator')),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Card(
              color: t.colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      !r.complete
                          ? 'Estimate incomplete'
                          : (r.aboveNisab ? 'Zakat due ${f.fmt(r.due!)}' : 'No zakat due'),
                      key: const Key('zakat-result'),
                      style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    if (!r.complete)
                      Text('Missing price per gram: ${r.missingPrices.join(' and ')}.'),
                    for (final a in r.breakdown.entries.where((a) => a.value != 0))
                      Text('${a.key} · ${a.value == null ? 'Unpriced' : f.fmt(a.value!)}'),
                    if (r.liabilities > 0) Text('Debts due · −${f.fmt(r.liabilities)}'),
                    if (r.complete) Text('Net zakatable wealth ${f.fmt(r.net)}${r.hasNisab ? ' · nisab ${f.fmt(r.nisab)}' : ''}'),
                    Text('Valuation date: ${z.valuedOn == null ? 'not recorded' : DateFormat.yMMMd().format(z.valuedOn!)}. '
                        'Estimate assumes a full lunar year above the ${z.nisabBasis} nisab.'),
                  ],
                ),
              ),
            ),
            gap,
            Text('Nisab', style: t.textTheme.titleSmall),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'silver', label: Text('Silver · 595 g')),
                ButtonSegment(value: 'gold', label: Text('Gold · 85 g')),
              ],
              selected: {z.nisabBasis},
              onSelectionChanged: (v) => setState(() => z.nisabBasis = v.first),
            ),
            if (z.nisabBasis == 'silver') ...[silverPrice, goldPrice] else ...[goldPrice, silverPrice],
            gap,
            Text('What you own', style: t.textTheme.titleSmall),
            _money('Cash and bank balances', z.cash, (v) => z.cash = v, key: const Key('zakat-cash')),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Include savings pots (${f.fmt(f.totalSaved)})'),
              value: z.includePots,
              onChanged: (v) => setState(() => z.includePots = v),
            ),
            _grams('Gold you own', z.goldGrams, (v) => z.goldGrams = v),
            _grams('Silver you own', z.silverGrams, (v) => z.silverGrams = v),
            _money(
              'Shares, funds and investments',
              z.investments,
              (v) => z.investments = v,
              help: 'Scholars differ on how much of a share\'s value counts',
            ),
            _money('Business stock for sale', z.businessStock, (v) => z.businessStock = v),
            _money('Money owed to you that you expect back', z.receivables, (v) => z.receivables = v),
            gap,
            Text('Subtract', style: t.textTheme.titleSmall),
            _money('Debts due now', z.debtsDue, (v) => z.debtsDue = v),
            gap,
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                z.hijriMonth == null
                    ? 'Set your zakat date'
                    : 'Zakat date: ${z.hijriDay ?? 1} ${hijriMonthNames[z.hijriMonth! - 1]}',
              ),
              subtitle: const Text('The Hijri date your wealth first reached the nisab'),
              trailing: const Icon(Icons.event_repeat_outlined),
              onTap: _pickHijri,
            ),
            gap,
            FilledButton(key: const Key('zakat-save'), onPressed: _save, child: const Text('Save')),
            if ((r.due ?? 0) > 0)
              TextButton(
                onPressed: () async {
                  if (_saved) return;
                  _saved = true;
                  final entry = MoneyEntry(at: DateTime.now(), amount: r.due!, category: 'Zakat', note: 'Zakat',
                    zakatYear: year);
                  await widget.state.updateFinance((f) {
                    f.zakat = ZakatInfo.fromJson(z.toJson());
                    f.entries.add(entry);
                  });
                  if (context.mounted) Navigator.pop(context);
                },
                child: Text('I paid ${f.fmt(r.due!)}${year == null ? '' : ' for $year AH'}: log it'),
              ),
            gap,
            Text(moneyDisclaimer, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            TextButton(
              onPressed: () => _openResource(context, moneyResources.firstWhere((r) => r.id == 'zakat')),
              child: const Text('How zakat works'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickHijri() async {
    var m = z.hijriMonth ?? 9, d = z.hijriDay ?? 1;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Zakat date'),
          content: Row(
            children: [
              DropdownButton<int>(
                value: d,
                items: [for (var i = 1; i <= 30; i++) DropdownMenuItem(value: i, child: Text('$i'))],
                onChanged: (v) => set(() => d = v ?? d),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButton<int>(
                  isExpanded: true,
                  value: m,
                  items: [
                    for (var i = 1; i <= 12; i++) DropdownMenuItem(value: i, child: Text(hijriMonthNames[i - 1])),
                  ],
                  onChanged: (v) => set(() => m = v ?? m),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('OK')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    setState(() {
      z.hijriMonth = m;
      z.hijriDay = d;
    });
  }

  var _saved = false;

  Future<void> _save({bool pop = true}) async {
    _saved = true;
    await widget.state.updateFinance((f) => f.zakat = ZakatInfo.fromJson(z.toJson()));
    if (pop && mounted) Navigator.pop(context);
  }
}

class _RecentCard extends StatelessWidget {
  final AppState state;
  const _RecentCard({required this.state});

  @override
  Widget build(BuildContext context) {
    final f = state.finance;
    final recent = [...f.entries]..sort((a, b) => b.at.compareTo(a.at));
    return SectionCard(
      title: 'Recent',
      icon: Icons.receipt_long_outlined,
      children: [
        if (recent.isEmpty) const _Hint('Tap Log to add what you spent or earned.'),
        for (final e in recent.take(5)) _LedgerRow(state: state, entry: e),
        TextButton.icon(
          onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => LedgerScreen(state: state))),
          icon: const Icon(Icons.receipt_long_outlined),
          label: const Text('View full ledger'),
        ),
      ],
    );
  }

  static String _label(Finance f, MoneyEntry e) {
    if (e.potId != null) return '${e.income ? 'From' : 'To'} ${f.pot(e.potId!)?.name ?? 'savings'}';
    if (e.debtId != null) return 'Debt · ${f.debt(e.debtId!)?.person ?? ''}';
    return e.category;
  }
}

class _HabitsCard extends StatelessWidget {
  final AppState state;
  const _HabitsCard({required this.state});

  @override
  Widget build(BuildContext context) {
    final have = {for (final h in state.habits) h.templateId};
    final left = moneyHabitTemplates.where((t) => !have.contains(t.id)).toList();
    if (left.isEmpty) return const SizedBox.shrink();
    return SectionCard(
      title: 'Money habits',
      icon: Icons.repeat,
      children: [
        for (final t in left)
          ListTile(
            key: Key('money-habit-${t.id}'),
            contentPadding: EdgeInsets.zero,
            leading: Text(t.emoji, style: const TextStyle(fontSize: 22)),
            title: Text(t.title),
            subtitle: Text(t.description),
            trailing: const Icon(Icons.add),
            onTap: () async {
              await state.upsertHabit(habitFromTemplate(t, seq: state.habits.length));
              if (context.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text('Added "${t.title}" to your habits')));
              }
            },
          ),
      ],
    );
  }
}

class _ResourcesCard extends StatelessWidget {
  const _ResourcesCard();

  @override
  Widget build(BuildContext context) => SectionCard(
    title: 'Money in Islam',
    icon: Icons.menu_book_outlined,
    children: [
      for (final r in moneyResources)
        ListTile(
          key: Key('resource-${r.id}'),
          contentPadding: EdgeInsets.zero,
          leading: Text(r.emoji, style: const TextStyle(fontSize: 22)),
          title: Text(r.title),
          subtitle: Text(r.summary),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _openResource(context, r),
        ),
      const _Hint(moneyDisclaimer),
    ],
  );
}

void _openResource(BuildContext context, MoneyResource r) => Navigator.of(
  context,
).push(DocumentViewer.route(title: r.title, markdown: r.markdown, fileName: 'money-${r.id}.md'));

class _Hint extends StatelessWidget {
  final String text;
  const _Hint(this.text);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(text, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
    );
  }
}

/// Bottom sheet to log an amount: spending by default, or income.
Future<void> showMoneySheet(
  BuildContext context,
  AppState state, {
  bool income = false,
  String? category,
  String? potId,
  String? debtId,
  MoneyEntry? entry,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (c) => _MoneySheet(state: state, income: entry?.income ?? income, category: entry?.category ?? category,
      potId: entry?.potId ?? potId, debtId: entry?.debtId ?? debtId, entry: entry),
  );
}

class _MoneySheet extends StatefulWidget {
  final AppState state;
  final bool income;
  final String? category, potId, debtId;
  final MoneyEntry? entry;
  const _MoneySheet({required this.state, required this.income, this.category, this.potId, this.debtId, this.entry});

  @override
  State<_MoneySheet> createState() => _MoneySheetState();
}

class _MoneySheetState extends State<_MoneySheet> {
  late bool income = widget.income;
  late String category = widget.category ?? (widget.income ? incomeCategories.first : spendCategories.first);
  late DateTime at = widget.entry?.at ?? DateTime.now();
  late final amount = TextEditingController(text: widget.entry == null ? '' :
      toMajor(widget.entry!.amount, widget.state.finance.currency).toString());
  late final note = TextEditingController(text: widget.entry?.note ?? '');
  var saving = false;

  @override
  void dispose() {
    amount.dispose();
    note.dispose();
    super.dispose();
  }
  String? error;

  bool get fixed => widget.potId != null || widget.debtId != null;

  @override
  Widget build(BuildContext context) {
    final f = widget.state.finance;
    final cats = income ? incomeCategories : f.expenseCategories;
    final title = widget.potId != null
        ? f.pot(widget.potId!)?.name ?? 'Savings transfer'
        : widget.debtId != null
        ? (income ? 'Repayment received' : 'Repayment')
        : null;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null) ...[
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            if (widget.potId != null)
              SegmentedButton<bool>(
                segments: const [ButtonSegment(value: false, label: Text('Add to pot')),
                  ButtonSegment(value: true, label: Text('Withdraw'))],
                selected: {income},
                onSelectionChanged: (v) => setState(() => income = v.first),
              ),
          ]
          else
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Spent')),
                ButtonSegment(value: true, label: Text('Income')),
              ],
              selected: {income},
              onSelectionChanged: (v) => setState(() {
                income = v.first;
                category = (income ? incomeCategories : spendCategories).first;
              }),
            ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('money-amount'),
            controller: amount,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: Theme.of(context).textTheme.headlineSmall,
            decoration: InputDecoration(labelText: 'Amount', suffixText: f.currency, errorText: error),
            onSubmitted: (_) => _save(),
          ),
          if (!fixed) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 0,
              children: [
                for (final c in cats)
                  ChoiceChip(
                    label: Text('${categoryEmoji[c] ?? ''} $c'),
                    selected: c == category,
                    onSelected: (_) => setState(() => category = c),
                  ),
              ],
            ),
          ],
          TextField(
            key: const Key('money-note'),
            controller: note,
            decoration: const InputDecoration(labelText: 'Note (optional)'),
            onSubmitted: (_) => _save(),
          ),
          ListTile(
            title: Text(DateFormat.yMMMd().format(at)),
            leading: const Icon(Icons.event_outlined),
            onTap: () async {
              final picked = await showDatePicker(context: context, initialDate: at,
                firstDate: DateTime(at.year < 1900 ? at.year : 1900), lastDate: DateTime(at.year > 2200 ? at.year : 2200, 12, 31));
              if (picked != null) setState(() => at = DateTime(picked.year, picked.month, picked.day, at.hour, at.minute));
            },
          ),
          const SizedBox(height: 12),
          FilledButton(key: const Key('money-save'), onPressed: saving ? null : _save, child: const Text('Save')),
        ],
      ),
    );
  }

  Future<void> _save() async {
    if (saving) return;
    final f = widget.state.finance;
    final original = widget.entry;
    final a = original?.amount == 0 && double.tryParse(amount.text) == 0 ? 0 : parseMoney(amount.text, f.currency);
    if (a == null) return setState(() => error = 'Enter an amount');
    final e = MoneyEntry(
      id: original?.id,
      at: at, amount: a, income: income, category: category, note: note.text.trim(),
      potId: widget.potId, debtId: widget.debtId,
      kind: original?.category == category && original?.income == income ? original?.kind : null,
    );
    final problem = f.transferError(e, replacing: original);
    if (problem != null) return setState(() => error = problem);
    final nav = Navigator.of(context);
    setState(() => saving = true);
    await widget.state.updateFinance((f) {
      if (original == null) {
        f.entries.add(e);
      } else {
        final stored = f.entries.where((x) => x.id == original.id).firstOrNull;
        if (stored == null) return;
        stored
          ..at = e.at
          ..amount = e.amount
          ..category = e.category
          ..income = e.income
          ..note = e.note
          ..kind = e.kind;
      }
    });
    nav.pop();
  }
}

Future<void> pickCurrency(BuildContext context, AppState state) async {
  final c = await showModalBottomSheet<String>(
    context: context,
    builder: (c) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          if (state.finance.currencyLocked || state.finance.ledgerCurrencies.length > 1)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Each ledger keeps its own currency. Your ${state.finance.currency} records stay in that ledger.'),
            ),
          for (final code in {...commonCurrencies, ...state.finance.ledgerCurrencies})
            ListTile(
              title: Text(code),
              subtitle: state.finance.currencyLocked || state.finance.ledgerCurrencies.length > 1
                  ? Text(state.finance.ledgerCurrencies.contains(code) ? 'Existing ledger' : 'Create separate ledger')
                  : null,
              trailing: code == state.finance.currency ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(c, code),
            ),
        ],
      ),
    ),
  );
  if (c == null || c == state.finance.currency || !context.mounted) return;
  final f = state.finance;
  if (f.currencyLocked || f.ledgerCurrencies.length > 1) {
    final exists = f.ledgerCurrencies.contains(c);
    final ok = await confirmDialog(context,
      title: exists ? 'Open $c ledger?' : 'Create $c ledger?',
      message: 'Your ${f.currency} amounts stay in the ${f.currency} ledger. You can switch back at any time.',
      confirm: exists ? 'Open ledger' : 'Create ledger',
    );
    if (ok) await state.updateFinance((f) => f.openLedger(c));
  } else {
    await state.updateFinance((f) => f.currency = c);
  }
}
