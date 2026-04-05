import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:myapp/models/downloaded_video.dart';
import 'package:myapp/models/video_history.dart';
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

class DownloadService with ChangeNotifier {
  static const String _downloadsBoxName = 'downloads';
  static const String _autoDownloadBoxName = 'auto_download_playlists';
  final YoutubeExplode _yt = YoutubeExplode();
  final Dio _dio = Dio();
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

  Future<Box<DownloadedVideo>> get _downloadsBox async => await Hive.openBox<DownloadedVideo>(_downloadsBoxName);
  Future<Box<String>> get _autoDownloadBox async => await Hive.openBox<String>(_autoDownloadBoxName);

  DownloadService() {
    _loadAutoDownloadPlaylists();
    loadDownloadedVideos();
  }

  Future<void> _loadAutoDownloadPlaylists() async {
    final box = await _autoDownloadBox;
    _autoDownloadPlaylists = box.values.toSet();
    notifyListeners();
  }

  Future<void> setPlaylistAutoDownload(String playlistName, bool enabled) async {
    final box = await _autoDownloadBox;
    if (enabled) {
      await box.put(playlistName, playlistName);
      _autoDownloadPlaylists.add(playlistName);
    } else {
      await box.delete(playlistName);
      _autoDownloadPlaylists.remove(playlistName);
    }
    notifyListeners();
  }

  bool isPlaylistAutoDownload(String playlistName) {
    return _autoDownloadPlaylists.contains(playlistName);
  }

  Future<PlaylistDownloadSummary> downloadPlaylistVideos(List<VideoHistory> videos) async {
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
        downloadVideo(
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

  Future<List<DownloadedVideo>> getDownloadedVideos() async {
    final box = await _downloadsBox;
    return box.values.toList();
  }

  Future<bool> downloadVideo(String videoId, String title, String thumbnailUrl, String channelTitle) async {
    final existing = await getDownloadedVideoById(videoId);
    if (_downloadStatus[videoId] == DownloadStatus.downloading || existing != null) {
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
          if (!await downloadedFile.exists() || await downloadedFile.length() == 0) {
            throw Exception('Archivo descargado vacío');
          }

          successfulPath = filePath;
          break;
        } catch (e) {
          lastError = e;
          if (await file.exists()) {
            await file.delete();
          }
        }
      }

      if (successfulPath == null) {
        throw Exception('No se pudo descargar con ningún stream: $lastError');
      }

      final downloadedVideo = DownloadedVideo(
        videoId: videoId,
        title: title,
        thumbnailUrl: thumbnailUrl,
        channelTitle: channelTitle,
        filePath: successfulPath,
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

  Future<bool> downloadFromPlaybackSource({
    required String videoId,
    required String title,
    required String thumbnailUrl,
    required String channelTitle,
    required String sourceUrl,
    bool isVideoSource = false,
  }) async {
    final existing = await getDownloadedVideoById(videoId);
    if (_downloadStatus[videoId] == DownloadStatus.downloading || existing != null) {
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

      final downloadedVideo = DownloadedVideo(
        videoId: videoId,
        title: title,
        thumbnailUrl: thumbnailUrl,
        channelTitle: channelTitle,
        filePath: targetPath,
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

  double getDownloadProgress(String videoId) {
    return _downloadProgress[videoId] ?? 0.0;
  }

  String? getDownloadError(String videoId) {
    return _downloadErrors[videoId];
  }

  Future<void> loadDownloadedVideos() async {
    final box = await _downloadsBox;
    final videos = box.values;
    for (var video in videos) {
      final fileExists = await File(video.filePath).exists();
      if (fileExists) {
        _downloadStatus[video.videoId] = DownloadStatus.downloaded;
        _downloadErrors.remove(video.videoId);
      } else {
        await box.delete(video.videoId);
        _downloadStatus.remove(video.videoId);
        _downloadErrors.remove(video.videoId);
      }
    }
    notifyListeners();
  }

  Future<DownloadedVideo?> getDownloadedVideoById(String videoId) async {
    final box = await _downloadsBox;
    final downloaded = box.get(videoId);
    if (downloaded == null) return null;

    final file = File(downloaded.filePath);
    if (!await file.exists()) {
      await box.delete(videoId);
      _downloadStatus.remove(videoId);
      _downloadErrors.remove(videoId);
      notifyListeners();
      return null;
    }
    return downloaded;
  }

  Future<bool> isVideoDownloaded(String videoId) async {
    final downloaded = await getDownloadedVideoById(videoId);
    return downloaded != null;
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

  String _inferFileExtension(String sourceUrl, {String fallback = 'm4a'}) {
    final localExtension = p.extension(sourceUrl).replaceFirst('.', '').toLowerCase();
    if (_isSafeExtension(localExtension)) return localExtension;

    try {
      final uri = Uri.parse(sourceUrl);
      final remoteExtension = p.extension(uri.path).replaceFirst('.', '').toLowerCase();
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
        ? manifest.muxed.sortByBitrate().last
        : manifest.audioOnly.sortByBitrate().last;

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

  String _toUserFriendlyDownloadError(Object error) {
    if (error is RequestLimitExceededException) {
      return 'No se pudo descargar en este momento. Intenta nuevamente más tarde.';
    }
    if (error is SocketException || error is HttpException) {
      return 'No hay conexión estable para descargar. Verifica tu internet e intenta de nuevo.';
    }
    return 'No se pudo completar la descarga.';
  }
}
