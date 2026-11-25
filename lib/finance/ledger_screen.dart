part of 'money_screen.dart';

class LedgerScreen extends StatefulWidget {
  final AppState state;
  const LedgerScreen({super.key, required this.state});

  @override
  State<LedgerScreen> createState() => _LedgerScreenState();
}

class _LedgerScreenState extends State<LedgerScreen> {
  DateTime? month;
  String? category, goalId;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.state,
    builder: (context, _) {
      final f = widget.state.finance;
      final rows = f.ledgerEntries(month: month, category: category, goalId: goalId);
      final months = {if (month != null) month!, for (final e in f.entries) DateTime(e.at.year, e.at.month)}.toList()
        ..sort((a, b) => b.compareTo(a));
      final categories = {if (category != null) category!, for (final e in f.entries) e.category}.toList()..sort();
      final goals = {if (goalId != null) goalId!, for (final p in f.pots) ?p.goalId};
      final net = rows.fold<int>(0, (sum, e) => sum + (e.income ? e.amount : -e.amount));
      return Scaffold(
        appBar: AppBar(
          title: Text('${f.currency} ledger'),
          actions: [IconButton(tooltip: 'Export filtered CSV', icon: const Icon(Icons.file_download_outlined),
            onPressed: rows.isEmpty ? null : () => _export(f, rows))],
        ),
        body: ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          itemCount: rows.length + 1,
          itemBuilder: (context, index) {
            if (index > 0) return _LedgerRow(state: widget.state, entry: rows[index - 1]);
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              DropdownButtonFormField<DateTime>(
                initialValue: month, isExpanded: true,
                decoration: const InputDecoration(labelText: 'Month'),
                items: [const DropdownMenuItem(child: Text('All months')), for (final m in months)
                  DropdownMenuItem(value: m, child: Text(DateFormat.yMMMM().format(m)))],
                onChanged: (v) => setState(() => month = v),
              ),
              DropdownButtonFormField<String>(
                initialValue: category, isExpanded: true,
                decoration: const InputDecoration(labelText: 'Category'),
                items: [const DropdownMenuItem(child: Text('All categories')), for (final c in categories)
                  DropdownMenuItem(value: c, child: Text(c))],
                onChanged: (v) => setState(() => category = v),
              ),
              if (goals.isNotEmpty) DropdownButtonFormField<String>(
                initialValue: goalId, isExpanded: true,
                decoration: const InputDecoration(labelText: 'Goal'),
                items: [const DropdownMenuItem(child: Text('All goals')), for (final id in goals)
                  DropdownMenuItem(value: id, child: Text(widget.state.goalById(id)?.title ?? 'Previous goal · $id'))],
                onChanged: (v) => setState(() => goalId = v),
              ),
              Padding(padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(rows.isEmpty ? 'No matching entries' :
                  '${rows.length} ${rows.length == 1 ? 'entry' : 'entries'} · Net cash flow ${f.fmt(net, sign: true)}')),
            ]);
          },
        ),
      );
    },
  );

  Future<void> _export(Finance f, List<MoneyEntry> rows) async {
    var details = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(builder: (c, set) => AlertDialog(
        title: const Text('Export ledger'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Save ${rows.length} filtered entries with their date, type, direction, amount and currency.'),
          CheckboxListTile(value: details, onChanged: (v) => set(() => details = v == true),
            title: const Text('Include categories and notes')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Choose file')),
        ],
      )),
    );
    if (ok != true || !mounted) return;
    try {
      final result = await FilePicker.saveFile(
        fileName: 'ledger-${f.currency}.csv', mimeType: 'text/csv',
        bytes: Uint8List.fromList(utf8.encode(ledgerCsv(f, rows, includeDetails: details))),
      );
      if (result != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ledger CSV saved')));
      }
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not save the CSV. Try another location.')));
    }
  }
}

class _LedgerRow extends StatelessWidget {
  final AppState state;
  final MoneyEntry entry;
  const _LedgerRow({required this.state, required this.entry});

  @override
  Widget build(BuildContext context) {
    final f = state.finance;
    final e = entry;
    final label = _RecentCard._label(f, e);
    final details = [if (label != e.kind.label) label, e.kind.label, DateFormat.yMMMd().format(e.at)];
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(e.note.isEmpty ? label : e.note),
      subtitle: Text('${details.join(' · ')}\n${f.fmt(e.income ? e.amount : -e.amount, sign: true)}'),
      onTap: () => showMoneySheet(context, state, entry: e),
      trailing: PopupMenuButton<String>(
        tooltip: 'Entry actions',
        onSelected: (action) async {
          if (action == 'edit') {
            await showMoneySheet(context, state, entry: e);
          } else {
            final ledger = f.ledgers.first;
            await state.removeMoney(e.id);
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: const Text('Entry deleted'),
              action: SnackBarAction(label: 'Undo', onPressed: () =>
                state.updateFinance((_) => ledger.entries.add(e))),
            ));
            }
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'edit', child: Text('Edit')),
          PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
    );
  }
}
