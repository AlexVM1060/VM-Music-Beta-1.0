import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:myapp/models/video_history.dart';
import 'package:myapp/services/apple_music_library_service.dart';
import 'package:myapp/services/playlist_service.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class AppleMusicPlaylistMigrationProgress {
  final int playlistIndex;
  final int playlistTotal;
  final String playlistName;
  final int trackIndex;
  final int trackTotal;
  final String trackTitle;

  const AppleMusicPlaylistMigrationProgress({
    required this.playlistIndex,
    required this.playlistTotal,
    required this.playlistName,
    required this.trackIndex,
    required this.trackTotal,
    required this.trackTitle,
  });
}

class AppleMusicPlaylistMigrationItemResult {
  final String sourcePlaylistName;
  final String targetPlaylistName;
  final int sourceTrackCount;
  final int importedCount;

  const AppleMusicPlaylistMigrationItemResult({
    required this.sourcePlaylistName,
    required this.targetPlaylistName,
    required this.sourceTrackCount,
    required this.importedCount,
  });
}

class AppleMusicPlaylistMigrationResult {
  final List<AppleMusicPlaylistMigrationItemResult> playlists;
  final int totalTracks;
  final int importedTracks;

  const AppleMusicPlaylistMigrationResult({
    required this.playlists,
    required this.totalTracks,
    required this.importedTracks,
  });
}

class AppleMusicPlaylistMigrationService {
  final PlaylistService _playlistService;
  final AppleMusicLibraryService _appleMusicService;
  YoutubeExplode _yt = YoutubeExplode();
  final Map<String, Video?> _queryCache = <String, Video?>{};
  DateTime? _lastSearchAt;
  static const Duration _baseSearchGap = Duration(milliseconds: 1100);

  AppleMusicPlaylistMigrationService({
    required PlaylistService playlistService,
    required AppleMusicLibraryService appleMusicService,
  }) : _playlistService = playlistService,
       _appleMusicService = appleMusicService;

  Future<AppleMusicPlaylistMigrationResult> migrateSelectedPlaylists({
    required List<AppleMusicLibraryPlaylist> selectedPlaylists,
    Future<void> Function(AppleMusicPlaylistMigrationProgress progress)?
    onProgress,
  }) async {
    final prepared = selectedPlaylists
        .where((playlist) => playlist.id.trim().isNotEmpty)
        .toList(growable: false);
    if (prepared.isEmpty) {
      return const AppleMusicPlaylistMigrationResult(
        playlists: [],
        totalTracks: 0,
        importedTracks: 0,
      );
    }

    final existingNames = (await _playlistService.getPlaylists())
        .map((playlist) => playlist.name.toLowerCase())
        .toSet();

    final playlistResults = <AppleMusicPlaylistMigrationItemResult>[];
    var totalTracks = 0;
    var importedTracks = 0;

    for (var p = 0; p < prepared.length; p++) {
      final sourcePlaylist = prepared[p];
      final sourceTracks = await _appleMusicService.fetchPlaylistTracks(
        sourcePlaylist.id,
      );
      totalTracks += sourceTracks.length;

      final targetName = _resolveUniquePlaylistName(
        sourceName: sourcePlaylist.name,
        existingLowercaseNames: existingNames,
      );
      await _playlistService.createPlaylist(targetName);
      existingNames.add(targetName.toLowerCase());

      var importedInPlaylist = 0;
      for (var t = 0; t < sourceTracks.length; t++) {
        final track = sourceTracks[t];
        if (onProgress != null) {
          await onProgress(
            AppleMusicPlaylistMigrationProgress(
              playlistIndex: p + 1,
              playlistTotal: prepared.length,
              playlistName: sourcePlaylist.name,
              trackIndex: t + 1,
              trackTotal: sourceTracks.length,
              trackTitle: track.title,
            ),
          );
        }

        final match = await _findBestYoutubeMatch(track);
        if (match == null) continue;
        final thumbnailUrl = _bestThumbnailFromSearchVideo(match);
        await _playlistService.addVideoToPlaylist(
          targetName,
          VideoHistory(
            videoId: match.id.value,
            title: match.title,
            thumbnailUrl: thumbnailUrl,
            channelTitle: match.author,
            watchedAt: DateTime.now(),
          ),
        );
        importedInPlaylist += 1;
        importedTracks += 1;
      }

      playlistResults.add(
        AppleMusicPlaylistMigrationItemResult(
          sourcePlaylistName: sourcePlaylist.name,
          targetPlaylistName: targetName,
          sourceTrackCount: sourceTracks.length,
          importedCount: importedInPlaylist,
        ),
      );
    }

    return AppleMusicPlaylistMigrationResult(
      playlists: playlistResults,
      totalTracks: totalTracks,
      importedTracks: importedTracks,
    );
  }

  Future<Video?> _findBestYoutubeMatch(AppleMusicLibraryTrack track) async {
    final query = '${track.title} ${track.artist}'.trim();
    if (query.isEmpty) return null;
    final cacheKey = query.toLowerCase();
    if (_queryCache.containsKey(cacheKey)) {
      return _queryCache[cacheKey];
    }

    final queries = _buildMusicFocusedQueries(track);
    final collected = <Video>[];
    final seenIds = <String>{};
    for (final q in queries) {
      final results = await _searchVideosWithRetry(q);
      for (final item in results) {
        if (seenIds.add(item.id.value)) {
          collected.add(item);
        }
      }
      if (collected.length >= 14) break;
    }

    if (collected.isEmpty) {
      _queryCache[cacheKey] = null;
      return null;
    }

    final autoGeneratedOnly = collected
        .where((video) => _isAutoGeneratedMusicCandidate(video))
        .toList(growable: false);
    if (autoGeneratedOnly.isEmpty) {
      _queryCache[cacheKey] = null;
      return null;
    }

    final ranked = autoGeneratedOnly.toList(growable: true)
      ..sort(
        (a, b) =>
            _scoreSearchVideo(b, track).compareTo(_scoreSearchVideo(a, track)),
      );
    final best = ranked.first;
    _queryCache[cacheKey] = best;
    return best;
  }

  List<String> _buildMusicFocusedQueries(AppleMusicLibraryTrack track) {
    final base = '${track.title} ${track.artist}'
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final set = <String>{
      '$base provided to youtube by',
      '$base auto-generated by youtube',
      '$base topic',
      base,
    };
    return set.where((q) => q.isNotEmpty).take(4).toList(growable: false);
  }

  Future<List<Video>> _searchVideosWithRetry(
    String query, {
    int maxAttempts = 4,
  }) async {
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        await _waitSearchSlot(attempt: attempt);
        final stream = await _yt.search
            .search(query)
            .timeout(const Duration(seconds: 20));
        return stream.take(8).toList();
      } on RequestLimitExceededException catch (e) {
        lastError = e;
        await _resetClient();
      } on SocketException catch (e) {
        lastError = e;
      } on TimeoutException catch (e) {
        lastError = e;
      } catch (e) {
        lastError = e;
        if (_looksLikeYoutubeAbuseRedirect(e)) {
          await _resetClient();
        }
      }

      if (attempt < maxAttempts) {
        final backoff = Duration(
          milliseconds: (1200 * attempt) + math.Random().nextInt(900),
        );
        await Future<void>.delayed(backoff);
      }
    }
    if (lastError != null && _looksLikeYoutubeAbuseRedirect(lastError)) {
      return const [];
    }
    return const [];
  }

  Future<void> _waitSearchSlot({required int attempt}) async {
    final now = DateTime.now();
    final previous = _lastSearchAt;
    var effectiveGap = _baseSearchGap;
    if (attempt > 1) {
      effectiveGap += Duration(milliseconds: attempt * 380);
    }
    if (previous != null) {
      final elapsed = now.difference(previous);
      if (elapsed < effectiveGap) {
        await Future<void>.delayed(effectiveGap - elapsed);
      }
    }
    final jitter = 120 + math.Random().nextInt(420);
    await Future<void>.delayed(Duration(milliseconds: jitter));
    _lastSearchAt = DateTime.now();
  }

  bool _looksLikeYoutubeAbuseRedirect(Object error) {
    final msg = error.toString().toLowerCase();
    return msg.contains('redirect limit exceeded') ||
        msg.contains('google_abuse') ||
        msg.contains('www.youtube.com/sorry') ||
        msg.contains('abuse');
  }

  Future<void> _resetClient() async {
    try {
      _yt.close();
    } catch (_) {}
    _yt = YoutubeExplode();
  }

  int _scoreSearchVideo(Video video, AppleMusicLibraryTrack track) {
    final title = video.title.toLowerCase();
    final author = video.author.toLowerCase();
    final description = video.description.toLowerCase();
    final text = '$title $author $description';
    final requestedTitle = track.title.toLowerCase();
    final requestedArtist = track.artist.toLowerCase();
    var score = 0;

    if (_isTopicAuthor(author)) score += 280;
    if (_hasAutoGeneratedSignal(video)) score += 220;
    if (title.contains(requestedTitle)) score += 120;
    if (author.contains(requestedArtist)) score += 90;

    final titleTokens = _tokens(requestedTitle);
    final artistTokens = _tokens(requestedArtist);
    for (final token in titleTokens) {
      if (title.contains(token)) score += 16;
    }
    for (final token in artistTokens) {
      if (author.contains(token) || title.contains(token)) score += 14;
    }

    const badKeywords = [
      'live',
      'karaoke',
      'remix',
      'cover',
      '8d',
      'slowed',
      'reverb',
    ];
    for (final bad in badKeywords) {
      if (title.contains(bad)) score -= 22;
    }
    if (_videoLikeKeywords.any(text.contains)) {
      score -= 250;
    }

    return score;
  }

  bool _isAutoGeneratedMusicCandidate(Video video) {
    final author = video.author.toLowerCase().trim();
    if (_isBlockedAuthor(author)) return false;

    final title = video.title.toLowerCase();
    final description = video.description.toLowerCase();
    final text = '$title $author $description';
    final topic = _isTopicAuthor(author);
    final autoGenerated = _hasAutoGeneratedSignal(video);
    final hasVideoLikeSignal = _videoLikeKeywords.any(text.contains);
    return (topic || autoGenerated) && !hasVideoLikeSignal;
  }

  bool _hasAutoGeneratedSignal(Video video) {
    final title = video.title.toLowerCase();
    final description = video.description.toLowerCase();
    return _autoGeneratedKeywords.any((keyword) {
      return title.contains(keyword) || description.contains(keyword);
    });
  }

  bool _isTopicAuthor(String authorLower) {
    final author = authorLower.trim();
    return author.endsWith('- topic') || author.endsWith('topic');
  }

  bool _isBlockedAuthor(String authorLower) {
    final author = authorLower.trim();
    return author == 'release - topic' || author == 'release topic';
  }

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
    'lyrics',
    'lyric',
  ];

  Iterable<String> _tokens(String text) {
    return text
        .split(RegExp(r'\s+'))
        .map((token) => token.trim())
        .where((token) => token.length >= 3);
  }

  String _bestThumbnailFromSearchVideo(Video video) {
    if (video.thumbnails.highResUrl.isNotEmpty) {
      return video.thumbnails.highResUrl;
    }
    if (video.thumbnails.mediumResUrl.isNotEmpty) {
      return video.thumbnails.mediumResUrl;
    }
    if (video.thumbnails.lowResUrl.isNotEmpty) {
      return video.thumbnails.lowResUrl;
    }
    return 'https://i.ytimg.com/vi/${video.id.value}/hqdefault.jpg';
  }

  String _resolveUniquePlaylistName({
    required String sourceName,
    required Set<String> existingLowercaseNames,
  }) {
    final trimmed = sourceName.trim();
    final base = trimmed.isEmpty ? 'Apple Music importada' : trimmed;
    if (!existingLowercaseNames.contains(base.toLowerCase())) return base;

    final withSuffix = '$base (Apple Music)';
    if (!existingLowercaseNames.contains(withSuffix.toLowerCase())) {
      return withSuffix;
    }

    var i = 2;
    while (true) {
      final candidate = '$withSuffix $i';
      if (!existingLowercaseNames.contains(candidate.toLowerCase())) {
        return candidate;
      }
      i += 1;
    }
  }

  void dispose() {
    _yt.close();
  }
}
