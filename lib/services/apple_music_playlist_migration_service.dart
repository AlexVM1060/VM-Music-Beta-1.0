import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
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
  final MethodChannel _backgroundTaskChannel = const MethodChannel(
    'com.vm.music.beta/background_task',
  );
  DateTime? _lastSearchAt;
  Future<void> _searchSlotTail = Future<void>.value();
  static const Duration _baseSearchGap = Duration(milliseconds: 260);
  static const int _maxTrackWorkers = 4;

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

    final taskToken = await _beginBackgroundTask();
    try {
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

        final matchedEntries = await _resolvePlaylistMatches(
          sourceTracks: sourceTracks,
          playlistIndex: p + 1,
          playlistTotal: prepared.length,
          playlistName: sourcePlaylist.name,
          onProgress: onProgress,
        );
        final importedInPlaylist = await _playlistService.addVideosToPlaylist(
          targetName,
          matchedEntries,
        );
        importedTracks += importedInPlaylist;

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
    } finally {
      await _endBackgroundTask(taskToken);
    }
  }

  Future<List<VideoHistory>> _resolvePlaylistMatches({
    required List<AppleMusicLibraryTrack> sourceTracks,
    required int playlistIndex,
    required int playlistTotal,
    required String playlistName,
    Future<void> Function(AppleMusicPlaylistMigrationProgress progress)?
    onProgress,
  }) async {
    if (sourceTracks.isEmpty) return const <VideoHistory>[];
    final results = List<VideoHistory?>.filled(sourceTracks.length, null);
    var cursor = 0;
    var processed = 0;

    Future<void> worker() async {
      while (true) {
        final index = cursor++;
        if (index >= sourceTracks.length) return;
        final track = sourceTracks[index];
        final match = await _findBestYoutubeMatch(track);
        if (match != null) {
          results[index] = VideoHistory(
            videoId: match.id.value,
            title: match.title,
            thumbnailUrl: _bestThumbnailFromSearchVideo(match),
            channelTitle: match.author,
            watchedAt: DateTime.now(),
          );
        }
        processed += 1;
        if (onProgress != null) {
          await onProgress(
            AppleMusicPlaylistMigrationProgress(
              playlistIndex: playlistIndex,
              playlistTotal: playlistTotal,
              playlistName: playlistName,
              trackIndex: processed,
              trackTotal: sourceTracks.length,
              trackTitle: track.title,
            ),
          );
        }
      }
    }

    final workers = math.min(_maxTrackWorkers, sourceTracks.length);
    await Future.wait(
      List<Future<void>>.generate(workers, (_) => worker(), growable: false),
    );
    return results.whereType<VideoHistory>().toList(growable: false);
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
      if (collected.length >= 30) break;
    }

    if (collected.isEmpty) {
      _queryCache[cacheKey] = null;
      return null;
    }

    final pureAutoGenerated = collected
        .where(_isPureYoutubeMusicAutoGeneratedResult)
        .toList(growable: false);
    if (pureAutoGenerated.isEmpty) {
      _queryCache[cacheKey] = null;
      return null;
    }

    final exactMatches = pureAutoGenerated
        .where((video) => _isExactTitleAndArtistMatch(video, track))
        .toList(growable: false);
    if (exactMatches.isEmpty) {
      _queryCache[cacheKey] = null;
      return null;
    }

    final ranked = exactMatches.toList(growable: true)
      ..sort((a, b) {
        final views = b.engagement.viewCount.compareTo(a.engagement.viewCount);
        if (views != 0) return views;
        return _tieBreakStrictMatchScore(
          b,
        ).compareTo(_tieBreakStrictMatchScore(a));
      });
    final best = ranked.first;
    _queryCache[cacheKey] = best;
    return best;
  }

  List<String> _buildMusicFocusedQueries(AppleMusicLibraryTrack track) {
    final title = track.title.replaceAll(RegExp(r'\s+'), ' ').trim();
    final artist = track.artist.replaceAll(RegExp(r'\s+'), ' ').trim();
    final base = '$title $artist'.replaceAll(RegExp(r'\s+'), ' ').trim();
    final set = <String>{
      if (title.isNotEmpty && artist.isNotEmpty) '"$title" "$artist"',
      if (title.isNotEmpty && artist.isNotEmpty) '$title - $artist',
      '$base topic',
      '$base provided to youtube by',
      '$base auto-generated by youtube',
      '$base audio',
      base,
    };
    return set.where((q) => q.isNotEmpty).take(5).toList(growable: false);
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
        return stream.take(12).toList();
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
    final previousTail = _searchSlotTail;
    final gate = Completer<void>();
    _searchSlotTail = gate.future;
    await previousTail;
    try {
      final now = DateTime.now();
      final previous = _lastSearchAt;
      var effectiveGap = _baseSearchGap;
      if (attempt > 1) {
        effectiveGap += Duration(milliseconds: attempt * 170);
      }
      if (previous != null) {
        final elapsed = now.difference(previous);
        if (elapsed < effectiveGap) {
          await Future<void>.delayed(effectiveGap - elapsed);
        }
      }
      final jitter = 20 + math.Random().nextInt(90);
      await Future<void>.delayed(Duration(milliseconds: jitter));
      _lastSearchAt = DateTime.now();
    } finally {
      gate.complete();
    }
  }

  Future<String?> _beginBackgroundTask() async {
    if (!Platform.isIOS) return null;
    try {
      return await _backgroundTaskChannel.invokeMethod<String>(
        'beginTask',
        <String, dynamic>{'name': 'apple_music_migration'},
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _endBackgroundTask(String? token) async {
    if (!Platform.isIOS || token == null || token.isEmpty) return;
    try {
      await _backgroundTaskChannel.invokeMethod<void>(
        'endTask',
        <String, dynamic>{'token': token},
      );
    } catch (_) {}
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

  bool _isExactTitleAndArtistMatch(Video video, AppleMusicLibraryTrack track) {
    final expectedTitle = _normalizeSongTitle(track.title);
    final expectedArtist = _normalizeArtist(track.artist);
    if (expectedTitle.isEmpty || expectedArtist.isEmpty) return false;

    final titleMatches = _candidateSongTitles(
      video.title,
    ).any((candidate) => _isEquivalentNormalized(candidate, expectedTitle));
    if (!titleMatches) return false;

    final artistCandidates = <String>{..._candidateArtistNames(video.author)};
    return artistCandidates.any(
      (candidate) => _isEquivalentNormalized(candidate, expectedArtist),
    );
  }

  int _tieBreakStrictMatchScore(Video video) {
    final author = video.author.toLowerCase();
    final title = video.title.toLowerCase();
    var score = 0;
    if (author.endsWith(' - topic') || author.endsWith(' topic')) {
      score += 3;
    }
    if (_isAutoGeneratedVideo(video)) score += 3;
    if (title.contains('official audio')) score += 2;
    if (title.contains('official video')) score -= 1;
    return score;
  }

  bool _isPureYoutubeMusicAutoGeneratedResult(Video video) {
    final author = video.author.toLowerCase().trim();
    if (_isBlockedSearchAuthor(author)) return false;
    final title = video.title.toLowerCase();
    final description = video.description.toLowerCase();
    final text = '$title $author $description';
    final topic = _isTopicVideo(video);
    final autoGenerated = _isAutoGeneratedVideo(video);
    final hasVideoLikeSignal = _searchVideoLikeKeywords.any(text.contains);
    return (topic || autoGenerated) && !hasVideoLikeSignal;
  }

  bool _isTopicVideo(Video video) {
    final author = video.author.toLowerCase().trim();
    return author.endsWith('- topic') || author.endsWith('topic');
  }

  bool _isAutoGeneratedVideo(Video video) {
    final title = video.title.toLowerCase();
    final description = video.description.toLowerCase();
    return _searchAutoGeneratedKeywords.any((keyword) {
      return title.contains(keyword) || description.contains(keyword);
    });
  }

  bool _isBlockedSearchAuthor(String authorLower) {
    final author = authorLower.trim();
    return author == 'release - topic' || author == 'release topic';
  }

  static const List<String> _searchAutoGeneratedKeywords = [
    'provided to youtube by',
    'auto-generated by youtube',
  ];

  static const List<String> _searchVideoLikeKeywords = [
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

  Iterable<String> _candidateSongTitles(String rawTitle) {
    final output = <String>{};
    void add(String value) {
      final normalized = _normalizeSongTitle(value);
      if (normalized.isNotEmpty) output.add(normalized);
    }

    add(rawTitle);
    final compactTitle = rawTitle.replaceAll(RegExp(r'\[[^\]]*\]'), ' ');
    add(compactTitle);

    final parts = rawTitle
        .split(RegExp(r'\s[-–—:]\s'))
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    for (final part in parts) {
      add(part);
    }
    if (parts.length >= 2) {
      add(parts.last);
      add(parts.first);
      add(parts.sublist(1).join(' '));
    }
    return output;
  }

  Iterable<String> _candidateArtistNames(String rawArtist) {
    final output = <String>{};
    void add(String value) {
      final normalized = _normalizeArtist(value);
      if (normalized.isNotEmpty) output.add(normalized);
    }

    add(rawArtist);
    final split = rawArtist
        .split(RegExp(r'\s[-–—:]\s'))
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    if (split.isNotEmpty) {
      add(split.first);
      add(split.last);
    }
    add(
      rawArtist.replaceAll(
        RegExp(r'\b(topic|official|vevo)\b', caseSensitive: false),
        ' ',
      ),
    );
    return output;
  }

  String _normalizeSongTitle(String input) {
    var value = input.toLowerCase().trim();
    value = value.replaceAll(RegExp(r'\[[^\]]*\]'), ' ');
    value = value.replaceAll(RegExp(r'\([^)]*\)'), ' ');
    value = value.replaceAll(RegExp(r'\{[^}]*\}'), ' ');
    value = value.replaceAll(RegExp(r'\b(feat\.?|ft\.?|featuring)\b.*$'), ' ');
    value = value.replaceAll(
      RegExp(
        r'\b(official|audio|video|lyric|lyrics|visualizer|mv|hd|4k|remaster(?:ed)?|topic)\b',
      ),
      ' ',
    );
    return _normalizeLooseText(value);
  }

  String _normalizeArtist(String input) {
    var value = input.toLowerCase().trim();
    value = value.replaceAll(RegExp(r'\[[^\]]*\]'), ' ');
    value = value.replaceAll(RegExp(r'\([^)]*\)'), ' ');
    value = value.replaceAll(
      RegExp(r'\b(topic|official|vevo|channel|records)\b'),
      ' ',
    );
    return _normalizeLooseText(value);
  }

  String _normalizeLooseText(String input) {
    var value = input.toLowerCase();
    _accentFoldMap.forEach((from, to) {
      value = value.replaceAll(from, to);
    });
    value = value.replaceAll('&', ' and ');
    value = value.replaceAll(RegExp(r'[^a-z0-9]+'), ' ');
    return value.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  bool _isEquivalentNormalized(String left, String right) {
    if (left == right) return true;
    return left.replaceAll(' ', '') == right.replaceAll(' ', '');
  }

  static const Map<String, String> _accentFoldMap = {
    'á': 'a',
    'à': 'a',
    'ä': 'a',
    'â': 'a',
    'ã': 'a',
    'å': 'a',
    'é': 'e',
    'è': 'e',
    'ë': 'e',
    'ê': 'e',
    'í': 'i',
    'ì': 'i',
    'ï': 'i',
    'î': 'i',
    'ó': 'o',
    'ò': 'o',
    'ö': 'o',
    'ô': 'o',
    'õ': 'o',
    'ú': 'u',
    'ù': 'u',
    'ü': 'u',
    'û': 'u',
    'ñ': 'n',
    'ç': 'c',
  };

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
