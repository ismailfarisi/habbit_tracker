import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../app_state.dart';
import '../logic/stats.dart';
import '../logic/tasks.dart';
import '../models.dart';
import '../widgets/adaptive.dart';
import '../widgets/task_editor.dart';
import 'quran.dart';
import '../goals/goals_card.dart';

/// A task's or goal habit's instructions: steps to tick, what counts as
/// done, and for Quran practice the verified passage (a habit's next daily
/// portion) with translation and recitation.
class TaskGuideScreen extends StatelessWidget {
  final AppState state;
  final String? taskId;
  final String? habitId;
  final DateTime? day, today;
  const TaskGuideScreen({super.key, required this.state, this.taskId, this.habitId, this.day, this.today});

  static Route<void> route(AppState state, {String? taskId, String? habitId, DateTime? day, DateTime? today}) => MaterialPageRoute<void>(
    builder: (_) => TaskGuideScreen(state: state, taskId: taskId, habitId: habitId, day: day, today: today),
  );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final asOf = today ?? DateTime.now();
        final now = day ?? asOf;
        final key = dayKey(now);
        final isToday = DateUtils.isSameDay(now, asOf);
        final task = taskId == null ? null : state.taskById(taskId!);
        final habit = habitId == null ? null : state.habitById(habitId!);
        if (task == null && habit == null) {
          return Scaffold(appBar: AppBar(), body: const Center(child: Text('This was removed.')));
        }
        final entry = habit == null ? null : state.habitEntry(now, habit.id);
        final g = task?.guide ?? habit?.guide ?? const TaskGuide();
        final quran = habit != null ? state.quranFor(habit, now, today: asOf) : state.quranForTask(task!, now, today: asOf);
        final t = Theme.of(context);
        final ticked = task != null
            ? task.stepsDone[key] ?? <int>{}
            : {for (final v in (entry!.data['steps'] as List?) ?? const []) if (v is num) v.toInt()};
        final done = task != null ? task.isDoneOn(now) : habitDone(entry, habit!);
        final goal = state.goalFor(task?.id ?? habit!.id);
        final future = isForecastDay(now, today: asOf);
        final dateLabel = DateFormat.MMMEd().format(now);
        final notes = task?.notes ?? '';
        void tick(int i, bool on) {
          if (task != null) {
            state.updateTask(task, (x) {
              final set = x.stepsDone[key] ??= <int>{};
              on ? set.add(i) : set.remove(i);
            });
          } else {
            final set = {...ticked};
            on ? set.add(i) : set.remove(i);
            state.logHabit(now, habit!.id, entry!.copy()..data['steps'] = (set.toList()..sort()));
          }
        }

        void markDone() => task != null
            ? state.updateTask(task, (x) => x.doneDates.add(key))
            : state.logHabit(now, habit!.id, entry!.copy()..done = true);

        return Scaffold(
          appBar: AppBar(
            title: Text(task?.title ?? '${habit!.emoji} ${habit.title}'),
            actions: [
              if (task != null)
                IconButton(
                  tooltip: 'Edit plan',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => showTaskEditor(context, state, task: task),
                ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              if (!isToday)
                Text('${future ? 'Forecast' : 'Log'} · ${DateFormat.yMMMMEEEEd().format(now)}',
                    style: t.textTheme.titleMedium),
              if (goal != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: ActionChip(
                    key: const Key('guide-goal'),
                    avatar: Text(goal.emoji),
                    label: Text('Goal: ${goal.title}'),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => GoalScreen(state: state, goalId: goal.id)),
                    ),
                  ),
                ),
              if (g.minutes != null || notes.isNotEmpty || habit != null)
                Text(
                  [
                    if (habit != null) habit.describeSchedule(),
                    if (g.minutes != null) 'About ${g.minutes} min',
                    if (notes.isNotEmpty) notes,
                  ].join(' · '),
                  style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
              if ((habit != null ? state.sessionForHabit(habit, now, today: asOf) : state.sessionForTask(task!, now, today: asOf)) case final s?) ...[
                const SizedBox(height: 12),
                Container(
                  key: const Key('guide-session'),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: t.colorScheme.secondaryContainer.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${isToday ? 'Today' : dateLabel} · session ${s.$1} of ${s.$2}',
                        style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSecondaryContainer),
                      ),
                      const SizedBox(height: 4),
                      Text(s.$3, style: t.textTheme.titleMedium),
                    ],
                  ),
                ),
              ],
              if (g.steps.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('Steps', style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                for (final (i, s) in g.steps.indexed)
                  CheckboxListTile.adaptive(
                    key: ValueKey('step-$i'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: ticked.contains(i),
                    title: Text('${i + 1}. $s'),
                    onChanged: future ? null : (v) => tick(i, v == true),
                  ),
              ],
              if (g.doneWhen.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: t.colorScheme.primaryContainer.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.flag_outlined, size: 20, color: t.colorScheme.primary),
                      const SizedBox(width: 8),
                      Expanded(child: Text('Done when: ${g.doneWhen}')),
                    ],
                  ),
                ),
              ],
              if (quran != null) ...[
                const SizedBox(height: 16),
                if (habit != null || task!.isRepeating)
                  Text(
                    isToday ? "Today's portion" : 'Portion for $dateLabel',
                    style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                  ),
                if (habit != null || task!.isRepeating) const SizedBox(height: 6),
                QuranPractice(
                  portion: quran,
                  whole: habit != null ? habit.guide?.quran : state.quranPlanForTask(task!),
                  newLabel: isToday ? 'New today' : 'New on $dateLabel',
                ),
              ],
              const SizedBox(height: 20),
              future
                  ? Text(
                      'Planned for ${DateFormat.yMMMMEEEEd().format(now)}, if each day before it is done.',
                      style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                    )
                  : done
                  ? Row(
                      children: [
                        Icon(Icons.check_circle, color: t.colorScheme.primary),
                        const SizedBox(width: 8),
                        Expanded(child: Text(isToday ? 'Done for today. Well done for showing up.' : 'Done on $dateLabel.')),
                      ],
                    )
                  : FilledButton.icon(
                      key: const Key('guide-done'),
                      style: primaryButton,
                      onPressed: markDone,
                      icon: const Icon(Icons.check),
                      label: const Text('Mark done'),
                    ),
            ],
          ),
        );
      },
    );
  }
}

enum _Scope { portion, withLast, allLearned }

/// A memorisation portion with a switch to recite it together with the
/// ayat already learned from the same passage.
class QuranPractice extends StatefulWidget {
  final QuranRef portion;
  final QuranRef? whole;
  final String newLabel;
  final AssetBundle? bundle;
  const QuranPractice({super.key, required this.portion, this.whole, this.newLabel = 'New today', this.bundle});

  @override
  State<QuranPractice> createState() => _QuranPracticeState();
}

class _QuranPracticeState extends State<QuranPractice> {
  _Scope _scope = _Scope.portion;

  @override
  Widget build(BuildContext context) {
    final p = widget.portion;
    final w = widget.whole;
    QuranPassageView view(int from) => QuranPassageView(
      key: ValueKey('passage-${p.surah}-$from-${p.to}'),
      passage: from == p.from ? p : QuranRef(p.surah, from, p.to, mode: p.mode),
      newFrom: from == p.from ? null : p.from,
      newLabel: widget.newLabel,
      bundle: widget.bundle,
    );
    if (w == null || p.mode != 'memorise' || w.surah != p.surah || p.from <= w.from) return view(p.from);
    final size = w.perDay ?? (p.to - p.from + 1);
    final lastFrom = p.from - size < w.from ? w.from : p.from - size;
    final scope = lastFrom == w.from && _scope == _Scope.withLast ? _Scope.allLearned : _scope;
    final t = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Recite together with what you learned',
          style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 6),
        SegmentedButton<_Scope>(
          key: const Key('quran-scope'),
          showSelectedIcon: false,
          segments: [
            const ButtonSegment(value: _Scope.portion, label: Text('New only')),
            if (lastFrom > w.from)
              ButtonSegment(value: _Scope.withLast, label: Text('+ ${_range(lastFrom, p.from - 1)}')),
            ButtonSegment(value: _Scope.allLearned, label: Text('All ${_range(w.from, p.to)}')),
          ],
          selected: {scope},
          onSelectionChanged: (v) => setState(() => _scope = v.first),
        ),
        const SizedBox(height: 8),
        view(switch (scope) {
          _Scope.portion => p.from,
          _Scope.withLast => lastFrom,
          _Scope.allLearned => w.from,
        }),
      ],
    );
  }
}

String _range(int from, int to) => from == to ? '$from' : '$from–$to';

/// Verses of a passage from the bundled Tanzil text, with an optional
/// translation, per-ayah recitation, a hide-to-test mode and a repeat counter.
/// With [newFrom], ayat before it are marked as already learned.
class QuranPassageView extends StatefulWidget {
  final QuranRef passage;
  final AssetBundle? bundle;
  final int? newFrom;
  final String newLabel;
  const QuranPassageView({super.key, required this.passage, this.bundle, this.newFrom, this.newLabel = 'New today'});

  @override
  State<QuranPassageView> createState() => _QuranPassageViewState();
}

class _QuranPassageViewState extends State<QuranPassageView> {
  late final Future<List<String>> _verses = QuranText.verses(p.surah, p.from, p.to, widget.bundle);
  Future<List<String>>? _translation;
  late bool _hide = p.mode == 'revise';
  final _revealed = <int>{};
  int _reps = 0;
  int? _playing;
  AudioPlayer? _player;

  QuranRef get p => widget.passage;

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  Future<void> _play(int ayah, {bool continueAll = false}) async {
    final player = _player ??= AudioPlayer();
    setState(() => _playing = ayah);
    await player.stop();
    await player.play(UrlSource(ayahAudioUrl(p.surah, ayah)));
    await player.onPlayerComplete.first;
    if (!mounted || _playing != ayah) return;
    if (continueAll && ayah < p.to) return _play(ayah + 1, continueAll: true);
    setState(() => _playing = null);
  }

  Future<void> _stop() async {
    setState(() => _playing = null);
    await _player?.stop();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: FutureBuilder<List<String>>(
          future: _verses,
          builder: (context, snap) {
            final verses = snap.data;
            if (verses == null) return const Center(child: CircularProgressIndicator.adaptive());
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        passageLabel(p.surah, p.from, p.to),
                        style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                    IconButton(
                      tooltip: _playing == null ? 'Play all' : 'Stop',
                      icon: Icon(_playing == null ? Icons.play_circle_outline : Icons.stop_circle_outlined),
                      onPressed: () => _playing == null ? _play(p.from, continueAll: true) : _stop(),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    FilterChip(
                      label: const Text('Translation'),
                      selected: _translation != null,
                      onSelected: (v) => setState(() => _translation = v ? loadTranslation(p.surah) : null),
                    ),
                    FilterChip(
                      key: const Key('quran-hide'),
                      label: const Text('Test myself'),
                      selected: _hide,
                      onSelected: (v) => setState(() {
                        _hide = v;
                        _revealed.clear();
                      }),
                    ),
                  ],
                ),
                FutureBuilder<List<String>>(
                  future: _translation,
                  builder: (context, tr) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (tr.hasError) Text('Translation needs the internet the first time.', style: muted),
                      for (final (i, v) in verses.indexed) ...[
                        if (widget.newFrom case final n? when p.from + i == p.from || p.from + i == n)
                          _divider(context, p.from + i < n ? 'Learned · ayat ${_range(p.from, n - 1)}' : widget.newLabel),
                        _verse(context, p.from + i, v, tr.data),
                      ],
                    ],
                  ),
                ),
                const Divider(),
                Row(
                  children: [
                    Expanded(child: Text('Repetitions: $_reps', style: t.textTheme.bodyMedium)),
                    TextButton(
                      style: compactButton,
                      onPressed: _reps == 0 ? null : () => setState(() => _reps = 0),
                      child: const Text('Reset'),
                    ),
                    FilledButton.tonal(
                      key: const Key('quran-rep'),
                      style: compactButton,
                      onPressed: () => setState(() => _reps++),
                      child: const Text('+1'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '${QuranText.attribution}\n${QuranText.recitationAttribution}'
                  '${_translation == null ? '' : '\n${QuranText.translationAttribution}'}',
                  style: muted,
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _divider(BuildContext context, String label) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Text(label, style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.primary)),
          const SizedBox(width: 8),
          const Expanded(child: Divider()),
        ],
      ),
    );
  }

  Widget _verse(BuildContext context, int ayah, String text, List<String>? tr) {
    final t = Theme.of(context);
    final hidden = _hide && !_revealed.contains(ayah);
    return InkWell(
      onTap: _hide ? () => setState(() => _revealed.contains(ayah) ? _revealed.remove(ayah) : _revealed.add(ayah)) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                IconButton(
                  tooltip: 'Play ayah $ayah',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(_playing == ayah ? Icons.graphic_eq : Icons.play_arrow_rounded),
                  onPressed: () => _play(ayah),
                ),
                Expanded(
                  child: hidden
                      ? Container(
                          key: ValueKey('hidden-$ayah'),
                          height: 40,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: t.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text('Ayah $ayah · tap to check', style: t.textTheme.bodySmall),
                        )
                      : Text(
                          '$text \u06DD${_arabicDigits(ayah)}',
                          textDirection: TextDirection.rtl,
                          textAlign: TextAlign.right,
                          style: t.textTheme.headlineSmall?.copyWith(height: 1.9),
                        ),
                ),
              ],
            ),
            if (tr != null && ayah - 1 < tr.length && !hidden)
              Padding(
                padding: const EdgeInsets.only(left: 48),
                child: Text('$ayah. ${tr[ayah - 1]}', style: t.textTheme.bodyMedium),
              ),
          ],
        ),
      ),
    );
  }
}

String _arabicDigits(int n) => n.toString().split('').map((d) => String.fromCharCode(0x0660 + int.parse(d))).join();
