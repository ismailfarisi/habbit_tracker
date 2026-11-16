import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_tracker/agent/speech_engine.dart';
import 'package:habit_tracker/app_state.dart';
import 'package:habit_tracker/logic/stats.dart';
import 'package:habit_tracker/logic/wake_challenge.dart';
import 'package:habit_tracker/models.dart';
import 'package:habit_tracker/screens/wake_challenge_screen.dart';
import 'package:habit_tracker/widgets/cards/wake_card.dart';

import 'support.dart';

class _NoSpeech extends FakeSpeechEngine {
  _NoSpeech() : super('');
  @override
  Future<bool> init({required void Function() onStopped, required void Function(String message) onError}) async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(mockPlugins);
  tearDown(() => speechEngineFactory = PluginSpeechEngine.new);

  group('phrase matching', () {
    const phrase = 'Today I will keep my promises to myself';
    test('exact, punctuation and case do not matter', () {
      expect(phraseMatchScore(phrase, 'today i will keep my promises to myself!'), 1);
      expect(phraseMatches(phrase, 'Today, I will keep my promises to myself.'), isTrue);
    });
    test('tolerates a missed word and small mishearings', () {
      expect(phraseMatches(phrase, 'today I will keep my promise to myself'), isTrue);
      expect(phraseMatches(phrase, 'today I keep my promises to myself'), isTrue);
    });
    test('rejects mumbling, partial reads and wrong order', () {
      expect(phraseMatches(phrase, ''), isFalse);
      expect(phraseMatches(phrase, 'today I will'), isFalse);
      expect(phraseMatches(phrase, 'myself to promises my keep will I today'), isFalse);
      expect(phraseMatches(phrase, 'five more minutes please'), isFalse);
    });
    test('every built-in phrase matches itself', () {
      for (final p in wakePhrases) {
        expect(phraseMatches(p, p), isTrue, reason: p);
      }
      final rng = Random(3);
      for (var i = 0; i < 20; i++) {
        expect(randomWakePhrase(rng, not: wakePhrases.first), isNot(wakePhrases.first));
      }
    });
  });

  test('math problems are well formed', () {
    final rng = Random(7);
    for (var i = 0; i < 50; i++) {
      final p = mathProblem(rng);
      final m = RegExp(r'^(\d+) × (\d+) \+ (\d+)$').firstMatch(p.question)!;
      expect(int.parse(m[1]!) * int.parse(m[2]!) + int.parse(m[3]!), p.answer);
      expect(int.parse(m[1]!), greaterThanOrEqualTo(6));
    }
  });

  Future<AppState> pumpCard(WidgetTester tester, {WakeChallenge mode = WakeChallenge.off, DateTime? now}) async {
    late AppState state;
    await tester.runAsync(() async {
      state = await loadState();
      await state.updateSettings((s) => s.wakeChallenge = mode);
    });
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListenableBuilder(
          listenable: state,
          builder: (_, _) => SingleChildScrollView(child: WakeCard(state: state, log: state.logFor(now ?? DateTime.now()), now: now)),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return state;
  }

  int answerShown(WidgetTester tester) {
    final q = tester.widget<Text>(find.byKey(const Key('mathQuestion'))).data!;
    final m = RegExp(r'(\d+) × (\d+) \+ (\d+)').firstMatch(q)!;
    return int.parse(m[1]!) * int.parse(m[2]!) + int.parse(m[3]!);
  }

  testWidgets("challenge off: I'm up marks the wake-up right away", (tester) async {
    final state = await pumpCard(tester);
    await tester.tap(find.text("I'm up!"));
    await tester.pumpAndSettle();
    expect(state.today.wakeAt, isNotNull);
    expect(find.byType(WakeChallengeScreen), findsNothing);
  });

  testWidgets('math challenge: wrong answer is rejected, two right answers log the wake-up', (tester) async {
    final state = await pumpCard(tester, mode: WakeChallenge.math);
    await tester.tap(find.text("I'm up!"));
    await tester.pumpAndSettle();
    expect(find.byType(WakeChallengeScreen), findsOneWidget);

    await tester.enterText(find.byKey(const Key('mathAnswer')), '${answerShown(tester) + 1}');
    await tester.tap(find.text('Check'));
    await tester.pumpAndSettle();
    expect(find.text('Not quite. Try again.'), findsOneWidget);
    expect(state.today.wakeAt, isNull);

    await tester.enterText(find.byKey(const Key('mathAnswer')), '${answerShown(tester)}');
    await tester.tap(find.text('Check'));
    await tester.pumpAndSettle();
    expect(find.text('Problem 2 of 2'), findsOneWidget);
    expect(state.today.wakeAt, isNull);

    await tester.enterText(find.byKey(const Key('mathAnswer')), '${answerShown(tester)}');
    await tester.tap(find.text('Check'));
    await tester.pumpAndSettle();
    expect(find.byType(WakeChallengeScreen), findsNothing);
    expect(state.today.wakeAt, isNotNull);
    expect(find.text('Undo'), findsOneWidget);
  });

  testWidgets('read-aloud challenge: reading the phrase logs the wake-up', (tester) async {
    final state = await pumpCard(tester, mode: WakeChallenge.readAloud);
    await tester.tap(find.text("I'm up!"));
    await tester.pumpAndSettle();
    final phrase = tester.widget<Text>(find.byKey(const Key('wakePhrase'))).data!.replaceAll(RegExp('[“”]'), '');
    speechEngineFactory = () => FakeSpeechEngine('uh $phrase');
    await tester.tap(find.text('Start reading'));
    await tester.pumpAndSettle();
    expect(find.byType(WakeChallengeScreen), findsNothing);
    expect(state.today.wakeAt, isNotNull);
  });

  testWidgets('read-aloud challenge: mumbling does not count', (tester) async {
    final state = await pumpCard(tester, mode: WakeChallenge.readAloud);
    await tester.tap(find.text("I'm up!"));
    await tester.pumpAndSettle();
    speechEngineFactory = () => FakeSpeechEngine('five more minutes');
    await tester.tap(find.text('Start reading'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Heard: five more minutes'), findsOneWidget);
    expect(find.byType(WakeChallengeScreen), findsOneWidget);
    expect(state.today.wakeAt, isNull);
  });

  testWidgets('read-aloud challenge falls back to math when speech is unavailable', (tester) async {
    final state = await pumpCard(tester, mode: WakeChallenge.readAloud);
    await tester.tap(find.text("I'm up!"));
    await tester.pumpAndSettle();
    speechEngineFactory = _NoSpeech.new;
    await tester.tap(find.text('Start reading'));
    await tester.pumpAndSettle();
    expect(find.textContaining('not available'), findsOneWidget);
    await tester.tap(find.textContaining('Solve math instead'));
    await tester.pumpAndSettle();
    for (var i = 0; i < wakeChallengeMathCount; i++) {
      await tester.enterText(find.byKey(const Key('mathAnswer')), '${answerShown(tester)}');
      await tester.tap(find.text('Check'));
      await tester.pumpAndSettle();
    }
    expect(state.today.wakeAt, isNotNull);
  });

  testWidgets('leaving the challenge does not log the wake-up', (tester) async {
    final state = await pumpCard(tester, mode: WakeChallenge.math);
    await tester.tap(find.text("I'm up!"));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();
    expect(state.today.wakeAt, isNull);
    expect(find.text("I'm up!"), findsOneWidget);
  });

  testWidgets('a tapped wake notification opens the challenge', (tester) async {
    final state = await pumpCard(tester, mode: WakeChallenge.math);
    state.notifications.wakeChallengeRequest.value = dayKey(DateTime.now());
    await tester.pumpAndSettle();
    expect(find.byType(WakeChallengeScreen), findsOneWidget);
    expect(state.notifications.wakeChallengeRequest.value, isNull);
  });

  testWidgets('a wake notification for another day, or with the challenge off, is ignored', (tester) async {
    final state = await pumpCard(tester);
    state.notifications.wakeChallengeRequest.value = dayKey(DateTime.now());
    await tester.pumpAndSettle();
    expect(find.byType(WakeChallengeScreen), findsNothing);
    await tester.runAsync(() => state.updateSettings((s) => s.wakeChallenge = WakeChallenge.math));
    state.notifications.wakeChallengeRequest.value = '2000-01-01';
    await tester.pumpAndSettle();
    expect(find.byType(WakeChallengeScreen), findsNothing);
  });

  testWidgets("practice mode from Settings doesn't log a wake-up", (tester) async {
    late AppState state;
    await tester.runAsync(() async => state = await loadState());
    await tester.pumpWidget(MaterialApp(home: WakeChallengeScreen(state: state, mode: WakeChallenge.math, practice: true)));
    for (var i = 0; i < wakeChallengeMathCount; i++) {
      await tester.enterText(find.byKey(const Key('mathAnswer')), '${answerShown(tester)}');
      await tester.tap(find.text('Check'));
      await tester.pumpAndSettle();
    }
    expect(state.today.wakeAt, isNull);
  });

  testWidgets("the wake card shows last night's sleep", (tester) async {
    final now = DateTime(2026, 6, 2, 9);
    late AppState state;
    await tester.runAsync(() async {
      state = await loadState();
      await state.setBedtime(DateTime(2026, 6, 1), DateTime(2026, 6, 1, 22, 30));
      await state.setWake(DateTime(2026, 6, 2), DateTime(2026, 6, 2, 5, 0));
    });
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: WakeCard(state: state, log: state.logFor(now), now: now))));
    await tester.pumpAndSettle();
    expect(find.text('😴 Slept 6h 30m (goal 7.5 h)'), findsOneWidget);
    expect(find.text('Going to bed'), findsNothing);
  });

  testWidgets('in the evening "Going to bed" logs the bedtime on that night', (tester) async {
    final now = DateTime(2026, 6, 1, 21, 10);
    final state = await pumpCard(tester, now: now);
    expect(find.textContaining('Bedtime 9:30'), findsOneWidget);
    await tester.tap(find.text('Going to bed'));
    await tester.pumpAndSettle();
    expect(state.logFor(DateTime(2026, 6, 1)).bedtimeAt, isNotNull);
    expect(find.textContaining('In bed at'), findsOneWidget);
    await tester.tap(find.text('Undo').last);
    await tester.pumpAndSettle();
    expect(state.logFor(DateTime(2026, 6, 1)).bedtimeAt, isNull);
  });
}
