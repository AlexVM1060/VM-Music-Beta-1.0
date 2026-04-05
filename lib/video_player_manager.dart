import 'dart:async';
import 'dart:developer';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:just_audio/just_audio.dart';
import 'package:myapp/models/downloaded_video.dart';
import 'package:myapp/models/video_history.dart';
import 'package:myapp/services/history_service.dart';
import 'package:myapp/services/lyrics_service.dart';
import 'package:video_player/video_player.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class PlaybackQueueItem {
  final String videoId;
  final String title;
  final String thumbnailUrl;
  final String artist;
  final bool isLocal;
  final String? localFilePath;
  final String? localPlainLyrics;
  final String? localSyncedLyrics;

  const PlaybackQueueItem({
    required this.videoId,
    required this.title,
    required this.thumbnailUrl,
    required this.artist,
    required this.isLocal,
    this.localFilePath,
    this.localPlainLyrics,
    this.localSyncedLyrics,
  });
}

// Mantiene el nombre para no romper imports, pero ahora gestiona audio estilo app musical.
class VideoPlayerManager extends ChangeNotifier with WidgetsBindingObserver {
  final HistoryService _historyService = HistoryService();
  final AudioHandler _audioHandler;
  final AudioPlayer _player = AudioPlayer();
  final YoutubeExplode _ytExplode = YoutubeExplode();
  final LyricsService _lyricsService = LyricsService();
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
  bool _autoplayEnabled = true;
  bool _isLyricsLayout = false;
  bool _isLyricsLoading = false;
  String? _lyricsText;
  String? _lyricsError;
  List<SyncedLyricLine> _syncedLyrics = const [];
  bool _isAdvancingQueue = false;
  bool _completionHandledForCurrent = false;
  bool _skipHistoryPushOnce = false;
  bool _isResettingEngines = false;
  bool _isSwitchingEngine = false;
  String? _currentStreamUrl;
  List<PlaybackQueueItem> _playbackQueue = const [];
  bool _isQueueLoading = false;
  String _queueTitle = 'Siguiente';
  int _queueEpoch = 0;
  final List<PlaybackQueueItem> _playbackHistory = [];
  final Map<String, StreamManifest> _manifestCache = {};
  final Map<String, Video> _videoCache = {};
  final Map<String, Future<StreamManifest>> _manifestRequests = {};
  final Map<String, Future<Video>> _videoRequests = {};
  final Map<String, List<PlaybackQueueItem>> _relatedQueueCache = {};
  final Map<String, Future<List<PlaybackQueueItem>>> _relatedQueueRequests = {};
  final Map<String, String> _lyricsCache = {};
  final Map<String, List<SyncedLyricLine>> _syncedLyricsCache = {};
  int _lyricsEpoch = 0;
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
        _onTrackCompleted();
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
  bool get autoplayEnabled => _autoplayEnabled;
  bool get isLyricsLayout => _isLyricsLayout;
  bool get isLyricsLoading => _isLyricsLoading;
  String? get lyricsText => _lyricsText;
  String? get lyricsError => _lyricsError;
  List<SyncedLyricLine> get syncedLyrics => _syncedLyrics;
  bool get hasSyncedLyrics => _syncedLyrics.isNotEmpty;
  int get currentSyncedLyricIndex {
    if (_syncedLyrics.isEmpty) return -1;
    final current = _position;
    var idx = -1;
    for (var i = 0; i < _syncedLyrics.length; i++) {
      if (current >= _syncedLyrics[i].timestamp) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }
  String? get currentStreamUrl => _currentStreamUrl;
  String? get errorMessage => _errorMessage;
  List<PlaybackQueueItem> get playbackQueue => _playbackQueue;
  bool get isQueueLoading => _isQueueLoading;
  String get queueTitle => _queueTitle;
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
    _rememberCurrentForHistory();
    await _resetEngines();
    _isLoading = true;
    _errorMessage = null;
    _currentVideoId = videoId;
    _isLocal = isLocalVideo;
    _isMinimized = false;
    _isFullScreen = false;
    _position = Duration.zero;
    _bufferedPosition = Duration.zero;
    _completionHandledForCurrent = false;
    _resetLyricsState();
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
      final hasLocalLyrics = (_lyricsText?.isNotEmpty ?? false) || _syncedLyrics.isNotEmpty;
      if (_isLyricsLayout && !hasLocalLyrics) {
        unawaited(_loadLyricsForCurrentTrack());
      }

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
            unawaited(_switchHiddenVideoToAudioEngine());
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

      if (_autoplayEnabled) {
        unawaited(_loadOnlineQueue(video, currentVideoId: videoId));
      } else {
        _clearQueueForAutoplayDisabled();
      }

      try {
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
        log('No se pudo guardar historial', error: e, stackTrace: s);
      }
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

  Future<List<PlaybackQueueItem>> _getRelatedQueueWithRetry(Video video) async {
    final key = video.id.value;
    final cached = _relatedQueueCache[key];
    if (cached != null) return cached;

    final inFlight = _relatedQueueRequests[key];
    if (inFlight != null) return inFlight;

    final future = _runYoutubeWithRetry(() async {
      final related = await _ytExplode.videos.getRelatedVideos(video);
      var queue = <PlaybackQueueItem>[];

      if (related != null) {
        queue = related
            .where((item) => item.id.value != key)
            .take(30)
            .map(
              (item) => PlaybackQueueItem(
                videoId: item.id.value,
                title: item.title,
                thumbnailUrl: item.thumbnails.mediumResUrl,
                artist: item.author,
                isLocal: false,
              ),
            )
            .toList();
      }

      if (queue.isNotEmpty) return _uniqueQueue(queue);

      // Fallback: búsqueda por artista + título cuando YouTube no entrega related.
      final combinedQuery = '${video.author} ${video.title}';
      final combinedSearch = await _ytExplode.search.search(combinedQuery);
      queue = combinedSearch
          .where((item) => item.id.value != key)
          .take(30)
          .map(
            (item) => PlaybackQueueItem(
              videoId: item.id.value,
              title: item.title,
              thumbnailUrl: item.thumbnails.mediumResUrl,
              artist: item.author,
              isLocal: false,
            ),
          )
          .toList();

      if (queue.isNotEmpty) return _uniqueQueue(queue);

      // Segundo fallback: solo título.
      final titleSearch = await _ytExplode.search.search(video.title);
      return _uniqueQueue(
        titleSearch
            .where((item) => item.id.value != key)
            .take(30)
            .map(
              (item) => PlaybackQueueItem(
                videoId: item.id.value,
                title: item.title,
                thumbnailUrl: item.thumbnails.mediumResUrl,
                artist: item.author,
                isLocal: false,
              ),
            )
            .toList(),
      );
    });

    _relatedQueueRequests[key] = future;
    try {
      final list = await future;
      if (list.isNotEmpty) {
        _relatedQueueCache[key] = list;
      }
      return list;
    } finally {
      _relatedQueueRequests.remove(key);
    }
  }

  List<PlaybackQueueItem> _uniqueQueue(List<PlaybackQueueItem> items) {
    final seen = <String>{};
    final output = <PlaybackQueueItem>[];
    for (final item in items) {
      if (seen.add(item.videoId)) {
        output.add(item);
      }
    }
    return output;
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
    String? localPlainLyrics,
    String? localSyncedLyrics,
  }) async {
    _rememberCurrentForHistory();
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
    _completionHandledForCurrent = false;
    _resetLyricsState();
    _applyLocalLyrics(
      plainLyrics: localPlainLyrics,
      syncedLyrics: localSyncedLyrics,
    );
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
      if (_autoplayEnabled) {
        unawaited(_loadLocalQueue(currentVideoId: id));
      } else {
        _clearQueueForAutoplayDisabled();
      }
      if (_isLyricsLayout) {
        unawaited(_loadLyricsForCurrentTrack());
      }
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

  Future<void> playQueueItem(PlaybackQueueItem item) async {
    if (item.isLocal) {
      final path = item.localFilePath;
      if (path == null || path.isEmpty) return;
      await playLocalFile(
        id: item.videoId,
        filePath: path,
        title: item.title,
        thumbnailUrl: item.thumbnailUrl,
        artist: item.artist,
        localPlainLyrics: item.localPlainLyrics,
        localSyncedLyrics: item.localSyncedLyrics,
      );
      return;
    }
    await play(item.videoId);
  }

  Future<void> playNextInQueue() async {
    await _playNextFromQueue();
  }

  Future<void> playPreviousInQueue() async {
    if (_playbackHistory.isEmpty) {
      await seekTo(Duration.zero);
      return;
    }
    final previous = _playbackHistory.removeLast();
    _skipHistoryPushOnce = true;
    await playQueueItem(previous);
  }

  void toggleAutoplay() {
    _autoplayEnabled = !_autoplayEnabled;
    if (!_autoplayEnabled) {
      _clearQueueForAutoplayDisabled();
    } else {
      unawaited(_reloadQueueForCurrentTrack());
    }
    notifyListeners();
  }

  void toggleLyricsLayout() {
    _isLyricsLayout = !_isLyricsLayout;
    if (_isLyricsLayout) {
      unawaited(_loadLyricsForCurrentTrack());
    }
    notifyListeners();
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
    if (_isResettingEngines) return;
    final max = _trackDuration;
    final clamped = newPosition < Duration.zero
        ? Duration.zero
        : (newPosition > max ? max : newPosition);
    final hidden = _hiddenVideoController;
    if (_usingHiddenVideo && hidden != null) {
      try {
        await hidden.seekTo(clamped);
      } catch (e, s) {
        log('seekTo en hidden video falló', error: e, stackTrace: s);
      }
      return;
    }
    try {
      await _player.seek(clamped);
    } catch (e, s) {
      log('seekTo en audio falló', error: e, stackTrace: s);
    }
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
    _isLyricsLayout = false;
    _resetLyricsState();
    _errorMessage = null;
    _currentStreamUrl = null;
    _playbackQueue = const [];
    _playbackHistory.clear();
    _isQueueLoading = false;
    _queueTitle = 'Siguiente';
    _completionHandledForCurrent = false;

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
    _isResettingEngines = true;
    await _player.stop();
    final controller = _hiddenVideoController;
    _hiddenVideoController = null;
    _usingHiddenVideo = false;
    if (controller != null) {
      controller.removeListener(_syncFromHiddenVideo);
      try {
        await controller.pause();
      } catch (_) {}
      try {
        await controller.dispose();
      } catch (_) {}
    }
    _isResettingEngines = false;
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
    final remaining = value.duration - value.position;
    if (!value.isPlaying &&
        value.duration > Duration.zero &&
        remaining <= const Duration(milliseconds: 350)) {
      _onTrackCompleted();
    }
    notifyListeners();
  }

  Future<void> _switchHiddenVideoToAudioEngine() async {
    if (_isSwitchingEngine || _isResettingEngines) return;
    if (!_usingHiddenVideo || _hiddenVideoController == null) return;
    final streamUrl = _currentStreamUrl;
    if (streamUrl == null || streamUrl.isEmpty) return;

    _isSwitchingEngine = true;
    try {
      final hidden = _hiddenVideoController;
      if (hidden == null) return;
      final position = hidden.value.position;
      hidden.removeListener(_syncFromHiddenVideo);
      try {
        await hidden.pause();
      } catch (_) {}

      // Desacoplamos el motor de video antes de iniciar audio para evitar audio doble.
      _hiddenVideoController = null;
      _usingHiddenVideo = false;

      try {
        await _player.setAudioSource(
          AudioSource.uri(Uri.parse(streamUrl), headers: _youtubeHeaders),
        );
        await _player.seek(position);
        await _player.play();
        _isPlaying = true;
        _isBuffering = false;
      } catch (e, s) {
        // Si falla el motor de audio, recuperamos fallback de video.
        log('Falló migración a audio, restaurando fallback', error: e, stackTrace: s);
        _hiddenVideoController = hidden;
        _usingHiddenVideo = true;
        hidden.addListener(_syncFromHiddenVideo);
        try {
          await hidden.play();
        } catch (_) {}
      } finally {
        if (_hiddenVideoController == null) {
          try {
            await hidden.dispose();
          } catch (_) {}
        }
      }
      notifyListeners();
    } catch (e, s) {
      log(
        'No se pudo migrar de video oculto a audio en background',
        error: e,
        stackTrace: s,
      );
    } finally {
      _isSwitchingEngine = false;
    }
  }

  Future<void> _loadOnlineQueue(
    Video currentVideo, {
    required String currentVideoId,
  }) async {
    if (!_autoplayEnabled) {
      _clearQueueForAutoplayDisabled();
      return;
    }
    final queueRequestId = ++_queueEpoch;
    _queueTitle = 'Recomendados';
    _isQueueLoading = true;
    notifyListeners();

    try {
      final related = await _getRelatedQueueWithRetry(currentVideo);
      if (queueRequestId != _queueEpoch || _currentVideoId != currentVideoId) return;
      _playbackQueue = related;
    } catch (e, s) {
      log('Error cargando recomendados', error: e, stackTrace: s);
      if (queueRequestId != _queueEpoch || _currentVideoId != currentVideoId) return;
      _playbackQueue = const [];
    } finally {
      if (queueRequestId == _queueEpoch && _currentVideoId == currentVideoId) {
        _isQueueLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> _loadLocalQueue({required String currentVideoId}) async {
    if (!_autoplayEnabled) {
      _clearQueueForAutoplayDisabled();
      return;
    }
    final queueRequestId = ++_queueEpoch;
    _queueTitle = 'Descargas';
    _isQueueLoading = true;
    notifyListeners();

    try {
      final box = await Hive.openBox<DownloadedVideo>('downloads');
      final queue = <PlaybackQueueItem>[];
      for (final item in box.values) {
        if (item.videoId == currentVideoId) continue;
        final file = File(item.filePath);
        if (!await file.exists()) continue;
        queue.add(
          PlaybackQueueItem(
            videoId: item.videoId,
            title: item.title,
            thumbnailUrl: item.thumbnailUrl,
            artist: item.channelTitle,
            isLocal: true,
            localFilePath: item.filePath,
            localPlainLyrics: item.plainLyrics,
            localSyncedLyrics: item.syncedLyrics,
          ),
        );
      }
      if (queueRequestId != _queueEpoch || _currentVideoId != currentVideoId) return;
      _playbackQueue = queue;
    } catch (e, s) {
      log('Error cargando cola local', error: e, stackTrace: s);
      if (queueRequestId != _queueEpoch || _currentVideoId != currentVideoId) return;
      _playbackQueue = const [];
    } finally {
      if (queueRequestId == _queueEpoch && _currentVideoId == currentVideoId) {
        _isQueueLoading = false;
        notifyListeners();
      }
    }
  }

  void _onTrackCompleted() {
    if (_completionHandledForCurrent) return;
    _completionHandledForCurrent = true;
    if (_autoplayEnabled) {
      unawaited(_playNextFromQueue());
    }
  }

  Future<void> _playNextFromQueue() async {
    if (_isAdvancingQueue) return;
    if (_playbackQueue.isEmpty) return;
    _isAdvancingQueue = true;
    try {
      final next = _playbackQueue.first;
      await playQueueItem(next);
    } catch (e, s) {
      log('Error reproduciendo siguiente de la cola', error: e, stackTrace: s);
    } finally {
      _isAdvancingQueue = false;
    }
  }

  void _rememberCurrentForHistory() {
    if (_skipHistoryPushOnce) {
      _skipHistoryPushOnce = false;
      return;
    }

    final currentId = _currentVideoId;
    final currentTitle = _trackTitle;
    final currentThumb = _trackThumbnailUrl;
    final currentArtist = _trackArtist;
    if (currentId == null ||
        currentTitle == null ||
        currentTitle.isEmpty ||
        currentThumb == null ||
        currentArtist == null) {
      return;
    }

    final item = PlaybackQueueItem(
      videoId: currentId,
      title: currentTitle,
      thumbnailUrl: currentThumb,
      artist: currentArtist,
      isLocal: _isLocal,
      localFilePath: _isLocal ? _currentStreamUrl : null,
    );

    if (_playbackHistory.isNotEmpty &&
        _playbackHistory.last.videoId == item.videoId &&
        _playbackHistory.last.isLocal == item.isLocal) {
      return;
    }
    _playbackHistory.add(item);
    if (_playbackHistory.length > 50) {
      _playbackHistory.removeAt(0);
    }
  }

  void _clearQueueForAutoplayDisabled() {
    ++_queueEpoch;
    _playbackQueue = const [];
    _isQueueLoading = false;
    _queueTitle = 'Siguiente';
  }

  Future<void> _reloadQueueForCurrentTrack() async {
    final currentId = _currentVideoId;
    if (currentId == null || !_autoplayEnabled) return;

    if (_isLocal) {
      await _loadLocalQueue(currentVideoId: currentId);
      return;
    }

    try {
      final video = await _getVideoWithRetry(currentId);
      if (_currentVideoId != currentId || !_autoplayEnabled) return;
      await _loadOnlineQueue(video, currentVideoId: currentId);
    } catch (e, s) {
      log('Error recargando cola para autoplay', error: e, stackTrace: s);
    }
  }

  void _resetLyricsState() {
    ++_lyricsEpoch;
    _isLyricsLoading = false;
    _lyricsText = null;
    _lyricsError = null;
    _syncedLyrics = const [];
  }

  Future<void> _loadLyricsForCurrentTrack() async {
    final title = _trackTitle?.trim();
    final artist = _trackArtist?.trim();
    if (title == null || title.isEmpty) {
      _lyricsText = null;
      _lyricsError = 'No se pudo identificar la canción para buscar letra.';
      _isLyricsLoading = false;
      notifyListeners();
      return;
    }

    final key = '${artist ?? ''}::$title'.toLowerCase();
    final cached = _lyricsCache[key];
    final cachedSynced = _syncedLyricsCache[key] ?? const <SyncedLyricLine>[];
    if (cached != null && cached.isNotEmpty) {
      _lyricsText = cached;
      _syncedLyrics = cachedSynced;
      _lyricsError = null;
      _isLyricsLoading = false;
      notifyListeners();
      // Si ya tenemos sincronizadas en caché, no hace falta pedir otra vez.
      if (cachedSynced.isNotEmpty) {
        return;
      }
      // Si solo hay letra plana en caché, seguimos y refrescamos en background
      // para intentar recuperar la versión sincronizada.
    }

    final hadCachedPlain = cached != null && cached.isNotEmpty;
    final requestId = ++_lyricsEpoch;
    if (!hadCachedPlain) {
      _isLyricsLoading = true;
      _lyricsError = null;
      _lyricsText = null;
      _syncedLyrics = const [];
      notifyListeners();
    }

    final result = await _lyricsService.fetchLyrics(
      title: title,
      artist: artist ?? '',
    );

    if (requestId != _lyricsEpoch) return;
    _isLyricsLoading = false;

    if (result == null || result.plainLyrics.trim().isEmpty) {
      if (hadCachedPlain) {
        // Conservamos letra previa si existía.
        _lyricsError = null;
        notifyListeners();
        return;
      }
      _lyricsText = null;
      _syncedLyrics = const [];
      _lyricsError = 'No encontramos la letra de esta canción.';
      notifyListeners();
      return;
    }

    _lyricsCache[key] = result.plainLyrics;
    _syncedLyricsCache[key] = List<SyncedLyricLine>.from(result.syncedLyrics);
    _lyricsText = result.plainLyrics;
    _syncedLyrics = result.syncedLyrics;
    _lyricsError = null;
    notifyListeners();
  }

  void _applyLocalLyrics({
    String? plainLyrics,
    String? syncedLyrics,
  }) {
    final localPlain = plainLyrics?.trim();
    final localSynced = syncedLyrics?.trim();
    if ((localPlain == null || localPlain.isEmpty) &&
        (localSynced == null || localSynced.isEmpty)) {
      return;
    }

    if (localSynced != null && localSynced.isNotEmpty) {
      final parsed = _lyricsService.parseSyncedLyrics(localSynced);
      if (parsed.isNotEmpty) {
        _syncedLyrics = parsed;
      }
      final cleaned = localPlain ?? _stripLrcTimestamps(localSynced);
      _lyricsText = cleaned;
      _lyricsError = null;
      _isLyricsLoading = false;
      return;
    }

    if (localPlain != null && localPlain.isNotEmpty) {
      _lyricsText = localPlain;
      _lyricsError = null;
      _isLyricsLoading = false;
    }
  }

  String _stripLrcTimestamps(String lrc) {
    return lrc
        .split('\n')
        .map((line) => line.replaceAll(RegExp(r'\[[0-9:.]+\]'), '').trim())
        .where((line) => line.isNotEmpty)
        .join('\n');
  }
}
