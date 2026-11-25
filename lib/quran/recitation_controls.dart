import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../models.dart';
import 'quran.dart';
import 'recitation_cache.dart';

/// One playback request owns its native player and completion subscription.
/// Stopping, switching ayat or leaving the screen invalidates late callbacks.
class RecitationPlayback extends ChangeNotifier {
  final RecitationCache cache;
  final AudioPlayer Function() createPlayer;
  final QuranRef passage;
  RecitationPlayback(this.passage, this.cache, this.createPlayer);

  AudioPlayer? _player;
  StreamSubscription<void>? _complete;
  int _generation = 0;
  int? ayah, failed;
  bool _all = false, preparing = false;
  String get status {
    if (failed != null) return 'Could not play ayah $failed.';
    if (ayah == null) return '';
    return preparing ? 'Loading ayah $ayah' : 'Playing ayah $ayah';
  }

  Future<void> _release() async {
    final sub = _complete;
    final player = _player;
    _complete = null;
    _player = null;
    try {
      await Future.wait([if (sub != null) sub.cancel(), if (player != null) player.dispose()]);
    } catch (_) {
      // The native source may already be unavailable after a playback error.
    }
  }

  void stop() {
    _generation++;
    ayah = failed = null;
    preparing = false;
    unawaited(_release());
    notifyListeners();
  }

  Future<void> play(int number, {bool all = false}) async {
    final request = ++_generation;
    final released = _release();
    ayah = number;
    failed = null;
    preparing = true;
    _all = all;
    notifyListeners();
    void error() {
      if (request != _generation) return;
      _generation++;
      ayah = null;
      failed = number;
      preparing = false;
      unawaited(_release());
      notifyListeners();
    }

    try {
      await released;
      final file = await cache.cached(passage.surah, number);
      if (request != _generation) return;
      final player = _player = createPlayer();
      _complete = player.onPlayerComplete.listen((_) {
        if (request != _generation) return;
        if (all && number < passage.to) {
          unawaited(play(number + 1, all: true));
        } else {
          stop();
        }
      }, onError: (Object _) => error());
      await player.play(file == null ? UrlSource(ayahAudioUrl(passage.surah, number)) : DeviceFileSource(file.path));
      if (request != _generation) return;
      preparing = false;
      notifyListeners();
    } catch (_) {
      error();
    }
  }

  void retry() {
    if (failed case final number?) unawaited(play(number, all: _all));
  }

  @override
  void dispose() {
    _generation++;
    unawaited(_release());
    super.dispose();
  }
}

String _size(int bytes) =>
    bytes >= 1000000 ? '${(bytes / 1000000).toStringAsFixed(1)} MB' : '${(bytes / 1000).ceil()} KB';

enum _DownloadState { idle, checking, ready, saving, saved, error }

class OfflineRecitation extends StatefulWidget {
  final QuranRef passage;
  final RecitationCache cache;
  const OfflineRecitation({super.key, required this.passage, required this.cache});

  @override
  State<OfflineRecitation> createState() => _OfflineRecitationState();
}

class _OfflineRecitationState extends State<OfflineRecitation> {
  _DownloadState _state = _DownloadState.idle;
  RecitationDownload? _request;
  int? _sizeBytes;
  int _received = 0;
  int? _ayah;
  bool _retrySave = false;

  @override
  void initState() {
    super.initState();
    _checkLocal();
  }

  Future<void> _checkLocal() async {
    try {
      final saved = await widget.cache.hasPassage(widget.passage);
      if (mounted && saved && _state == _DownloadState.idle) setState(() => _state = _DownloadState.saved);
    } catch (_) {
      // Storage errors are actionable if the user requests a download.
    }
  }

  Future<void> _run(bool save) async {
    _request?.close();
    final request = _request = widget.cache.begin();
    setState(() {
      _state = save ? _DownloadState.saving : _DownloadState.checking;
      _received = 0;
      _ayah = null;
      _retrySave = save;
    });
    try {
      if (save) {
        await request.save(widget.passage, (ayah, bytes) {
          if (_request == request && mounted) {
            setState(() {
              _ayah = ayah;
              _received = bytes;
            });
          }
        });
      } else {
        final bytes = await request.remainingBytes(widget.passage);
        if (_request != request || !mounted) return;
        _sizeBytes = bytes;
      }
      if (_request != request || !mounted) return;
      setState(() => _state = save || _sizeBytes == 0 ? _DownloadState.saved : _DownloadState.ready);
    } catch (_) {
      if (_request == request && mounted) setState(() => _state = _DownloadState.error);
    } finally {
      request.close();
      if (_request == request) _request = null;
    }
  }

  void _stop() {
    _request?.close();
    _request = null;
    setState(() => _state = _DownloadState.idle);
  }

  @override
  void dispose() {
    _request?.close();
    _request = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = switch (_state) {
      _DownloadState.idle => null,
      _DownloadState.checking => 'Checking download size…',
      _DownloadState.saving => 'Downloading${_ayah == null ? '' : ' ayah $_ayah'} · ${_size(_received)}',
      _DownloadState.error => 'Audio download unavailable. Check your connection and storage.',
      _DownloadState.ready => _sizeBytes == null ? 'Download size unavailable' : '${_size(_sizeBytes!)} to download',
      _DownloadState.saved => 'Audio available offline',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (status != null) Semantics(liveRegion: _state != _DownloadState.saving, child: Text(status)),
        Wrap(
          children: [
            if (_state == _DownloadState.idle)
              TextButton.icon(
                icon: const Icon(Icons.download_outlined),
                label: const Text('Get offline audio'),
                onPressed: () => _run(false),
              ),
            if (_state == _DownloadState.ready)
              TextButton(onPressed: () => _run(true), child: const Text('Download audio')),
            if (_state == _DownloadState.checking || _state == _DownloadState.saving || _state == _DownloadState.ready)
              TextButton(onPressed: _stop, child: Text(_state == _DownloadState.ready ? 'Cancel' : 'Stop download')),
            if (_state == _DownloadState.error)
              TextButton(onPressed: () => _run(_retrySave), child: const Text('Retry download')),
          ],
        ),
      ],
    );
  }
}
