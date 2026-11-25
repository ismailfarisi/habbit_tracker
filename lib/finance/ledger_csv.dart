import 'finance.dart';

/// Notes and categories can describe sensitive purchases. Both are opt-in.
String ledgerCsv(
  Finance f,
  Iterable<MoneyEntry> entries, {
  bool includeDetails = false,
}) {
  String text(String value) {
    // CSV quoting alone does not prevent spreadsheet formula evaluation.
    final protected = RegExp(r'^\s*[=+@-]|^[\t\r\n]').hasMatch(value)
        ? "'$value"
        : value;
    return '"${protected.replaceAll('"', '""')}"';
  }

  final lines = [
    'Date,Type,Direction,Amount,Currency${includeDetails ? ',Category,Note' : ''}',
  ];
  for (final e in entries) {
    final decimals = currencyDecimals(f.currency);
    final digits = e.amount.toString().padLeft(decimals + 1, '0');
    final point = digits.length - decimals;
    final amount = decimals == 0
        ? digits
        : '${digits.substring(0, point)}.${digits.substring(point)}';
    lines.add(
      [
        ymd(e.at),
        e.kind.label,
        e.income ? 'In' : 'Out',
        amount,
        text(f.currency),
        if (includeDetails) ...[text(e.category), text(e.note)],
      ].join(','),
    );
  }
  return '${lines.join('\r\n')}\r\n';
}
