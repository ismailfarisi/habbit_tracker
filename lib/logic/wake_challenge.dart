/// Pure logic of the anti-snooze wake challenge: phrases to read aloud with
/// a forgiving match against the speech transcript, and math problems.
library;

import 'dart:math';

const wakePhrases = [
  'The early morning light is calling me out of bed',
  'I am awake and ready to make today count',
  'Fresh water on my face and a clear mind for the day',
  'Discipline is choosing what I want most over what I want now',
  'Seven bright stars fade slowly as the sun rises',
  'A brisk walk in the cool breeze wakes up my whole body',
  'Today I will keep my promises to myself',
  'Quick brown foxes jump over lazy sleeping dogs',
];

/// Math problems to solve in a row.
const wakeChallengeMathCount = 2;

String randomWakePhrase(Random rng, {String? not}) {
  final options = wakePhrases.where((p) => p != not).toList();
  return options[rng.nextInt(options.length)];
}

List<String> _words(String s) =>
    s.toLowerCase().replaceAll(RegExp(r"[^a-z0-9' ]"), ' ').split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();

int _distance(String a, String b) {
  var prev = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final cur = List<int>.filled(b.length + 1, 0)..[0] = i;
    for (var j = 1; j <= b.length; j++) {
      cur[j] = [prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)].reduce(min);
    }
    prev = cur;
  }
  return prev[b.length];
}

/// Words match when equal, or for longer words when one letter is off
/// (recognisers often drop plurals or mishear a single sound).
bool _sameWord(String a, String b) => a == b || (min(a.length, b.length) >= 4 && _distance(a, b) <= 1);

/// Fraction (0..1) of [target]'s words heard in order in [heard] (longest
/// common subsequence of words, fuzzily compared).
double phraseMatchScore(String target, String heard) {
  final t = _words(target), h = _words(heard);
  if (t.isEmpty) return 0;
  var prev = List<int>.filled(h.length + 1, 0);
  for (var i = 1; i <= t.length; i++) {
    final cur = List<int>.filled(h.length + 1, 0);
    for (var j = 1; j <= h.length; j++) {
      cur[j] = _sameWord(t[i - 1], h[j - 1]) ? prev[j - 1] + 1 : max(prev[j], cur[j - 1]);
    }
    prev = cur;
  }
  return prev[h.length] / t.length;
}

/// Whether [heard] is close enough to [target] to prove the user is awake.
bool phraseMatches(String target, String heard, {double threshold = 0.8}) =>
    phraseMatchScore(target, heard) >= threshold;

class MathProblem {
  final String question;
  final int answer;
  const MathProblem(this.question, this.answer);

  @override
  String toString() => '$question = $answer';
}

/// A problem that needs a moment of real thought: "a × b + c".
MathProblem mathProblem(Random rng) {
  final a = 6 + rng.nextInt(14), b = 3 + rng.nextInt(7), c = 11 + rng.nextInt(89);
  return MathProblem('$a × $b + $c', a * b + c);
}
