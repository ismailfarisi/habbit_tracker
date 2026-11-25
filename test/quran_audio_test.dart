import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_tracker/models.dart';
import 'package:habit_tracker/quran/quran.dart';
import 'package:habit_tracker/quran/quran_practice.dart';
import 'package:habit_tracker/quran/recitation_cache.dart';
import 'package:habit_tracker/quran/recitation_controls.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'support.dart';

class _Player extends Fake implements AudioPlayer {
  final events = StreamController<void>.broadcast();
  final bool offline;
  final started = Completer<Source>();
  bool released = false;
  _Player({this.offline = false});

  @override
  Stream<void> get onPlayerComplete => events.stream;

  @override
  Future<void> play(
    Source source, {
    double? volume,
    double? balance,
    AudioContext? ctx,
    Duration? position,
    PlayerMode? mode,
  }) async {
    started.complete(source);
    if (offline) throw const SocketException('Offline');
  }

  @override
  Future<void> dispose() async {
    released = true;
    await events.close();
  }
}

class _EmptyCache extends Fake implements RecitationCache {
  @override
  Future<File?> cached(int surah, int ayah) async => null;
  @override
  Future<bool> hasPassage(QuranRef p) async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(mockPlugins);
  const passage = QuranRef(67, 1, 2);

  test('download sizes missing ayat, publishes complete files and retries only missing audio', () async {
    final dir = await Directory.systemTemp.createTemp('quran-retry-');
    addTearDown(() => dir.delete(recursive: true));
    final requests = <String>[];
    var fail = true;
    final cache = RecitationCache(
      directory: () async => dir,
      client: () => MockClient.streaming((request, _) async {
        final name = request.url.pathSegments.last;
        requests.add('${request.method} $name');
        if (request.method == 'HEAD') return http.StreamedResponse(const Stream.empty(), 200, contentLength: 32);
        if (name.endsWith('002.mp3') && fail) {
          return http.StreamedResponse(Stream.value([1]), 200, contentLength: 32);
        }
        return http.StreamedResponse(Stream.value(List.filled(32, 1)), 200, contentLength: 32);
      }),
    );
    expect(await cache.hasPassage(passage), isFalse);
    expect(requests, isEmpty);
    final first = cache.begin();
    expect(await first.remainingBytes(passage), 64);
    expect(requests, ['HEAD 067001.mp3', 'HEAD 067002.mp3']);
    await expectLater(first.save(passage, (_, _) {}), throwsA(isA<HttpException>()));
    first.close();
    expect(await (await cache.cached(67, 1))!.length(), 32);
    expect(await cache.cached(67, 2), isNull);

    fail = false;
    requests.clear();
    final retry = cache.begin();
    expect(await retry.remainingBytes(passage), 32);
    await retry.save(passage, (_, _) {});
    retry.close();
    expect(requests, ['HEAD 067002.mp3', 'GET 067002.mp3']);
    final offline = RecitationCache(directory: () async => dir, client: () => throw StateError('Unexpected HTTP'));
    expect(await offline.hasPassage(passage), isTrue);
    final player = _Player();
    final playback = RecitationPlayback(passage, offline, () => player);
    await playback.play(2);
    expect((await player.started.future as DeviceFileSource).path, (await cache.cached(67, 2))!.path);
    expect(playback.status, 'Playing ayah 2');
    playback.stop();
    await Future<void>.delayed(Duration.zero);
    expect(player.released, isTrue);
    playback.dispose();
  });

  test('stop aborts the active request and cleans up its partially written ayah', () async {
    final dir = await Directory.systemTemp.createTemp('quran-cancel-');
    addTearDown(() => dir.delete(recursive: true));
    final cache = RecitationCache(
      directory: () async => dir,
      client: () => MockClient.streaming((request, _) async {
        final abort = (request as http.AbortableRequest).abortTrigger!;
        Stream<List<int>> body() async* {
          yield [1];
          await abort;
          throw http.RequestAbortedException(request.url);
        }

        return http.StreamedResponse(body(), 200, contentLength: 2);
      }),
    );
    final download = cache.begin();
    final started = Completer<void>();
    final finished = expectLater(
      download.save(passage, (_, _) => started.complete()),
      throwsA(isA<http.RequestAbortedException>()),
    );
    await started.future;
    await RecitationCache.cancelDownloads();
    await finished;
    expect(await cache.cached(67, 1), isNull);
    expect(await dir.list(recursive: true).where((e) => e is File).toList(), isEmpty);
  });

  test('play all advances on completion, and stop releases the last player', () async {
    final players = <_Player>[];
    final playback = RecitationPlayback(passage, _EmptyCache(), () {
      final player = _Player();
      players.add(player);
      return player;
    });
    final second = Completer<void>();
    playback.addListener(() {
      if (playback.ayah == 2 && !playback.preparing && !second.isCompleted) second.complete();
    });
    await playback.play(1, all: true);
    players.single.events.add(null);
    await second.future.timeout(const Duration(seconds: 2));
    expect(players, hasLength(2));
    expect(players.first.released, isTrue);
    playback.stop();
    expect(playback.ayah, isNull);
    expect(players.last.released, isTrue);
    playback.dispose();
  });

  testWidgets('failed streaming clears playing and lets the reader retry or recall offline', (tester) async {
    QuranText.cache = QuranText.parse(File('assets/quran/quran-uthmani.txt').readAsStringSync());
    final s = await loadState({
      'settings.v1': jsonEncode({'onboarded': true}),
    });
    final day = DateTime(2026, 11, 20);
    final task = await s.addTask(title: 'Read Al-Mulk');
    final study = QuranStudySession(s, day, day, 'task/${task.id}');
    final players = <_Player>[];
    final cache = _EmptyCache();
    tester.view.physicalSize = const Size(600, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: QuranPassageView(
              study: study,
              passage: passage,
              audioCache: cache,
              createPlayer: () {
                final p = _Player(offline: players.isEmpty);
                players.add(p);
                return p;
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Play all'));
    await tester.pumpAndSettle();
    expect(players.single.released, isTrue);
    expect(find.text('Could not play ayah 1.'), findsOneWidget);
    expect(find.byTooltip('Stop'), findsNothing);
    await tester.tap(find.byKey(const Key('quran-hide')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('hidden-1')));
    await tester.pumpAndSettle();
    final arabic = (await QuranText.verses(67, 1, 1)).single;
    expect(find.textContaining(arabic), findsOneWidget);

    await tester.tap(find.text('Retry playback'));
    await tester.pumpAndSettle();
    expect(find.text('Playing ayah 1'), findsOneWidget);
    players.last.events.addError(StateError('Connection lost'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Stop'), findsNothing);
    expect(find.text('Could not play ayah 1.'), findsOneWidget);
    expect(s.storage.loadTasks().single.doneDates, isEmpty);
    expect(s.storage.loadLogs().values.single.quranPractice.values.single.revised, isFalse);
  });
}
