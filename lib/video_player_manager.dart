import 'dart:async';
import 'dart:developer';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:myapp/models/video_history.dart';
import 'package:myapp/services/history_service.dart';
import 'package:video_player/video_player.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

// Mantiene el nombre para no romper imports, pero ahora gestiona audio estilo app musical.
class VideoPlayerManager extends ChangeNotifier with WidgetsBindingObserver {
  final HistoryService _historyService = HistoryService();
  final AudioHandler _audioHandler;
  final AudioPlayer _player = AudioPlayer();
  final YoutubeExplode _ytExplode = YoutubeExplode();
  VideoPlayerController? _hiddenVideoController;

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _bufferedSub;
  StreamSubscription<Duration?>? _durationSub;
  StreamSubscription<PlayerState>? _playerStateSub;

  String? _currentVideoId;
  bool _isMinimized = false;
  bool _isFullScreen = false;

  String? _trackTitle;
  String? _trackThumbnailUrl;
  String? _trackArtist;
  Duration _trackDuration = Duration.zero;
  bool _isLocal = false;
  bool _isLoading = false;
  String? _errorMessage;

  Duration _position = Duration.zero;
  Duration _bufferedPosition = Duration.zero;
  bool _isPlaying = false;
  bool _isBuffering = false;
  bool _usingHiddenVideo = false;
  String? _currentStreamUrl;
  final Map<String, StreamManifest> _manifestCache = {};
  final Map<String, Video> _videoCache = {};
  final Map<String, Future<StreamManifest>> _manifestRequests = {};
  final Map<String, Future<Video>> _videoRequests = {};
  static const Map<String, String> _youtubeHeaders = {
    'User-Agent':
        'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
    'Accept': '*/*',
    'Origin': 'https://www.youtube.com',
    'Referer': 'https://www.youtube.com/',
  };

  VideoPlayerManager(this._audioHandler) {
    WidgetsBinding.instance.addObserver(this);
    _positionSub = _player.positionStream.listen((position) {
      _position = position;
      notifyListeners();
    });

    _bufferedSub = _player.bufferedPositionStream.listen((buffered) {
      _bufferedPosition = buffered;
      notifyListeners();
    });

    _durationSub = _player.durationStream.listen((duration) {
      if (duration != null) {
        _trackDuration = duration;
        notifyListeners();
      }
    });

    _playerStateSub = _player.playerStateStream.listen((state) {
      _isPlaying = state.playing;
      _isBuffering = state.processingState == ProcessingState.buffering ||
          state.processingState == ProcessingState.loading;
      if (state.processingState == ProcessingState.completed) {
        _isPlaying = false;
      }
      notifyListeners();
    });
  }

  String? get currentVideoId => _currentVideoId;
  bool get isMinimized => _isMinimized;
  bool get isFullScreen => _isFullScreen;
  String? get trackTitle => _trackTitle;
  String? get trackThumbnailUrl => _trackThumbnailUrl;
  String? get trackArtist => _trackArtist;
  Duration get trackDuration => _trackDuration;
  Duration get position => _position;
  Duration get bufferedPosition => _bufferedPosition;
  bool get isPlaying => _isPlaying;
  bool get isBuffering => _isBuffering;
  bool get isLoading => _isLoading;
  bool get isLocal => _isLocal;
  bool get isUsingVideoFallback => _usingHiddenVideo;
  String? get currentStreamUrl => _currentStreamUrl;
  String? get errorMessage => _errorMessage;
  bool get isInBackground => false;

  void init() {}

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if ((state == AppLifecycleState.paused || state == AppLifecycleState.inactive) &&
        _usingHiddenVideo) {
      unawaited(_switchHiddenVideoToAudioEngine());
    }
  }

  // Compatibilidad con pantallas legadas de video.
  void setPlayerData({
    required String videoId,
    required Object controller,
    String? streamUrl,
    required String title,
    required String thumbnailUrl,
    required String channelTitle,
    Duration? duration,
    bool isLocal = false,
  }) {}

  Future<void> play(String videoId, {bool isLocalVideo = false}) async {
    await _resetEngines();
    _isLoading = true;
    _errorMessage = null;
    _currentVideoId = videoId;
    _isLocal = isLocalVideo;
    _isMinimized = false;
    _isFullScreen = false;
    _position = Duration.zero;
    _bufferedPosition = Duration.zero;
    notifyListeners();

    try {
      final manifest = await _getManifestWithRetry(videoId);
      final video = await _getVideoWithRetry(videoId);

      final audioStreams = manifest.audioOnly.toList();
      if (audioStreams.isEmpty) {
        throw Exception('No se encontraron streams de audio');
      }

      final orderedStreams = _prioritizeAudioStreams(audioStreams);
      _trackTitle = video.title;
      _trackThumbnailUrl = video.thumbnails.highResUrl;
      _trackArtist = video.author;
      _trackDuration = video.duration ?? Duration.zero;

      Object? lastAudioError;
      var started = false;
      for (final stream in orderedStreams) {
        try {
          await _player.setAudioSource(
            AudioSource.uri(stream.url, headers: _youtubeHeaders),
          );
          await _player.play();
          started = true;
          _usingHiddenVideo = false;
          _currentStreamUrl = stream.url.toString();
          break;
        } catch (e) {
          lastAudioError = e;
        }
      }

      if (!started) {
        final muxedStreams = _prioritizeMuxedStreams(manifest.muxed.toList());
        Object? lastMuxedError;
        for (final stream in muxedStreams) {
          try {
            final controller = VideoPlayerController.networkUrl(
              stream.url,
              httpHeaders: _youtubeHeaders,
            );
            await controller.initialize();
            await controller.play();
            _hiddenVideoController = controller;
            _usingHiddenVideo = true;
            _currentStreamUrl = stream.url.toString();
            _isPlaying = true;
            _isBuffering = false;
            _trackDuration = controller.value.duration;
            controller.addListener(_syncFromHiddenVideo);
            started = true;
            break;
          } catch (e) {
            lastMuxedError = e;
          }
        }
        if (!started) {
          throw Exception(
            'No se pudo iniciar audio ni fallback de video: audio=$lastAudioError muxed=$lastMuxedError',
          );
        }
      }

      await _historyService.addVideoToHistory(
        VideoHistory(
          videoId: videoId,
          title: _trackTitle ?? 'Sin título',
          thumbnailUrl: _trackThumbnailUrl ?? '',
          channelTitle: _trackArtist ?? '',
          watchedAt: DateTime.now(),
        ),
      );
    } catch (e, s) {
      log('Error reproduciendo audio', error: e, stackTrace: s);
      _errorMessage = 'No se pudo reproducir esta canción.';
      _isPlaying = false;
      _isBuffering = false;
      await _player.stop();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<StreamManifest> _getManifestWithRetry(String videoId) async {
    final cached = _manifestCache[videoId];
    if (cached != null) return cached;
    final inFlight = _manifestRequests[videoId];
    if (inFlight != null) return inFlight;

    final future = _runYoutubeWithRetry(
      () => _ytExplode.videos.streamsClient.getManifest(videoId),
    );
    _manifestRequests[videoId] = future;
    try {
      final manifest = await future;
      _manifestCache[videoId] = manifest;
      return manifest;
    } finally {
      _manifestRequests.remove(videoId);
    }
  }

  Future<Video> _getVideoWithRetry(String videoId) async {
    final cached = _videoCache[videoId];
    if (cached != null) return cached;
    final inFlight = _videoRequests[videoId];
    if (inFlight != null) return inFlight;

    final future = _runYoutubeWithRetry(
      () => _ytExplode.videos.get(VideoId(videoId)),
    );
    _videoRequests[videoId] = future;
    try {
      final video = await future;
      _videoCache[videoId] = video;
      return video;
    } finally {
      _videoRequests.remove(videoId);
    }
  }

  Future<T> _runYoutubeWithRetry<T>(
    Future<T> Function() action, {
    int maxAttempts = 3,
  }) async {
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await action();
      } on RequestLimitExceededException {
        rethrow;
      } on SocketException catch (e) {
        lastError = e;
      } on HttpException catch (e) {
        lastError = e;
      } catch (e) {
        lastError = e;
      }

      if (attempt < maxAttempts) {
        final waitSeconds = attempt * 2;
        await Future<void>.delayed(Duration(seconds: waitSeconds));
      }
    }
    throw lastError ?? Exception('Error desconocido al contactar YouTube');
  }

  Future<void> playLocalFile({
    required String id,
    required String filePath,
    required String title,
    required String thumbnailUrl,
    required String artist,
  }) async {
    await _resetEngines();
    _isLoading = true;
    _errorMessage = null;
    _currentVideoId = id;
    _isLocal = true;
    _isMinimized = false;
    _isFullScreen = false;
    _trackTitle = title;
    _trackThumbnailUrl = thumbnailUrl;
    _trackArtist = artist;
    _currentStreamUrl = filePath;
    _position = Duration.zero;
    _bufferedPosition = Duration.zero;
    notifyListeners();

    final localFile = File(filePath);
    if (!await localFile.exists()) {
      _errorMessage = 'El archivo local no existe.';
      _isLoading = false;
      notifyListeners();
      return;
    }

    try {
      await _player.setAudioSource(AudioSource.file(filePath));
      // No esperamos a que termine la reproducción para no bloquear la UI.
      unawaited(_player.play());
      _usingHiddenVideo = false;
    } catch (e, s) {
      log('Error reproduciendo archivo local', error: e, stackTrace: s);
      _errorMessage = 'No se pudo reproducir el archivo descargado.';
      _isPlaying = false;
      _isBuffering = false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  List<AudioOnlyStreamInfo> _prioritizeAudioStreams(List<AudioOnlyStreamInfo> streams) {
    final sortedByBitrate = [...streams]
      ..sort((a, b) => b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond));

    if (!Platform.isIOS) {
      return sortedByBitrate;
    }

    final preferred = <AudioOnlyStreamInfo>[];
    final fallback = <AudioOnlyStreamInfo>[];

    for (final stream in sortedByBitrate) {
      final container = stream.container.name.toLowerCase();
      if (container == 'mp4' || container == 'm4a') {
        preferred.add(stream);
      } else {
        fallback.add(stream);
      }
    }

    return [...preferred, ...fallback];
  }

  Future<void> togglePlayPause() async {
    if (_usingHiddenVideo && _hiddenVideoController != null) {
      if (_hiddenVideoController!.value.isPlaying) {
        await _hiddenVideoController!.pause();
      } else {
        await _hiddenVideoController!.play();
      }
      return;
    }
    if (_isPlaying) {
      await _player.pause();
    } else {
      await _player.play();
    }
  }

  Future<void> seekTo(Duration newPosition) async {
    final max = _trackDuration;
    final clamped = newPosition < Duration.zero
        ? Duration.zero
        : (newPosition > max ? max : newPosition);
    if (_usingHiddenVideo && _hiddenVideoController != null) {
      await _hiddenVideoController!.seekTo(clamped);
      return;
    }
    await _player.seek(clamped);
  }

  void minimize() {
    if (!_isMinimized) {
      _isMinimized = true;
      notifyListeners();
    }
  }

  void maximize() {
    if (_isMinimized) {
      _isMinimized = false;
      notifyListeners();
    }
  }

  Future<void> close() async {
    await _resetEngines();

    _currentVideoId = null;
    _isMinimized = false;
    _isFullScreen = false;
    _trackTitle = null;
    _trackThumbnailUrl = null;
    _trackArtist = null;
    _trackDuration = Duration.zero;
    _position = Duration.zero;
    _bufferedPosition = Duration.zero;
    _isPlaying = false;
    _isBuffering = false;
    _isLoading = false;
    _usingHiddenVideo = false;
    _isLocal = false;
    _errorMessage = null;
    _currentStreamUrl = null;

    notifyListeners();
  }

  void setFullScreen(bool isFullScreen) {
    if (_isFullScreen != isFullScreen) {
      _isFullScreen = isFullScreen;
      notifyListeners();
    }
  }

  Future<void> switchToBackgroundAudio() async {}

  Future<void> switchToForegroundVideo() async {}

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _positionSub?.cancel();
    _bufferedSub?.cancel();
    _durationSub?.cancel();
    _playerStateSub?.cancel();
    _hiddenVideoController?.removeListener(_syncFromHiddenVideo);
    _hiddenVideoController?.dispose();
    _player.dispose();
    _ytExplode.close();
    _audioHandler.stop();
    super.dispose();
  }

  List<MuxedStreamInfo> _prioritizeMuxedStreams(List<MuxedStreamInfo> streams) {
    final sortedByQuality = [...streams]
      ..sort((a, b) => b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond));

    if (!Platform.isIOS) {
      return sortedByQuality;
    }

    final preferred = <MuxedStreamInfo>[];
    final fallback = <MuxedStreamInfo>[];
    for (final stream in sortedByQuality) {
      final container = stream.container.name.toLowerCase();
      if (container == 'mp4') {
        preferred.add(stream);
      } else {
        fallback.add(stream);
      }
    }
    return [...preferred, ...fallback];
  }

  Future<void> _resetEngines() async {
    await _player.stop();
    if (_hiddenVideoController != null) {
      _hiddenVideoController!.removeListener(_syncFromHiddenVideo);
      await _hiddenVideoController!.pause();
      await _hiddenVideoController!.dispose();
      _hiddenVideoController = null;
    }
    _usingHiddenVideo = false;
  }

  void _syncFromHiddenVideo() {
    final controller = _hiddenVideoController;
    if (controller == null) return;
    final value = controller.value;
    _position = value.position;
    _bufferedPosition = value.position;
    _trackDuration = value.duration;
    _isPlaying = value.isPlaying;
    _isBuffering = value.isBuffering;
    notifyListeners();
  }

  Future<void> _switchHiddenVideoToAudioEngine() async {
    if (!_usingHiddenVideo || _hiddenVideoController == null) return;
    final streamUrl = _currentStreamUrl;
    if (streamUrl == null || streamUrl.isEmpty) return;

    try {
      final position = _hiddenVideoController!.value.position;
      await _player.setAudioSource(
        AudioSource.uri(Uri.parse(streamUrl), headers: _youtubeHeaders),
      );
      await _player.seek(position);
      await _player.play();

      _hiddenVideoController!.removeListener(_syncFromHiddenVideo);
      await _hiddenVideoController!.pause();
      await _hiddenVideoController!.dispose();
      _hiddenVideoController = null;
      _usingHiddenVideo = false;
      _isPlaying = true;
      _isBuffering = false;
      notifyListeners();
    } catch (e, s) {
      log(
        'No se pudo migrar de video oculto a audio en background',
        error: e,
        stackTrace: s,
      );
    }
  }
}
