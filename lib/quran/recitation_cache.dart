import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models.dart';
import 'quran.dart';

/// The local copy of the Alafasy 128 kbps recording. Only completed files
/// enter the cache. Streaming a verse never opts the user into a download.
class RecitationCache {
  static final _writes = <RecitationDownload, Future<void>>{};

  /// Before erasing the audio directory, stop writers and wait for their
  /// staging files to close so an older request cannot re-create it.
  static Future<void> cancelDownloads() async {
    final active = Map.of(_writes);
    for (final job in active.keys) {
      job.close();
    }
    await Future.wait(active.values.map((job) => job.then<void>((_) {}, onError: (Object _) {})));
  }

  final Future<Directory> Function() directory;
  final http.Client Function() client;
  const RecitationCache({this.directory = getApplicationSupportDirectory, this.client = http.Client.new});

  Future<File> _file(int surah, int ayah) async =>
      File('${(await directory()).path}/quran-audio/alafasy-128/$surah-$ayah.mp3');

  Future<File?> cached(int surah, int ayah) async {
    final f = await _file(surah, ayah);
    return await f.exists() && await f.length() > 0 ? f : null;
  }

  Future<bool> hasPassage(QuranRef p) async {
    for (var ayah = p.from; ayah <= p.to; ayah++) {
      if (await cached(p.surah, ayah) == null) return false;
    }
    return true;
  }

  RecitationDownload begin() => RecitationDownload._(this, client());
}

/// A cancellable size check or download. Complete ayat survive cancellation
/// so retries request only the missing files.
class RecitationDownload {
  final RecitationCache _cache;
  final http.Client _client;
  final _abort = Completer<void>();
  RecitationDownload._(this._cache, this._client);

  void close() {
    if (_abort.isCompleted) return;
    _abort.complete();
    _client.close();
  }

  void _checkActive() {
    if (_abort.isCompleted) throw StateError('Download stopped');
  }

  Future<http.StreamedResponse> _request(String method, int surah, int ayah) {
    _checkActive();
    return _client
        .send(http.AbortableRequest(method, Uri.parse(ayahAudioUrl(surah, ayah)), abortTrigger: _abort.future))
        .timeout(const Duration(seconds: 15));
  }

  /// Null when the server does not advertise sizes. No audio is transferred.
  Future<int?> remainingBytes(QuranRef p) async {
    var total = 0;
    for (var a = p.from; a <= p.to; a++) {
      if (await _cache.cached(p.surah, a) != null) continue;
      final res = await _request('HEAD', p.surah, a);
      await res.stream.drain<void>().timeout(const Duration(seconds: 15));
      if (res.statusCode == 405 || res.statusCode == 501) return null;
      if (res.statusCode != 200) throw const HttpException('Recording unavailable');
      if ((res.contentLength ?? 0) <= 0) return null;
      total += res.contentLength!;
    }
    return total;
  }

  Future<void> save(QuranRef p, void Function(int ayah, int bytes) progress) async {
    if (RecitationCache._writes.containsKey(this)) throw StateError('Download already active');
    final writing = _save(p, progress);
    RecitationCache._writes[this] = writing;
    try {
      await writing;
    } finally {
      RecitationCache._writes.remove(this);
    }
  }

  Future<void> _save(QuranRef p, void Function(int ayah, int bytes) progress) async {
    var received = 0;
    for (var a = p.from; a <= p.to; a++) {
      _checkActive();
      if (await _cache.cached(p.surah, a) != null) continue;
      final file = await _cache._file(p.surah, a);
      _checkActive();
      await file.parent.create(recursive: true);
      final response = await _request('GET', p.surah, a);
      final type = response.headers['content-type']?.split(';').first.trim();
      if (response.statusCode != 200 ||
          (type != null && !type.startsWith('audio/') && type != 'application/octet-stream')) {
        throw const HttpException('Recording unavailable');
      }
      // A unique staging directory also permits overlapping passage downloads.
      _checkActive();
      final staging = await file.parent.createTemp('download-');
      try {
        final partial = File('${staging.path}/ayah.part');
        final output = await partial.open(mode: FileMode.write);
        var bytes = 0;
        try {
          await for (final chunk in response.stream.timeout(const Duration(seconds: 20))) {
            _checkActive();
            await output.writeFrom(chunk);
            bytes += chunk.length;
            progress(a, received + bytes);
          }
        } finally {
          await output.close();
        }
        _checkActive();
        if (bytes == 0 || (response.contentLength != null && bytes != response.contentLength)) {
          throw const HttpException('Incomplete recording');
        }
        await partial.rename(file.path);
        received += bytes;
      } finally {
        await staging.delete(recursive: true);
      }
    }
  }
}
