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
  static const _QueueHistoryProfile _emptyHistoryProfile = _QueueHistoryProfile(
    topArtists: [],
    topTitleTokens: [],
  );
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
  bool _isTogglingPlayPause = false;
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

  Future<void> play(
    String videoId, {
    bool isLocalVideo = false,
    String? preferredThumbnailUrl,
    String? preferredTitle,
    String? preferredArtist,
    Duration? preferredDuration,
  }) async {
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
    _trackTitle = (preferredTitle != null && preferredTitle.trim().isNotEmpty)
        ? preferredTitle.trim()
        : null;
    _trackArtist = (preferredArtist != null && preferredArtist.trim().isNotEmpty)
        ? preferredArtist.trim()
        : null;
    _trackDuration = preferredDuration ?? Duration.zero;
    _trackThumbnailUrl = null;
    if (preferredThumbnailUrl != null && preferredThumbnailUrl.isNotEmpty) {
      _trackThumbnailUrl = preferredThumbnailUrl;
    }
    _resetLyricsState();
    notifyListeners();

    try {
      final manifestFuture = _getManifestWithRetry(videoId);
      final videoFuture = _getVideoWithRetry(videoId);
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

      // Metadata/cola/historial en segundo plano para no bloquear inicio de reproducción.
      unawaited(() async {
        Video? video;
        try {
          video = await videoFuture.timeout(const Duration(seconds: 6));
        } catch (e, s) {
          log('No se pudo resolver metadata de video a tiempo', error: e, stackTrace: s);
        }

        if (_currentVideoId != videoId) return;

        if (video != null) {
          _trackTitle = video.title;
          _trackThumbnailUrl =
              (preferredThumbnailUrl != null && preferredThumbnailUrl.isNotEmpty)
                  ? preferredThumbnailUrl
                  : video.thumbnails.highResUrl;
          _trackArtist = video.author;
          _trackDuration = video.duration ?? Duration.zero;
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
      _errorMessage = 'No se pudo reproducir esta canción.';
      _isPlaying = false;
      _isBuffering = false;
      await _player.stop();
    } finally {
      _isLoading = false;
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
      maxAttempts: 2,
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
      maxAttempts: 2,
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
    } catch (_) {
      return null;
    }
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
        );
        // Fast-path: con related suficiente ya no hacemos más requests.
        if (fastQueue.length >= 18) return fastQueue;
        candidates.addAll(related.take(50));
      }

      final historyProfile = await _buildQueueHistoryProfile(primaryArtist: video.author);

      // Búsqueda base por artista + título.
      final combinedQuery = _buildRecommendationQuery(video.author, video.title);
      final batchedSearches = <Future<List<Video>>>[
        _safeSearchVideos(combinedQuery, limit: 24),
      ];

      // Refuerzo por historial: artistas más escuchados.
      for (final artist in historyProfile.topArtists.take(1)) {
        batchedSearches.add(_safeSearchVideos('$artist topic', limit: 12));
        batchedSearches.add(_safeSearchVideos('$artist official audio', limit: 12));
      }
      final batchResults = await Future.wait(batchedSearches);
      for (final batch in batchResults) {
        candidates.addAll(batch);
      }

      // Fallback final: solo título si no hay suficientes candidatos.
      if (candidates.length < 8) {
        final titleQuery = _sanitizeSearchQuery(video.title);
        candidates.addAll(await _safeSearchVideos(titleQuery, limit: 20));
      }

      return _buildSmartQueue(
        candidates,
        currentVideoId: key,
        primaryArtist: video.author,
        historyProfile: historyProfile,
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
  }) {
    final normalizedPrimaryArtist = primaryArtist.toLowerCase().trim();
    final filtered = source
        .where((item) => item.id.value != currentVideoId)
        .where(_looksLikeMusicVideo)
        .toList();

    filtered.sort((a, b) {
      final scoreA = _recommendationScore(a, normalizedPrimaryArtist, historyProfile);
      final scoreB = _recommendationScore(b, normalizedPrimaryArtist, historyProfile);
      return scoreB.compareTo(scoreA);
    });

    final seenIds = <String>{};
    final seenNormalizedTitles = <String>{};
    final output = <PlaybackQueueItem>[];

    for (final item in filtered) {
      final id = item.id.value;
      if (!seenIds.add(id)) continue;

      final normalizedTitle = _normalizeTitleForQueueDedup(item.title);
      if (normalizedTitle.isNotEmpty && !seenNormalizedTitles.add(normalizedTitle)) {
        continue;
      }

      output.add(
        PlaybackQueueItem(
          videoId: id,
          title: item.title,
          thumbnailUrl: item.thumbnails.mediumResUrl,
          artist: item.author,
          isLocal: false,
        ),
      );

      if (output.length >= 30) break;
    }

    return output;
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
    if (isTopic) score += 3200;
    if (author.contains(normalizedPrimaryArtist)) score += 340;
    if (title.contains(normalizedPrimaryArtist)) score += 180;
    if (isTopic && author.contains(normalizedPrimaryArtist)) score += 320;

    for (final artist in historyProfile.topArtists.take(5)) {
      final normalizedArtist = artist.toLowerCase();
      if (author.contains(normalizedArtist)) {
        score += isTopic ? 520 : 300;
      }
      if (title.contains(normalizedArtist)) {
        score += 170;
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

  bool _isTopicAuthor(String authorLower) {
    final author = authorLower.trim();
    return author.endsWith('- topic') || author.endsWith('topic');
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

  String _buildRecommendationQuery(String artist, String title) {
    final normalizedArtist = _normalizeArtistName(artist);
    var normalizedTitle = _normalizeTitleForQueueDedup(title);
    if (normalizedArtist.isNotEmpty && normalizedTitle.startsWith(normalizedArtist)) {
      normalizedTitle = normalizedTitle.substring(normalizedArtist.length).trim();
    }
    return _sanitizeSearchQuery('$artist $normalizedTitle');
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

  Future<List<Video>> _safeSearchVideos(
    String rawQuery, {
    required int limit,
  }) async {
    final query = _sanitizeSearchQuery(rawQuery);
    if (query.isEmpty) return const [];
    try {
      final results = await _ytExplode.search.search(query);
      return results.take(limit).toList();
    } catch (e, s) {
      log('Busqueda de recomendados falló: $query', error: e, stackTrace: s);
      return const [];
    }
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
    'topic',
    'official video',
    'visualizer',
    'live',
    'session',
    'en vivo',
    'acoustic',
    'remix',
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

      final shouldPlay = !_isPlaying;
      _isPlaying = shouldPlay;
      if (shouldPlay) {
        _isBuffering = true;
      }
      notifyListeners();

      try {
        if (shouldPlay) {
          await _player.play();
        } else {
          await _player.pause();
        }
      } catch (e, s) {
        log('togglePlayPause en audio falló', error: e, stackTrace: s);
      } finally {
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
