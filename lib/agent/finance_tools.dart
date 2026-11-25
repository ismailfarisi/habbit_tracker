/// Money tools for the coach (log spending, budgets, pots, debts, zakat) and
/// tools that let it customise the app (settings, Today's cards).
library;

import 'dart:convert';

import '../app_state.dart';
import '../finance/finance.dart';
import '../models.dart';
import '../services/openrouter.dart';
import '../services/task_tools.dart';

Map<String, dynamic> _fn(String name, String description, Map<String, dynamic> props, List<String> required) => {
  'type': 'function',
  'function': {
    'name': name,
    'description': description,
    'parameters': {'type': 'object', 'properties': props, 'required': required},
  },
};

const _amount = {'type': 'number', 'description': 'Amount in the user\'s currency, major units (e.g. 12.5)'};
const _date = {'type': 'string', 'description': 'YYYY-MM-DD'};

/// Settings the coach may change, with a short description for the model.
const aiSettings = {
  'remindersEnabled': 'bool: all reminders on/off',
  'prayerOffsetMin': 'int: remind this many minutes before prayer time (0-60)',
  'prayerHadith': 'bool: hadith in prayer reminders',
  'wakeAlarmLoud': 'bool: loud full-screen wake alarm',
  'themeMode': 'string: system | light | dark',
  'sleepHours': 'number: sleep goal in hours',
  'windDownMinutes': 'int: wind-down reminder minutes before bed',
  'bedtimeReminder': 'bool',
  'suhoorReminder': 'bool',
  'jumuahReminder': 'bool',
  'sunnahDuha': 'bool: show Duha prayer',
  'sunnahWitr': 'bool: show Witr prayer',
  'taraweeh': 'bool',
  'focusSleep': 'bool: block chosen apps at sleep time',
  'focusStrict': 'bool: no "5 more minutes" on the app pause',
  'freezesPerMonth': 'int: streak freezes per month (0-4)',
};

final financeToolDefinitions = <Map<String, dynamic>>[
  _fn(
    'log_money',
    'Record money spent or received. Use category Sadaqah for charity, Zakat for zakat paid.',
    {
      'amount': _amount,
      'income': {'type': 'boolean', 'description': 'true for money received'},
      'category': {
        'type': 'string',
        'description': 'Spending: ${spendCategories.join(', ')}. Income: ${incomeCategories.join(', ')}.',
      },
      'note': {'type': 'string'},
      'date': _date,
      'pot_id': {
        'type': 'string',
        'description': 'Put money into (or, with income true, take it out of) this savings pot',
      },
      'debt_id': {'type': 'string', 'description': 'A repayment on this debt'},
    },
    ['amount', 'category'],
  ),
  _fn(
    'set_budget',
    'Set or remove (amount 0) a monthly limit for a spending category.',
    {
      'category': {'type': 'string', 'enum': spendCategories},
      'amount': _amount,
    },
    ['category', 'amount'],
  ),
  _fn(
    'create_savings_pot',
    'Create a savings pot, optionally linked to a goal so the goal shows its progress.',
    {
      'name': {'type': 'string'},
      'emoji': {'type': 'string'},
      'target': _amount,
      'by': _date,
      'goal_id': {'type': 'string'},
    },
    ['name', 'target'],
  ),
  _fn(
    'add_debt',
    'Write a debt down (Quran 2:282): money the user owes, or is owed.',
    {
      'person': {'type': 'string'},
      'amount': _amount,
      'i_owe': {'type': 'boolean', 'description': 'true if the user owes the person'},
      'due': _date,
      'note': {'type': 'string'},
    },
    ['person', 'amount', 'i_owe'],
  ),
  _fn('update_zakat', 'Save zakat inputs and return the calculation. Only pass what the user told you.', {
    'nisab_basis': {
      'type': 'string',
      'enum': ['silver', 'gold'],
    },
    'gold_price_per_gram': _amount,
    'silver_price_per_gram': _amount,
    'cash': _amount,
    'gold_grams': {'type': 'number'},
    'silver_grams': {'type': 'number'},
    'investments': _amount,
    'business_stock': _amount,
    'receivables': _amount,
    'debts_due': _amount,
    'hijri_month': {'type': 'integer', 'description': '1-12, the zakat anniversary'},
    'hijri_day': {'type': 'integer'},
  }, []),
  _fn('money_summary', 'This month\'s income, spending by category, budgets, pots, debts and zakat.', {}, []),
  _fn(
    'set_currency',
    'Change the currency (ISO code, e.g. AED).',
    {
      'code': {'type': 'string'},
    },
    ['code'],
  ),
  _fn(
    'update_settings',
    'Change app settings to suit the user. Allowed keys: ${aiSettings.entries.map((e) => '${e.key} (${e.value})').join('; ')}.',
    {
      'changes': {'type': 'object', 'description': 'key → new value'},
    },
    ['changes'],
  ),
  _fn(
    'customize_today',
    'Hide, show or reorder the cards on Today. Card ids: wake, prayers, tasks, money, a habit id, or goal-<goal id>.',
    {
      'hide': {
        'type': 'array',
        'items': {'type': 'string'},
      },
      'show': {
        'type': 'array',
        'items': {'type': 'string'},
      },
      'pin': {
        'type': 'array',
        'items': {'type': 'string'},
        'description': 'Cards to show first, in order; replaces the pinned list',
      },
    },
    [],
  ),
];

final financeToolNames = {for (final t in financeToolDefinitions) (t['function'] as Map)['name'] as String};

class FinanceTools {
  final AppState state;
  final void Function(ToolActivity activity)? onActivity;
  final DateTime Function() clock;
  FinanceTools(this.state, {this.onActivity, DateTime Function()? clock}) : clock = clock ?? DateTime.now;

  Finance get f => state.finance;
  String _err(String e) => jsonEncode({'error': e});
  int? _minor(Object? v) => v is num && v >= 0 ? toMinor(v, f.currency) : null;
  DateTime? _day(Object? v) => v is String ? DateTime.tryParse(v) : null;

  Future<String> execute(ToolCall call) async {
    final a = call.arguments.trim().isEmpty ? <String, dynamic>{} : jsonDecode(call.arguments) as Map<String, dynamic>;
    switch (call.name) {
      case 'log_money':
        final amount = _minor(a['amount']);
        if (amount == null || amount == 0) return _err('amount must be a positive number');
        final income = a['income'] == true;
        final cats = income ? incomeCategories : spendCategories;
        final cat = cats.firstWhere(
          (c) => c.toLowerCase() == '${a['category']}'.toLowerCase(),
          orElse: () => cats.last,
        );
        final potId = a['pot_id'] as String?, debtId = a['debt_id'] as String?;
        if (potId != null && f.pot(potId) == null) return _err('no pot $potId; see money_summary');
        if (debtId != null && f.debt(debtId) == null) return _err('no debt $debtId; see money_summary');
        final d = _day(a['date']);
        final now = clock();
        final e = await state.addMoney(
          MoneyEntry(
            at: d == null ? now : DateTime(d.year, d.month, d.day, now.hour, now.minute),
            amount: amount,
            income: income,
            category: potId != null && !income ? 'Savings' : cat,
            note: (a['note'] as String? ?? '').trim(),
            potId: potId,
            debtId: debtId,
          ),
        );
        onActivity?.call(
          ToolActivity(
            '${income ? 'Received' : 'Spent'} ${f.fmt(amount)} · ${potId != null ? f.pot(potId)!.name : e.category}',
            undo: () => state.removeMoney(e.id),
          ),
        );
        return jsonEncode({'ok': true, 'id': e.id, 'spent_today': f.fmt(f.spentOn(now))});
      case 'set_budget':
        final cat = a['category'] as String?;
        final amount = _minor(a['amount']);
        if (!spendCategories.contains(cat) || amount == null) return _err('category and amount are required');
        final prev = f.budgets[cat];
        await state.setBudget(cat!, amount);
        onActivity?.call(
          ToolActivity(
            amount == 0 ? 'Removed the $cat budget' : '$cat budget ${f.fmt(amount)}/month',
            undo: () => state.setBudget(cat, prev),
          ),
        );
        return jsonEncode({'ok': true});
      case 'create_savings_pot':
        final target = _minor(a['target']);
        final name = (a['name'] as String? ?? '').trim();
        if (name.isEmpty || target == null || target == 0) return _err('name and a positive target are required');
        final goalId = a['goal_id'] as String?;
        if (goalId != null && state.goalById(goalId) == null) return _err('no goal $goalId');
        final p = SavingsPot(
          name: name,
          emoji: (a['emoji'] as String?)?.trim().isNotEmpty == true ? a['emoji'] as String : '🏦',
          target: target,
          by: _day(a['by']),
          goalId: goalId,
        );
        await state.upsertPot(p);
        onActivity?.call(ToolActivity('Savings pot "${p.name}" · ${f.fmt(target)}', undo: () => state.deletePot(p.id)));
        return jsonEncode({'ok': true, 'id': p.id});
      case 'add_debt':
        final amount = _minor(a['amount']);
        final person = (a['person'] as String? ?? '').trim();
        if (person.isEmpty || amount == null || amount == 0) return _err('person and a positive amount are required');
        final d = Debt(
          person: person,
          amount: amount,
          iOwe: a['i_owe'] != false,
          due: _day(a['due']),
          note: (a['note'] as String? ?? '').trim(),
        );
        await state.upsertDebt(d);
        onActivity?.call(
          ToolActivity(
            d.iOwe ? 'Debt to $person · ${f.fmt(amount)}' : '$person owes you ${f.fmt(amount)}',
            undo: () => state.deleteDebt(d.id),
          ),
        );
        return jsonEncode({'ok': true, 'id': d.id});
      case 'update_zakat':
        final prev = ZakatInfo.fromJson(f.zakat.toJson());
        final z = ZakatInfo.fromJson(f.zakat.toJson());
        void money(String k, void Function(int v) set) {
          final v = _minor(a[k]);
          if (v != null) set(v);
        }

        if (a['nisab_basis'] case final String b when b == 'gold' || b == 'silver') z.nisabBasis = b;
        money('gold_price_per_gram', (v) => z.goldPricePerGram = v);
        money('silver_price_per_gram', (v) => z.silverPricePerGram = v);
        money('cash', (v) => z.cash = v);
        money('investments', (v) => z.investments = v);
        money('business_stock', (v) => z.businessStock = v);
        money('receivables', (v) => z.receivables = v);
        money('debts_due', (v) => z.debtsDue = v);
        if (a['gold_grams'] case final num g when g >= 0) z.goldGrams = g.toDouble();
        if (a['silver_grams'] case final num g when g >= 0) z.silverGrams = g.toDouble();
        if (a['hijri_month'] case final int m when m >= 1 && m <= 12) {
          z.hijriMonth = m;
          z.hijriDay = (a['hijri_day'] as num?)?.toInt().clamp(1, 30) ?? 1;
        }
        await state.updateFinance((x) => x.zakat = z);
        final r = f.zakatResult();
        onActivity?.call(
          ToolActivity(
            r.hasNisab ? 'Zakat: ${r.aboveNisab ? '${f.fmt(r.due)} due' : 'below the nisab'}' : 'Saved zakat details',
            undo: () => state.updateFinance((x) => x.zakat = prev),
          ),
        );
        return jsonEncode({
          'net_wealth': f.fmt(r.net),
          'nisab': r.hasNisab ? f.fmt(r.nisab) : 'unknown: ask for today\'s ${z.nisabBasis} price per gram',
          'zakat_due': f.fmt(r.due),
          'includes_savings_pots': z.includePots ? f.fmt(f.totalSaved) : 'no',
        });
      case 'money_summary':
        final now = clock();
        final m = f.month(now);
        return jsonEncode({
          'summary': f.summary(now),
          'by_category': {for (final e in m.byCategory.entries) e.key: f.fmt(e.value)},
          'recent': [
            for (final e in ([...f.entries]..sort((x, y) => y.at.compareTo(x.at))).take(15))
              '${ymd(e.at)} ${e.income ? '+' : '-'}${f.fmt(e.amount)} ${e.category}${e.note.isEmpty ? '' : ' (${e.note})'}',
          ],
        });
      case 'set_currency':
        final code = '${a['code'] ?? ''}'.trim().toUpperCase();
        if (!RegExp(r'^[A-Z]{3}$').hasMatch(code)) return _err('use a 3-letter ISO code');
        final prev = f.currency;
        await state.updateFinance((x) => x.currency = code);
        onActivity?.call(ToolActivity('Currency $code', undo: () => state.updateFinance((x) => x.currency = prev)));
        return jsonEncode({'ok': true});
      case 'update_settings':
        final changes = a['changes'];
        if (changes is! Map || changes.isEmpty) return _err('changes must be an object');
        final bad = changes.keys.where((k) => !aiSettings.containsKey(k)).toList();
        if (bad.isNotEmpty) return _err('not allowed: ${bad.join(', ')}. Allowed: ${aiSettings.keys.join(', ')}');
        if (changes['themeMode'] case final Object t when !const ['system', 'light', 'dark'].contains(t)) {
          return _err('themeMode must be system, light or dark');
        }
        final before = state.settings.toJson();
        final Settings next;
        try {
          next = Settings.fromJson({...before, ...changes.cast<String, dynamic>()});
        } catch (e) {
          return _err('wrong value type: $e');
        }
        final applied = next.toJson();
        await state.setSettings(next);
        onActivity?.call(
          ToolActivity('Changed ${changes.keys.join(', ')}', undo: () {
            final current = state.settings.toJson();
            for (final key in changes.keys.cast<String>()) {
              if (current[key] == applied[key]) current[key] = before[key];
            }
            return state.setSettings(Settings.fromJson(current));
          }),
        );
        return jsonEncode({
          'ok': true,
          'now': {for (final k in changes.keys) k: next.toJson()[k]},
        });
      case 'customize_today':
        List<String> ids(String k) => [for (final v in (a[k] as List? ?? const [])) '$v'];
        final hide = ids('hide'), show = ids('show');
        final pin = a['pin'] is List ? ids('pin') : null;
        if (hide.isEmpty && show.isEmpty && pin == null) return _err('pass hide, show or pin');
        final prevHidden = [...state.settings.todayHidden], prevPinned = [...state.settings.todayPinned];
        await state.updateSettings((s) {
          s.todayHidden = {...s.todayHidden.where((i) => !show.contains(i)), ...hide}.toList();
          if (pin != null) s.todayPinned = pin;
          if (show.contains('money') && !s.todayPinned.contains('money') && f.isEmpty) s.todayPinned.add('money');
        });
        onActivity?.call(
          ToolActivity(
            [
              if (hide.isNotEmpty) 'Hid ${hide.join(', ')} on Today',
              if (show.isNotEmpty) 'Showing ${show.join(', ')}',
              if (pin != null) 'Pinned ${pin.join(', ')}',
            ].join(' · '),
            undo: () => state.updateSettings((s) {
              s.todayHidden = prevHidden;
              s.todayPinned = prevPinned;
            }),
          ),
        );
        return jsonEncode({'ok': true, 'hidden': state.settings.todayHidden, 'pinned': state.settings.todayPinned});
    }
    return _err('unknown tool ${call.name}');
  }
}

const financePrompt = '''
Money: the app has a Money section (spending and income, monthly budgets, savings pots, debts, zakat, sadaqah).
- Log what the user tells you they spent or received with log_money; Sadaqah and Zakat are categories.
- For savings goals (Hajj, emergency fund, Umrah…), create the goal and a savings pot linked to it with goal_id; give the monthly amount needed.
- Zakat: 2.5% of net zakatable wealth held for a lunar year above the nisab (595 g silver or 85 g gold). Never guess metal prices: ask the user for today's price per gram.
- Present Islamic finance points as general guidance, not a fatwa or personal financial advice; suggest a qualified scholar for rulings on their situation. Be gentle about spending; never shame.
Customising the app: you can change settings with update_settings and hide, show or reorder Today's cards with customize_today when it helps the user. Explain what you changed.''';
