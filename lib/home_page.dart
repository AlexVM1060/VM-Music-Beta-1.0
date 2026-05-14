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
import 'package:myapp/services/lyrics_service.dart';
import 'package:myapp/services/playlist_service.dart';
import 'package:myapp/services/profile_service.dart';
import 'package:myapp/services/song_stream_cache_service.dart';
import 'package:myapp/services/social_service.dart';
import 'package:myapp/social_friends_page.dart';
import 'package:myapp/services/thumbnail_cache_service.dart';
import 'package:myapp/search_page.dart';
import 'package:myapp/utils/artist_name_utils.dart';
import 'package:myapp/utils/thumbnail_quality.dart';
import 'package:myapp/video_player_manager.dart';
import 'package:myapp/widgets/ios_notice.dart';
import 'package:myapp/widgets/favorites_star_badge.dart';
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
  static const String _curatedShelvesCacheKey = 'curated_music_shelves_v9';
  static const String _homeContentCacheKey = 'home_content_v1';
  static const Duration _trendingCacheTtl = Duration(hours: 6);
  static const Duration _curatedShelvesCacheTtl = Duration(hours: 4);
  static const Duration _homeContentCacheTtl = Duration(hours: 18);
  final YoutubeExplode _yt = YoutubeExplode();
  late Future<_HomeContent> _contentFuture;
  late Future<List<_HomeTrack>> _trendingFuture;
  late Future<_HomeShelf> _musicVideosShelfFuture;
  late Future<_HomeShelf> _mexicanGenreShelfFuture;
  final Map<String, _HomeResolvedAlbumRef> _albumRefByVideoIdCache = {};
  final Map<String, Future<_HomeResolvedAlbumRef?>> _albumRefByVideoIdInFlight =
      {};
  final Map<String, _HomeResolvedAlbumRef> _albumShelfRefByItemId = {};
  final Map<String, _HomeResolvedChannelPlaylistRef>
  _ytMusicMxPlaylistRefByItemId = {};

  @override
  void initState() {
    super.initState();
    _contentFuture = _loadContent(includeNetwork: false);
    _trendingFuture = _loadTrendingTracks();
    _musicVideosShelfFuture = _buildMusicVideosShelfFallback();
    _mexicanGenreShelfFuture = _buildMexicanGenreShelf();
    unawaited(_refreshHomeContentInBackground());
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

  Future<void> _refreshHomeContentInBackground() async {
    try {
      // Deja que el contenido inicial (cache/local) se pinte primero.
      await _contentFuture;
    } catch (_) {
      // Seguimos con refresh en background aunque falle cache inicial.
    }
    if (!mounted) return;
    final updated = _loadContent();
    setState(() {
      _contentFuture = updated;
    });
    await updated;
  }

  Future<_HomeContent> _loadContent({bool includeNetwork = true}) async {
    final historyService = context.read<HistoryService>();
    final downloadService = context.read<DownloadService>();
    if (!includeNetwork) {
      final cached = await _readHomeContentCache();
      if (cached != null) return cached;
    }

    final history = await historyService.getHistory();
    final asyncTasks = <Future<dynamic>>[
      downloadService.getDownloadedVideos(),
      _readTrendingCache(),
      includeNetwork
          ? _loadSearchStyleRecommendationSeed(history)
          : Future.value(const <_HomeTrack>[]),
      includeNetwork
          ? _loadHistoryRandomRecommendationSeed(history)
          : Future.value(const <_HomeTrack>[]),
      includeNetwork
          ? _loadCuratedShelves(history)
          : _readCuratedShelvesCache(),
    ];
    final asyncResults = await Future.wait<dynamic>(asyncTasks);
    final downloads = asyncResults[0] as List<DownloadedVideo>;
    final trendingSeed = asyncResults[1] as List<_HomeTrack>;
    final searchSeed = asyncResults[2] as List<_HomeTrack>;
    final historyRandomSeed = asyncResults[3] as List<_HomeTrack>;
    final curatedShelves = asyncResults[4] as List<_HomeShelf>;
    final downloadsById = <String, DownloadedVideo>{
      for (final item in downloads) item.videoId: item,
    };

    final suggestions = _buildSuggestions(
      history: history,
      downloads: downloads,
      trendingSeed: trendingSeed,
      searchSeed: searchSeed,
      historyRandomSeed: historyRandomSeed,
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
    final albumsForYouShelf = includeNetwork
        ? await _buildSuggestedAlbumsShelfFromSuggestions(suggestions)
        : const _HomeShelf(
            id: 'albums_for_you',
            title: 'Álbumes sugeridos',
            subtitle: 'Álbumes relacionados a tus sugerencias',
            tracks: [],
          );
    final shelves = List<_HomeShelf>.from(curatedShelves, growable: true);
    shelves.removeWhere((shelf) => shelf.id == 'albums_for_you');
    if (albumsForYouShelf.tracks.isNotEmpty) {
      final insertIndex = shelves.indexWhere((s) => s.id == 'quick_picks');
      if (insertIndex == -1) {
        shelves.insert(0, albumsForYouShelf);
      } else {
        shelves.insert(insertIndex + 1, albumsForYouShelf);
      }
    }
    final content = _HomeContent(
      suggestions: suggestions,
      relisten: relisten,
      mixes: mixes,
      curatedShelves: shelves,
    );
    await _writeHomeContentCache(content);
    return content;
  }

  Future<_HomeContent?> _readHomeContentCache() async {
    try {
      final box = await Hive.openBox<String>(_homeCacheBoxName);
      final raw = box.get(_homeContentCacheKey);
      if (raw == null || raw.isEmpty) return null;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final updatedAtMs = (map['updatedAtMs'] as num?)?.toInt() ?? 0;
      if (updatedAtMs <= 0) return null;
      final updatedAt = DateTime.fromMillisecondsSinceEpoch(updatedAtMs);
      if (DateTime.now().difference(updatedAt) > _homeContentCacheTtl) {
        return null;
      }

      List<_HomeTrack> parseTracks(dynamic rawList) {
        final list = (rawList as List<dynamic>? ?? const <dynamic>[])
            .whereType<Map>()
            .map(
              (item) => _homeTrackFromMap(
                Map<String, dynamic>.from(item.cast<dynamic, dynamic>()),
              ),
            )
            .whereType<_HomeTrack>()
            .toList(growable: false);
        return list;
      }

      final suggestions = parseTracks(map['suggestions']);
      final relisten = parseTracks(map['relisten']);
      final mixes = (map['mixes'] as List<dynamic>? ?? const <dynamic>[])
          .whereType<Map>()
          .map((mixRaw) {
            final mixMap = Map<String, dynamic>.from(
              mixRaw.cast<dynamic, dynamic>(),
            );
            final tracks = parseTracks(mixMap['tracks']);
            if (tracks.isEmpty) return null;
            return _HomeMix(
              title: (mixMap['title'] ?? '').toString(),
              subtitle: (mixMap['subtitle'] ?? '').toString(),
              tracks: tracks,
            );
          })
          .whereType<_HomeMix>()
          .toList(growable: false);
      final curatedShelves =
          (map['curatedShelves'] as List<dynamic>? ?? const <dynamic>[])
              .whereType<Map>()
              .map((shelfRaw) {
                final shelfMap = Map<String, dynamic>.from(
                  shelfRaw.cast<dynamic, dynamic>(),
                );
                final tracks = parseTracks(shelfMap['tracks']);
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

      return _HomeContent(
        suggestions: suggestions,
        relisten: relisten,
        mixes: mixes,
        curatedShelves: curatedShelves,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeHomeContentCache(_HomeContent content) async {
    try {
      final box = await Hive.openBox<String>(_homeCacheBoxName);
      final payload = jsonEncode({
        'updatedAtMs': DateTime.now().millisecondsSinceEpoch,
        'suggestions': content.suggestions.map(_homeTrackToMap).toList(),
        'relisten': content.relisten.map(_homeTrackToMap).toList(),
        'mixes': content.mixes
            .map(
              (mix) => {
                'title': mix.title,
                'subtitle': mix.subtitle,
                'tracks': mix.tracks.map(_homeTrackToMap).toList(),
              },
            )
            .toList(),
        'curatedShelves': content.curatedShelves
            .map(
              (shelf) => {
                'id': shelf.id,
                'title': shelf.title,
                'subtitle': shelf.subtitle,
                'tracks': shelf.tracks.map(_homeTrackToMap).toList(),
              },
            )
            .toList(),
      });
      await box.put(_homeContentCacheKey, payload);
    } catch (_) {
      // Best effort.
    }
  }

  Map<String, dynamic> _homeTrackToMap(_HomeTrack item) {
    return {
      'videoId': item.videoId,
      'title': item.title,
      'artist': item.artist,
      'thumbnailUrl': item.thumbnailUrl,
      'isLocal': item.isLocal,
      'localFilePath': item.localFilePath,
      'localPlainLyrics': item.localPlainLyrics,
      'localSyncedLyrics': item.localSyncedLyrics,
    };
  }

  _HomeTrack? _homeTrackFromMap(Map<String, dynamic> map) {
    final videoId = (map['videoId'] ?? '').toString().trim();
    final title = (map['title'] ?? '').toString().trim();
    if (videoId.isEmpty || title.isEmpty) return null;
    return _HomeTrack(
      videoId: videoId,
      title: title,
      artist: cleanArtistName((map['artist'] ?? '').toString()),
      thumbnailUrl: (map['thumbnailUrl'] ?? '').toString(),
      isLocal: (map['isLocal'] as bool?) ?? false,
      localFilePath: (map['localFilePath'] as String?)?.trim(),
      localPlainLyrics: (map['localPlainLyrics'] as String?)?.trim(),
      localSyncedLyrics: (map['localSyncedLyrics'] as String?)?.trim(),
    );
  }

  Future<List<_HomeShelf>> _loadCuratedShelves(
    List<VideoHistory> history,
  ) async {
    final cached = await _readCuratedShelvesCache();
    if (cached.isNotEmpty) return cached;
    _ytMusicMxPlaylistRefByItemId.clear();

    final shelves = <_HomeShelf>[];
    final quickPicks = await _buildQuickPicksShelf(history);
    if (quickPicks.tracks.isNotEmpty) shelves.add(quickPicks);
    final suggestedAlbums = await _buildSuggestedAlbumsShelf(history);
    if (suggestedAlbums.tracks.isNotEmpty) shelves.add(suggestedAlbums);

    final channelShelves = await _loadYouTubeMusicMxShelvesFromChannel();
    if (channelShelves.isNotEmpty) {
      shelves.addAll(channelShelves);
    }
    if (!shelves.any((s) => s.id == 'ytmx_nuevos_videos_musicales')) {
      final videosShelf = await _buildMusicVideosShelfFallback();
      if (videosShelf.tracks.isNotEmpty) {
        shelves.add(videosShelf);
      }
    }

    final fetched = await Future.wait([
      if (channelShelves.isEmpty)
        _buildShelfFromSeed(
          const _ShelfSeed(
            id: 'ytmx_exitos_del_momento',
            title: 'Éxitos del Momento',
            subtitle: 'YouTube Music México',
            query:
                'youtube music mexico éxitos del momento canciones top mexico topic',
          ),
        ),
      if (channelShelves.isEmpty)
        _buildShelfFromSeed(
          const _ShelfSeed(
            id: 'ytmx_nueva_musica',
            title: 'Nueva Música',
            subtitle: 'YouTube Music México',
            query:
                'youtube music mexico nueva música estrenos semana topic official audio',
          ),
        ),
      if (channelShelves.isEmpty)
        _buildShelfFromSeed(
          const _ShelfSeed(
            id: 'ytmx_una_vuelta_al_pasado',
            title: 'Una vuelta al pasado',
            subtitle: 'YouTube Music México',
            query:
                'youtube music mexico una vuelta al pasado throwback clásicos topic',
          ),
        ),
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
    final videosIndex = shelves.indexWhere(
      (shelf) => shelf.id == 'ytmx_nuevos_videos_musicales',
    );
    final albumsIndex = shelves.indexWhere(
      (shelf) => shelf.id == 'albums_for_you',
    );
    if (videosIndex != -1 &&
        albumsIndex != -1 &&
        videosIndex != albumsIndex + 1) {
      final videosShelf = shelves.removeAt(videosIndex);
      final insertAt = shelves.indexWhere(
        (shelf) => shelf.id == 'albums_for_you',
      );
      if (insertAt == -1) {
        shelves.add(videosShelf);
      } else {
        shelves.insert(insertAt + 1, videosShelf);
      }
    }
    final throwbackPastIndex = shelves.indexWhere(
      (shelf) => shelf.id == 'ytmx_una_vuelta_al_pasado',
    );
    final newMusicIndex = shelves.indexWhere(
      (shelf) => shelf.id == 'ytmx_nueva_musica',
    );
    if (throwbackPastIndex != -1 &&
        newMusicIndex != -1 &&
        throwbackPastIndex > newMusicIndex) {
      final throwbackPastShelf = shelves.removeAt(throwbackPastIndex);
      final targetIndex = shelves.indexWhere(
        (shelf) => shelf.id == 'ytmx_nueva_musica',
      );
      if (targetIndex == -1) {
        shelves.add(throwbackPastShelf);
      } else {
        shelves.insert(targetIndex, throwbackPastShelf);
      }
    }
    if (shelves.isNotEmpty) {
      await _writeCuratedShelvesCache(shelves);
    }
    return shelves;
  }

  Future<List<_HomeShelf>> _loadYouTubeMusicMxShelvesFromChannel() async {
    const channelUrl =
        'https://www.youtube.com/channel/UC-9-kyTW8ZkZNDHQJ6FgpwQ';
    const targetTitles = <String, String>{
      'éxitos del momento': 'ytmx_exitos_del_momento',
      'nueva música': 'ytmx_nueva_musica',
      'una vuelta al pasado': 'ytmx_una_vuelta_al_pasado',
      'nuevos videos musicales': 'ytmx_nuevos_videos_musicales',
    };
    final normalizedToDisplay = <String, String>{
      'éxitos del momento': 'Éxitos del Momento',
      'nueva música': 'Nueva Música',
      'una vuelta al pasado': 'Una vuelta al pasado',
      'nuevos videos musicales': 'Nuevos videos musicales',
    };
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      final uri = Uri.parse(channelUrl);
      final request = await client.getUrl(uri);
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
      );
      request.headers.set(
        HttpHeaders.acceptLanguageHeader,
        'es-MX,es;q=0.9,en;q=0.8',
      );
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        client.close(force: true);
        return const <_HomeShelf>[];
      }
      final html = await utf8.decodeStream(response);
      client.close(force: true);

      final marker = 'var ytInitialData = ';
      final start = html.indexOf(marker);
      if (start == -1) return const <_HomeShelf>[];
      final end = html.indexOf(';</script>', start);
      if (end == -1) return const <_HomeShelf>[];
      final jsonRaw = html.substring(start + marker.length, end).trim();
      final root = jsonDecode(jsonRaw);
      if (root is! Map<String, dynamic>) return const <_HomeShelf>[];

      final found = <String, _HomeShelf>{};

      void walk(dynamic node) {
        if (node is Map) {
          final map = Map<String, dynamic>.from(node.cast<dynamic, dynamic>());
          final richShelf = map['richShelfRenderer'];
          if (richShelf is Map) {
            final shelf = Map<String, dynamic>.from(
              richShelf.cast<dynamic, dynamic>(),
            );
            final titleRaw = ((shelf['title'] as Map?)?['simpleText'] ?? '')
                .toString()
                .trim();
            final titleKey = titleRaw.toLowerCase();
            final shelfId = targetTitles[titleKey];
            if (shelfId != null && !found.containsKey(shelfId)) {
              final contents = (shelf['contents'] as List?) ?? const [];
              final tracks = <_HomeTrack>[];
              for (final rawItem in contents) {
                if (rawItem is! Map) continue;
                final richItem = Map<String, dynamic>.from(
                  rawItem.cast<dynamic, dynamic>(),
                );
                final lockup =
                    ((richItem['richItemRenderer'] as Map?)?['content']
                            as Map?)?['lockupViewModel']
                        as Map?;
                if (lockup == null) continue;
                final contentId = (lockup['contentId'] ?? '').toString().trim();
                if (contentId.isEmpty) continue;
                final contentType = (lockup['contentType'] ?? '')
                    .toString()
                    .trim()
                    .toUpperCase();
                final metadata =
                    (lockup['metadata'] as Map?)?['lockupMetadataViewModel']
                        as Map?;
                final playlistTitle =
                    ((metadata?['title'] as Map?)?['content'] ?? '')
                        .toString()
                        .trim();
                if (playlistTitle.isEmpty) continue;
                final description =
                    (((metadata?['metadata']
                                    as Map?)?['contentMetadataViewModel']
                                as Map?)?['metadataRows']
                            as List?)
                        ?.whereType<Map>()
                        .map((row) {
                          final parts =
                              (row['metadataParts'] as List?) ??
                              const <dynamic>[];
                          return parts
                              .whereType<Map>()
                              .map(
                                (part) =>
                                    ((part['text'] as Map?)?['content'] ?? '')
                                        .toString()
                                        .trim(),
                              )
                              .where((text) => text.isNotEmpty)
                              .join(' ');
                        })
                        .where((rowText) => rowText.trim().isNotEmpty)
                        .join(' • ')
                        .trim() ??
                    '';
                final thumbSources =
                    (((((lockup['contentImage']
                                            as Map?)?['collectionThumbnailViewModel']
                                        as Map?)?['primaryThumbnail']
                                    as Map?)?['thumbnailViewModel']
                                as Map?)?['image']
                            as Map?)?['sources']
                        as List? ??
                    const [];
                String thumbUrl = '';
                if (thumbSources.isNotEmpty && thumbSources.first is Map) {
                  thumbUrl = (thumbSources.first['url'] ?? '').toString();
                }
                final isMusicVideoShelf =
                    shelfId == 'ytmx_nuevos_videos_musicales' ||
                    contentType.contains('VIDEO');
                final itemId = isMusicVideoShelf
                    ? 'ytmxmv:$contentId'
                    : 'ytmx:$contentId';
                if (!isMusicVideoShelf) {
                  _ytMusicMxPlaylistRefByItemId[itemId] =
                      _HomeResolvedChannelPlaylistRef(
                        playlistId: contentId,
                        title: playlistTitle,
                        subtitle: 'YouTube Music México',
                        thumbnailUrl: thumbUrl,
                      );
                }
                tracks.add(
                  _HomeTrack(
                    videoId: itemId,
                    title: playlistTitle,
                    artist: description,
                    thumbnailUrl: thumbUrl,
                    isLocal: false,
                  ),
                );
                if (tracks.length >= 14) break;
              }
              if (tracks.isNotEmpty) {
                found[shelfId] = _HomeShelf(
                  id: shelfId,
                  title: normalizedToDisplay[titleKey] ?? titleRaw,
                  subtitle: '',
                  tracks: tracks,
                );
              }
            }
          }
          for (final value in map.values) {
            walk(value);
          }
        } else if (node is List) {
          for (final item in node) {
            walk(item);
          }
        }
      }

      walk(root);
      return [
        if (found['ytmx_exitos_del_momento'] != null)
          found['ytmx_exitos_del_momento']!,
        if (found['ytmx_una_vuelta_al_pasado'] != null)
          found['ytmx_una_vuelta_al_pasado']!,
        if (found['ytmx_nueva_musica'] != null) found['ytmx_nueva_musica']!,
        if (found['ytmx_nuevos_videos_musicales'] != null)
          found['ytmx_nuevos_videos_musicales']!,
      ];
    } catch (_) {
      return const <_HomeShelf>[];
    }
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

  Future<_HomeShelf> _buildSuggestedAlbumsShelf(
    List<VideoHistory> history,
  ) async {
    final topArtists = _extractTopArtists(history);
    final queries = <String>[
      'youtube music albums for you',
      ...topArtists.take(5).map((artist) => '$artist album youtube music'),
      ...topArtists
          .take(3)
          .map((artist) => '$artist full album official audio'),
      ...history
          .take(6)
          .map((item) => '${item.channelTitle} ${item.title} album'),
    ];

    final seen = <String>{};
    final tracks = <_HomeTrack>[];
    try {
      final batches = await Future.wait(queries.map(_yt.search.search));
      for (final batch in batches) {
        for (final video in batch.take(44)) {
          if (!_isValidSuggestedAlbumTrack(video)) continue;
          final id = video.id.value.trim();
          if (id.isEmpty || !seen.add(id)) continue;
          tracks.add(_HomeTrack.fromVideo(video));
          if (tracks.length >= 14) {
            return _HomeShelf(
              id: 'albums_for_you',
              title: 'Álbumes sugeridos',
              subtitle: 'Álbumes para ti en YouTube Music',
              tracks: tracks,
            );
          }
        }
      }
    } catch (_) {
      // Best effort.
    }

    if (tracks.length < 10) {
      final fallbackFromHistory = await _buildAlbumsFromHistoryFallback(
        history,
        seen,
      );
      for (final item in fallbackFromHistory) {
        if (seen.add(item.videoId)) {
          tracks.add(item);
        }
        if (tracks.length >= 14) break;
      }
    }

    return _HomeShelf(
      id: 'albums_for_you',
      title: 'Álbumes sugeridos',
      subtitle: 'Álbumes para ti en YouTube Music',
      tracks: tracks,
    );
  }

  Future<List<_HomeTrack>> _buildAlbumsFromHistoryFallback(
    List<VideoHistory> history,
    Set<String> seenIds,
  ) async {
    if (history.isEmpty) return const <_HomeTrack>[];
    final output = <_HomeTrack>[];
    final artistQueries = history
        .map((item) => cleanArtistName(item.channelTitle).trim())
        .where((artist) => artist.isNotEmpty)
        .toSet()
        .take(5)
        .map((artist) => '$artist album topic')
        .toList(growable: false);
    try {
      final batches = await Future.wait(artistQueries.map(_yt.search.search));
      for (final batch in batches) {
        for (final video in batch.take(30)) {
          if (!_isValidSuggestedAlbumTrack(video)) continue;
          final id = video.id.value.trim();
          if (id.isEmpty || seenIds.contains(id)) continue;
          output.add(_HomeTrack.fromVideo(video));
          if (output.length >= 14) return output;
        }
      }
    } catch (_) {
      // Best effort.
    }
    return output;
  }

  bool _isValidSuggestedAlbumTrack(Video video) {
    final title = video.title.toLowerCase();
    final author = video.author.toLowerCase();
    final description = video.description.toLowerCase();
    final blob = '$title $author $description';
    if (_shelfBlockedKeywords.any(blob.contains)) return false;
    if (_isBlockedSearchAuthor(author)) return false;
    final isVideoLike = _searchVideoLikeKeywords.any(blob.contains);
    if (isVideoLike) return false;
    final hasAlbumSignal =
        blob.contains('album') ||
        blob.contains('álbum') ||
        blob.contains('ep') ||
        blob.contains('deluxe') ||
        blob.contains('edition');
    final looksMusicSource =
        author.endsWith('- topic') ||
        author.endsWith('topic') ||
        blob.contains('official audio') ||
        blob.contains('youtube music');
    return hasAlbumSignal && looksMusicSource;
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

  Future<_HomeShelf> _buildMusicVideosShelfFallback() async {
    const fixedPlaylistId = 'OLLkIRtf8ibMYeheSlKEf7-Y4QtvTRt7low';
    final fixedFromPage = await _buildShelfFromPlaylistPage(
      shelfId: 'ytmx_nuevos_videos_musicales',
      title: 'Nuevos videos musicales',
      playlistId: fixedPlaylistId,
      forceVideoPrefix: true,
      limit: 18,
    );
    if (fixedFromPage.tracks.isNotEmpty) {
      return fixedFromPage;
    }
    final fixedTracks = await _buildShelfFromPlaylistId(
      shelfId: 'ytmx_nuevos_videos_musicales',
      title: 'Nuevos videos musicales',
      playlistId: fixedPlaylistId,
      forceVideoPrefix: true,
      limit: 18,
    );
    if (fixedTracks.tracks.isNotEmpty) {
      return fixedTracks;
    }

    const queries = <String>[
      'nuevos videos musicales mexico estreno oficial',
      'youtube music mexico nuevos videos musicales',
      'latin pop official music video estreno',
      'regional mexicano video oficial nuevo',
    ];
    final tracks = <_HomeTrack>[];
    final seen = <String>{};
    try {
      for (final query in queries) {
        final results = await _yt.search.search(query);
        for (final video in results.take(34)) {
          if (!_isValidMusicVideoShelfTrack(video)) continue;
          final id = video.id.value.trim();
          if (id.isEmpty || !seen.add(id)) continue;
          tracks.add(
            _HomeTrack(
              videoId: 'ytmxmv:$id',
              title: video.title,
              artist: cleanArtistName(video.author),
              thumbnailUrl: bestThumbnailForVideo(video),
              isLocal: false,
            ),
          );
          if (tracks.length >= 14) {
            return _HomeShelf(
              id: 'ytmx_nuevos_videos_musicales',
              title: 'Nuevos videos musicales',
              subtitle: '',
              tracks: tracks,
            );
          }
        }
      }
    } catch (_) {
      // Best effort.
    }
    return _HomeShelf(
      id: 'ytmx_nuevos_videos_musicales',
      title: 'Nuevos videos musicales',
      subtitle: '',
      tracks: tracks,
    );
  }

  Future<_HomeShelf> _buildShelfFromPlaylistId({
    required String shelfId,
    required String title,
    required String playlistId,
    required bool forceVideoPrefix,
    int limit = 14,
  }) async {
    final tracks = <_HomeTrack>[];
    final seen = <String>{};
    try {
      final videos = _yt.playlists.getVideos(playlistId);
      await for (final video in videos) {
        final id = video.id.value.trim();
        if (id.isEmpty || !seen.add(id)) continue;
        tracks.add(
          _HomeTrack(
            videoId: forceVideoPrefix ? 'ytmxmv:$id' : id,
            title: video.title,
            artist: cleanArtistName(video.author),
            thumbnailUrl: bestThumbnailForVideo(video),
            isLocal: false,
          ),
        );
        if (tracks.length >= limit) break;
      }
    } catch (_) {
      // Best effort.
    }
    return _HomeShelf(id: shelfId, title: title, subtitle: '', tracks: tracks);
  }

  Future<_HomeShelf> _buildShelfFromPlaylistPage({
    required String shelfId,
    required String title,
    required String playlistId,
    required bool forceVideoPrefix,
    int limit = 14,
  }) async {
    final tracks = <_HomeTrack>[];
    final seen = <String>{};
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      final uri = Uri.parse(
        'https://www.youtube.com/playlist?list=$playlistId',
      );
      final request = await client.getUrl(uri);
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
      );
      request.headers.set(
        HttpHeaders.acceptLanguageHeader,
        'es-MX,es;q=0.9,en;q=0.8',
      );
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        client.close(force: true);
        return _HomeShelf(
          id: shelfId,
          title: title,
          subtitle: '',
          tracks: tracks,
        );
      }
      final html = await utf8.decodeStream(response);
      client.close(force: true);

      final marker = 'var ytInitialData = ';
      final start = html.indexOf(marker);
      if (start == -1) {
        return _HomeShelf(
          id: shelfId,
          title: title,
          subtitle: '',
          tracks: tracks,
        );
      }
      final end = html.indexOf(';</script>', start);
      if (end == -1) {
        return _HomeShelf(
          id: shelfId,
          title: title,
          subtitle: '',
          tracks: tracks,
        );
      }
      final jsonRaw = html.substring(start + marker.length, end).trim();
      final root = jsonDecode(jsonRaw);
      if (root is! Map<String, dynamic>) {
        return _HomeShelf(
          id: shelfId,
          title: title,
          subtitle: '',
          tracks: tracks,
        );
      }

      void walk(dynamic node) {
        if (tracks.length >= limit) return;
        if (node is Map) {
          final map = Map<String, dynamic>.from(node.cast<dynamic, dynamic>());
          final renderer = map['playlistVideoRenderer'];
          if (renderer is Map) {
            final r = Map<String, dynamic>.from(
              renderer.cast<dynamic, dynamic>(),
            );
            final id = (r['videoId'] ?? '').toString().trim();
            if (id.isNotEmpty && seen.add(id)) {
              final titleRuns =
                  (((r['title'] as Map?)?['runs']) as List?) ?? const [];
              final videoTitle = titleRuns.isNotEmpty && titleRuns.first is Map
                  ? (titleRuns.first['text'] ?? '').toString().trim()
                  : '';
              final authorRuns =
                  ((((r['shortBylineText'] as Map?)?['runs']) as List?) ??
                  const []);
              final author = authorRuns.isNotEmpty && authorRuns.first is Map
                  ? cleanArtistName((authorRuns.first['text'] ?? '').toString())
                  : '';
              final thumbs =
                  (((((r['thumbnail'] as Map?)?['thumbnails']) as List?) ??
                  const []));
              String thumbUrl = '';
              if (thumbs.isNotEmpty && thumbs.last is Map) {
                thumbUrl = (thumbs.last['url'] ?? '').toString();
              }
              tracks.add(
                _HomeTrack(
                  videoId: forceVideoPrefix ? 'ytmxmv:$id' : id,
                  title: videoTitle.isEmpty ? 'Video musical' : videoTitle,
                  artist: author,
                  thumbnailUrl: thumbUrl,
                  isLocal: false,
                ),
              );
            }
          }
          for (final value in map.values) {
            walk(value);
            if (tracks.length >= limit) break;
          }
        } else if (node is List) {
          for (final item in node) {
            walk(item);
            if (tracks.length >= limit) break;
          }
        }
      }

      walk(root);
    } catch (_) {
      // Best effort.
    }
    return _HomeShelf(id: shelfId, title: title, subtitle: '', tracks: tracks);
  }

  bool _isValidMusicVideoShelfTrack(Video video) {
    final title = video.title.toLowerCase();
    final author = video.author.toLowerCase();
    final description = video.description.toLowerCase();
    final blob = '$title $author $description';
    if (_shelfBlockedKeywords.any(blob.contains)) return false;
    if (_isBlockedSearchAuthor(author)) return false;
    final hasMusicVideoSignal =
        blob.contains('official video') ||
        blob.contains('video oficial') ||
        blob.contains('music video') ||
        blob.contains('mv') ||
        blob.contains('videoclip');
    final isTopic = author.endsWith('- topic') || author.endsWith('topic');
    return hasMusicVideoSignal && !isTopic;
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

  Future<List<_HomeTrack>> _loadHistoryRandomRecommendationSeed(
    List<VideoHistory> history,
  ) async {
    if (history.isEmpty) return const <_HomeTrack>[];
    final manager = context.read<VideoPlayerManager>();
    final rand = math.Random();
    final ids = history
        .map((item) => item.videoId.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    ids.shuffle(rand);
    final seeds = ids.take(5).toList(growable: false);
    final queueBatches = await Future.wait(
      seeds.map(
        (seed) => manager.fetchQueueStyleRecommendations(
          limit: 12,
          seedVideoId: seed,
        ),
      ),
    );
    final output = <_HomeTrack>[];
    final seen = <String>{};
    for (final queueItems in queueBatches) {
      for (final item in queueItems) {
        final id = item.videoId.trim();
        if (id.isEmpty || !seen.add(id)) continue;
        output.add(_HomeTrack.fromQueueItem(item));
        if (output.length >= 40) return output;
      }
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
    required List<_HomeTrack> historyRandomSeed,
  }) {
    const target = 24;
    final rand = math.Random();
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

    // 0) Primero variamos con recomendaciones de 5 canciones aleatorias del historial.
    for (final item in historyRandomSeed) {
      add(item);
      if (suggestions.length >= target) return suggestions;
    }

    // 0.1) Luego parte de recomendados tipo Buscar/cola.
    for (final item in searchSeed.take(10)) {
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

    suggestions.shuffle(rand);
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
    final videosUpdated = _buildMusicVideosShelfFallback();
    final mexicanUpdated = _buildMexicanGenreShelf();
    setState(() {
      _contentFuture = updated;
      _trendingFuture = trendingUpdated;
      _musicVideosShelfFuture = videosUpdated;
      _mexicanGenreShelfFuture = mexicanUpdated;
    });
    await Future.wait([
      updated,
      trendingUpdated,
      videosUpdated,
      mexicanUpdated,
    ]);
  }

  Future<_HomeShelf> _buildMexicanGenreShelf() async {
    const endpoint =
        'https://music.youtube.com/youtubei/v1/browse?key=AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8';
    const clientVersion = '1.20240226.01.00';

    String runsToText(dynamic node) {
      final runs = (node as List?) ?? const [];
      return runs
          .whereType<Map>()
          .map((r) => (r['text'] ?? '').toString())
          .join()
          .trim();
    }

    Future<Map<String, dynamic>?> postBrowse({
      required String browseId,
      String? params,
      required String referer,
    }) async {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      try {
        final req = await client.postUrl(Uri.parse(endpoint));
        req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
        req.headers.set(HttpHeaders.acceptHeader, 'application/json');
        req.headers.set(
          HttpHeaders.userAgentHeader,
          'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        );
        req.headers.set('Origin', 'https://music.youtube.com');
        req.headers.set('Referer', referer);
        req.headers.set('X-Youtube-Client-Name', '67');
        req.headers.set('X-Youtube-Client-Version', clientVersion);
        req.add(
          utf8.encode(
            jsonEncode(<String, Object?>{
              'browseId': browseId,
              if (params != null && params.isNotEmpty) 'params': params,
              'context': {
                'client': {
                  'clientName': 'WEB_REMIX',
                  'clientVersion': clientVersion,
                  'hl': 'es-419',
                  'gl': 'MX',
                },
                'request': {'useSsl': true},
              },
              'contentCheckOk': true,
              'racyCheckOk': true,
            }),
          ),
        );
        final res = await req.close();
        if (res.statusCode < 200 || res.statusCode >= 300) return null;
        final body = await utf8.decoder.bind(res).join();
        final decoded = jsonDecode(body);
        if (decoded is Map<String, dynamic>) return decoded;
        if (decoded is Map) {
          return Map<String, dynamic>.from(decoded.cast<dynamic, dynamic>());
        }
        return null;
      } catch (_) {
        return null;
      } finally {
        client.close(force: true);
      }
    }

    String? musicaMexicanaParams(Map<String, dynamic> root) {
      String? out;
      void walk(dynamic n) {
        if (out != null) return;
        if (n is Map) {
          final m = Map<String, dynamic>.from(n.cast<dynamic, dynamic>());
          final btn = m['musicNavigationButtonRenderer'];
          if (btn is Map) {
            final b = Map<String, dynamic>.from(btn.cast<dynamic, dynamic>());
            final text = runsToText(
              (b['buttonText'] as Map?)?['runs'],
            ).toLowerCase();
            if (text == 'música mexicana' || text == 'musica mexicana') {
              final p =
                  (((b['clickCommand'] as Map?)?['browseEndpoint']
                              as Map?)?['params'] ??
                          '')
                      .toString()
                      .trim();
              if (p.isNotEmpty) out = p;
            }
          }
          for (final v in m.values) {
            walk(v);
          }
        } else if (n is List) {
          for (final v in n) {
            walk(v);
          }
        }
      }

      walk(root);
      return out;
    }

    final moodRoot = await postBrowse(
      browseId: 'FEmusic_moods_and_genres',
      referer: 'https://music.youtube.com/moods_and_genres',
    );
    if (moodRoot == null) {
      return const _HomeShelf(
        id: 'ytm_musica_mexicana',
        title: 'Música Mexicana',
        subtitle: '',
        tracks: [],
      );
    }
    final params = musicaMexicanaParams(moodRoot);
    if (params == null || params.isEmpty) {
      return const _HomeShelf(
        id: 'ytm_musica_mexicana',
        title: 'Música Mexicana',
        subtitle: '',
        tracks: [],
      );
    }

    final genreRoot = await postBrowse(
      browseId: 'FEmusic_moods_and_genres_category',
      params: params,
      referer: 'https://music.youtube.com/moods_and_genres',
    );
    if (genreRoot == null) {
      return const _HomeShelf(
        id: 'ytm_musica_mexicana',
        title: 'Música Mexicana',
        subtitle: '',
        tracks: [],
      );
    }

    String firstThumbFromAny(dynamic node) {
      final thumbs =
          (((node as Map?)?['thumbnail'] as Map?)?['thumbnails'] as List?) ??
          const [];
      if (thumbs.isNotEmpty && thumbs.last is Map) {
        return (thumbs.last['url'] ?? '').toString().trim();
      }
      return '';
    }

    final songTracks = <_HomeTrack>[];
    final playlistTracks = <_HomeTrack>[];
    final seen = <String>{};

    void addSongTrack({
      required String videoId,
      required String title,
      required String subtitle,
      required String thumbnailUrl,
    }) {
      final cleanVideoId = videoId.trim();
      final cleanTitle = title.trim();
      if (cleanVideoId.isEmpty || cleanTitle.isEmpty) return;
      final itemId = 'ytmxmv:$cleanVideoId';
      if (!seen.add(itemId)) return;
      songTracks.add(
        _HomeTrack(
          videoId: itemId,
          title: cleanTitle,
          artist: subtitle.trim(),
          thumbnailUrl: thumbnailUrl.trim(),
          isLocal: false,
        ),
      );
    }

    void addPlaylistTrack({
      required String browseId,
      required String title,
      required String subtitle,
      required String thumbnailUrl,
    }) {
      final cleanBrowseId = browseId.trim();
      final cleanTitle = title.trim();
      if (cleanBrowseId.isEmpty || cleanTitle.isEmpty) return;
      final itemId = 'ytmx:$cleanBrowseId';
      if (!seen.add(itemId)) return;
      _ytMusicMxPlaylistRefByItemId[itemId] = _HomeResolvedChannelPlaylistRef(
        playlistId: cleanBrowseId.startsWith('VL')
            ? cleanBrowseId.substring(2)
            : cleanBrowseId,
        title: cleanTitle,
        subtitle: '',
        thumbnailUrl: thumbnailUrl.trim(),
      );
      playlistTracks.add(
        _HomeTrack(
          videoId: itemId,
          title: cleanTitle,
          artist: subtitle.trim(),
          thumbnailUrl: thumbnailUrl.trim(),
          isLocal: false,
        ),
      );
    }

    void walkItems(dynamic n) {
      if (songTracks.length + playlistTracks.length >= 30) return;
      if (n is Map) {
        final m = Map<String, dynamic>.from(n.cast<dynamic, dynamic>());
        final twoRow = m['musicTwoRowItemRenderer'];
        if (twoRow is Map) {
          final r = Map<String, dynamic>.from(twoRow.cast<dynamic, dynamic>());
          final title = runsToText(((r['title'] as Map?)?['runs']));
          if (title.isNotEmpty) {
            final subtitle = runsToText(
              ((((r['subtitle'] as Map?)?['runs']) as List?) ?? const []),
            );
            final thumbs =
                (((((r['thumbnailRenderer'] as Map?)?['musicThumbnailRenderer']
                            as Map?)?['thumbnail']
                        as Map?)?['thumbnails']
                    as List?) ??
                const []);
            var thumbUrl = '';
            if (thumbs.isNotEmpty && thumbs.last is Map) {
              thumbUrl = (thumbs.last['url'] ?? '').toString().trim();
            }
            final nav = (r['navigationEndpoint'] as Map?) ?? const {};
            final watchVideoId =
                (((nav['watchEndpoint'] as Map?)?['videoId'] ?? '').toString())
                    .trim();
            final browseId =
                (((nav['browseEndpoint'] as Map?)?['browseId'] ?? '')
                        .toString())
                    .trim();
            if (watchVideoId.isNotEmpty) {
              addSongTrack(
                videoId: watchVideoId,
                title: title,
                subtitle: subtitle,
                thumbnailUrl: thumbUrl,
              );
            } else if (browseId.isNotEmpty) {
              addPlaylistTrack(
                browseId: browseId,
                title: title,
                subtitle: subtitle,
                thumbnailUrl: thumbUrl,
              );
            }
          }
        }
        final responsive = m['musicResponsiveListItemRenderer'];
        if (responsive is Map) {
          final r = Map<String, dynamic>.from(
            responsive.cast<dynamic, dynamic>(),
          );
          final flexColumns = (r['flexColumns'] as List?) ?? const [];
          String title = '';
          String subtitle = '';
          if (flexColumns.isNotEmpty && flexColumns.first is Map) {
            final firstCol = Map<String, dynamic>.from(
              flexColumns.first.cast<dynamic, dynamic>(),
            );
            title = runsToText(
              (((firstCol['musicResponsiveListItemFlexColumnRenderer']
                          as Map?)?['text']
                      as Map?)?['runs']) ??
                  const [],
            );
          }
          if (flexColumns.length > 1 && flexColumns[1] is Map) {
            final secondCol = Map<String, dynamic>.from(
              flexColumns[1].cast<dynamic, dynamic>(),
            );
            subtitle = runsToText(
              (((secondCol['musicResponsiveListItemFlexColumnRenderer']
                          as Map?)?['text']
                      as Map?)?['runs']) ??
                  const [],
            );
          }
          final thumbFromRenderer = firstThumbFromAny(
            ((r['thumbnail'] as Map?)?['musicThumbnailRenderer']) as Map? ?? {},
          );
          final nav = (r['navigationEndpoint'] as Map?) ?? const {};
          final watchVideoId =
              (((nav['watchEndpoint'] as Map?)?['videoId'] ?? '').toString())
                  .trim();
          final watchPlaylistId =
              (((nav['watchEndpoint'] as Map?)?['playlistId'] ?? '').toString())
                  .trim();
          final browseId =
              (((nav['browseEndpoint'] as Map?)?['browseId'] ?? '').toString())
                  .trim();

          if (watchVideoId.isNotEmpty) {
            addSongTrack(
              videoId: watchVideoId,
              title: title,
              subtitle: subtitle,
              thumbnailUrl: thumbFromRenderer,
            );
          } else if (watchPlaylistId.isNotEmpty || browseId.isNotEmpty) {
            final playlistId = watchPlaylistId.isNotEmpty
                ? watchPlaylistId
                : browseId;
            addPlaylistTrack(
              browseId: playlistId,
              title: title,
              subtitle: subtitle,
              thumbnailUrl: thumbFromRenderer,
            );
          }
        }
        for (final v in m.values) {
          walkItems(v);
          if (songTracks.length + playlistTracks.length >= 30) {
            break;
          }
        }
      } else if (n is List) {
        for (final v in n) {
          walkItems(v);
          if (songTracks.length + playlistTracks.length >= 30) {
            break;
          }
        }
      }
    }

    walkItems(genreRoot);
    final orderedTracks = <_HomeTrack>[...songTracks, ...playlistTracks];
    return _HomeShelf(
      id: 'ytm_musica_mexicana',
      title: 'Música Mexicana',
      subtitle: '',
      tracks: orderedTracks,
    );
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

  Future<void> _openResolvedAlbumRef(_HomeResolvedAlbumRef resolved) async {
    if (!mounted) return;
    await Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => AlbumTracksPage(
          playlistId: resolved.playlistId,
          albumTitle: resolved.title,
          artistName: resolved.artist,
          seedThumbnailUrl: resolved.thumbnailUrl,
        ),
      ),
    );
  }

  Future<void> _openChannelPlaylistRef(
    _HomeResolvedChannelPlaylistRef resolved, {
    bool showTrackArtwork = false,
  }) async {
    if (!mounted) return;
    await Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => AlbumTracksPage(
          playlistId: resolved.playlistId,
          albumTitle: resolved.title,
          artistName: resolved.subtitle,
          seedThumbnailUrl: resolved.thumbnailUrl,
          showTrackArtwork: showTrackArtwork,
        ),
      ),
    );
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

  Future<_HomeShelf> _buildSuggestedAlbumsShelfFromSuggestions(
    List<_HomeTrack> suggestions,
  ) async {
    _albumShelfRefByItemId.clear();
    if (suggestions.isEmpty) {
      return const _HomeShelf(
        id: 'albums_for_you',
        title: 'Álbumes sugeridos',
        subtitle: 'Álbumes relacionados a tus sugerencias',
        tracks: [],
      );
    }

    final uniqueSuggestions = <_HomeTrack>[];
    final seenVideos = <String>{};
    for (final item in suggestions) {
      if (!seenVideos.add(item.videoId)) continue;
      uniqueSuggestions.add(item);
      if (uniqueSuggestions.length >= 12) break;
    }

    final results = await Future.wait(
      uniqueSuggestions.map(_resolveAlbumRefFast),
    );
    final tracks = <_HomeTrack>[];
    final seenAlbums = <String>{};
    for (final resolved in results) {
      if (resolved == null) continue;
      final albumId = resolved.playlistId.trim();
      if (albumId.isEmpty || !seenAlbums.add(albumId)) continue;
      final itemId = 'album:$albumId';
      _albumShelfRefByItemId[itemId] = resolved;
      tracks.add(
        _HomeTrack(
          videoId: itemId,
          title: resolved.title,
          artist: cleanArtistName(resolved.artist),
          thumbnailUrl: resolved.thumbnailUrl,
          isLocal: false,
        ),
      );
      if (tracks.length >= 14) break;
    }
    tracks.shuffle(math.Random());

    return _HomeShelf(
      id: 'albums_for_you',
      title: 'Álbumes sugeridos',
      subtitle: 'Álbumes relacionados a tus sugerencias',
      tracks: tracks,
    );
  }

  Rect _shareOriginFromContext(BuildContext context) {
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox != null && renderBox.hasSize) {
      return renderBox.localToGlobal(Offset.zero) & renderBox.size;
    }
    return const Rect.fromLTWH(1, 1, 1, 1);
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

  Future<void> _handleShelfItemTap(_HomeShelf shelf, _HomeTrack item) async {
    final enableTrackArtworkForYtMxShelf =
        shelf.id == 'ytmx_exitos_del_momento' ||
        shelf.id == 'ytmx_nueva_musica' ||
        shelf.id == 'ytmx_una_vuelta_al_pasado' ||
        shelf.id == 'ytm_musica_mexicana';
    final rawGlobalId = item.videoId.trim();
    if (rawGlobalId.startsWith('ytmxmv:') && rawGlobalId.length > 7) {
      final videoId = rawGlobalId.substring(7).trim();
      if (videoId.isNotEmpty) {
        await context.read<VideoPlayerManager>().playFromUserSelection(
          context,
          videoId,
          preferredThumbnailUrl: item.thumbnailUrl,
          preferredTitle: item.title,
          preferredArtist: item.artist,
          preferVideoPlayback: true,
        );
        return;
      }
    }
    if (rawGlobalId.startsWith('ytmx:') && rawGlobalId.length > 5) {
      final mapped = _ytMusicMxPlaylistRefByItemId[rawGlobalId];
      if (mapped != null) {
        await _openChannelPlaylistRef(
          mapped,
          showTrackArtwork: enableTrackArtworkForYtMxShelf,
        );
        return;
      }
      final playlistId = rawGlobalId.substring(5).trim();
      if (playlistId.isNotEmpty) {
        await _openChannelPlaylistRef(
          _HomeResolvedChannelPlaylistRef(
            playlistId: playlistId,
            title: item.title,
            subtitle: '',
            thumbnailUrl: item.thumbnailUrl,
          ),
          showTrackArtwork: enableTrackArtworkForYtMxShelf,
        );
        return;
      }
    }

    if (shelf.id.startsWith('ytmx_')) {
      if (shelf.id == 'ytmx_nuevos_videos_musicales') {
        final rawId = item.videoId.trim();
        final videoId = rawId.startsWith('ytmxmv:') && rawId.length > 7
            ? rawId.substring(7).trim()
            : rawId;
        if (videoId.isNotEmpty) {
          await context.read<VideoPlayerManager>().playFromUserSelection(
            context,
            videoId,
            preferredThumbnailUrl: item.thumbnailUrl,
            preferredTitle: item.title,
            preferredArtist: item.artist,
            preferVideoPlayback: true,
          );
          return;
        }
      }
      final rawId = item.videoId.trim();
      if (rawId.startsWith('ytmxmv:') && rawId.length > 7) {
        final videoId = rawId.substring(7).trim();
        if (videoId.isNotEmpty) {
          await context.read<VideoPlayerManager>().playFromUserSelection(
            context,
            videoId,
            preferredThumbnailUrl: item.thumbnailUrl,
            preferredTitle: item.title,
            preferredArtist: item.artist,
            preferVideoPlayback: true,
          );
          return;
        }
      }
      final resolved = _ytMusicMxPlaylistRefByItemId[item.videoId];
      if (resolved != null) {
        await _openChannelPlaylistRef(
          resolved,
          showTrackArtwork: enableTrackArtworkForYtMxShelf,
        );
        return;
      }
      if (rawId.startsWith('ytmx:') && rawId.length > 5) {
        final playlistId = rawId.substring(5).trim();
        if (playlistId.isNotEmpty) {
          await _openChannelPlaylistRef(
            _HomeResolvedChannelPlaylistRef(
              playlistId: playlistId,
              title: item.title,
              subtitle: '',
              thumbnailUrl: item.thumbnailUrl,
            ),
            showTrackArtwork: enableTrackArtworkForYtMxShelf,
          );
          return;
        }
      }
    }
    if (shelf.id == 'albums_for_you') {
      final resolved = _albumShelfRefByItemId[item.videoId];
      if (resolved != null) {
        await _openResolvedAlbumRef(resolved);
        return;
      }
      await _openAlbumFromTrack(item);
      return;
    }
    await _playTrack(item);
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
            final content = snapshot.data;
            if (snapshot.connectionState == ConnectionState.waiting &&
                content == null) {
              return const Center(
                child: CupertinoActivityIndicator(radius: 14),
              );
            }

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
            final topPicks = content.suggestions
                .take(12)
                .toList(growable: false);
            final matchingVideoShelves = content.curatedShelves
                .where((s) => s.id == 'ytmx_nuevos_videos_musicales')
                .toList(growable: false);
            final videosShelfFromContent = matchingVideoShelves.isNotEmpty
                ? matchingVideoShelves.first
                : null;
            final curatedShelvesForRender =
                content.curatedShelves
                    .where((s) => s.id != 'ytmx_nuevos_videos_musicales')
                    .toList(growable: false)
                  ..sort((a, b) {
                    const preferredOrder = <String, int>{
                      'albums_for_you': 10,
                      'ytmx_exitos_del_momento': 20,
                      'ytmx_una_vuelta_al_pasado': 30,
                      'ytmx_nueva_musica': 40,
                    };
                    final rankA = preferredOrder[a.id] ?? 1000;
                    final rankB = preferredOrder[b.id] ?? 1000;
                    if (rankA != rankB) return rankA.compareTo(rankB);
                    return 0;
                  });
            final hasAlbumsSuggested = curatedShelvesForRender.any(
              (s) => s.id == 'albums_for_you',
            );

            return CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                CupertinoSliverRefreshControl(onRefresh: _refresh),
                const SliverToBoxAdapter(child: SizedBox(height: 10)),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 2, 18, 8),
                    child: const Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Listen Now',
                            style: TextStyle(
                              fontFamily: '.SF Pro Display',
                              fontSize: 38,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.9,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SliverToBoxAdapter(child: _HomeProfileNowPlayingHeader()),
                _SectionHeaderSliver(
                  title: 'Top Picks',
                  subtitle: 'Just Updated',
                ),
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 286,
                    child: ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                      scrollDirection: Axis.horizontal,
                      itemCount: topPicks.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 12),
                      itemBuilder: (context, index) {
                        final item = topPicks[index];
                        return _HeroTopPickCard(
                          item: item,
                          onTap: () => _playTrack(item),
                          onContextAction: (action) =>
                              _runTrackContextAction(item, action),
                        );
                      },
                    ),
                  ),
                ),
                if (curatedShelvesForRender.isNotEmpty) ...[
                  const SliverToBoxAdapter(child: SizedBox(height: 10)),
                  _SectionHeaderSliver(
                    title: 'Browse',
                    subtitle: 'Quick picks, throwbacks and trending playlists',
                  ),
                  for (final shelf in curatedShelvesForRender) ...[
                    _SectionHeaderSliver(
                      title: shelf.title,
                      subtitle:
                          shelf.id == 'ytmx_exitos_del_momento' ||
                              shelf.id == 'ytmx_nueva_musica' ||
                              shelf.id == 'ytmx_una_vuelta_al_pasado'
                          ? ''
                          : shelf.subtitle,
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
                                onTap: (item) =>
                                    _handleShelfItemTap(shelf, item),
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
                    else if (shelf.id == 'albums_for_you' ||
                        shelf.id == 'ytmx_exitos_del_momento' ||
                        shelf.id == 'ytmx_nueva_musica')
                      SliverToBoxAdapter(
                        child: SizedBox(
                          height: 286,
                          child: ListView.separated(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                            scrollDirection: Axis.horizontal,
                            itemCount: shelf.tracks.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(width: 12),
                            itemBuilder: (context, index) {
                              final item = shelf.tracks[index];
                              return _HeroTopPickCard(
                                item: item,
                                onTap: () => _handleShelfItemTap(shelf, item),
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
                                onTap: () => _handleShelfItemTap(shelf, item),
                              );
                            },
                          ),
                        ),
                      ),
                    if (shelf.id == 'albums_for_you') ...[
                      const _SectionHeaderSliver(
                        title: 'Nuevos videos musicales',
                        subtitle: '',
                      ),
                      SliverToBoxAdapter(
                        child: FutureBuilder<_HomeShelf>(
                          future: _musicVideosShelfFuture,
                          builder: (context, videosSnapshot) {
                            final shelfData =
                                videosSnapshot.data ?? videosShelfFromContent;
                            if (shelfData == null || shelfData.tracks.isEmpty) {
                              return const SizedBox(
                                height: 210,
                                child: Center(
                                  child: CupertinoActivityIndicator(radius: 12),
                                ),
                              );
                            }
                            return SizedBox(
                              height: 232,
                              child: ListView.separated(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  8,
                                  16,
                                  10,
                                ),
                                scrollDirection: Axis.horizontal,
                                itemCount: shelfData.tracks.length,
                                separatorBuilder: (_, _) =>
                                    const SizedBox(width: 12),
                                itemBuilder: (context, index) {
                                  final item = shelfData.tracks[index];
                                  return _HomeVideoFeatureCard(
                                    item: item,
                                    onTap: () => _handleShelfItemTap(
                                      const _HomeShelf(
                                        id: 'ytmx_nuevos_videos_musicales',
                                        title: 'Nuevos videos musicales',
                                        subtitle: '',
                                        tracks: [],
                                      ),
                                      item,
                                    ),
                                  );
                                },
                              ),
                            );
                          },
                        ),
                      ),
                      const _SectionHeaderSliver(
                        title: 'Música Mexicana',
                        subtitle: '',
                      ),
                      SliverToBoxAdapter(
                        child: FutureBuilder<_HomeShelf>(
                          future: _mexicanGenreShelfFuture,
                          builder: (context, mexicanSnapshot) {
                            final shelfData = mexicanSnapshot.data;
                            if (shelfData == null || shelfData.tracks.isEmpty) {
                              return const SizedBox(
                                height: 210,
                                child: Center(
                                  child: CupertinoActivityIndicator(radius: 12),
                                ),
                              );
                            }
                            final songItems = shelfData.tracks
                                .where(
                                  (track) => track.videoId.trim().startsWith(
                                    'ytmxmv:',
                                  ),
                                )
                                .toList(growable: false);
                            final playlistItems = shelfData.tracks
                                .where(
                                  (track) =>
                                      track.videoId.trim().startsWith('ytmx:'),
                                )
                                .toList(growable: false);
                            return SizedBox(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (songItems.isNotEmpty) ...[
                                    SizedBox(
                                      height: 320,
                                      child: ListView.separated(
                                        padding: const EdgeInsets.fromLTRB(
                                          16,
                                          6,
                                          16,
                                          8,
                                        ),
                                        scrollDirection: Axis.horizontal,
                                        itemCount: _buildTrackColumns(
                                          songItems,
                                          itemsPerColumn: 4,
                                        ).length,
                                        separatorBuilder: (_, _) =>
                                            const SizedBox(width: 12),
                                        itemBuilder: (context, index) {
                                          final columnItems =
                                              _buildTrackColumns(
                                                songItems,
                                                itemsPerColumn: 4,
                                              )[index];
                                          return _StackedTrackColumn(
                                            items: columnItems,
                                            onTap: (item) =>
                                                _handleShelfItemTap(
                                                  const _HomeShelf(
                                                    id: 'ytm_musica_mexicana',
                                                    title: 'Música Mexicana',
                                                    subtitle: '',
                                                    tracks: [],
                                                  ),
                                                  item,
                                                ),
                                            onSwipeToQueueNext: (item) =>
                                                _addTrackToQueue(
                                                  item,
                                                  insertMode:
                                                      ManualQueueInsertMode
                                                          .next,
                                                ),
                                            onSwipeToQueueEnd: (item) =>
                                                _addTrackToQueue(
                                                  item,
                                                  insertMode:
                                                      ManualQueueInsertMode.end,
                                                ),
                                            onContextAction:
                                                _runTrackContextAction,
                                            allowSwipeToQueue: false,
                                            thinCards: true,
                                          );
                                        },
                                      ),
                                    ),
                                  ],
                                  if (playlistItems.isNotEmpty) ...[
                                    const Padding(
                                      padding: EdgeInsets.fromLTRB(
                                        18,
                                        4,
                                        18,
                                        6,
                                      ),
                                      child: Text(
                                        'Playlists',
                                        style: TextStyle(
                                          fontFamily: '.SF Pro Display',
                                          fontSize: 22,
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: -0.3,
                                        ),
                                      ),
                                    ),
                                    SizedBox(
                                      height: 222,
                                      child: ListView.separated(
                                        padding: const EdgeInsets.fromLTRB(
                                          16,
                                          6,
                                          16,
                                          8,
                                        ),
                                        scrollDirection: Axis.horizontal,
                                        itemCount: playlistItems.length,
                                        separatorBuilder: (_, _) =>
                                            const SizedBox(width: 12),
                                        itemBuilder: (context, index) {
                                          final item = playlistItems[index];
                                          return _HomeFeatureCard(
                                            item: item,
                                            onTap: () => _handleShelfItemTap(
                                              const _HomeShelf(
                                                id: 'ytm_musica_mexicana',
                                                title: 'Música Mexicana',
                                                subtitle: '',
                                                tracks: [],
                                              ),
                                              item,
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ],
                  if (!hasAlbumsSuggested) ...[
                    const _SectionHeaderSliver(
                      title: 'Nuevos videos musicales',
                      subtitle: '',
                    ),
                    SliverToBoxAdapter(
                      child: FutureBuilder<_HomeShelf>(
                        future: _musicVideosShelfFuture,
                        builder: (context, videosSnapshot) {
                          final shelfData =
                              videosSnapshot.data ?? videosShelfFromContent;
                          if (shelfData == null || shelfData.tracks.isEmpty) {
                            return const SizedBox(
                              height: 210,
                              child: Center(
                                child: CupertinoActivityIndicator(radius: 12),
                              ),
                            );
                          }
                          return SizedBox(
                            height: 232,
                            child: ListView.separated(
                              padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                              scrollDirection: Axis.horizontal,
                              itemCount: shelfData.tracks.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(width: 12),
                              itemBuilder: (context, index) {
                                final item = shelfData.tracks[index];
                                return _HomeVideoFeatureCard(
                                  item: item,
                                  onTap: () => _handleShelfItemTap(
                                    const _HomeShelf(
                                      id: 'ytmx_nuevos_videos_musicales',
                                      title: 'Nuevos videos musicales',
                                      subtitle: '',
                                      tracks: [],
                                    ),
                                    item,
                                  ),
                                );
                              },
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ],
                const SliverToBoxAdapter(child: SizedBox(height: 6)),
                _SectionHeaderSliver(title: 'Recently Played  >', subtitle: ''),
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
  static const Map<String, String> _youtubePreviewHeaders = <String, String>{
    'User-Agent':
        'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
    'Accept': '*/*',
    'Origin': 'https://www.youtube.com',
    'Referer': 'https://www.youtube.com/',
  };
  static const List<String> _noteReactionEmojis = <String>[
    '🔥',
    '❤️',
    '👍🏻',
    '😭',
    '😯',
    '🍅',
  ];
  List<SocialUser> _followingUsers = const <SocialUser>[];
  final YoutubeExplode _yt = YoutubeExplode();
  final AudioPlayer _friendPreviewPlayer = AudioPlayer();
  final LyricsService _lyricsService = LyricsService();
  RealtimeChannel? _friendRealtimeChannel;
  RealtimeChannel? _reactionNotificationChannel;
  Timer? _reactionNotificationPollTimer;
  DateTime _lastReactionNotificationCheckUtc = DateTime.now().toUtc();
  Set<String> _followingIds = <String>{};
  Timer? _friendRefreshTimer;
  final Map<String, String> _friendPhotoUrlById = <String, String>{};
  final Map<String, ImageProvider<Object>> _friendImageById =
      <String, ImageProvider<Object>>{};
  final Map<String, String> _friendPreviewVideoIdByFriendId =
      <String, String>{};
  final Map<String, String> _friendPreviewUrlByFriendId = <String, String>{};
  Map<String, MusicNoteReactionSummary> _noteReactionByUserId =
      const <String, MusicNoteReactionSummary>{};
  bool _isSendingReaction = false;
  bool _resumeMainPlayerAfterPreview = false;
  final ValueNotifier<bool> _isFriendPreviewLoading = ValueNotifier<bool>(
    false,
  );
  final ValueNotifier<bool> _isFriendPreviewLyricsLoading = ValueNotifier<bool>(
    false,
  );
  final ValueNotifier<_FriendPreviewLyricSweepState?> _friendPreviewLyricSweep =
      ValueNotifier<_FriendPreviewLyricSweepState?>(null);
  List<SyncedLyricLine> _friendPreviewSyncedLyrics = const [];
  int _friendPreviewRequestEpoch = 0;
  StreamSubscription<PlayerState>? _friendPreviewStateSub;
  StreamSubscription<Duration>? _friendPreviewPositionSub;
  final Map<String, String> _reactorDisplayNameCache = <String, String>{};
  final Set<String> _handledReactionNotificationIds = <String>{};

  bool get _shouldRunLiveWork {
    if (!mounted) return false;
    final appInForeground = context
        .read<VideoPlayerManager>()
        .isAppInForeground;
    if (!appInForeground) return false;
    final selectedTab = context.read<AppTabState?>()?.selectedIndex ?? 0;
    return selectedTab == 0;
  }

  String _songKeyForTrack({
    required String? videoId,
    required String? song,
    required String? artist,
  }) {
    return SocialService.buildMusicNoteSongKey(
      videoId: videoId,
      song: song,
      artist: artist,
    );
  }

  String _reactionMapKey({required String userId, required String songKey}) {
    return SocialService.buildMusicNoteReactionMapKey(
      targetUserId: userId,
      songKey: songKey,
    );
  }

  void _notifyIfMyReactionCountIncreased({
    required Map<String, MusicNoteReactionSummary> previous,
    required Map<String, MusicNoteReactionSummary> next,
  }) {
    if (!mounted) return;
    final social = context.read<SocialService>();
    final manager = context.read<VideoPlayerManager>();
    final myId = (social.myUserId ?? '').trim();
    if (myId.isEmpty) return;
    final mySongKey = _songKeyForTrack(
      videoId: manager.currentVideoId,
      song: manager.trackTitle,
      artist: manager.trackArtist,
    );
    if (mySongKey.isEmpty) return;
    final key = _reactionMapKey(userId: myId, songKey: mySongKey);
    final prevCount = previous[key]?.count ?? 0;
    final nextSummary = next[key];
    final nextCount = nextSummary?.count ?? 0;
    if (nextCount <= prevCount) return;
    final emoji = (nextSummary?.topEmoji ?? '').trim();
    final suffix = emoji.isEmpty ? '' : ' $emoji';
    _showQueueIosToast(
      context,
      message: 'Nueva reacción en tu canción$suffix',
      icon: CupertinoIcons.bell_fill,
    );
  }

  void _setFriendPreviewLoading(bool value) {
    if (_isFriendPreviewLoading.value == value) return;
    _isFriendPreviewLoading.value = value;
  }

  void _clearFriendPreviewLyrics() {
    _friendPreviewSyncedLyrics = const [];
    if (_isFriendPreviewLyricsLoading.value) {
      _isFriendPreviewLyricsLoading.value = false;
    }
    if (_friendPreviewLyricSweep.value != null) {
      _friendPreviewLyricSweep.value = null;
    }
  }

  void _updateFriendPreviewActiveLyric(Duration position) {
    final lines = _friendPreviewSyncedLyrics;
    if (lines.isEmpty) {
      if (_friendPreviewLyricSweep.value != null) {
        _friendPreviewLyricSweep.value = null;
      }
      return;
    }
    var low = 0;
    var high = lines.length - 1;
    var answer = -1;
    while (low <= high) {
      final mid = low + ((high - low) >> 1);
      final ts = lines[mid].timestamp;
      if (ts <= position) {
        answer = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    final text = answer < 0 ? '' : lines[answer].text.trim();
    if (text.isEmpty) {
      if (_friendPreviewLyricSweep.value != null) {
        _friendPreviewLyricSweep.value = null;
      }
      return;
    }
    final lineStart = lines[answer].timestamp;
    Duration? lineEnd;
    for (var i = answer + 1; i < lines.length; i++) {
      final nextTs = lines[i].timestamp;
      if (nextTs > lineStart) {
        lineEnd = nextTs;
        break;
      }
    }
    final durationMs =
        ((lineEnd ?? (lineStart + const Duration(seconds: 4))) - lineStart)
            .inMilliseconds;
    final safeDurationMs = durationMs <= 0 ? 1 : durationMs;
    final elapsedMs = (position - lineStart).inMilliseconds;
    final progress = (elapsedMs / safeDurationMs).clamp(0.0, 1.0);
    final next = _FriendPreviewLyricSweepState(text: text, progress: progress);
    final current = _friendPreviewLyricSweep.value;
    if (current == null ||
        current.text != next.text ||
        (current.progress - next.progress).abs() > 0.006) {
      _friendPreviewLyricSweep.value = next;
    }
  }

  Future<void> _loadFriendPreviewLyrics({
    required String? title,
    required String? artist,
    required int requestEpoch,
  }) async {
    final cleanTitle = (title ?? '').trim();
    final cleanArtist = (artist ?? '').trim();
    _clearFriendPreviewLyrics();
    if (cleanTitle.isEmpty || cleanArtist.isEmpty) return;
    _isFriendPreviewLyricsLoading.value = true;
    try {
      final result = await _lyricsService.fetchLyrics(
        title: cleanTitle,
        artist: cleanArtist,
      );
      if (!mounted || requestEpoch != _friendPreviewRequestEpoch) return;
      final synced = result?.syncedLyrics ?? const <SyncedLyricLine>[];
      if (synced.isEmpty) return;
      _friendPreviewSyncedLyrics = List<SyncedLyricLine>.from(synced);
      _updateFriendPreviewActiveLyric(_friendPreviewPlayer.position);
    } catch (_) {
      // Mejor esfuerzo.
    } finally {
      if (mounted && requestEpoch == _friendPreviewRequestEpoch) {
        _isFriendPreviewLyricsLoading.value = false;
      }
    }
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
    _friendPreviewPositionSub = _friendPreviewPlayer
        .createPositionStream(
          steps: 220,
          minPeriod: const Duration(milliseconds: 220),
          maxPeriod: const Duration(milliseconds: 750),
        )
        .listen((position) {
          _updateFriendPreviewActiveLyric(position);
        });
    unawaited(_attachReactionNotificationListener());
    _reactionNotificationPollTimer = Timer.periodic(
      const Duration(seconds: 12),
      (_) {
        if (!_shouldRunLiveWork) return;
        unawaited(_pollReactionNotifications());
      },
    );
    unawaited(_loadFollowingPreview());
  }

  Future<void> _attachReactionNotificationListener() async {
    try {
      final social = context.read<SocialService>();
      await social.ensureReady();
      if (!mounted) return;
      final myId = (social.myUserId ?? '').trim();
      if (myId.isEmpty) return;

      _reactionNotificationChannel?.unsubscribe();
      _reactionNotificationChannel =
          Supabase.instance.client.channel('music-note-reactions:$myId')
            ..onPostgresChanges(
              event: PostgresChangeEvent.insert,
              schema: 'public',
              table: 'music_note_reactions',
              callback: (payload) {
                unawaited(_handleReactionNotification(payload.newRecord));
              },
            )
            ..onPostgresChanges(
              event: PostgresChangeEvent.update,
              schema: 'public',
              table: 'music_note_reactions',
              callback: (payload) {
                unawaited(_handleReactionNotification(payload.newRecord));
              },
            )
            ..subscribe();
    } catch (_) {
      // Mejor esfuerzo: si falla realtime, no bloqueamos la UI.
    }
  }

  Future<void> _handleReactionNotification(Map<String, dynamic> row) async {
    if (!mounted) return;
    final social = context.read<SocialService>();
    final myId = (social.myUserId ?? '').trim();
    if (myId.isEmpty) return;
    final targetUserId = (row['target_user_id'] ?? '').toString().trim();
    if (targetUserId != myId) return;
    final reactorId = (row['reactor_id'] ?? '').toString().trim();
    if (reactorId.isEmpty || reactorId == myId) return;
    final emoji = (row['emoji'] ?? '').toString().trim();
    if (emoji.isEmpty) return;

    final reactorName = await _resolveReactorDisplayName(reactorId);
    if (!mounted) return;
    _showQueueIosToast(
      context,
      message: '$reactorName reaccionó $emoji a tu canción',
      icon: CupertinoIcons.bell_fill,
    );
  }

  Future<void> _pollReactionNotifications() async {
    if (!_shouldRunLiveWork) return;
    try {
      final social = context.read<SocialService>();
      await social.ensureReady();
      if (!mounted) return;
      final myId = (social.myUserId ?? '').trim();
      if (myId.isEmpty) return;
      final nowUtc = DateTime.now().toUtc();
      final fromIso = _lastReactionNotificationCheckUtc.toIso8601String();

      final rows = await Supabase.instance.client
          .from('music_note_reactions')
          .select('reactor_id, target_user_id, emoji, updated_at, song_key')
          .eq('target_user_id', myId)
          .gt('updated_at', fromIso)
          .order('updated_at', ascending: true)
          .limit(30);

      _lastReactionNotificationCheckUtc = nowUtc;
      if (!mounted) return;
      if (rows.isEmpty) return;

      for (final raw in rows) {
        final row = Map<String, dynamic>.from(raw);
        final reactorId = (row['reactor_id'] ?? '').toString().trim();
        final targetUserId = (row['target_user_id'] ?? '').toString().trim();
        final emoji = (row['emoji'] ?? '').toString().trim();
        final updatedAt = (row['updated_at'] ?? '').toString().trim();
        final songKey = (row['song_key'] ?? '').toString().trim();
        if (reactorId.isEmpty ||
            targetUserId.isEmpty ||
            emoji.isEmpty ||
            updatedAt.isEmpty) {
          continue;
        }
        if (reactorId == myId || targetUserId != myId) continue;
        final dedupeKey = '$reactorId|$targetUserId|$songKey|$emoji|$updatedAt';
        if (_handledReactionNotificationIds.contains(dedupeKey)) continue;
        _handledReactionNotificationIds.add(dedupeKey);
        final reactorName = await _resolveReactorDisplayName(reactorId);
        if (!mounted) return;
        _showQueueIosToast(
          context,
          message: '$reactorName reaccionó $emoji a tu canción',
          icon: CupertinoIcons.bell_fill,
        );
      }
    } catch (_) {
      // Mejor esfuerzo.
    }
  }

  Future<String> _resolveReactorDisplayName(String reactorId) async {
    final cleanId = reactorId.trim();
    if (cleanId.isEmpty) return 'Alguien';
    final cached = _reactorDisplayNameCache[cleanId];
    if (cached != null && cached.isNotEmpty) return cached;
    try {
      final rows = await Supabase.instance.client
          .from('users')
          .select('name, username')
          .eq('id', cleanId)
          .limit(1);
      if (rows.isEmpty) return 'Alguien';
      final row = Map<String, dynamic>.from(rows.first as Map);
      final name = (row['name'] ?? '').toString().trim();
      final username = (row['username'] ?? '').toString().trim();
      final display = name.isNotEmpty
          ? name
          : (username.isNotEmpty ? '@$username' : 'Alguien');
      _reactorDisplayNameCache[cleanId] = display;
      return display;
    } catch (_) {
      return 'Alguien';
    }
  }

  Future<void> _loadFollowingPreview() async {
    try {
      final social = context.read<SocialService>();
      final manager = context.read<VideoPlayerManager>();
      await social.ensureReady();
      final following = await social.getFollowingUsers();
      final myId = (social.myUserId ?? '').trim();
      final reactionTargetSongKeyByUserId = <String, String>{};
      for (final user in following) {
        final songKey = _songKeyForTrack(
          videoId: user.currentVideoId,
          song: user.currentSong,
          artist: user.currentArtist,
        );
        if (songKey.isEmpty) continue;
        reactionTargetSongKeyByUserId[user.id] = songKey;
      }
      final mySongKey = _songKeyForTrack(
        videoId: manager.currentVideoId,
        song: manager.trackTitle,
        artist: manager.trackArtist,
      );
      if (myId.isNotEmpty && mySongKey.isNotEmpty) {
        reactionTargetSongKeyByUserId[myId] = mySongKey;
      }
      final reactionByUserId = await social.getMusicNoteReactionSummaries(
        targetSongKeyByUserId: reactionTargetSongKeyByUserId,
      );
      if (!mounted) return;
      _attachRealtimeToFriends(following);
      _pruneFriendImageCache(following.map((u) => u.id).toSet());
      final hasListChanges = !_sameSocialUserList(_followingUsers, following);
      final nextIds = following.map((u) => u.id).toSet();
      final hasIdChanges =
          nextIds.length != _followingIds.length ||
          !nextIds.containsAll(_followingIds);
      final hasReactionChanges = !_sameReactionSummaryMap(
        _noteReactionByUserId,
        reactionByUserId,
      );
      if (!hasListChanges && !hasIdChanges && !hasReactionChanges) return;
      final previousReactionMap = _noteReactionByUserId;
      setState(() {
        _followingUsers = following;
        _followingIds = nextIds;
        _noteReactionByUserId = reactionByUserId;
      });
      _notifyIfMyReactionCountIncreased(
        previous: previousReactionMap,
        next: reactionByUserId,
      );
    } catch (_) {
      if (!mounted) return;
      _detachFriendRealtime();
      _pruneFriendImageCache(const <String>{});
      setState(() {
        _followingUsers = const <SocialUser>[];
        _followingIds = <String>{};
        _noteReactionByUserId = const <String, MusicNoteReactionSummary>{};
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
    _friendRefreshTimer = Timer.periodic(const Duration(seconds: 12), (_) {
      if (!_shouldRunLiveWork) return;
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
          unawaited(
            _invalidateFriendPreviewCacheIfSongChanged(current, updated),
          );
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
      final social = context.read<SocialService>();
      final manager = context.read<VideoPlayerManager>();
      final rows = await Supabase.instance.client
          .from('users')
          .select()
          .inFilter('id', ids.toList(growable: false));
      final myId = (social.myUserId ?? '').trim();
      final reactionTargetSongKeyByUserId = <String, String>{};
      final mySongKey = _songKeyForTrack(
        videoId: manager.currentVideoId,
        song: manager.trackTitle,
        artist: manager.trackArtist,
      );
      if (myId.isNotEmpty && mySongKey.isNotEmpty) {
        reactionTargetSongKeyByUserId[myId] = mySongKey;
      }
      for (final row in rows) {
        final user = SocialUser.fromMap(Map<String, dynamic>.from(row));
        final songKey = _songKeyForTrack(
          videoId: user.currentVideoId,
          song: user.currentSong,
          artist: user.currentArtist,
        );
        if (songKey.isEmpty) continue;
        reactionTargetSongKeyByUserId[user.id] = songKey;
      }
      final reactionByUserId = await social.getMusicNoteReactionSummaries(
        targetSongKeyByUserId: reactionTargetSongKeyByUserId,
      );
      if (!mounted) return;
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
      final hasReactionChanges = !_sameReactionSummaryMap(
        _noteReactionByUserId,
        reactionByUserId,
      );
      if (!changed && !hasReactionChanges) return;
      final previousReactionMap = _noteReactionByUserId;
      setState(() {
        _followingUsers = List<SocialUser>.unmodifiable(next);
        _noteReactionByUserId = reactionByUserId;
      });
      _notifyIfMyReactionCountIncreased(
        previous: previousReactionMap,
        next: reactionByUserId,
      );
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

  bool _sameReactionSummaryMap(
    Map<String, MusicNoteReactionSummary> a,
    Map<String, MusicNoteReactionSummary> b,
  ) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      final other = b[entry.key];
      if (other == null) return false;
      if (entry.value.topEmoji != other.topEmoji ||
          entry.value.count != other.count ||
          (entry.value.myEmoji ?? '') != (other.myEmoji ?? '')) {
        return false;
      }
    }
    return true;
  }

  void _pruneFriendImageCache(Set<String> validIds) {
    _friendPhotoUrlById.removeWhere((id, _) => !validIds.contains(id));
    _friendImageById.removeWhere((id, _) => !validIds.contains(id));
    _friendPreviewVideoIdByFriendId.removeWhere(
      (id, _) => !validIds.contains(id),
    );
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
    unawaited(_friendPreviewPositionSub?.cancel());
    _isFriendPreviewLoading.dispose();
    _isFriendPreviewLyricsLoading.dispose();
    _friendPreviewLyricSweep.dispose();
    unawaited(_friendPreviewPlayer.dispose());
    _yt.close();
    _detachFriendRealtime();
    _reactionNotificationPollTimer?.cancel();
    _reactionNotificationPollTimer = null;
    final reactionChannel = _reactionNotificationChannel;
    _reactionNotificationChannel = null;
    if (reactionChannel != null) {
      Supabase.instance.client.removeChannel(reactionChannel);
    }
    super.dispose();
  }

  Future<void> _playFriendPreviewAudio({
    required String? friendId,
    required String? videoId,
    String? title,
    String? artist,
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
    _clearFriendPreviewLyrics();
    if (mounted) {
      _setFriendPreviewLoading(true);
    }
    unawaited(
      _loadFriendPreviewLyrics(
        title: title,
        artist: artist,
        requestEpoch: requestEpoch,
      ),
    );
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
        final cachedFilePath =
            await SongStreamCacheService.resolveFreshFilePath(id);
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

      String? pickValidUrl(Iterable<String?> candidates) {
        for (final raw in candidates) {
          final trimmed = (raw ?? '').trim();
          if (trimmed.isEmpty) continue;
          final uri = Uri.tryParse(trimmed);
          if (uri == null) continue;
          if (uri.hasScheme &&
              (uri.scheme == 'http' || uri.scheme == 'https')) {
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

      final candidatePreviewUrls = <String>[];
      final manifest = await _yt.videos.streamsClient.getManifest(id);
      if (!mounted || requestEpoch != _friendPreviewRequestEpoch) return;
      AudioOnlyStreamInfo? bestAudio;
      for (final stream in manifest.audioOnly) {
        final candidateUrl = stream.url.toString();
        if (!isAllowedForPlatform(candidateUrl, isVideo: false)) continue;
        if (bestAudio == null ||
            stream.bitrate.bitsPerSecond > bestAudio.bitrate.bitsPerSecond) {
          bestAudio = stream;
        }
      }
      if (bestAudio != null) {
        candidatePreviewUrls.add(bestAudio.url.toString());
      }

      MuxedStreamInfo? bestMuxed;
      for (final stream in manifest.muxed) {
        final candidateUrl = stream.url.toString();
        if (!isAllowedForPlatform(candidateUrl, isVideo: true)) continue;
        if (bestMuxed == null ||
            stream.bitrate.bitsPerSecond > bestMuxed.bitrate.bitsPerSecond) {
          bestMuxed = stream;
        }
      }
      if (bestMuxed != null) {
        candidatePreviewUrls.add(bestMuxed.url.toString());
      }

      final sanitizedCandidates = <String>[];
      for (final raw in candidatePreviewUrls) {
        final valid = pickValidUrl(<String?>[raw])?.trim();
        if (valid == null || valid.isEmpty) continue;
        if (!sanitizedCandidates.contains(valid)) {
          sanitizedCandidates.add(valid);
        }
      }
      if (sanitizedCandidates.isEmpty) return;

      await _friendPreviewPlayer.stop();
      if (!mounted || requestEpoch != _friendPreviewRequestEpoch) return;
      String? previewUrl;
      Object? lastSetUrlError;
      for (final candidate in sanitizedCandidates) {
        try {
          await _friendPreviewPlayer.setUrl(
            candidate,
            headers: _youtubePreviewHeaders,
          );
          previewUrl = candidate;
          break;
        } catch (e) {
          lastSetUrlError = e;
        }
      }
      if ((previewUrl ?? '').isEmpty) {
        throw Exception(
          'No se pudo cargar preview con youtube_explode: $lastSetUrlError',
        );
      }
      if (!mounted || requestEpoch != _friendPreviewRequestEpoch) return;
      _startFriendPreviewPlayback(requestEpoch);
      _friendPreviewVideoIdByFriendId[ownerId] = id;
      _friendPreviewUrlByFriendId[ownerId] = previewUrl!;
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
    _clearFriendPreviewLyrics();
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
    VoidCallback? onTapAvatar,
    String? noteReactionText,
    VoidCallback? onTapNoteReaction,
    String? autoplayVideoId,
    String? autoplayFriendId,
    String? autoplayTitle,
    String? autoplayArtist,
    VoidCallback? onAddNextFromTitleMenu,
    VoidCallback? onAddToEndFromTitleMenu,
    VoidCallback? onAddToFavoritesFromTitleMenu,
    VoidCallback? onAddToPlaylistFromTitleMenu,
    VoidCallback? onOpenArtistFromTitleMenu,
    VoidCallback? onOpenAlbumFromTitleMenu,
  }) async {
    _clearFriendPreviewLyrics();
    final previewId = (autoplayVideoId ?? '').trim();
    if (previewId.isNotEmpty) {
      unawaited(
        _playFriendPreviewAudio(
          friendId: autoplayFriendId,
          videoId: previewId,
          title: autoplayTitle,
          artist: autoplayArtist,
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
                      ValueListenableBuilder<bool>(
                        valueListenable: _isFriendPreviewLyricsLoading,
                        builder: (context, lyricsLoading, child) {
                          return ValueListenableBuilder<
                            _FriendPreviewLyricSweepState?
                          >(
                            valueListenable: _friendPreviewLyricSweep,
                            builder: (context, lyricSweep, child) {
                              return GestureDetector(
                                onTap: () {},
                                child: _HomeSocialPreviewCard(
                                  titleNote: titleNote,
                                  onPlayNowFromTitleMenu: expandedPlayNowAction,
                                  onAddNextFromTitleMenu:
                                      onAddNextFromTitleMenu,
                                  onAddToEndFromTitleMenu:
                                      onAddToEndFromTitleMenu,
                                  onAddToFavoritesFromTitleMenu:
                                      onAddToFavoritesFromTitleMenu,
                                  onAddToPlaylistFromTitleMenu:
                                      onAddToPlaylistFromTitleMenu,
                                  onOpenArtistFromTitleMenu:
                                      onOpenArtistFromTitleMenu,
                                  onOpenAlbumFromTitleMenu:
                                      onOpenAlbumFromTitleMenu,
                                  noteText: noteText,
                                  noteReactionText: noteReactionText,
                                  onTapNoteReaction: onTapNoteReaction,
                                  onTapAvatar: onTapAvatar,
                                  footerText: footerText,
                                  imageProvider: imageProvider,
                                  frameImageUrl: frameImageUrl,
                                  lyricSweep: lyricSweep,
                                  lyricsLoading: lyricsLoading,
                                  scale: 1.65,
                                ),
                              );
                            },
                          );
                        },
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

  Future<void> _refreshReactionSummaries() async {
    try {
      final social = context.read<SocialService>();
      final manager = context.read<VideoPlayerManager>();
      await social.ensureReady();
      final myId = (social.myUserId ?? '').trim();
      final targetSongKeyByUserId = <String, String>{};
      for (final friend in _followingUsers) {
        final songKey = _songKeyForTrack(
          videoId: friend.currentVideoId,
          song: friend.currentSong,
          artist: friend.currentArtist,
        );
        if (songKey.isEmpty) continue;
        targetSongKeyByUserId[friend.id] = songKey;
      }
      final mySongKey = _songKeyForTrack(
        videoId: manager.currentVideoId,
        song: manager.trackTitle,
        artist: manager.trackArtist,
      );
      if (myId.isNotEmpty && mySongKey.isNotEmpty) {
        targetSongKeyByUserId[myId] = mySongKey;
      }
      if (targetSongKeyByUserId.isEmpty) return;
      final next = await social.getMusicNoteReactionSummaries(
        targetSongKeyByUserId: targetSongKeyByUserId,
      );
      if (!mounted) return;
      if (_sameReactionSummaryMap(_noteReactionByUserId, next)) return;
      final previousReactionMap = _noteReactionByUserId;
      setState(() {
        _noteReactionByUserId = next;
      });
      _notifyIfMyReactionCountIncreased(
        previous: previousReactionMap,
        next: next,
      );
    } catch (_) {
      // Mejor esfuerzo.
    }
  }

  Future<void> _reactToMusicNote(
    String targetUserId,
    String targetSongKey,
    String emoji,
  ) async {
    if (_isSendingReaction) return;
    setState(() => _isSendingReaction = true);
    try {
      final social = context.read<SocialService>();
      await social.reactToMusicNote(
        targetUserId: targetUserId,
        targetSongKey: targetSongKey,
        emoji: emoji,
      );
      unawaited(HapticFeedback.selectionClick());
      await _refreshReactionSummaries();
    } catch (_) {
      if (!mounted) return;
      showIosNotice(
        context,
        'No se pudo enviar la reacción. Verifica tu tabla music_note_reactions en Supabase.',
      );
    } finally {
      if (mounted) setState(() => _isSendingReaction = false);
    }
  }

  Future<void> _showMusicReactionPicker(
    String targetUserId,
    String targetSongKey,
  ) async {
    final target = targetUserId.trim();
    final songKey = targetSongKey.trim();
    if (target.isEmpty || songKey.isEmpty) return;
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (popupContext) => CupertinoActionSheet(
        title: const Text('Reaccionar a nota musical'),
        message: Wrap(
          spacing: 10,
          runSpacing: 10,
          alignment: WrapAlignment.center,
          children: _noteReactionEmojis
              .map(
                (emoji) => CupertinoButton(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  minimumSize: const Size(32, 32),
                  onPressed: () async {
                    Navigator.of(popupContext).pop();
                    await _reactToMusicNote(target, songKey, emoji);
                  },
                  child: Text(emoji, style: const TextStyle(fontSize: 27)),
                ),
              )
              .toList(growable: false),
        ),
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(popupContext).pop(),
          child: const Text('Cancelar'),
        ),
      ),
    );
  }

  Future<void> _showMyReactionDetails({
    required String myUserId,
    required String mySongKey,
  }) async {
    final social = context.read<SocialService>();
    List<MusicNoteReactionDetail> details = const <MusicNoteReactionDetail>[];
    try {
      details = await social.getMusicNoteReactionDetails(
        targetUserId: myUserId,
        targetSongKey: mySongKey,
      );
    } catch (_) {
      if (!mounted) return;
      showIosNotice(context, 'No se pudo cargar la lista de reacciones.');
      return;
    }
    if (!mounted) return;
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (popupContext) => CupertinoActionSheet(
        title: const Text('Reacciones a tu nota'),
        message: details.isEmpty
            ? const Text('Aún no hay reacciones para esta canción.')
            : SizedBox(
                height: 220,
                child: ListView.separated(
                  itemCount: details.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (_, index) {
                    final item = details[index];
                    final displayName = item.reactorName.trim().isEmpty
                        ? '@${item.reactorUsername}'
                        : item.reactorName.trim();
                    final username = item.reactorUsername.trim().isEmpty
                        ? ''
                        : '@${item.reactorUsername.trim()}';
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: CupertinoColors.tertiarySystemFill.resolveFrom(
                          popupContext,
                        ),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          Text(
                            item.emoji,
                            style: const TextStyle(fontSize: 22),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              username.isEmpty
                                  ? displayName
                                  : '$displayName · $username',
                              style: TextStyle(
                                fontSize: 13.5,
                                color: CupertinoColors.label.resolveFrom(
                                  popupContext,
                                ),
                                decoration: TextDecoration.none,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(popupContext).pop(),
          child: const Text('Cerrar'),
        ),
      ),
    );
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
        ? (safeTrackTitle.isNotEmpty ? safeTrackTitle : 'Reproduciendo ahora')
        : 'No estas reproduciendo nada ahora.';
    final artistText = (currentTrackArtist ?? '').trim();
    final bioText = profile.bio.trim().isEmpty
        ? 'Escribe algo...'
        : profile.bio.trim();
    final photoPath = (profile.photoPath ?? '').trim();
    final photoUrl = (profile.photoUrl ?? '').trim();
    final frameUrl = (profile.frameUrl ?? '').trim();
    final hasLocalPhoto = photoPath.isNotEmpty && File(photoPath).existsSync();
    final hasRemotePhoto = photoUrl.isNotEmpty;
    final ImageProvider? myImageProvider = hasLocalPhoto
        ? FileImage(File(photoPath))
        : (hasRemotePhoto ? NetworkImage(photoUrl) : null);
    final myId = (context.read<SocialService>().myUserId ?? '').trim();
    final mySongKey = _songKeyForTrack(
      videoId: currentVideoId,
      song: currentTrackTitle,
      artist: currentTrackArtist,
    );
    final myReactionSummary = (myId.isEmpty || mySongKey.isEmpty)
        ? null
        : _noteReactionByUserId[_reactionMapKey(
            userId: myId,
            songKey: mySongKey,
          )];
    final myReactionText = myReactionSummary == null
        ? null
        : '${myReactionSummary.topEmoji} ${myReactionSummary.count}';

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
                            context
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
                        thumbnailUrl:
                            context
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
                        thumbnailUrl:
                            context
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
                        thumbnailUrl:
                            context
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
                        thumbnailUrl:
                            context
                                .read<VideoPlayerManager>()
                                .trackThumbnailUrl ??
                            '',
                      )
                    : null,
                noteText: bioText,
                noteReactionText: myReactionText,
                onTapNoteReaction: (myId.isEmpty || mySongKey.isEmpty)
                    ? null
                    : () => _showMyReactionDetails(
                        myUserId: myId,
                        mySongKey: mySongKey,
                      ),
                footerText: 'Tu',
                imageProvider: myImageProvider,
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
                          thumbnailUrl:
                              context
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
                          thumbnailUrl:
                              context
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
                          thumbnailUrl:
                              context
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
                          thumbnailUrl:
                              context
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
                          thumbnailUrl:
                              context
                                  .read<VideoPlayerManager>()
                                  .trackThumbnailUrl ??
                              '',
                        )
                      : null,
                  noteText: bioText,
                  noteReactionText: myReactionText,
                  onTapNoteReaction: (myId.isEmpty || mySongKey.isEmpty)
                      ? null
                      : () => _showMyReactionDetails(
                          myUserId: myId,
                          mySongKey: mySongKey,
                        ),
                  footerText: 'Tu',
                  imageProvider: myImageProvider,
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
                final friendSongKey = _songKeyForTrack(
                  videoId: friend.currentVideoId,
                  song: friend.currentSong,
                  artist: friend.currentArtist,
                );
                final friendReactionSummary = friendSongKey.isEmpty
                    ? null
                    : _noteReactionByUserId[_reactionMapKey(
                        userId: friend.id,
                        songKey: friendSongKey,
                      )];
                final friendReactionText = friendReactionSummary == null
                    ? null
                    : '${friendReactionSummary.topEmoji} ${friendReactionSummary.count}';
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
                    noteReactionText: friendReactionText,
                    onTapNoteReaction: friendSongKey.isEmpty
                        ? null
                        : () => _showMusicReactionPicker(
                            friend.id,
                            friendSongKey,
                          ),
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
                              playlistName:
                                  PlaylistService.favoritesPlaylistName,
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
                      noteReactionText: friendReactionText,
                      onTapNoteReaction: friendSongKey.isEmpty
                          ? null
                          : () => _showMusicReactionPicker(
                              friend.id,
                              friendSongKey,
                            ),
                      footerText: friend.name.trim().isEmpty
                          ? '@${friend.username}'
                          : friend.name.trim(),
                      imageProvider: _friendImageProvider(friend),
                      frameImageUrl: friendFrameUrl,
                      autoplayVideoId: friend.currentVideoId,
                      autoplayFriendId: friend.id,
                      autoplayTitle: friendTitleText,
                      autoplayArtist: friendArtist,
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
  final _FriendPreviewLyricSweepState? lyricSweep;
  final bool lyricsLoading;
  final String? noteReactionText;
  final VoidCallback? onTapNoteReaction;
  final VoidCallback? onTapAvatar;
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
    this.lyricSweep,
    this.lyricsLoading = false,
    this.noteReactionText,
    this.onTapNoteReaction,
    this.onTapAvatar,
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final lyricBubbleBackground = isDark
        ? CupertinoColors.secondarySystemGroupedBackground.resolveFrom(context)
        : CupertinoColors.systemBackground
              .resolveFrom(context)
              .withValues(alpha: 0.9);
    final currentLyricLine = (lyricSweep?.text ?? '').trim();
    final lyricBubbleText = currentLyricLine.isNotEmpty
        ? currentLyricLine
        : (lyricsLoading ? 'Cargando Lyrics...' : '');
    final reactionBubbleScale = scale > 1.0 ? 0.78 : 1.0;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 130 * scale,
            height: _titleAreaHeight * scale,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Padding(
                  padding: EdgeInsets.only(top: scale > 1.0 ? 18 * scale : 0),
                  child: onPlayNowFromTitleMenu == null
                      ? Align(
                          alignment: Alignment.topCenter,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              GestureDetector(
                                behavior: HitTestBehavior.translucent,
                                onTap: onTap,
                                child: titleNote,
                              ),
                              if (onTapNoteReaction != null)
                                Positioned(
                                  right: -8 * scale,
                                  bottom: -10 * scale,
                                  child: SizedBox(
                                    width: 34 * scale * reactionBubbleScale,
                                    height: 28 * scale * reactionBubbleScale,
                                    child: CupertinoButton(
                                      padding: EdgeInsets.zero,
                                      minimumSize: Size.zero,
                                      onPressed: onTapNoteReaction,
                                      child: Container(
                                        padding: EdgeInsets.symmetric(
                                          horizontal:
                                              6 * scale * reactionBubbleScale,
                                          vertical:
                                              2.5 * scale * reactionBubbleScale,
                                        ),
                                        decoration: BoxDecoration(
                                          color: CupertinoColors
                                              .systemBackground
                                              .resolveFrom(context),
                                          borderRadius: BorderRadius.circular(
                                            999,
                                          ),
                                          border: Border.all(
                                            color: CupertinoColors.separator
                                                .resolveFrom(context)
                                                .withValues(alpha: 0.32),
                                            width: 0.6,
                                          ),
                                        ),
                                        child:
                                            (noteReactionText ?? '')
                                                .trim()
                                                .isNotEmpty
                                            ? Text(
                                                noteReactionText!.trim(),
                                                style: TextStyle(
                                                  fontSize:
                                                      10 *
                                                      scale *
                                                      reactionBubbleScale,
                                                  fontWeight: FontWeight.w600,
                                                  color: CupertinoColors.label
                                                      .resolveFrom(context),
                                                  decoration:
                                                      TextDecoration.none,
                                                ),
                                              )
                                            : Icon(
                                                CupertinoIcons.smiley,
                                                size:
                                                    12 *
                                                    scale *
                                                    reactionBubbleScale,
                                                color: CupertinoColors.label
                                                    .resolveFrom(context),
                                              ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        )
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
                                textColor: CupertinoColors.label.resolveFrom(
                                  context,
                                ),
                                iconColor: CupertinoColors.systemGrey
                                    .resolveFrom(context),
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
                                  iconColor: CupertinoColors.systemGrey
                                      .resolveFrom(context),
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
                                  iconColor: CupertinoColors.systemGrey
                                      .resolveFrom(context),
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
                                  iconColor: CupertinoColors.systemGrey
                                      .resolveFrom(context),
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
                                  iconColor: CupertinoColors.systemGrey
                                      .resolveFrom(context),
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
                                  iconColor: CupertinoColors.systemGrey
                                      .resolveFrom(context),
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
                                  iconColor: CupertinoColors.systemGrey
                                      .resolveFrom(context),
                                ),
                              ),
                          ],
                          child: Align(
                            alignment: Alignment.topCenter,
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                GestureDetector(
                                  behavior: HitTestBehavior.translucent,
                                  onTap: onTap,
                                  child: titleNote,
                                ),
                                if (onTapNoteReaction != null)
                                  Positioned(
                                    right: -8 * scale,
                                    bottom: -10 * scale,
                                    child: SizedBox(
                                      width: 34 * scale * reactionBubbleScale,
                                      height: 28 * scale * reactionBubbleScale,
                                      child: CupertinoButton(
                                        padding: EdgeInsets.zero,
                                        minimumSize: Size.zero,
                                        onPressed: onTapNoteReaction,
                                        child: Container(
                                          padding: EdgeInsets.symmetric(
                                            horizontal:
                                                6 * scale * reactionBubbleScale,
                                            vertical:
                                                2.5 *
                                                scale *
                                                reactionBubbleScale,
                                          ),
                                          decoration: BoxDecoration(
                                            color: CupertinoColors
                                                .systemBackground
                                                .resolveFrom(context),
                                            borderRadius: BorderRadius.circular(
                                              999,
                                            ),
                                            border: Border.all(
                                              color: CupertinoColors.separator
                                                  .resolveFrom(context)
                                                  .withValues(alpha: 0.32),
                                              width: 0.6,
                                            ),
                                          ),
                                          child:
                                              (noteReactionText ?? '')
                                                  .trim()
                                                  .isNotEmpty
                                              ? Text(
                                                  noteReactionText!.trim(),
                                                  style: TextStyle(
                                                    fontSize:
                                                        10 *
                                                        scale *
                                                        reactionBubbleScale,
                                                    fontWeight: FontWeight.w600,
                                                    color: CupertinoColors.label
                                                        .resolveFrom(context),
                                                    decoration:
                                                        TextDecoration.none,
                                                  ),
                                                )
                                              : Icon(
                                                  CupertinoIcons.smiley,
                                                  size:
                                                      12 *
                                                      scale *
                                                      reactionBubbleScale,
                                                  color: CupertinoColors.label
                                                      .resolveFrom(context),
                                                ),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                ),
                if (lyricBubbleText.isNotEmpty)
                  Positioned(
                    top: -24 * scale,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        constraints: BoxConstraints(maxWidth: 120 * scale),
                        padding: EdgeInsets.symmetric(
                          horizontal: 8 * scale,
                          vertical: 3 * scale,
                        ),
                        decoration: BoxDecoration(
                          color: lyricBubbleBackground,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: CupertinoColors.separator
                                .resolveFrom(context)
                                .withValues(alpha: 0.28),
                            width: 0.6,
                          ),
                        ),
                        child: SizedBox(
                          width: 104 * scale,
                          child: _HomeLyricSweepText(
                            text: lyricBubbleText,
                            progress: currentLyricLine.isNotEmpty
                                ? (lyricSweep?.progress ?? 0)
                                : 0,
                            style: TextStyle(
                              fontFamily: '.SF Pro Text',
                              fontSize: 9.5 * scale,
                              fontWeight: FontWeight.w600,
                              color: CupertinoColors.label.resolveFrom(context),
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
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
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: onTapAvatar,
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
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(9 * scale),
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 1.5 * scale),
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
  State<_HomeFloatingFrameDrift> createState() =>
      _HomeFloatingFrameDriftState();
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
    _yAnimation = Tween<double>(
      begin: -2.0,
      end: 2.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
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
  static const double _edgeSafetyPadding = 4.0;
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
        if (!constraints.hasBoundedWidth) {
          return Text(
            widget.text,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: widget.style,
          );
        }
        final maxWidth = constraints.maxWidth;
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          maxLines: 1,
          textDirection: Directionality.of(context),
        )..layout(minWidth: 0, maxWidth: double.infinity);

        final textWidth = painter.width + _edgeSafetyPadding;
        final textHeight = painter.height;
        _overflow = (textWidth - maxWidth).clamp(0.0, double.infinity);
        if (_overflow <= 1) {
          _cycleEpoch++;
          _cycleRunning = false;
          _scrollController?.stop();
          _fadeController?.stop();
          _scrollController?.value = 0;
          _fadeController?.value = 1;
          return SizedBox(
            width: maxWidth,
            child: Text(
              widget.text,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: widget.style,
            ),
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
        return SizedBox(
          width: maxWidth,
          child: ClipRect(
            child: AnimatedBuilder(
              animation: Listenable.merge([
                _scrollController!,
                _fadeController!,
              ]),
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
                              child: Padding(
                                padding: const EdgeInsets.only(
                                  right: _edgeSafetyPadding,
                                ),
                                child: Text(
                                  widget.text,
                                  maxLines: 1,
                                  softWrap: false,
                                  style: widget.style,
                                  textAlign: TextAlign.left,
                                ),
                              ),
                            ),
                            const SizedBox(width: gap),
                            SizedBox(
                              width: textWidth,
                              child: Padding(
                                padding: const EdgeInsets.only(
                                  right: _edgeSafetyPadding,
                                ),
                                child: Text(
                                  widget.text,
                                  maxLines: 1,
                                  softWrap: false,
                                  style: widget.style,
                                  textAlign: TextAlign.left,
                                ),
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

class _FriendPreviewLyricSweepState {
  final String text;
  final double progress;

  const _FriendPreviewLyricSweepState({
    required this.text,
    required this.progress,
  });
}

class _HomeLyricSweepText extends StatelessWidget {
  final String text;
  final double progress;
  final TextStyle style;

  const _HomeLyricSweepText({
    required this.text,
    required this.progress,
    required this.style,
  });

  @override
  Widget build(BuildContext context) {
    final targetProgress = progress.clamp(0.0, 1.0);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final activeColor = isDark ? CupertinoColors.white : CupertinoColors.black;
    final inactiveColor = isDark
        ? CupertinoColors.white.withValues(alpha: 0.42)
        : CupertinoColors.black.withValues(alpha: 0.38);
    return LayoutBuilder(
      builder: (context, constraints) {
        final words = text.trim().split(RegExp(r'\s+'));
        if (words.isEmpty || (words.length == 1 && words.first.isEmpty)) {
          return Text(
            text,
            maxLines: 3,
            softWrap: true,
            overflow: TextOverflow.visible,
            textAlign: TextAlign.center,
            style: style.copyWith(color: activeColor),
          );
        }
        final lines = <String>[];
        var current = '';
        final maxWidth = constraints.maxWidth;
        for (final word in words) {
          final candidate = current.isEmpty ? word : '$current $word';
          final probe = TextPainter(
            text: TextSpan(text: candidate, style: style),
            maxLines: 1,
            textDirection: TextDirection.ltr,
          )..layout(maxWidth: double.infinity);
          if (probe.width <= maxWidth || current.isEmpty) {
            current = candidate;
            continue;
          }
          lines.add(current);
          current = word;
          if (lines.length == 2) break;
        }
        if (lines.length < 3 && current.isNotEmpty) {
          lines.add(current);
        }
        if (lines.isEmpty) {
          lines.add(text.trim());
        }

        return TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: targetProgress),
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOutCubic,
          builder: (context, animatedProgress, _) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: List<Widget>.generate(lines.length, (index) {
                final normalized = animatedProgress * lines.length;
                final lineProgress = (normalized - index).clamp(0.0, 1.0);
                final lineText = lines[index];
                return Stack(
                  children: [
                    Text(
                      lineText,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.visible,
                      textAlign: TextAlign.center,
                      style: style.copyWith(color: inactiveColor),
                    ),
                    ClipRect(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        widthFactor: lineProgress,
                        child: Text(
                          lineText,
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.visible,
                          textAlign: TextAlign.center,
                          style: style.copyWith(color: activeColor),
                        ),
                      ),
                    ),
                  ],
                );
              }),
            );
          },
        );
      },
    );
  }
}

class _HomeReverseMarqueeTextState extends State<_HomeReverseMarqueeText>
    with SingleTickerProviderStateMixin {
  static const double _edgeSafetyPadding = 7.0;
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
    final nextOverflow = math
        .max(0.0, (painter.width + _edgeSafetyPadding) - maxWidth)
        .toDouble();
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
                child: Padding(
                  padding: const EdgeInsets.only(right: _edgeSafetyPadding),
                  child: Text(
                    widget.text,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.visible,
                    style: widget.style,
                  ),
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

class _HomeResolvedChannelPlaylistRef {
  final String playlistId;
  final String title;
  final String subtitle;
  final String thumbnailUrl;

  const _HomeResolvedChannelPlaylistRef({
    required this.playlistId,
    required this.title,
    required this.subtitle,
    required this.thumbnailUrl,
  });
}

class _SectionHeaderSliver extends StatelessWidget {
  final String title;
  final String subtitle;

  const _SectionHeaderSliver({required this.title, this.subtitle = ''});

  @override
  Widget build(BuildContext context) {
    final hasSubtitle = subtitle.trim().isNotEmpty;
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
            if (hasSubtitle) ...[
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

class _HomeVideoFeatureCard extends StatelessWidget {
  final _HomeTrack item;
  final VoidCallback onTap;

  const _HomeVideoFeatureCard({required this.item, required this.onTap});

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
      width: 252,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Material(
          color: cardColor,
          surfaceTintColor: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            child: Container(
              decoration: BoxDecoration(
                color: cardColor,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: cardBorder, width: 0.6),
              ),
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child:
                          item.thumbnailUrl.isNotEmpty &&
                              item.thumbnailUrl.startsWith('/')
                          ? Image.file(
                              File(item.thumbnailUrl),
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => Container(
                                color: CupertinoColors.tertiarySystemFill
                                    .resolveFrom(context),
                                alignment: Alignment.center,
                                child: const Icon(
                                  CupertinoIcons.videocam_fill,
                                  size: 28,
                                ),
                              ),
                            )
                          : Image.network(
                              item.thumbnailUrl,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => Container(
                                color: CupertinoColors.tertiarySystemFill
                                    .resolveFrom(context),
                                alignment: Alignment.center,
                                child: const Icon(
                                  CupertinoIcons.videocam_fill,
                                  size: 28,
                                ),
                              ),
                            ),
                    ),
                  ),
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
                  const SizedBox(height: 3),
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

class _HeroTopPickCard extends StatelessWidget {
  final _HomeTrack item;
  final VoidCallback onTap;
  final Future<void> Function(_TrackContextAction action)? onContextAction;

  const _HeroTopPickCard({
    required this.item,
    required this.onTap,
    this.onContextAction,
  });

  @override
  Widget build(BuildContext context) {
    final isYtMusicMxCard = item.videoId.startsWith('ytmx:');
    final supportingText = item.artist.trim();
    final hasTopLabel = !isYtMusicMxCard && supportingText.isNotEmpty;
    final hasBottomLabel = supportingText.isNotEmpty;
    final card = SizedBox(
      width: 232,
      height: 268,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            child: Stack(
              fit: StackFit.expand,
              children: [
                SquareThumbnail.network(
                  imageUrl: item.thumbnailUrl,
                  size: 232,
                  borderRadius: 16,
                  fallback: Container(
                    color: CupertinoColors.tertiarySystemFill.resolveFrom(
                      context,
                    ),
                    alignment: Alignment.center,
                    child: const Icon(CupertinoIcons.music_note, size: 34),
                  ),
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color(0x14000000),
                        Color(0x22000000),
                        Color(0xA6000000),
                      ],
                      stops: [0.0, 0.58, 1.0],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (hasTopLabel)
                        Text(
                          item.artist.toUpperCase(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: '.SF Pro Text',
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.2,
                            color: Color(0xFFF2F2F7),
                          ),
                        ),
                      const Spacer(),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              item.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: '.SF Pro Display',
                                fontSize: 22,
                                height: 1.04,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.55,
                                color: CupertinoColors.white,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          FavoritesStarBadge(videoId: item.videoId, size: 16),
                        ],
                      ),
                      if (hasBottomLabel) const SizedBox(height: 4),
                      if (hasBottomLabel)
                        Text(
                          supportingText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: '.SF Pro Text',
                            fontSize: 13,
                            color: Color(0xFFE5E5EA),
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

    final contextAction = onContextAction;
    if (contextAction == null) return card;
    return _TrackContextMenu(onAction: contextAction, child: card);
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

    final card = LayoutBuilder(
      builder: (context, constraints) => ClipRRect(
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
                  if (constraints.hasBoundedWidth)
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
                    )
                  else
                    SizedBox(
                      width: 220,
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
                  const SizedBox(width: 8),
                  const SizedBox(
                    width: 14,
                    child: Center(child: SizedBox.shrink()),
                  ),
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 14,
                    child: Center(
                      child: FavoritesStarBadge(videoId: item.videoId),
                    ),
                  ),
                ],
              ),
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
