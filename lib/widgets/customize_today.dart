import 'package:flutter/material.dart';

import '../app_state.dart';

Future<void> customizeToday(BuildContext context, AppState state) =>
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _CustomizeToday(state: state),
    );

class _CustomizeToday extends StatefulWidget {
  final AppState state;
  const _CustomizeToday({required this.state});

  @override
  State<_CustomizeToday> createState() => _CustomizeTodayState();
}

class _CustomizeTodayState extends State<_CustomizeToday> {
  late final settings = widget.state.settings;
  late var hidden = {...settings.todayHidden};
  late var pinned = [...settings.todayPinned];
  late bool showMoney = settings.showMoneyShortcut;
  final history = <(Set<String>, List<String>, bool)>[];

  void change(VoidCallback edit) => setState(() {
    history.add(({...hidden}, [...pinned], showMoney));
    edit();
  });

  void undo() => setState(() {
    final previous = history.removeLast();
    hidden = previous.$1;
    pinned = previous.$2;
    showMoney = previous.$3;
  });

  Future<void> save() async {
    await widget.state.updateSettings((s) {
      s.todayHidden = hidden.toList();
      s.todayPinned = pinned;
      s.showMoneyShortcut = showMoney;
    });
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final labels = {
      'wake': 'Wake & sleep',
      'prayers': 'Prayer tracking',
      for (final g in state.goals.where((g) => !g.archived))
        'goal-${g.id}': g.title,
      for (final h in state.activeHabits.where(
        (h) => state.goalFor(h.id) == null,
      ))
        h.id: h.title,
      'tasks': 'Tasks',
      'money': 'Money',
    };
    final order = {...pinned.where(labels.containsKey), ...labels.keys};
    return SafeArea(
      child: FractionallySizedBox(
        heightFactor: 0.84,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                'Customize Today',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final id in order)
                    Builder(
                      builder: (context) {
                        final label = labels[id]!;
                        final index = pinned.indexOf(id);
                        final visible =
                            !hidden.contains(id) &&
                            (id != 'money' ||
                                !state.finance.isEmpty ||
                                showMoney ||
                                index >= 0);
                        return ListTile(
                          leading: Checkbox.adaptive(
                            value: visible,
                            semanticLabel: 'Show $label',
                            onChanged: (on) => change(() {
                              if (on == true) {
                                hidden.remove(id);
                                if (id == 'money') showMoney = true;
                              } else {
                                hidden.add(id);
                                pinned.remove(id);
                              }
                            }),
                          ),
                          title: Text(label),
                          subtitle: index < 0
                              ? null
                              : Text('Pinned · ${index + 1}'),
                          trailing: PopupMenuButton<String>(
                            tooltip: 'Order $label',
                            enabled: visible,
                            onSelected: (action) => change(() {
                              pinned.remove(id);
                              if (action == 'pin') pinned.insert(0, id);
                              if (action == 'up') pinned.insert(index - 1, id);
                              if (action == 'down')
                                pinned.insert(index + 1, id);
                            }),
                            itemBuilder: (_) => [
                              if (index < 0)
                                const PopupMenuItem(
                                  value: 'pin',
                                  child: Text('Pin first'),
                                ),
                              if (index >= 0)
                                const PopupMenuItem(
                                  value: 'unpin',
                                  child: Text('Unpin'),
                                ),
                              if (index > 0)
                                const PopupMenuItem(
                                  value: 'up',
                                  child: Text('Move up'),
                                ),
                              if (index >= 0 && index < pinned.length - 1)
                                const PopupMenuItem(
                                  value: 'down',
                                  child: Text('Move down'),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
                  TextButton(
                    onPressed: () => change(() {
                      hidden = {'wake', 'prayers'};
                      pinned = [];
                      showMoney = false;
                    }),
                    child: const Text('Restore defaults'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: history.isEmpty ? null : undo,
                    child: const Text('Undo'),
                  ),
                  FilledButton(onPressed: save, child: const Text('Save')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
