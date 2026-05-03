import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:myapp/models/downloaded_video.dart';
import 'package:myapp/playlists_page.dart';
import 'package:myapp/search_page.dart';
import 'package:myapp/search_view_state.dart';
import 'package:myapp/services/download_service.dart';
import 'package:myapp/services/library_albums_service.dart';
import 'package:myapp/video_player_manager.dart';
import 'package:myapp/widgets/square_thumbnail.dart';
import 'package:provider/provider.dart';

enum _LibrarySection { playlist, albumes, videos, descargas }

class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key});

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  _LibrarySection? _selectedSection;
  LibraryAlbum? _selectedLibraryAlbum;
  bool _isForwardTransition = true;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_handleSearchChanged);
  }

  @override
  void dispose() {
    _setLibraryAppBarHidden(false);
    _searchController.removeListener(_handleSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _handleSearchChanged() {
    final next = _searchController.text.trim().toLowerCase();
    if (next == _searchQuery) return;
    setState(() {
      _searchQuery = next;
    });
  }

  List<DownloadedVideo> _filterSongs(List<DownloadedVideo> songs) {
    if (_searchQuery.isEmpty) return songs;
    return songs
        .where((song) {
          final title = song.title.toLowerCase();
          final artist = song.channelTitle.toLowerCase();
          return title.contains(_searchQuery) || artist.contains(_searchQuery);
        })
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground.resolveFrom(
        context,
      ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: _buildAnimatedSectionContent(),
      ),
    );
  }

  Widget _buildAnimatedSectionContent() {
    final current = _buildSectionContent();
    final beginX = _isForwardTransition ? 0.08 : -0.06;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 460),
      reverseDuration: const Duration(milliseconds: 360),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        final slide = Tween<Offset>(
          begin: Offset(beginX, 0),
          end: Offset.zero,
        ).animate(curved);
        final scale = Tween<double>(begin: 0.985, end: 1.0).animate(curved);
        return FadeTransition(
          opacity: curved,
          child: ClipRect(
            child: SlideTransition(
              position: slide,
              child: ScaleTransition(scale: scale, child: child),
            ),
          ),
        );
      },
      layoutBuilder: (currentChild, previousChildren) {
        return Stack(
          fit: StackFit.expand,
          children: [
            ...previousChildren,
            if (currentChild != null) currentChild,
          ],
        );
      },
      child: KeyedSubtree(
        key: ValueKey<String>(
          'lib_${_selectedSection?.name ?? 'root'}_${_selectedLibraryAlbum?.playlistId ?? 'none'}',
        ),
        child: current,
      ),
    );
  }

  Widget _buildSectionContent() {
    switch (_selectedSection) {
      case _LibrarySection.playlist:
        return PlaylistsPage(onBack: _goBackToLibraryList, useSafeArea: false);
      case _LibrarySection.albumes:
        if (_selectedLibraryAlbum != null) {
          final album = _selectedLibraryAlbum!;
          return _LibraryEdgeSwipeBack(
            onBack: _closeEmbeddedLibraryAlbum,
            child: AlbumTracksPage(
              playlistId: album.playlistId,
              albumTitle: album.title,
              artistName: album.artist,
              seedThumbnailUrl: album.thumbnailUrl,
              embedded: true,
              onBack: _closeEmbeddedLibraryAlbum,
            ),
          );
        }
        return _LibraryEdgeSwipeBack(
          onBack: _goBackToLibraryList,
          child: _buildAlbumsSection(),
        );
      case _LibrarySection.videos:
        return _LibraryEdgeSwipeBack(
          onBack: _goBackToLibraryList,
          child: _buildPlaceholderSection('Videos'),
        );
      case _LibrarySection.descargas:
        return _LibraryEdgeSwipeBack(
          onBack: _goBackToLibraryList,
          child: _buildDownloadsSection(),
        );
      case null:
        return _buildLibraryList();
    }
  }

  Widget _buildLibraryList() {
    final sections = <({IconData icon, String title, _LibrarySection section})>[
      (
        icon: CupertinoIcons.music_note_list,
        title: 'Playlist',
        section: _LibrarySection.playlist,
      ),
      (
        icon: CupertinoIcons.music_albums,
        title: 'Albumes',
        section: _LibrarySection.albumes,
      ),
      (
        icon: CupertinoIcons.videocam,
        title: 'Videos',
        section: _LibrarySection.videos,
      ),
      (
        icon: CupertinoIcons.arrow_down_circle,
        title: 'Descargas',
        section: _LibrarySection.descargas,
      ),
    ];

    final hasMiniPlayer = context.select<VideoPlayerManager, bool>(
      (playerManager) =>
          playerManager.currentVideoId != null && playerManager.isMinimized,
    );
    final bottomInset = MediaQuery.of(context).padding.bottom;
    const tabBarReserve = 108.0;
    const miniPlayerReserve = 64.0;
    final bottomReserve =
        tabBarReserve + (hasMiniPlayer ? miniPlayerReserve : 0) + bottomInset;

    return ListView.separated(
      padding: EdgeInsets.fromLTRB(12, 14, 12, 14 + bottomReserve),
      itemBuilder: (context, index) {
        final section = sections[index];
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final cardColor = isDark
            ? Colors.black
            : CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
                context,
              );
        final border = isDark
            ? Colors.white.withValues(alpha: 0.12)
            : CupertinoColors.separator
                  .resolveFrom(context)
                  .withValues(alpha: 0.12);

        return ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Material(
            color: cardColor,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () {
                _openLibrarySection(section.section);
              },
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: border, width: 0.5),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 14,
                ),
                child: Row(
                  children: [
                    Icon(section.icon, size: 22),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        section.title,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    Icon(
                      CupertinoIcons.chevron_forward,
                      size: 16,
                      color: CupertinoColors.secondaryLabel.resolveFrom(context),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemCount: sections.length,
    );
  }

  Widget _buildPlaceholderSection(String title) {
    final hasMiniPlayer = context.select<VideoPlayerManager, bool>(
      (playerManager) =>
          playerManager.currentVideoId != null && playerManager.isMinimized,
    );
    final bottomInset = MediaQuery.of(context).padding.bottom;
    const tabBarReserve = 108.0;
    const miniPlayerReserve = 64.0;
    final bottomReserve =
        tabBarReserve + (hasMiniPlayer ? miniPlayerReserve : 0) + bottomInset;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        _buildSectionHeader(title),
        const SizedBox(height: 120),
        const Center(child: Text('Disponible próximamente.')),
        SizedBox(height: bottomReserve),
      ],
    );
  }

  Widget _buildAlbumsSection() {
    final libraryAlbums = context.watch<LibraryAlbumsService>().albums;
    final hasMiniPlayer = context.select<VideoPlayerManager, bool>(
      (playerManager) =>
          playerManager.currentVideoId != null && playerManager.isMinimized,
    );
    final bottomInset = MediaQuery.of(context).padding.bottom;
    const tabBarReserve = 108.0;
    const miniPlayerReserve = 64.0;
    final bottomReserve =
        tabBarReserve + (hasMiniPlayer ? miniPlayerReserve : 0) + bottomInset;

    if (libraryAlbums.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          _buildSectionHeader(
            'Álbumes',
            topPadding: _albumsHeaderTopPadding(context),
          ),
          const SizedBox(height: 156),
          const Center(child: Text('Aún no has agregado álbumes en Buscar.')),
          SizedBox(height: bottomReserve),
        ],
      );
    }

    return Column(
      children: [
        _buildSectionHeader(
          'Álbumes',
          topPadding: _albumsHeaderTopPadding(context),
        ),
        Expanded(
          child: ListView.separated(
            padding: EdgeInsets.fromLTRB(12, 26, 12, 14 + bottomReserve),
            itemCount: libraryAlbums.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final album = libraryAlbums[index];
              final isDark = Theme.of(context).brightness == Brightness.dark;
              final cardColor = isDark
                  ? Colors.black
                  : CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
                      context,
                    );
              final border = isDark
                  ? Colors.white.withValues(alpha: 0.12)
                  : CupertinoColors.separator
                        .resolveFrom(context)
                        .withValues(alpha: 0.12);
              return ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Material(
                  color: cardColor,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () {
                      setState(() {
                        _isForwardTransition = true;
                        _selectedLibraryAlbum = album;
                      });
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        color: cardColor,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: border, width: 0.5),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 14,
                      ),
                      child: Row(
                        children: [
                          album.thumbnailUrl.isNotEmpty
                              ? SquareThumbnail.network(
                                  imageUrl: album.thumbnailUrl,
                                  size: 56,
                                  borderRadius: 10,
                                  fallback: Container(
                                    width: 56,
                                    height: 56,
                                    decoration: BoxDecoration(
                                      color: CupertinoColors.tertiarySystemFill
                                          .resolveFrom(context),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    alignment: Alignment.center,
                                    child: const Icon(
                                      CupertinoIcons.music_albums,
                                      size: 20,
                                    ),
                                  ),
                                )
                              : Container(
                                width: 56,
                                height: 56,
                                decoration: BoxDecoration(
                                  color: CupertinoColors.tertiarySystemFill
                                      .resolveFrom(context),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                alignment: Alignment.center,
                                child: const Icon(
                                  CupertinoIcons.music_albums,
                                  size: 20,
                                ),
                              ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  album.title,
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                if (album.artist.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    album.artist,
                                    style: TextStyle(
                                      color: CupertinoColors.secondaryLabel
                                          .resolveFrom(context),
                                      fontSize: 12,
                                      fontFamily: '.SF Pro Text',
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ],
                            ),
                          ),
                          Icon(
                            CupertinoIcons.chevron_forward,
                            size: 16,
                            color: CupertinoColors.secondaryLabel.resolveFrom(
                              context,
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
      ],
    );
  }

  Widget _buildDownloadsSection() {
    final downloadService = context.watch<DownloadService>();
    final manager = context.read<VideoPlayerManager>();
    final hasMiniPlayer = context.select<VideoPlayerManager, bool>(
      (playerManager) =>
          playerManager.currentVideoId != null && playerManager.isMinimized,
    );
    final bottomInset = MediaQuery.of(context).padding.bottom;
    const tabBarReserve = 108.0;
    const miniPlayerReserve = 64.0;
    final bottomReserve =
        tabBarReserve + (hasMiniPlayer ? miniPlayerReserve : 0) + bottomInset;

    return Column(
      children: [
        _buildSectionHeader('Descargas'),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: CupertinoSearchTextField(
            controller: _searchController,
            placeholder: 'Buscar por título o artista',
          ),
        ),
        Expanded(
          child: FutureBuilder<List<DownloadedVideo>>(
            future: downloadService.getDownloadedVideos(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CupertinoActivityIndicator(radius: 14));
              }

              final songs = snapshot.data ?? const <DownloadedVideo>[];
              final filteredSongs = _filterSongs(songs);
              final hasSearch = _searchQuery.isNotEmpty;

              return RefreshIndicator(
                onRefresh: () async {
                  await downloadService.loadDownloadedVideos();
                },
                child: _buildDownloadsList(
                  context: context,
                  songs: filteredSongs,
                  allSongsEmpty: songs.isEmpty,
                  hasSearch: hasSearch,
                  manager: manager,
                  downloadService: downloadService,
                  bottomReserve: bottomReserve,
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSectionHeader(String title, {double topPadding = 10}) {
    return Padding(
      padding: EdgeInsets.fromLTRB(8, topPadding, 8, 0),
      child: Row(
        children: [
          CupertinoButton(
            padding: EdgeInsets.zero,
            minimumSize: const Size(34, 34),
            onPressed: _goBackToLibraryList,
            child: Icon(
              CupertinoIcons.chevron_left,
              color: CupertinoColors.label.resolveFrom(context),
            ),
          ),
          const SizedBox(width: 4),
          Text(
            title,
            style: TextStyle(
              fontFamily: '.SF Pro Display',
              fontSize: 24,
              fontWeight: FontWeight.w700,
              color: CupertinoColors.label.resolveFrom(context),
            ),
          ),
        ],
      ),
    );
  }

  void _goBackToLibraryList() {
    _setLibraryAppBarHidden(false);
    setState(() {
      _isForwardTransition = false;
      _selectedLibraryAlbum = null;
      _selectedSection = null;
      _searchController.clear();
      _searchQuery = '';
    });
  }

  void _closeEmbeddedLibraryAlbum() {
    setState(() {
      _isForwardTransition = false;
      _selectedLibraryAlbum = null;
    });
  }

  void _openLibrarySection(_LibrarySection section) {
    _setLibraryAppBarHidden(section == _LibrarySection.albumes);
    setState(() {
      _isForwardTransition = true;
      _selectedSection = section;
    });
  }

  void _setLibraryAppBarHidden(bool value) {
    context.read<SearchViewState>().setLibraryAlbumFullscreen(value);
  }

  double _albumsHeaderTopPadding(BuildContext context) {
    return MediaQuery.of(context).padding.top + 10;
  }

  Widget _buildDownloadsList({
    required BuildContext context,
    required List<DownloadedVideo> songs,
    required bool allSongsEmpty,
    required bool hasSearch,
    required VideoPlayerManager manager,
    required DownloadService downloadService,
    required double bottomReserve,
  }) {
    if (allSongsEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 180),
          const Center(child: Text('Aún no has descargado música.')),
          SizedBox(height: bottomReserve),
        ],
      );
    }

    if (songs.isEmpty && hasSearch) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 180),
          const Center(
            child: Text('No encontramos canciones con esa búsqueda.'),
          ),
          SizedBox(height: bottomReserve),
        ],
      );
    }

    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(12, 2, 12, 20 + bottomReserve),
      itemCount: songs.length,
      itemBuilder: (context, index) {
        final song = songs[index];
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final cardColor = isDark
            ? Colors.black
            : CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
                context,
              );
        final cardBorder = isDark
            ? Colors.white.withValues(alpha: 0.12)
            : CupertinoColors.separator
                  .resolveFrom(context)
                  .withValues(alpha: 0.12);
        final localThumbPath = song.localThumbnailPath?.trim() ?? '';
        final hasLocalThumb = localThumbPath.isNotEmpty;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2.0),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Material(
              color: cardColor,
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () async {
                  final local = await downloadService
                      .resolvePlayableDownloadedVideo(song.videoId);
                  if (!context.mounted) return;
                  if (local == null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'No se encontró el archivo local de esta descarga.',
                        ),
                      ),
                    );
                    return;
                  }
                  final localThumb = local.localThumbnailPath?.trim() ?? '';
                  await manager.playLocalFileFromUserSelection(
                    context,
                    id: local.videoId,
                    filePath: local.filePath,
                    title: local.title,
                    thumbnailUrl: localThumb.isNotEmpty
                        ? localThumb
                        : local.thumbnailUrl,
                    artist: local.channelTitle,
                    localPlainLyrics: local.plainLyrics,
                    localSyncedLyrics: local.syncedLyrics,
                  );
                },
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: cardBorder, width: 0.5),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12.0,
                    vertical: 5.0,
                  ),
                  child: Row(
                    children: [
                      hasLocalThumb
                          ? SquareThumbnail.file(
                              filePath: localThumbPath,
                              size: 64,
                              borderRadius: 10,
                              fallback: Container(
                                width: 64,
                                height: 64,
                                color: CupertinoColors.tertiarySystemFill
                                    .resolveFrom(context),
                                alignment: Alignment.center,
                                child: const Icon(CupertinoIcons.music_note),
                              ),
                            )
                          : SquareThumbnail.network(
                              imageUrl: song.thumbnailUrl,
                              size: 64,
                              borderRadius: 10,
                              fallback: Container(
                                width: 64,
                                height: 64,
                                color: CupertinoColors.tertiarySystemFill
                                    .resolveFrom(context),
                                alignment: Alignment.center,
                                child: const Icon(CupertinoIcons.music_note),
                              ),
                            ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              song.title,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.bold),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              song.channelTitle,
                              style: TextStyle(
                                color: CupertinoColors.secondaryLabel
                                    .resolveFrom(context),
                                fontSize: 12,
                                fontFamily: '.SF Pro Text',
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(
                          CupertinoIcons.delete,
                          color: CupertinoColors.systemRed,
                        ),
                        tooltip: 'Eliminar descarga',
                        onPressed: () async {
                          await downloadService.deleteVideo(song.videoId);
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Canción eliminada de descargas.'),
                            ),
                          );
                        },
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

class _LibraryEdgeSwipeBack extends StatefulWidget {
  final Widget child;
  final VoidCallback onBack;

  const _LibraryEdgeSwipeBack({required this.child, required this.onBack});

  @override
  State<_LibraryEdgeSwipeBack> createState() => _LibraryEdgeSwipeBackState();
}

class _LibraryEdgeSwipeBackState extends State<_LibraryEdgeSwipeBack> {
  static const double _edgeWidth = 24;
  static const double _distanceThreshold = 72;
  static const double _velocityThreshold = 540;

  double _dragDistance = 0;
  bool _fired = false;

  void _resetGesture() {
    _dragDistance = 0;
    _fired = false;
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: _edgeWidth,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: (_) {
              _dragDistance = 0;
              _fired = false;
            },
            onHorizontalDragUpdate: (details) {
              if (_fired) return;
              final delta = details.primaryDelta ?? 0;
              if (delta > 0) {
                _dragDistance += delta;
              } else if (_dragDistance > 0) {
                _dragDistance = (_dragDistance + delta).clamp(
                  0,
                  double.infinity,
                );
              }
            },
            onHorizontalDragEnd: (details) {
              if (_fired) return;
              final velocity = details.primaryVelocity ?? 0;
              final shouldBack =
                  _dragDistance >= _distanceThreshold ||
                  velocity >= _velocityThreshold;
              if (shouldBack) {
                _fired = true;
                widget.onBack();
              }
              _resetGesture();
            },
            onHorizontalDragCancel: _resetGesture,
          ),
        ),
      ],
    );
  }
}
