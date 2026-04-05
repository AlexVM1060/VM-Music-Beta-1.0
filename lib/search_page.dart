import 'dart:developer' as developer;
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:myapp/video_player_manager.dart';
import 'package:provider/provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

enum SearchState { initial, loading, success, error, noResults }

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _textController = TextEditingController();
  final YoutubeExplode _youtubeExplode = YoutubeExplode();
  List<Video> _videos = [];
  List<Video> _allSearchResults = [];
  SearchState _searchState = SearchState.initial;
  final Map<String, List<Video>> _searchCache = {};
  final Map<String, Future<List<Video>>> _searchInFlight = {};
  bool _onlyMusic = true;

  Future<void> _searchVideos() async {
    if (_textController.text.trim().isEmpty) return;
    FocusScope.of(context).unfocus();
    final query = _textController.text.trim();
    final cached = _searchCache[query];
    if (cached != null) {
      final filteredVideos = _onlyMusic
          ? cached.where(_isStrictMusicVideo).toList()
          : cached;
      setState(() {
        _allSearchResults = cached;
        _videos = filteredVideos;
        _searchState = filteredVideos.isEmpty ? SearchState.noResults : SearchState.success;
      });
      return;
    }

    setState(() {
      _searchState = SearchState.loading;
      _videos = [];
    });

    try {
      final searchResult = await _searchWithCache(query);
      if (!mounted) return;

      if (searchResult.isEmpty) {
        setState(() => _searchState = SearchState.noResults);
      } else {
        final allVideos = searchResult.toList();
        final filteredVideos = _onlyMusic
            ? allVideos.where(_isStrictMusicVideo).toList()
            : allVideos;

        setState(() {
          _allSearchResults = allVideos;
          _videos = filteredVideos;
          _searchState = filteredVideos.isEmpty ? SearchState.noResults : SearchState.success;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _searchState = SearchState.error);
      }
    }
  }

  bool _isStrictMusicVideo(Video video) {
    final title = video.title.toLowerCase();
    final author = video.author.toLowerCase();

    const strictTitleKeywords = [
      'official audio',
      'official music video',
    ];

    final isTopicChannel = author.contains('- topic');
    final isVevoChannel = author.contains('vevo');
    final hasOfficialMusicLabel = strictTitleKeywords.any(title.contains);

    return isTopicChannel || isVevoChannel || hasOfficialMusicLabel;
  }

  Future<void> _openVideoPlayer(String videoId) async {
    try {
      await Provider.of<VideoPlayerManager>(context, listen: false).play(videoId);
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
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0),
        child: Column(
          children: [
            const SizedBox(height: 16),
            _buildSearchBar(),
            const SizedBox(height: 10),
            _buildMusicFilterSwitch(),
            const SizedBox(height: 24),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    return TextField(
      controller: _textController,
      onSubmitted: (_) => _searchVideos(),
      decoration: InputDecoration(
        hintText: 'Buscar en YouTube...',
        prefixIcon: const Icon(Icons.search),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(30.0),
          borderSide: BorderSide.none,
        ),
        filled: true,
        fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
    );
  }

  Widget _buildMusicFilterSwitch() {
    return SwitchListTile.adaptive(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      title: const Text('Solo música'),
      subtitle: const Text('Topic, VEVO y Official Audio'),
      value: _onlyMusic,
      onChanged: (value) {
        setState(() {
          _onlyMusic = value;
        });
        if (_allSearchResults.isNotEmpty) {
          final filtered = value
              ? _allSearchResults.where(_isStrictMusicVideo).toList()
              : _allSearchResults;
          setState(() {
            _videos = filtered;
            _searchState = filtered.isEmpty ? SearchState.noResults : SearchState.success;
          });
        }
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
            'Busca algo para empezar',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
        );
      case SearchState.success:
        return ListView.builder(
          itemCount: _videos.length,
          itemBuilder: (context, index) {
            final video = _videos[index];
            return VideoCard(
              video: video,
              onPlay: () => _openVideoPlayer(video.id.value),
            );
          },
        );
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    _youtubeExplode.close();
    super.dispose();
  }
}

class VideoCard extends StatelessWidget {
  final Video video;
  final VoidCallback onPlay;

  const VideoCard({
    super.key,
    required this.video,
    required this.onPlay,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2.0,
      margin: const EdgeInsets.symmetric(vertical: 8.0),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.0)),
      child: InkWell(
        onTap: onPlay,
        borderRadius: BorderRadius.circular(12.0),
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8.0),
                child: Image.network(
                  video.thumbnails.mediumResUrl,
                  width: 120,
                  height: 67.5,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) =>
                      Icon(Icons.videocam_off_outlined, size: 67.5, color: Colors.grey),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      video.title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      video.author,
                      style: Theme.of(context).textTheme.bodySmall,
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
    );
  }
}
