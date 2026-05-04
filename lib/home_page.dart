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
import 'package:just_audio/just_audio.dart';
import 'package:myapp/models/downloaded_video.dart';
import 'package:myapp/models/video_history.dart';
import 'package:myapp/app_tab_state.dart';
import 'package:myapp/search_view_state.dart';
import 'package:myapp/services/app_lifecycle_service.dart';
import 'package:myapp/services/app_settings_service.dart';
import 'package:myapp/services/download_service.dart';
import 'package:myapp/services/history_service.dart';
import 'package:myapp/services/playlist_service.dart';
import 'package:myapp/services/profile_service.dart';
import 'package:myapp/services/song_stream_cache_service.dart';
import 'package:myapp/services/social_service.dart';
import 'package:myapp/services/yt_resolver_service.dart';
import 'package:myapp/social_friends_page.dart';
import 'package:myapp/services/thumbnail_cache_service.dart';
import 'package:myapp/search_page.dart';
import 'package:myapp/utils/artist_name_utils.dart';
import 'package:myapp/utils/thumbnail_quality.dart';
import 'package:myapp/video_player_manager.dart';
import 'package:myapp/widgets/ios_notice.dart';
import 'package:myapp/widgets/playlist_picker_sheet.dart';
import 'package:myapp/widgets/queue_swipe_action_button.dart';
import 'package:myapp/widgets/square_thumbnail.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
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
  final Map<String, Future<_HomeResolvedAlbumRef?>> _albumRefByVideoIdInFlight =
      {};

  @override
  void initState() {
    super.initState();
    _contentFuture = _loadContent();
    _trendingFuture = _loadTrendingTracks();
    unawaited(_warmHomeArtworkCache());
  }

  @override
  void dispose() {
    _yt.close();
    super.dispose();
  }

  Future<void> _warmHomeArtworkCache() async {
    try {
      final content = await _contentFuture;
      final trending = await _trendingFuture;
      final urls = <String>[
        ...content.suggestions.map((item) => item.thumbnailUrl),
        ...content.relisten.map((item) => item.thumbnailUrl),
        ...content.mixes.expand(
          (mix) => mix.tracks.map((item) => item.thumbnailUrl),
        ),
        ...content.curatedShelves.expand(
          (shelf) => shelf.tracks.map((item) => item.thumbnailUrl),
        ),
        ...trending.map((item) => item.thumbnailUrl),
      ];
      await ThumbnailCacheService.prefetchUrls(urls, maxItems: 36);
    } catch (_) {
      // Best effort.
    }
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

  Future<List<_HomeShelf>> _loadCuratedShelves(
    List<VideoHistory> history,
  ) async {
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
    final isTopicAuthor =
        author.endsWith('- topic') || author.endsWith('topic');
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
                    artist: cleanArtistName(
                      (trackRaw['artist'] ?? '').toString(),
                    ),
                    thumbnailUrl: (trackRaw['thumbnailUrl'] ?? '').toString(),
                    isLocal: false,
                  ),
                )
                .where(
                  (track) => track.videoId.isNotEmpty && track.title.isNotEmpty,
                )
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

  Future<void> _saveTrackToPlaylist(
    _HomeTrack track,
    String playlistName,
  ) async {
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

  Future<void> _runTrackContextAction(
    _HomeTrack track,
    _TrackContextAction action,
  ) async {
    if (action == _TrackContextAction.addNext) {
      await _addTrackToQueue(track, insertMode: ManualQueueInsertMode.next);
      return;
    }
    if (action == _TrackContextAction.addToEnd) {
      await _addTrackToQueue(track, insertMode: ManualQueueInsertMode.end);
      return;
    }
    if (action == _TrackContextAction.addToFavorites) {
      await _saveTrackToPlaylist(track, PlaylistService.favoritesPlaylistName);
      return;
    }
    if (action == _TrackContextAction.addToPlaylist) {
      await _addTrackToPlaylist(track);
      return;
    }
    if (action == _TrackContextAction.share) {
      await _shareTrackDeepLink(track);
      return;
    }
    if (action == _TrackContextAction.openArtist) {
      await _openArtistFromTrack(track);
      return;
    }
    if (action == _TrackContextAction.openAlbum) {
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
      context.read<SearchViewState>().requestOpenArtistProfile(
        PendingArtistProfile(
          channelId: channelId,
          channelName: details.title,
          channelThumbnailUrl: details.logoUrl,
        ),
      );
      context.read<AppTabState?>()?.setIndex(1);
    } catch (_) {
      if (!mounted) return;
      showIosNotice(context, 'No se pudo abrir el perfil del artista.');
    }
  }

  Future<void> _openAlbumFromTrack(_HomeTrack track) async {
    try {
      final resolved = await _resolveAlbumFromSearchFallback(track);
      if (!mounted) return;
      if (resolved == null) {
        showIosNotice(
          context,
          'No se pudo identificar el álbum de esta canción.',
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
      showIosNotice(context, 'No se pudo abrir el álbum.');
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
              return CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  CupertinoSliverRefreshControl(onRefresh: _refresh),
                  const SliverToBoxAdapter(child: SizedBox(height: 180)),
                  const SliverToBoxAdapter(
                    child: Center(child: Text('No se pudo cargar Inicio.')),
                  ),
                ],
              );
            }
            final relistenColumns = _buildTrackColumns(
              content.relisten,
              itemsPerColumn: 4,
            );

            return CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                CupertinoSliverRefreshControl(onRefresh: _refresh),
                const SliverToBoxAdapter(child: SizedBox(height: 12)),
                const SliverToBoxAdapter(child: _HomeProfileNowPlayingHeader()),
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
                    title: 'Explorar en VM Music',
                    subtitle:
                        'Quick picks, throwbacks y playlists en tendencia',
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
                            separatorBuilder: (_, _) =>
                                const SizedBox(width: 12),
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
                                onContextAction: _runTrackContextAction,
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
                            separatorBuilder: (_, _) =>
                                const SizedBox(width: 12),
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
                          onContextAction: _runTrackContextAction,
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
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: SizedBox(
                              height: 76,
                              child: _CompactReplayCard(
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
                                onContextAction: (action) =>
                                    _runTrackContextAction(item, action),
                                allowSwipeToQueue: true,
                                thin: true,
                              ),
                            ),
                          );
                        },
                      ),
                    );
                  },
                ),
                SliverToBoxAdapter(child: SizedBox(height: bottomReserve)),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _HomeProfileNowPlayingHeader extends StatefulWidget {
  const _HomeProfileNowPlayingHeader();

  @override
  State<_HomeProfileNowPlayingHeader> createState() =>
      _HomeProfileNowPlayingHeaderState();
}

class _HomeProfileNowPlayingHeaderState
    extends State<_HomeProfileNowPlayingHeader> {
  List<SocialUser> _followingUsers = const <SocialUser>[];
  final YoutubeExplode _yt = YoutubeExplode();
  final AudioPlayer _friendPreviewPlayer = AudioPlayer();
  final YtResolverService _ytResolverService = YtResolverService();
  RealtimeChannel? _friendRealtimeChannel;
  Set<String> _followingIds = <String>{};
  Timer? _friendRefreshTimer;
  final Map<String, String> _friendPhotoUrlById = <String, String>{};
  final Map<String, ImageProvider<Object>> _friendImageById =
      <String, ImageProvider<Object>>{};
  final Map<String, String> _friendPreviewVideoIdByFriendId = <String, String>{};
  final Map<String, String> _friendPreviewUrlByFriendId = <String, String>{};
  bool _resumeMainPlayerAfterPreview = false;
  final ValueNotifier<bool> _isFriendPreviewLoading = ValueNotifier<bool>(false);
  int _friendPreviewRequestEpoch = 0;
  StreamSubscription<PlayerState>? _friendPreviewStateSub;

  void _setFriendPreviewLoading(bool value) {
    if (_isFriendPreviewLoading.value == value) return;
    _isFriendPreviewLoading.value = value;
  }

  void _startFriendPreviewPlayback(int requestEpoch) {
    unawaited(_startFriendPreviewPlaybackAsync(requestEpoch));
  }

  Future<void> _startFriendPreviewPlaybackAsync(int requestEpoch) async {
    try {
      await _friendPreviewPlayer.seek(const Duration(minutes: 1));
    } catch (_) {
      // Si el stream no permite seek inmediato, continuamos.
    }
    if (!mounted || requestEpoch != _friendPreviewRequestEpoch) return;
    unawaited(_friendPreviewPlayer.play());
    if (!mounted || requestEpoch != _friendPreviewRequestEpoch) return;
    if (_friendPreviewPlayer.playing ||
        _friendPreviewPlayer.processingState == ProcessingState.ready) {
      _setFriendPreviewLoading(false);
      return;
    }
    unawaited(_settleFriendPreviewLoading(requestEpoch));
  }

  Future<void> _settleFriendPreviewLoading(int requestEpoch) async {
    for (var i = 0; i < 14; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      if (!mounted || requestEpoch != _friendPreviewRequestEpoch) return;
      if (_friendPreviewPlayer.playing ||
          _friendPreviewPlayer.processingState == ProcessingState.ready) {
        _setFriendPreviewLoading(false);
        return;
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _friendPreviewStateSub = _friendPreviewPlayer.playerStateStream.listen((
      state,
    ) {
      if (!mounted) return;
      if (_isFriendPreviewLoading.value &&
          (state.playing || state.processingState == ProcessingState.ready)) {
        _setFriendPreviewLoading(false);
      }
    });
    unawaited(_loadFollowingPreview());
  }

  Future<void> _loadFollowingPreview() async {
    try {
      final social = context.read<SocialService>();
      await social.ensureReady();
      final following = await social.getFollowingUsers();
      if (!mounted) return;
      _attachRealtimeToFriends(following);
      _pruneFriendImageCache(following.map((u) => u.id).toSet());
      final hasListChanges = !_sameSocialUserList(_followingUsers, following);
      final nextIds = following.map((u) => u.id).toSet();
      final hasIdChanges =
          nextIds.length != _followingIds.length ||
          !nextIds.containsAll(_followingIds);
      if (!hasListChanges && !hasIdChanges) return;
      setState(() {
        _followingUsers = following;
        _followingIds = nextIds;
      });
    } catch (_) {
      if (!mounted) return;
      _detachFriendRealtime();
      _pruneFriendImageCache(const <String>{});
      setState(() {
        _followingUsers = const <SocialUser>[];
        _followingIds = <String>{};
      });
    }
  }

  void _attachRealtimeToFriends(List<SocialUser> users) {
    final ids = users
        .map((u) => u.id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (ids.isEmpty) {
      _detachFriendRealtime();
      return;
    }
    final sameSet =
        ids.length == _followingIds.length && ids.containsAll(_followingIds);
    if (sameSet && _friendRealtimeChannel != null) return;
    _detachFriendRealtime();
    final client = Supabase.instance.client;
    _followingIds = ids;
    _friendRefreshTimer?.cancel();
    _friendRefreshTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      unawaited(_refreshFriendsFromServer(ids));
    });
    _friendRealtimeChannel = client.channel('friends-live-all')
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'users',
        callback: (payload) {
          if (!mounted) return;
          final map = payload.newRecord;
          if (map.isEmpty) return;
          final id = (map['id'] ?? '').toString().trim();
          if (id.isEmpty || !_followingIds.contains(id)) return;
          final updated = SocialUser.fromMap(Map<String, dynamic>.from(map));
          final index = _followingUsers.indexWhere((u) => u.id == id);
          if (index == -1) return;
          final current = _followingUsers[index];
          if (_sameSocialUser(current, updated)) return;
          unawaited(_invalidateFriendPreviewCacheIfSongChanged(current, updated));
          setState(() {
            final next = List<SocialUser>.from(
              _followingUsers,
              growable: false,
            );
            next[index] = updated;
            _followingUsers = next;
          });
        },
      )
      ..subscribe();
    unawaited(_refreshFriendsFromServer(ids));
  }

  Future<void> _refreshFriendsFromServer(Set<String> ids) async {
    try {
      if (ids.isEmpty) return;
      final rows = await Supabase.instance.client
          .from('users')
          .select()
          .inFilter('id', ids.toList(growable: false));
      if (!mounted || rows.isEmpty) return;
      final byId = <String, SocialUser>{};
      for (final row in rows) {
        final user = SocialUser.fromMap(Map<String, dynamic>.from(row));
        byId[user.id] = user;
      }
      bool changed = false;
      final next = <SocialUser>[];
      for (final user in _followingUsers) {
        final refreshed = byId[user.id] ?? user;
        if (!_sameSocialUser(user, refreshed)) changed = true;
        unawaited(_invalidateFriendPreviewCacheIfSongChanged(user, refreshed));
        next.add(refreshed);
      }
      if (!changed) return;
      setState(() {
        _followingUsers = List<SocialUser>.unmodifiable(next);
      });
    } catch (_) {
      // Fallback silencioso.
    }
  }

  void _detachFriendRealtime() {
    final channel = _friendRealtimeChannel;
    _friendRealtimeChannel = null;
    _friendRefreshTimer?.cancel();
    _friendRefreshTimer = null;
    if (channel != null) {
      Supabase.instance.client.removeChannel(channel);
    }
  }

  bool _sameSocialUser(SocialUser a, SocialUser b) {
    return a.id == b.id &&
        a.name == b.name &&
        a.username == b.username &&
        (a.photoUrl ?? '') == (b.photoUrl ?? '') &&
        (a.frameUrl ?? '') == (b.frameUrl ?? '') &&
        (a.currentVideoId ?? '') == (b.currentVideoId ?? '') &&
        a.note == b.note &&
        a.currentSong == b.currentSong &&
        a.currentArtist == b.currentArtist &&
        a.isPlaying == b.isPlaying &&
        a.updatedAt == b.updatedAt;
  }

  bool _sameSocialUserList(List<SocialUser> a, List<SocialUser> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_sameSocialUser(a[i], b[i])) return false;
    }
    return true;
  }

  void _pruneFriendImageCache(Set<String> validIds) {
    _friendPhotoUrlById.removeWhere((id, _) => !validIds.contains(id));
    _friendImageById.removeWhere((id, _) => !validIds.contains(id));
    _friendPreviewVideoIdByFriendId.removeWhere((id, _) => !validIds.contains(id));
    _friendPreviewUrlByFriendId.removeWhere((id, _) => !validIds.contains(id));
  }

  Future<void> _invalidateFriendPreviewCacheIfSongChanged(
    SocialUser previous,
    SocialUser next,
  ) async {
    if (previous.id != next.id) return;
    final oldVideoId = (previous.currentVideoId ?? '').trim();
    final newVideoId = (next.currentVideoId ?? '').trim();
    if (oldVideoId.isEmpty || oldVideoId == newVideoId) return;
    _friendPreviewVideoIdByFriendId.remove(previous.id);
    _friendPreviewUrlByFriendId.remove(previous.id);
    await SongStreamCacheService.evictVideoId(oldVideoId);
  }

  @override
  void dispose() {
    unawaited(_friendPreviewStateSub?.cancel());
    _isFriendPreviewLoading.dispose();
    unawaited(_friendPreviewPlayer.dispose());
    _yt.close();
    _detachFriendRealtime();
    super.dispose();
  }

  Future<void> _playFriendPreviewAudio({
    required String? friendId,
    required String? videoId,
  }) async {
    final ownerId = (friendId ?? '').trim();
    final id = (videoId ?? '').trim();
    if (ownerId.isEmpty || id.isEmpty) return;

    final manager = context.read<VideoPlayerManager>();
    final shouldPauseMain = manager.isPlaying;
    if (shouldPauseMain) {
      _resumeMainPlayerAfterPreview = true;
      await manager.togglePlayPause();
    } else {
      _resumeMainPlayerAfterPreview = false;
    }

    final requestEpoch = ++_friendPreviewRequestEpoch;
    if (mounted) {
      _setFriendPreviewLoading(true);
    }
    try {
      final cachedVideoId = _friendPreviewVideoIdByFriendId[ownerId];
      final cachedUrl = (_friendPreviewUrlByFriendId[ownerId] ?? '').trim();
      if (cachedVideoId == id && cachedUrl.isNotEmpty) {
        await _friendPreviewPlayer.stop();
        if (!mounted || requestEpoch != _friendPreviewRequestEpoch) return;
        if (!kIsWeb && cachedUrl.startsWith('/')) {
          final cachedFile = File(cachedUrl);
          if (await cachedFile.exists()) {
            await _friendPreviewPlayer.setFilePath(cachedUrl);
            if (!mounted || requestEpoch != _friendPreviewRequestEpoch) return;
            _startFriendPreviewPlayback(requestEpoch);
            return;
          }
        }
        await _friendPreviewPlayer.setUrl(cachedUrl);
        if (!mounted || requestEpoch != _friendPreviewRequestEpoch) return;
        _startFriendPreviewPlayback(requestEpoch);
        return;
      }

      if (!kIsWeb) {
        final cachedFilePath = await SongStreamCacheService.resolveFreshFilePath(id);
        if (!mounted || requestEpoch != _friendPreviewRequestEpoch) return;
        if (cachedFilePath != null && cachedFilePath.isNotEmpty) {
          await _friendPreviewPlayer.stop();
          if (!mounted || requestEpoch != _friendPreviewRequestEpoch) return;
          await _friendPreviewPlayer.setFilePath(cachedFilePath);
          if (!mounted || requestEpoch != _friendPreviewRequestEpoch) return;
          _startFriendPreviewPlayback(requestEpoch);
          _friendPreviewVideoIdByFriendId[ownerId] = id;
          _friendPreviewUrlByFriendId[ownerId] = cachedFilePath;
          return;
        }
      }

      final resolved = await _ytResolverService.resolveVideo(id);
      if (!mounted || requestEpoch != _friendPreviewRequestEpoch) return;
      String? pickValidUrl(Iterable<String?> candidates) {
        for (final raw in candidates) {
          final trimmed = (raw ?? '').trim();
          if (trimmed.isEmpty) continue;
          final uri = Uri.tryParse(trimmed);
          if (uri == null) continue;
          if (uri.hasScheme && (uri.scheme == 'http' || uri.scheme == 'https')) {
            return trimmed;
          }
        }
        return null;
      }

      bool isIosFriendlyAudioSource(String rawUrl) {
        final trimmed = rawUrl.trim();
        if (trimmed.isEmpty) return false;
        final uri = Uri.tryParse(trimmed);
        if (uri == null) return false;
        final path = uri.path.toLowerCase();
        final mime = (uri.queryParameters['mime'] ?? '')
            .toLowerCase()
            .replaceAll(' ', '');
        if (mime.contains('audio/webm') || mime.contains('audio/ogg')) {
          return false;
        }
        if (path.endsWith('.webm') || path.endsWith('.ogg')) return false;
        return true;
      }

      bool isIosFriendlyVideoSource(String rawUrl) {
        final trimmed = rawUrl.trim();
        if (trimmed.isEmpty) return false;
        final uri = Uri.tryParse(trimmed);
        if (uri == null) return false;
        final path = uri.path.toLowerCase();
        final mime = (uri.queryParameters['mime'] ?? '')
            .toLowerCase()
            .replaceAll(' ', '');
        if (mime.contains('video/webm') || mime.contains('video/ogg')) {
          return false;
        }
        return path.endsWith('.mp4') ||
            path.endsWith('.m3u8') ||
            path.endsWith('.mov') ||
            mime.contains('video/mp4') ||
            mime.contains('application/x-mpegurl') ||
            mime.contains('application/vnd.apple.mpegurl') ||
            path == '/stream' ||
            path.endsWith('/stream');
      }

      bool isAllowedForPlatform(String url, {required bool isVideo}) {
        if (kIsWeb) return true;
        if (!Platform.isIOS) return true;
        return isVideo
            ? isIosFriendlyVideoSource(url)
            : isIosFriendlyAudioSource(url);
      }

      var previewUrl = pickValidUrl(<String?>[
            // Igual que el player principal para fuentes de backend:
            // en iOS suele ser más compatible muxed/source que audio webm.
            resolved?.muxedUrl,
            resolved?.audioUrl,
            resolved?.sourceUrl,
          ]) ??
          '';
      if (previewUrl.isNotEmpty &&
          !isAllowedForPlatform(
            previewUrl,
            isVideo: previewUrl == (resolved?.muxedUrl ?? '').trim(),
          )) {
        previewUrl = '';
      }
      if (previewUrl.trim().isEmpty) {
        final manifest = await _yt.videos.streamsClient.getManifest(id);
        if (!mounted || requestEpoch != _friendPreviewRequestEpoch) return;
        AudioOnlyStreamInfo? bestAudio;
        for (final stream in manifest.audioOnly) {
          if (bestAudio == null ||
              stream.bitrate.bitsPerSecond > bestAudio.bitrate.bitsPerSecond) {
            bestAudio = stream;
          }
        }
        if (bestAudio != null) {
          previewUrl = bestAudio.url.toString();
        } else {
          MuxedStreamInfo? bestMuxed;
          for (final stream in manifest.muxed) {
            if (bestMuxed == null ||
                stream.bitrate.bitsPerSecond > bestMuxed.bitrate.bitsPerSecond) {
              bestMuxed = stream;
            }
          }
          previewUrl = bestMuxed?.url.toString() ?? '';
        }
      }
      if (previewUrl.trim().isEmpty) return;

      await _friendPreviewPlayer.stop();
      if (!mounted || requestEpoch != _friendPreviewRequestEpoch) return;
      await _friendPreviewPlayer.setUrl(previewUrl);
      if (!mounted || requestEpoch != _friendPreviewRequestEpoch) return;
      _startFriendPreviewPlayback(requestEpoch);
      _friendPreviewVideoIdByFriendId[ownerId] = id;
      _friendPreviewUrlByFriendId[ownerId] = previewUrl;
      final warmUri = Uri.tryParse(previewUrl);
      if (warmUri != null && !kIsWeb) {
        unawaited(
          SongStreamCacheService.warmFromStreamUrl(
            videoId: id,
            streamUri: warmUri,
          ),
        );
      }
    } catch (e, s) {
      debugPrint('[friend-preview] play failed videoId=$id error=$e');
      debugPrintStack(
        stackTrace: s,
        label: '[friend-preview] stack videoId=$id',
      );
      if (mounted && requestEpoch == _friendPreviewRequestEpoch) {
        _setFriendPreviewLoading(false);
      }
    }
  }

  Future<void> _stopFriendPreviewAudio() async {
    _friendPreviewRequestEpoch++;
    if (mounted) {
      _setFriendPreviewLoading(false);
    }
    try {
      await _friendPreviewPlayer.stop();
    } catch (_) {
      // Ignorar.
    }
    if (!_resumeMainPlayerAfterPreview) return;
    _resumeMainPlayerAfterPreview = false;
    if (!mounted) return;
    final manager = context.read<VideoPlayerManager>();
    if (!manager.isPlaying && manager.currentVideoId != null) {
      await manager.togglePlayPause();
    }
  }

  Future<void> _playSongFromNowPlayingNote({
    required String titleText,
    required String artistText,
    String? preferredVideoId,
    String? preferredThumbnailUrl,
  }) async {
    final manager = context.read<VideoPlayerManager>();
    final directVideoId = (preferredVideoId ?? '').trim();
    if (directVideoId.isEmpty) {
      if (!mounted) return;
      showIosNotice(context, 'Surgio un problema al intentarlo.');
      return;
    }
    final preferredTitle = titleText.trim();
    final preferredArtist = artistText.trim();
    final thumbnailFallback =
        'https://i.ytimg.com/vi/$directVideoId/hqdefault.jpg';
    final thumb = (preferredThumbnailUrl ?? '').trim();
    try {
      await manager.playFromUserSelection(
        context,
        directVideoId,
        preferredTitle: preferredTitle.isEmpty ? null : preferredTitle,
        preferredArtist: preferredArtist.isEmpty ? null : preferredArtist,
        preferredThumbnailUrl: thumb.isEmpty ? thumbnailFallback : thumb,
      );
    } catch (_) {
      if (!mounted) return;
      showIosNotice(context, 'Surgio un problema al intentarlo.');
    }
  }

  Future<void> _addNowPlayingToQueue({
    required String videoId,
    required String title,
    required String artist,
    required String thumbnailUrl,
    required ManualQueueInsertMode insertMode,
  }) async {
    final manager = context.read<VideoPlayerManager>();
    final added = manager.addOnlineTrackToPlaybackQueue(
      videoId: videoId,
      title: title,
      thumbnailUrl: thumbnailUrl,
      artist: artist,
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

  Future<void> _saveNowPlayingToPlaylist({
    required String playlistName,
    required String videoId,
    required String title,
    required String artist,
    required String thumbnailUrl,
  }) async {
    final playlistService = context.read<PlaylistService>();
    final downloadService = context.read<DownloadService>();
    final videoManager = context.read<VideoPlayerManager>();
    final entry = VideoHistory(
      videoId: videoId,
      title: title,
      thumbnailUrl: thumbnailUrl,
      channelTitle: artist,
      watchedAt: DateTime.now(),
    );
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

  Future<void> _addNowPlayingToPlaylistPicker({
    required String videoId,
    required String title,
    required String artist,
    required String thumbnailUrl,
  }) async {
    final playlistService = context.read<PlaylistService>();
    final playlists = await playlistService.getPlaylists();
    if (!mounted || playlists.isEmpty) return;
    final selectedName = await showGlassPlaylistPickerSheet(
      context: context,
      playlists: playlists,
      subtitle: title,
    );
    if (!mounted || selectedName == null || selectedName.isEmpty) return;
    await _saveNowPlayingToPlaylist(
      playlistName: selectedName,
      videoId: videoId,
      title: title,
      artist: artist,
      thumbnailUrl: thumbnailUrl,
    );
  }

  Future<void> _openArtistFromNowPlaying(String videoId) async {
    final cleanId = videoId.trim();
    if (cleanId.isEmpty) return;
    try {
      final details = await _yt.channels.getByVideo(cleanId);
      if (!mounted) return;
      final channelId = details.id.value.trim();
      if (channelId.isEmpty) return;
      context.read<SearchViewState>().requestOpenArtistProfile(
        PendingArtistProfile(
          channelId: channelId,
          channelName: details.title,
          channelThumbnailUrl: details.logoUrl,
        ),
      );
      context.read<AppTabState?>()?.setIndex(1);
    } catch (_) {
      if (!mounted) return;
      showIosNotice(context, 'No se pudo abrir el perfil del artista.');
    }
  }

  Future<void> _openAlbumFromNowPlaying({
    required String videoId,
    required String title,
    required String artist,
    required String thumbnailUrl,
  }) async {
    try {
      final resolved = await resolveAlbumFromSongAndArtistLikeSearch(
        songTitle: title,
        artistName: artist,
      );
      if (!mounted) return;
      if (resolved == null) {
        showIosNotice(
          context,
          'No se pudo identificar el álbum de esta canción.',
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
                : thumbnailUrl,
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      showIosNotice(context, 'No se pudo abrir el álbum.');
    }
  }

  Future<void> _openExpandedSocialCard({
    required Widget titleNote,
    required VoidCallback? onPlayNowFromTitleMenu,
    required String noteText,
    required String footerText,
    required ImageProvider<Object>? imageProvider,
    required String? frameImageUrl,
    String? autoplayVideoId,
    String? autoplayFriendId,
    VoidCallback? onAddNextFromTitleMenu,
    VoidCallback? onAddToEndFromTitleMenu,
    VoidCallback? onAddToFavoritesFromTitleMenu,
    VoidCallback? onAddToPlaylistFromTitleMenu,
    VoidCallback? onOpenArtistFromTitleMenu,
    VoidCallback? onOpenAlbumFromTitleMenu,
  }) async {
    final previewId = (autoplayVideoId ?? '').trim();
    if (previewId.isNotEmpty) {
      unawaited(
        _playFriendPreviewAudio(
          friendId: autoplayFriendId,
          videoId: previewId,
        ),
      );
    }
    try {
      await showGeneralDialog<void>(
        context: context,
        barrierLabel: 'Cerrar',
        barrierDismissible: true,
        barrierColor: Colors.black.withValues(alpha: 0.14),
        transitionDuration: const Duration(milliseconds: 280),
        pageBuilder: (context, animation, secondaryAnimation) {
          final expandedPlayNowAction = onPlayNowFromTitleMenu == null
              ? null
              : () {
                  onPlayNowFromTitleMenu();
                  if (Navigator.of(context).canPop()) {
                    Navigator.of(context).pop();
                  }
                };
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.of(context).pop(),
            child: Stack(
              children: [
                Positioned.fill(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                    child: const SizedBox.expand(),
                  ),
                ),
                Center(
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      GestureDetector(
                        onTap: () {},
                        child: _HomeSocialPreviewCard(
                          titleNote: titleNote,
                          onPlayNowFromTitleMenu: expandedPlayNowAction,
                          onAddNextFromTitleMenu: onAddNextFromTitleMenu,
                          onAddToEndFromTitleMenu: onAddToEndFromTitleMenu,
                          onAddToFavoritesFromTitleMenu:
                              onAddToFavoritesFromTitleMenu,
                          onAddToPlaylistFromTitleMenu:
                              onAddToPlaylistFromTitleMenu,
                          onOpenArtistFromTitleMenu: onOpenArtistFromTitleMenu,
                          onOpenAlbumFromTitleMenu: onOpenAlbumFromTitleMenu,
                          noteText: noteText,
                          footerText: footerText,
                          imageProvider: imageProvider,
                          frameImageUrl: frameImageUrl,
                          scale: 1.65,
                        ),
                      ),
                      ValueListenableBuilder<bool>(
                        valueListenable: _isFriendPreviewLoading,
                        builder: (context, isLoading, child) {
                          if (!isLoading) return const SizedBox.shrink();
                          return Positioned(
                            top: 14,
                            right: 14,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: CupertinoColors.systemBackground
                                    .resolveFrom(context)
                                    .withValues(alpha: 0.86),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: const Padding(
                                padding: EdgeInsets.all(8),
                                child: CupertinoActivityIndicator(radius: 10),
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
        transitionBuilder: (context, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.9, end: 1.0).animate(curved),
              child: child,
            ),
          );
        },
      );
    } finally {
      await _stopFriendPreviewAudio();
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = context.watch<ProfileService>();
    final currentTrackTitle = context.select<VideoPlayerManager, String?>(
      (manager) => manager.trackTitle,
    );
    final currentTrackArtist = context.select<VideoPlayerManager, String?>(
      (manager) => manager.trackArtist,
    );
    final isPlaying = context.select<VideoPlayerManager, bool>(
      (manager) => manager.isPlaying,
    );
    final currentVideoId = context.select<VideoPlayerManager, String?>(
      (manager) => manager.currentVideoId,
    );
    final hasTrack =
        (currentTrackTitle ?? '').trim().isNotEmpty ||
        (currentVideoId ?? '').trim().isNotEmpty;
    final safeTrackTitle = (currentTrackTitle ?? '').trim();
    final titleText = hasTrack
        ? (safeTrackTitle.isNotEmpty
              ? safeTrackTitle
              : 'Reproduciendo ahora')
        : 'No estas reproduciendo nada ahora.';
    final artistText = (currentTrackArtist ?? '').trim();
    final bioText = profile.bio.trim().isEmpty
        ? 'Escribe algo...'
        : profile.bio.trim();
    final photoPath = (profile.photoPath ?? '').trim();
    final frameUrl = (profile.frameUrl ?? '').trim();
    final hasLocalPhoto = photoPath.isNotEmpty && File(photoPath).existsSync();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _HomeSocialPreviewCard(
                key: const ValueKey<String>('home-social-self'),
                titleNote: _HomeAnimatedNowPlayingNote(
                  titleText: titleText,
                  artistText: artistText,
                  hasTrack: hasTrack,
                  isPlaying: isPlaying,
                ),
                onPlayNowFromTitleMenu: hasTrack
                    ? () => _playSongFromNowPlayingNote(
                        titleText: titleText,
                        artistText: artistText,
                        preferredVideoId: context
                            .read<VideoPlayerManager>()
                            .currentVideoId,
                        preferredThumbnailUrl: context
                            .read<VideoPlayerManager>()
                            .trackThumbnailUrl,
                      )
                    : null,
                onAddNextFromTitleMenu: hasTrack
                    ? () => _addNowPlayingToQueue(
                        videoId: (currentVideoId ?? '').trim(),
                        title: titleText,
                        artist: artistText,
                        thumbnailUrl:
                            context.read<VideoPlayerManager>().trackThumbnailUrl ??
                            '',
                        insertMode: ManualQueueInsertMode.next,
                      )
                    : null,
                onAddToEndFromTitleMenu: hasTrack
                    ? () => _addNowPlayingToQueue(
                        videoId: (currentVideoId ?? '').trim(),
                        title: titleText,
                        artist: artistText,
                        thumbnailUrl:
                            context.read<VideoPlayerManager>().trackThumbnailUrl ??
                            '',
                        insertMode: ManualQueueInsertMode.end,
                      )
                    : null,
                onAddToFavoritesFromTitleMenu: hasTrack
                    ? () => _saveNowPlayingToPlaylist(
                        playlistName: PlaylistService.favoritesPlaylistName,
                        videoId: (currentVideoId ?? '').trim(),
                        title: titleText,
                        artist: artistText,
                        thumbnailUrl:
                            context.read<VideoPlayerManager>().trackThumbnailUrl ??
                            '',
                      )
                    : null,
                onAddToPlaylistFromTitleMenu: hasTrack
                    ? () => _addNowPlayingToPlaylistPicker(
                        videoId: (currentVideoId ?? '').trim(),
                        title: titleText,
                        artist: artistText,
                        thumbnailUrl:
                            context.read<VideoPlayerManager>().trackThumbnailUrl ??
                            '',
                      )
                    : null,
                onOpenArtistFromTitleMenu: hasTrack
                    ? () => _openArtistFromNowPlaying((currentVideoId ?? '').trim())
                    : null,
                onOpenAlbumFromTitleMenu: hasTrack
                    ? () => _openAlbumFromNowPlaying(
                        videoId: (currentVideoId ?? '').trim(),
                        title: titleText,
                        artist: artistText,
                        thumbnailUrl:
                            context.read<VideoPlayerManager>().trackThumbnailUrl ??
                            '',
                      )
                    : null,
                noteText: bioText,
                footerText: 'Tu',
                imageProvider: hasLocalPhoto
                    ? FileImage(File(photoPath))
                    : null,
                frameImageUrl: frameUrl.isEmpty ? null : frameUrl,
                onTap: () => _openExpandedSocialCard(
                  titleNote: _HomeAnimatedNowPlayingNote(
                    titleText: titleText,
                    artistText: artistText,
                    hasTrack: hasTrack,
                    isPlaying: isPlaying,
                  ),
                  onPlayNowFromTitleMenu: hasTrack
                      ? () => _playSongFromNowPlayingNote(
                          titleText: titleText,
                          artistText: artistText,
                          preferredVideoId: context
                              .read<VideoPlayerManager>()
                              .currentVideoId,
                          preferredThumbnailUrl: context
                              .read<VideoPlayerManager>()
                              .trackThumbnailUrl,
                        )
                      : null,
                  onAddNextFromTitleMenu: hasTrack
                      ? () => _addNowPlayingToQueue(
                          videoId: (currentVideoId ?? '').trim(),
                          title: titleText,
                          artist: artistText,
                          thumbnailUrl: context
                                  .read<VideoPlayerManager>()
                                  .trackThumbnailUrl ??
                              '',
                          insertMode: ManualQueueInsertMode.next,
                        )
                      : null,
                  onAddToEndFromTitleMenu: hasTrack
                      ? () => _addNowPlayingToQueue(
                          videoId: (currentVideoId ?? '').trim(),
                          title: titleText,
                          artist: artistText,
                          thumbnailUrl: context
                                  .read<VideoPlayerManager>()
                                  .trackThumbnailUrl ??
                              '',
                          insertMode: ManualQueueInsertMode.end,
                        )
                      : null,
                  onAddToFavoritesFromTitleMenu: hasTrack
                      ? () => _saveNowPlayingToPlaylist(
                          playlistName: PlaylistService.favoritesPlaylistName,
                          videoId: (currentVideoId ?? '').trim(),
                          title: titleText,
                          artist: artistText,
                          thumbnailUrl: context
                                  .read<VideoPlayerManager>()
                                  .trackThumbnailUrl ??
                              '',
                        )
                      : null,
                  onAddToPlaylistFromTitleMenu: hasTrack
                      ? () => _addNowPlayingToPlaylistPicker(
                          videoId: (currentVideoId ?? '').trim(),
                          title: titleText,
                          artist: artistText,
                          thumbnailUrl: context
                                  .read<VideoPlayerManager>()
                                  .trackThumbnailUrl ??
                              '',
                        )
                      : null,
                  onOpenArtistFromTitleMenu: hasTrack
                      ? () => _openArtistFromNowPlaying(
                          (currentVideoId ?? '').trim(),
                        )
                      : null,
                  onOpenAlbumFromTitleMenu: hasTrack
                      ? () => _openAlbumFromNowPlaying(
                          videoId: (currentVideoId ?? '').trim(),
                          title: titleText,
                          artist: artistText,
                          thumbnailUrl: context
                                  .read<VideoPlayerManager>()
                                  .trackThumbnailUrl ??
                              '',
                        )
                      : null,
                  noteText: bioText,
                  footerText: 'Tu',
                  imageProvider: hasLocalPhoto ? FileImage(File(photoPath)) : null,
                  frameImageUrl: frameUrl.isEmpty ? null : frameUrl,
                ),
              ),
              const SizedBox(width: 26),
              ..._followingUsers.map((friend) {
                final friendSong = friend.currentSong.trim();
                final friendArtist = friend.currentArtist.trim();
                final friendFrameUrlRaw = (friend.frameUrl ?? '').trim();
                final friendFrameUrl = friendFrameUrlRaw.isEmpty
                    ? null
                    : friendFrameUrlRaw;
                final friendHasTrack =
                    friendSong.isNotEmpty ||
                    (friend.currentVideoId ?? '').trim().isNotEmpty;
                final friendTitleText = friendHasTrack
                    ? friendSong
                    : 'No esta reproduciendo nada ahora.';
                return Padding(
                  key: ValueKey<String>('home-social-friend-${friend.id}'),
                  padding: const EdgeInsets.only(right: 26),
                  child: _HomeSocialPreviewCard(
                    key: ValueKey<String>(
                      'home-social-friend-card-${friend.id}',
                    ),
                    titleNote: _HomeAnimatedNowPlayingNote(
                      titleText: friendTitleText,
                      artistText: friendArtist,
                      hasTrack: friendHasTrack,
                      isPlaying: friend.isPlaying,
                    ),
                    onPlayNowFromTitleMenu: friendHasTrack
                        ? () => _playSongFromNowPlayingNote(
                            titleText: friendTitleText,
                            artistText: friendArtist,
                            preferredVideoId: friend.currentVideoId,
                            preferredThumbnailUrl:
                                'https://i.ytimg.com/vi/${(friend.currentVideoId ?? '').trim()}/hqdefault.jpg',
                          )
                        : null,
                    onAddNextFromTitleMenu: friendHasTrack
                        ? () => _addNowPlayingToQueue(
                            videoId: (friend.currentVideoId ?? '').trim(),
                            title: friendTitleText,
                            artist: friendArtist,
                            thumbnailUrl:
                                'https://i.ytimg.com/vi/${(friend.currentVideoId ?? '').trim()}/hqdefault.jpg',
                            insertMode: ManualQueueInsertMode.next,
                          )
                        : null,
                    onAddToEndFromTitleMenu: friendHasTrack
                        ? () => _addNowPlayingToQueue(
                            videoId: (friend.currentVideoId ?? '').trim(),
                            title: friendTitleText,
                            artist: friendArtist,
                            thumbnailUrl:
                                'https://i.ytimg.com/vi/${(friend.currentVideoId ?? '').trim()}/hqdefault.jpg',
                            insertMode: ManualQueueInsertMode.end,
                          )
                        : null,
                    onAddToFavoritesFromTitleMenu: friendHasTrack
                        ? () => _saveNowPlayingToPlaylist(
                            playlistName: PlaylistService.favoritesPlaylistName,
                            videoId: (friend.currentVideoId ?? '').trim(),
                            title: friendTitleText,
                            artist: friendArtist,
                            thumbnailUrl:
                                'https://i.ytimg.com/vi/${(friend.currentVideoId ?? '').trim()}/hqdefault.jpg',
                          )
                        : null,
                    onAddToPlaylistFromTitleMenu: friendHasTrack
                        ? () => _addNowPlayingToPlaylistPicker(
                            videoId: (friend.currentVideoId ?? '').trim(),
                            title: friendTitleText,
                            artist: friendArtist,
                            thumbnailUrl:
                                'https://i.ytimg.com/vi/${(friend.currentVideoId ?? '').trim()}/hqdefault.jpg',
                          )
                        : null,
                    onOpenArtistFromTitleMenu: friendHasTrack
                        ? () => _openArtistFromNowPlaying(
                            (friend.currentVideoId ?? '').trim(),
                          )
                        : null,
                    onOpenAlbumFromTitleMenu: friendHasTrack
                        ? () => _openAlbumFromNowPlaying(
                            videoId: (friend.currentVideoId ?? '').trim(),
                            title: friendTitleText,
                            artist: friendArtist,
                            thumbnailUrl:
                                'https://i.ytimg.com/vi/${(friend.currentVideoId ?? '').trim()}/hqdefault.jpg',
                          )
                        : null,
                    noteText: friend.note.trim().isEmpty
                        ? 'Escribe algo...'
                        : friend.note.trim(),
                    footerText: friend.name.trim().isEmpty
                        ? '@${friend.username}'
                        : friend.name.trim(),
                    imageProvider: _friendImageProvider(friend),
                    frameImageUrl: friendFrameUrl,
                    onTap: () => _openExpandedSocialCard(
                      titleNote: _HomeAnimatedNowPlayingNote(
                        titleText: friendTitleText,
                        artistText: friendArtist,
                        hasTrack: friendHasTrack,
                        isPlaying: friend.isPlaying,
                      ),
                      onPlayNowFromTitleMenu: friendHasTrack
                          ? () => _playSongFromNowPlayingNote(
                              titleText: friendTitleText,
                              artistText: friendArtist,
                              preferredVideoId: friend.currentVideoId,
                              preferredThumbnailUrl:
                                  'https://i.ytimg.com/vi/${(friend.currentVideoId ?? '').trim()}/hqdefault.jpg',
                            )
                          : null,
                      onAddNextFromTitleMenu: friendHasTrack
                          ? () => _addNowPlayingToQueue(
                              videoId: (friend.currentVideoId ?? '').trim(),
                              title: friendTitleText,
                              artist: friendArtist,
                              thumbnailUrl:
                                  'https://i.ytimg.com/vi/${(friend.currentVideoId ?? '').trim()}/hqdefault.jpg',
                              insertMode: ManualQueueInsertMode.next,
                            )
                          : null,
                      onAddToEndFromTitleMenu: friendHasTrack
                          ? () => _addNowPlayingToQueue(
                              videoId: (friend.currentVideoId ?? '').trim(),
                              title: friendTitleText,
                              artist: friendArtist,
                              thumbnailUrl:
                                  'https://i.ytimg.com/vi/${(friend.currentVideoId ?? '').trim()}/hqdefault.jpg',
                              insertMode: ManualQueueInsertMode.end,
                            )
                          : null,
                      onAddToFavoritesFromTitleMenu: friendHasTrack
                          ? () => _saveNowPlayingToPlaylist(
                              playlistName: PlaylistService.favoritesPlaylistName,
                              videoId: (friend.currentVideoId ?? '').trim(),
                              title: friendTitleText,
                              artist: friendArtist,
                              thumbnailUrl:
                                  'https://i.ytimg.com/vi/${(friend.currentVideoId ?? '').trim()}/hqdefault.jpg',
                            )
                          : null,
                      onAddToPlaylistFromTitleMenu: friendHasTrack
                          ? () => _addNowPlayingToPlaylistPicker(
                              videoId: (friend.currentVideoId ?? '').trim(),
                              title: friendTitleText,
                              artist: friendArtist,
                              thumbnailUrl:
                                  'https://i.ytimg.com/vi/${(friend.currentVideoId ?? '').trim()}/hqdefault.jpg',
                            )
                          : null,
                      onOpenArtistFromTitleMenu: friendHasTrack
                          ? () => _openArtistFromNowPlaying(
                              (friend.currentVideoId ?? '').trim(),
                            )
                          : null,
                      onOpenAlbumFromTitleMenu: friendHasTrack
                          ? () => _openAlbumFromNowPlaying(
                              videoId: (friend.currentVideoId ?? '').trim(),
                              title: friendTitleText,
                              artist: friendArtist,
                              thumbnailUrl:
                                  'https://i.ytimg.com/vi/${(friend.currentVideoId ?? '').trim()}/hqdefault.jpg',
                            )
                          : null,
                      noteText: friend.note.trim().isEmpty
                          ? 'Escribe algo...'
                          : friend.note.trim(),
                      footerText: friend.name.trim().isEmpty
                          ? '@${friend.username}'
                          : friend.name.trim(),
                      imageProvider: _friendImageProvider(friend),
                      frameImageUrl: friendFrameUrl,
                      autoplayVideoId: friend.currentVideoId,
                      autoplayFriendId: friend.id,
                    ),
                  ),
                );
              }),
              _HomeAddFriendCard(
                onPressed: () async {
                  await Navigator.of(context).push(
                    CupertinoPageRoute<void>(
                      builder: (_) => const SocialFriendsPage(),
                    ),
                  );
                  await _loadFollowingPreview();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  ImageProvider<Object>? _friendImageProvider(SocialUser friend) {
    final id = friend.id.trim();
    if (id.isEmpty) return null;
    final baseUrl = (friend.photoUrl ?? '').trim();
    if (baseUrl.isEmpty) {
      _friendPhotoUrlById.remove(id);
      _friendImageById.remove(id);
      return null;
    }
    final previousUrl = _friendPhotoUrlById[id];
    if (previousUrl == baseUrl) {
      return _friendImageById[id];
    }
    final provider = NetworkImage(baseUrl);
    _friendPhotoUrlById[id] = baseUrl;
    _friendImageById[id] = provider;
    return provider;
  }
}

class _HomeSocialPreviewCard extends StatelessWidget {
  static const double _titleAreaHeight = 56;
  final Widget titleNote;
  final VoidCallback? onPlayNowFromTitleMenu;
  final VoidCallback? onAddNextFromTitleMenu;
  final VoidCallback? onAddToEndFromTitleMenu;
  final VoidCallback? onAddToFavoritesFromTitleMenu;
  final VoidCallback? onAddToPlaylistFromTitleMenu;
  final VoidCallback? onOpenArtistFromTitleMenu;
  final VoidCallback? onOpenAlbumFromTitleMenu;
  final String noteText;
  final String footerText;
  final ImageProvider<Object>? imageProvider;
  final String? frameImageUrl;
  final double scale;
  final VoidCallback? onTap;

  const _HomeSocialPreviewCard({
    super.key,
    required this.titleNote,
    this.onPlayNowFromTitleMenu,
    this.onAddNextFromTitleMenu,
    this.onAddToEndFromTitleMenu,
    this.onAddToFavoritesFromTitleMenu,
    this.onAddToPlaylistFromTitleMenu,
    this.onOpenArtistFromTitleMenu,
    this.onOpenAlbumFromTitleMenu,
    required this.noteText,
    required this.footerText,
    required this.imageProvider,
    required this.frameImageUrl,
    this.scale = 1.0,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final normalizedFrameImageUrl = (frameImageUrl ?? '').trim();
    final resolvedFrameImageUrl = normalizedFrameImageUrl.isEmpty
        ? null
        : normalizedFrameImageUrl;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: onTap,
      child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 130 * scale,
          height: _titleAreaHeight * scale,
          child: Padding(
            padding: EdgeInsets.only(top: scale > 1.0 ? 18 * scale : 0),
            child: onPlayNowFromTitleMenu == null
                ? Align(alignment: Alignment.topCenter, child: titleNote)
                : CupertinoContextMenu(
                    actions: [
                      CupertinoContextMenuAction(
                        onPressed: () {
                          Navigator.of(context).pop();
                          unawaited(HapticFeedback.selectionClick());
                          onPlayNowFromTitleMenu?.call();
                        },
                        child: _ContextMenuActionContent(
                          label: 'Reproducir ahora',
                          icon: CupertinoIcons.play_fill,
                          textColor: CupertinoColors.label.resolveFrom(context),
                          iconColor: CupertinoColors.systemGrey.resolveFrom(
                            context,
                          ),
                        ),
                      ),
                      if (onAddNextFromTitleMenu != null)
                        CupertinoContextMenuAction(
                          onPressed: () {
                            Navigator.of(context).pop();
                            unawaited(HapticFeedback.selectionClick());
                            onAddNextFromTitleMenu?.call();
                          },
                          child: _ContextMenuActionContent(
                            label: 'Añadir como siguiente',
                            icon: CupertinoIcons.text_insert,
                            textColor: CupertinoColors.label.resolveFrom(
                              context,
                            ),
                            iconColor: CupertinoColors.systemGrey.resolveFrom(
                              context,
                            ),
                          ),
                        ),
                      if (onAddToEndFromTitleMenu != null)
                        CupertinoContextMenuAction(
                          onPressed: () {
                            Navigator.of(context).pop();
                            unawaited(HapticFeedback.selectionClick());
                            onAddToEndFromTitleMenu?.call();
                          },
                          child: _ContextMenuActionContent(
                            label: 'Añadir al final',
                            icon: CupertinoIcons.text_append,
                            textColor: CupertinoColors.label.resolveFrom(
                              context,
                            ),
                            iconColor: CupertinoColors.systemGrey.resolveFrom(
                              context,
                            ),
                          ),
                        ),
                      if (onAddToFavoritesFromTitleMenu != null)
                        CupertinoContextMenuAction(
                          onPressed: () {
                            Navigator.of(context).pop();
                            unawaited(HapticFeedback.selectionClick());
                            onAddToFavoritesFromTitleMenu?.call();
                          },
                          child: _ContextMenuActionContent(
                            label: 'Añadir a Favoritos',
                            icon: CupertinoIcons.star_fill,
                            textColor: CupertinoColors.label.resolveFrom(
                              context,
                            ),
                            iconColor: CupertinoColors.systemGrey.resolveFrom(
                              context,
                            ),
                          ),
                        ),
                      if (onAddToPlaylistFromTitleMenu != null)
                        CupertinoContextMenuAction(
                          onPressed: () {
                            Navigator.of(context).pop();
                            unawaited(HapticFeedback.selectionClick());
                            onAddToPlaylistFromTitleMenu?.call();
                          },
                          child: _ContextMenuActionContent(
                            label: 'Añadir a playlist',
                            icon: CupertinoIcons.music_note_list,
                            textColor: CupertinoColors.label.resolveFrom(
                              context,
                            ),
                            iconColor: CupertinoColors.systemGrey.resolveFrom(
                              context,
                            ),
                          ),
                        ),
                      if (onOpenArtistFromTitleMenu != null)
                        CupertinoContextMenuAction(
                          onPressed: () {
                            Navigator.of(context).pop();
                            unawaited(HapticFeedback.selectionClick());
                            onOpenArtistFromTitleMenu?.call();
                          },
                          child: _ContextMenuActionContent(
                            label: 'Ir al artista',
                            icon: CupertinoIcons.person_crop_circle,
                            textColor: CupertinoColors.label.resolveFrom(
                              context,
                            ),
                            iconColor: CupertinoColors.systemGrey.resolveFrom(
                              context,
                            ),
                          ),
                        ),
                      if (onOpenAlbumFromTitleMenu != null)
                        CupertinoContextMenuAction(
                          onPressed: () {
                            Navigator.of(context).pop();
                            unawaited(HapticFeedback.selectionClick());
                            onOpenAlbumFromTitleMenu?.call();
                          },
                          child: _ContextMenuActionContent(
                            label: 'Ir al álbum',
                            icon: CupertinoIcons.rectangle_stack_fill,
                            textColor: CupertinoColors.label.resolveFrom(
                              context,
                            ),
                            iconColor: CupertinoColors.systemGrey.resolveFrom(
                              context,
                            ),
                          ),
                        ),
                    ],
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: titleNote,
                    ),
                  ),
          ),
        ),
        Padding(
          padding: EdgeInsets.only(left: 22 * scale, top: 2 * scale),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _HomeThoughtDot(size: 8 * scale),
              SizedBox(width: 3 * scale),
              _HomeThoughtDot(size: 6 * scale),
              SizedBox(width: 3 * scale),
              _HomeThoughtDot(size: 4 * scale),
            ],
          ),
        ),
        SizedBox(height: 6 * scale),
        SizedBox(
          width: 98 * scale,
          height: 98 * scale,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 0,
                top: 0,
                child: SizedBox(
                  width: 90 * scale,
                  height: 90 * scale,
                  child: ClipOval(
                    child: ColoredBox(
                      color: CupertinoColors.tertiarySystemFill.resolveFrom(
                        context,
                      ),
                      child: imageProvider == null
                          ? const Icon(
                              CupertinoIcons.person_crop_circle_fill,
                              size: 34,
                            )
                          : Image(
                              image: imageProvider as ImageProvider<Object>,
                              fit: BoxFit.cover,
                              gaplessPlayback: true,
                              errorBuilder: (_, _, _) => const Icon(
                                CupertinoIcons.person_crop_circle_fill,
                                size: 34,
                              ),
                            ),
                    ),
                  ),
                ),
              ),
              if (resolvedFrameImageUrl != null)
                Positioned(
                  left: -2 * scale,
                  bottom: -3 * scale,
                  child: IgnorePointer(
                    child: _HomeFloatingFrameDrift(
                      child: SizedBox(
                        width: 36 * scale,
                        height: 36 * scale,
                        child: Image.network(
                          resolvedFrameImageUrl,
                          key: ValueKey<String>(resolvedFrameImageUrl),
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                  ),
                ),
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  constraints: BoxConstraints(maxWidth: 68 * scale),
                  padding: EdgeInsets.symmetric(
                    horizontal: 7 * scale,
                    vertical: 4 * scale,
                  ),
                  decoration: BoxDecoration(
                    color: CupertinoColors.secondarySystemGroupedBackground
                        .resolveFrom(context),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: CupertinoColors.separator
                          .resolveFrom(context)
                          .withValues(alpha: 0.22),
                      width: 0.6,
                    ),
                  ),
                  child: _HomeReverseMarqueeText(
                    text: noteText,
                    style: TextStyle(
                      fontFamily: '.SF Pro Text',
                      fontSize: 10 * scale,
                      color: CupertinoColors.label.resolveFrom(context),
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: 6 * scale),
        SizedBox(
          width: 90 * scale,
          child: Text(
            footerText,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: '.SF Pro Text',
              fontSize: 12 * scale,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
              decoration: TextDecoration.none,
            ),
          ),
        ),
      ],
    ),
    );
  }
}

class _HomeAddFriendCard extends StatelessWidget {
  final Future<void> Function() onPressed;

  const _HomeAddFriendCard({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Espacio equivalente al bloque "nota + puntos" de las tarjetas sociales.
        const SizedBox(height: 70),
        CupertinoButton(
          padding: EdgeInsets.zero,
          minimumSize: Size.zero,
          onPressed: onPressed,
          child: Container(
            width: 90,
            height: 90,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: CupertinoColors.tertiarySystemFill.resolveFrom(context),
            ),
            child: Icon(
              CupertinoIcons.add,
              size: 26,
              color: CupertinoColors.label.resolveFrom(context),
            ),
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          width: 90,
          child: Text(
            'Anadir Amigos',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: '.SF Pro Text',
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
        ),
      ],
    );
  }
}

class _HomeFloatingFrameDrift extends StatefulWidget {
  final Widget child;

  const _HomeFloatingFrameDrift({required this.child});

  @override
  State<_HomeFloatingFrameDrift> createState() => _HomeFloatingFrameDriftState();
}

class _HomeFloatingFrameDriftState extends State<_HomeFloatingFrameDrift>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _xAnimation;
  late final Animation<double> _yAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3200),
    )..repeat(reverse: true);
    _xAnimation = Tween<double>(begin: -3.5, end: 3.5).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutSine),
    );
    _yAnimation = Tween<double>(begin: -2.0, end: 2.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final wave = 0.9 + (0.1 * math.sin(_controller.value * 2 * math.pi));
        return Transform.translate(
          offset: Offset(_xAnimation.value * wave, _yAnimation.value * wave),
          child: widget.child,
        );
      },
    );
  }
}

class _HomeMiniSpectrum extends StatefulWidget {
  final bool active;

  const _HomeMiniSpectrum({required this.active});

  @override
  State<_HomeMiniSpectrum> createState() => _HomeMiniSpectrumState();
}

class _HomeMiniSpectrumState extends State<_HomeMiniSpectrum>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final barColor = CupertinoColors.systemPink.resolveFrom(context);
    final idleColor = CupertinoColors.secondaryLabel.resolveFrom(context);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value * 2 * math.pi;
        final bars = <double>[
          4 + (math.sin(t + 0.1) + 1) * 6,
          4 + (math.sin(t + 1.1) + 1) * 6,
          4 + (math.sin(t + 2.0) + 1) * 6,
          4 + (math.sin(t + 2.8) + 1) * 6,
        ];
        return SizedBox(
          width: 14,
          height: 14,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(4, (index) {
              final h = widget.active ? (bars[index] * 0.55) : 3.0;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOutCubic,
                width: 2,
                height: h,
                decoration: BoxDecoration(
                  color: widget.active ? barColor : idleColor,
                  borderRadius: BorderRadius.circular(999),
                ),
              );
            }),
          ),
        );
      },
    );
  }
}

class _HomeThoughtDot extends StatelessWidget {
  final double size;

  const _HomeThoughtDot({required this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
          context,
        ),
        shape: BoxShape.circle,
        border: Border.all(
          color: CupertinoColors.separator
              .resolveFrom(context)
              .withValues(alpha: 0.2),
          width: 0.5,
        ),
      ),
    );
  }
}

class _HomeMarqueeText extends StatefulWidget {
  final String text;
  final TextStyle style;

  const _HomeMarqueeText({required this.text, required this.style});

  @override
  State<_HomeMarqueeText> createState() => _HomeMarqueeTextState();
}

class _HomeMarqueeTextState extends State<_HomeMarqueeText>
    with TickerProviderStateMixin {
  AnimationController? _scrollController;
  AnimationController? _fadeController;
  double _overflow = 0;
  String _lastText = '';
  Duration _scrollDuration = const Duration(milliseconds: 4200);
  double _travel = 0;
  int _cycleEpoch = 0;
  bool _cycleRunning = false;

  @override
  void dispose() {
    _cycleEpoch++;
    _scrollController?.dispose();
    _fadeController?.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _HomeMarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _lastText = '';
      _restartCycle();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          maxLines: 1,
          textDirection: Directionality.of(context),
        )..layout(minWidth: 0, maxWidth: double.infinity);

        final textWidth = painter.width;
        final textHeight = painter.height;
        _overflow = (textWidth - maxWidth).clamp(0.0, double.infinity);
        if (_overflow <= 1) {
          _cycleEpoch++;
          _cycleRunning = false;
          _scrollController?.stop();
          _fadeController?.stop();
          _scrollController?.value = 0;
          _fadeController?.value = 1;
          return Text(
            widget.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: widget.style,
          );
        }

        _ensureControllers();
        final ms = ((_overflow / 26) * 1000).clamp(2200, 9000).round();
        final duration = Duration(milliseconds: ms);
        _travel = _overflow + 36.0;
        if (_scrollDuration != duration) {
          _scrollDuration = duration;
          _restartCycle();
        }
        if (_lastText != widget.text) {
          _lastText = widget.text;
          _restartCycle();
        }

        _startCycleIfNeeded();
        const gap = 36.0;
        return ClipRect(
          child: AnimatedBuilder(
            animation: Listenable.merge([_scrollController!, _fadeController!]),
            builder: (context, _) {
              final eased = Curves.easeInOutCubic.transform(
                _scrollController!.value,
              );
              return Transform.translate(
                offset: Offset(-_travel * eased, 0),
                child: SizedBox(
                  height: textHeight,
                  child: Opacity(
                    opacity: _fadeController!.value,
                    child: OverflowBox(
                      minHeight: textHeight,
                      maxHeight: textHeight,
                      maxWidth: double.infinity,
                      alignment: Alignment.centerLeft,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: textWidth,
                            child: Text(
                              widget.text,
                              maxLines: 1,
                              softWrap: false,
                              style: widget.style,
                              textAlign: TextAlign.left,
                            ),
                          ),
                          const SizedBox(width: gap),
                          SizedBox(
                            width: textWidth,
                            child: Text(
                              widget.text,
                              maxLines: 1,
                              softWrap: false,
                              style: widget.style,
                              textAlign: TextAlign.left,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  void _ensureControllers() {
    _scrollController ??= AnimationController(
      vsync: this,
      duration: _scrollDuration,
      value: 0,
    );
    _fadeController ??= AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      value: 1,
    );
  }

  void _restartCycle() {
    _cycleEpoch++;
    _cycleRunning = false;
    _scrollController?.stop();
    _fadeController?.stop();
    _scrollController?.value = 0;
    _fadeController?.value = 1;
  }

  void _startCycleIfNeeded() {
    if (_cycleRunning) return;
    _cycleRunning = true;
    final token = _cycleEpoch;
    unawaited(_runCycle(token));
  }

  Future<void> _runCycle(int token) async {
    while (mounted && token == _cycleEpoch && _overflow > 1) {
      await Future<void>.delayed(const Duration(seconds: 15));
      if (!mounted || token != _cycleEpoch || _overflow <= 1) return;

      try {
        await _scrollController!.animateTo(
          1,
          duration: _scrollDuration,
          curve: Curves.easeInOutCubic,
        );
      } catch (_) {
        return;
      }
      if (!mounted || token != _cycleEpoch) return;

      try {
        await _fadeController!.animateTo(
          0,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        );
      } catch (_) {
        return;
      }
      if (!mounted || token != _cycleEpoch) return;

      _scrollController!.value = 0;

      try {
        await _fadeController!.animateTo(
          1,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeInCubic,
        );
      } catch (_) {
        return;
      }
    }
    if (token == _cycleEpoch) {
      _cycleRunning = false;
    }
  }
}

class _HomeReverseMarqueeText extends StatefulWidget {
  final String text;
  final TextStyle style;

  const _HomeReverseMarqueeText({required this.text, required this.style});

  @override
  State<_HomeReverseMarqueeText> createState() =>
      _HomeReverseMarqueeTextState();
}

class _HomeReverseMarqueeTextState extends State<_HomeReverseMarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  double _overflow = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _syncAnimation(double maxWidth) {
    final painter = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout(minWidth: 0, maxWidth: double.infinity);
    final nextOverflow = math.max(0.0, painter.width - maxWidth).toDouble();
    if ((nextOverflow - _overflow).abs() < 0.5) return;
    _overflow = nextOverflow;
    if (_overflow <= 0.5) {
      _controller.stop();
      return;
    }
    final ms = (2200 + (_overflow * 28)).round().clamp(2200, 7000);
    _controller.duration = Duration(milliseconds: ms);
    _controller.repeat(reverse: true);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _syncAnimation(constraints.maxWidth);
        if (_overflow <= 0.5) {
          return Text(
            widget.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: widget.style,
          );
        }
        return ClipRect(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              final x =
                  -_overflow * Curves.easeInOut.transform(_controller.value);
              return Transform.translate(
                offset: Offset(x, 0),
                child: Text(
                  widget.text,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.visible,
                  style: widget.style,
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _HomeAnimatedNowPlayingNote extends StatefulWidget {
  final String titleText;
  final String artistText;
  final bool hasTrack;
  final bool isPlaying;

  const _HomeAnimatedNowPlayingNote({
    required this.titleText,
    required this.artistText,
    required this.hasTrack,
    required this.isPlaying,
  });

  @override
  State<_HomeAnimatedNowPlayingNote> createState() =>
      _HomeAnimatedNowPlayingNoteState();
}

class _HomeAnimatedNowPlayingNoteState
    extends State<_HomeAnimatedNowPlayingNote>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _xAnimation;
  late final Animation<double> _yAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3200),
    );
    _xAnimation = Tween<double>(begin: -6, end: 6).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutSine),
    );
    _yAnimation = Tween<double>(
      begin: -2.8,
      end: 2.8,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
    _controller.repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final trackKey =
        '${widget.titleText}|${widget.artistText}|${widget.hasTrack}';
    final idleVerticalOffset = widget.hasTrack ? 0.0 : 16.0;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Transform.translate(
          offset: Offset(
            _xAnimation.value,
            _yAnimation.value + idleVerticalOffset,
          ),
          child: _HomeNoteBubble(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 320),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) {
                final slide = Tween<Offset>(
                  begin: const Offset(0.08, 0),
                  end: Offset.zero,
                ).animate(animation);
                return FadeTransition(
                  opacity: animation,
                  child: SlideTransition(position: slide, child: child),
                );
              },
              child: Row(
                key: ValueKey<String>(trackKey),
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _HomeMarqueeText(
                          text: widget.titleText,
                          style: TextStyle(
                            fontFamily: '.SF Pro Text',
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: CupertinoColors.label.resolveFrom(context),
                            decoration: TextDecoration.none,
                          ),
                        ),
                        if (widget.hasTrack &&
                            widget.artistText.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          _HomeMarqueeText(
                            text: widget.artistText,
                            style: TextStyle(
                              fontFamily: '.SF Pro Text',
                              fontSize: 12,
                              color: CupertinoColors.secondaryLabel.resolveFrom(
                                context,
                              ),
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                  _HomeMiniSpectrum(
                    active: widget.hasTrack && widget.isPlaying,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _HomeNoteBubble extends StatelessWidget {
  final Widget child;

  const _HomeNoteBubble({required this.child});

  @override
  Widget build(BuildContext context) {
    final border = CupertinoColors.separator
        .resolveFrom(context)
        .withValues(alpha: 0.22);
    return Container(
      constraints: const BoxConstraints(maxWidth: 176),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
          context,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: border, width: 0.6),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, 8),
          ),
          BoxShadow(
            color: Colors.white.withValues(alpha: 0.06),
            blurRadius: 6,
            offset: const Offset(0, -1),
          ),
        ],
      ),
      child: child,
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
  final Future<void> Function(_HomeTrack item, _TrackContextAction action)
  onContextAction;
  final bool allowSwipeToQueue;
  final bool thinCards;

  const _StackedTrackColumn({
    required this.items,
    required this.onTap,
    required this.onSwipeToQueueNext,
    required this.onSwipeToQueueEnd,
    required this.onContextAction,
    required this.allowSwipeToQueue,
    this.thinCards = false,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final clampedItems = items.take(4).toList(growable: false);
    return SizedBox(
      width: 330,
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
                  onContextAction: (action) => onContextAction(item, action),
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
  final Future<void> Function(_TrackContextAction action) onContextAction;
  final bool allowSwipeToQueue;
  final bool thin;

  const _CompactReplayCard({
    required this.item,
    required this.onTap,
    required this.onSwipeToQueueNext,
    required this.onSwipeToQueueEnd,
    required this.onContextAction,
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
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: thin ? 228 : 220),
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
              ],
            ),
          ),
        ),
      ),
    );

    final contextMenuWrapped = _TrackContextMenu(
      onAction: onContextAction,
      child: card,
    );

    return allowSwipeToQueue
        ? Slidable(
            key: ObjectKey(item),
            startActionPane: _queueActionPane(
              context,
              onNext: onSwipeToQueueNext,
              onEnd: onSwipeToQueueEnd,
            ),
            child: contextMenuWrapped,
          )
        : contextMenuWrapped;
  }
}

enum _TrackContextAction {
  addNext,
  addToEnd,
  addToFavorites,
  addToPlaylist,
  share,
  openArtist,
  openAlbum,
}

class _TrackContextMenu extends StatelessWidget {
  final Future<void> Function(_TrackContextAction action) onAction;
  final Widget child;

  const _TrackContextMenu({required this.onAction, required this.child});

  @override
  Widget build(BuildContext context) {
    final gray = CupertinoColors.systemGrey.resolveFrom(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? CupertinoColors.white : CupertinoColors.black;
    final actions = <Widget>[
      CupertinoContextMenuAction(
        onPressed: () {
          Navigator.of(context).pop();
          unawaited(onAction(_TrackContextAction.addNext));
        },
        child: _ContextMenuActionContent(
          label: 'Añadir como siguiente',
          icon: CupertinoIcons.text_insert,
          textColor: textColor,
          iconColor: gray,
        ),
      ),
      CupertinoContextMenuAction(
        onPressed: () {
          Navigator.of(context).pop();
          unawaited(onAction(_TrackContextAction.addToEnd));
        },
        child: _ContextMenuActionContent(
          label: 'Añadir al final',
          icon: CupertinoIcons.text_append,
          textColor: textColor,
          iconColor: gray,
        ),
      ),
      CupertinoContextMenuAction(
        onPressed: () {
          Navigator.of(context).pop();
          unawaited(onAction(_TrackContextAction.addToFavorites));
        },
        child: _ContextMenuActionContent(
          label: 'Añadir a Favoritos',
          icon: CupertinoIcons.star_fill,
          textColor: textColor,
          iconColor: gray,
        ),
      ),
      CupertinoContextMenuAction(
        onPressed: () {
          Navigator.of(context).pop();
          unawaited(onAction(_TrackContextAction.addToPlaylist));
        },
        child: _ContextMenuActionContent(
          label: 'Añadir a playlist',
          icon: CupertinoIcons.music_note_list,
          textColor: textColor,
          iconColor: gray,
        ),
      ),
      CupertinoContextMenuAction(
        onPressed: () {
          Navigator.of(context).pop();
          unawaited(onAction(_TrackContextAction.share));
        },
        child: _ContextMenuActionContent(
          label: 'Compartir',
          icon: CupertinoIcons.square_arrow_up,
          textColor: textColor,
          iconColor: gray,
        ),
      ),
      CupertinoContextMenuAction(
        onPressed: () {
          Navigator.of(context).pop();
          unawaited(onAction(_TrackContextAction.openArtist));
        },
        child: _ContextMenuActionContent(
          label: 'Ir al artista',
          icon: CupertinoIcons.person_crop_circle,
          textColor: textColor,
          iconColor: gray,
        ),
      ),
      CupertinoContextMenuAction(
        onPressed: () {
          Navigator.of(context).pop();
          unawaited(onAction(_TrackContextAction.openAlbum));
        },
        child: _ContextMenuActionContent(
          label: 'Ir al álbum',
          icon: CupertinoIcons.rectangle_stack_fill,
          textColor: textColor,
          iconColor: gray,
        ),
      ),
    ];

    return CupertinoContextMenu(
      actions: actions,
      enableHapticFeedback: true,
      child: child,
    );
  }
}

class _ContextMenuActionContent extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color textColor;
  final Color iconColor;

  const _ContextMenuActionContent({
    required this.label,
    required this.icon,
    required this.textColor,
    required this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: textColor),
          ),
        ),
        Icon(icon, color: iconColor, size: 20),
      ],
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
