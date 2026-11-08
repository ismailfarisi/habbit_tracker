/// Local analysis of a spoken transcript, used alongside the AI feedback.
class SpeechMetrics {
  final int wordCount;
  final Duration duration;
  final Map<String, int> fillers;

  /// Share (0-1) of the target text's words that the recognizer heard, or
  /// null when there's no target text (e.g. impromptu speaking).
  final double? accuracy;
  final List<String> missedWords;

  const SpeechMetrics({
    required this.wordCount,
    required this.duration,
    required this.fillers,
    this.accuracy,
    this.missedWords = const [],
  });

  int get fillerCount => fillers.values.fold(0, (a, b) => a + b);

  double? get wordsPerMinute =>
      duration.inSeconds < 3 ? null : wordCount / (duration.inMilliseconds / 60000);

  String describe() {
    final b = StringBuffer('Words: $wordCount');
    if (wordsPerMinute != null) b.write(', pace: ${wordsPerMinute!.round()} words/min');
    b.write(', filler words: $fillerCount');
    if (fillers.isNotEmpty) {
      b.write(' (${fillers.entries.map((e) => '"${e.key}" x${e.value}').join(', ')})');
    }
    if (accuracy != null) {
      b.write(', recognizer matched ${(accuracy! * 100).round()}% of target words');
      if (missedWords.isNotEmpty) {
        b.write('; words not recognized: ${missedWords.take(20).join(', ')}');
      }
    }
    return b.toString();
  }
}

const _singleFillers = {'um', 'umm', 'uh', 'uhh', 'er', 'erm', 'ah', 'hmm', 'like', 'basically', 'actually', 'literally'};
const _phraseFillers = ['you know', 'i mean', 'kind of', 'sort of'];

List<String> tokenize(String text) => text
    .toLowerCase()
    .replaceAll(RegExp(r"[’']"), '')
    .split(RegExp(r'[^a-z0-9]+'))
    .where((w) => w.isNotEmpty)
    .toList();

SpeechMetrics analyzeSpeech(String transcript, Duration duration, {String? target}) {
  final words = tokenize(transcript);
  final fillers = <String, int>{};
  for (final w in words) {
    if (_singleFillers.contains(w)) fillers[w] = (fillers[w] ?? 0) + 1;
  }
  final joined = ' ${words.join(' ')} ';
  for (final p in _phraseFillers) {
    final n = ' $p '.allMatches(joined).length;
    if (n > 0) fillers[p] = n;
  }

  double? accuracy;
  var missed = <String>[];
  final targetWords = target == null ? const <String>[] : tokenize(target);
  if (targetWords.isNotEmpty && words.isNotEmpty) {
    final matched = _lcsMatches(targetWords, words);
    accuracy = matched.where((m) => m).length / targetWords.length;
    missed = {
      for (var i = 0; i < targetWords.length; i++)
        if (!matched[i]) targetWords[i],
    }.toList();
  }

  return SpeechMetrics(
    wordCount: words.length,
    duration: duration,
    fillers: fillers,
    accuracy: accuracy,
    missedWords: missed,
  );
}

/// For each word of [a], whether it is part of the longest common
/// subsequence with [b].
List<bool> _lcsMatches(List<String> a, List<String> b) {
  final n = a.length, m = b.length;
  final t = List.generate(n + 1, (_) => List.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      t[i][j] = a[i] == b[j] ? t[i + 1][j + 1] + 1 : (t[i + 1][j] > t[i][j + 1] ? t[i + 1][j] : t[i][j + 1]);
    }
  }
  final out = List.filled(n, false);
  var i = 0, j = 0;
  while (i < n && j < m) {
    if (a[i] == b[j]) {
      out[i] = true;
      i++;
      j++;
    } else if (t[i + 1][j] >= t[i][j + 1]) {
      i++;
    } else {
      j++;
    }
  }
  return out;
}
