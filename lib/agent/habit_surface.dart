/// `HabitSurface(state, habit, day)` renders a habit's stored A2UI surface
/// for one day, offline, with `basicCatalog()` + the habit catalog.
///
/// The surface data model is the day's `HabitEntry` (see habit_catalog.dart):
/// it is seeded from `state.habitEntry(day, habit.id)`, every write a
/// component makes is saved with `state.logHabit`, and changes made elsewhere
/// (another surface, the day editor) flow back in. The `logEntry`,
/// `finishSession` and `askCoach` actions are handled here; `askCoach` goes
/// to [HabitSurface.onAskCoach], or opens the coach sheet by default.
///
/// If the habit has no surface, or it is invalid or fails while rendering,
/// [HabitFallback] (a plain check / counter / minutes UI for the habit's
/// kind) is shown instead, so a habit can always be logged.
///
/// With `persist: false` nothing is saved (used to preview a proposed habit
/// in the chat).
library;

import 'dart:async';
import 'dart:convert';

import 'package:a2ui_core/a2ui_core.dart';
import 'package:a2ui_flutter/a2ui_flutter.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../habits/habit.dart';
import '../logic/stats.dart';
import '../widgets/coach_sheet.dart';
import 'habit_catalog.dart';
import 'habit_components.dart';

typedef AskCoachHandler = void Function(HabitDef habit, Map<String, dynamic> request);

class HabitSurface extends StatefulWidget {
  final AppState state;
  final HabitDef habit;
  final DateTime day;
  final bool persist;
  final AskCoachHandler? onAskCoach;

  const HabitSurface(this.state, this.habit, this.day, {super.key, this.persist = true, this.onAskCoach});

  @override
  State<HabitSurface> createState() => HabitSurfaceState();
}

class HabitSurfaceState extends State<HabitSurface> {
  static var _nextId = 0;

  MessageProcessor<ComponentImplementation>? _processor;
  SurfaceModel<ComponentImplementation>? _surface;
  DataSubscription<Object?>? _dataSub;
  final _subs = <Subscription>[];
  HabitEntry _preview = HabitEntry();
  String _surfaceJson = '';
  bool _syncing = false;

  /// True when the stored surface could not be used and [HabitFallback] is
  /// shown.
  bool get usingFallback => _surface == null;

  /// The entry currently shown.
  HabitEntry get entry => widget.persist ? widget.state.habitEntry(widget.day, widget.habit.id) : _preview;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onState);
    _open();
  }

  @override
  void didUpdateWidget(HabitSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget;
    if (old.state != widget.state) {
      old.state.removeListener(_onState);
      widget.state.addListener(_onState);
    }
    if (old.habit.id != widget.habit.id ||
        dayKey(old.day) != dayKey(widget.day) ||
        jsonEncode(widget.habit.uiSurface) != _surfaceJson) {
      _close();
      _open();
    } else {
      _pushToSurface();
    }
  }

  @override
  void dispose() {
    widget.state.removeListener(_onState);
    _close();
    super.dispose();
  }

  Map<String, dynamic> _model(HabitEntry e) => {
        ...e.toJson(),
        'habit': {'title': widget.habit.title, 'target': widget.habit.target, 'unit': widget.habit.unit},
        'day': dayKey(widget.day),
      };

  void _open() {
    _surfaceJson = jsonEncode(widget.habit.uiSurface);
    final stored = widget.habit.uiSurface;
    if (stored == null) return;
    final processor = MessageProcessor<ComponentImplementation>(
      catalogs: habitCatalogs(),
      defaultVersion: A2uiProtocolVersion.v1_0,
    );
    try {
      final message = normalizeHabitSurface(stored);
      final id = 'habit-${widget.habit.id}-${_nextId++}';
      (message['createSurface'] as Map)
        ..['surfaceId'] = id
        ..['dataModel'] = _model(entry);
      processor.processMessages([message]);
      final surface = processor.model.getSurface(id);
      if (surface == null) throw HabitSurfaceError('The surface was not created.');
      _processor = processor;
      _surface = surface;
      _dataSub = surface.dataModel.subscribe<Object?>('/', (_) => _pullFromSurface());
      _subs
        ..add(surface.onAction.subscribe(_onAction))
        ..add(surface.onError.subscribe(_onError));
    } catch (e) {
      debugPrint('Habit "${widget.habit.title}": using the fallback UI ($e)');
      processor.dispose();
    }
  }

  void _close() {
    _dataSub?.unsubscribe();
    _dataSub = null;
    for (final s in _subs) {
      s.unsubscribe();
    }
    _subs.clear();
    _processor?.dispose();
    _processor = null;
    _surface = null;
  }

  void _onError(A2uiRendererError error) {
    debugPrint('Habit "${widget.habit.title}": surface error ${error.code}: ${error.message}');
    if (!mounted) return;
    setState(_close);
  }

  void _onState() {
    if (!mounted) return;
    _pushToSurface();
    if (_surface == null) setState(() {});
  }

  /// Copies the stored entry (and habit facts) into the data model when it
  /// was changed outside this surface.
  void _pushToSurface() {
    final surface = _surface;
    if (surface == null || _syncing) return;
    final want = _model(entry);
    if (jsonEncode(want) == jsonEncode(surface.dataModel.get('/'))) return;
    _syncing = true;
    try {
      surface.dataModel.set('/', want);
    } finally {
      _syncing = false;
    }
  }

  /// Saves what the components wrote into the data model.
  void _pullFromSurface() {
    final surface = _surface;
    if (surface == null || _syncing) return;
    final raw = surface.dataModel.get('/');
    if (raw is! Map) return;
    final data = (jsonDecode(jsonEncode(raw)) as Map).cast<String, dynamic>()
      ..remove('habit')
      ..remove('day');
    _save(HabitEntry.fromJson(data));
  }

  void _save(HabitEntry next) {
    if (jsonEncode(next.toJson()) == jsonEncode(entry.toJson())) return;
    if (widget.persist) {
      _syncing = true;
      unawaited(widget.state.logHabit(widget.day, widget.habit.id, next));
      _syncing = false;
    } else {
      setState(() => _preview = next);
    }
    _pushToSurface();
  }

  void _onAction(A2uiRendererAction action) {
    final c = action.context;
    switch (action.name) {
      case logEntryAction:
        _save(applyLogEntry(entry, c));
      case finishSessionAction:
        _save(applyFinishSession(entry, c, DateTime.now()));
      case askCoachAction:
        final request = {...c, 'habit': widget.habit.title, 'day': dayKey(widget.day)};
        if (widget.onAskCoach != null) {
          widget.onAskCoach!(widget.habit, request);
        } else if (mounted) {
          showCoachSheet(context, widget.state, habit: widget.habit, request: request);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final surface = _surface;
    return HabitScope(
      habit: widget.habit,
      day: widget.day,
      speechLocale: widget.state.settings.speechLocale,
      history: (metric, days) =>
          metricHistory(widget.state.logs, widget.habit, metric, days: days, end: widget.day),
      child: surface == null
          ? HabitFallback(habit: widget.habit, entry: entry, onChanged: _save)
          : A2uiSurface(key: ObjectKey(surface), surface: surface),
    );
  }
}

num? _num(Object? v) => v is num ? v : (v is String ? num.tryParse(v) : null);

Map<String, num> _metrics(Object? v) => {
      if (v is Map)
        for (final e in v.entries)
          if (_num(e.value) != null) e.key.toString(): _num(e.value)!,
    };

/// The entry after a `logEntry` action with [context]
/// `{done?, value?, addValue?, minutes?, addMinutes?, metrics?, notes?}`.
HabitEntry applyLogEntry(HabitEntry current, Map<String, dynamic> context) {
  final e = current.copy();
  if (context['done'] is bool) e.done = context['done'] as bool;
  if (_num(context['value']) != null) e.value = _num(context['value']);
  if (_num(context['addValue']) != null) e.value = (e.value ?? 0) + _num(context['addValue'])!;
  if (_num(context['minutes']) != null) e.minutes = _num(context['minutes'])!.round();
  if (_num(context['addMinutes']) != null) e.minutes = (e.minutes ?? 0) + _num(context['addMinutes'])!.round();
  e.metrics.addAll(_metrics(context['metrics']));
  if (context['notes'] is String) e.notes = context['notes'] as String;
  return e;
}

/// The entry after a `finishSession` action with [context]
/// `{durationSec?, addMinutes?, metrics?, transcript?}`: a session is
/// appended and its metrics become the day's latest metrics.
HabitEntry applyFinishSession(HabitEntry current, Map<String, dynamic> context, DateTime now) {
  final e = current.copy();
  final metrics = _metrics(context['metrics']);
  e.sessions.add(HabitSession(
    at: now,
    durationSec: _num(context['durationSec'])?.round() ?? 0,
    metrics: metrics,
    transcript: context['transcript'] is String ? context['transcript'] as String : null,
  ));
  e.metrics.addAll(metrics);
  if (_num(context['addMinutes']) != null) e.minutes = (e.minutes ?? 0) + _num(context['addMinutes'])!.round();
  return e;
}

/// Plain logging UI for a habit whose surface is missing or unusable.
class HabitFallback extends StatelessWidget {
  final HabitDef habit;
  final HabitEntry entry;
  final ValueChanged<HabitEntry> onChanged;
  const HabitFallback({super.key, required this.habit, required this.entry, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final counted = habit.kind == HabitKind.count;
    final timed = habit.kind == HabitKind.duration || habit.kind == HabitKind.practice;
    final have = counted ? (entry.value ?? 0) : (entry.minutes ?? 0);
    final step = timed ? 5 : 1;
    void bump(num by) {
      final next = entry.copy();
      final v = (have + by).clamp(0, 100000);
      counted ? next.value = v : next.minutes = v.round();
      onChanged(next);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      if (counted || timed)
        Row(children: [
          IconButton.filledTonal(
            tooltip: 'Less',
            onPressed: have <= 0 ? null : () => bump(-step),
            icon: const Icon(Icons.remove),
          ),
          Expanded(
            child: Text(
              '$have / ${habit.target} ${timed ? 'min' : habit.unit}',
              textAlign: TextAlign.center,
              style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          IconButton.filled(tooltip: 'More', onPressed: () => bump(step), icon: const Icon(Icons.add)),
        ]),
      CheckboxListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: habitDone(entry, habit),
        onChanged: (v) => onChanged(entry.copy()..done = v ?? false),
        title: const Text('Done today'),
      ),
    ]);
  }
}
