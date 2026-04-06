import 'dart:developer' as developer;
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:myapp/search_view_state.dart';
import 'package:myapp/video_player_manager.dart';
import 'package:provider/provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

enum SearchState { initial, loading, success, error, noResults }

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

class _SearchPageState extends State<SearchPage> with SingleTickerProviderStateMixin {
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
  final Map<String, String?> _artistInternetImageCache = {};
  final FocusNode _searchFocusNode = FocusNode();
  int _searchEpoch = 0;
  bool _showArtists = true;
  _SelectedArtistView? _selectedArtistView;
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
        _searchState =
            cached.isEmpty && cachedChannels.isEmpty
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
      final searchResult = await _searchWithCache(query);
      if (!mounted || epoch != _searchEpoch) return;
      setState(() {
        _videos = searchResult.toList();
        _channels = cachedChannels ?? const [];
        _searchState = searchResult.isEmpty ? SearchState.loading : SearchState.success;
      });

      final channelResult = await _searchChannelsWithCache(query);
      if (!mounted || epoch != _searchEpoch) return;
      setState(() {
        _channels = channelResult;
        _searchState =
            _videos.isEmpty && channelResult.isEmpty
                ? SearchState.noResults
                : SearchState.success;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _searchState = SearchState.error);
      }
    }
  }

  Future<void> _openChannel(SearchChannelWithSubscribers channelData) async {
    final channel = channelData.channel;
    setState(() {
      _selectedArtistView = _SelectedArtistView(
        channelId: channel.id.value,
        channelName: channel.name,
        channelThumbnailUrl: _thumbnailOf(channelData) ?? '',
      );
    });
    _searchViewState?.setArtistFullscreen(true);
  }

  Future<void> _openVideoPlayer(
    String videoId, {
    String? thumbnailUrl,
    String? title,
    String? artist,
  }) async {
    try {
      await Provider.of<VideoPlayerManager>(context, listen: false).play(
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

  Future<List<Video>> _searchWithCache(String query) async {
    final cached = _searchCache[query];
    if (cached != null) return cached;
    final inFlight = _searchInFlight[query];
    if (inFlight != null) return inFlight;

    final future = _runYoutubeWithRetry(
      () async => (await _youtubeExplode.search.search(query)).toList(),
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

  Future<List<SearchChannelWithSubscribers>> _searchChannelsWithCache(String query) async {
    final cached = await _getCachedChannels(query);
    if (cached != null) return cached;
    final inFlight = _channelSearchInFlight[query];
    if (inFlight != null) {
      final result = await inFlight;
      return _normalizeChannelResults(result);
    }

    final future = _runYoutubeWithRetry<Object>(() async {
      final list = await _youtubeExplode.search
          .searchContent(query, filter: TypeFilters.channel);
      final channels = list.whereType<SearchChannel>().toList();
      final topSearchChannelPhoto = await _resolveTopSubscribedChannelPhoto(channels);
      final resolvedByChannelSearch = await _resolveChannelsWithSubscribers(channels);
      final videos = await _searchWithCache(query);
      final resolvedByVideoSearch = await _resolveChannelsFromTopVideos(videos);
      final merged = _mergeChannelCandidates(
        resolvedByChannelSearch,
        resolvedByVideoSearch,
      );
      final filtered = _filterChannelsBySubscribers(merged);
      return _hydrateTopicChannelPhotos(
        filtered,
        merged,
        forcedTopicThumbnail: topSearchChannelPhoto,
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

  Future<List<SearchChannelWithSubscribers>?> _getCachedChannels(String query) async {
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
            channel: SearchChannel(
              details.id,
              details.title,
              '',
              0,
              [Thumbnail(Uri.parse(details.logoUrl), 0, 0)],
            ),
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
      } else if ((item.subscribersCount ?? 0) > (existing.subscribersCount ?? 0)) {
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

    final knownSubscribers = channels.where((item) => item.subscribersCount != null).toList();
    if (knownSubscribers.isNotEmpty) {
      return _prioritizeTopicFirst(knownSubscribers).take(_maxChannelsToShow).toList();
    }

    // Fallback final: si YouTube no devuelve conteo de suscriptores.
    final fallback = channels.where((item) => item.subscribersCount == null).toList();
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
    List<SearchChannelWithSubscribers> pool,
    {String? forcedTopicThumbnail}
  ) async {
    if (selected.isEmpty) return selected;
    final globalFallback = forcedTopicThumbnail ?? _bestArtistThumbnailFromPool(pool);
    final hydrated = <SearchChannelWithSubscribers>[];

    for (final item in selected) {
      if (!_isTopicChannel(item.channel)) {
        hydrated.add(item);
        continue;
      }

      final internetArtistPhoto = await _resolveArtistImageFromInternet(item.channel.name);
      final chosen = internetArtistPhoto ?? globalFallback ?? _thumbnailOf(item);
      hydrated.add(item.copyWith(thumbnailUrlOverride: chosen));
    }

    return hydrated;
  }

  Future<String?> _resolveTopSubscribedChannelPhoto(
    List<SearchChannel> channels,
  ) async {
    if (channels.isEmpty) return null;
    final resolved = await _resolveChannelsWithSubscribers(channels.take(6).toList());
    return _topThumbnailFromResolved(resolved);
  }

  String? _topThumbnailFromResolved(List<SearchChannelWithSubscribers> channels) {
    if (channels.isEmpty) return null;
    final sorted = channels.toList()
      ..sort((a, b) => (b.subscribersCount ?? 0).compareTo(a.subscribersCount ?? 0));
    for (final item in sorted) {
      final thumb = _thumbnailOf(item);
      if (thumb != null && thumb.isNotEmpty) return thumb;
    }
    return null;
  }

  Future<String?> _resolveArtistImageFromInternet(String rawChannelName) async {
    final artistName = rawChannelName
        .replaceAll(RegExp(r'\s*[-–—]\s*topic$', caseSensitive: false), '')
        .replaceAll(RegExp(r'\btopic\b', caseSensitive: false), '')
        .trim();
    if (artistName.isEmpty) return null;
    final cacheKey = artistName.toLowerCase();
    if (_artistInternetImageCache.containsKey(cacheKey)) {
      return _artistInternetImageCache[cacheKey];
    }

    try {
      final title = await _resolveWikipediaTitle(artistName);
      if (title == null || title.isEmpty) {
        _artistInternetImageCache[cacheKey] = null;
        return null;
      }
      final image = await _resolveWikipediaThumbnail(title);
      _artistInternetImageCache[cacheKey] = image;
      return image;
    } catch (_) {
      _artistInternetImageCache[cacheKey] = null;
      return null;
    }
  }

  Future<String?> _resolveWikipediaTitle(String artistName) async {
    final uri = Uri.https('en.wikipedia.org', '/w/api.php', {
      'action': 'opensearch',
      'search': artistName,
      'limit': '1',
      'namespace': '0',
      'format': 'json',
    });

    final data = await _getJsonFromInternet(uri);
    if (data is! List || data.length < 2) return null;
    final titles = data[1];
    if (titles is! List || titles.isEmpty) return null;
    return titles.first?.toString();
  }

  Future<String?> _resolveWikipediaThumbnail(String title) async {
    final uri = Uri.https('en.wikipedia.org', '/w/api.php', {
      'action': 'query',
      'format': 'json',
      'prop': 'pageimages',
      'piprop': 'thumbnail',
      'pithumbsize': '600',
      'titles': title,
    });

    final data = await _getJsonFromInternet(uri);
    if (data is! Map<String, dynamic>) return null;
    final query = data['query'];
    if (query is! Map<String, dynamic>) return null;
    final pages = query['pages'];
    if (pages is! Map<String, dynamic>) return null;
    for (final value in pages.values) {
      if (value is! Map<String, dynamic>) continue;
      final thumb = value['thumbnail'];
      if (thumb is! Map<String, dynamic>) continue;
      final source = thumb['source'];
      if (source is String && source.isNotEmpty) return source;
    }
    return null;
  }

  Future<dynamic> _getJsonFromInternet(Uri uri) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, 'VMMusic/1.0');
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}', uri: uri);
      }
      final body = await response.transform(utf8.decoder).join();
      return jsonDecode(body);
    } finally {
      client.close(force: true);
    }
  }

  String? _bestArtistThumbnailFromPool(List<SearchChannelWithSubscribers> pool) {
    final candidates = pool.where((item) => !_isTopicChannel(item.channel)).toList()
      ..sort((a, b) => (b.subscribersCount ?? 0).compareTo(a.subscribersCount ?? 0));
    for (final item in candidates) {
      final thumb = _thumbnailOf(item);
      if (thumb != null && thumb.isNotEmpty) return thumb;
    }
    return null;
  }

  String? _thumbnailOf(SearchChannelWithSubscribers item) {
    if (item.thumbnailUrlOverride != null && item.thumbnailUrlOverride!.isNotEmpty) {
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
    if (_subscriberCountCache.containsKey(channelId) || _channelLogoCache.containsKey(channelId)) {
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
    if (selectedArtist != null) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) {
            setState(() => _selectedArtistView = null);
            context.read<SearchViewState>().setArtistFullscreen(false);
          }
        },
        child: ChannelVideosPage(
          channelId: selectedArtist.channelId,
          channelName: selectedArtist.channelName,
          channelThumbnailUrl: selectedArtist.channelThumbnailUrl,
          embedded: true,
          onBack: () {
            setState(() => _selectedArtistView = null);
            context.read<SearchViewState>().setArtistFullscreen(false);
          },
        ),
      );
    }

    if (context.read<SearchViewState>().isArtistFullscreen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        context.read<SearchViewState>().setArtistFullscreen(false);
      });
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
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
                color: const Color(0xFF581A95).withValues(alpha: focused ? 0.34 : 0.14),
                blurRadius: focused ? 20 : 10,
                spreadRadius: focused ? 0.9 : 0,
                offset: const Offset(0, 2),
              ),
              BoxShadow(
                color: const Color(0xFFFF2A6D).withValues(alpha: focused ? 0.24 : 0.08),
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
                    contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
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
        return const Center(child: Text('Error al buscar. Inténtalo de nuevo.'));
      case SearchState.noResults:
        return const Center(child: Text('No se encontraron videos.'));
      case SearchState.initial:
        return Center(
          child: Text(
            'Comienza haciendo',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
        );
      case SearchState.success:
        final prioritizedVideos = _prioritizedVideos(_videos);
        return ListView(
          children: [
            if (_showArtists && _channels.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Artista principal',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              TopArtistCard(
                channel: _channels.first,
                subscriberLabel: _formatSubscribers(_channels.first.subscribersCount),
                onOpenChannel: () => _openChannel(_channels.first),
              ),
              if (_channels.length > 1) ...[
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
                ..._channels.skip(1).take(4).map(
                  (channel) => ChannelCard(
                    channel: channel,
                    subscriberLabel: _formatSubscribers(channel.subscribersCount),
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
            ...prioritizedVideos.take(20).map(
              (video) => VideoCard(
                video: video,
                onPlay: () => _openVideoPlayer(
                  video.id.value,
                  thumbnailUrl: video.thumbnails.mediumResUrl,
                  title: video.title,
                  artist: video.author,
                ),
              ),
            ),
          ],
        );
    }
  }

  List<Video> _prioritizedVideos(List<Video> source) {
    final topic = <Video>[];
    final music = <Video>[];
    final others = <Video>[];
    final seen = <String>{};

    for (final video in source) {
      final id = video.id.value;
      if (seen.contains(id)) continue;
      seen.add(id);
      if (_isTopicVideo(video)) {
        topic.add(video);
      } else if (_looksLikeMusicVideo(video)) {
        music.add(video);
      } else {
        others.add(video);
      }
    }

    return [...topic, ...music, ...others];
  }

  bool _isTopicVideo(Video video) {
    final author = video.author.toLowerCase().trim();
    return author.endsWith('- topic') || author.endsWith('topic');
  }

  bool _looksLikeMusicVideo(Video video) {
    final haystack = '${video.title} ${video.author}'.toLowerCase();
    const hints = [
      'official',
      'music video',
      'official video',
      'official audio',
      'lyrics',
      'lyric',
      'audio',
      'topic',
      'vevo',
      'session',
      'live',
      'acoustic',
      'remix',
      'en vivo',
    ];
    return hints.any(haystack.contains);
  }

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
                padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 7.0),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: Image.network(
                        thumb,
                        width: 52,
                        height: 52,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) => const SizedBox(
                          width: 52,
                          height: 52,
                          child: Icon(Icons.account_circle_outlined, size: 26, color: Colors.grey),
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
                            style: CupertinoTheme.of(context).textTheme.textStyle.copyWith(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '$subscriberLabel • ${channel.channel.videoCount} videos',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: CupertinoTheme.of(context).textTheme.textStyle.copyWith(
                                  fontSize: 13,
                                  color: Colors.white70,
                                ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Icon(Icons.chevron_right_rounded, color: Colors.white70),
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
            colors: [
              Color(0xFFFF004D),
              Color(0xFFFF7A00),
              Color(0xFF7A5CFF),
            ],
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFFF4D00).withValues(alpha: isActive ? 0.3 : 0.16),
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
                        ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.2)
                        : CupertinoColors.systemGrey6.resolveFrom(context).withValues(alpha: 0.52)),
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
                    style: CupertinoTheme.of(context).textTheme.textStyle.copyWith(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: isActive ? Theme.of(context).colorScheme.primary : null,
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
                        child: Image.network(
                          thumb,
                          width: 72,
                          height: 72,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) => const SizedBox(
                            width: 72,
                            height: 72,
                            child: Icon(Icons.account_circle_outlined, size: 38, color: Colors.grey),
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
                              style: CupertinoTheme.of(context).textTheme.textStyle.copyWith(
                                    fontSize: 26,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white,
                                  ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              subscriberLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: CupertinoTheme.of(context).textTheme.textStyle.copyWith(
                                    fontSize: 14,
                                    color: Colors.white70,
                                  ),
                            ),
                            Text(
                              '${channel.channel.videoCount} videos',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: CupertinoTheme.of(context).textTheme.textStyle.copyWith(
                                    fontSize: 13,
                                    color: Colors.white70,
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: onOpenChannel,
                    icon: const Icon(Icons.music_note_rounded),
                    label: const Text('Ver videos musicales'),
                  ),
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

class VideoCard extends StatelessWidget {
  final Video video;
  final VoidCallback onPlay;
  final bool highlightTop;

  const VideoCard({
    super.key,
    required this.video,
    required this.onPlay,
    this.highlightTop = false,
  });

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(14);
    final card = ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Material(
          color: Colors.white.withValues(alpha: 0.035),
          child: InkWell(
            onTap: onPlay,
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
              padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 5.0),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10.0),
                    child: Image.network(
                      video.thumbnails.mediumResUrl,
                      width: 64,
                      height: 64,
                      fit: BoxFit.cover,
                      alignment: Alignment.center,
                      errorBuilder: (context, error, stackTrace) =>
                          const SizedBox(
                            width: 64,
                            height: 64,
                            child: Icon(Icons.videocam_off_outlined, size: 26, color: Colors.grey),
                          ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          video.title,
                          style: CupertinoTheme.of(context).textTheme.textStyle.copyWith(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          video.author,
                          style: CupertinoTheme.of(context).textTheme.textStyle.copyWith(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: Colors.white70,
                              ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
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

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.0),
      child: highlightTop
          ? Container(
              padding: const EdgeInsets.all(1.1),
              decoration: BoxDecoration(
                borderRadius: borderRadius,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: const [
                    Color(0xFFFF3D00),
                    Color(0xFFFF8A00),
                    Color(0xFFFFC107),
                  ].map((c) => c.withValues(alpha: 0.52)).toList(),
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFFF6D00).withValues(alpha: 0.08),
                    blurRadius: 8,
                    spreadRadius: 0,
                  ),
                ],
              ),
              child: card,
            )
          : card,
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
    // 1) Canal uploads page (ruta principal)
    try {
      final uploads = await _runYoutubeWithRetry(
        () => _yt.channels.getUploadsFromPage(
          widget.channelId,
          videoSorting: VideoSorting.newest,
          videoType: VideoType.normal,
        ),
      );
      final result = uploads.toList();
      if (result.isNotEmpty) return result;
    } catch (_) {}

    // 2) Playlist de uploads del canal (mejor para canales - Topic)
    try {
      final streamResult = await _runYoutubeWithRetry(
        () => _yt.channels.getUploads(widget.channelId).take(80).toList(),
      );
      if (streamResult.isNotEmpty) return streamResult;
    } catch (_) {}

    // 3) Fallback por busqueda del nombre del canal/topic
    final searchFallback = await _searchMusicByChannelName();
    return searchFallback;
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
        );
        for (final item in result.take(20)) {
          if (!_looksLikeMusic(item)) continue;
          if (seenIds.add(item.id.value)) {
            collected.add(item);
          }
          if (collected.length >= 80) {
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

    topic.sort((a, b) => b.engagement.viewCount.compareTo(a.engagement.viewCount));
    music.sort((a, b) => b.engagement.viewCount.compareTo(a.engagement.viewCount));
    others.sort((a, b) => b.engagement.viewCount.compareTo(a.engagement.viewCount));

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
    if (widget.channelThumbnailUrl.isNotEmpty) return widget.channelThumbnailUrl;
    if (_videos.isNotEmpty) return _videos.first.thumbnails.highResUrl;
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
        await Future<void>.delayed(Duration(seconds: attempt * 2));
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
      await Provider.of<VideoPlayerManager>(context, listen: false).play(
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

  @override
  void dispose() {
    _bgMotionController.dispose();
    _yt.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final content = _loading
        ? const Center(child: CupertinoActivityIndicator(radius: 14))
        : _error
            ? const Center(child: Text('No se pudieron cargar los videos del canal.'))
            : _videos.isEmpty
                ? const Center(child: Text('No se encontraron videos musicales en este canal.'))
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
                          padding: const EdgeInsets.fromLTRB(0, 0, 0, 8),
                          child: Column(
                            children: [
                              Transform.translate(
                                offset: Offset.zero,
                                child: const _ArtistHeaderListConnector(),
                              ),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    'Populares',
                                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                          fontWeight: FontWeight.w700,
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
                              highlightTop: index < 3,
                              onPlay: () => _openVideoPlayer(
                                video.id.value,
                                thumbnailUrl: video.thumbnails.mediumResUrl,
                                title: video.title,
                                artist: video.author,
                              ),
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

  const _ArtistHeroHeader({
    required this.imageUrl,
    required this.artistName,
  });

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
              : Image.network(
                  imageUrl,
                  fit: BoxFit.cover,
                  alignment: Alignment.center,
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
          child: Text(
            artistName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
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
