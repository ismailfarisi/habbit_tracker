import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../logic/stats.dart';
import '../models.dart';
import '../widgets/adaptive.dart';
import 'quran.dart';
import 'recitation_cache.dart';
import 'recitation_controls.dart';
import 'surahs.dart';

/// Storage context for recall and revision, kept separate from a completion.
class QuranStudySession {
  final AppState state;
  final DateTime day, today;
  final String activity;
  const QuranStudySession(this.state, this.day, this.today, this.activity);
  bool get forecast => isForecastDay(day, today: today);
  String keyFor(QuranRef p) => '$activity/${p.surah}:${p.from}-${p.to}';
}

enum _Scope { portion, withLast, allLearned }

class QuranPractice extends StatefulWidget {
  final QuranRef portion;
  final QuranRef? whole;
  final String newLabel, dayLabel;
  final AssetBundle? bundle;
  final QuranStudySession? study;
  final VoidCallback? onComplete;
  final bool portionDone;
  const QuranPractice({
    super.key,
    required this.portion,
    this.whole,
    this.newLabel = 'New today',
    this.dayLabel = 'Today',
    this.bundle,
    this.study,
    this.onComplete,
    this.portionDone = false,
  });

  @override
  State<QuranPractice> createState() => _QuranPracticeState();
}

class _QuranPracticeState extends State<QuranPractice> {
  _Scope _scope = _Scope.portion;
  int? _bookmark;

  @override
  Widget build(BuildContext context) {
    final p = widget.portion;
    final w = widget.whole;
    final withLearned = w != null && p.mode == 'memorise' && w.surah == p.surah && p.from > w.from;
    final scope = withLearned ? _scope : _Scope.portion;
    final start = switch (scope) {
      _Scope.portion => p.from,
      _Scope.withLast => (p.from - (w!.perDay ?? (p.to - p.from + 1))).clamp(w.from, p.from),
      _Scope.allLearned => w!.from,
    };
    final end = scope == _Scope.allLearned && !widget.portionDone ? p.from - 1 : p.to;
    final bookmarks = [
      for (final id in widget.study?.state.settings.quranBookmarks ?? const <String>{})
        if (id.startsWith('${p.surah}:'))
          if (int.tryParse(id.split(':').last) case final a?
              when p.surah >= 1 && p.surah <= surahInfo.length && a >= 1 && a <= surahInfo[p.surah - 1].$3)
            a,
    ]..sort();
    final a = bookmarks.contains(_bookmark) ? _bookmark : null;
    final passage = QuranRef(
      p.surah,
      a ?? start,
      a ?? end,
      mode: a != null || scope == _Scope.allLearned ? 'revise' : p.mode,
    );
    final day = widget.dayLabel;
    final labels = {
      _Scope.portion: day,
      _Scope.withLast: 'Previous + ${day == 'Today' ? 'today' : day}',
      _Scope.allLearned: widget.study?.forecast == true ? 'Prior portions' : 'All learned',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (withLearned || bookmarks.isNotEmpty)
          Wrap(
            key: const Key('quran-scope'),
            spacing: 6,
            children: [
              for (final option in withLearned ? _Scope.values : const [_Scope.portion])
                ChoiceChip(
                  label: Text(labels[option]!),
                  selected: a == null && scope == option,
                  onSelected: (_) => setState(() {
                    _scope = option;
                    _bookmark = null;
                  }),
                ),
              if (bookmarks.isNotEmpty)
                PopupMenuButton<int>(
                  tooltip: 'Review a bookmarked ayah',
                  onSelected: (v) => setState(() => _bookmark = v),
                  itemBuilder: (_) => [for (final n in bookmarks) PopupMenuItem(value: n, child: Text('Ayah $n'))],
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(a == null ? 'Bookmarks (${bookmarks.length})' : 'Bookmarked ayah $a'),
                  ),
                ),
            ],
          ),
        QuranPassageView(
          key: ValueKey('passage-${passage.surah}-${passage.from}-${passage.to}-${passage.mode}'),
          passage: passage,
          newFrom: scope == _Scope.withLast && a == null ? p.from : null,
          newLabel: widget.newLabel,
          priorLabel: widget.study?.forecast == true ? 'Projected' : 'Learned',
          bundle: widget.bundle,
          study: widget.study,
        ),
        if (widget.onComplete != null && a == null && scope != _Scope.allLearned) ...[
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const Key('guide-done'),
            style: primaryButton,
            onPressed: widget.onComplete,
            icon: const Icon(Icons.check),
            label: Text(switch (p.mode) {
              'memorise' => 'Mark ayat ${_range(p.from, p.to)} learned',
              'revise' => 'Complete planned revision',
              _ => 'Mark ayat ${_range(p.from, p.to)} read',
            }),
          ),
        ],
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
  final String newLabel, priorLabel;
  final QuranStudySession? study;
  final RecitationCache audioCache;
  final AudioPlayer Function() createPlayer;
  const QuranPassageView({
    super.key,
    required this.passage,
    this.bundle,
    this.newFrom,
    this.newLabel = 'New today',
    this.priorLabel = 'Learned',
    this.study,
    this.audioCache = const RecitationCache(),
    this.createPlayer = AudioPlayer.new,
  });

  @override
  State<QuranPassageView> createState() => _QuranPassageViewState();
}

class _QuranPassageViewState extends State<QuranPassageView> {
  late final Future<List<String>> _verses = QuranText.verses(p.surah, p.from, p.to, widget.bundle);
  Future<List<String>>? _translation;
  late QuranPracticeLog _scratch = QuranPracticeLog(recall: p.mode == 'revise');
  late final _playback = RecitationPlayback(p, widget.audioCache, widget.createPlayer);

  QuranRef get p => widget.passage;
  QuranPracticeLog get _practice {
    final study = widget.study;
    if (study == null || study.forecast) return _scratch;
    return study.state.logFor(study.day).quranPractice[study.keyFor(p)] ?? _scratch;
  }

  void _change(void Function(QuranPracticeLog) change) {
    final next = QuranPracticeLog.fromJson(_practice.toJson());
    change(next);
    setState(() => _scratch = next);
    final study = widget.study;
    if (study != null && !study.forecast) {
      study.state.saveQuranPractice(study.day, study.keyFor(p), next, today: study.today);
    }
  }

  @override
  void initState() {
    super.initState();
    _playback.addListener(_mediaChanged);
  }

  void _mediaChanged() => setState(() {});

  @override
  void dispose() {
    _playback.removeListener(_mediaChanged);
    _playback.dispose();
    super.dispose();
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
            if (snap.hasError) return const Text('The bundled Quran text could not be loaded.');
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
                      tooltip: _playback.ayah == null ? 'Play all' : 'Stop',
                      icon: Icon(_playback.ayah == null ? Icons.play_circle_outline : Icons.stop_circle_outlined),
                      onPressed: () => _playback.ayah == null ? _playback.play(p.from, all: true) : _playback.stop(),
                    ),
                  ],
                ),
                if (_playback.status.isNotEmpty) Semantics(liveRegion: true, child: Text(_playback.status)),
                if (_playback.failed != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(onPressed: _playback.retry, child: const Text('Retry playback')),
                  ),
                OfflineRecitation(cache: widget.audioCache, passage: p),
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
                      selected: _practice.recall,
                      onSelected: (v) => _change((log) {
                        log.recall = v;
                        log.revealed.clear();
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
                          _divider(
                            context,
                            p.from + i < n ? '${widget.priorLabel} · ayat ${_range(p.from, n - 1)}' : widget.newLabel,
                          ),
                        _verse(context, p.from + i, v, tr.data),
                      ],
                    ],
                  ),
                ),
                const Divider(),
                if (widget.study?.forecast != true) ...[
                  Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text('Repetitions: ${_practice.repetitions}', style: t.textTheme.bodyMedium),
                      TextButton(
                        style: compactButton,
                        onPressed: _practice.repetitions == 0 ? null : () => _change((log) => log.repetitions = 0),
                        child: const Text('Reset'),
                      ),
                      FilledButton.tonal(
                        key: const Key('quran-rep'),
                        style: compactButton,
                        onPressed: () => _change((log) => log.repetitions++),
                        child: const Text('+1'),
                      ),
                    ],
                  ),
                  if (widget.study != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _practice.revised
                          ? Semantics(liveRegion: true, child: const Text('Revision saved · portion unchanged'))
                          : OutlinedButton.icon(
                              key: const Key('quran-revision'),
                              icon: const Icon(Icons.replay),
                              label: const Text('Save revision only'),
                              onPressed: () => _change((log) => log.revised = true),
                            ),
                    ),
                ],
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
          Flexible(
            child: Text(label, style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.primary)),
          ),
          const SizedBox(width: 8),
          const Expanded(child: Divider()),
        ],
      ),
    );
  }

  Widget _verse(BuildContext context, int ayah, String text, List<String>? tr) {
    final t = Theme.of(context);
    final hidden = _practice.recall && !_practice.revealed.contains(ayah);
    final study = widget.study;
    final bookmarked = study?.state.settings.quranBookmarks.contains('${p.surah}:$ayah') ?? false;
    return InkWell(
      onTap: _practice.recall
          ? () => _change((log) {
              if (!log.revealed.remove(ayah)) log.revealed.add(ayah);
            })
          : null,
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
                  icon: Icon(_playback.ayah == ayah ? Icons.graphic_eq : Icons.play_arrow_rounded),
                  onPressed: () => _playback.play(ayah),
                ),
                if (study != null && !study.forecast)
                  IconButton(
                    tooltip: '${bookmarked ? 'Remove bookmark for' : 'Bookmark'} ayah $ayah',
                    icon: Icon(bookmarked ? Icons.bookmark : Icons.bookmark_border),
                    onPressed: () => study.state.toggleQuranBookmark(p.surah, ayah),
                  ),
                Expanded(
                  child: hidden
                      ? Container(
                          key: ValueKey('hidden-$ayah'),
                          constraints: const BoxConstraints(minHeight: 48),
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
