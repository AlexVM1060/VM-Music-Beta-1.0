import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:path/path.dart' as p;
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:myapp/models/downloaded_video.dart';
import 'package:myapp/models/video_history.dart';
import 'package:myapp/services/app_settings_service.dart';
import 'package:myapp/services/lyrics_service.dart';
import 'package:myapp/services/playlist_service.dart';
import 'package:myapp/services/youtube_request_guard.dart';
import 'package:myapp/utils/thumbnail_quality.dart';
import 'package:myapp/video_player_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

enum DownloadStatus { notDownloaded, downloading, downloaded, error }

class PlaylistDownloadSummary {
  final int queued;
  final int alreadyDownloaded;
  final int alreadyInProgress;

  const PlaylistDownloadSummary({
    required this.queued,
    required this.alreadyDownloaded,
    required this.alreadyInProgress,
  });
}

class _PlaybackDownloadSource {
  final String url;
  final bool isVideoSource;

  const _PlaybackDownloadSource({
    required this.url,
    required this.isVideoSource,
  });
}

class DownloadService with ChangeNotifier {
  static const String _downloadsBoxName = 'downloads';
  static const String _autoDownloadBoxName = 'auto_download_playlists';
  final YoutubeExplode _yt = YoutubeExplode();
  final YoutubeRequestGuard _youtubeGuard = YoutubeRequestGuard.shared;
  final Dio _dio = Dio();
  final LyricsService _lyricsService = LyricsService();
  final AppSettingsService _settingsService;
  final Connectivity _connectivity = Connectivity();
  static const Map<String, String> _youtubeHeaders = {
    'User-Agent':
        'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
    'Accept': '*/*',
    'Origin': 'https://www.youtube.com',
    'Referer': 'https://www.youtube.com/',
  };

  final Map<String, double> _downloadProgress = {};
  final Map<String, DownloadStatus> _downloadStatus = {};
  final Map<String, String> _downloadErrors = {};
  Set<String> _autoDownloadPlaylists = {};
  final Map<String, StreamManifest> _manifestCache = {};
  final Map<String, Future<StreamManifest>> _manifestRequests = {};
  late final Future<void> _initialDownloadsSync;

  Future<Box<DownloadedVideo>> get _downloadsBox async =>
      await Hive.openBox<DownloadedVideo>(_downloadsBoxName);
  Future<Box<String>> get _autoDownloadBox async =>
      await Hive.openBox<String>(_autoDownloadBoxName);

  DownloadService(this._settingsService) {
    _loadAutoDownloadPlaylists();
    _initialDownloadsSync = loadDownloadedVideos();
  }

  Future<void> _loadAutoDownloadPlaylists() async {
    final box = await _autoDownloadBox;
    if (box.containsKey('Videos favoritos') &&
        !box.containsKey(PlaylistService.favoritesPlaylistName)) {
      await box.put(
        PlaylistService.favoritesPlaylistName,
        PlaylistService.favoritesPlaylistName,
      );
      await box.delete('Videos favoritos');
    }
    _autoDownloadPlaylists = box.values.toSet();
    notifyListeners();
  }

  Future<void> setPlaylistAutoDownload(
    String playlistName,
    bool enabled,
  ) async {
    final box = await _autoDownloadBox;
    final normalized = PlaylistService.isFavoritesPlaylistName(playlistName)
        ? PlaylistService.favoritesPlaylistName
        : playlistName;
    if (enabled) {
      await box.put(normalized, normalized);
      _autoDownloadPlaylists.add(normalized);
      if (normalized == PlaylistService.favoritesPlaylistName) {
        await box.delete('Videos favoritos');
        _autoDownloadPlaylists.remove('Videos favoritos');
      }
    } else {
      await box.delete(normalized);
      _autoDownloadPlaylists.remove(normalized);
      if (normalized == PlaylistService.favoritesPlaylistName) {
        await box.delete('Videos favoritos');
        _autoDownloadPlaylists.remove('Videos favoritos');
      }
    }
    notifyListeners();
  }

  Future<bool> autoDownloadIfEnabled(
    String playlistName,
    VideoHistory video,
  ) async {
    if (!isPlaylistAutoDownload(playlistName)) return false;
    return downloadVideoLikePlayer(
      video.videoId,
      video.title,
      video.thumbnailUrl,
      video.channelTitle,
    );
  }

  Future<bool> autoDownloadIfEnabledUsingClone(
    String playlistName,
    VideoHistory video, {
    required VideoPlayerManager videoManager,
  }) async {
    if (!isPlaylistAutoDownload(playlistName)) return false;
    return downloadVideoUsingClone(video: video, videoManager: videoManager);
  }

  Future<bool> downloadVideoUsingClone({
    required VideoHistory video,
    required VideoPlayerManager videoManager,
  }) async {
    final source = await videoManager.resolveDownloadSourceIsolated(
      video.videoId,
    );
    if (source != null && source.sourceUrl.isNotEmpty) {
      return downloadFromPlaybackSource(
        videoId: video.videoId,
        title: video.title,
        thumbnailUrl: video.thumbnailUrl,
        channelTitle: video.channelTitle,
        sourceUrl: source.sourceUrl,
        isVideoSource: source.isVideoSource,
      );
    }

    return downloadVideoLikePlayer(
      video.videoId,
      video.title,
      video.thumbnailUrl,
      video.channelTitle,
    );
  }

  bool isPlaylistAutoDownload(String playlistName) {
    if (_autoDownloadPlaylists.contains(playlistName)) return true;
    if (PlaylistService.isFavoritesPlaylistName(playlistName)) {
      return _autoDownloadPlaylists.contains(
            PlaylistService.favoritesPlaylistName,
          ) ||
          _autoDownloadPlaylists.contains('Videos favoritos');
    }
    return false;
  }

  Future<PlaylistDownloadSummary> downloadPlaylistVideos(
    List<VideoHistory> videos,
  ) async {
    var queuedCount = 0;
    var alreadyDownloadedCount = 0;
    var alreadyInProgressCount = 0;

    for (final video in videos) {
      final isDownloaded = await isVideoDownloaded(video.videoId);
      if (isDownloaded) {
        alreadyDownloadedCount++;
        continue;
      }

      if (_downloadStatus[video.videoId] == DownloadStatus.downloading) {
        alreadyInProgressCount++;
        continue;
      }

      // Encolamos sin esperar a que finalice para que "Descargar todo" sea inmediato.
      unawaited(
        downloadVideoLikePlayer(
          video.videoId,
          video.title,
          video.thumbnailUrl,
          video.channelTitle,
        ),
      );
      queuedCount++;
    }

    return PlaylistDownloadSummary(
      queued: queuedCount,
      alreadyDownloaded: alreadyDownloadedCount,
      alreadyInProgress: alreadyInProgressCount,
    );
  }

  Future<PlaylistDownloadSummary> downloadPlaylistVideosUsingClone(
    List<VideoHistory> videos, {
    required VideoPlayerManager videoManager,
  }) async {
    var queuedCount = 0;
    var alreadyDownloadedCount = 0;
    var alreadyInProgressCount = 0;

    for (final video in videos) {
      final isDownloaded = await isVideoDownloaded(video.videoId);
      if (isDownloaded) {
        alreadyDownloadedCount++;
        continue;
      }

      if (_downloadStatus[video.videoId] == DownloadStatus.downloading) {
        alreadyInProgressCount++;
        continue;
      }

      unawaited(
        downloadVideoUsingClone(video: video, videoManager: videoManager),
      );
      queuedCount++;
    }

    return PlaylistDownloadSummary(
      queued: queuedCount,
      alreadyDownloaded: alreadyDownloadedCount,
      alreadyInProgress: alreadyInProgressCount,
    );
  }

  Future<List<DownloadedVideo>> getDownloadedVideos() async {
    await _ensureInitialDownloadsSync();
    final box = await _downloadsBox;
    final videos = box.values.toList(growable: false);
    final resolved = <DownloadedVideo>[];
    var changed = false;
    for (final video in videos) {
      final repaired = await _sanitizeDownloadedVideoEntry(box, video);
      if (repaired == null) {
        changed = true;
        continue;
      }
      if (_didDownloadedEntryChange(video, repaired)) {
        changed = true;
      }
      resolved.add(repaired);
    }
    if (changed) {
      notifyListeners();
    }
    return resolved;
  }

  Future<bool> downloadVideo(
    String videoId,
    String title,
    String thumbnailUrl,
    String channelTitle,
  ) async {
    final existing = await getDownloadedVideoById(videoId);
    if (_downloadStatus[videoId] == DownloadStatus.downloading ||
        existing != null) {
      return false;
    }
    if (!await _ensureDownloadAllowedByNetwork(videoId)) {
      return false;
    }

    _downloadStatus[videoId] = DownloadStatus.downloading;
    _downloadProgress[videoId] = 0.0;
    _downloadErrors.remove(videoId);
    notifyListeners();

    try {
      final streamManifest = await _getManifestWithRetry(videoId);
      final audioOnlyStreams = streamManifest.audioOnly.toList();
      if (audioOnlyStreams.isEmpty) {
        throw Exception('No se encontraron streams de audio para descarga');
      }
      final candidates = _prioritizeAudioStreams(audioOnlyStreams);
      final appDir = await getApplicationDocumentsDirectory();
      Object? lastError;
      String? successfulPath;

      for (final streamInfo in candidates) {
        final filePath = '${appDir.path}/$videoId.${streamInfo.container.name}';
        final file = File(filePath);
        if (await file.exists()) {
          await file.delete();
        }

        try {
          final sink = file.openWrite();
          final stream = _yt.videos.streamsClient.get(streamInfo);
          final totalBytes = streamInfo.size.totalBytes;
          var receivedBytes = 0;
          await for (final chunk in stream) {
            sink.add(chunk);
            receivedBytes += chunk.length;
            if (totalBytes > 0) {
              _downloadProgress[videoId] = receivedBytes / totalBytes;
              notifyListeners();
            }
          }
          await sink.flush();
          await sink.close();

          final downloadedFile = File(filePath);
          if (!await downloadedFile.exists() ||
              await downloadedFile.length() == 0) {
            throw Exception('Archivo descargado vacío');
          }

          successfulPath = filePath;
          break;
        } catch (e) {
          lastError = e;
          if (await file.exists()) {
            await file.delete();
          }
          // Fallback por URL directa para casos donde falle el stream client.
          try {
            await _dio.download(
              streamInfo.url.toString(),
              filePath,
              options: Options(
                headers: _youtubeHeaders,
                responseType: ResponseType.bytes,
                followRedirects: true,
                receiveTimeout: const Duration(minutes: 3),
                sendTimeout: const Duration(minutes: 1),
              ),
              onReceiveProgress: (received, total) {
                if (total > 0) {
                  _downloadProgress[videoId] = received / total;
                  notifyListeners();
                }
              },
            );
            final downloadedFile = File(filePath);
            if (!await downloadedFile.exists() ||
                await downloadedFile.length() == 0) {
              throw Exception('Archivo descargado vacío');
            }
            successfulPath = filePath;
            break;
          } catch (dioError) {
            lastError = dioError;
            if (await file.exists()) {
              await file.delete();
            }
          }
        }
      }

      if (successfulPath == null) {
        throw Exception('No se pudo descargar con ningún stream: $lastError');
      }

      final lyrics = await _fetchLyricsSafe(title: title, artist: channelTitle);
      final localThumbnailPath = await _downloadThumbnailSafe(
        videoId: videoId,
        thumbnailUrl: thumbnailUrl,
      );
      final downloadedVideo = DownloadedVideo(
        videoId: videoId,
        title: title,
        thumbnailUrl: thumbnailUrl,
        channelTitle: channelTitle,
        filePath: successfulPath,
        plainLyrics: lyrics?.plainLyrics,
        syncedLyrics: lyrics?.rawSyncedLyrics,
        localThumbnailPath: localThumbnailPath,
      );

      final box = await _downloadsBox;
      await box.put(videoId, downloadedVideo);

      _downloadStatus[videoId] = DownloadStatus.downloaded;
      _downloadProgress.remove(videoId);
      notifyListeners();
      return true;
    } catch (e) {
      _downloadStatus[videoId] = DownloadStatus.error;
      _downloadProgress.remove(videoId);
      _downloadErrors[videoId] = _toUserFriendlyDownloadError(e);
      notifyListeners();
      return false;
    }
  }

  Future<bool> downloadVideoLikePlayer(
    String videoId,
    String title,
    String thumbnailUrl,
    String channelTitle,
  ) async {
    final existing = await getDownloadedVideoById(videoId);
    if (_downloadStatus[videoId] == DownloadStatus.downloading ||
        existing != null) {
      return false;
    }
    if (!await _ensureDownloadAllowedByNetwork(videoId)) {
      return false;
    }

    try {
      final sources = await _resolvePlaybackDownloadSources(videoId);
      for (final source in sources.take(8)) {
        final ok = await downloadFromPlaybackSource(
          videoId: videoId,
          title: title,
          thumbnailUrl: thumbnailUrl,
          channelTitle: channelTitle,
          sourceUrl: source.url,
          isVideoSource: source.isVideoSource,
        );
        if (ok) return true;
      }
      return false;
    } catch (_) {
      return downloadVideo(videoId, title, thumbnailUrl, channelTitle);
    }
  }

  Future<bool> downloadFromPlaybackSource({
    required String videoId,
    required String title,
    required String thumbnailUrl,
    required String channelTitle,
    required String sourceUrl,
    bool isVideoSource = false,
  }) async {
    final existing = await getDownloadedVideoById(videoId);
    if (_downloadStatus[videoId] == DownloadStatus.downloading ||
        existing != null) {
      return false;
    }
    if (!await _ensureDownloadAllowedByNetwork(videoId)) {
      return false;
    }

    _downloadStatus[videoId] = DownloadStatus.downloading;
    _downloadProgress[videoId] = 0.0;
    _downloadErrors.remove(videoId);
    notifyListeners();

    try {
      final sourceFile = File(sourceUrl);
      final isLocalSource = await sourceFile.exists();
      final appDir = await getApplicationDocumentsDirectory();
      // Para URLs remotas de YouTube usamos extensión fija segura para evitar
      // nombres enormes por query params (File name too long en iOS).
      final extension = isLocalSource
          ? _inferFileExtension(
              sourceUrl,
              fallback: isVideoSource ? 'mp4' : 'm4a',
            )
          : (isVideoSource ? 'mp4' : 'm4a');
      final targetPath = '${appDir.path}/$videoId.$extension';
      final targetFile = File(targetPath);
      if (await targetFile.exists()) {
        await targetFile.delete();
      }

      if (isLocalSource) {
        await sourceFile.copy(targetPath);
      } else {
        try {
          await _downloadFromDirectUrl(
            sourceUrl: sourceUrl,
            targetPath: targetPath,
            videoId: videoId,
          );
        } catch (directError) {
          // Fallback robusto: usa youtube_explode con el mismo videoId.
          await _downloadFromManifestFallback(
            videoId: videoId,
            isVideoSource: isVideoSource,
            targetPath: targetPath,
          ).catchError((fallbackError) {
            throw Exception(
              'Direct URL failed: $directError | Manifest fallback failed: $fallbackError',
            );
          });
        }
      }

      if (!await targetFile.exists() || await targetFile.length() == 0) {
        throw Exception('Archivo descargado vacío');
      }

      final lyrics = await _fetchLyricsSafe(title: title, artist: channelTitle);
      final localThumbnailPath = await _downloadThumbnailSafe(
        videoId: videoId,
        thumbnailUrl: thumbnailUrl,
      );
      final downloadedVideo = DownloadedVideo(
        videoId: videoId,
        title: title,
        thumbnailUrl: thumbnailUrl,
        channelTitle: channelTitle,
        filePath: targetPath,
        plainLyrics: lyrics?.plainLyrics,
        syncedLyrics: lyrics?.rawSyncedLyrics,
        localThumbnailPath: localThumbnailPath,
      );

      final box = await _downloadsBox;
      await box.put(videoId, downloadedVideo);

      _downloadStatus[videoId] = DownloadStatus.downloaded;
      _downloadProgress.remove(videoId);
      _downloadErrors.remove(videoId);
      notifyListeners();
      return true;
    } catch (e) {
      _downloadStatus[videoId] = DownloadStatus.error;
      _downloadProgress.remove(videoId);
      _downloadErrors[videoId] = _toUserFriendlyDownloadError(e);
      notifyListeners();
      return false;
    }
  }

  Future<void> deleteVideo(String videoId) async {
    final box = await _downloadsBox;
    final video = box.get(videoId);
    if (video != null) {
      final file = File(video.filePath);
      if (await file.exists()) {
        await file.delete();
      }
      final thumbPath = video.localThumbnailPath;
      if (thumbPath != null && thumbPath.isNotEmpty) {
        final thumbFile = File(thumbPath);
        if (await thumbFile.exists()) {
          await thumbFile.delete();
        }
      }
      await box.delete(videoId);
      _downloadStatus.remove(videoId);
      _downloadErrors.remove(videoId);
      notifyListeners();
    }
  }

  DownloadStatus getDownloadStatus(String videoId) {
    if (_downloadStatus.containsKey(videoId)) {
      return _downloadStatus[videoId]!;
    }
    return DownloadStatus.notDownloaded;
  }

  bool isDownloading(String videoId) {
    return _downloadStatus[videoId] == DownloadStatus.downloading;
  }

  double getDownloadProgress(String videoId) {
    return _downloadProgress[videoId] ?? 0.0;
  }

  String? getDownloadError(String videoId) {
    return _downloadErrors[videoId];
  }

  Future<void> loadDownloadedVideos() async {
    final box = await _downloadsBox;
    final videos = box.values.toList(growable: false);
    for (final video in videos) {
      await _sanitizeDownloadedVideoEntry(box, video);
    }
    notifyListeners();
  }

  Future<DownloadedVideo?> getDownloadedVideoById(String videoId) async {
    await _ensureInitialDownloadsSync();
    final box = await _downloadsBox;
    final downloaded = box.get(videoId);
    if (downloaded == null) {
      _downloadStatus.remove(videoId);
      _downloadErrors.remove(videoId);
      return null;
    }
    final repaired = await _sanitizeDownloadedVideoEntry(box, downloaded);
    if (repaired == null) {
      notifyListeners();
      return null;
    }
    if (_didDownloadedEntryChange(downloaded, repaired)) {
      notifyListeners();
    }
    return repaired;
  }

  Future<DownloadedVideo?> resolvePlayableDownloadedVideo(
    String videoId,
  ) async {
    return getDownloadedVideoById(videoId);
  }

  Future<String?> _findRecoveredDownloadPath(String videoId) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      const extensions = ['m4a', 'mp4', 'webm', 'mp3', 'aac', 'ogg'];
      for (final ext in extensions) {
        final candidate = File('${appDir.path}/$videoId.$ext');
        if (await candidate.exists()) {
          return candidate.path;
        }
      }

      final extensionless = File('${appDir.path}/$videoId');
      if (await extensionless.exists()) {
        return extensionless.path;
      }
    } catch (_) {
      // Best effort de recuperación local.
    }
    return null;
  }

  Future<String?> _findRecoveredThumbnailPath(String videoId) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      const extensions = ['jpg', 'jpeg', 'png', 'webp'];
      for (final ext in extensions) {
        final candidate = File('${appDir.path}/${videoId}_thumb.$ext');
        if (await candidate.exists()) {
          return candidate.path;
        }
      }
    } catch (_) {
      // Best effort de recuperación local.
    }
    return null;
  }

  Future<void> _ensureInitialDownloadsSync() async {
    try {
      await _initialDownloadsSync;
    } catch (_) {
      // Evitamos bloquear la UI si falla la sincronización inicial.
    }
  }

  String? _normalizePathOrNull(String? value) {
    if (value == null) return null;
    final normalized = value.trim();
    return normalized.isEmpty ? null : normalized;
  }

  Future<String?> _resolveExistingDownloadPath(
    String videoId, {
    required String preferredPath,
  }) async {
    final normalized = preferredPath.trim();
    if (normalized.isNotEmpty && await File(normalized).exists()) {
      return normalized;
    }
    return _findRecoveredDownloadPath(videoId);
  }

  Future<String?> _resolveExistingThumbnailPath(
    String videoId, {
    String? preferredPath,
  }) async {
    final normalized = _normalizePathOrNull(preferredPath);
    if (normalized != null && await File(normalized).exists()) {
      return normalized;
    }
    return _findRecoveredThumbnailPath(videoId);
  }

  bool _didDownloadedEntryChange(
    DownloadedVideo before,
    DownloadedVideo after,
  ) {
    return before.filePath != after.filePath ||
        _normalizePathOrNull(before.localThumbnailPath) !=
            _normalizePathOrNull(after.localThumbnailPath);
  }

  Future<DownloadedVideo?> _sanitizeDownloadedVideoEntry(
    Box<DownloadedVideo> box,
    DownloadedVideo downloaded,
  ) async {
    final resolvedFilePath = await _resolveExistingDownloadPath(
      downloaded.videoId,
      preferredPath: downloaded.filePath,
    );
    if (resolvedFilePath == null || resolvedFilePath.isEmpty) {
      await box.delete(downloaded.videoId);
      _downloadStatus.remove(downloaded.videoId);
      _downloadErrors.remove(downloaded.videoId);
      return null;
    }

    final resolvedThumbPath = await _resolveExistingThumbnailPath(
      downloaded.videoId,
      preferredPath: downloaded.localThumbnailPath,
    );
    final normalizedOriginalThumb = _normalizePathOrNull(
      downloaded.localThumbnailPath,
    );

    if (resolvedFilePath == downloaded.filePath &&
        resolvedThumbPath == normalizedOriginalThumb) {
      _downloadStatus[downloaded.videoId] = DownloadStatus.downloaded;
      _downloadErrors.remove(downloaded.videoId);
      return downloaded;
    }

    final repaired = DownloadedVideo(
      videoId: downloaded.videoId,
      title: downloaded.title,
      thumbnailUrl: downloaded.thumbnailUrl,
      channelTitle: downloaded.channelTitle,
      filePath: resolvedFilePath,
      plainLyrics: downloaded.plainLyrics,
      syncedLyrics: downloaded.syncedLyrics,
      localThumbnailPath: resolvedThumbPath,
    );
    await box.put(downloaded.videoId, repaired);
    _downloadStatus[downloaded.videoId] = DownloadStatus.downloaded;
    _downloadErrors.remove(downloaded.videoId);
    return repaired;
  }

  Future<bool> isVideoDownloaded(String videoId) async {
    final downloaded = await getDownloadedVideoById(videoId);
    return downloaded != null;
  }

  Future<bool> _ensureDownloadAllowedByNetwork(String videoId) async {
    if (!_settingsService.downloadOnlyOnWifi) return true;
    try {
      final results = await _connectivity.checkConnectivity();
      final hasWifi =
          results.contains(ConnectivityResult.wifi) ||
          results.contains(ConnectivityResult.ethernet);
      if (hasWifi) return true;
    } catch (_) {
      // Si no se puede determinar la red, permitimos continuar para no bloquear al usuario.
      return true;
    }

    _downloadStatus[videoId] = DownloadStatus.error;
    _downloadProgress.remove(videoId);
    _downloadErrors[videoId] =
        'Descarga bloqueada: activa datos móviles en configuración o conéctate a Wi‑Fi.';
    notifyListeners();
    return false;
  }

  List<AudioOnlyStreamInfo> _prioritizeAudioStreams(
    List<AudioOnlyStreamInfo> streams,
  ) {
    final targetBitrate = _targetBitrateForCurrentQuality();
    final sortedByBitrate = [...streams]
      ..sort((a, b) {
        final aContainer = a.container.name.toLowerCase();
        final bContainer = b.container.name.toLowerCase();
        final aPreferredContainer = (aContainer == 'mp4' || aContainer == 'm4a')
            ? 1
            : 0;
        final bPreferredContainer = (bContainer == 'mp4' || bContainer == 'm4a')
            ? 1
            : 0;
        if (aPreferredContainer != bPreferredContainer) {
          return bPreferredContainer.compareTo(aPreferredContainer);
        }

        if (targetBitrate != null) {
          final aDistance = (a.bitrate.bitsPerSecond - targetBitrate).abs();
          final bDistance = (b.bitrate.bitsPerSecond - targetBitrate).abs();
          if (aDistance != bDistance) return aDistance.compareTo(bDistance);
        }

        return b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond);
      });
    return sortedByBitrate;
  }

  int? _targetBitrateForCurrentQuality() {
    return switch (_settingsService.audioQuality) {
      AudioQualityPreference.automatic => Platform.isIOS ? 160000 : 128000,
      AudioQualityPreference.low => 96000,
      AudioQualityPreference.normal => 160000,
      AudioQualityPreference.high => 320000,
      AudioQualityPreference.veryHigh => null,
    };
  }

  Future<List<_PlaybackDownloadSource>> _resolvePlaybackDownloadSources(
    String videoId,
  ) async {
    final manifest = await _getManifestWithRetry(videoId);
    final sources = <_PlaybackDownloadSource>[];
    final seen = <String>{};

    final audioStreams = manifest.audioOnly.toList();
    if (audioStreams.isNotEmpty) {
      for (final stream in _prioritizeAudioStreams(audioStreams)) {
        final url = stream.url.toString();
        if (!seen.add(url)) continue;
        sources.add(_PlaybackDownloadSource(url: url, isVideoSource: false));
      }
    }

    final muxedStreams = manifest.muxed.toList();
    if (muxedStreams.isNotEmpty) {
      for (final stream in _prioritizeMuxedStreams(muxedStreams)) {
        final url = stream.url.toString();
        if (!seen.add(url)) continue;
        sources.add(_PlaybackDownloadSource(url: url, isVideoSource: true));
      }
    }

    if (sources.isEmpty) {
      throw Exception('No hay streams disponibles para descargar.');
    }
    return sources;
  }

  List<MuxedStreamInfo> _prioritizeMuxedStreams(List<MuxedStreamInfo> streams) {
    final targetHeight = _targetVideoHeightForCurrentQuality();
    final sortedByQuality = [...streams]
      ..sort((a, b) {
        final aHeight = a.videoResolution.height;
        final bHeight = b.videoResolution.height;

        if (targetHeight == null) {
          final heightCompare = bHeight.compareTo(aHeight);
          if (heightCompare != 0) return heightCompare;
        } else {
          final aWithinTarget = aHeight <= targetHeight;
          final bWithinTarget = bHeight <= targetHeight;
          if (aWithinTarget != bWithinTarget) {
            return aWithinTarget ? -1 : 1;
          }
          if (aWithinTarget) {
            final heightCompare = bHeight.compareTo(aHeight);
            if (heightCompare != 0) return heightCompare;
          } else {
            final heightCompare = aHeight.compareTo(bHeight);
            if (heightCompare != 0) return heightCompare;
          }
        }

        final frameRateCompare = b.videoQuality.index.compareTo(
          a.videoQuality.index,
        );
        if (frameRateCompare != 0) return frameRateCompare;
        return b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond);
      });

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

  int? _targetVideoHeightForCurrentQuality() {
    return switch (_settingsService.audioQuality) {
      AudioQualityPreference.low => 240,
      AudioQualityPreference.normal => 420,
      AudioQualityPreference.high => 720,
      AudioQualityPreference.veryHigh => null,
      AudioQualityPreference.automatic => 420,
    };
  }

  String _inferFileExtension(String sourceUrl, {String fallback = 'm4a'}) {
    final localExtension = p
        .extension(sourceUrl)
        .replaceFirst('.', '')
        .toLowerCase();
    if (_isSafeExtension(localExtension)) return localExtension;

    try {
      final uri = Uri.parse(sourceUrl);
      final remoteExtension = p
          .extension(uri.path)
          .replaceFirst('.', '')
          .toLowerCase();
      if (_isSafeExtension(remoteExtension)) return remoteExtension;
    } catch (_) {
      // Ignorado, se usa fallback
    }

    return fallback;
  }

  bool _isSafeExtension(String ext) {
    if (ext.isEmpty) return false;
    if (ext.length > 5) return false;
    const allowed = {'m4a', 'mp4', 'webm', 'mp3', 'aac', 'ogg'};
    return allowed.contains(ext);
  }

  Future<void> _downloadFromDirectUrl({
    required String sourceUrl,
    required String targetPath,
    required String videoId,
  }) async {
    await _dio.download(
      sourceUrl,
      targetPath,
      options: Options(
        headers: _youtubeHeaders,
        responseType: ResponseType.bytes,
        followRedirects: true,
        receiveTimeout: const Duration(minutes: 3),
        sendTimeout: const Duration(minutes: 1),
      ),
      onReceiveProgress: (received, total) {
        if (total > 0) {
          _downloadProgress[videoId] = received / total;
          notifyListeners();
        }
      },
    );
  }

  Future<void> _downloadFromManifestFallback({
    required String videoId,
    required bool isVideoSource,
    required String targetPath,
  }) async {
    final manifest = await _getManifestWithRetry(videoId);
    final streamInfo = isVideoSource
        ? _prioritizeMuxedStreams(manifest.muxed.toList()).first
        : _prioritizeAudioStreams(manifest.audioOnly.toList()).first;

    final file = File(targetPath);
    if (await file.exists()) {
      await file.delete();
    }

    final output = file.openWrite();
    final stream = _yt.videos.streamsClient.get(streamInfo);
    final totalBytes = streamInfo.size.totalBytes;
    var receivedBytes = 0;

    await for (final chunk in stream) {
      output.add(chunk);
      receivedBytes += chunk.length;
      if (totalBytes > 0) {
        _downloadProgress[videoId] = receivedBytes / totalBytes;
        notifyListeners();
      }
    }

    await output.flush();
    await output.close();
  }

  Future<StreamManifest> _getManifestWithRetry(String videoId) async {
    final cached = _manifestCache[videoId];
    if (cached != null) return cached;
    final inFlight = _manifestRequests[videoId];
    if (inFlight != null) return inFlight;

    final future = _runYoutubeWithRetry(
      () => _yt.videos.streamsClient.getManifest(videoId),
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

  Future<T> _runYoutubeWithRetry<T>(
    Future<T> Function() action, {
    int maxAttempts = 3,
  }) async {
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        await _youtubeGuard.waitForSlot();
        return await action();
      } on RequestLimitExceededException catch (e) {
        lastError = e;
        _youtubeGuard.activateSlowMode(
          Duration(seconds: 35 + (attempt * 18)),
        );
      } on SocketException catch (e) {
        lastError = e;
      } on HttpException catch (e) {
        lastError = e;
      } catch (e) {
        lastError = e;
        if (_youtubeGuard.isRateLimitError(e)) {
          _youtubeGuard.activateSlowMode(
            Duration(seconds: 35 + (attempt * 18)),
          );
        }
      }

      if (attempt < maxAttempts) {
        final delay = _youtubeGuard.retryDelay(
          attempt: attempt,
          lastError: lastError,
        );
        await Future<void>.delayed(delay);
      }
    }
    throw lastError ?? Exception('Error desconocido al contactar YouTube');
  }

  String _toUserFriendlyDownloadError(Object error) {
    if (error is RequestLimitExceededException) {
      return 'No se pudo descargar en este momento. Intenta nuevamente más tarde.';
    }
    if (error is SocketException || error is HttpException) {
      return 'No hay conexión estable para descargar. Verifica tu internet e intenta de nuevo.';
    }
    return 'No se pudo completar la descarga.';
  }

  Future<LyricsResult?> _fetchLyricsSafe({
    required String title,
    required String artist,
  }) async {
    try {
      return await _lyricsService.fetchLyrics(title: title, artist: artist);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _downloadThumbnailSafe({
    required String videoId,
    required String thumbnailUrl,
  }) async {
    final urls = buildThumbnailCandidates(
      videoId: videoId,
      thumbnailUrl: thumbnailUrl.trim(),
    );
    if (urls.isEmpty) return null;

    try {
      final appDir = await getApplicationDocumentsDirectory();
      for (final url in urls) {
        final ext = _inferThumbnailExtension(url);
        final targetPath = '${appDir.path}/${videoId}_thumb.$ext';
        final file = File(targetPath);
        if (await file.exists()) {
          await file.delete();
        }
        try {
          await _dio.download(
            url,
            targetPath,
            options: Options(
              headers: _youtubeHeaders,
              followRedirects: true,
              receiveTimeout: const Duration(seconds: 25),
              sendTimeout: const Duration(seconds: 10),
            ),
          );
          final downloaded = File(targetPath);
          if (await downloaded.exists() && await downloaded.length() > 0) {
            return targetPath;
          }
        } catch (_) {
          if (await file.exists()) {
            await file.delete();
          }
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  String _inferThumbnailExtension(String url) {
    try {
      final uri = Uri.parse(url);
      final ext = p.extension(uri.path).replaceFirst('.', '').toLowerCase();
      const allowed = {'jpg', 'jpeg', 'png', 'webp'};
      if (allowed.contains(ext)) return ext == 'jpeg' ? 'jpg' : ext;
    } catch (_) {}
    return 'jpg';
  }
}
