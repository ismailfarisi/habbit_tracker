import '../logic/hijri.dart';
import 'finance.dart';

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

class FinanceAgendaItem {
  final String id, detail;
  final DateTime originalDate, date;
  final FinanceReminder _reminder;

  /// The only user-visible text intended for the lock screen.
  String get privateTitle => 'Personal reminder';

  FinanceAgendaItem(
    this.id,
    this.detail,
    this.originalDate,
    this.date,
    this._reminder,
  );

  /// Call inside AppState.updateFinance to persist and reschedule.
  void snooze(DateTime until) {
    if (!_day(until).isAfter(date)) return;
    _reminder.snoozeFrom = originalDate;
    _reminder.snoozeTo = _day(until);
  }
}

/// A personal plan with opt-in delivery. Its details stay inside the app.
class FinancePlan {
  final String key, detail;
  final FinanceReminder reminder;
  final DateTime? fixedDate;
  final DateTime? Function(DateTime) _occurrence;
  final bool Function(DateTime, DateTime) _paid;

  FinancePlan._(
    this.key,
    this.detail,
    this.reminder,
    this.fixedDate,
    this._occurrence,
    this._paid,
  );

  FinanceAgendaItem? on(DateTime day) {
    if (!reminder.enabled) return null;
    final date = _day(day);
    final from = reminder.snoozeFrom, to = reminder.snoozeTo;
    final original = to == date && from != null && _occurrence(from) == from
        ? from
        : _occurrence(date);
    if (original == null || (original == from && date != to)) return null;
    if (date.isBefore(reminder.enabledOn!) || _paid(original, date)) {
      return null;
    }
    return FinanceAgendaItem(
      '$key-${ymd(original)}',
      detail,
      original,
      date,
      reminder,
    );
  }

  FinanceAgendaItem? next(DateTime today) {
    if (!reminder.enabled) return null;
    final start = _day(today);
    // A one-off debt may be years away, or past due and waiting to be snoozed.
    if (fixedDate case final DateTime due) {
      final effective = reminder.snoozeFrom == due
          ? reminder.snoozeTo ?? due
          : due;
      return on(effective);
    }
    for (var i = 0; i <= 366; i++) {
      final item = on(DateTime(start.year, start.month, start.day + i));
      if (item != null) return item;
    }
    final moved = reminder.snoozeTo;
    return moved != null && !moved.isBefore(start) ? on(moved) : null;
  }
}

Iterable<FinancePlan> financePlans(Finance f, {int hijriOffsetDays = 0, bool enabledOnly = false}) sync* {
  for (final d in f.debts) {
    if (enabledOnly && !d.reminder.enabled) continue;
    if (d.archived || d.due == null || f.debtLeft(d) == 0) continue;
    final entered = d.reminder.enabledOn;
    final due = entered != null && entered.isAfter(d.due!) ? _day(entered) : _day(d.due!);
    yield FinancePlan._(
      '${f.currency}-debt-${d.id}',
      'Debt · ${d.person} · ${f.fmt(f.debtLeft(d))}',
      d.reminder,
      due,
      (day) => day == due ? due : null,
      (_, _) => f.debtLeft(d) == 0,
    );
  }
  for (final p in f.pots) {
    if (enabledOnly && !p.reminder.enabled) continue;
    if (p.archived || p.by == null || f.potSaved(p.id) >= p.target) continue;
    final target = _day(p.by!);
    yield FinancePlan._(
      '${f.currency}-pot-${p.id}',
      'Savings contribution · ${p.name}',
      p.reminder,
      null,
      (date) {
        final last = DateTime(date.year, date.month + 1, 0).day;
        return !date.isAfter(target) && date.day == target.day.clamp(1, last)
            ? date
            : null;
      },
      (original, effective) {
        final start = DateTime(original.year, original.month);
        final nextMonth = DateTime(original.year, original.month + 1);
        final end = effective.isBefore(nextMonth)
            ? nextMonth
            : DateTime(effective.year, effective.month, effective.day + 1);
        return f.entries.any(
          (e) =>
              e.potId == p.id &&
              !e.income &&
              e.amount > 0 &&
              !e.at.isBefore(start) &&
              e.at.isBefore(end),
        );
      },
    );
  }
  final z = f.zakat;
  if ((enabledOnly && !z.reminder.enabled) || z.hijriMonth == null) return;
  yield FinancePlan._(
    '${f.currency}-zakat',
    'Zakat anniversary · ${f.currency} ledger',
    z.reminder,
    null,
    (date) {
      final h = hijriOf(date, offsetDays: hijriOffsetDays);
      if (h.month != z.hijriMonth) return null;
      final day = z.hijriDay ?? 1;
      if (h.day == day) return date;
      if (day != 30 || h.day != 29) return null;
      final next = hijriOf(
        DateTime(date.year, date.month, date.day + 1),
        offsetDays: hijriOffsetDays,
      );
      return next.month != h.month ? date : null;
    },
    (original, effective) {
      final h = hijriOf(original, offsetDays: hijriOffsetDays);
      bool covers(DateTime paid) {
        final day = _day(paid);
        final p = hijriOf(day, offsetDays: hijriOffsetDays);
        return (p.year == h.year && p.month == h.month) ||
            (!day.isBefore(original) && !day.isAfter(effective));
      }

      return (z.lastPaid != null && covers(z.lastPaid!)) ||
          f.entries.any(
            (e) =>
                e.category == 'Zakat' &&
                !e.income &&
                e.amount > 0 &&
                covers(e.at),
          );
    },
  );
}

/// Due rows from every currency ledger. In-app callers can display detail.
/// Notifications should use privateTitle and a neutral body.
List<FinanceAgendaItem> financeAgenda(
  Finance f,
  DateTime day, {
  int hijriOffsetDays = 0,
}) => [
  for (final ledger in f.ledgers)
    for (final plan in financePlans(ledger, hijriOffsetDays: hijriOffsetDays, enabledOnly: true))
      if (plan.on(day) case final FinanceAgendaItem item) item,
];
