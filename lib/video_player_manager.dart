import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive/hive.dart';
import 'package:just_audio/just_audio.dart';
import 'package:myapp/audio_handler.dart';
import 'package:myapp/models/downloaded_video.dart';
import 'package:myapp/models/video_history.dart';
import 'package:myapp/services/history_service.dart';
import 'package:myapp/services/lyrics_service.dart';
import 'package:myapp/services/now_playing_artwork_service.dart';
import 'package:myapp/utils/thumbnail_quality.dart';
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

class DownloadSourceInfo {
  final String sourceUrl;
  final bool isVideoSource;

  const DownloadSourceInfo({
    required this.sourceUrl,
    required this.isVideoSource,
  });
}

class _QueueHistoryProfile {
  final List<String> topArtists;
  final List<String> topTitleTokens;

  const _QueueHistoryProfile({
    required this.topArtists,
    required this.topTitleTokens,
  });
}

// Mantiene el nombre para no romper imports, pero ahora gestiona audio estilo app musical.
class VideoPlayerManager extends ChangeNotifier with WidgetsBindingObserver {
  static const MethodChannel _iosBassBoostChannel =
      MethodChannel('com.vm.music.beta/ios_bass_boost');
  static const _QueueHistoryProfile _emptyHistoryProfile = _QueueHistoryProfile(
    topArtists: [],
    topTitleTokens: [],
  );
  final HistoryService _historyService = HistoryService();
  final AudioHandler _audioHandler;
  late final AudioPlayer _player;
  AndroidLoudnessEnhancer? _androidBassEnhancer;
  AndroidEqualizer? _androidBassEqualizer;
  bool _bassBoostConfigured = false;
  YoutubeExplode _ytExplode = YoutubeExplode();
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
  bool _bassBoostEnabled = false;
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
  bool _isTogglingPlayPause = false;
  String? _currentStreamUrl;
  List<PlaybackQueueItem> _playbackQueue = const [];
  bool _isQueueLoading = false;
  String _queueTitle = 'Siguiente';
  int _queueEpoch = 0;
  final List<PlaybackQueueItem> _playbackHistory = [];
  final Set<String> _sessionPlayedVideoIds = <String>{};
  final Map<String, StreamManifest> _manifestCache = {};
  final Map<String, Video> _videoCache = {};
  final Map<String, Future<StreamManifest>> _manifestRequests = {};
  final Map<String, Future<Video>> _videoRequests = {};
  final Map<String, List<PlaybackQueueItem>> _relatedQueueCache = {};
  final Map<String, Future<List<PlaybackQueueItem>>> _relatedQueueRequests = {};
  final Map<String, String> _lyricsCache = {};
  final Map<String, List<SyncedLyricLine>> _syncedLyricsCache = {};
  final Map<String, String> _searchThumbnailOverrides = {};
  final NowPlayingArtworkService _nowPlayingArtworkService = NowPlayingArtworkService();
  final Map<String, Uri> _systemArtworkByVideoId = {};
  final Map<String, String> _systemArtworkSourceByVideoId = {};
  final MyAudioHandler? _appAudioHandler;
  DateTime _lastSystemPlaybackSync = DateTime.fromMillisecondsSinceEpoch(0);
  int _nowPlayingArtworkEpoch = 0;
  DateTime? _lastYoutubeRequestAt;
  DateTime? _youtubeSlowModeUntil;
  int _lyricsEpoch = 0;
  static const Duration _youtubeMinRequestGap = Duration(milliseconds: 450);
  static const Duration _youtubeSlowRequestGap = Duration(milliseconds: 1650);
  static const Duration _youtubeRateLimitCooldown = Duration(seconds: 40);
  static const double _defaultPlaybackVolume = 3;
  static const String _youtubeiPlayerEndpoint =
      'https://www.youtube.com/youtubei/v1/player?key=AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8';
  static const Map<String, String> _youtubeHeaders = {
    'User-Agent':
        'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
    'Accept': '*/*',
    'Origin': 'https://www.youtube.com',
    'Referer': 'https://www.youtube.com/',
  };

  VideoPlayerManager(this._audioHandler)
      : _appAudioHandler = _audioHandler is MyAudioHandler ? _audioHandler : null {
    if (!kIsWeb && Platform.isAndroid) {
      _androidBassEnhancer = AndroidLoudnessEnhancer();
      _androidBassEqualizer = AndroidEqualizer();
      _player = AudioPlayer(
        audioPipeline: AudioPipeline(
          androidAudioEffects: [
            _androidBassEnhancer!,
            _androidBassEqualizer!,
          ],
        ),
      );
    } else {
      _player = AudioPlayer();
    }
    unawaited(_applyDefaultPlaybackVolume());
    _bindSystemMediaControls();
    WidgetsBinding.instance.addObserver(this);
    _positionSub = _player.positionStream.listen((position) {
      _position = position;
      _syncSystemPlaybackState();
      notifyListeners();
    });

    _bufferedSub = _player.bufferedPositionStream.listen((buffered) {
      _bufferedPosition = buffered;
      _syncSystemPlaybackState();
      notifyListeners();
    });

    _durationSub = _player.durationStream.listen((duration) {
      if (duration != null) {
        _trackDuration = duration;
        _syncSystemNowPlaying();
        _syncSystemPlaybackState(force: true);
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
      _syncSystemPlaybackState(force: true);
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
  bool get bassBoostEnabled => _bassBoostEnabled;
  bool get isBassBoostSupported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);
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

  void clearErrorMessage() {
    if (_errorMessage == null) return;
    _errorMessage = null;
    notifyListeners();
  }

  void _bindSystemMediaControls() {
    _appAudioHandler?.bindCallbacks(
      onPlayRequested: () async {
        if (!_isPlaying) {
          await togglePlayPause();
        }
      },
      onPauseRequested: () async {
        if (_isPlaying) {
          await togglePlayPause();
        }
      },
      onSkipNextRequested: () async {
        await playNextInQueue();
      },
      onSkipPreviousRequested: () async {
        await playPreviousInQueue();
      },
      onSeekRequested: (position) async {
        await seekTo(position);
      },
      onStopRequested: () async {
        await close();
      },
    );
  }

  Uri? _buildArtUri(String? rawThumb) {
    if (rawThumb == null || rawThumb.trim().isEmpty) return null;
    final value = rawThumb.trim();
    if (value.startsWith('/')) {
      return Uri.file(value);
    }
    return Uri.tryParse(value);
  }

  Uri? _cachedSystemArtUri({
    required String videoId,
    required String? thumbnailSource,
  }) {
    final source = thumbnailSource?.trim() ?? '';
    if (source.isEmpty) return null;
    final storedSource = _systemArtworkSourceByVideoId[videoId];
    if (storedSource == source) {
      return _systemArtworkByVideoId[videoId];
    }
    _systemArtworkByVideoId.remove(videoId);
    _systemArtworkSourceByVideoId.remove(videoId);
    return null;
  }

  Future<Uri?> _prepareSystemArtwork({
    required String videoId,
    required String? thumbnailSource,
  }) async {
    final source = thumbnailSource?.trim() ?? '';
    if (videoId.trim().isEmpty || source.isEmpty) return null;
    final cached = _cachedSystemArtUri(
      videoId: videoId,
      thumbnailSource: source,
    );
    if (cached != null) return cached;
    final processed = await _nowPlayingArtworkService.resolveNowPlayingArtUri(
      videoId: videoId,
      thumbnailSource: source,
    );
    if (processed != null) {
      _systemArtworkByVideoId[videoId] = processed;
      _systemArtworkSourceByVideoId[videoId] = source;
    }
    return processed;
  }

  Future<void> _precacheQueueArtwork(Iterable<PlaybackQueueItem> items) async {
    for (final item in items) {
      try {
        await _prepareSystemArtwork(
          videoId: item.videoId,
          thumbnailSource: item.thumbnailUrl,
        );
      } catch (_) {
        // Best effort.
      }
    }
  }

  void _syncSystemNowPlaying() {
    final handler = _appAudioHandler;
    if (handler == null) return;
    final videoId = _currentVideoId;
    final title = (_trackTitle ?? '').trim();
    final artist = (_trackArtist ?? '').trim();
    final thumb = _trackThumbnailUrl;
    if (videoId == null || videoId.isEmpty || title.isEmpty) return;
    final fallbackArtUri = _buildArtUri(thumb);
    final cachedArtUri = _cachedSystemArtUri(
      videoId: videoId,
      thumbnailSource: thumb,
    );
    final initialArtUri = cachedArtUri ?? fallbackArtUri;
    handler.syncNowPlaying(
      id: videoId,
      title: title,
      artist: artist.isEmpty ? 'Artista desconocido' : artist,
      artUri: initialArtUri,
      duration: _trackDuration > Duration.zero ? _trackDuration : null,
      extras: {
        'isLocal': _isLocal,
      },
    );

    if (thumb == null || thumb.trim().isEmpty) return;
    final requestEpoch = ++_nowPlayingArtworkEpoch;
    unawaited(() async {
      final processedUri = await _nowPlayingArtworkService.resolveNowPlayingArtUri(
        videoId: videoId,
        thumbnailSource: thumb,
      );
      if (processedUri == null) return;
      if (requestEpoch != _nowPlayingArtworkEpoch) return;
      if (_currentVideoId != videoId) return;
      if ((_trackThumbnailUrl ?? '').trim() != thumb.trim()) return;
      _systemArtworkByVideoId[videoId] = processedUri;
      _systemArtworkSourceByVideoId[videoId] = thumb.trim();
      if (initialArtUri?.toString() == processedUri.toString()) return;
      handler.syncNowPlaying(
        id: videoId,
        title: title,
        artist: artist.isEmpty ? 'Artista desconocido' : artist,
        artUri: processedUri,
        duration: _trackDuration > Duration.zero ? _trackDuration : null,
        extras: {
          'isLocal': _isLocal,
        },
      );
    }());
  }

  void _syncSystemPlaybackState({bool force = false}) {
    final handler = _appAudioHandler;
    if (handler == null) return;
    final now = DateTime.now();
    if (!force && now.difference(_lastSystemPlaybackSync) < const Duration(milliseconds: 700)) {
      return;
    }
    _lastSystemPlaybackSync = now;
    handler.syncPlaybackState(
      playing: _isPlaying,
      buffering: _isBuffering || _isLoading,
      position: _position,
      bufferedPosition: _bufferedPosition,
      speed: _isPlaying ? 1.0 : 0.0,
    );
  }

  void _clearSystemNowPlaying() {
    _nowPlayingArtworkEpoch++;
    _appAudioHandler?.clearNowPlaying();
    _appAudioHandler?.syncStopped();
  }

  void registerSearchThumbnail(String videoId, String? thumbnailUrl) {
    if (thumbnailUrl == null || thumbnailUrl.trim().isEmpty) return;
    _searchThumbnailOverrides[videoId] = thumbnailUrl.trim();
  }

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

  Future<void> play(
    String videoId, {
    bool isLocalVideo = false,
    String? preferredThumbnailUrl,
    String? preferredTitle,
    String? preferredArtist,
    Duration? preferredDuration,
    bool isRecoveryAttempt = false,
  }) async {
    _rememberCurrentForHistory();
    await _disableBassBoostOnTrackChange();
    await _resetEngines();
    await _applyDefaultPlaybackVolume();
    _isLoading = true;
    _errorMessage = null;
    _currentVideoId = videoId;
    _isLocal = isLocalVideo;
    _isMinimized = false;
    _isFullScreen = false;
    _position = Duration.zero;
    _bufferedPosition = Duration.zero;
    _completionHandledForCurrent = false;
    _trackTitle = (preferredTitle != null && preferredTitle.trim().isNotEmpty)
        ? preferredTitle.trim()
        : null;
    _trackArtist = (preferredArtist != null && preferredArtist.trim().isNotEmpty)
        ? preferredArtist.trim()
        : null;
    _trackDuration = preferredDuration ?? Duration.zero;
    final effectivePreferredThumbnail =
        (preferredThumbnailUrl != null && preferredThumbnailUrl.trim().isNotEmpty)
        ? preferredThumbnailUrl.trim()
        : _searchThumbnailOverrides[videoId];
    if (effectivePreferredThumbnail != null && effectivePreferredThumbnail.isNotEmpty) {
      _searchThumbnailOverrides[videoId] = effectivePreferredThumbnail;
    }
    _trackThumbnailUrl = null;
    if (effectivePreferredThumbnail != null && effectivePreferredThumbnail.isNotEmpty) {
      _trackThumbnailUrl = effectivePreferredThumbnail;
    }
    _resetLyricsState();
    _syncSystemNowPlaying();
    _syncSystemPlaybackState(force: true);
    notifyListeners();

    try {
      final shouldFetchVideoMetadata =
          _autoplayEnabled ||
          _trackTitle == null ||
          _trackArtist == null ||
          _trackThumbnailUrl == null ||
          _trackDuration == Duration.zero;
      final manifestFuture = _getManifestWithRetry(videoId);
      final Future<Video>? videoFuture = shouldFetchVideoMetadata
          ? _getVideoWithRetry(videoId)
          : null;
      final manifest = await manifestFuture;

      final audioStreams = manifest.audioOnly.toList();
      if (audioStreams.isEmpty) {
        throw Exception('No se encontraron streams de audio');
      }

      final orderedStreams = _prioritizeAudioStreams(audioStreams);

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

      if (!_autoplayEnabled) {
        _clearQueueForAutoplayDisabled();
      }
      unawaited(_applyBassBoostEffect());

      _sessionPlayedVideoIds.add(videoId);

      // Metadata/cola/historial en segundo plano para no bloquear inicio de reproducción.
      unawaited(() async {
        Video? video;
        try {
          if (videoFuture != null) {
            video = await videoFuture.timeout(const Duration(seconds: 6));
          }
        } catch (e, s) {
          log('No se pudo resolver metadata de video a tiempo', error: e, stackTrace: s);
        }

        if (_currentVideoId != videoId) return;

        if (video != null) {
          _trackTitle = video.title;
          _trackThumbnailUrl =
              (effectivePreferredThumbnail != null && effectivePreferredThumbnail.isNotEmpty)
                  ? effectivePreferredThumbnail
                  : bestThumbnailForVideo(video);
          _trackArtist = video.author;
          _trackDuration = video.duration ?? Duration.zero;
          _syncSystemNowPlaying();
          _syncSystemPlaybackState(force: true);
          notifyListeners();
        }

        final hasLocalLyrics = (_lyricsText?.isNotEmpty ?? false) || _syncedLyrics.isNotEmpty;
        if (_isLyricsLayout && !hasLocalLyrics) {
          await _loadLyricsForCurrentTrack();
        }

        if (_autoplayEnabled && video != null && _currentVideoId == videoId) {
          await _loadOnlineQueue(video, currentVideoId: videoId);
        }

        if (_currentVideoId == videoId) {
          await _addCurrentTrackToHistory(videoId);
        }
      }());
    } catch (e, s) {
      log('Error reproduciendo audio', error: e, stackTrace: s);
      if (e is RequestLimitExceededException && !isRecoveryAttempt && !isLocalVideo) {
        _activateYoutubeSlowMode(const Duration(minutes: 2));
        _manifestCache.remove(videoId);
        _videoCache.remove(videoId);
        _manifestRequests.remove(videoId);
        _videoRequests.remove(videoId);
        try {
          await Future<void>.delayed(const Duration(milliseconds: 1400));
          await _resetYoutubeClientForRecovery();
          await play(
            videoId,
            isLocalVideo: isLocalVideo,
            preferredThumbnailUrl: preferredThumbnailUrl,
            preferredTitle: preferredTitle,
            preferredArtist: preferredArtist,
            preferredDuration: preferredDuration,
            isRecoveryAttempt: true,
          );
          return;
        } catch (recoveryError, recoveryStack) {
          log(
            'Recuperacion por RequestLimitExceeded falló',
            error: recoveryError,
            stackTrace: recoveryStack,
          );
        }
      }
      if (!isLocalVideo &&
          (e is RequestLimitExceededException ||
              e is HandshakeException ||
              e is SocketException ||
              e is HttpException)) {
        final altSource = await _resolveDownloadSourceViaYoutubei(videoId);
        if (altSource != null) {
          final played = await _attemptPlaybackFromDownloadSource(altSource);
          if (played) {
            _errorMessage = null;
            _syncSystemNowPlaying();
            _syncSystemPlaybackState(force: true);
            return;
          }
        }
      }
      _errorMessage = _buildPlaybackErrorMessage(e);
      _isPlaying = false;
      _isBuffering = false;
      await _player.stop();
      _syncSystemPlaybackState(force: true);
    } finally {
      _isLoading = false;
      _syncSystemPlaybackState(force: true);
      notifyListeners();
    }
  }

  Future<void> _addCurrentTrackToHistory(String videoId) async {
    final title = _trackTitle;
    final thumbnail = _trackThumbnailUrl;
    final artist = _trackArtist;
    if (title == null || title.isEmpty || thumbnail == null || thumbnail.isEmpty || artist == null) {
      return;
    }
    try {
      await _historyService.addVideoToHistory(
        VideoHistory(
          videoId: videoId,
          title: title,
          thumbnailUrl: thumbnail,
          channelTitle: artist,
          watchedAt: DateTime.now(),
        ),
      );
    } catch (e, s) {
      log('No se pudo guardar historial', error: e, stackTrace: s);
    }
  }

  Future<StreamManifest> _getManifestWithRetry(String videoId) async {
    final cached = _manifestCache[videoId];
    if (cached != null) return cached;
    final inFlight = _manifestRequests[videoId];
    if (inFlight != null) return inFlight;

    final future = _runYoutubeWithRetry(
      () => _ytExplode.videos.streamsClient.getManifest(videoId),
      maxAttempts: _isYoutubeSlowModeActive ? 4 : 3,
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
      maxAttempts: _isYoutubeSlowModeActive ? 4 : 3,
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

  Future<DownloadSourceInfo?> resolveDownloadSourceSilently(String videoId) async {
    try {
      final manifest = await _getManifestWithRetry(videoId);
      final audioStreams = manifest.audioOnly.toList();
      if (audioStreams.isNotEmpty) {
        final selectedAudio = _prioritizeAudioStreams(audioStreams).first;
        return DownloadSourceInfo(
          sourceUrl: selectedAudio.url.toString(),
          isVideoSource: false,
        );
      }

      final muxedStreams = manifest.muxed.toList();
      if (muxedStreams.isNotEmpty) {
        final selectedMuxed = _prioritizeMuxedStreams(muxedStreams).first;
        return DownloadSourceInfo(
          sourceUrl: selectedMuxed.url.toString(),
          isVideoSource: true,
        );
      }

      return null;
    } on RequestLimitExceededException {
      return _resolveDownloadSourceViaYoutubei(videoId);
    } catch (_) {
      return null;
    }
  }

  Future<DownloadSourceInfo?> resolveDownloadSourceIsolated(String videoId) async {
    try {
      final manifest = await _getManifestWithRetry(videoId);
      final audioStreams = _prioritizeAudioStreams(manifest.audioOnly.toList());
      for (final stream in audioStreams.take(6)) {
        final ok = await _probeAudioStreamSilently(stream.url);
        if (ok) {
          return DownloadSourceInfo(
            sourceUrl: stream.url.toString(),
            isVideoSource: false,
          );
        }
      }

      final muxedStreams = _prioritizeMuxedStreams(manifest.muxed.toList());
      for (final stream in muxedStreams.take(4)) {
        final ok = await _probeVideoStreamSilently(stream.url);
        if (ok) {
          return DownloadSourceInfo(
            sourceUrl: stream.url.toString(),
            isVideoSource: true,
          );
        }
      }

      // Fallback final: regresar mejor esfuerzo sin probe.
      return resolveDownloadSourceSilently(videoId);
    } on RequestLimitExceededException {
      return _resolveDownloadSourceViaYoutubei(videoId);
    } catch (_) {
      return null;
    }
  }

  Future<DownloadSourceInfo?> _resolveDownloadSourceViaYoutubei(String videoId) async {
    final client = HttpClient();
    try {
      final candidates = <Map<String, Object>>[
        {
          'name': 'WEB',
          'version': '2.20240224.11.00',
          'ua':
              'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        },
        {
          'name': 'ANDROID',
          'version': '19.09.37',
          'ua': 'com.google.android.youtube/19.09.37 (Linux; U; Android 14)',
        },
        {
          'name': 'IOS',
          'version': '19.09.3',
          'ua': 'com.google.ios.youtube/19.09.3 (iPhone16,2; U; CPU iOS 17_3 like Mac OS X)',
        },
      ];

      for (final clientDef in candidates) {
        final req = await client.postUrl(Uri.parse(_youtubeiPlayerEndpoint));
        req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
        req.headers.set(HttpHeaders.acceptHeader, 'application/json');
        req.headers.set(HttpHeaders.userAgentHeader, clientDef['ua'] as String);

        final payload = <String, Object>{
          'videoId': videoId,
          'context': {
            'client': {
              'clientName': clientDef['name'] as String,
              'clientVersion': clientDef['version'] as String,
            },
          },
          'contentCheckOk': true,
          'racyCheckOk': true,
        };
        req.add(utf8.encode(jsonEncode(payload)));

        final res = await req.close();
        if (res.statusCode < 200 || res.statusCode >= 300) {
          continue;
        }
        final body = await utf8.decoder.bind(res).join();
        final raw = jsonDecode(body);
        if (raw is! Map<String, dynamic>) continue;

        final streamingData = raw['streamingData'];
        if (streamingData is! Map<String, dynamic>) continue;

        String? pickedAudio;
        String? pickedMuxed;

        final adaptive = streamingData['adaptiveFormats'];
        if (adaptive is List) {
          final audioFormats = adaptive.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).where((f) {
            final mime = (f['mimeType']?.toString() ?? '').toLowerCase();
            return mime.contains('audio/') && (f['url']?.toString().isNotEmpty ?? false);
          }).toList()
            ..sort((a, b) => (b['bitrate'] as num? ?? 0).compareTo(a['bitrate'] as num? ?? 0));
          if (audioFormats.isNotEmpty) {
            pickedAudio = audioFormats.first['url']?.toString();
          }
        }

        final formats = streamingData['formats'];
        if (formats is List) {
          final muxedFormats = formats.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).where((f) {
            final hasUrl = f['url']?.toString().isNotEmpty ?? false;
            final mime = (f['mimeType']?.toString() ?? '').toLowerCase();
            return hasUrl && (mime.contains('video/') || mime.contains('mp4'));
          }).toList()
            ..sort((a, b) => (b['bitrate'] as num? ?? 0).compareTo(a['bitrate'] as num? ?? 0));
          if (muxedFormats.isNotEmpty) {
            pickedMuxed = muxedFormats.first['url']?.toString();
          }
        }

        final hlsManifest = streamingData['hlsManifestUrl']?.toString();
        if (pickedAudio != null && pickedAudio.trim().isNotEmpty) {
          return DownloadSourceInfo(sourceUrl: pickedAudio.trim(), isVideoSource: false);
        }
        if (pickedMuxed != null && pickedMuxed.trim().isNotEmpty) {
          return DownloadSourceInfo(sourceUrl: pickedMuxed.trim(), isVideoSource: true);
        }
        if (hlsManifest != null && hlsManifest.trim().isNotEmpty) {
          return DownloadSourceInfo(sourceUrl: hlsManifest.trim(), isVideoSource: true);
        }
      }

      return null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> _attemptPlaybackFromDownloadSource(DownloadSourceInfo source) async {
    final uri = Uri.parse(source.sourceUrl);
    final headers = _headersForStreamUri(uri) ?? const <String, String>{};

    if (!source.isVideoSource) {
      try {
        await _player.setAudioSource(AudioSource.uri(uri, headers: headers));
        unawaited(_applyBassBoostEffect());
        await _player.play();
        _usingHiddenVideo = false;
        _currentStreamUrl = source.sourceUrl;
        _isPlaying = true;
        _isBuffering = false;
        _syncSystemPlaybackState(force: true);
        notifyListeners();
        return true;
      } catch (_) {}
    }

    try {
      final controller = VideoPlayerController.networkUrl(
        uri,
        httpHeaders: headers,
      );
      await controller.initialize();
      await controller.play();
      _hiddenVideoController = controller;
      _usingHiddenVideo = true;
      _currentStreamUrl = source.sourceUrl;
      _isPlaying = true;
      _isBuffering = false;
      _trackDuration = controller.value.duration;
      controller.addListener(_syncFromHiddenVideo);
      unawaited(_switchHiddenVideoToAudioEngine());
      _syncSystemPlaybackState(force: true);
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  Map<String, String>? _headersForStreamUri(Uri uri) {
    final host = uri.host.toLowerCase();
    if (host.contains('googlevideo.com') || host.contains('youtube.com') || host.contains('ytimg.com')) {
      return _youtubeHeaders;
    }
    return null;
  }

  Future<bool> _probeAudioStreamSilently(Uri url) async {
    final probe = AudioPlayer();
    try {
      await probe.setVolume(0);
      await probe.setAudioSource(
        AudioSource.uri(url, headers: _youtubeHeaders),
      );
      return true;
    } catch (_) {
      return false;
    } finally {
      await probe.dispose();
    }
  }

  Future<bool> _probeVideoStreamSilently(Uri url) async {
    VideoPlayerController? controller;
    try {
      controller = VideoPlayerController.networkUrl(
        url,
        httpHeaders: _youtubeHeaders,
      );
      await controller.initialize();
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        await controller?.dispose();
      } catch (_) {}
    }
  }

  Future<List<PlaybackQueueItem>> _getRelatedQueueWithRetry(Video video) async {
    final key = video.id.value;
    final cached = _relatedQueueCache[key];
    if (cached != null) return cached;

    final inFlight = _relatedQueueRequests[key];
    if (inFlight != null) return inFlight;

    final future = () async {
      final candidates = <Video>[];
      List<Video>? related;

      try {
        related = await _runYoutubeWithRetry(
          () => _ytExplode.videos.getRelatedVideos(video),
          maxAttempts: 2,
        );
      } catch (e, s) {
        log('Related videos falló, seguimos con búsqueda', error: e, stackTrace: s);
      }

      if (related != null && related.isNotEmpty) {
        final fastQueue = _buildSmartQueue(
          related,
          currentVideoId: key,
          primaryArtist: video.author,
          historyProfile: _emptyHistoryProfile,
          relatedArtistHints: const [],
        );
        // Fast-path: con related suficiente ya no hacemos más requests.
        if (fastQueue.length >= 18) return fastQueue;
        candidates.addAll(related.take(50));
      }

      final historyProfile = await _buildQueueHistoryProfile(primaryArtist: video.author);
      final similarArtists = _buildSimilarArtistCandidates(
        primaryArtist: video.author,
        currentTitle: video.title,
        relatedVideos: related ?? const [],
      );

      // Búsqueda base por artista + título.
      final normalizedPrimaryArtist = _normalizeArtistName(video.author);
      final batchedSearches = <Future<List<Video>>>[
        _searchTopicChannelUploads(video.author, limit: 28),
        _safeSearchVideos('${video.author} topic', limit: 14, onlyTopic: true),
      ];

      // Refuerzo por historial: artistas más escuchados.
      for (final artist in similarArtists.take(6)) {
        if (_normalizeArtistName(artist) == normalizedPrimaryArtist) continue;
        batchedSearches.add(_searchTopicChannelUploads(artist, limit: 20));
        batchedSearches.add(_safeSearchVideos('$artist topic', limit: 12, onlyTopic: true));
      }
      batchedSearches.add(_pickRandomHistoryArtistVideos(historyProfile));
      final batchResults = await Future.wait(batchedSearches);
      for (final batch in batchResults) {
        candidates.addAll(batch);
      }

      // Fallback: autogenerados de YouTube (sin videos/lyrics), usando artista actual y similares.
      if (candidates.length < 12) {
        final seenAutoArtists = <String>{};
        final autoQueries = <Future<List<Video>>>[];
        final fallbackArtists = <String>[
          video.author,
          ...similarArtists.take(8),
          ...historyProfile.topArtists.take(2),
        ];
        for (final artist in fallbackArtists) {
          final normalized = _normalizeArtistName(artist);
          if (normalized.isEmpty || !seenAutoArtists.add(normalized)) continue;
          autoQueries.add(
            _safeSearchVideos(
              '$artist provided to youtube by',
              limit: 14,
              onlyAutoGenerated: true,
            ),
          );
          autoQueries.add(
            _safeSearchVideos(
              '$artist auto-generated by youtube',
              limit: 14,
              onlyAutoGenerated: true,
            ),
          );
        }
        final autoBatches = await Future.wait(autoQueries);
        for (final batch in autoBatches) {
          candidates.addAll(batch);
        }
      }

      return _buildSmartQueue(
        candidates,
        currentVideoId: key,
        primaryArtist: video.author,
        historyProfile: historyProfile,
        relatedArtistHints: similarArtists,
      );
    }();

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

  List<PlaybackQueueItem> _buildSmartQueue(
    Iterable<Video> source, {
    required String currentVideoId,
    required String primaryArtist,
    required _QueueHistoryProfile historyProfile,
    required List<String> relatedArtistHints,
  }) {
    final normalizedPrimaryArtist = primaryArtist.toLowerCase().trim();
    final normalizedPrimary = _normalizeArtistName(primaryArtist);
    final similarArtists = relatedArtistHints
        .map(_normalizeArtistName)
        .where((value) => value.isNotEmpty)
        .toSet();
    similarArtists.remove(normalizedPrimary);
    final historyArtists = historyProfile.topArtists
        .map(_normalizeArtistName)
        .where((value) => value.isNotEmpty && value != normalizedPrimary && !similarArtists.contains(value))
        .take(2)
        .toSet();
    final allowedArtists = <String>{
      normalizedPrimary,
      ...similarArtists,
      ...historyArtists,
    }..removeWhere((value) => value.isEmpty);
    final filtered = source
        .where((item) => item.id.value != currentVideoId)
        .where((item) => !_sessionPlayedVideoIds.contains(item.id.value))
        .where(_isPureYoutubeMusicAudio)
        .where((item) {
          if (allowedArtists.isEmpty) return true;
          final author = _normalizeArtistName(item.author);
          if (author.isEmpty) return false;
          for (final artist in allowedArtists) {
            if (author.contains(artist) || artist.contains(author)) return true;
          }
          return false;
        })
        .toList();

    final tier0 = <Video>[];
    final tier1 = <Video>[];
    final tier2 = <Video>[];
    final tier3 = <Video>[];
    for (final item in filtered) {
      final tier = _artistPriorityTier(
        author: item.author,
        normalizedPrimary: normalizedPrimary,
        similarArtists: similarArtists,
        historyArtists: historyArtists,
      );
      if (tier == 0) {
        tier0.add(item);
      } else if (tier == 1) {
        tier1.add(item);
      } else if (tier == 2) {
        tier2.add(item);
      } else {
        tier3.add(item);
      }
    }

    void sortByScore(List<Video> list) {
      list.sort((a, b) {
        final scoreA = _recommendationScore(a, normalizedPrimaryArtist, historyProfile);
        final scoreB = _recommendationScore(b, normalizedPrimaryArtist, historyProfile);
        return scoreB.compareTo(scoreA);
      });
    }

    sortByScore(tier0);
    sortByScore(tier1);
    sortByScore(tier2);
    sortByScore(tier3);
    final ordered = <Video>[...tier0, ...tier1, ...tier2, ...tier3];

    final seenIds = <String>{};
    final seenNormalizedTitles = <String>{};
    final artistUsage = <String, int>{};
    var acceptedSimilar = 0;
    var acceptedPrimary = 0;
    var acceptedHistory = 0;
    final output = <PlaybackQueueItem>[];

    for (final item in ordered) {
      final id = item.id.value;
      if (!seenIds.add(id)) continue;
      final tier = _artistPriorityTier(
        author: item.author,
        normalizedPrimary: normalizedPrimary,
        similarArtists: similarArtists,
        historyArtists: historyArtists,
      );
      if (tier == 2 && acceptedHistory >= 2) continue;
      if (tier == 1 && acceptedPrimary >= 10) continue;
      if (tier == 0 && acceptedSimilar >= 18) continue;
      final normalizedArtist = _normalizeArtistName(item.author);
      if (normalizedArtist.isNotEmpty) {
        final usage = artistUsage[normalizedArtist] ?? 0;
        if (usage >= 4) continue;
        artistUsage[normalizedArtist] = usage + 1;
      }

      final normalizedTitle = _normalizeTitleForQueueDedup(item.title);
      if (normalizedTitle.isNotEmpty && !seenNormalizedTitles.add(normalizedTitle)) {
        continue;
      }

      output.add(
        PlaybackQueueItem(
          videoId: id,
          title: item.title,
          thumbnailUrl: _bestThumbnailUrl(item),
          artist: item.author,
          isLocal: false,
        ),
      );
      if (tier == 0) {
        acceptedSimilar++;
      } else if (tier == 1) {
        acceptedPrimary++;
      } else if (tier == 2) {
        acceptedHistory++;
      }

      if (output.length >= 30) break;
    }

    return output;
  }

  int _artistPriorityTier({
    required String author,
    required String normalizedPrimary,
    required Set<String> similarArtists,
    required Set<String> historyArtists,
  }) {
    final normalizedAuthor = _normalizeArtistName(author);
    if (normalizedAuthor.isNotEmpty) {
      if (_matchesArtistGroup(normalizedAuthor, similarArtists)) return 0;
      if (_matchesArtistGroup(normalizedAuthor, {normalizedPrimary})) return 1;
      if (_matchesArtistGroup(normalizedAuthor, historyArtists)) return 2;
    }
    return 3;
  }

  bool _matchesArtistGroup(String normalizedAuthor, Set<String> group) {
    for (final artist in group) {
      if (artist.isEmpty) continue;
      if (normalizedAuthor.contains(artist) || artist.contains(normalizedAuthor)) {
        return true;
      }
    }
    return false;
  }

  List<String> _buildSimilarArtistCandidates({
    required String primaryArtist,
    required String currentTitle,
    required List<Video> relatedVideos,
  }) {
    final normalizedPrimary = _normalizeArtistName(primaryArtist);
    final scores = <String, int>{};

    void addScore(String rawArtist, int score) {
      final normalized = _normalizeArtistName(rawArtist);
      if (normalized.isEmpty || normalized == normalizedPrimary) return;
      scores[normalized] = (scores[normalized] ?? 0) + score;
    }

    final collaborators = _extractCollaboratorArtists(currentTitle);
    final currentTrackCollaborators = _extractCollaboratorArtists(_trackTitle ?? '');
    for (final artist in collaborators) {
      addScore(artist, 240);
    }
    for (final artist in currentTrackCollaborators) {
      addScore(artist, 220);
    }

    final topRelatedTopicAuthors = _extractTopRelatedTopicAuthors(
      relatedVideos: relatedVideos,
      normalizedPrimaryArtist: normalizedPrimary,
      limit: 10,
    );
    var relatedWeight = 170;
    for (final artist in topRelatedTopicAuthors) {
      addScore(artist, relatedWeight);
      if (relatedWeight > 88) relatedWeight -= 12;
    }

    for (final video in relatedVideos.take(50)) {
      if (!_isPureYoutubeMusicAudio(video)) continue;
      final boost = _isTopicAuthor(video.author.toLowerCase()) ? 74 : 52;
      addScore(video.author, boost);
    }

    final sorted = scores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.map((e) => e.key).take(12).toList();
  }

  List<String> _extractCollaboratorArtists(String title) {
    if (title.trim().isEmpty) return const [];
    final cleaned = title
        .replaceAll(RegExp(r'[\(\)\[\]\{\}]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final match = RegExp(
      r'(?:feat\.?|ft\.?|with|x|&|y)\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(cleaned);
    if (match == null) return const [];

    final tail = (match.group(1) ?? '')
        .replaceAll(RegExp(r'\b(official|audio|video|lyrics|lyric)\b', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (tail.isEmpty) return const [];

    final seen = <String>{};
    final artists = <String>[];
    for (final raw in tail.split(RegExp(r'[,/;|•]| and ', caseSensitive: false))) {
      final normalized = _normalizeArtistName(raw);
      if (normalized.isEmpty || !seen.add(normalized)) continue;
      artists.add(normalized);
      if (artists.length >= 6) break;
    }
    return artists;
  }

  List<String> _extractTopRelatedTopicAuthors({
    required List<Video> relatedVideos,
    required String normalizedPrimaryArtist,
    required int limit,
  }) {
    final counter = <String, int>{};
    for (final video in relatedVideos.take(70)) {
      final authorRaw = video.author.toLowerCase().trim();
      if (!_isTopicAuthor(authorRaw) || _isBlockedRecommendationAuthor(authorRaw)) continue;
      if (!_isPureYoutubeMusicAudio(video)) continue;
      final normalized = _normalizeArtistName(video.author);
      if (normalized.isEmpty || normalized == normalizedPrimaryArtist) continue;
      counter[normalized] = (counter[normalized] ?? 0) + 1;
    }
    final sorted = counter.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.map((e) => e.key).take(limit).toList();
  }

  int _recommendationScore(
    Video item,
    String normalizedPrimaryArtist,
    _QueueHistoryProfile historyProfile,
  ) {
    final title = item.title.toLowerCase();
    final author = item.author.toLowerCase();
    var score = 0;

    final isTopic = _isTopicAuthor(author);
    final isAutoGenerated = _hasAutoGeneratedSignal(item);
    if (isTopic) score += 3200;
    if (isAutoGenerated) score += 2200;
    if (author.contains(normalizedPrimaryArtist)) score += 340;
    if (title.contains(normalizedPrimaryArtist)) score += 180;
    if (isTopic && author.contains(normalizedPrimaryArtist)) score += 320;

    for (final artist in historyProfile.topArtists.take(2)) {
      final normalizedArtist = artist.toLowerCase();
      if (author.contains(normalizedArtist)) {
        score += isTopic ? 170 : 90;
      }
      if (title.contains(normalizedArtist)) {
        score += 52;
      }
    }

    for (final token in historyProfile.topTitleTokens.take(10)) {
      if (token.length < 3) continue;
      if (title.contains(token)) score += 48;
    }

    score += _musicKeywordScore(title, author);

    final views = item.engagement.viewCount;
    if (views > 0) {
      score += (views / 100000).floor().clamp(0, 500);
    }

    return score;
  }

  int _musicKeywordScore(String title, String author) {
    final text = '$title $author';
    var score = 0;
    for (final keyword in _musicKeywords) {
      if (text.contains(keyword)) score += 25;
    }
    return score;
  }

  bool _looksLikeMusicVideo(Video item) {
    final text = '${item.title} ${item.author}'.toLowerCase();
    return _musicKeywords.any(text.contains);
  }

  bool _isPureYoutubeMusicAudio(Video item) {
    final author = item.author.toLowerCase().trim();
    if (_isBlockedRecommendationAuthor(author)) return false;
    final title = item.title.toLowerCase();
    final text = '$title $author';
    final topic = _isTopicAuthor(author);
    final autoGenerated = _hasAutoGeneratedSignal(item);
    final hasVideoLikeSignal = _videoLikeKeywords.any(text.contains);
    return (topic || autoGenerated) && !hasVideoLikeSignal;
  }

  bool _hasAutoGeneratedSignal(Video item) {
    final title = item.title.toLowerCase();
    final description = item.description.toLowerCase();
    return _autoGeneratedKeywords.any((keyword) {
      return title.contains(keyword) || description.contains(keyword);
    });
  }

  bool _isTopicAuthor(String authorLower) {
    final author = authorLower.trim();
    return author.endsWith('- topic') || author.endsWith('topic');
  }

  bool _isBlockedRecommendationAuthor(String authorLower) {
    final author = authorLower.trim();
    return author == 'release - topic' || author == 'release topic';
  }

  String _bestThumbnailUrl(Video video) {
    return bestThumbnailForVideo(video);
  }

  String _normalizeTitleForQueueDedup(String title) {
    var normalized = title.toLowerCase();
    normalized = normalized.replaceAll(RegExp(r'\s*[\(\[\{].*?[\)\]\}]'), ' ');
    normalized = normalized.replaceAll(
      RegExp(
        r'\b(official|video|audio|lyric|lyrics|visualizer|live|session|en vivo|remix|feat\.?|ft\.?)\b',
      ),
      ' ',
    );
    normalized = normalized.replaceAll(RegExp(r'[^a-z0-9\s]'), ' ');
    normalized = normalized.replaceAll(RegExp(r'\s+'), ' ').trim();
    return normalized;
  }

  String _sanitizeSearchQuery(String query) {
    var normalized = query
        .replaceAll(RegExp(r'\s*[\(\[\{].*?[\)\]\}]'), ' ')
        .replaceAll(RegExp(r'\bofficial\b', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'\bvisualizer\b', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'\bvideo\b', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    if (normalized.isEmpty) return normalized;

    final seen = <String>{};
    final compact = <String>[];
    for (final token in normalized.split(' ')) {
      final key = token.toLowerCase();
      if (key.isEmpty) continue;
      if (!seen.add(key)) continue;
      compact.add(token);
      if (compact.length >= 8) break;
    }

    return compact.join(' ').trim();
  }

  Future<List<Video>> _searchTopicChannelUploads(
    String artist, {
    required int limit,
  }) async {
    final channel = await _resolveBestTopicChannel(artist);
    if (channel == null) return const [];
    if (_isBlockedRecommendationAuthor(channel.name.toLowerCase())) return const [];
    try {
      final uploads = await _runYoutubeWithRetry(
        () => _ytExplode.channels.getUploads(channel.id.value).take(80).toList(),
        maxAttempts: 1,
      );
      final prioritized = _prioritizeTopicStyleVideos(uploads);
      return prioritized
          .where(_isPureYoutubeMusicAudio)
          .take(limit)
          .toList();
    } catch (e, s) {
      log('No se pudieron cargar uploads de canal topic: ${channel.name}', error: e, stackTrace: s);
      return const [];
    }
  }

  Future<SearchChannel?> _resolveBestTopicChannel(String artist) async {
    final normalizedArtist = _normalizeArtistName(artist);
    if (normalizedArtist.isEmpty) return null;
    try {
      final raw = await _runYoutubeWithRetry(
        () => _ytExplode.search.searchContent(artist, filter: TypeFilters.channel),
        maxAttempts: 1,
      );
      final channels = raw.whereType<SearchChannel>().take(12).toList();
      if (channels.isEmpty) return null;

      final topicOnly = channels.where((channel) => _isTopicAuthor(channel.name.toLowerCase())).toList();
      final filteredTopicOnly = topicOnly
          .where((channel) => !_isBlockedRecommendationAuthor(channel.name.toLowerCase()))
          .toList();
      if (filteredTopicOnly.isEmpty) return null;

      SearchChannel best = filteredTopicOnly.first;
      var bestScore = -1;
      for (final channel in filteredTopicOnly) {
        final name = channel.name.toLowerCase().trim();
        final description = channel.description.toLowerCase().trim();
        var score = 0;
        if (name.contains(normalizedArtist)) score += 6;
        if (description.contains(normalizedArtist)) score += 2;
        if (name == '$normalizedArtist - topic') score += 8;
        if (name.endsWith('- topic') || name.endsWith('topic')) score += 4;
        if (score > bestScore) {
          bestScore = score;
          best = channel;
        }
      }
      return best;
    } catch (e, s) {
      log('No se pudo resolver canal topic para $artist', error: e, stackTrace: s);
      return null;
    }
  }

  List<Video> _prioritizeTopicStyleVideos(List<Video> source) {
    final topic = <Video>[];
    final music = <Video>[];
    final others = <Video>[];
    final seenIds = <String>{};

    for (final video in source) {
      final id = video.id.value;
      if (!seenIds.add(id)) continue;
      if (_isTopicAuthor(video.author.toLowerCase())) {
        topic.add(video);
      } else if (_looksLikeMusicVideo(video)) {
        music.add(video);
      } else {
        others.add(video);
      }
    }

    topic.sort((a, b) => b.engagement.viewCount.compareTo(a.engagement.viewCount));
    music.sort((a, b) => b.engagement.viewCount.compareTo(a.engagement.viewCount));
    others.sort((a, b) => b.engagement.viewCount.compareTo(a.engagement.viewCount));
    return [...topic, ...music, ...others];
  }

  Future<void> _waitForYoutubeRequestSlot() async {
    final now = DateTime.now();
    final slowModeActive = _youtubeSlowModeUntil != null && now.isBefore(_youtubeSlowModeUntil!);
    final effectiveGap = slowModeActive ? _youtubeSlowRequestGap : _youtubeMinRequestGap;
    final last = _lastYoutubeRequestAt;
    if (last == null) {
      _lastYoutubeRequestAt = now;
      return;
    }
    final elapsed = now.difference(last);
    if (elapsed < effectiveGap) {
      await Future<void>.delayed(effectiveGap - elapsed);
    }
    if (slowModeActive) {
      final jitterMs = 120 + math.Random().nextInt(420);
      await Future<void>.delayed(Duration(milliseconds: jitterMs));
    }
    _lastYoutubeRequestAt = DateTime.now();
  }

  bool get _isYoutubeSlowModeActive {
    final until = _youtubeSlowModeUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  void _activateYoutubeSlowMode([Duration duration = _youtubeRateLimitCooldown]) {
    final now = DateTime.now();
    final until = now.add(duration);
    if (_youtubeSlowModeUntil == null || until.isAfter(_youtubeSlowModeUntil!)) {
      _youtubeSlowModeUntil = until;
    }
  }

  Future<void> _resetYoutubeClientForRecovery() async {
    try {
      _ytExplode.close();
    } catch (_) {}
    _ytExplode = YoutubeExplode();
  }

  Future<List<Video>> _safeSearchVideos(
    String rawQuery, {
    required int limit,
    bool onlyTopic = false,
    bool onlyAutoGenerated = false,
  }) async {
    final query = _sanitizeSearchQuery(rawQuery);
    if (query.isEmpty) return const [];
    try {
      final results = await _runYoutubeWithRetry(
        () => _ytExplode.search.search(query),
        maxAttempts: 2,
      );
      final list = results.toList();
      if (!onlyTopic) {
        if (!onlyAutoGenerated) return list.take(limit).toList();
        return list.where(_hasAutoGeneratedSignal).take(limit).toList();
      }
      Iterable<Video> filtered = list.where((item) => _isTopicAuthor(item.author.toLowerCase()));
      filtered = filtered.where((item) => !_isBlockedRecommendationAuthor(item.author.toLowerCase()));
      if (onlyAutoGenerated) {
        filtered = filtered.where(_hasAutoGeneratedSignal);
      }
      return filtered.take(limit).toList();
    } catch (e, s) {
      log('Busqueda de recomendados falló: $query', error: e, stackTrace: s);
      return const [];
    }
  }

  Future<List<Video>> _pickRandomHistoryArtistVideos(
    _QueueHistoryProfile historyProfile,
  ) async {
    final random = math.Random();
    final picks = <Video>[];
    final seenIds = <String>{};
    for (final artist in historyProfile.topArtists.take(2)) {
      try {
        final pool = await _searchTopicChannelUploads(artist, limit: 30);
        if (pool.isEmpty) continue;
        final chosen = pool[random.nextInt(pool.length)];
        if (seenIds.add(chosen.id.value)) {
          picks.add(chosen);
        }
      } catch (_) {
        // Si falla un artista, seguimos con el siguiente.
      }
    }
    return picks;
  }

  Future<_QueueHistoryProfile> _buildQueueHistoryProfile({
    required String primaryArtist,
  }) async {
    final artistCounter = <String, int>{};
    final tokenCounter = <String, int>{};

    void addArtist(String? raw) {
      if (raw == null || raw.trim().isEmpty) return;
      final normalized = _normalizeArtistName(raw);
      if (normalized.isEmpty) return;
      artistCounter[normalized] = (artistCounter[normalized] ?? 0) + 1;
    }

    void addTitleTokens(String? rawTitle) {
      if (rawTitle == null || rawTitle.trim().isEmpty) return;
      final normalized = _normalizeTitleForQueueDedup(rawTitle);
      if (normalized.isEmpty) return;
      for (final token in normalized.split(' ')) {
        if (token.length < 3) continue;
        if (_historyStopwords.contains(token)) continue;
        tokenCounter[token] = (tokenCounter[token] ?? 0) + 1;
      }
    }

    addArtist(primaryArtist);
    addArtist(_trackArtist);
    addTitleTokens(_trackTitle);

    for (final item in _playbackHistory.reversed.take(30)) {
      addArtist(item.artist);
      addTitleTokens(item.title);
    }

    try {
      final history = await _historyService.getHistory();
      for (final item in history.take(40)) {
        addArtist(item.channelTitle);
        addTitleTokens(item.title);
      }
    } catch (_) {
      // Si falla historial, seguimos con la señal local de sesión.
    }

    final topArtists = artistCounter.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final topTokens = tokenCounter.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return _QueueHistoryProfile(
      topArtists: topArtists.map((e) => e.key).toList(),
      topTitleTokens: topTokens.map((e) => e.key).toList(),
    );
  }

  String _normalizeArtistName(String input) {
    return input
        .toLowerCase()
        .replaceAll(RegExp(r'\s*[-–—]\s*topic$', caseSensitive: false), '')
        .replaceAll(RegExp(r'\btopic\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\bvevo\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\bofficial\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\brecords?\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\bmusic\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static const List<String> _musicKeywords = [
    'official audio',
    'audio',
    'lyric',
    'lyrics',
    'music video',
    'vevo',
    'official video',
    'visualizer',
    'live',
    'session',
    'en vivo',
    'acoustic',
    'remix',
  ];

  static const List<String> _autoGeneratedKeywords = [
    'provided to youtube by',
    'auto-generated by youtube',
  ];

  static const List<String> _videoLikeKeywords = [
    'official video',
    'music video',
    'video oficial',
    'live',
    'en vivo',
    'concert',
    'session',
    'visualizer',
    'performance',
    'clip oficial',
  ];

  static const Set<String> _historyStopwords = {
    'the',
    'and',
    'with',
    'from',
    'para',
    'con',
    'del',
    'de',
    'los',
    'las',
    'una',
    'uno',
    'official',
    'video',
    'audio',
    'lyrics',
    'lyric',
    'live',
    'topic',
  };

  Future<T> _runYoutubeWithRetry<T>(
    Future<T> Function() action, {
    int maxAttempts = 3,
  }) async {
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        await _waitForYoutubeRequestSlot();
        return await action();
      } on RequestLimitExceededException catch (e) {
        lastError = e;
        _activateYoutubeSlowMode(Duration(seconds: 35 + (attempt * 18)));
        if (attempt < maxAttempts) {
          await _resetYoutubeClientForRecovery();
        }
      } on SocketException catch (e) {
        lastError = e;
      } on HandshakeException catch (e) {
        lastError = e;
      } on HttpException catch (e) {
        lastError = e;
      } catch (e) {
        lastError = e;
      }

      if (attempt < maxAttempts) {
        final waitSeconds = (lastError is RequestLimitExceededException)
            ? (4 + (attempt * 4))
            : (attempt * 3);
        final jitterMs = 120 + math.Random().nextInt(380);
        await Future<void>.delayed(Duration(seconds: waitSeconds, milliseconds: jitterMs));
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
    await _disableBassBoostOnTrackChange();
    await _resetEngines();
    await _applyDefaultPlaybackVolume();
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

    String? resolvedPlainLyrics = localPlainLyrics;
    String? resolvedSyncedLyrics = localSyncedLyrics;
    final hasPassedLyrics =
        (resolvedPlainLyrics?.trim().isNotEmpty ?? false) ||
        (resolvedSyncedLyrics?.trim().isNotEmpty ?? false);
    if (!hasPassedLyrics) {
      try {
        final box = await Hive.openBox<DownloadedVideo>('downloads');
        final downloaded = box.get(id);
        if (downloaded != null) {
          resolvedPlainLyrics = downloaded.plainLyrics;
          resolvedSyncedLyrics = downloaded.syncedLyrics;
        }
      } catch (_) {
        // Ignoramos: si falla Hive, seguimos sin letra local.
      }
    }

    final hasAppliedLocalLyrics = _applyLocalLyrics(
      plainLyrics: resolvedPlainLyrics,
      syncedLyrics: resolvedSyncedLyrics,
    );
    _syncSystemNowPlaying();
    _syncSystemPlaybackState(force: true);
    notifyListeners();

    final localFile = File(filePath);
    if (!await localFile.exists()) {
      _errorMessage = 'El archivo local no existe.';
      _isLoading = false;
      _syncSystemPlaybackState(force: true);
      notifyListeners();
      return;
    }

    try {
      await _player.setAudioSource(AudioSource.file(filePath));
      unawaited(_applyBassBoostEffect());
      // No esperamos a que termine la reproducción para no bloquear la UI.
      unawaited(_playInBackgroundSafely(isLocalPlayback: true));
      _sessionPlayedVideoIds.add(id);
      _usingHiddenVideo = false;
      if (_autoplayEnabled) {
        unawaited(_loadLocalQueue(currentVideoId: id));
      } else {
        _clearQueueForAutoplayDisabled();
      }
      if (_isLyricsLayout && !hasAppliedLocalLyrics) {
        unawaited(_loadLyricsForCurrentTrack());
      }
      _syncSystemPlaybackState(force: true);
    } catch (e, s) {
      log('Error reproduciendo archivo local', error: e, stackTrace: s);
      _errorMessage = _buildPlaybackErrorMessage(
        e,
        isLocalPlayback: true,
      );
      _isPlaying = false;
      _isBuffering = false;
      _syncSystemPlaybackState(force: true);
    } finally {
      _isLoading = false;
      _syncSystemPlaybackState(force: true);
      notifyListeners();
    }
  }

  Future<void> playQueueItem(PlaybackQueueItem item) async {
    try {
      await _prepareSystemArtwork(
        videoId: item.videoId,
        thumbnailSource: item.thumbnailUrl,
      ).timeout(
        const Duration(milliseconds: 500),
        onTimeout: () => null,
      );
    } catch (e, s) {
      log(
        'No se pudo preparar artwork para cola',
        error: e,
        stackTrace: s,
      );
    }
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
    await play(
      item.videoId,
      preferredThumbnailUrl: item.thumbnailUrl,
      preferredTitle: item.title,
      preferredArtist: item.artist,
    );
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

  void toggleBassBoost() {
    if (!isBassBoostSupported) {
      _bassBoostEnabled = false;
      notifyListeners();
      return;
    }
    _bassBoostEnabled = !_bassBoostEnabled;
    unawaited(_applyBassBoostEffect());
    notifyListeners();
  }

  Future<void> _disableBassBoostOnTrackChange() async {
    if (!_bassBoostEnabled) return;
    _bassBoostEnabled = false;
    await _applyBassBoostEffect();
    notifyListeners();
  }

  Future<void> _applyBassBoostEffect() async {
    if (kIsWeb) return;
    if (Platform.isIOS) {
      try {
        await _iosBassBoostChannel.invokeMethod<void>(
          'setBassBoost',
          <String, Object>{
            'enabled': _bassBoostEnabled,
            'amount': _bassBoostEnabled ? 1.1 : 0.0,
          },
        );
        _bassBoostConfigured = true;
      } catch (e, s) {
        log('No se pudo aplicar Bass Boost en iOS', error: e, stackTrace: s);
        if (_bassBoostConfigured) return;
        _bassBoostEnabled = false;
        _bassBoostConfigured = true;
      }
      return;
    }
    if (!Platform.isAndroid) return;
    final enhancer = _androidBassEnhancer;
    final equalizer = _androidBassEqualizer;
    if (enhancer == null || equalizer == null) return;

    try {
      await enhancer.setEnabled(_bassBoostEnabled);
      await equalizer.setEnabled(_bassBoostEnabled);

      final params = await equalizer.parameters;
      final minDb = params.minDecibels;
      final maxDb = params.maxDecibels;
      for (final band in params.bands) {
        double targetGain = 0.0;
        if (_bassBoostEnabled) {
          final f = band.centerFrequency;
          if (f <= 90) {
            targetGain = 6.0;
          } else if (f <= 180) {
            targetGain = 4.8;
          } else if (f <= 320) {
            targetGain = 2.4;
          } else if (f <= 600) {
            targetGain = 0.8;
          } else {
            targetGain = 0.0;
          }
        }
        await band.setGain(targetGain.clamp(minDb, maxDb).toDouble());
      }

      await enhancer.setTargetGain(_bassBoostEnabled ? 1.8 : 0.0);
      _bassBoostConfigured = true;
    } catch (e, s) {
      log('No se pudo aplicar Bass Boost', error: e, stackTrace: s);
      if (_bassBoostConfigured) return;
      _bassBoostEnabled = false;
      _bassBoostConfigured = true;
    }
  }

  Future<void> _applyDefaultPlaybackVolume() async {
    try {
      await _player.setVolume(_defaultPlaybackVolume);
    } catch (_) {
      // Best effort: algunos backends pueden limitar o ignorar >1.0.
    }
  }

  void toggleLyricsLayout() {
    _isLyricsLayout = !_isLyricsLayout;
    final hasCurrentLyrics = (_lyricsText?.trim().isNotEmpty ?? false) || _syncedLyrics.isNotEmpty;
    if (_isLyricsLayout && !hasCurrentLyrics) {
      unawaited(_loadLyricsForCurrentTrack());
    }
    notifyListeners();
  }

  List<AudioOnlyStreamInfo> _prioritizeAudioStreams(List<AudioOnlyStreamInfo> streams) {
    final targetBitrate = Platform.isIOS ? 160000 : 128000;
    final sorted = [...streams]
      ..sort((a, b) {
        final aContainer = a.container.name.toLowerCase();
        final bContainer = b.container.name.toLowerCase();
        final aPreferredContainer = (aContainer == 'mp4' || aContainer == 'm4a') ? 1 : 0;
        final bPreferredContainer = (bContainer == 'mp4' || bContainer == 'm4a') ? 1 : 0;

        if (aPreferredContainer != bPreferredContainer) {
          return bPreferredContainer.compareTo(aPreferredContainer);
        }

        final aDistance = (a.bitrate.bitsPerSecond - targetBitrate).abs();
        final bDistance = (b.bitrate.bitsPerSecond - targetBitrate).abs();
        if (aDistance != bDistance) return aDistance.compareTo(bDistance);

        return b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond);
      });
    return sorted;
  }

  Future<void> _playInBackgroundSafely({bool isLocalPlayback = false}) async {
    try {
      await _player.play();
    } catch (e, s) {
      log('play() en background falló', error: e, stackTrace: s);
      _errorMessage = _buildPlaybackErrorMessage(
        e,
        isLocalPlayback: isLocalPlayback,
      );
      _isPlaying = false;
      _isBuffering = false;
      notifyListeners();
    }
  }

  Future<void> togglePlayPause() async {
    if (_isResettingEngines || _isTogglingPlayPause) return;
    _isTogglingPlayPause = true;
    try {
      if (_usingHiddenVideo && _hiddenVideoController != null) {
        final controller = _hiddenVideoController!;
        final shouldPlay = !controller.value.isPlaying;

        // Feedback inmediato para que el botón cambie sin esperar al stream.
        _isPlaying = shouldPlay;
        notifyListeners();

        try {
          if (shouldPlay) {
            await controller.play();
          } else {
            await controller.pause();
          }
        } catch (e, s) {
          log('togglePlayPause en hidden video falló', error: e, stackTrace: s);
        } finally {
          final value = controller.value;
          _isPlaying = value.isPlaying;
          _isBuffering = value.isBuffering;
          notifyListeners();
        }
        return;
      }

      // Usamos el estado real del motor para evitar desincronizaciones del UI flag.
      final shouldPlay = !_player.playing;
      _isPlaying = shouldPlay;
      if (shouldPlay) {
        _isBuffering = true;
      }
      notifyListeners();

      try {
        if (shouldPlay) {
          // En just_audio, play() puede mantener el Future vivo durante la reproducción.
          // No esperamos aquí para no bloquear taps siguientes.
          unawaited(_playInBackgroundSafely(isLocalPlayback: _isLocal));
        } else {
          await _player.pause();
        }
      } catch (e, s) {
        log('togglePlayPause en audio falló', error: e, stackTrace: s);
      } finally {
        if (shouldPlay) {
          // Damos un frame para que el estado interno se sincronice.
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
        _isPlaying = _player.playing;
        _isBuffering = false;
        notifyListeners();
      }
    } finally {
      _isTogglingPlayPause = false;
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

    _clearSystemNowPlaying();
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
    _clearSystemNowPlaying();
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
    _syncSystemPlaybackState(force: true);
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
        unawaited(_applyBassBoostEffect());
        await _player.seek(position);
        await _player.play();
        _isPlaying = true;
        _isBuffering = false;
        _syncSystemPlaybackState(force: true);
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
      unawaited(_precacheQueueArtwork(_playbackQueue.take(8)));
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
            thumbnailUrl: (item.localThumbnailPath != null &&
                    item.localThumbnailPath!.isNotEmpty)
                ? item.localThumbnailPath!
                : item.thumbnailUrl,
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
      unawaited(_precacheQueueArtwork(_playbackQueue.take(8)));
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

  bool _applyLocalLyrics({
    String? plainLyrics,
    String? syncedLyrics,
  }) {
    final localPlain = plainLyrics?.trim();
    final localSynced = syncedLyrics?.trim();
    if ((localPlain == null || localPlain.isEmpty) &&
        (localSynced == null || localSynced.isEmpty)) {
      return false;
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
      return true;
    }

    if (localPlain != null && localPlain.isNotEmpty) {
      _lyricsText = localPlain;
      _lyricsError = null;
      _isLyricsLoading = false;
      return true;
    }
    return false;
  }

  String _stripLrcTimestamps(String lrc) {
    return lrc
        .split('\n')
        .map((line) => line.replaceAll(RegExp(r'\[[0-9:.]+\]'), '').trim())
        .where((line) => line.isNotEmpty)
        .join('\n');
  }

  String _buildPlaybackErrorMessage(
    Object error, {
    bool isLocalPlayback = false,
  }) {
    final raw = error.toString();
    if (error is RequestLimitExceededException) {
      return 'No se pudo reproducir porque YouTube limitó temporalmente la solicitud. Intenta de nuevo en unos minutos.';
    }
    if (error is SocketException) {
      return isLocalPlayback
          ? 'No se pudo reproducir el archivo local por un problema de acceso al sistema de archivos.'
          : 'No se pudo reproducir por un problema de conexión a internet.';
    }
    if (error is HandshakeException) {
      return 'No se pudo establecer una conexión segura (TLS) con el servidor de audio. Intenta de nuevo o cambia de red.';
    }
    if (error is HttpException) {
      return 'No se pudo reproducir porque el servidor respondió con un error de red.';
    }
    if (raw.contains('No se encontraron streams de audio')) {
      return 'No se pudo reproducir porque no se encontró un stream de audio compatible para esta canción.';
    }
    if (raw.contains('No se pudo iniciar audio ni fallback de video')) {
      return 'No se pudo reproducir porque falló tanto el stream de audio como el fallback de video.';
    }
    if (raw.contains('El archivo local no existe')) {
      return 'No se pudo reproducir porque el archivo descargado ya no existe en el dispositivo.';
    }
    if (raw.contains('No se pudo reproducir el archivo descargado')) {
      return 'No se pudo reproducir el archivo descargado. Puede estar dañado o incompleto.';
    }
    return isLocalPlayback
        ? 'No se pudo reproducir el archivo local: $raw'
        : 'No se pudo reproducir esta canción: $raw';
  }
}
