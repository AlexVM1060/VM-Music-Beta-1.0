import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:hive/hive.dart';
import 'package:myapp/models/downloaded_video.dart';
import 'package:myapp/models/video_history.dart';
import 'package:myapp/services/download_service.dart';
import 'package:myapp/services/history_service.dart';
import 'package:myapp/services/playlist_service.dart';
import 'package:myapp/utils/artist_name_utils.dart';
import 'package:myapp/utils/thumbnail_quality.dart';
import 'package:myapp/video_player_manager.dart';
import 'package:myapp/widgets/playlist_picker_sheet.dart';
import 'package:myapp/widgets/square_thumbnail.dart';
import 'package:provider/provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const String _homeCacheBoxName = 'home_cache';
  static const String _trendingCacheKey = 'mx_trending_topic_v2';
  static const Duration _trendingCacheTtl = Duration(hours: 6);
  final YoutubeExplode _yt = YoutubeExplode();
  late Future<_HomeContent> _contentFuture;
  late Future<List<_HomeTrack>> _trendingFuture;
  bool _relistenListIsDragging = false;

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
    final trendingSeed = await _readTrendingCache();
    final searchSeed = await _loadSearchStyleRecommendationSeed(history);

    final suggestions = _buildSuggestions(
      history: history,
      downloads: downloads,
      trendingSeed: trendingSeed,
      searchSeed: searchSeed,
    );
    final relisten = history
        .take(20)
        .map(_HomeTrack.fromHistory)
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
    List<_HomeTrack> dedupeTracks(Iterable<_HomeTrack> source, {int take = 12}) {
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

  Future<void> _addTrackToQueue(_HomeTrack track) async {
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
          )
        : manager.addOnlineTrackToPlaybackQueue(
            videoId: track.videoId,
            title: track.title,
            thumbnailUrl: track.thumbnailUrl,
            artist: track.artist,
          );
    if (!mounted) return;
    await HapticFeedback.lightImpact();
    if (!mounted) return;
    _showQueueIosToast(
      context,
      message: added
          ? 'Se ha añadido a la cola'
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

    final downloadService = context.read<DownloadService>();
    final videoManager = context.read<VideoPlayerManager>();
    final entry = VideoHistory(
      videoId: track.videoId,
      title: track.title,
      thumbnailUrl: track.thumbnailUrl,
      channelTitle: track.artist,
      watchedAt: DateTime.now(),
    );

    await playlistService.addVideoToPlaylist(selectedName, entry);
    await downloadService.autoDownloadIfEnabledUsingClone(
      selectedName,
      entry,
      videoManager: videoManager,
    );
    if (!mounted) return;
    await HapticFeedback.lightImpact();
    if (!mounted) return;
    final label = PlaylistService.isFavoritesPlaylistName(selectedName)
        ? 'Añadida a Favoritos'
        : 'Añadida a $selectedName';
    _showQueueIosToast(
      context,
      message: label,
      icon: PlaylistService.isFavoritesPlaylistName(selectedName)
          ? CupertinoIcons.star_fill
          : CupertinoIcons.check_mark_circled_solid,
    );
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

  List<List<_HomeTrack>> _buildRelistenColumns(List<_HomeTrack> source) {
    if (source.isEmpty) return const [];
    final columns = <List<_HomeTrack>>[];
    for (var index = 0; index < source.length; index += 2) {
      final pair = <_HomeTrack>[source[index]];
      if (index + 1 < source.length) {
        pair.add(source[index + 1]);
      }
      columns.add(pair);
    }
    return columns;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
            final relistenColumns = _buildRelistenColumns(content.relisten);

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
                  const SliverToBoxAdapter(child: SizedBox(height: 6)),
                  _SectionHeaderSliver(
                    title: 'Volver a escuchar',
                    subtitle: 'Tus últimas reproducciones',
                  ),
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: 232,
                      child: NotificationListener<ScrollNotification>(
                        onNotification: (notification) {
                          final nextIsDragging =
                              notification is ScrollStartNotification ||
                              (notification is UserScrollNotification &&
                                  notification.direction !=
                                      ScrollDirection.idle) ||
                              notification is ScrollUpdateNotification;
                          final nextIsIdle =
                              notification is ScrollEndNotification ||
                              (notification is UserScrollNotification &&
                                  notification.direction ==
                                      ScrollDirection.idle);
                          if (nextIsDragging && !_relistenListIsDragging) {
                            setState(() {
                              _relistenListIsDragging = true;
                            });
                          } else if (nextIsIdle && _relistenListIsDragging) {
                            setState(() {
                              _relistenListIsDragging = false;
                            });
                          }
                          return false;
                        },
                        child: ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
                          scrollDirection: Axis.horizontal,
                          itemCount: relistenColumns.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 12),
                          itemBuilder: (context, index) {
                            final columnItems = relistenColumns[index];
                            return _RelistenStackedColumn(
                              items: columnItems,
                              onTap: _playTrack,
                              onSwipeToQueue: _addTrackToQueue,
                              onAddToPlaylist: _addTrackToPlaylist,
                              allowSwipeToQueue: !_relistenListIsDragging,
                            );
                          },
                        ),
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
                              onSwipeToQueue: () => _addTrackToQueue(item),
                              onAddToPlaylist: () => _addTrackToPlaylist(item),
                            );
                          },
                        ),
                      );
                    },
                  ),
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

  const _HomeContent({
    required this.suggestions,
    required this.relisten,
    required this.mixes,
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

class _RelistenStackedColumn extends StatelessWidget {
  final List<_HomeTrack> items;
  final Future<void> Function(_HomeTrack item) onTap;
  final Future<void> Function(_HomeTrack item) onSwipeToQueue;
  final Future<void> Function(_HomeTrack item) onAddToPlaylist;
  final bool allowSwipeToQueue;

  const _RelistenStackedColumn({
    required this.items,
    required this.onTap,
    required this.onSwipeToQueue,
    required this.onAddToPlaylist,
    required this.allowSwipeToQueue,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      width: 286,
      child: Column(
        children: [
          _CompactReplayCard(
            item: items.first,
            onTap: () => onTap(items.first),
            onSwipeToQueue: () => onSwipeToQueue(items.first),
            onAddToPlaylist: () => onAddToPlaylist(items.first),
            allowSwipeToQueue: allowSwipeToQueue,
          ),
          const SizedBox(height: 10),
          if (items.length > 1)
            _CompactReplayCard(
              item: items[1],
              onTap: () => onTap(items[1]),
              onSwipeToQueue: () => onSwipeToQueue(items[1]),
              onAddToPlaylist: () => onAddToPlaylist(items[1]),
              allowSwipeToQueue: allowSwipeToQueue,
            )
          else
            const Spacer(),
        ],
      ),
    );
  }
}

class _CompactReplayCard extends StatelessWidget {
  final _HomeTrack item;
  final VoidCallback onTap;
  final Future<void> Function() onSwipeToQueue;
  final VoidCallback onAddToPlaylist;
  final bool allowSwipeToQueue;

  const _CompactReplayCard({
    required this.item,
    required this.onTap,
    required this.onSwipeToQueue,
    required this.onAddToPlaylist,
    required this.allowSwipeToQueue,
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

    final card = ClipRRect(
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
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            child: Row(
              children: [
                _AdaptiveThumb(item: item, size: 64),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
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
                const SizedBox(width: 8),
                _QueueAddButton(onPressed: onAddToPlaylist),
              ],
            ),
          ),
        ),
      ),
    );

    return Expanded(
      child: allowSwipeToQueue
          ? Dismissible(
              key: ObjectKey(item),
              direction: DismissDirection.startToEnd,
              dismissThresholds: const {DismissDirection.startToEnd: 0.28},
              confirmDismiss: (_) async {
                await onSwipeToQueue();
                return false;
              },
              background: _queueSwipeBackground(context),
              child: card,
            )
          : card,
    );
  }
}

class _TrendingRowCard extends StatelessWidget {
  final _HomeTrack item;
  final VoidCallback onTap;
  final Future<void> Function() onSwipeToQueue;
  final VoidCallback onAddToPlaylist;

  const _TrendingRowCard({
    required this.item,
    required this.onTap,
    required this.onSwipeToQueue,
    required this.onAddToPlaylist,
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
      child: Dismissible(
        key: ObjectKey(item),
        direction: DismissDirection.startToEnd,
        dismissThresholds: const {DismissDirection.startToEnd: 0.28},
        confirmDismiss: (_) async {
          await onSwipeToQueue();
          return false;
        },
        background: _queueSwipeBackground(context),
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
                    _QueueAddButton(onPressed: onAddToPlaylist),
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

    if (item.isLocal &&
        item.thumbnailUrl.isNotEmpty &&
        item.thumbnailUrl.startsWith('/')) {
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
    final bg = CupertinoColors.tertiarySystemFill.resolveFrom(context);
    return CupertinoButton(
      padding: const EdgeInsets.all(6),
      minimumSize: const Size(32, 32),
      borderRadius: BorderRadius.circular(11),
      color: bg,
      onPressed: onPressed,
      child: Icon(
        CupertinoIcons.add,
        size: 16,
        color: CupertinoColors.systemPink.resolveFrom(context),
      ),
    );
  }
}

Widget _queueSwipeBackground(BuildContext context) {
  return Container(
    alignment: Alignment.centerLeft,
    padding: const EdgeInsets.symmetric(horizontal: 18),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(14),
      color: CupertinoColors.systemGreen.withValues(alpha: 0.18),
      border: Border.all(
        color: CupertinoColors.systemGreen.withValues(alpha: 0.36),
        width: 0.8,
      ),
    ),
    child: const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          CupertinoIcons.add_circled_solid,
          color: CupertinoColors.systemGreen,
          size: 18,
        ),
        SizedBox(width: 8),
        Text(
          'Añadir a la cola',
          style: TextStyle(
            fontFamily: '.SF Pro Text',
            fontWeight: FontWeight.w700,
            fontSize: 13,
            color: CupertinoColors.systemGreen,
          ),
        ),
      ],
    ),
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
    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(
        position: _slide,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: DecoratedBox(
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
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
            ),
          ),
        ),
      ),
    );
  }
}
