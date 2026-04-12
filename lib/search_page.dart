import 'dart:developer' as developer;
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:myapp/models/video_history.dart';
import 'package:myapp/search_view_state.dart';
import 'package:myapp/services/download_service.dart';
import 'package:myapp/services/history_service.dart';
import 'package:myapp/services/playlist_service.dart';
import 'package:myapp/utils/thumbnail_quality.dart';
import 'package:myapp/video_player_manager.dart';
import 'package:myapp/widgets/playlist_picker_sheet.dart';
import 'package:myapp/widgets/square_thumbnail.dart';
import 'package:provider/provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

enum SearchState { initial, loading, success, error, noResults }

String _bestQualityThumbnail(Video video) {
  return bestThumbnailForVideo(video);
}

class SearchChannelWithSubscribers {
  final SearchChannel channel;
  final int? subscribersCount;
  final String? thumbnailUrlOverride;

  const SearchChannelWithSubscribers({
    required this.channel,
    required this.subscribersCount,
    this.thumbnailUrlOverride,
  });

  SearchChannelWithSubscribers copyWith({
    SearchChannel? channel,
    int? subscribersCount,
    String? thumbnailUrlOverride,
  }) {
    return SearchChannelWithSubscribers(
      channel: channel ?? this.channel,
      subscribersCount: subscribersCount ?? this.subscribersCount,
      thumbnailUrlOverride: thumbnailUrlOverride ?? this.thumbnailUrlOverride,
    );
  }
}

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage>
    with SingleTickerProviderStateMixin {
  static const int _minimumSubscribers = 100000;
  static const int _maxChannelsToShow = 2;
  final TextEditingController _textController = TextEditingController();
  final YoutubeExplode _youtubeExplode = YoutubeExplode();
  List<Video> _videos = [];
  List<SearchChannelWithSubscribers> _channels = [];
  SearchState _searchState = SearchState.initial;
  final Map<String, List<Video>> _searchCache = {};
  final Map<String, Object> _channelSearchCache = {};
  final Map<String, Future<List<Video>>> _searchInFlight = {};
  final Map<String, Future<Object>> _channelSearchInFlight = {};
  final Map<String, int?> _subscriberCountCache = {};
  final Map<String, String?> _channelLogoCache = {};
  final FocusNode _searchFocusNode = FocusNode();
  int _searchEpoch = 0;
  bool _showArtists = true;
  _SelectedArtistView? _selectedArtistView;
  int _artistTransitionDirection = 1;
  List<Video> _initialRecommendations = const [];
  bool _initialRecommendationsLoading = false;
  String? _initialRecommendationQuery;
  SearchViewState? _searchViewState;
  AnimationController? _searchBarGlowController;

  @override
  void initState() {
    super.initState();
    _ensureSearchBarGlowController();
    _searchFocusNode.addListener(() {
      final glow = _ensureSearchBarGlowController();
      if (_searchFocusNode.hasFocus) {
        glow.repeat();
      } else {
        glow.stop();
      }
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_loadInitialRecommendations());
    });
  }

  AnimationController _ensureSearchBarGlowController() {
    final existing = _searchBarGlowController;
    if (existing != null) return existing;
    final created = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    );
    _searchBarGlowController = created;
    return created;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextState = context.read<SearchViewState>();
    if (identical(_searchViewState, nextState)) return;
    _searchViewState?.removeListener(_handleSearchViewStateChanged);
    _searchViewState = nextState;
    _searchViewState?.addListener(_handleSearchViewStateChanged);
  }

  void _handleSearchViewStateChanged() {
    if (!mounted) return;
    final pending = _searchViewState?.consumePendingArtistProfile();
    if (pending == null) return;
    setState(() {
      _artistTransitionDirection = 1;
      _selectedArtistView = _SelectedArtistView(
        channelId: pending.channelId,
        channelName: pending.channelName,
        channelThumbnailUrl: pending.channelThumbnailUrl,
      );
    });
    _searchViewState?.setArtistFullscreen(true);
  }

  @override
  void reassemble() {
    super.reassemble();
    _channelSearchCache.clear();
    _channelSearchInFlight.clear();
    _channels = [];
  }

  Future<void> _searchVideos() async {
    if (_textController.text.trim().isEmpty) return;
    FocusScope.of(context).unfocus();
    final query = _textController.text.trim();
    final epoch = ++_searchEpoch;
    final cached = _searchCache[query];
    final cachedChannels = await _getCachedChannels(query);
    if (cached != null && cachedChannels != null) {
      setState(() {
        _videos = cached;
        _channels = cachedChannels;
        _searchState = cached.isEmpty && cachedChannels.isEmpty
            ? SearchState.noResults
            : SearchState.success;
      });
      return;
    }

    setState(() {
      _searchState = SearchState.loading;
      _videos = [];
      _channels = [];
    });

    try {
      final videosFuture = _searchWithCache(query);
      final channelsFuture = _searchChannelsWithCache(query);

      // Mostramos el canal del artista tan pronto como esté listo.
      unawaited(() async {
        try {
          final channelResult = await channelsFuture;
          if (!mounted || epoch != _searchEpoch) return;
          setState(() {
            _channels = channelResult;
            _searchState = _videos.isEmpty && channelResult.isEmpty
                ? SearchState.noResults
                : SearchState.success;
          });
        } catch (_) {
          // Ignoramos: la búsqueda de videos puede seguir funcionando.
        }
      }());

      final searchResult = await videosFuture;
      if (!mounted || epoch != _searchEpoch) return;
      setState(() {
        _videos = searchResult.toList();
        _channels = _channels.isNotEmpty
            ? _channels
            : (cachedChannels ?? const []);
        _searchState = _videos.isEmpty && _channels.isEmpty
            ? SearchState.noResults
            : SearchState.success;
      });

      // Si canales aún no termina, esperamos su resultado final.
      final channelResult = await channelsFuture;
      if (!mounted || epoch != _searchEpoch) return;
      setState(() {
        _channels = channelResult;
        _searchState = _videos.isEmpty && channelResult.isEmpty
            ? SearchState.noResults
            : SearchState.success;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _searchState = SearchState.error);
      }
    }
  }

  Future<void> _loadInitialRecommendations() async {
    if (!mounted) return;
    setState(() {
      _initialRecommendationsLoading = true;
    });

    final query = await _pickInitialRecommendationQuery();
    try {
      final videos = await _searchWithCache(query);
      if (!mounted) return;
      setState(() {
        _initialRecommendationQuery = query;
        _initialRecommendations = _prioritizedVideos(videos).take(12).toList();
        _initialRecommendationsLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _initialRecommendationQuery = query;
        _initialRecommendations = const [];
        _initialRecommendationsLoading = false;
      });
    }
  }

  Future<String> _pickInitialRecommendationQuery() async {
    try {
      final history = await context.read<HistoryService>().getHistory();
      final byArtist = history
          .map((h) => h.channelTitle.trim())
          .where((artist) => artist.isNotEmpty)
          .toSet()
          .toList();
      if (byArtist.isNotEmpty) {
        final artist = byArtist[math.Random().nextInt(byArtist.length)];
        return artist;
      }

      final byTitle = history
          .map((h) => h.title.trim())
          .where((title) => title.isNotEmpty)
          .toList();
      if (byTitle.isNotEmpty) {
        return byTitle[math.Random().nextInt(byTitle.length)];
      }
    } catch (_) {
      // Si falla historial, usamos fallback.
    }

    const fallbackQueries = ['Regional mexicano', 'musica en ingles', 'rels b'];
    return fallbackQueries[math.Random().nextInt(fallbackQueries.length)];
  }

  Future<void> _openChannel(SearchChannelWithSubscribers channelData) async {
    final channel = channelData.channel;
    setState(() {
      _artistTransitionDirection = 1;
      _selectedArtistView = _SelectedArtistView(
        channelId: channel.id.value,
        channelName: channel.name,
        channelThumbnailUrl: _thumbnailOf(channelData) ?? '',
      );
    });
    _searchViewState?.setArtistFullscreen(true);
  }

  void _closeArtistChannel() {
    setState(() {
      _artistTransitionDirection = -1;
      _selectedArtistView = null;
    });
    _searchViewState?.setArtistFullscreen(false);
  }

  Future<void> _openVideoPlayer(
    String videoId, {
    String? thumbnailUrl,
    String? title,
    String? artist,
  }) async {
    try {
      final manager = Provider.of<VideoPlayerManager>(context, listen: false);
      manager.registerSearchThumbnail(videoId, thumbnailUrl);
      await manager.play(
        videoId,
        preferredThumbnailUrl: thumbnailUrl,
        preferredTitle: title,
        preferredArtist: artist,
      );
    } catch (e, s) {
      developer.log('Error al abrir reproductor', error: e, stackTrace: s);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo iniciar la reproducción.')),
      );
    }
  }

  Future<void> _playVideoPreferLocal(Video video) async {
    final downloadService = context.read<DownloadService>();
    final videoManager = context.read<VideoPlayerManager>();
    final local = await downloadService.getDownloadedVideoById(video.id.value);

    if (!mounted) return;
    if (local != null) {
      final thumb =
          (local.localThumbnailPath != null &&
              local.localThumbnailPath!.isNotEmpty)
          ? local.localThumbnailPath!
          : local.thumbnailUrl;
      await videoManager.playLocalFile(
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

    await _openVideoPlayer(
      video.id.value,
      thumbnailUrl: _bestQualityThumbnail(video),
      title: video.title,
      artist: video.author,
    );
  }

  void _queueVideo(Video video) {
    final manager = context.read<VideoPlayerManager>();
    final added = manager.addOnlineTrackToPlaybackQueue(
      videoId: video.id.value,
      title: video.title,
      thumbnailUrl: _bestQualityThumbnail(video),
      artist: video.author,
    );
    if (!mounted) return;
    _showIosTopToast(
      context,
      message: added
          ? 'Se ha añadido a la cola'
          : 'Esta canción ya está en cola',
      icon: added
          ? CupertinoIcons.check_mark_circled_solid
          : CupertinoIcons.info_circle_fill,
    );
  }

  Future<void> _openArtistFromVideo(Video video) async {
    try {
      final details = await _runYoutubeWithRetry(
        () => _youtubeExplode.channels.getByVideo(video.id.value),
        maxAttempts: 1,
      );
      if (!mounted) return;
      setState(() {
        _artistTransitionDirection = 1;
        _selectedArtistView = _SelectedArtistView(
          channelId: details.id.value,
          channelName: details.title,
          channelThumbnailUrl: details.logoUrl,
        );
      });
      _searchViewState?.setArtistFullscreen(true);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No se pudo abrir el perfil del artista.'),
        ),
      );
    }
  }

  Future<void> _showVideoOptionsMenu(Video video) async {
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
              child: BackdropFilter(
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
                                video.title,
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
                              icon: CupertinoIcons.person_crop_circle,
                              label: 'Ir al artista',
                              onTap: () =>
                                  Navigator.of(sheetContext).pop('artist'),
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
    if (action == 'favorites') {
      await _addVideoToPlaylist(video, PlaylistService.favoritesPlaylistName);
      return;
    }
    if (action == 'playlist') {
      await _showPlaylistPicker(video);
      return;
    }
    if (action == 'artist') {
      await _openArtistFromVideo(video);
    }
  }

  Future<void> _showPlaylistPicker(Video video) async {
    final playlistService = context.read<PlaylistService>();
    final playlists = await playlistService.getPlaylists();
    if (!mounted || playlists.isEmpty) return;

    final selectedName = await showGlassPlaylistPickerSheet(
      context: context,
      playlists: playlists,
      subtitle: video.title,
    );
    if (!mounted || selectedName == null || selectedName.isEmpty) return;
    await _addVideoToPlaylist(video, selectedName);
  }

  Future<void> _addVideoToPlaylist(Video video, String playlistName) async {
    final playlistService = context.read<PlaylistService>();
    final downloadService = context.read<DownloadService>();
    final videoManager = context.read<VideoPlayerManager>();
    final track = VideoHistory(
      videoId: video.id.value,
      title: video.title,
      thumbnailUrl: _bestQualityThumbnail(video),
      channelTitle: video.author,
      watchedAt: DateTime.now(),
    );
    await playlistService.addVideoToPlaylist(playlistName, track);
    await downloadService.autoDownloadIfEnabledUsingClone(
      playlistName,
      track,
      videoManager: videoManager,
    );
    if (!mounted) return;
    final label = PlaylistService.isFavoritesPlaylistName(playlistName)
        ? 'Añadida a Favoritos'
        : 'Añadida a $playlistName';
    _showIosTopToast(
      context,
      message: label,
      icon: PlaylistService.isFavoritesPlaylistName(playlistName)
          ? CupertinoIcons.star_fill
          : CupertinoIcons.check_mark_circled_solid,
    );
  }

  Future<List<Video>> _searchWithCache(String query) async {
    final cached = _searchCache[query];
    if (cached != null) return cached;
    final inFlight = _searchInFlight[query];
    if (inFlight != null) return inFlight;

    final future = _runYoutubeWithRetry(
      () => _searchAutoGeneratedTopicVideos(query),
    );
    _searchInFlight[query] = future;
    try {
      final result = await future;
      _searchCache[query] = result;
      return result;
    } finally {
      _searchInFlight.remove(query);
    }
  }

  Future<List<Video>> _searchAutoGeneratedTopicVideos(String query) async {
    final queries = _buildAudioFocusedQueries(query);
    final videosById = <String, Video>{};
    final scoresById = <String, int>{};
    final phase1Count = queries.length >= 2 ? 2 : queries.length;
    final phase1 = List.generate(
      phase1Count,
      (index) => _collectSearchBatch(
        searchQuery: queries[index],
        queryIndex: index,
        originalQuery: query,
        videosById: videosById,
        scoresById: scoresById,
      ),
    );
    await Future.wait(phase1);

    // Si ya hay suficientes candidatos, devolvemos rápido.
    if (scoresById.length < 18 && queries.length > phase1Count) {
      final phase2 = List.generate(queries.length - phase1Count, (offset) {
        final index = phase1Count + offset;
        return _collectSearchBatch(
          searchQuery: queries[index],
          queryIndex: index,
          originalQuery: query,
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
    return ids.map((id) => videosById[id]!).toList();
  }

  Future<void> _collectSearchBatch({
    required String searchQuery,
    required int queryIndex,
    required String originalQuery,
    required Map<String, Video> videosById,
    required Map<String, int> scoresById,
  }) async {
    try {
      final raw = await _runYoutubeWithRetry(
        () => _youtubeExplode.search.search(searchQuery),
        maxAttempts: 1,
      );
      for (final video in raw.take(40)) {
        if (!_isPureYoutubeMusicAudioSearchResult(video)) continue;
        final id = video.id.value;
        final score = _searchRelevanceScore(
          video: video,
          originalQuery: originalQuery,
          queryIndex: queryIndex,
        );
        final previous = scoresById[id];
        if (previous == null || score > previous) {
          scoresById[id] = score;
          videosById[id] = video;
        }
      }
    } catch (_) {
      // Ignoramos esta subconsulta y seguimos.
    }
  }

  List<String> _buildAudioFocusedQueries(String query) {
    final normalized = query.replaceAll(RegExp(r'\s+'), ' ').trim();
    final compact = normalized
        .replaceAll(RegExp(r'\s*[\(\[\{].*?[\)\]\}]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final set = <String>{
      normalized,
      '$compact topic',
      '$compact official audio',
      '$compact provided to youtube by',
      '$compact auto-generated by youtube',
    };

    // Si es "artista - cancion", reforzamos por artista.
    final dashParts = compact.split(RegExp(r'\s*-\s*'));
    if (dashParts.length >= 2) {
      final artist = dashParts.first.trim();
      if (artist.isNotEmpty) {
        set.add('$artist topic');
        set.add('$artist provided to youtube by');
      }
    }

    return set.where((q) => q.isNotEmpty).take(8).toList();
  }

  int _searchRelevanceScore({
    required Video video,
    required String originalQuery,
    required int queryIndex,
  }) {
    final title = video.title.toLowerCase();
    final author = video.author.toLowerCase();
    final description = video.description.toLowerCase();
    final text = '$title $author $description';
    final normalizedQuery = originalQuery.toLowerCase().trim();
    final tokens = normalizedQuery
        .split(RegExp(r'\s+'))
        .where((token) => token.length >= 3)
        .take(8)
        .toList();

    var score = 0;
    if (_isTopicVideo(video)) score += 120;
    if (_isAutoGeneratedVideo(video)) score += 100;
    if (text.contains(normalizedQuery)) score += 120;
    for (final token in tokens) {
      if (text.contains(token)) score += 22;
    }
    if (queryIndex == 0) score += 35;
    score -= queryIndex * 6;
    final views = video.engagement.viewCount;
    if (views > 0) {
      score += (views / 300000).floor().clamp(0, 50);
    }
    return score;
  }

  Future<List<SearchChannelWithSubscribers>> _searchChannelsWithCache(
    String query,
  ) async {
    final cached = await _getCachedChannels(query);
    if (cached != null) return cached;
    final inFlight = _channelSearchInFlight[query];
    if (inFlight != null) {
      final result = await inFlight;
      return _normalizeChannelResults(result);
    }

    final future = _runYoutubeWithRetry<Object>(() async {
      final list = await _youtubeExplode.search.searchContent(
        query,
        filter: TypeFilters.channel,
      );
      final channels = list.whereType<SearchChannel>().take(8).toList();
      if (channels.isEmpty) return const <SearchChannelWithSubscribers>[];

      // Ruta rápida: evita llamadas extras para que el artista aparezca antes.
      final resolvedByChannelSearch = await _resolveChannelsWithSubscribers(
        channels,
      );
      final filtered = _filterChannelsBySubscribers(resolvedByChannelSearch);
      if (filtered.isNotEmpty) {
        return _hydrateTopicChannelPhotos(
          filtered,
          resolvedByChannelSearch,
          forcedTopicThumbnail: _topThumbnailFromResolved(
            resolvedByChannelSearch,
          ),
        );
      }

      // Fallback solo si no hubo suficientes candidatos por canal.
      final videos = await _searchWithCache(query);
      final resolvedByVideoSearch = await _resolveChannelsFromTopVideos(
        videos.take(2).toList(),
      );
      final merged = _mergeChannelCandidates(
        resolvedByChannelSearch,
        resolvedByVideoSearch,
      );
      final mergedFiltered = _filterChannelsBySubscribers(merged);
      return _hydrateTopicChannelPhotos(
        mergedFiltered,
        merged,
        forcedTopicThumbnail: _topThumbnailFromResolved(merged),
      );
    });
    _channelSearchInFlight[query] = future;
    try {
      final result = await future;
      final normalized = await _normalizeChannelResults(result);
      _channelSearchCache[query] = normalized;
      return normalized;
    } finally {
      _channelSearchInFlight.remove(query);
    }
  }

  Future<List<SearchChannelWithSubscribers>?> _getCachedChannels(
    String query,
  ) async {
    final cached = _channelSearchCache[query];
    if (cached == null) return null;
    final normalized = await _normalizeChannelResults(cached);
    _channelSearchCache[query] = normalized;
    return normalized;
  }

  Future<List<SearchChannelWithSubscribers>> _normalizeChannelResults(
    Object rawResult,
  ) async {
    if (rawResult is List<SearchChannelWithSubscribers>) {
      return _hydrateTopicChannelPhotos(
        _filterChannelsBySubscribers(rawResult),
        rawResult,
        forcedTopicThumbnail: _topThumbnailFromResolved(rawResult),
      );
    }
    if (rawResult is List<SearchChannel>) {
      final resolved = await _resolveChannelsWithSubscribers(rawResult);
      return _hydrateTopicChannelPhotos(
        _filterChannelsBySubscribers(resolved),
        resolved,
        forcedTopicThumbnail: _topThumbnailFromResolved(resolved),
      );
    }
    return const [];
  }

  Future<List<SearchChannelWithSubscribers>> _resolveChannelsWithSubscribers(
    List<SearchChannel> channels,
  ) async {
    final toResolve = channels.take(_maxChannelsToShow).toList();
    return Future.wait(toResolve.map(_resolveChannelSubscribers));
  }

  Future<List<SearchChannelWithSubscribers>> _resolveChannelsFromTopVideos(
    List<Video> videos,
  ) async {
    final resolved = <SearchChannelWithSubscribers>[];
    final seenIds = <String>{};
    final sourceVideos = videos.take(4).toList();

    for (var i = 0; i < sourceVideos.length; i++) {
      final video = sourceVideos[i];
      try {
        final details = await _runYoutubeWithRetry(
          () => _youtubeExplode.channels.getByVideo(video.id.value),
          maxAttempts: 1,
        );
        final channelId = details.id.value;
        if (seenIds.contains(channelId)) continue;
        seenIds.add(channelId);
        _subscriberCountCache[channelId] = details.subscribersCount;
        resolved.add(
          SearchChannelWithSubscribers(
            channel: SearchChannel(details.id, details.title, '', 0, [
              Thumbnail(Uri.parse(details.logoUrl), 0, 0),
            ]),
            subscribersCount: details.subscribersCount,
          ),
        );
      } catch (e, s) {
        developer.log(
          'No se pudo resolver canal desde video ${video.title}',
          error: e,
          stackTrace: s,
        );
      }
    }

    return resolved;
  }

  List<SearchChannelWithSubscribers> _mergeChannelCandidates(
    List<SearchChannelWithSubscribers> a,
    List<SearchChannelWithSubscribers> b,
  ) {
    final merged = <String, SearchChannelWithSubscribers>{};
    for (final item in [...a, ...b]) {
      final id = item.channel.id.value;
      final existing = merged[id];
      if (existing == null) {
        merged[id] = item;
      } else if ((item.subscribersCount ?? 0) >
          (existing.subscribersCount ?? 0)) {
        merged[id] = item;
      }
    }
    return merged.values.toList();
  }

  List<SearchChannelWithSubscribers> _filterChannelsBySubscribers(
    List<SearchChannelWithSubscribers> channels,
  ) {
    if (channels.isEmpty) return const [];
    final verified = channels
        .where((item) => (item.subscribersCount ?? 0) > _minimumSubscribers)
        .toList();

    if (verified.isNotEmpty) {
      return _prioritizeTopicFirst(verified).take(_maxChannelsToShow).toList();
    }

    final knownSubscribers = channels
        .where((item) => item.subscribersCount != null)
        .toList();
    if (knownSubscribers.isNotEmpty) {
      return _prioritizeTopicFirst(
        knownSubscribers,
      ).take(_maxChannelsToShow).toList();
    }

    // Fallback final: si YouTube no devuelve conteo de suscriptores.
    final fallback = channels
        .where((item) => item.subscribersCount == null)
        .toList();
    return _prioritizeTopicFirst(fallback).take(_maxChannelsToShow).toList();
  }

  List<SearchChannelWithSubscribers> _prioritizeTopicFirst(
    List<SearchChannelWithSubscribers> channels,
  ) {
    final prioritized = channels.toList();
    prioritized.sort((a, b) {
      final aTopic = _isTopicChannel(a.channel);
      final bTopic = _isTopicChannel(b.channel);
      if (aTopic == bTopic) return 0;
      return aTopic ? -1 : 1;
    });
    return prioritized;
  }

  bool _isTopicChannel(SearchChannel channel) {
    final name = channel.name.toLowerCase().trim();
    return RegExp(r'(\s*[-–—]\s*topic|\s+topic)\s*$').hasMatch(name);
  }

  Future<List<SearchChannelWithSubscribers>> _hydrateTopicChannelPhotos(
    List<SearchChannelWithSubscribers> selected,
    List<SearchChannelWithSubscribers> pool, {
    String? forcedTopicThumbnail,
  }) async {
    if (selected.isEmpty) return selected;
    final globalFallback =
        forcedTopicThumbnail ?? _bestArtistThumbnailFromPool(pool);
    final hydrated = <SearchChannelWithSubscribers>[];

    for (final item in selected) {
      if (!_isTopicChannel(item.channel)) {
        hydrated.add(item);
        continue;
      }

      final chosen = globalFallback ?? _thumbnailOf(item);
      hydrated.add(item.copyWith(thumbnailUrlOverride: chosen));
    }

    return hydrated;
  }

  String? _topThumbnailFromResolved(
    List<SearchChannelWithSubscribers> channels,
  ) {
    if (channels.isEmpty) return null;
    final sorted = channels.toList()
      ..sort(
        (a, b) => (b.subscribersCount ?? 0).compareTo(a.subscribersCount ?? 0),
      );
    for (final item in sorted) {
      final thumb = _thumbnailOf(item);
      if (thumb != null && thumb.isNotEmpty) return thumb;
    }
    return null;
  }

  String? _bestArtistThumbnailFromPool(
    List<SearchChannelWithSubscribers> pool,
  ) {
    final candidates =
        pool.where((item) => !_isTopicChannel(item.channel)).toList()..sort(
          (a, b) =>
              (b.subscribersCount ?? 0).compareTo(a.subscribersCount ?? 0),
        );
    for (final item in candidates) {
      final thumb = _thumbnailOf(item);
      if (thumb != null && thumb.isNotEmpty) return thumb;
    }
    return null;
  }

  String? _thumbnailOf(SearchChannelWithSubscribers item) {
    if (item.thumbnailUrlOverride != null &&
        item.thumbnailUrlOverride!.isNotEmpty) {
      return item.thumbnailUrlOverride;
    }
    if (item.channel.thumbnails.isEmpty) return null;
    final url = item.channel.thumbnails.first.url.toString();
    if (url.isEmpty) return null;
    return url;
  }

  Future<SearchChannelWithSubscribers> _resolveChannelSubscribers(
    SearchChannel channel,
  ) async {
    final channelId = channel.id.value;
    final cachedSubscribers = _subscriberCountCache[channelId];
    final cachedLogo = _channelLogoCache[channelId];
    if (_subscriberCountCache.containsKey(channelId) ||
        _channelLogoCache.containsKey(channelId)) {
      return SearchChannelWithSubscribers(
        channel: channel,
        subscribersCount: cachedSubscribers,
        thumbnailUrlOverride: cachedLogo,
      );
    }

    int? subscribersCount;
    String? logoUrl;
    try {
      final details = await _runYoutubeWithRetry(
        () => _youtubeExplode.channels.get(channelId),
        maxAttempts: 1,
      );
      subscribersCount = details.subscribersCount;
      logoUrl = details.logoUrl;
    } catch (e, s) {
      developer.log(
        'No se pudieron cargar los suscriptores del canal ${channel.name}',
        error: e,
        stackTrace: s,
      );
    }

    _subscriberCountCache[channelId] = subscribersCount;
    _channelLogoCache[channelId] = logoUrl;
    return SearchChannelWithSubscribers(
      channel: channel,
      subscribersCount: subscribersCount,
      thumbnailUrlOverride: logoUrl,
    );
  }

  String _formatSubscribers(int? subscribersCount) {
    if (subscribersCount == null) return 'Suscriptores no disponibles';
    if (subscribersCount >= 1000000) {
      final value = subscribersCount / 1000000;
      return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} M suscriptores';
    }
    if (subscribersCount >= 1000) {
      final value = subscribersCount / 1000;
      return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} k suscriptores';
    }
    return '$subscribersCount suscriptores';
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
    throw lastError ?? Exception('Error de red al consultar YouTube');
  }

  @override
  Widget build(BuildContext context) {
    final selectedArtist = _selectedArtistView;
    if (context.read<SearchViewState>().isArtistFullscreen &&
        selectedArtist == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        context.read<SearchViewState>().setArtistFullscreen(false);
      });
    }

    return PopScope(
      canPop: selectedArtist == null,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && selectedArtist != null) {
          _closeArtistChannel();
        }
      },
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 320),
        reverseDuration: const Duration(milliseconds: 280),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) {
          final beginX = _artistTransitionDirection > 0 ? 0.14 : -0.14;
          final slide =
              Tween<Offset>(begin: Offset(beginX, 0), end: Offset.zero).animate(
                CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
              );
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(position: slide, child: child),
          );
        },
        child: selectedArtist == null
            ? KeyedSubtree(
                key: const ValueKey('search_home'),
                child: Scaffold(
                  backgroundColor:
                      Theme.of(context).brightness == Brightness.dark
                      ? Colors.black
                      : CupertinoColors.systemGroupedBackground.resolveFrom(
                          context,
                        ),
                  body: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0),
                    child: Column(
                      children: [
                        const SizedBox(height: 16),
                        _buildSearchBar(),
                        const SizedBox(height: 10),
                        _buildSearchFilters(),
                        const SizedBox(height: 24),
                        Expanded(child: _buildBody()),
                      ],
                    ),
                  ),
                ),
              )
            : KeyedSubtree(
                key: ValueKey('artist_${selectedArtist.channelId}'),
                child: ChannelVideosPage(
                  channelId: selectedArtist.channelId,
                  channelName: selectedArtist.channelName,
                  channelThumbnailUrl: selectedArtist.channelThumbnailUrl,
                  embedded: true,
                  onBack: _closeArtistChannel,
                ),
              ),
      ),
    );
  }

  @override
  void dispose() {
    _searchViewState?.removeListener(_handleSearchViewStateChanged);
    _searchFocusNode.dispose();
    _searchBarGlowController?.dispose();
    _youtubeExplode.close();
    _textController.dispose();
    super.dispose();
  }

  Widget _buildSearchFilters() {
    return Row(
      children: [
        SearchModeButton(
          label: 'Canciones',
          icon: CupertinoIcons.music_note_2,
          isActive: true,
          onPressed: () {},
        ),
        const SizedBox(width: 10),
        SearchModeButton(
          label: 'Artistas',
          icon: CupertinoIcons.person_2,
          isActive: _showArtists,
          onPressed: () {
            setState(() {
              _showArtists = !_showArtists;
            });
          },
        ),
      ],
    );
  }

  Widget _buildSearchBar() {
    final borderRadius = BorderRadius.circular(18);
    final focused = _searchFocusNode.hasFocus;
    final glow = _ensureSearchBarGlowController();

    return AnimatedBuilder(
      animation: glow,
      builder: (context, _) {
        final rotation = glow.value * math.pi * 2;
        return Container(
          height: 42,
          padding: const EdgeInsets.all(1.25),
          decoration: BoxDecoration(
            borderRadius: borderRadius,
            gradient: SweepGradient(
              transform: GradientRotation(rotation),
              colors: [
                const Color(0xFFFF004D),
                const Color(0xFFFF7A00),
                const Color(0xFF7A5CFF),
                const Color(0xFFFF004D),
              ],
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(
                  0xFF581A95,
                ).withValues(alpha: focused ? 0.34 : 0.14),
                blurRadius: focused ? 20 : 10,
                spreadRadius: focused ? 0.9 : 0,
                offset: const Offset(0, 2),
              ),
              BoxShadow(
                color: const Color(
                  0xFFFF2A6D,
                ).withValues(alpha: focused ? 0.24 : 0.08),
                blurRadius: focused ? 26 : 12,
                spreadRadius: focused ? 1.2 : 0,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: borderRadius,
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF0A0D14).withValues(alpha: 0.83),
                  borderRadius: borderRadius,
                ),
                child: TextField(
                  focusNode: _searchFocusNode,
                  controller: _textController,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _searchVideos(),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Buscar en YouTube...',
                    hintStyle: TextStyle(
                      color: Colors.white.withValues(alpha: 0.58),
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                    prefixIcon: Align(
                      widthFactor: 1,
                      heightFactor: 1,
                      child: Icon(
                        CupertinoIcons.search,
                        size: 17,
                        color: focused
                            ? const Color(0xFFFF7A9C)
                            : Colors.white.withValues(alpha: 0.75),
                      ),
                    ),
                    prefixIconConstraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 42,
                    ),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      vertical: 12,
                      horizontal: 4,
                    ),
                    border: InputBorder.none,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBody() {
    switch (_searchState) {
      case SearchState.loading:
        return const Center(child: CircularProgressIndicator());
      case SearchState.error:
        return const Center(
          child: Text('Error al buscar. Inténtalo de nuevo.'),
        );
      case SearchState.noResults:
        return const Center(child: Text('No se encontraron videos.'));
      case SearchState.initial:
        final downloadService = context.watch<DownloadService>();
        if (_initialRecommendationsLoading && _initialRecommendations.isEmpty) {
          return const Center(child: CupertinoActivityIndicator(radius: 14));
        }
        if (_initialRecommendations.isEmpty) {
          return Center(
            child: Text(
              'Comienza haciendo',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          );
        }
        return ListView(
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _initialRecommendationQuery == null
                    ? 'Recomendado para ti'
                    : 'Recomendado para ti • $_initialRecommendationQuery',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            ..._initialRecommendations.map(
              (video) => VideoCard(
                video: video,
                isDownloaded:
                    downloadService.getDownloadStatus(video.id.value) ==
                    DownloadStatus.downloaded,
                onPlay: () => _playVideoPreferLocal(video),
                onQueue: () => _queueVideo(video),
                onMenuTap: () => _showVideoOptionsMenu(video),
              ),
            ),
          ],
        );
      case SearchState.success:
        final downloadService = context.watch<DownloadService>();
        final prioritizedVideos = _prioritizedVideos(_videos);
        final displayChannels = _orderedChannelsForDisplay(
          channels: _channels,
          videos: prioritizedVideos,
        );
        final primaryVideo = prioritizedVideos.isNotEmpty
            ? prioritizedVideos.first
            : null;
        final primaryArtistChannelThumb = primaryVideo == null
            ? null
            : _findChannelThumbnailForArtist(
                artistName: primaryVideo.author,
                channels: displayChannels,
              );
        return ListView(
          children: [
            if (_showArtists &&
                (primaryVideo != null || displayChannels.isNotEmpty)) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Artista principal',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (primaryVideo != null)
                _TopArtistFromVideoCard(
                  video: primaryVideo,
                  channelThumbnailUrl: primaryArtistChannelThumb,
                  onOpen: () => _openArtistFromVideo(primaryVideo),
                )
              else
                TopArtistCard(
                  channel: displayChannels.first,
                  subscriberLabel: _formatSubscribers(
                    displayChannels.first.subscribersCount,
                  ),
                  onOpenChannel: () => _openChannel(displayChannels.first),
                ),
              if (displayChannels.length > 1) ...[
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    'Canales relacionados',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                ...displayChannels
                    .skip(1)
                    .take(4)
                    .map(
                      (channel) => ChannelCard(
                        channel: channel,
                        subscriberLabel: _formatSubscribers(
                          channel.subscribersCount,
                        ),
                        onTap: () => _openChannel(channel),
                      ),
                    ),
              ],
              const SizedBox(height: 14),
            ],
            if (prioritizedVideos.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Canciones y videos populares',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
            ...prioritizedVideos
                .take(20)
                .map(
                  (video) => VideoCard(
                    video: video,
                    isDownloaded:
                        downloadService.getDownloadStatus(video.id.value) ==
                        DownloadStatus.downloaded,
                    onPlay: () => _playVideoPreferLocal(video),
                    onQueue: () => _queueVideo(video),
                    onMenuTap: () => _showVideoOptionsMenu(video),
                  ),
                ),
          ],
        );
    }
  }

  List<SearchChannelWithSubscribers> _orderedChannelsForDisplay({
    required List<SearchChannelWithSubscribers> channels,
    required List<Video> videos,
  }) {
    if (channels.length <= 1 || videos.isEmpty) return channels;
    final primaryArtist = _normalizeArtistNameForMatch(videos.first.author);
    if (primaryArtist.isEmpty) return channels;

    final ranked =
        <({SearchChannelWithSubscribers item, int index, int score})>[];
    for (var i = 0; i < channels.length; i++) {
      final item = channels[i];
      final channelName = _normalizeArtistNameForMatch(item.channel.name);
      var score = 0;
      if (channelName == primaryArtist) score += 120;
      if (channelName.contains(primaryArtist)) score += 60;
      if (primaryArtist.contains(channelName)) score += 40;
      ranked.add((item: item, index: i, score: score));
    }

    ranked.sort((a, b) {
      if (a.score != b.score) return b.score.compareTo(a.score);
      return a.index.compareTo(b.index);
    });
    return ranked.map((e) => e.item).toList();
  }

  String _normalizeArtistNameForMatch(String input) {
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

  String? _findChannelThumbnailForArtist({
    required String artistName,
    required List<SearchChannelWithSubscribers> channels,
  }) {
    if (channels.isEmpty) return null;
    final normalizedArtist = _normalizeArtistNameForMatch(artistName);
    if (normalizedArtist.isEmpty) return null;

    SearchChannelWithSubscribers? best;
    var bestScore = -1;
    for (final channel in channels) {
      final normalizedChannel = _normalizeArtistNameForMatch(
        channel.channel.name,
      );
      if (normalizedChannel.isEmpty) continue;
      var score = 0;
      if (normalizedChannel == normalizedArtist) score += 120;
      if (normalizedChannel.contains(normalizedArtist)) score += 60;
      if (normalizedArtist.contains(normalizedChannel)) score += 40;
      if (score > bestScore) {
        bestScore = score;
        best = channel;
      }
    }
    if (best == null || bestScore <= 0) return null;
    if (best.thumbnailUrlOverride != null &&
        best.thumbnailUrlOverride!.isNotEmpty) {
      return best.thumbnailUrlOverride!;
    }
    if (best.channel.thumbnails.isNotEmpty) {
      return best.channel.thumbnails.first.url.toString();
    }
    return null;
  }

  List<Video> _prioritizedVideos(List<Video> source) {
    final dedup = <String, Video>{};
    for (final video in source) {
      dedup.putIfAbsent(video.id.value, () => video);
    }
    final ordered = dedup.values.toList()
      ..sort(
        (a, b) => b.engagement.viewCount.compareTo(a.engagement.viewCount),
      );
    return ordered;
  }

  bool _isTopicVideo(Video video) {
    final author = video.author.toLowerCase().trim();
    return author.endsWith('- topic') || author.endsWith('topic');
  }

  bool _isPureYoutubeMusicAudioSearchResult(Video video) {
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
}

class _SelectedArtistView {
  final String channelId;
  final String channelName;
  final String channelThumbnailUrl;

  const _SelectedArtistView({
    required this.channelId,
    required this.channelName,
    required this.channelThumbnailUrl,
  });
}

class ChannelCard extends StatelessWidget {
  final SearchChannelWithSubscribers channel;
  final String subscriberLabel;
  final VoidCallback onTap;

  const ChannelCard({
    super.key,
    required this.channel,
    required this.subscriberLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final thumb = _thumbnailUrl(channel);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.0),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Material(
            color: Colors.white.withValues(alpha: 0.035),
            child: InkWell(
              onTap: onTap,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.14),
                    width: 0.6,
                  ),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.white.withValues(alpha: 0.075),
                      Colors.white.withValues(alpha: 0.02),
                    ],
                  ),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12.0,
                  vertical: 7.0,
                ),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: Transform.scale(
                        scale: 1.05,
                        child: Image.network(
                          thumb,
                          width: 52,
                          height: 52,
                          fit: BoxFit.cover,
                          alignment: Alignment.center,
                          errorBuilder: (context, error, stackTrace) =>
                              const SizedBox(
                                width: 52,
                                height: 52,
                                child: Icon(
                                  Icons.account_circle_outlined,
                                  size: 26,
                                  color: Colors.grey,
                                ),
                              ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            channel.channel.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: CupertinoTheme.of(context)
                                .textTheme
                                .textStyle
                                .copyWith(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: CupertinoColors.label.resolveFrom(
                                    context,
                                  ),
                                ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '$subscriberLabel • ${channel.channel.videoCount} videos',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: CupertinoTheme.of(context)
                                .textTheme
                                .textStyle
                                .copyWith(
                                  fontSize: 13,
                                  color: CupertinoColors.secondaryLabel
                                      .resolveFrom(context),
                                ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      Icons.chevron_right_rounded,
                      color: CupertinoColors.tertiaryLabel.resolveFrom(context),
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

  String _thumbnailUrl(SearchChannelWithSubscribers channelData) {
    if (channelData.thumbnailUrlOverride != null &&
        channelData.thumbnailUrlOverride!.isNotEmpty) {
      return channelData.thumbnailUrlOverride!;
    }
    if (channelData.channel.thumbnails.isNotEmpty) {
      return channelData.channel.thumbnails.first.url.toString();
    }
    return '';
  }
}

class SearchModeButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool isActive;
  final VoidCallback onPressed;

  const SearchModeButton({
    super.key,
    required this.label,
    required this.icon,
    required this.isActive,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(14);
    return CupertinoButton(
      padding: EdgeInsets.zero,
      minimumSize: Size.zero,
      onPressed: onPressed,
      child: Container(
        padding: const EdgeInsets.all(1.25),
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFFF004D), Color(0xFFFF7A00), Color(0xFF7A5CFF)],
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(
                0xFFFF4D00,
              ).withValues(alpha: isActive ? 0.3 : 0.16),
              blurRadius: isActive ? 16 : 10,
              spreadRadius: isActive ? 0.6 : 0.0,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: borderRadius,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Container(
              height: 30,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: (isActive
                    ? Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.2)
                    : CupertinoColors.systemGrey6
                          .resolveFrom(context)
                          .withValues(alpha: 0.52)),
                borderRadius: borderRadius,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 14,
                    color: isActive
                        ? Theme.of(context).colorScheme.primary
                        : CupertinoColors.label.resolveFrom(context),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: CupertinoTheme.of(context).textTheme.textStyle
                        .copyWith(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: isActive
                              ? Theme.of(context).colorScheme.primary
                              : null,
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

class TopArtistCard extends StatelessWidget {
  final SearchChannelWithSubscribers channel;
  final String subscriberLabel;
  final VoidCallback onOpenChannel;

  const TopArtistCard({
    super.key,
    required this.channel,
    required this.subscriberLabel,
    required this.onOpenChannel,
  });

  @override
  Widget build(BuildContext context) {
    final thumb = _thumbnailUrl(channel);
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Material(
          color: Colors.white.withValues(alpha: 0.04),
          child: InkWell(
            onTap: onOpenChannel,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.16),
                  width: 0.8,
                ),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withValues(alpha: 0.10),
                    Colors.white.withValues(alpha: 0.03),
                  ],
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: Transform.scale(
                          scale: 1.05,
                          child: Image.network(
                            thumb,
                            width: 72,
                            height: 72,
                            fit: BoxFit.cover,
                            alignment: Alignment.center,
                            errorBuilder: (context, error, stackTrace) =>
                                const SizedBox(
                                  width: 72,
                                  height: 72,
                                  child: Icon(
                                    Icons.account_circle_outlined,
                                    size: 38,
                                    color: Colors.grey,
                                  ),
                                ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              channel.channel.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: CupertinoTheme.of(context)
                                  .textTheme
                                  .textStyle
                                  .copyWith(
                                    fontSize: 26,
                                    fontWeight: FontWeight.w700,
                                    color: CupertinoColors.label.resolveFrom(
                                      context,
                                    ),
                                  ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              subscriberLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: CupertinoTheme.of(context)
                                  .textTheme
                                  .textStyle
                                  .copyWith(
                                    fontSize: 14,
                                    color: CupertinoColors.secondaryLabel
                                        .resolveFrom(context),
                                  ),
                            ),
                            Text(
                              '${channel.channel.videoCount} videos',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: CupertinoTheme.of(context)
                                  .textTheme
                                  .textStyle
                                  .copyWith(
                                    fontSize: 13,
                                    color: CupertinoColors.secondaryLabel
                                        .resolveFrom(context),
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _ArtistVideosActionButton(onPressed: onOpenChannel),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _thumbnailUrl(SearchChannelWithSubscribers channelData) {
    if (channelData.thumbnailUrlOverride != null &&
        channelData.thumbnailUrlOverride!.isNotEmpty) {
      return channelData.thumbnailUrlOverride!;
    }
    if (channelData.channel.thumbnails.isNotEmpty) {
      return channelData.channel.thumbnails.first.url.toString();
    }
    return '';
  }
}

class _TopArtistFromVideoCard extends StatelessWidget {
  final Video video;
  final String? channelThumbnailUrl;
  final VoidCallback onOpen;

  const _TopArtistFromVideoCard({
    required this.video,
    this.channelThumbnailUrl,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final thumb =
        (channelThumbnailUrl != null && channelThumbnailUrl!.isNotEmpty)
        ? channelThumbnailUrl!
        : bestThumbnailForVideo(video);
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Material(
          color: Colors.white.withValues(alpha: 0.04),
          child: InkWell(
            onTap: onOpen,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.16),
                  width: 0.8,
                ),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withValues(alpha: 0.10),
                    Colors.white.withValues(alpha: 0.03),
                  ],
                ),
              ),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: Transform.scale(
                      scale: 1.05,
                      child: Image.network(
                        thumb,
                        width: 72,
                        height: 72,
                        fit: BoxFit.cover,
                        alignment: Alignment.center,
                        errorBuilder: (context, error, stackTrace) =>
                            const SizedBox(
                              width: 72,
                              height: 72,
                              child: Icon(
                                Icons.account_circle_outlined,
                                size: 38,
                                color: Colors.grey,
                              ),
                            ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          video.author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: CupertinoTheme.of(context).textTheme.textStyle
                              .copyWith(
                                fontSize: 24,
                                fontWeight: FontWeight.w700,
                                color: CupertinoColors.label.resolveFrom(
                                  context,
                                ),
                              ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Del primer resultado',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: CupertinoTheme.of(context).textTheme.textStyle
                              .copyWith(
                                fontSize: 13,
                                color: CupertinoColors.secondaryLabel
                                    .resolveFrom(context),
                              ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: CupertinoColors.tertiaryLabel.resolveFrom(context),
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

class _ArtistVideosActionButton extends StatefulWidget {
  final VoidCallback onPressed;

  const _ArtistVideosActionButton({required this.onPressed});

  @override
  State<_ArtistVideosActionButton> createState() =>
      _ArtistVideosActionButtonState();
}

class _ArtistVideosActionButtonState extends State<_ArtistVideosActionButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _borderController;

  @override
  void initState() {
    super.initState();
    _borderController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    )..repeat();
  }

  @override
  void dispose() {
    _borderController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(14);
    return AnimatedBuilder(
      animation: _borderController,
      builder: (context, _) {
        return CupertinoButton(
          padding: EdgeInsets.zero,
          minimumSize: Size.zero,
          onPressed: widget.onPressed,
          child: Container(
            padding: const EdgeInsets.all(1.2),
            decoration: BoxDecoration(
              borderRadius: borderRadius,
              gradient: SweepGradient(
                transform: GradientRotation(
                  _borderController.value * math.pi * 2,
                ),
                colors: [
                  const Color(0xFFE79A52).withValues(alpha: 0.82),
                  const Color(0xFFEDB567).withValues(alpha: 0.82),
                  const Color(0xFFF1CB86).withValues(alpha: 0.82),
                  const Color(0xFFE9A15A).withValues(alpha: 0.82),
                  const Color(0xFFE79A52).withValues(alpha: 0.82),
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFDA9A57).withValues(alpha: 0.14),
                  blurRadius: 10,
                  spreadRadius: 0,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: borderRadius,
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                child: Container(
                  height: 36,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        const Color(0xFFEABF81).withValues(alpha: 0.50),
                        const Color(0xFFE5AE6D).withValues(alpha: 0.56),
                        const Color(0xFFDF995A).withValues(alpha: 0.54),
                      ],
                    ),
                    borderRadius: borderRadius,
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.14),
                      width: 0.45,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFFDDA15F).withValues(alpha: 0.10),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Icon(
                        Icons.music_note_rounded,
                        size: 16,
                        color: Colors.white,
                      ),
                      SizedBox(width: 7),
                      Text(
                        'Ver videos musicales',
                        style: TextStyle(
                          fontFamily: '.SF Pro Text',
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
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
  }
}

class VideoCard extends StatelessWidget {
  final Video video;
  final VoidCallback onPlay;
  final VoidCallback? onQueue;
  final VoidCallback onMenuTap;
  final bool isDownloaded;
  final bool highlightTop;

  const VideoCard({
    super.key,
    required this.video,
    required this.onPlay,
    this.onQueue,
    required this.onMenuTap,
    this.isDownloaded = false,
    this.highlightTop = false,
  });

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(14);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark
        ? Colors.black
        : CupertinoColors.secondarySystemGroupedBackground.resolveFrom(context);
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : CupertinoColors.separator
              .resolveFrom(context)
              .withValues(alpha: 0.14);
    final card = ClipRRect(
      borderRadius: borderRadius,
      child: Material(
        color: cardColor,
        child: InkWell(
          onTap: onPlay,
          child: Container(
            decoration: BoxDecoration(
              color: cardColor,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: borderColor, width: 0.6),
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: 12.0,
              vertical: 6.0,
            ),
            child: Row(
              children: [
                SquareThumbnail.network(
                  imageUrl: _bestQualityThumbnail(video),
                  size: 64,
                  borderRadius: 10,
                  zoom: 1,
                  fallback: Container(
                    width: 64,
                    height: 64,
                    color: CupertinoColors.tertiarySystemFill.resolveFrom(
                      context,
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.videocam_off_outlined,
                      size: 24,
                      color: CupertinoColors.secondaryLabel.resolveFrom(
                        context,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        video.title,
                        style: CupertinoTheme.of(context).textTheme.textStyle
                            .copyWith(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: CupertinoColors.label.resolveFrom(context),
                              letterSpacing: -0.1,
                            ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        video.author,
                        style: CupertinoTheme.of(context).textTheme.textStyle
                            .copyWith(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: CupertinoColors.secondaryLabel.resolveFrom(
                                context,
                              ),
                            ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (isDownloaded) ...[
                  Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      color: CupertinoColors.tertiarySystemFill.resolveFrom(
                        context,
                      ),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: CupertinoColors.separator
                            .resolveFrom(context)
                            .withValues(alpha: 0.32),
                        width: 0.5,
                      ),
                    ),
                    child: const Icon(
                      CupertinoIcons.arrow_down_circle_fill,
                      size: 14,
                      color: CupertinoColors.systemGreen,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(32, 32),
                  onPressed: onMenuTap,
                  child: Icon(
                    CupertinoIcons.ellipsis_circle,
                    size: 24,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final swipeCard = onQueue == null
        ? card
        : Dismissible(
            key: ObjectKey(video),
            direction: DismissDirection.startToEnd,
            dismissThresholds: const {DismissDirection.startToEnd: 0.28},
            confirmDismiss: (_) async {
              onQueue?.call();
              return false;
            },
            background: Container(
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              decoration: BoxDecoration(
                borderRadius: borderRadius,
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
            ),
            child: card,
          );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.0),
      child: highlightTop
          ? Container(
              padding: const EdgeInsets.all(1),
              decoration: BoxDecoration(
                borderRadius: borderRadius,
                color: CupertinoColors.systemPink
                    .resolveFrom(context)
                    .withValues(alpha: 0.34),
                boxShadow: [
                  BoxShadow(
                    color: CupertinoColors.systemPink
                        .resolveFrom(context)
                        .withValues(alpha: 0.16),
                    blurRadius: 10,
                    spreadRadius: 0,
                  ),
                ],
              ),
              child: swipeCard,
            )
          : swipeCard,
    );
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
      child: BackdropFilter(
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

void _showIosTopToast(
  BuildContext context, {
  required String message,
  required IconData icon,
}) {
  final overlay = Overlay.of(context, rootOverlay: true);

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
              child: _IosTopToast(message: message, icon: icon),
            ),
          ),
        ),
      );
    },
  );
  overlay.insert(entry);
  Timer(const Duration(milliseconds: 1900), () {
    entry.remove();
  });
}

class _IosTopToast extends StatefulWidget {
  final String message;
  final IconData icon;

  const _IosTopToast({required this.message, required this.icon});

  @override
  State<_IosTopToast> createState() => _IosTopToastState();
}

class _IosTopToastState extends State<_IosTopToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      reverseDuration: const Duration(milliseconds: 240),
    );
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    _slide = Tween<Offset>(
      begin: const Offset(0, -0.06),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _controller.forward();
    Timer(const Duration(milliseconds: 1400), () {
      if (mounted) {
        _controller.reverse();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: _slide,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 330),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: Theme.of(context).brightness == Brightness.dark
                    ? Colors.black.withValues(alpha: 0.72)
                    : Colors.white.withValues(alpha: 0.86),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Colors.white.withValues(alpha: 0.14)
                      : Colors.black.withValues(alpha: 0.08),
                  width: 0.6,
                ),
              ),
              child: Text(
                widget.message,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: '.SF Pro Text',
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Colors.white
                      : Colors.black,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ChannelVideosPage extends StatefulWidget {
  final String channelId;
  final String channelName;
  final String channelThumbnailUrl;
  final bool embedded;
  final VoidCallback? onBack;

  const ChannelVideosPage({
    super.key,
    required this.channelId,
    required this.channelName,
    required this.channelThumbnailUrl,
    this.embedded = false,
    this.onBack,
  });

  @override
  State<ChannelVideosPage> createState() => _ChannelVideosPageState();
}

class _ChannelVideosPageState extends State<ChannelVideosPage>
    with SingleTickerProviderStateMixin {
  final YoutubeExplode _yt = YoutubeExplode();
  static const Duration _channelFetchTimeout = Duration(seconds: 6);
  List<Video> _videos = [];
  bool _loading = true;
  bool _error = false;
  late final AnimationController _bgMotionController;
  Color _bgColorA = const Color(0xFF3A2A44);
  Color _bgColorB = const Color(0xFF1B2E4A);
  Color _bgColorC = const Color(0xFF1F3D33);

  @override
  void initState() {
    super.initState();
    _bgMotionController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 26),
    )..repeat(reverse: true);
    _loadChannelVideos();
    _seedBackgroundPalette();
  }

  Future<void> _loadChannelVideos() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final allUploads = await _fetchChannelVideosWithFallback();
      final selected = _prioritizePopularVideos(allUploads);
      if (!mounted) return;
      setState(() {
        _videos = selected;
        _loading = false;
      });
      unawaited(_seedBackgroundPalette());
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = true;
        _loading = false;
      });
    }
  }

  Future<List<Video>> _fetchChannelVideosWithFallback() async {
    // Ejecutamos ambas fuentes en paralelo para obtener resultados más rápido.
    final fromPageFuture = _fetchUploadsFromPageFast();
    final fromPlaylistFuture = _fetchUploadsPlaylistFast();

    final first = await Future.any<(String, List<Video>)>([
      fromPageFuture.then((videos) => ('page', videos)),
      fromPlaylistFuture.then((videos) => ('playlist', videos)),
    ]);

    if (first.$2.isNotEmpty) return first.$2;

    final second = first.$1 == 'page'
        ? await fromPlaylistFuture
        : await fromPageFuture;
    if (second.isNotEmpty) return second;

    // 3) Fallback por busqueda del nombre del canal/topic
    final searchFallback = await _searchMusicByChannelName();
    return searchFallback;
  }

  Future<List<Video>> _fetchUploadsFromPageFast() async {
    try {
      final uploads = await _runYoutubeWithRetry(
        () => _yt.channels.getUploadsFromPage(
          widget.channelId,
          videoSorting: VideoSorting.newest,
          videoType: VideoType.normal,
        ),
        maxAttempts: 1,
      ).timeout(_channelFetchTimeout);
      return uploads.toList();
    } catch (_) {
      return const <Video>[];
    }
  }

  Future<List<Video>> _fetchUploadsPlaylistFast() async {
    try {
      final streamResult = await _runYoutubeWithRetry(
        () => _yt.channels.getUploads(widget.channelId).take(80).toList(),
        maxAttempts: 1,
      ).timeout(_channelFetchTimeout);
      return streamResult;
    } catch (_) {
      return const <Video>[];
    }
  }

  Future<List<Video>> _searchMusicByChannelName() async {
    final normalizedName = widget.channelName
        .replaceAll('- Topic', '')
        .replaceAll('Topic', '')
        .trim();
    final queries = <String>[
      '$normalizedName topic',
      '$normalizedName official audio',
      '$normalizedName music video',
    ];
    final collected = <Video>[];
    final seenIds = <String>{};
    for (final query in queries) {
      try {
        final result = await _runYoutubeWithRetry(
          () => _yt.search.search(query),
          maxAttempts: 1,
        ).timeout(_channelFetchTimeout);
        for (final item in result.take(20)) {
          if (!_looksLikeMusic(item)) continue;
          if (seenIds.add(item.id.value)) {
            collected.add(item);
          }
          if (collected.length >= 40) {
            return collected;
          }
        }
      } catch (_) {}
    }
    return collected;
  }

  List<Video> _prioritizePopularVideos(List<Video> source) {
    final topic = <Video>[];
    final music = <Video>[];
    final others = <Video>[];
    final seenIds = <String>{};

    for (final video in source) {
      final id = video.id.value;
      if (!seenIds.add(id)) continue;
      if (_isTopicVideo(video)) {
        topic.add(video);
      } else if (_looksLikeMusic(video)) {
        music.add(video);
      } else {
        others.add(video);
      }
    }

    topic.sort(
      (a, b) => b.engagement.viewCount.compareTo(a.engagement.viewCount),
    );
    music.sort(
      (a, b) => b.engagement.viewCount.compareTo(a.engagement.viewCount),
    );
    others.sort(
      (a, b) => b.engagement.viewCount.compareTo(a.engagement.viewCount),
    );

    return [...topic, ...music, ...others];
  }

  bool _looksLikeMusic(Video video) {
    final title = '${video.title} ${video.author}'.toLowerCase();
    const keywords = [
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
    return keywords.any(title.contains);
  }

  bool _isTopicVideo(Video video) {
    final author = video.author.toLowerCase().trim();
    return author.endsWith('- topic') || author.endsWith('topic');
  }

  String get _artistDisplayName {
    return widget.channelName
        .replaceAll(RegExp(r'\s*[-–—]\s*topic$', caseSensitive: false), '')
        .trim();
  }

  String get _headerImageUrl {
    if (widget.channelThumbnailUrl.isNotEmpty) {
      return widget.channelThumbnailUrl;
    }
    if (_videos.isNotEmpty) return bestThumbnailForVideo(_videos.first);
    return '';
  }

  Future<void> _seedBackgroundPalette() async {
    final imageUrl = _headerImageUrl;
    if (imageUrl.isEmpty) return;
    try {
      final scheme = await ColorScheme.fromImageProvider(
        provider: NetworkImage(imageUrl),
        brightness: Brightness.dark,
      );
      if (!mounted) return;
      setState(() {
        _bgColorA = scheme.primary.withValues(alpha: 0.72);
        _bgColorB = scheme.secondary.withValues(alpha: 0.66);
        _bgColorC = scheme.tertiary.withValues(alpha: 0.62);
      });
    } catch (_) {
      // Si falla la extracción, mantenemos la paleta por defecto.
    }
  }

  Future<T> _runYoutubeWithRetry<T>(
    Future<T> Function() action, {
    int maxAttempts = 2,
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
        await Future<void>.delayed(Duration(seconds: attempt));
      }
    }
    throw lastError ?? Exception('Error de red');
  }

  Future<void> _openVideoPlayer(
    String videoId, {
    String? thumbnailUrl,
    String? title,
    String? artist,
  }) async {
    try {
      final manager = Provider.of<VideoPlayerManager>(context, listen: false);
      manager.registerSearchThumbnail(videoId, thumbnailUrl);
      await manager.play(
        videoId,
        preferredThumbnailUrl: thumbnailUrl,
        preferredTitle: title,
        preferredArtist: artist,
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo iniciar la reproducción.')),
      );
    }
  }

  Future<void> _playVideoPreferLocal(Video video) async {
    final downloadService = context.read<DownloadService>();
    final videoManager = context.read<VideoPlayerManager>();
    final local = await downloadService.getDownloadedVideoById(video.id.value);

    if (!mounted) return;
    if (local != null) {
      final thumb =
          (local.localThumbnailPath != null &&
              local.localThumbnailPath!.isNotEmpty)
          ? local.localThumbnailPath!
          : local.thumbnailUrl;
      await videoManager.playLocalFile(
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

    await _openVideoPlayer(
      video.id.value,
      thumbnailUrl: _bestQualityThumbnail(video),
      title: video.title,
      artist: video.author,
    );
  }

  void _queueVideo(Video video) {
    final manager = context.read<VideoPlayerManager>();
    final added = manager.addOnlineTrackToPlaybackQueue(
      videoId: video.id.value,
      title: video.title,
      thumbnailUrl: _bestQualityThumbnail(video),
      artist: video.author,
    );
    if (!mounted) return;
    _showIosTopToast(
      context,
      message: added ? 'Añadida a la cola' : 'Esta canción ya está en cola',
      icon: added
          ? CupertinoIcons.check_mark_circled_solid
          : CupertinoIcons.info_circle_fill,
    );
  }

  Future<void> _showVideoOptionsMenu(Video video) async {
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
              child: BackdropFilter(
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
                                video.title,
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
    if (action == 'favorites') {
      await _addVideoToPlaylist(video, PlaylistService.favoritesPlaylistName);
      return;
    }
    if (action == 'playlist') {
      await _showPlaylistPicker(video);
    }
  }

  Future<void> _showPlaylistPicker(Video video) async {
    final playlistService = context.read<PlaylistService>();
    final playlists = await playlistService.getPlaylists();
    if (!mounted || playlists.isEmpty) return;

    final selectedName = await showGlassPlaylistPickerSheet(
      context: context,
      playlists: playlists,
      subtitle: video.title,
    );
    if (!mounted || selectedName == null || selectedName.isEmpty) return;
    await _addVideoToPlaylist(video, selectedName);
  }

  Future<void> _addVideoToPlaylist(Video video, String playlistName) async {
    final playlistService = context.read<PlaylistService>();
    final downloadService = context.read<DownloadService>();
    final videoManager = context.read<VideoPlayerManager>();
    final track = VideoHistory(
      videoId: video.id.value,
      title: video.title,
      thumbnailUrl: _bestQualityThumbnail(video),
      channelTitle: video.author,
      watchedAt: DateTime.now(),
    );
    await playlistService.addVideoToPlaylist(playlistName, track);
    await downloadService.autoDownloadIfEnabledUsingClone(
      playlistName,
      track,
      videoManager: videoManager,
    );
    if (!mounted) return;
    final label = PlaylistService.isFavoritesPlaylistName(playlistName)
        ? 'Añadida a Favoritos'
        : 'Añadida a $playlistName';
    _showIosTopToast(
      context,
      message: label,
      icon: PlaylistService.isFavoritesPlaylistName(playlistName)
          ? CupertinoIcons.star_fill
          : CupertinoIcons.check_mark_circled_solid,
    );
  }

  Future<void> _playTopTrack() async {
    if (_videos.isEmpty) return;
    await _playVideoPreferLocal(_videos.first);
  }

  Future<void> _playRandomTrack() async {
    if (_videos.isEmpty) return;
    final randomIndex = math.Random().nextInt(_videos.length);
    await _playVideoPreferLocal(_videos[randomIndex]);
  }

  @override
  void dispose() {
    _bgMotionController.dispose();
    _yt.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final downloadService = context.watch<DownloadService>();
    final content = _loading
        ? const Center(child: CupertinoActivityIndicator(radius: 14))
        : _error
        ? const Center(
            child: Text('No se pudieron cargar los videos del canal.'),
          )
        : _videos.isEmpty
        ? const Center(
            child: Text('No se encontraron videos musicales en este canal.'),
          )
        : CustomScrollView(
            slivers: [
              SliverAppBar(
                backgroundColor: Colors.black.withValues(alpha: 0.3),
                elevation: 0,
                pinned: true,
                expandedHeight: 320,
                leading: widget.embedded
                    ? IconButton(
                        icon: const Icon(Icons.arrow_back_ios_new_rounded),
                        onPressed: widget.onBack,
                      )
                    : null,
                flexibleSpace: FlexibleSpaceBar(
                  background: _ArtistHeroHeader(
                    imageUrl: _headerImageUrl,
                    artistName: _artistDisplayName,
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 0, 0, 10),
                  child: Column(
                    children: [
                      Transform.translate(
                        offset: Offset.zero,
                        child: const _ArtistHeaderListConnector(),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(18),
                          child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                            child: Container(
                              padding: const EdgeInsets.fromLTRB(
                                14,
                                12,
                                14,
                                12,
                              ),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(18),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.18),
                                  width: 0.6,
                                ),
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [
                                    Colors.white.withValues(alpha: 0.085),
                                    Colors.white.withValues(alpha: 0.02),
                                  ],
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Artista destacado',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelMedium
                                        ?.copyWith(
                                          color: CupertinoColors.secondaryLabel
                                              .resolveFrom(context),
                                          letterSpacing: 0.25,
                                        ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _artistDisplayName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge
                                        ?.copyWith(
                                          fontWeight: FontWeight.w800,
                                          color: CupertinoColors.label
                                              .resolveFrom(context),
                                        ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    '${_videos.length} tracks populares',
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: CupertinoColors.secondaryLabel
                                              .resolveFrom(context),
                                        ),
                                  ),
                                  const SizedBox(height: 12),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: _ArtistActionPill(
                                          icon: CupertinoIcons.play_fill,
                                          label: 'Reproducir',
                                          isPrimary: true,
                                          onPressed: _playTopTrack,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: _ArtistActionPill(
                                          icon: CupertinoIcons.shuffle,
                                          label: 'Aleatorio',
                                          onPressed: _playRandomTrack,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    'Populares',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverList.builder(
                  itemCount: _videos.length,
                  itemBuilder: (context, index) {
                    final video = _videos[index];
                    return VideoCard(
                      video: video,
                      isDownloaded:
                          downloadService.getDownloadStatus(video.id.value) ==
                          DownloadStatus.downloaded,
                      highlightTop: index < 3,
                      onPlay: () => _playVideoPreferLocal(video),
                      onQueue: () => _queueVideo(video),
                      onMenuTap: () => _showVideoOptionsMenu(video),
                    );
                  },
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          );

    final pageBody = Stack(
      fit: StackFit.expand,
      children: [
        _AnimatedArtistBackground(
          animation: _bgMotionController,
          colorA: _bgColorA,
          colorB: _bgColorB,
          colorC: _bgColorC,
        ),
        Positioned.fill(child: content),
      ],
    );

    if (widget.embedded) return pageBody;

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      body: pageBody,
    );
  }
}

class _AnimatedArtistBackground extends StatelessWidget {
  final Animation<double> animation;
  final Color colorA;
  final Color colorB;
  final Color colorC;

  const _AnimatedArtistBackground({
    required this.animation,
    required this.colorA,
    required this.colorB,
    required this.colorC,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final t = animation.value;
        final wobbleA = math.sin(t * math.pi * 2);
        final wobbleB = math.cos((t + 0.18) * math.pi * 2);
        final wobbleC = math.sin((t + 0.42) * math.pi * 2);

        return Stack(
          fit: StackFit.expand,
          children: [
            Container(color: Colors.black),
            Positioned(
              left: -26 + (wobbleA * 22),
              top: 130 + (wobbleB * 16),
              width: 310,
              height: 310,
              child: _BlurBlob(color: colorA),
            ),
            Positioned(
              right: -16 + (wobbleB * 20),
              top: 184 + (wobbleC * 16),
              width: 288,
              height: 288,
              child: _BlurBlob(color: colorB),
            ),
            Positioned(
              left: 42 + (wobbleC * 20),
              bottom: -24 + (wobbleA * 16),
              width: 322,
              height: 322,
              child: _BlurBlob(color: colorC),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            IgnorePointer(
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [0.0, 0.35, 0.75, 1.0],
                    colors: [
                      Color.fromARGB(72, 0, 0, 0),
                      Color.fromARGB(36, 0, 0, 0),
                      Color.fromARGB(120, 0, 0, 0),
                      Color.fromARGB(210, 0, 0, 0),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _BlurBlob extends StatelessWidget {
  final Color color;

  const _BlurBlob({required this.color});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.42),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.34),
            blurRadius: 140,
            spreadRadius: 28,
          ),
        ],
      ),
    );
  }
}

class _ArtistHeroHeader extends StatelessWidget {
  final String imageUrl;
  final String artistName;

  const _ArtistHeroHeader({required this.imageUrl, required this.artistName});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(color: Colors.black),
        Positioned.fill(
          child: imageUrl.isEmpty
              ? Container(
                  color: Colors.black,
                  alignment: Alignment.center,
                  child: const Icon(
                    Icons.person_rounded,
                    size: 92,
                    color: Colors.white54,
                  ),
                )
              : Transform.scale(
                  scale: 1.02,
                  child: Image.network(
                    imageUrl,
                    fit: BoxFit.cover,
                    alignment: Alignment.center,
                    filterQuality: FilterQuality.high,
                    errorBuilder: (context, error, stackTrace) => Container(
                      color: Colors.black,
                      alignment: Alignment.center,
                      child: const Icon(
                        Icons.person_rounded,
                        size: 92,
                        color: Colors.white54,
                      ),
                    ),
                  ),
                ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0.40, 0.74, 1.0],
                  colors: [
                    Color.fromARGB(0, 0, 0, 0),
                    Color.fromARGB(25, 0, 0, 0),
                    Color.fromARGB(95, 0, 0, 0),
                  ],
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 24,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.34),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.24),
                    width: 0.55,
                  ),
                ),
                child: const Text(
                  'ARTIST',
                  style: TextStyle(
                    fontFamily: '.SF Pro Text',
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                artistName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.25,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ArtistActionPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isPrimary;
  final VoidCallback onPressed;

  const _ArtistActionPill({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.isPrimary = false,
  });

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(14);
    final primaryColor = const Color(0xFFE83C64);
    return CupertinoButton(
      padding: EdgeInsets.zero,
      minimumSize: Size.zero,
      onPressed: onPressed,
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            height: 34,
            decoration: BoxDecoration(
              borderRadius: borderRadius,
              color: isPrimary
                  ? primaryColor.withValues(alpha: 0.88)
                  : Colors.white.withValues(alpha: 0.11),
              border: Border.all(
                color: isPrimary
                    ? Colors.white.withValues(alpha: 0.26)
                    : Colors.white.withValues(alpha: 0.18),
                width: 0.55,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 14, color: Colors.white),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: const TextStyle(
                    fontFamily: '.SF Pro Text',
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ArtistHeaderListConnector extends StatelessWidget {
  const _ArtistHeaderListConnector();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 22,
      child: Stack(
        alignment: Alignment.topCenter,
        children: [
          ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color.fromARGB(130, 0, 0, 0),
                      Color.fromARGB(36, 0, 0, 0),
                      Color.fromARGB(0, 0, 0, 0),
                    ],
                  ),
                ),
              ),
            ),
          ),
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: Container(
              margin: EdgeInsets.zero,
              height: 12,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                gradient: const LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    Color.fromARGB(130, 255, 0, 77),
                    Color.fromARGB(130, 255, 122, 0),
                    Color.fromARGB(130, 122, 92, 255),
                  ],
                ),
              ),
            ),
          ),
          Container(
            margin: EdgeInsets.zero,
            height: 5,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(3),
              gradient: const LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  Color(0xFFFF004D),
                  Color(0xFFFF7A00),
                  Color(0xFF7A5CFF),
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFFF4D00).withValues(alpha: 0.60),
                  blurRadius: 30,
                  spreadRadius: 2.2,
                  offset: const Offset(0, 1),
                ),
                BoxShadow(
                  color: const Color(0xFF7A5CFF).withValues(alpha: 0.40),
                  blurRadius: 26,
                  spreadRadius: 1.6,
                  offset: const Offset(0, 0),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
