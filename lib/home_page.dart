import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter, Rect;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:hive/hive.dart';
import 'package:myapp/models/downloaded_video.dart';
import 'package:myapp/models/video_history.dart';
import 'package:myapp/services/app_lifecycle_service.dart';
import 'package:myapp/services/app_settings_service.dart';
import 'package:myapp/services/download_service.dart';
import 'package:myapp/services/history_service.dart';
import 'package:myapp/services/playlist_service.dart';
import 'package:myapp/search_page.dart';
import 'package:myapp/utils/artist_name_utils.dart';
import 'package:myapp/utils/thumbnail_quality.dart';
import 'package:myapp/video_player_manager.dart';
import 'package:myapp/widgets/playlist_picker_sheet.dart';
import 'package:myapp/widgets/queue_swipe_action_button.dart';
import 'package:myapp/widgets/square_thumbnail.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const String _homeCacheBoxName = 'home_cache';
  static const String _trendingCacheKey = 'mx_trending_topic_v2';
  static const String _curatedShelvesCacheKey = 'curated_music_shelves_v3';
  static const Duration _trendingCacheTtl = Duration(hours: 6);
  static const Duration _curatedShelvesCacheTtl = Duration(hours: 4);
  final YoutubeExplode _yt = YoutubeExplode();
  late Future<_HomeContent> _contentFuture;
  late Future<List<_HomeTrack>> _trendingFuture;
  final Map<String, _HomeResolvedAlbumRef> _albumRefByVideoIdCache = {};
  final Map<String, Future<_HomeResolvedAlbumRef?>> _albumRefByVideoIdInFlight = {};

  @override
  void initState() {
    super.initState();
    _contentFuture = _loadContent();
    _trendingFuture = _loadTrendingTracks();
  }

  @override
  void dispose() {
    _yt.close();
    super.dispose();
  }

  Future<_HomeContent> _loadContent() async {
    final historyService = context.read<HistoryService>();
    final downloadService = context.read<DownloadService>();

    final history = await historyService.getHistory();
    final downloads = await downloadService.getDownloadedVideos();
    final downloadsById = <String, DownloadedVideo>{
      for (final item in downloads) item.videoId: item,
    };
    final trendingSeed = await _readTrendingCache();
    final searchSeed = await _loadSearchStyleRecommendationSeed(history);
    final curatedShelves = await _loadCuratedShelves(history);

    final suggestions = _buildSuggestions(
      history: history,
      downloads: downloads,
      trendingSeed: trendingSeed,
      searchSeed: searchSeed,
    );
    final relisten = history
        .take(20)
        .map((item) => _homeTrackFromHistory(item, downloadsById))
        .toList(growable: false);
    final mixes = _buildDailyMixes(
      suggestions: suggestions,
      relisten: relisten,
      trendingSeed: trendingSeed,
      searchSeed: searchSeed,
    );
    return _HomeContent(
      suggestions: suggestions,
      relisten: relisten,
      mixes: mixes,
      curatedShelves: curatedShelves,
    );
  }

  Future<List<_HomeShelf>> _loadCuratedShelves(List<VideoHistory> history) async {
    final cached = await _readCuratedShelvesCache();
    if (cached.isNotEmpty) return cached;

    final shelves = <_HomeShelf>[];
    final quickPicks = await _buildQuickPicksShelf(history);
    if (quickPicks.tracks.isNotEmpty) shelves.add(quickPicks);

    final fetched = await Future.wait([
      _buildShelfFromSeed(
        const _ShelfSeed(
          id: 'trending_community',
          title: 'Trending community playlists',
          subtitle: 'Playlists y mixes que están subiendo',
          query: 'youtube music community playlist trending mix',
        ),
      ),
      _buildShelfFromSeed(
        const _ShelfSeed(
          id: 'throwback_jams',
          title: 'Throwback jams',
          subtitle: 'Clásicos para volver a poner en repeat',
          query: 'throwback jams 2000s 2010s topic',
        ),
      ),
      _buildShelfFromSeed(
        const _ShelfSeed(
          id: 'top_mexico',
          title: 'Top México',
          subtitle: 'Canciones destacadas de México ahora',
          query: 'top mexico songs youtube music topic',
        ),
      ),
      _buildShelfFromSeed(
        const _ShelfSeed(
          id: 'top_global',
          title: 'Top Global',
          subtitle: 'Lo más escuchado alrededor del mundo',
          query: 'top global songs youtube music topic',
        ),
      ),
    ]);
    for (final shelf in fetched) {
      if (shelf.tracks.isNotEmpty) {
        shelves.add(shelf);
      }
    }
    if (shelves.isNotEmpty) {
      await _writeCuratedShelvesCache(shelves);
    }
    return shelves;
  }

  Future<_HomeShelf> _buildQuickPicksShelf(List<VideoHistory> history) async {
    final manager = context.read<VideoPlayerManager>();
    var queueItems = await manager.fetchQueueStyleRecommendations(limit: 26);
    if (queueItems.isEmpty && history.isNotEmpty) {
      final seed = history
          .map((item) => item.videoId.trim())
          .firstWhere((id) => id.isNotEmpty, orElse: () => '');
      if (seed.isNotEmpty) {
        queueItems = await manager.fetchQueueStyleRecommendations(
          limit: 26,
          seedVideoId: seed,
        );
      }
    }

    final tracks = <_HomeTrack>[];
    final seen = <String>{};
    for (final item in queueItems) {
      final id = item.videoId.trim();
      if (id.isEmpty || !seen.add(id)) continue;
      tracks.add(_HomeTrack.fromQueueItem(item));
      if (tracks.length >= 16) break;
    }

    return _HomeShelf(
      id: 'quick_picks',
      title: 'Quick picks',
      subtitle: 'Basado en lo que escuchas en YouTube Music',
      tracks: tracks,
    );
  }

  Future<_HomeShelf> _buildShelfFromSeed(_ShelfSeed seed) async {
    final tracks = <_HomeTrack>[];
    final seen = <String>{};
    try {
      final results = await _yt.search.search(seed.query);
      for (final video in results.take(44)) {
        if (!_isValidShelfTrack(video)) continue;
        final id = video.id.value.trim();
        if (id.isEmpty || !seen.add(id)) continue;
        tracks.add(_HomeTrack.fromVideo(video));
        if (tracks.length >= 14) break;
      }
    } catch (_) {
      // Best effort.
    }
    return _HomeShelf(
      id: seed.id,
      title: seed.title,
      subtitle: seed.subtitle,
      tracks: tracks,
    );
  }

  bool _isValidShelfTrack(Video video) {
    final title = video.title.toLowerCase();
    final author = video.author.toLowerCase();
    final description = video.description.toLowerCase();
    final blob = '$title $author $description';
    if (_shelfBlockedKeywords.any(blob.contains)) return false;
    if (_isPureYoutubeMusicAutoGenerated(video)) return true;
    if (_isBlockedSearchAuthor(video.author.toLowerCase())) return false;
    final text = '$title $description';
    final isVideoLike = _searchVideoLikeKeywords.any(text.contains);
    final isTopicAuthor = author.endsWith('- topic') || author.endsWith('topic');
    return !isVideoLike && isTopicAuthor;
  }

  static const List<String> _shelfBlockedKeywords = [
    'spotify',
    'deezer',
    'apple music',
    'amazon music',
    'tidal',
  ];

  Future<List<_HomeShelf>> _readCuratedShelvesCache() async {
    try {
      final box = await Hive.openBox<String>(_homeCacheBoxName);
      final raw = box.get(_curatedShelvesCacheKey);
      if (raw == null || raw.isEmpty) return const [];
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final updatedAtMs = (map['updatedAtMs'] as num?)?.toInt() ?? 0;
      if (updatedAtMs <= 0) return const [];
      final updatedAt = DateTime.fromMillisecondsSinceEpoch(updatedAtMs);
      if (DateTime.now().difference(updatedAt) > _curatedShelvesCacheTtl) {
        return const [];
      }

      final decodedShelves = (map['shelves'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((rawShelf) {
            final shelfMap = Map<String, dynamic>.from(
              rawShelf.cast<dynamic, dynamic>(),
            );
            final tracks = (shelfMap['tracks'] as List<dynamic>? ?? const [])
                .whereType<Map>()
                .map(
                  (trackRaw) => _HomeTrack(
                    videoId: (trackRaw['videoId'] ?? '').toString(),
                    title: (trackRaw['title'] ?? '').toString(),
                    artist: cleanArtistName((trackRaw['artist'] ?? '').toString()),
                    thumbnailUrl: (trackRaw['thumbnailUrl'] ?? '').toString(),
                    isLocal: false,
                  ),
                )
                .where((track) => track.videoId.isNotEmpty && track.title.isNotEmpty)
                .toList(growable: false);
            if (tracks.isEmpty) return null;
            return _HomeShelf(
              id: (shelfMap['id'] ?? '').toString(),
              title: (shelfMap['title'] ?? '').toString(),
              subtitle: (shelfMap['subtitle'] ?? '').toString(),
              tracks: tracks,
            );
          })
          .whereType<_HomeShelf>()
          .toList(growable: false);
      return decodedShelves;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _writeCuratedShelvesCache(List<_HomeShelf> shelves) async {
    try {
      final box = await Hive.openBox<String>(_homeCacheBoxName);
      final payload = jsonEncode({
        'updatedAtMs': DateTime.now().millisecondsSinceEpoch,
        'shelves': shelves
            .map(
              (shelf) => {
                'id': shelf.id,
                'title': shelf.title,
                'subtitle': shelf.subtitle,
                'tracks': shelf.tracks
                    .take(18)
                    .map(
                      (track) => {
                        'videoId': track.videoId,
                        'title': track.title,
                        'artist': track.artist,
                        'thumbnailUrl': track.thumbnailUrl,
                      },
                    )
                    .toList(growable: false),
              },
            )
            .toList(growable: false),
      });
      await box.put(_curatedShelvesCacheKey, payload);
    } catch (_) {
      // Best effort.
    }
  }

  _HomeTrack _homeTrackFromHistory(
    VideoHistory item,
    Map<String, DownloadedVideo> downloadsById,
  ) {
    final downloaded = downloadsById[item.videoId];
    if (downloaded == null) return _HomeTrack.fromHistory(item);

    final localThumbPath = downloaded.localThumbnailPath?.trim() ?? '';
    final localThumbExists =
        localThumbPath.isNotEmpty && File(localThumbPath).existsSync();
    return _HomeTrack(
      videoId: item.videoId,
      title: item.title,
      artist: cleanArtistName(item.channelTitle),
      thumbnailUrl: localThumbExists ? localThumbPath : downloaded.thumbnailUrl,
      isLocal: false,
    );
  }

  Future<List<_HomeTrack>> _loadSearchStyleRecommendationSeed(
    List<VideoHistory> history,
  ) async {
    final manager = context.read<VideoPlayerManager>();
    var queueItems = await manager.fetchQueueStyleRecommendations(limit: 20);
    if (queueItems.isEmpty) {
      final seed = history
          .map((item) => item.videoId.trim())
          .firstWhere((id) => id.isNotEmpty, orElse: () => '');
      if (seed.isNotEmpty) {
        queueItems = await manager.fetchQueueStyleRecommendations(
          limit: 20,
          seedVideoId: seed,
        );
      }
    }
    if (queueItems.isEmpty) return const <_HomeTrack>[];

    final output = <_HomeTrack>[];
    final seen = <String>{};
    for (final item in queueItems) {
      final id = item.videoId.trim();
      if (id.isEmpty || !seen.add(id)) continue;
      output.add(_HomeTrack.fromQueueItem(item));
      if (output.length >= 14) break;
    }
    return output;
  }

  Future<List<_HomeTrack>> _loadTrendingTracks() async {
    final cached = await _readTrendingCache();
    if (cached.isNotEmpty) {
      return cached;
    }

    const phaseQueries = <String>[
      'mexico top songs topic',
      'canciones en tendencia mexico topic',
      'regional mexicano topic',
      'corridos tumbados topic',
      'top latin mexico topic',
      'musica mexicana 2026 topic',
    ];

    final videosById = <String, Video>{};
    final scoresById = <String, int>{};

    final phase1Count = phaseQueries.length >= 3 ? 3 : phaseQueries.length;
    final phase1 = List.generate(
      phase1Count,
      (index) => _collectTrendingBatch(
        searchQuery: phaseQueries[index],
        queryIndex: index,
        videosById: videosById,
        scoresById: scoresById,
      ),
    );
    await Future.wait(phase1);

    if (scoresById.length < 16 && phaseQueries.length > phase1Count) {
      final phase2 = List.generate(phaseQueries.length - phase1Count, (offset) {
        final index = phase1Count + offset;
        return _collectTrendingBatch(
          searchQuery: phaseQueries[index],
          queryIndex: index,
          videosById: videosById,
          scoresById: scoresById,
        );
      });
      await Future.wait(phase2);
    }

    final ids = scoresById.keys.toList()
      ..sort((a, b) {
        final viewsA = videosById[a]?.engagement.viewCount ?? 0;
        final viewsB = videosById[b]?.engagement.viewCount ?? 0;
        if (viewsA != viewsB) return viewsB.compareTo(viewsA);
        return (scoresById[b] ?? 0).compareTo(scoresById[a] ?? 0);
      });
    final result = ids
        .take(18)
        .map((id) => _HomeTrack.fromVideo(videosById[id]!))
        .toList(growable: false);
    if (result.isNotEmpty) {
      await _writeTrendingCache(result);
    }
    return result;
  }

  Future<void> _collectTrendingBatch({
    required String searchQuery,
    required int queryIndex,
    required Map<String, Video> videosById,
    required Map<String, int> scoresById,
  }) async {
    try {
      final raw = await _yt.search.search(searchQuery);
      for (final video in raw.take(36)) {
        if (!_isPureYoutubeMusicAutoGenerated(video)) continue;
        final id = video.id.value;
        final score = _trendingScore(
          video: video,
          searchQuery: searchQuery,
          queryIndex: queryIndex,
        );
        final previous = scoresById[id];
        if (previous == null || score > previous) {
          scoresById[id] = score;
          videosById[id] = video;
        }
      }
    } catch (_) {
      // Best effort.
    }
  }

  int _trendingScore({
    required Video video,
    required String searchQuery,
    required int queryIndex,
  }) {
    final title = video.title.toLowerCase();
    final author = video.author.toLowerCase();
    final description = video.description.toLowerCase();
    final text = '$title $author $description';
    final tokens = searchQuery
        .toLowerCase()
        .split(RegExp(r'\\s+'))
        .where((token) => token.length >= 3)
        .take(8)
        .toList(growable: false);

    var score = 0;
    if (_isTopicVideo(video)) score += 110;
    if (_isAutoGeneratedVideo(video)) score += 90;
    for (final token in tokens) {
      if (text.contains(token)) score += 20;
    }
    if (queryIndex == 0) score += 28;
    score -= queryIndex * 5;
    final views = video.engagement.viewCount;
    if (views > 0) {
      score += (views / 250000).floor().clamp(0, 55);
    }
    return score;
  }

  bool _isPureYoutubeMusicAutoGenerated(Video video) {
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

  Future<List<_HomeTrack>> _readTrendingCache() async {
    try {
      final box = await Hive.openBox<String>(_homeCacheBoxName);
      final raw = box.get(_trendingCacheKey);
      if (raw == null || raw.isEmpty) return const [];
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final updatedAtMs = (map['updatedAtMs'] as num?)?.toInt() ?? 0;
      if (updatedAtMs <= 0) return const [];
      final updatedAt = DateTime.fromMillisecondsSinceEpoch(updatedAtMs);
      if (DateTime.now().difference(updatedAt) > _trendingCacheTtl) {
        return const [];
      }
      final items = (map['items'] as List<dynamic>? ?? const <dynamic>[])
          .whereType<Map>()
          .map(
            (item) => _HomeTrack(
              videoId: (item['videoId'] ?? '').toString(),
              title: (item['title'] ?? '').toString(),
              artist: cleanArtistName((item['artist'] ?? '').toString()),
              thumbnailUrl: (item['thumbnailUrl'] ?? '').toString(),
              isLocal: false,
            ),
          )
          .where((item) => item.videoId.isNotEmpty && item.title.isNotEmpty)
          .toList(growable: false);
      return items;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _writeTrendingCache(List<_HomeTrack> tracks) async {
    try {
      final box = await Hive.openBox<String>(_homeCacheBoxName);
      final payload = jsonEncode({
        'updatedAtMs': DateTime.now().millisecondsSinceEpoch,
        'items': tracks
            .take(24)
            .map(
              (item) => {
                'videoId': item.videoId,
                'title': item.title,
                'artist': item.artist,
                'thumbnailUrl': item.thumbnailUrl,
              },
            )
            .toList(growable: false),
      });
      await box.put(_trendingCacheKey, payload);
    } catch (_) {
      // Best effort.
    }
  }

  List<_HomeTrack> _buildSuggestions({
    required List<VideoHistory> history,
    required List<DownloadedVideo> downloads,
    required List<_HomeTrack> trendingSeed,
    required List<_HomeTrack> searchSeed,
  }) {
    const target = 14;
    final suggestions = <_HomeTrack>[];
    final seenIds = <String>{};
    final relistenIds = history.take(20).map((e) => e.videoId).toSet();
    final topArtists = _extractTopArtists(history);

    void add(_HomeTrack item) {
      if (seenIds.contains(item.videoId)) return;
      if (relistenIds.contains(item.videoId)) return;
      seenIds.add(item.videoId);
      suggestions.add(item);
    }

    // 0) Parte de recomendados tipo Buscar/cola.
    for (final item in searchSeed.take(8)) {
      add(item);
      if (suggestions.length >= target) return suggestions;
    }

    // 1) Tendencias alineadas con gustos del historial.
    for (final item in trendingSeed) {
      final artist = _normalizeArtist(item.artist);
      final matchesTaste = topArtists.any(
        (favorite) => artist.contains(favorite) || favorite.contains(artist),
      );
      if (!matchesTaste) continue;
      add(item);
      if (suggestions.length >= target) return suggestions;
    }

    // 2) Algunas del historial, pero no las que salen en "Volver a escuchar".
    for (final item in history.skip(20)) {
      add(_HomeTrack.fromHistory(item));
      if (suggestions.length >= target) return suggestions;
    }

    // 3) Relleno con descargas que no estén en relisten.
    for (final item in downloads) {
      add(_HomeTrack.fromDownloaded(item));
      if (suggestions.length >= target) return suggestions;
    }

    // 4) Si falta, usamos más tendencia (aunque no matchee artista).
    for (final item in trendingSeed) {
      add(item);
      if (suggestions.length >= target) return suggestions;
    }

    // 5) Fallback final con historial reciente no usado.
    for (final item in history) {
      add(_HomeTrack.fromHistory(item));
      if (suggestions.length >= target) break;
    }

    return suggestions;
  }

  List<_HomeMix> _buildDailyMixes({
    required List<_HomeTrack> suggestions,
    required List<_HomeTrack> relisten,
    required List<_HomeTrack> trendingSeed,
    required List<_HomeTrack> searchSeed,
  }) {
    List<_HomeTrack> dedupeTracks(
      Iterable<_HomeTrack> source, {
      int take = 12,
    }) {
      final out = <_HomeTrack>[];
      final seen = <String>{};
      for (final item in source) {
        if (!seen.add(item.videoId)) continue;
        out.add(item);
        if (out.length >= take) break;
      }
      return out;
    }

    final mixes = <_HomeMix>[];
    final madeForYou = dedupeTracks([...searchSeed, ...suggestions], take: 12);
    if (madeForYou.isNotEmpty) {
      mixes.add(
        _HomeMix(
          title: 'Mix para ti',
          subtitle: 'Radio personalizada',
          tracks: madeForYou,
        ),
      );
    }
    final relistenMix = dedupeTracks(relisten, take: 12);
    if (relistenMix.isNotEmpty) {
      mixes.add(
        _HomeMix(
          title: 'Volver a escuchar',
          subtitle: 'Basado en tu historial',
          tracks: relistenMix,
        ),
      );
    }
    final trendingMix = dedupeTracks(trendingSeed, take: 12);
    if (trendingMix.isNotEmpty) {
      mixes.add(
        _HomeMix(
          title: 'Tendencia MX',
          subtitle: 'Lo más escuchado ahora',
          tracks: trendingMix,
        ),
      );
    }
    return mixes;
  }

  List<String> _extractTopArtists(List<VideoHistory> history) {
    final counts = <String, int>{};
    for (final item in history.take(40)) {
      final key = _normalizeArtist(item.channelTitle);
      if (key.isEmpty) continue;
      counts.update(key, (value) => value + 1, ifAbsent: () => 1);
    }
    final ranked = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return ranked.take(6).map((e) => e.key).toList(growable: false);
  }

  String _normalizeArtist(String input) {
    return input
        .toLowerCase()
        .replaceAll(RegExp(r'\s*[-–—]\s*topic$', caseSensitive: false), '')
        .replaceAll(RegExp(r'\btopic\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  Future<void> _refresh() async {
    final updated = _loadContent();
    final trendingUpdated = _loadTrendingTracks();
    setState(() {
      _contentFuture = updated;
      _trendingFuture = trendingUpdated;
    });
    await Future.wait([updated, trendingUpdated]);
  }

  Future<void> _playTrack(_HomeTrack track) async {
    final manager = context.read<VideoPlayerManager>();
    final downloadService = context.read<DownloadService>();

    if (track.isLocal && track.localFilePath != null) {
      await manager.playLocalFileFromUserSelection(
        context,
        id: track.videoId,
        filePath: track.localFilePath!,
        title: track.title,
        thumbnailUrl: track.thumbnailUrl,
        artist: track.artist,
        localPlainLyrics: track.localPlainLyrics,
        localSyncedLyrics: track.localSyncedLyrics,
      );
      return;
    }

    final local = await downloadService.getDownloadedVideoById(track.videoId);
    if (!mounted) return;
    if (local != null) {
      final thumb =
          (local.localThumbnailPath != null &&
              local.localThumbnailPath!.isNotEmpty)
          ? local.localThumbnailPath!
          : local.thumbnailUrl;
      await manager.playLocalFileFromUserSelection(
        context,
        id: local.videoId,
        filePath: local.filePath,
        title: local.title,
        thumbnailUrl: thumb,
        artist: local.channelTitle,
        localPlainLyrics: local.plainLyrics,
        localSyncedLyrics: local.syncedLyrics,
      );
      return;
    }

    await manager.playFromUserSelection(
      context,
      track.videoId,
      preferredThumbnailUrl: track.thumbnailUrl,
      preferredTitle: track.title,
      preferredArtist: track.artist,
    );
  }

  Future<void> _addTrackToQueue(
    _HomeTrack track, {
    ManualQueueInsertMode insertMode = ManualQueueInsertMode.end,
  }) async {
    final manager = context.read<VideoPlayerManager>();
    final added = track.isLocal && track.localFilePath != null
        ? manager.addLocalTrackToPlaybackQueue(
            videoId: track.videoId,
            title: track.title,
            thumbnailUrl: track.thumbnailUrl,
            artist: track.artist,
            filePath: track.localFilePath!,
            localPlainLyrics: track.localPlainLyrics,
            localSyncedLyrics: track.localSyncedLyrics,
            insertMode: insertMode,
          )
        : manager.addOnlineTrackToPlaybackQueue(
            videoId: track.videoId,
            title: track.title,
            thumbnailUrl: track.thumbnailUrl,
            artist: track.artist,
            insertMode: insertMode,
          );
    if (!mounted) return;
    await HapticFeedback.lightImpact();
    if (!mounted) return;
    _showQueueIosToast(
      context,
      message: added
          ? (insertMode == ManualQueueInsertMode.next
                ? 'Se añadió como siguiente'
                : 'Se ha añadido a la cola')
          : 'Esta canción ya está en cola',
      icon: added
          ? CupertinoIcons.check_mark_circled_solid
          : CupertinoIcons.info_circle_fill,
    );
  }

  Future<void> _addTrackToPlaylist(_HomeTrack track) async {
    final playlistService = context.read<PlaylistService>();
    final playlists = await playlistService.getPlaylists();
    if (!mounted || playlists.isEmpty) return;

    final selectedName = await showGlassPlaylistPickerSheet(
      context: context,
      playlists: playlists,
      subtitle: track.title,
    );
    if (!mounted || selectedName == null || selectedName.isEmpty) return;
    await _saveTrackToPlaylist(track, selectedName);
  }

  Future<void> _saveTrackToPlaylist(_HomeTrack track, String playlistName) async {
    final downloadService = context.read<DownloadService>();
    final videoManager = context.read<VideoPlayerManager>();
    final entry = VideoHistory(
      videoId: track.videoId,
      title: track.title,
      thumbnailUrl: track.thumbnailUrl,
      channelTitle: track.artist,
      watchedAt: DateTime.now(),
    );

    final playlistService = context.read<PlaylistService>();
    await playlistService.addVideoToPlaylist(playlistName, entry);
    await downloadService.autoDownloadIfEnabledUsingClone(
      playlistName,
      entry,
      videoManager: videoManager,
    );
    if (!mounted) return;
    await HapticFeedback.lightImpact();
    if (!mounted) return;
    final label = PlaylistService.isFavoritesPlaylistName(playlistName)
        ? 'Añadida a Favoritos'
        : 'Añadida a $playlistName';
    _showQueueIosToast(
      context,
      message: label,
      icon: PlaylistService.isFavoritesPlaylistName(playlistName)
          ? CupertinoIcons.star_fill
          : CupertinoIcons.check_mark_circled_solid,
    );
  }

  Future<void> _showTrackOptionsMenu(_HomeTrack track) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(26),
              child: _AdaptiveBackdropFilter(
                filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                child: Container(
                  decoration: BoxDecoration(
                    color: CupertinoColors.systemGrey6
                        .resolveFrom(sheetContext)
                        .withValues(alpha: 0.82),
                    borderRadius: BorderRadius.circular(26),
                    border: Border.all(
                      color: CupertinoColors.white.withValues(alpha: 0.24),
                      width: 0.7,
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(height: 8),
                      Container(
                        width: 42,
                        height: 4,
                        decoration: BoxDecoration(
                          color: CupertinoColors.systemGrey3
                              .resolveFrom(sheetContext)
                              .withValues(alpha: 0.75),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                track.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: CupertinoTheme.of(sheetContext)
                                    .textTheme
                                    .navTitleTextStyle
                                    .copyWith(fontWeight: FontWeight.w700),
                              ),
                            ),
                            const SizedBox(width: 8),
                            CupertinoButton(
                              padding: EdgeInsets.zero,
                              minimumSize: const Size(34, 34),
                              onPressed: () => Navigator.of(sheetContext).pop(),
                              child: Icon(
                                CupertinoIcons.xmark_circle_fill,
                                size: 24,
                                color: CupertinoColors.secondaryLabel
                                    .resolveFrom(sheetContext),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(10, 0, 10, 14),
                        child: Column(
                          children: [
                            _GlassSheetActionRow(
                              icon: CupertinoIcons.text_insert,
                              label: 'Añadir como siguiente',
                              onTap: () => Navigator.of(sheetContext).pop('next'),
                            ),
                            const SizedBox(height: 8),
                            _GlassSheetActionRow(
                              icon: CupertinoIcons.text_append,
                              label: 'Añadir al final',
                              onTap: () => Navigator.of(sheetContext).pop('end'),
                            ),
                            const SizedBox(height: 8),
                            _GlassSheetActionRow(
                              icon: CupertinoIcons.star_fill,
                              label: 'Añadir a Favoritos',
                              onTap: () =>
                                  Navigator.of(sheetContext).pop('favorites'),
                            ),
                            const SizedBox(height: 8),
                            _GlassSheetActionRow(
                              icon: CupertinoIcons.music_note_list,
                              label: 'Añadir a playlist',
                              onTap: () =>
                                  Navigator.of(sheetContext).pop('playlist'),
                            ),
                            const SizedBox(height: 8),
                            _GlassSheetActionRow(
                              icon: CupertinoIcons.square_arrow_up,
                              label: 'Compartir',
                              onTap: () =>
                                  Navigator.of(sheetContext).pop('share'),
                            ),
                            const SizedBox(height: 8),
                            _GlassSheetActionRow(
                              icon: CupertinoIcons.person_crop_circle,
                              label: 'Ir al artista',
                              onTap: () =>
                                  Navigator.of(sheetContext).pop('artist'),
                            ),
                            const SizedBox(height: 8),
                            _GlassSheetActionRow(
                              icon: CupertinoIcons.rectangle_stack_fill,
                              label: 'Ir al álbum',
                              onTap: () =>
                                  Navigator.of(sheetContext).pop('album'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );

    if (!mounted || action == null) return;
    if (action == 'next') {
      await _addTrackToQueue(track, insertMode: ManualQueueInsertMode.next);
      return;
    }
    if (action == 'end') {
      await _addTrackToQueue(track, insertMode: ManualQueueInsertMode.end);
      return;
    }
    if (action == 'favorites') {
      await _saveTrackToPlaylist(track, PlaylistService.favoritesPlaylistName);
      return;
    }
    if (action == 'playlist') {
      await _addTrackToPlaylist(track);
      return;
    }
    if (action == 'share') {
      await _shareTrackDeepLink(track);
      return;
    }
    if (action == 'artist') {
      await _openArtistFromTrack(track);
      return;
    }
    if (action == 'album') {
      await _openAlbumFromTrack(track);
    }
  }

  Future<void> _shareTrackDeepLink(_HomeTrack track) async {
    final videoId = track.videoId.trim();
    if (videoId.isEmpty) return;
    final title = track.title.trim();
    final artist = cleanArtistName(track.artist).trim();
    final thumbnailUrl = track.thumbnailUrl.trim();
    final deepLink = Uri(
      scheme: 'vmmusic',
      host: 'song',
      queryParameters: <String, String>{
        'videoId': videoId,
        if (title.isNotEmpty) 'title': title,
        if (artist.isNotEmpty) 'artist': artist,
        if (thumbnailUrl.isNotEmpty) 'thumbnailUrl': thumbnailUrl,
      },
    ).toString();
    final label = artist.isEmpty ? title : '$title · $artist';
    await SharePlus.instance.share(
      ShareParams(
        subject: 'VM Music',
        text: '$label\n$deepLink',
        sharePositionOrigin: _shareOriginFromContext(context),
      ),
    );
  }

  Future<void> _openArtistFromTrack(_HomeTrack track) async {
    final videoId = track.videoId.trim();
    if (videoId.isEmpty) return;
    try {
      final details = await _yt.channels.getByVideo(videoId);
      if (!mounted) return;
      final channelId = details.id.value.trim();
      if (channelId.isEmpty) return;
      await Navigator.of(context).push(
        CupertinoPageRoute<void>(
          builder: (_) => ChannelVideosPage(
            channelId: channelId,
            channelName: details.title,
            channelThumbnailUrl: details.logoUrl,
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No se pudo abrir el perfil del artista.'),
        ),
      );
    }
  }

  Future<void> _openAlbumFromTrack(_HomeTrack track) async {
    try {
      final resolved = await _resolveAlbumFromSearchFallback(track);
      if (!mounted) return;
      if (resolved == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No se pudo identificar el álbum de esta canción.'),
          ),
        );
        return;
      }
      await Navigator.of(context).push(
        CupertinoPageRoute<void>(
          builder: (_) => AlbumTracksPage(
            playlistId: resolved.playlistId,
            albumTitle: resolved.title,
            artistName: resolved.artist,
            seedThumbnailUrl: resolved.thumbnailUrl.isNotEmpty
                ? resolved.thumbnailUrl
                : track.thumbnailUrl,
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo abrir el álbum.')),
      );
    }
  }

  Future<_HomeResolvedAlbumRef?> _resolveAlbumFromSearchFallback(
    _HomeTrack track,
  ) async {
    final videoId = track.videoId.trim();
    if (videoId.isNotEmpty) {
      final cached = _albumRefByVideoIdCache[videoId];
      if (cached != null) return cached;
      final inFlight = _albumRefByVideoIdInFlight[videoId];
      if (inFlight != null) return inFlight;
    }

    final future = _resolveAlbumRefFast(track);
    if (videoId.isNotEmpty) {
      _albumRefByVideoIdInFlight[videoId] = future;
    }
    try {
      final resolved = await future;
      if (videoId.isNotEmpty) {
        if (resolved != null) {
          _albumRefByVideoIdCache[videoId] = resolved;
        }
      }
      return resolved;
    } finally {
      if (videoId.isNotEmpty) {
        _albumRefByVideoIdInFlight.remove(videoId);
      }
    }
  }

  Future<_HomeResolvedAlbumRef?> _resolveAlbumRefFast(_HomeTrack track) async {
    // Camino rápido: usar datos locales de la card.
    final localResolved = await resolveAlbumFromSongAndArtistLikeSearch(
      songTitle: track.title,
      artistName: track.artist,
    );
    if (localResolved != null) {
      return _HomeResolvedAlbumRef(
        playlistId: localResolved.playlistId,
        title: localResolved.title,
        artist: localResolved.artist,
        thumbnailUrl: localResolved.thumbnailUrl,
      );
    }

    // Fallback: si el camino rápido no encontró álbum, refinamos con metadata real del video.
    final videoId = track.videoId.trim();
    if (videoId.isEmpty) return null;
    String songTitle = track.title;
    String artistName = track.artist;
    try {
      final video = await _yt.videos.get(videoId);
      final fetchedTitle = video.title.trim();
      final fetchedArtist = video.author.trim();
      if (fetchedTitle.isNotEmpty) songTitle = fetchedTitle;
      if (fetchedArtist.isNotEmpty) artistName = fetchedArtist;
    } catch (_) {
      return null;
    }

    final refinedResolved = await resolveAlbumFromSongAndArtistLikeSearch(
      songTitle: songTitle,
      artistName: artistName,
    );
    if (refinedResolved == null) return null;
    return _HomeResolvedAlbumRef(
      playlistId: refinedResolved.playlistId,
      title: refinedResolved.title,
      artist: refinedResolved.artist,
      thumbnailUrl: refinedResolved.thumbnailUrl,
    );
  }

  Rect _shareOriginFromContext(BuildContext context) {
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox != null && renderBox.hasSize) {
      return renderBox.localToGlobal(Offset.zero) & renderBox.size;
    }
    return const Rect.fromLTWH(1, 1, 1, 1);
  }

  Future<List<PlaybackQueueItem>> _buildQueueItemsFromTracks(
    List<_HomeTrack> tracks,
  ) async {
    final downloadService = context.read<DownloadService>();
    final queue = <PlaybackQueueItem>[];
    final seenIds = <String>{};

    for (final track in tracks) {
      if (!seenIds.add(track.videoId)) continue;
      if (track.isLocal &&
          track.localFilePath != null &&
          track.localFilePath!.isNotEmpty &&
          File(track.localFilePath!).existsSync()) {
        queue.add(
          PlaybackQueueItem(
            videoId: track.videoId,
            title: track.title,
            thumbnailUrl: track.thumbnailUrl,
            artist: track.artist,
            isLocal: true,
            localFilePath: track.localFilePath,
            localPlainLyrics: track.localPlainLyrics,
            localSyncedLyrics: track.localSyncedLyrics,
          ),
        );
        continue;
      }

      final local = await downloadService.getDownloadedVideoById(track.videoId);
      if (local != null) {
        final thumb =
            (local.localThumbnailPath != null &&
                local.localThumbnailPath!.isNotEmpty)
            ? local.localThumbnailPath!
            : local.thumbnailUrl;
        queue.add(
          PlaybackQueueItem(
            videoId: local.videoId,
            title: local.title,
            thumbnailUrl: thumb,
            artist: cleanArtistName(local.channelTitle),
            isLocal: true,
            localFilePath: local.filePath,
            localPlainLyrics: local.plainLyrics,
            localSyncedLyrics: local.syncedLyrics,
          ),
        );
      } else {
        queue.add(
          PlaybackQueueItem(
            videoId: track.videoId,
            title: track.title,
            thumbnailUrl: track.thumbnailUrl,
            artist: track.artist,
            isLocal: false,
          ),
        );
      }
    }
    return queue;
  }

  Future<void> _playMix(_HomeMix mix) async {
    if (mix.tracks.isEmpty) return;
    final manager = context.read<VideoPlayerManager>();
    final queueItems = await _buildQueueItemsFromTracks(mix.tracks);
    if (queueItems.isEmpty) return;
    final first = queueItems.first;
    final rest = queueItems.skip(1).toList(growable: false);
    manager.replaceManualPlaybackQueue(rest, queueTitle: 'Mix · ${mix.title}');
    await manager.playQueueItem(first);
  }

  Future<void> _queueMix(_HomeMix mix) async {
    if (mix.tracks.isEmpty) return;
    final manager = context.read<VideoPlayerManager>();
    final queueItems = await _buildQueueItemsFromTracks(mix.tracks);
    var addedCount = 0;
    for (final item in queueItems) {
      final added = item.isLocal
          ? manager.addLocalTrackToPlaybackQueue(
              videoId: item.videoId,
              title: item.title,
              thumbnailUrl: item.thumbnailUrl,
              artist: item.artist,
              filePath: item.localFilePath ?? '',
              localPlainLyrics: item.localPlainLyrics,
              localSyncedLyrics: item.localSyncedLyrics,
            )
          : manager.addOnlineTrackToPlaybackQueue(
              videoId: item.videoId,
              title: item.title,
              thumbnailUrl: item.thumbnailUrl,
              artist: item.artist,
            );
      if (added) addedCount++;
    }
    if (!mounted) return;
    _showQueueIosToast(
      context,
      message: addedCount > 0
          ? 'Mix añadido a la cola ($addedCount)'
          : 'Ese mix ya estaba en cola',
      icon: addedCount > 0
          ? CupertinoIcons.check_mark_circled_solid
          : CupertinoIcons.info_circle_fill,
    );
  }

  List<List<_HomeTrack>> _buildTrackColumns(
    List<_HomeTrack> source, {
    int itemsPerColumn = 2,
  }) {
    if (source.isEmpty) return const [];
    final normalizedItemsPerColumn = itemsPerColumn <= 0 ? 1 : itemsPerColumn;
    final columns = <List<_HomeTrack>>[];
    for (
      var index = 0;
      index < source.length;
      index += normalizedItemsPerColumn
    ) {
      final end = math.min(index + normalizedItemsPerColumn, source.length);
      columns.add(source.sublist(index, end));
    }
    return columns;
  }

  bool _shouldRenderAsTopSongsStack(_HomeShelf shelf) {
    return shelf.id == 'quick_picks' ||
        shelf.id == 'top_mexico' ||
        shelf.id == 'top_global';
  }

  bool _isThinStackShelf(_HomeShelf shelf) {
    return shelf.id == 'quick_picks' ||
        shelf.id == 'top_mexico' ||
        shelf.id == 'top_global';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hasMiniPlayer = context.select<VideoPlayerManager, bool>(
      (playerManager) =>
          playerManager.currentVideoId != null && playerManager.isMinimized,
    );
    final bottomInset = MediaQuery.of(context).padding.bottom;
    const tabBarReserve = 108.0;
    const miniPlayerReserve = 64.0;
    final bottomReserve =
        tabBarReserve + (hasMiniPlayer ? miniPlayerReserve : 0) + bottomInset;
    final pageBackground = isDark
        ? Colors.black
        : CupertinoColors.systemGroupedBackground.resolveFrom(context);

    return Scaffold(
      backgroundColor: pageBackground,
      body: SafeArea(
        bottom: false,
        child: FutureBuilder<_HomeContent>(
          future: _contentFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(
                child: CupertinoActivityIndicator(radius: 14),
              );
            }

            final content = snapshot.data;
            if (content == null) {
              return RefreshIndicator(
                onRefresh: _refresh,
                child: ListView(
                  children: const [
                    SizedBox(height: 180),
                    Center(child: Text('No se pudo cargar Inicio.')),
                  ],
                ),
              );
            }
            final relistenColumns = _buildTrackColumns(
              content.relisten,
              itemsPerColumn: 4,
            );

            return RefreshIndicator(
              onRefresh: _refresh,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  const SliverToBoxAdapter(child: SizedBox(height: 12)),
                  _SectionHeaderSliver(
                    title: 'Sugerencias para ti',
                    subtitle: 'Mezcla de tu historial y descargas',
                  ),
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: 222,
                      child: ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
                        scrollDirection: Axis.horizontal,
                        itemCount: content.suggestions.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 12),
                        itemBuilder: (context, index) {
                          final item = content.suggestions[index];
                          return _HomeFeatureCard(
                            item: item,
                            onTap: () => _playTrack(item),
                          );
                        },
                      ),
                    ),
                  ),
                if (content.mixes.isNotEmpty) ...[
                    const SliverToBoxAdapter(child: SizedBox(height: 6)),
                    _SectionHeaderSliver(
                      title: 'Mixes para ti',
                      subtitle: 'Como en radio, pero con tu gusto',
                    ),
                    SliverToBoxAdapter(
                      child: SizedBox(
                        height: 154,
                        child: ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
                          scrollDirection: Axis.horizontal,
                          itemCount: content.mixes.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 12),
                          itemBuilder: (context, index) {
                            final mix = content.mixes[index];
                            return _HomeMixCard(
                              mix: mix,
                              onPlay: () => _playMix(mix),
                              onQueue: () => _queueMix(mix),
                            );
                          },
                        ),
                    ),
                  ),
                ],
                  if (content.curatedShelves.isNotEmpty) ...[
                    const SliverToBoxAdapter(child: SizedBox(height: 6)),
                    _SectionHeaderSliver(
                      title: 'Explorar en YouTube Music',
                      subtitle: 'Quick picks, throwbacks y playlists en tendencia',
                    ),
                    for (final shelf in content.curatedShelves) ...[
                      _SectionHeaderSliver(
                        title: shelf.title,
                        subtitle: shelf.subtitle,
                      ),
                      if (_shouldRenderAsTopSongsStack(shelf))
                        SliverToBoxAdapter(
                          child: SizedBox(
                            height: _isThinStackShelf(shelf) ? 320 : 352,
                            child: ListView.separated(
                              padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
                              scrollDirection: Axis.horizontal,
                              itemCount: _buildTrackColumns(
                                shelf.tracks,
                                itemsPerColumn: 4,
                              ).length,
                              separatorBuilder: (_, _) => const SizedBox(width: 12),
                              itemBuilder: (context, index) {
                                final columnItems = _buildTrackColumns(
                                  shelf.tracks,
                                  itemsPerColumn: 4,
                                )[index];
                                return _StackedTrackColumn(
                                  items: columnItems,
                                  onTap: _playTrack,
                                  onSwipeToQueueNext: (item) => _addTrackToQueue(
                                    item,
                                    insertMode: ManualQueueInsertMode.next,
                                  ),
                                  onSwipeToQueueEnd: (item) => _addTrackToQueue(
                                    item,
                                    insertMode: ManualQueueInsertMode.end,
                                  ),
                                  onShowTrackMenu: _showTrackOptionsMenu,
                                  allowSwipeToQueue: false,
                                  thinCards: _isThinStackShelf(shelf),
                                );
                              },
                            ),
                          ),
                        )
                      else
                        SliverToBoxAdapter(
                          child: SizedBox(
                            height: 222,
                            child: ListView.separated(
                              padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
                              scrollDirection: Axis.horizontal,
                              itemCount: shelf.tracks.length,
                              separatorBuilder: (_, _) => const SizedBox(width: 12),
                              itemBuilder: (context, index) {
                                final item = shelf.tracks[index];
                                return _HomeFeatureCard(
                                  item: item,
                                  onTap: () => _playTrack(item),
                                );
                              },
                            ),
                          ),
                        ),
                    ],
                  ],
                  const SliverToBoxAdapter(child: SizedBox(height: 6)),
                  _SectionHeaderSliver(
                    title: 'Volver a escuchar',
                    subtitle: 'Tus últimas reproducciones',
                  ),
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: 320,
                      child: ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
                        scrollDirection: Axis.horizontal,
                        itemCount: relistenColumns.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 12),
                        itemBuilder: (context, index) {
                          final columnItems = relistenColumns[index];
                          return _StackedTrackColumn(
                            items: columnItems,
                            onTap: _playTrack,
                            onSwipeToQueueNext: (item) => _addTrackToQueue(
                              item,
                              insertMode: ManualQueueInsertMode.next,
                            ),
                            onSwipeToQueueEnd: (item) => _addTrackToQueue(
                              item,
                              insertMode: ManualQueueInsertMode.end,
                            ),
                            onShowTrackMenu: _showTrackOptionsMenu,
                            allowSwipeToQueue: false,
                            thinCards: true,
                          );
                        },
                      ),
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 6)),
                  const SliverToBoxAdapter(child: SizedBox(height: 6)),
                  _SectionHeaderSliver(
                    title: 'En tendencia',
                    subtitle: 'Lo más escuchado ahora',
                  ),
                  FutureBuilder<List<_HomeTrack>>(
                    future: _trendingFuture,
                    builder: (context, trendingSnapshot) {
                      if (trendingSnapshot.connectionState ==
                          ConnectionState.waiting) {
                        return const SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(0, 20, 0, 24),
                            child: Center(
                              child: CupertinoActivityIndicator(radius: 12),
                            ),
                          ),
                        );
                      }

                      final trending =
                          trendingSnapshot.data ?? const <_HomeTrack>[];
                      if (trending.isEmpty) {
                        return const SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(16, 10, 16, 24),
                            child: Text(
                              'No se pudieron cargar tendencias ahora.',
                            ),
                          ),
                        );
                      }

                      return SliverPadding(
                        padding: const EdgeInsets.fromLTRB(12, 6, 12, 18),
                        sliver: SliverList.builder(
                          itemCount: trending.length,
                          itemBuilder: (context, index) {
                            final item = trending[index];
                            return _TrendingRowCard(
                              item: item,
                              onTap: () => _playTrack(item),
                              onSwipeToQueueNext: () => _addTrackToQueue(
                                item,
                                insertMode: ManualQueueInsertMode.next,
                              ),
                              onSwipeToQueueEnd: () => _addTrackToQueue(
                                item,
                                insertMode: ManualQueueInsertMode.end,
                              ),
                              onShowTrackMenu: () => _showTrackOptionsMenu(item),
                            );
                          },
                        ),
                      );
                    },
                  ),
                  SliverToBoxAdapter(child: SizedBox(height: bottomReserve)),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _HomeContent {
  final List<_HomeTrack> suggestions;
  final List<_HomeTrack> relisten;
  final List<_HomeMix> mixes;
  final List<_HomeShelf> curatedShelves;

  const _HomeContent({
    required this.suggestions,
    required this.relisten,
    required this.mixes,
    required this.curatedShelves,
  });
}

class _ShelfSeed {
  final String id;
  final String title;
  final String subtitle;
  final String query;

  const _ShelfSeed({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.query,
  });
}

class _HomeMix {
  final String title;
  final String subtitle;
  final List<_HomeTrack> tracks;

  const _HomeMix({
    required this.title,
    required this.subtitle,
    required this.tracks,
  });
}

class _HomeShelf {
  final String id;
  final String title;
  final String subtitle;
  final List<_HomeTrack> tracks;

  const _HomeShelf({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.tracks,
  });
}

class _HomeTrack {
  final String videoId;
  final String title;
  final String artist;
  final String thumbnailUrl;
  final bool isLocal;
  final String? localFilePath;
  final String? localPlainLyrics;
  final String? localSyncedLyrics;

  const _HomeTrack({
    required this.videoId,
    required this.title,
    required this.artist,
    required this.thumbnailUrl,
    required this.isLocal,
    this.localFilePath,
    this.localPlainLyrics,
    this.localSyncedLyrics,
  });

  factory _HomeTrack.fromHistory(VideoHistory item) {
    return _HomeTrack(
      videoId: item.videoId,
      title: item.title,
      artist: cleanArtistName(item.channelTitle),
      thumbnailUrl: item.thumbnailUrl,
      isLocal: false,
    );
  }

  factory _HomeTrack.fromDownloaded(DownloadedVideo item) {
    final thumb =
        (item.localThumbnailPath != null && item.localThumbnailPath!.isNotEmpty)
        ? item.localThumbnailPath!
        : item.thumbnailUrl;
    return _HomeTrack(
      videoId: item.videoId,
      title: item.title,
      artist: cleanArtistName(item.channelTitle),
      thumbnailUrl: thumb,
      isLocal: true,
      localFilePath: item.filePath,
      localPlainLyrics: item.plainLyrics,
      localSyncedLyrics: item.syncedLyrics,
    );
  }

  factory _HomeTrack.fromVideo(Video video) {
    return _HomeTrack(
      videoId: video.id.value,
      title: video.title,
      artist: cleanArtistName(video.author),
      thumbnailUrl: bestThumbnailForVideo(video),
      isLocal: false,
    );
  }

  factory _HomeTrack.fromQueueItem(PlaybackQueueItem item) {
    return _HomeTrack(
      videoId: item.videoId,
      title: item.title,
      artist: cleanArtistName(item.artist),
      thumbnailUrl: item.thumbnailUrl,
      isLocal: item.isLocal,
      localFilePath: item.localFilePath,
      localPlainLyrics: item.localPlainLyrics,
      localSyncedLyrics: item.localSyncedLyrics,
    );
  }
}

class _HomeResolvedAlbumRef {
  final String playlistId;
  final String title;
  final String artist;
  final String thumbnailUrl;

  const _HomeResolvedAlbumRef({
    required this.playlistId,
    required this.title,
    required this.artist,
    required this.thumbnailUrl,
  });
}

class _SectionHeaderSliver extends StatelessWidget {
  final String title;
  final String subtitle;

  const _SectionHeaderSliver({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontFamily: '.SF Pro Display',
                fontSize: 24,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.4,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: TextStyle(
                fontFamily: '.SF Pro Text',
                fontSize: 13,
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeFeatureCard extends StatelessWidget {
  final _HomeTrack item;
  final VoidCallback onTap;

  const _HomeFeatureCard({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark
        ? Colors.black
        : CupertinoColors.secondarySystemGroupedBackground.resolveFrom(context);
    final cardBorder = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : CupertinoColors.separator
              .resolveFrom(context)
              .withValues(alpha: 0.12);

    return SizedBox(
      width: 162,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Material(
          color: cardColor,
          surfaceTintColor: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            child: Container(
              decoration: BoxDecoration(
                color: cardColor,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: cardBorder, width: 0.6),
              ),
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _AdaptiveThumb(item: item, size: 142),
                  const SizedBox(height: 10),
                  Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: '.SF Pro Text',
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    item.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: '.SF Pro Text',
                      fontSize: 12,
                      color: CupertinoColors.secondaryLabel.resolveFrom(
                        context,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HomeMixCard extends StatelessWidget {
  final _HomeMix mix;
  final VoidCallback onPlay;
  final VoidCallback onQueue;

  const _HomeMixCard({
    required this.mix,
    required this.onPlay,
    required this.onQueue,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark
        ? Colors.black
        : CupertinoColors.secondarySystemGroupedBackground.resolveFrom(context);
    final cardBorder = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : CupertinoColors.separator
              .resolveFrom(context)
              .withValues(alpha: 0.12);
    final coverTrack = mix.tracks.isNotEmpty ? mix.tracks.first : null;

    return SizedBox(
      width: 226,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Material(
          color: cardColor,
          child: InkWell(
            onTap: onPlay,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: cardBorder, width: 0.6),
              ),
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  coverTrack == null
                      ? Container(
                          width: 76,
                          height: 76,
                          decoration: BoxDecoration(
                            color: CupertinoColors.tertiarySystemFill
                                .resolveFrom(context),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          alignment: Alignment.center,
                          child: const Icon(CupertinoIcons.music_note_list),
                        )
                      : _AdaptiveThumb(item: coverTrack, size: 76),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          mix.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: '.SF Pro Text',
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          mix.subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: '.SF Pro Text',
                            fontSize: 12,
                            color: CupertinoColors.secondaryLabel.resolveFrom(
                              context,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            CupertinoButton(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              minimumSize: Size.zero,
                              color: CupertinoColors.systemPink.resolveFrom(
                                context,
                              ),
                              borderRadius: BorderRadius.circular(999),
                              onPressed: onPlay,
                              child: const Icon(
                                CupertinoIcons.play_fill,
                                color: CupertinoColors.white,
                                size: 14,
                              ),
                            ),
                            const SizedBox(width: 6),
                            CupertinoButton(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              minimumSize: Size.zero,
                              color: CupertinoColors.tertiarySystemFill
                                  .resolveFrom(context),
                              borderRadius: BorderRadius.circular(999),
                              onPressed: onQueue,
                              child: Icon(
                                CupertinoIcons.music_note_list,
                                color: CupertinoColors.label.resolveFrom(
                                  context,
                                ),
                                size: 14,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StackedTrackColumn extends StatelessWidget {
  final List<_HomeTrack> items;
  final Future<void> Function(_HomeTrack item) onTap;
  final Future<void> Function(_HomeTrack item) onSwipeToQueueNext;
  final Future<void> Function(_HomeTrack item) onSwipeToQueueEnd;
  final Future<void> Function(_HomeTrack item) onShowTrackMenu;
  final bool allowSwipeToQueue;
  final bool thinCards;

  const _StackedTrackColumn({
    required this.items,
    required this.onTap,
    required this.onSwipeToQueueNext,
    required this.onSwipeToQueueEnd,
    required this.onShowTrackMenu,
    required this.allowSwipeToQueue,
    this.thinCards = false,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final clampedItems = items.take(4).toList(growable: false);
    return SizedBox(
      width: 286,
      child: LayoutBuilder(
        builder: (context, constraints) {
          const spacing = 8.0;
          const slotsPerColumn = 4;
          final hasBoundedHeight = constraints.maxHeight.isFinite;
          final rowHeight = hasBoundedHeight
              ? (constraints.maxHeight - (slotsPerColumn - 1) * spacing) /
                    slotsPerColumn
              : 82.0;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: List.generate(clampedItems.length * 2 - 1, (index) {
              if (index.isOdd) return const SizedBox(height: spacing);
              final itemIndex = index ~/ 2;
              final item = clampedItems[itemIndex];
              return SizedBox(
                height: rowHeight,
                child: _CompactReplayCard(
                  item: item,
                  onTap: () => onTap(item),
                  onSwipeToQueueNext: () => onSwipeToQueueNext(item),
                  onSwipeToQueueEnd: () => onSwipeToQueueEnd(item),
                  onShowTrackMenu: () => onShowTrackMenu(item),
                  allowSwipeToQueue: allowSwipeToQueue,
                  thin: thinCards,
                ),
              );
            }),
          );
        },
      ),
    );
  }
}

class _CompactReplayCard extends StatelessWidget {
  final _HomeTrack item;
  final VoidCallback onTap;
  final Future<void> Function() onSwipeToQueueNext;
  final Future<void> Function() onSwipeToQueueEnd;
  final VoidCallback onShowTrackMenu;
  final bool allowSwipeToQueue;
  final bool thin;

  const _CompactReplayCard({
    required this.item,
    required this.onTap,
    required this.onSwipeToQueueNext,
    required this.onSwipeToQueueEnd,
    required this.onShowTrackMenu,
    required this.allowSwipeToQueue,
    this.thin = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark
        ? Colors.black
        : CupertinoColors.secondarySystemGroupedBackground.resolveFrom(context);
    final cardBorder = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : CupertinoColors.separator
              .resolveFrom(context)
              .withValues(alpha: 0.12);
    final thumbSize = thin ? 56.0 : 64.0;
    final cardRadius = thin ? 12.0 : 14.0;
    final horizontalPadding = thin ? 8.0 : 8.0;
    final verticalPadding = thin ? 4.0 : 7.0;
    final titleFontSize = thin ? 13.0 : 14.0;
    final artistFontSize = thin ? 11.0 : 12.0;
    final titleArtistGap = thin ? 2.0 : 4.0;
    final thumbTextGap = thin ? 8.0 : 10.0;
    final trailingGap = thin ? 6.0 : 8.0;

    final card = ClipRRect(
      borderRadius: BorderRadius.circular(cardRadius),
      child: Material(
        color: cardColor,
        surfaceTintColor: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(cardRadius),
              border: Border.all(color: cardBorder, width: 0.6),
            ),
            padding: EdgeInsets.symmetric(
              horizontal: horizontalPadding,
              vertical: verticalPadding,
            ),
            child: Row(
              children: [
                _AdaptiveThumb(item: item, size: thumbSize),
                SizedBox(width: thumbTextGap),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: '.SF Pro Text',
                          fontSize: titleFontSize,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(height: titleArtistGap),
                      Text(
                        item.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: '.SF Pro Text',
                          fontSize: artistFontSize,
                          color: CupertinoColors.secondaryLabel.resolveFrom(
                            context,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: trailingGap),
                _QueueAddButton(onPressed: onShowTrackMenu),
              ],
            ),
          ),
        ),
      ),
    );

    return allowSwipeToQueue
        ? Slidable(
            key: ObjectKey(item),
            startActionPane: _queueActionPane(
              context,
              onNext: onSwipeToQueueNext,
              onEnd: onSwipeToQueueEnd,
            ),
            child: card,
          )
        : card;
  }
}

class _TrendingRowCard extends StatelessWidget {
  final _HomeTrack item;
  final VoidCallback onTap;
  final Future<void> Function() onSwipeToQueueNext;
  final Future<void> Function() onSwipeToQueueEnd;
  final VoidCallback onShowTrackMenu;

  const _TrendingRowCard({
    required this.item,
    required this.onTap,
    required this.onSwipeToQueueNext,
    required this.onSwipeToQueueEnd,
    required this.onShowTrackMenu,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark
        ? Colors.black
        : CupertinoColors.secondarySystemGroupedBackground.resolveFrom(context);
    final cardBorder = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : CupertinoColors.separator
              .resolveFrom(context)
              .withValues(alpha: 0.12);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Slidable(
        key: ObjectKey(item),
        startActionPane: _queueActionPane(
          context,
          onNext: onSwipeToQueueNext,
          onEnd: onSwipeToQueueEnd,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Material(
            color: cardColor,
            surfaceTintColor: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: cardBorder, width: 0.6),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    _AdaptiveThumb(item: item, size: 64),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: '.SF Pro Text',
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            item.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: '.SF Pro Text',
                              fontSize: 13,
                              color: CupertinoColors.secondaryLabel.resolveFrom(
                                context,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    _QueueAddButton(onPressed: onShowTrackMenu),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AdaptiveThumb extends StatelessWidget {
  final _HomeTrack item;
  final double size;

  const _AdaptiveThumb({required this.item, required this.size});

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: size,
      height: size,
      color: CupertinoColors.tertiarySystemFill.resolveFrom(context),
      alignment: Alignment.center,
      child: const Icon(CupertinoIcons.music_note),
    );

    if (item.thumbnailUrl.isNotEmpty && item.thumbnailUrl.startsWith('/')) {
      final file = File(item.thumbnailUrl);
      if (file.existsSync()) {
        return SquareThumbnail.file(
          filePath: item.thumbnailUrl,
          size: size,
          borderRadius: 10,
          fallback: fallback,
        );
      }
    }

    return SquareThumbnail.network(
      imageUrl: item.thumbnailUrl,
      size: size,
      borderRadius: 10,
      fallback: fallback,
    );
  }
}

class _QueueAddButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _QueueAddButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      padding: EdgeInsets.zero,
      minimumSize: const Size(30, 30),
      borderRadius: BorderRadius.circular(11),
      onPressed: onPressed,
      child: Icon(
        CupertinoIcons.ellipsis_circle,
        size: 22,
        color: CupertinoColors.secondaryLabel.resolveFrom(context),
      ),
    );
  }
}

class _AdaptiveBackdropFilter extends StatelessWidget {
  final ImageFilter filter;
  final Widget child;

  const _AdaptiveBackdropFilter({required this.filter, required this.child});

  @override
  Widget build(BuildContext context) {
    final appInForeground =
        context.select<AppLifecycleService?, bool>((s) => s?.isForeground ?? true);
    final dataSaverMode =
        context.select<AppSettingsService?, bool>((s) => s?.dataSaverMode ?? false);
    final disableBackdrop =
        dataSaverMode ||
        !appInForeground ||
        defaultTargetPlatform == TargetPlatform.iOS;
    if (disableBackdrop) return child;
    return BackdropFilter(filter: filter, child: child);
  }
}

class _GlassSheetActionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _GlassSheetActionRow({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: _AdaptiveBackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Material(
          color: Colors.white.withValues(alpha: 0.05),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: CupertinoColors.white.withValues(alpha: 0.18),
                  width: 0.6,
                ),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withValues(alpha: 0.08),
                    Colors.white.withValues(alpha: 0.02),
                  ],
                ),
              ),
              child: Row(
                children: [
                  Icon(icon, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      label,
                      style: const TextStyle(
                        fontFamily: '.SF Pro Text',
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                  ),
                  Icon(
                    CupertinoIcons.chevron_right,
                    size: 17,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

ActionPane _queueActionPane(
  BuildContext context, {
  required Future<void> Function() onNext,
  required Future<void> Function() onEnd,
}) {
  return ActionPane(
    motion: const StretchMotion(),
    extentRatio: 0.46,
    dismissible: DismissiblePane(
      onDismissed: () {},
      closeOnCancel: true,
      confirmDismiss: () async {
        unawaited(onNext());
        return false;
      },
    ),
    children: [
      QueueSwipeActionButton(
        onTap: onNext,
        baseColor: CupertinoColors.systemPink.resolveFrom(context),
        icon: CupertinoIcons.text_insert,
        label: 'Siguiente',
      ),
      QueueSwipeActionButton(
        onTap: onEnd,
        baseColor: CupertinoColors.systemBlue.resolveFrom(context),
        icon: CupertinoIcons.text_append,
        label: 'Al final',
      ),
    ],
  );
}

void _showQueueIosToast(
  BuildContext context, {
  required String message,
  required IconData icon,
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final isDark = Theme.of(context).brightness == Brightness.dark;

  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (overlayContext) {
      final bottomInset = MediaQuery.of(overlayContext).padding.bottom;
      return IgnorePointer(
        ignoring: true,
        child: SizedBox.expand(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.only(bottom: bottomInset + 130),
              child: _QueueIosToast(
                message: message,
                icon: icon,
                isDark: isDark,
              ),
            ),
          ),
        ),
      );
    },
  );
  overlay.insert(entry);
  Timer(const Duration(milliseconds: 1900), entry.remove);
}

class _QueueIosToast extends StatefulWidget {
  final String message;
  final IconData icon;
  final bool isDark;

  const _QueueIosToast({
    required this.message,
    required this.icon,
    required this.isDark,
  });

  @override
  State<_QueueIosToast> createState() => _QueueIosToastState();
}

class _QueueIosToastState extends State<_QueueIosToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      reverseDuration: const Duration(milliseconds: 220),
    );
    _opacity = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.06),
      end: Offset.zero,
    ).animate(_opacity);
    unawaited(_run());
  }

  Future<void> _run() async {
    await _controller.forward();
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    if (!mounted) return;
    await _controller.reverse();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lightweightEffects =
        defaultTargetPlatform == TargetPlatform.iOS ||
        context.select<AppLifecycleService, bool>((s) => !s.isForeground) ||
        (context.select<AppSettingsService?, bool>(
          (s) => s?.dataSaverMode ?? false,
        ));
    final toastContent = DecoratedBox(
      decoration: BoxDecoration(
        color: widget.isDark
            ? const Color(0xFF0D0F13).withValues(alpha: 0.84)
            : Colors.white.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: widget.isDark
              ? Colors.white.withValues(alpha: 0.14)
              : Colors.black.withValues(alpha: 0.08),
          width: 0.6,
        ),
        boxShadow: [
          BoxShadow(
            color: CupertinoColors.black.withValues(alpha: 0.18),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              widget.icon,
              size: 18,
              color: CupertinoColors.systemPink.resolveFrom(context),
            ),
            const SizedBox(width: 8),
            Text(
              widget.message,
              style: TextStyle(
                fontFamily: '.SF Pro Text',
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: widget.isDark ? Colors.white : Colors.black,
                decoration: TextDecoration.none,
              ),
            ),
          ],
        ),
      ),
    );

    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(
        position: _slide,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: lightweightEffects
              ? toastContent
              : BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                  child: toastContent,
                ),
        ),
      ),
    );
  }
}
