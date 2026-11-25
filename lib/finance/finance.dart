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

/// Categories that move money aside rather than spend it.
const _notSpending = {'Savings'};

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
  return (v * _unit(code)).round();
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

  MoneyEntry({
    String? id,
    required this.at,
    required this.amount,
    this.income = false,
    required this.category,
    this.note = '',
    this.potId,
    this.debtId,
  }) : id = id ?? 'm${_id()}';

  Map<String, dynamic> toJson() => {
    'id': id,
    'at': at.toIso8601String(),
    'amount': amount,
    if (income) 'income': true,
    'category': category,
    if (note.isNotEmpty) 'note': note,
    if (potId != null) 'potId': potId,
    if (debtId != null) 'debtId': debtId,
  };

  factory MoneyEntry.fromJson(Map<String, dynamic> j) => MoneyEntry(
    id: j['id'] as String?,
    at: _date(j['at']) ?? DateTime.now(),
    amount: (j['amount'] as num?)?.toInt() ?? 0,
    income: j['income'] == true,
    category: j['category'] as String? ?? 'Other',
    note: j['note'] as String? ?? '',
    potId: j['potId'] as String?,
    debtId: j['debtId'] as String?,
  );
}

class SavingsPot {
  final String id;
  String name;
  String emoji;
  int target;
  DateTime? by;
  String? goalId;
  bool archived;

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
  );
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
  );
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
  });

  Map<String, dynamic> toJson() => {
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
      lastPaid: _date(j['lastPaid']),
    );
  }
}

class ZakatResult {
  final int assets, liabilities, net, nisab, due;

  /// False until the metal price for the chosen nisab is entered.
  final bool hasNisab;
  const ZakatResult({
    required this.assets,
    required this.liabilities,
    required this.net,
    required this.nisab,
    required this.due,
    required this.hasNisab,
  });

  bool get aboveNisab => hasNisab && net >= nisab;
}

/// 2.5% of net zakatable wealth when it is at or above the nisab.
ZakatResult calculateZakat(ZakatInfo z, {int potSavings = 0}) {
  final assets =
      z.cash +
      (z.includePots ? potSavings : 0) +
      (z.goldGrams * z.goldPricePerGram).round() +
      (z.silverGrams * z.silverPricePerGram).round() +
      z.investments +
      z.businessStock +
      z.receivables;
  final liabilities = z.debtsDue;
  final net = assets - liabilities;
  final gold = z.nisabBasis == 'gold';
  final price = gold ? z.goldPricePerGram : z.silverPricePerGram;
  final nisab = (price * (gold ? goldNisabGrams : silverNisabGrams)).round();
  final has = price > 0;
  final due = has && net > 0 && net >= nisab ? (net * zakatRate).round() : 0;
  return ZakatResult(assets: assets, liabilities: liabilities, net: net, nisab: nisab, due: due, hasNisab: has);
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
  const MonthSummary(this.income, this.spent, this.saved, this.sadaqah, this.byCategory);
  int get left => income - spent - saved;
}

class Finance {
  String currency;
  List<MoneyEntry> entries;

  /// Monthly limit per spending category.
  Map<String, int> budgets;
  List<SavingsPot> pots;
  List<Debt> debts;
  ZakatInfo zakat;

  Finance({
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
       zakat = zakat ?? ZakatInfo();

  bool get isEmpty => entries.isEmpty && budgets.isEmpty && pots.isEmpty && debts.isEmpty;

  Map<String, dynamic> toJson() => {
    'currency': currency,
    'entries': entries.map((e) => e.toJson()).toList(),
    'budgets': budgets,
    'pots': pots.map((p) => p.toJson()).toList(),
    'debts': debts.map((d) => d.toJson()).toList(),
    'zakat': zakat.toJson(),
  };

  factory Finance.fromJson(Map<String, dynamic> j) {
    List<T> list<T>(String k, T Function(Map<String, dynamic>) f) => [
      for (final e in (j[k] as List? ?? const [])) f((e as Map).cast<String, dynamic>()),
    ];
    return Finance(
      currency: j['currency'] as String? ?? 'USD',
      entries: list('entries', MoneyEntry.fromJson),
      budgets: {
        for (final e in ((j['budgets'] as Map?) ?? const {}).entries) e.key as String: (e.value as num).toInt(),
      },
      pots: list('pots', SavingsPot.fromJson),
      debts: list('debts', Debt.fromJson),
      zakat: j['zakat'] is Map ? ZakatInfo.fromJson((j['zakat'] as Map).cast()) : null,
    );
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

  static bool _isSpending(MoneyEntry e) => !e.income && e.potId == null && !_notSpending.contains(e.category);

  MonthSummary month(DateTime month) {
    var income = 0, spent = 0, saved = 0, sadaqah = 0;
    final by = <String, int>{};
    for (final e in inMonth(month)) {
      if (e.income) {
        if (e.potId == null && e.debtId == null) income += e.amount;
      } else if (!_isSpending(e)) {
        saved += e.amount;
      } else {
        spent += e.amount;
        by[e.category] = (by[e.category] ?? 0) + e.amount;
        if (e.category == 'Sadaqah') sadaqah += e.amount;
      }
    }
    return MonthSummary(income, spent, saved, sadaqah, by);
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
    b.writeln('- Spent today: ${fmt(spentOn(now))}. Sadaqah this week: ${fmt(sadaqahInWeek(now))}.');
    if (budgets.isNotEmpty) {
      b.writeln(
        '- Budgets this month: ${budgets.entries.map((e) => '${e.key} ${fmt(m.byCategory[e.key] ?? 0)} of ${fmt(e.value)}').join(', ')}.',
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
    if (z.hasNisab) b.writeln('- Zakat: net wealth ${fmt(z.net)}, nisab ${fmt(z.nisab)}, due ${fmt(z.due)}.');
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
