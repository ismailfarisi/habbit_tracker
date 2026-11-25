/// Money: spending and income, monthly budgets, savings pots, debts and zakat.
///
/// Amounts are integers in the currency's minor unit (cents, fils…), so sums
/// never drift. Pot balances and debt repayments are derived from entries, so
/// removing an entry (Undo) also undoes its effect. Plain Dart, no Flutter.
library;

import 'package:intl/intl.dart';

import '../logic/hijri.dart';

const spendCategories = [
  'Food', 'Groceries', 'Rent & bills', 'Transport', 'Family', 'Health', 'Education', //
  'Shopping', 'Fun', 'Sadaqah', 'Zakat', 'Savings', 'Debt', 'Other',
];
const incomeCategories = ['Salary', 'Business', 'Gift', 'Other income'];

const categoryEmoji = {
  'Food': '🍽️',
  'Groceries': '🛒',
  'Rent & bills': '🏠',
  'Transport': '🚌',
  'Family': '👨‍👩‍👧',
  'Health': '🩺',
  'Education': '📚',
  'Shopping': '🛍️',
  'Fun': '🎈',
  'Sadaqah': '🤲',
  'Zakat': '🌙',
  'Savings': '🏦',
  'Debt': '🔗',
  'Other': '•',
  'Salary': '💼',
  'Business': '🏪',
  'Gift': '🎁',
  'Other income': '➕',
};

enum EntryKind { spending('Spending'), income('Income'), savings('Savings transfer'), debt('Debt payment');
  const EntryKind(this.label);
  final String label;
}

const commonCurrencies = [
  'AED', 'SAR', 'QAR', 'KWD', 'BHD', 'OMR', 'USD', 'EUR', 'GBP', 'INR', 'PKR', 'BDT', //
  'MYR', 'IDR', 'TRY', 'EGP', 'MAD', 'NGN', 'CAD', 'AUD', 'JOD', 'SGD', 'ZAR',
];

int currencyDecimals(String code) =>
    const {'JPY': 0, 'IDR': 0, 'KRW': 0, 'IQD': 0, 'KWD': 3, 'BHD': 3, 'OMR': 3, 'JOD': 3, 'TND': 3}[code] ?? 2;

int _unit(String code) => const [1, 10, 100, 1000][currencyDecimals(code)];

/// "AED 1,250.50"; whole amounts drop the decimals.
String formatMoney(int minor, String code, {bool sign = false}) {
  final whole = minor % _unit(code) == 0;
  final f = NumberFormat.currency(
    locale: 'en',
    name: code,
    symbol: '$code ',
    decimalDigits: whole ? 0 : currencyDecimals(code),
  );
  final s = f.format(minor.abs() / _unit(code));
  return minor < 0 ? '−$s' : (sign && minor > 0 ? '+$s' : s);
}

/// Parses "12.5" or "1,200" into minor units; null if it isn't a positive amount.
int? parseMoney(String text, String code) {
  final v = double.tryParse(text.replaceAll(',', '').replaceAll(' ', '').trim());
  if (v == null || v.isNaN || v.isInfinite || v <= 0) return null;
  final minor = (v * _unit(code)).round();
  return minor > 0 ? minor : null;
}

/// Converts an amount from an AI tool (major units, e.g. 12.5) to minor units.
int toMinor(num major, String code) => (major * _unit(code)).round();
double toMajor(int minor, String code) => minor / _unit(code);

int _seq = 0;
String _id() => '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${(_seq++).toRadixString(36)}';
String ymd(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v) : null;

class MoneyEntry {
  final String id;
  DateTime at;
  int amount;
  bool income;
  String category;
  String note;
  String? potId;
  String? debtId;
  EntryKind kind;
  /// For a payment logged from the calculator against a specific anniversary.
  final int? zakatYear;
  final String? habitId;

  MoneyEntry({
    String? id,
    required this.at,
    required this.amount,
    this.income = false,
    required this.category,
    this.note = '',
    this.potId,
    this.debtId,
    this.habitId,
    EntryKind? kind,
    this.zakatYear,
  }) : kind = kind ?? (potId != null || category == 'Savings' ? EntryKind.savings
          : debtId != null || category == 'Debt' ? EntryKind.debt
          : income ? EntryKind.income : EntryKind.spending),
       id = id ?? 'm${_id()}';

  Map<String, dynamic> toJson() => {
    'id': id,
    'at': at.toIso8601String(),
    'amount': amount,
    if (income) 'income': true,
    'kind': kind.name,
    if (zakatYear != null) 'zakatYear': zakatYear,
    'category': category,
    if (note.isNotEmpty) 'note': note,
    if (potId != null) 'potId': potId,
    if (debtId != null) 'debtId': debtId,
    if (habitId != null) 'habitId': habitId,
  };

  factory MoneyEntry.fromJson(Map<String, dynamic> j) => MoneyEntry(
    id: j['id'] as String?,
    at: _date(j['at']) ?? DateTime.now(),
    amount: (j['amount'] as num?)?.toInt() ?? 0,
    income: j['income'] == true,
    zakatYear: (j['zakatYear'] as num?)?.toInt(),
    kind: EntryKind.values.where((v) => v.name == j['kind']).firstOrNull,
    category: j['category'] as String? ?? 'Other',
    note: j['note'] as String? ?? '',
    potId: j['potId'] as String?,
    debtId: j['debtId'] as String?,
    habitId: j['habitId'] as String?,
  );
}

class FinanceReminder {
  DateTime? enabledOn;
  DateTime? snoozeFrom, snoozeTo;
  bool get enabled => enabledOn != null;

  void setEnabled(bool enabled, DateTime today) {
    enabledOn = enabled ? DateTime(today.year, today.month, today.day) : null;
    snoozeFrom = null;
    snoozeTo = null;
  }

  Map<String, dynamic> toJson() => {
    if (enabledOn != null) 'enabledOn': ymd(enabledOn!),
    if (snoozeFrom != null) 'snoozeFrom': ymd(snoozeFrom!),
    if (snoozeTo != null) 'snoozeTo': ymd(snoozeTo!),
  };

  FinanceReminder();

  FinanceReminder.fromJson(Object? data) {
    if (data is Map) {
      enabledOn = _date(data['enabledOn']);
      snoozeFrom = _date(data['snoozeFrom']);
      snoozeTo = _date(data['snoozeTo']);
    }
  }
}

class SavingsPot {
  final String id;
  String name;
  String emoji;
  int target;
  DateTime? by;
  String? goalId;
  bool archived;

  FinanceReminder reminder = FinanceReminder();

  SavingsPot({
    String? id,
    required this.name,
    this.emoji = '🏦',
    required this.target,
    this.by,
    this.goalId,
    this.archived = false,
  }) : id = id ?? 'p${_id()}';

  Map<String, dynamic> toJson() => {
    if (reminder.enabled) 'reminder': reminder.toJson(),
    'id': id,
    'name': name,
    'emoji': emoji,
    'target': target,
    if (by != null) 'by': ymd(by!),
    if (goalId != null) 'goalId': goalId,
    if (archived) 'archived': true,
  };

  factory SavingsPot.fromJson(Map<String, dynamic> j) => SavingsPot(
    id: j['id'] as String?,
    name: j['name'] as String? ?? 'Savings',
    emoji: j['emoji'] as String? ?? '🏦',
    target: (j['target'] as num?)?.toInt() ?? 0,
    by: _date(j['by']),
    goalId: j['goalId'] as String?,
    archived: j['archived'] == true,
  )..reminder = FinanceReminder.fromJson(j['reminder']);
}

class Debt {
  final String id;
  String person;
  int amount;

  /// True when the user owes [person]; false when [person] owes the user.
  bool iOwe;
  DateTime? due;
  String note;
  bool archived;

  FinanceReminder reminder = FinanceReminder();

  Debt({
    String? id,
    required this.person,
    required this.amount,
    this.iOwe = true,
    this.due,
    this.note = '',
    this.archived = false,
  }) : id = id ?? 'd${_id()}';

  Map<String, dynamic> toJson() => {
    if (reminder.enabled) 'reminder': reminder.toJson(),
    'id': id,
    'person': person,
    'amount': amount,
    'iOwe': iOwe,
    if (due != null) 'due': ymd(due!),
    if (note.isNotEmpty) 'note': note,
    if (archived) 'archived': true,
  };

  factory Debt.fromJson(Map<String, dynamic> j) => Debt(
    id: j['id'] as String?,
    person: j['person'] as String? ?? '',
    amount: (j['amount'] as num?)?.toInt() ?? 0,
    iOwe: j['iOwe'] != false,
    due: _date(j['due']),
    note: j['note'] as String? ?? '',
    archived: j['archived'] == true,
  )..reminder = FinanceReminder.fromJson(j['reminder']);
}

const goldNisabGrams = 85.0;
const silverNisabGrams = 595.0;
const zakatRate = 0.025;

/// The user's zakat inputs. Money values are minor units; metals in grams.
class ZakatInfo {
  /// 'silver' or 'gold'.
  String nisabBasis;
  int goldPricePerGram;
  int silverPricePerGram;
  int cash;
  double goldGrams;
  double silverGrams;
  int investments;
  int businessStock;
  int receivables;
  int debtsDue;

  /// Count savings pot balances as cash.
  bool includePots;

  /// The Hijri anniversary on which zakat is worked out, e.g. 1 Ramadan.
  int? hijriMonth;
  int? hijriDay;
  DateTime? lastPaid;
  DateTime? valuedOn;

  FinanceReminder reminder = FinanceReminder();

  ZakatInfo({
    this.nisabBasis = 'silver',
    this.goldPricePerGram = 0,
    this.silverPricePerGram = 0,
    this.cash = 0,
    this.goldGrams = 0,
    this.silverGrams = 0,
    this.investments = 0,
    this.businessStock = 0,
    this.receivables = 0,
    this.debtsDue = 0,
    this.includePots = true,
    this.hijriMonth,
    this.hijriDay,
    this.lastPaid,
    this.valuedOn,
  });

  Map<String, dynamic> toJson() => {
    if (reminder.enabled) 'reminder': reminder.toJson(),
    'nisabBasis': nisabBasis,
    'goldPricePerGram': goldPricePerGram,
    'silverPricePerGram': silverPricePerGram,
    'cash': cash,
    'goldGrams': goldGrams,
    'silverGrams': silverGrams,
    'investments': investments,
    'businessStock': businessStock,
    'receivables': receivables,
    'debtsDue': debtsDue,
    'includePots': includePots,
    if (hijriMonth != null) 'hijriMonth': hijriMonth,
    if (hijriDay != null) 'hijriDay': hijriDay,
    if (valuedOn != null) 'valuedOn': ymd(valuedOn!),
    if (lastPaid != null) 'lastPaid': ymd(lastPaid!),
  };

  factory ZakatInfo.fromJson(Map<String, dynamic> j) {
    int i(String k) => (j[k] as num?)?.toInt() ?? 0;
    return ZakatInfo(
      nisabBasis: j['nisabBasis'] == 'gold' ? 'gold' : 'silver',
      goldPricePerGram: i('goldPricePerGram'),
      silverPricePerGram: i('silverPricePerGram'),
      cash: i('cash'),
      goldGrams: (j['goldGrams'] as num?)?.toDouble() ?? 0,
      silverGrams: (j['silverGrams'] as num?)?.toDouble() ?? 0,
      investments: i('investments'),
      businessStock: i('businessStock'),
      receivables: i('receivables'),
      debtsDue: i('debtsDue'),
      includePots: j['includePots'] != false,
      hijriMonth: (j['hijriMonth'] as num?)?.toInt(),
      hijriDay: (j['hijriDay'] as num?)?.toInt(),
      valuedOn: _date(j['valuedOn']),
      lastPaid: _date(j['lastPaid']),
    )..reminder = FinanceReminder.fromJson(j['reminder']);
  }
}

class ZakatResult {
  final int assets, liabilities, net, nisab;
  final int? due;
  final List<String> missingPrices;
  final Map<String, int?> breakdown;
  bool get complete => missingPrices.isEmpty;

  /// False until the metal price for the chosen nisab is entered.
  final bool hasNisab;
  const ZakatResult({
    required this.assets,
    required this.liabilities,
    required this.net,
    required this.nisab,
    required this.due,
    required this.hasNisab,
    required this.breakdown,
    required this.missingPrices,
  });

  bool get aboveNisab => complete && net >= nisab;
}

/// 2.5% of net zakatable wealth when it is at or above the nisab.
ZakatResult calculateZakat(ZakatInfo z, {int potSavings = 0}) {
  final missing = [
    if ((z.goldGrams > 0 || z.nisabBasis == 'gold') && z.goldPricePerGram <= 0) 'gold',
    if ((z.silverGrams > 0 || z.nisabBasis == 'silver') && z.silverPricePerGram <= 0) 'silver',
  ];
  final breakdown = <String, int?>{
    'Cash': z.cash,
    if (z.includePots) 'Savings pots': potSavings,
    if (z.goldGrams > 0) 'Gold (${z.goldGrams} g)': z.goldPricePerGram > 0 ? (z.goldGrams * z.goldPricePerGram).round() : null,
    if (z.silverGrams > 0) 'Silver (${z.silverGrams} g)': z.silverPricePerGram > 0 ? (z.silverGrams * z.silverPricePerGram).round() : null,
    'Investments': z.investments,
    'Business stock': z.businessStock,
    'Receivables': z.receivables,
  };
  final assets = breakdown.values.whereType<int>().fold(0, (a, b) => a + b);
  final liabilities = z.debtsDue;
  final net = assets - liabilities;
  final gold = z.nisabBasis == 'gold';
  final price = gold ? z.goldPricePerGram : z.silverPricePerGram;
  final nisab = (price * (gold ? goldNisabGrams : silverNisabGrams)).round();
  final has = price > 0;
  final due = missing.isNotEmpty ? null : net >= nisab ? (net * zakatRate).round() : 0;
  return ZakatResult(assets: assets, liabilities: liabilities, net: net, nisab: nisab, due: due, hasNisab: has,
      breakdown: breakdown, missingPrices: missing);
}

/// The next date on or after [from] that falls on Hijri [month]/[day]
/// (the 30th falls back to the 29th in 29-day months).
DateTime? nextHijriDate(int month, int day, DateTime from, {int offsetDays = 0}) {
  for (var i = 0; i < 400; i++) {
    final d = DateTime(from.year, from.month, from.day + i);
    final h = hijriOf(d, offsetDays: offsetDays);
    if (h.month != month) continue;
    if (h.day == day) return d;
    if (day == 30 &&
        h.day == 29 &&
        hijriOf(DateTime(d.year, d.month, d.day + 1), offsetDays: offsetDays).month != month) {
      return d;
    }
  }
  return null;
}

class MonthSummary {
  final int income, spent, saved, sadaqah;
  final Map<String, int> byCategory;
  const MonthSummary(this.income, this.spent, this.saved, this.sadaqah, this.byCategory, this.withdrawn, this.debtOut, this.debtIn);
  final int withdrawn, debtOut, debtIn;
  int usedFor(String category) => switch (category) {
    'Debt' => debtOut,
    'Savings' => saved,
    _ => byCategory[category] ?? 0,
  };
  int get left => income - spent - saved + withdrawn - debtOut + debtIn;
}

class RecurringExpense {
  final String id, name, category;
  final int amount;
  RecurringExpense({String? id, required this.name, required this.category, required this.amount})
      : id = id ?? 'r${_id()}';
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'category': category, 'amount': amount};
  factory RecurringExpense.fromJson(Map<String, dynamic> j) => RecurringExpense(id: j['id'] as String?,
    name: j['name'] as String, category: j['category'] as String, amount: (j['amount'] as num).toInt());
}

class _Ledger {
  String currency;
  List<MoneyEntry> entries;

  /// Monthly limit per spending category.
  Map<String, int> budgets;
  List<SavingsPot> pots;
  List<Debt> debts;
  ZakatInfo zakat;

  _Ledger({
    this.currency = 'USD',
    List<MoneyEntry>? entries,
    Map<String, int>? budgets,
    List<SavingsPot>? pots,
    List<Debt>? debts,
    ZakatInfo? zakat,
  }) : entries = entries ?? [],
       budgets = budgets ?? {},
       pots = pots ?? [],
       debts = debts ?? [],
       zakat = zakat ?? ZakatInfo() {
    locked = hasAmounts;
  }

  final List<RecurringExpense> recurring = [];
  final List<String> customCategories = [];
  bool locked = false;
  bool get hasAmounts => recurring.isNotEmpty || entries.isNotEmpty || budgets.isNotEmpty || pots.isNotEmpty || debts.isNotEmpty ||
      [zakat.cash, zakat.investments, zakat.businessStock, zakat.receivables, zakat.debtsDue,
        zakat.goldGrams, zakat.silverGrams, zakat.goldPricePerGram, zakat.silverPricePerGram].any((n) => n != 0);


  Map<String, dynamic> toJson() => {
    'currency': currency,
    if (recurring.isNotEmpty) 'recurring': recurring.map((r) => r.toJson()).toList(),
    if (customCategories.isNotEmpty) 'customCategories': customCategories,
    if (locked || hasAmounts) 'currencyLocked': true,
    'entries': entries.map((e) => e.toJson()).toList(),
    'budgets': budgets,
    'pots': pots.map((p) => p.toJson()).toList(),
    'debts': debts.map((d) => d.toJson()).toList(),
    'zakat': zakat.toJson(),
  };

  factory _Ledger.fromJson(Map<String, dynamic> j) {
    List<T> list<T>(String k, T Function(Map<String, dynamic>) f) => [
      for (final e in (j[k] as List? ?? const [])) f((e as Map).cast<String, dynamic>()),
    ];
    final ledger = _Ledger(
      currency: j['currency'] as String? ?? 'USD',
      entries: list('entries', MoneyEntry.fromJson),
      budgets: {
        for (final e in ((j['budgets'] as Map?) ?? const {}).entries) e.key as String: (e.value as num).toInt(),
      },
      pots: list('pots', SavingsPot.fromJson),
      debts: list('debts', Debt.fromJson),
      zakat: j['zakat'] is Map ? ZakatInfo.fromJson((j['zakat'] as Map).cast()) : null,
    )
      ..recurring.addAll(list('recurring', RecurringExpense.fromJson))
      ..customCategories.addAll((j['customCategories'] as List? ?? const []).whereType<String>());
    ledger.locked = j['currencyLocked'] == true || ledger.hasAmounts;
    return ledger;
  }

}

class Finance {
  _Ledger _active;
  final Map<String, _Ledger> _others = {};

  Finance({String currency = 'USD', List<MoneyEntry>? entries, Map<String, int>? budgets,
    List<SavingsPot>? pots, List<Debt>? debts, ZakatInfo? zakat})
      : _active = _Ledger(currency: currency, entries: entries, budgets: budgets, pots: pots, debts: debts, zakat: zakat);

  Finance._(this._active);
  List<RecurringExpense> get recurring => _active.recurring;
  List<String> get customCategories => _active.customCategories;
  List<String> get expenseCategories => {...spendCategories, ...customCategories}.toList();
  String get currency => _active.currency;
  bool get currencyLocked => _active.locked || _active.hasAmounts;
  bool get isEmpty => !_active.hasAmounts;
  List<MoneyEntry> get entries => _active.entries;
  Map<String, int> get budgets => _active.budgets;
  List<SavingsPot> get pots => _active.pots;
  List<Debt> get debts => _active.debts;
  ZakatInfo get zakat => _active.zakat;
  set zakat(ZakatInfo value) => _active.zakat = value;

  set currency(String code) {
    if (code == currency) return;
    if (currencyLocked || _others.containsKey(code)) throw StateError('Choose a separate ledger for $code.');
    _active.currency = code;
  }

  Set<String> get ledgerCurrencies => {currency, ..._others.keys};
  /// A stable view for actions such as Undo that can outlive a ledger switch.
  Finance get activeLedger => Finance._(_active);
  Iterable<Finance> get ledgers => [activeLedger, ..._others.values.map(Finance._)];

  /// Explicit user action. Previous balances remain in their original units.
  void openLedger(String code) {
    if (currency == code) return;
    _others[currency] = _active;
    _active = _others.remove(code) ?? _Ledger(currency: code);
  }

  Map<String, dynamic> toJson() {
    if (_active.hasAmounts) _active.locked = true;
    return {
      ..._active.toJson(),
      if (_others.isNotEmpty) 'otherLedgers': [for (final ledger in _others.values) ledger.toJson()],
    };
  }

  factory Finance.fromJson(Map<String, dynamic> j) {
    final f = Finance._(_Ledger.fromJson(j));
    for (final data in (j['otherLedgers'] as List? ?? const []).whereType<Map>()) {
      final ledger = _Ledger.fromJson(data.cast<String, dynamic>());
      if (ledger.currency != f.currency) f._others[ledger.currency] = ledger;
    }
    return f;
  }

  String fmt(int minor, {bool sign = false}) => formatMoney(minor, currency, sign: sign);

  SavingsPot? pot(String id) => pots.where((p) => p.id == id).firstOrNull;
  Debt? debt(String id) => debts.where((d) => d.id == id).firstOrNull;
  SavingsPot? potForGoal(String goalId) => pots.where((p) => p.goalId == goalId && !p.archived).firstOrNull;

  /// Money put into a pot minus money taken out of it.
  int potSaved(String id) =>
      entries.where((e) => e.potId == id).fold(0, (s, e) => s + (e.income ? -e.amount : e.amount));

  int get totalSaved => pots.where((p) => !p.archived).fold(0, (s, p) => s + potSaved(p.id));

  /// Amount repaid on a debt so far.
  int debtPaid(String id) => entries.where((e) => e.debtId == id).fold(0, (s, e) => s + e.amount);
  int debtLeft(Debt d) => (d.amount - debtPaid(d.id)).clamp(0, d.amount);

  int get totalIOwe => debts.where((d) => d.iOwe && !d.archived).fold(0, (s, d) => s + debtLeft(d));
  int get totalOwedToMe => debts.where((d) => !d.iOwe && !d.archived).fold(0, (s, d) => s + debtLeft(d));

  Iterable<MoneyEntry> inMonth(DateTime month) =>
      entries.where((e) => e.at.year == month.year && e.at.month == month.month);

  Iterable<MoneyEntry> onDay(DateTime day) =>
      entries.where((e) => e.at.year == day.year && e.at.month == day.month && e.at.day == day.day);

  static bool _isSpending(MoneyEntry e) => e.kind == EntryKind.spending;

  MonthSummary month(DateTime month) {
    var income = 0, spent = 0, saved = 0, sadaqah = 0;
    final by = <String, int>{};
    var withdrawn = 0, debtOut = 0, debtIn = 0;
    for (final e in inMonth(month)) {
      switch (e.kind) {
        case EntryKind.income:
          income += e.amount;
        case EntryKind.savings:
          if (e.income) { withdrawn += e.amount; } else { saved += e.amount; }
        case EntryKind.debt:
          if (e.income) { debtIn += e.amount; } else { debtOut += e.amount; }
        case EntryKind.spending:
          spent += e.amount;
          by[e.category] = (by[e.category] ?? 0) + e.amount;
          if (e.category == 'Sadaqah') sadaqah += e.amount;
      }
    }
    return MonthSummary(income, spent, saved, sadaqah, by, withdrawn, debtOut, debtIn);
  }

  int potChangeInMonth(String id, DateTime month) => inMonth(month).where((e) => e.potId == id)
      .fold(0, (sum, e) => sum + (e.income ? -e.amount : e.amount));

  /// Equal installments from the start of this month through the target month.
  int monthlyContribution(SavingsPot pot, DateTime today) {
    if (pot.by == null) return 0;
    final remaining = pot.target - potSaved(pot.id) + potChangeInMonth(pot.id, today);
    if (remaining <= 0 || pot.target <= potSaved(pot.id)) return 0;
    final months = (pot.by!.year - today.year) * 12 + pot.by!.month - today.month + 1;
    return months <= 1 ? remaining : (remaining + months - 1) ~/ months;
  }

  int contributionLeftThisMonth(SavingsPot pot, DateTime today) {
    final left = monthlyContribution(pot, today) - potChangeInMonth(pot.id, today);
    return left.clamp(0, pot.target);
  }

  /// Reserves the larger of the category budget or expected recurring bills.
  /// Spending already logged in that category has already reduced cash flow.
  int afterPlannedExpenses(DateTime day) {
    final m = month(day);
    final expected = <String, int>{};
    for (final bill in recurring) {
      expected.update(bill.category, (v) => v + bill.amount, ifAbsent: () => bill.amount);
    }
    var cash = m.left;
    for (final category in {...budgets.keys, ...expected.keys}) {
      final limit = budgets[category] ?? 0;
      final bills = expected[category] ?? 0;
      final remaining = (limit > bills ? limit : bills) - m.usedFor(category);
      if (remaining > 0) cash -= remaining;
    }
    return cash;
  }

  List<MoneyEntry> ledgerEntries({DateTime? month, String? category, String? goalId}) {
    final items = month == null ? entries : inMonth(month);
    final ids = {for (final p in pots.where((p) => p.goalId == goalId)) p.id};
    return items.where((e) => (category == null || e.category == category) &&
        (goalId == null || ids.contains(e.potId))).toList()
      ..sort((a, b) => b.at.compareTo(a.at));
  }

  String? transferError(MoneyEntry entry, {MoneyEntry? replacing}) {
    if (entry.potId != null && entry.debtId != null) return 'Choose one savings pot or debt.';
    if (entry.potId case final String id) {
      final original = replacing?.potId == id ? (replacing!.income ? -replacing.amount : replacing.amount) : 0;
      final available = potSaved(id) - original;
      if (available + (entry.income ? -entry.amount : entry.amount) < 0) return 'The pot cannot cover this withdrawal.';
    }
    if (entry.debtId case final String id) {
      final d = debt(id);
      if (d == null || entry.income == d.iOwe) return 'Use the repayment direction for this debt.';
      final original = replacing?.debtId == id ? replacing!.amount : 0;
      if (debtPaid(id) - original + entry.amount > d.amount) return 'Repayment exceeds the outstanding debt.';
    }
    return null;
  }

  int spentOn(DateTime day) => onDay(day).where(_isSpending).fold(0, (s, e) => s + e.amount);

  /// Sadaqah in the week (Monday–Sunday) containing [day].
  int sadaqahInWeek(DateTime day) {
    final start = DateTime(day.year, day.month, day.day - (day.weekday - 1));
    final end = DateTime(start.year, start.month, start.day + 7);
    return entries
        .where((e) => !e.income && e.category == 'Sadaqah' && !e.at.isBefore(start) && e.at.isBefore(end))
        .fold(0, (s, e) => s + e.amount);
  }

  ZakatResult zakatResult() => calculateZakat(zakat, potSavings: totalSaved);

  /// A short plain-text summary for the AI.
  String summary(DateTime now) {
    final m = month(now);
    final b = StringBuffer('Money (currency $currency):\n');
    b.writeln(
      '- This month: income ${fmt(m.income)}, spent ${fmt(m.spent)}, saved ${fmt(m.saved)}, sadaqah ${fmt(m.sadaqah)}.',
    );
    b.writeln('- Net cash flow ${fmt(m.left)}. After remaining budgets and expected bills: ${fmt(afterPlannedExpenses(now))}.');
    if (customCategories.isNotEmpty) b.writeln('- Custom spending categories: ${customCategories.join(', ')}.');
    b.writeln('- Spent today: ${fmt(spentOn(now))}. Sadaqah this week: ${fmt(sadaqahInWeek(now))}.');
    if (budgets.isNotEmpty) {
      b.writeln(
        '- Budgets this month: ${budgets.entries.map((e) => '${e.key} ${fmt(m.usedFor(e.key))} of ${fmt(e.value)}').join(', ')}.',
      );
    }
    for (final p in pots.where((p) => !p.archived)) {
      b.writeln(
        '- Pot "${p.name}" (id ${p.id}): ${fmt(potSaved(p.id))} of ${fmt(p.target)}'
        '${p.by == null ? '' : ' by ${ymd(p.by!)}'}${p.goalId == null ? '' : ', for goal ${p.goalId}'}.',
      );
    }
    for (final d in debts.where((d) => !d.archived)) {
      b.writeln(
        '- Debt (id ${d.id}) ${d.iOwe ? 'user owes ${d.person}' : '${d.person} owes the user'}: '
        '${fmt(debtLeft(d))} left of ${fmt(d.amount)}${d.due == null ? '' : ', due ${ymd(d.due!)}'}.',
      );
    }
    final z = zakatResult();
    if (z.complete) {
      b.writeln('- Zakat estimate: net wealth ${fmt(z.net)}, ${zakat.nisabBasis} nisab ${fmt(z.nisab)}, due ${fmt(z.due!)} assuming a full lunar year.');
    } else {
      b.writeln('- Zakat estimate incomplete. Missing price per gram: ${z.missingPrices.join(', ')}.');
    }
    return b.toString();
  }
}

const _countryCurrency = {
  'AE': 'AED',
  'SA': 'SAR',
  'QA': 'QAR',
  'KW': 'KWD',
  'BH': 'BHD',
  'OM': 'OMR',
  'US': 'USD',
  'GB': 'GBP',
  'IN': 'INR',
  'PK': 'PKR',
  'BD': 'BDT',
  'MY': 'MYR',
  'ID': 'IDR',
  'TR': 'TRY',
  'EG': 'EGP',
  'MA': 'MAD',
  'NG': 'NGN',
  'CA': 'CAD',
  'AU': 'AUD',
  'JO': 'JOD',
  'DE': 'EUR',
  'FR': 'EUR',
  'NL': 'EUR',
  'BE': 'EUR',
  'ES': 'EUR',
  'IT': 'EUR',
  'IE': 'EUR',
  'AT': 'EUR',
  'SG': 'SGD',
  'ZA': 'ZAR',
};

/// A first guess at the user's currency from a locale like "en_AE".
String currencyForLocale([String? locale]) {
  final l = locale ?? Intl.systemLocale;
  final cc = l.split(RegExp('[_-]')).skip(1).firstOrNull?.toUpperCase();
  return _countryCurrency[cc] ?? 'USD';
}
