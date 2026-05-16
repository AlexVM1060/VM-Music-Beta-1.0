import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive/hive.dart';
import 'package:myapp/models/playlist.dart';
import 'package:myapp/models/downloaded_video.dart';
import 'package:myapp/playlist_detail_page.dart';
import 'package:myapp/playlists_page.dart';
import 'package:myapp/search_page.dart';
import 'package:myapp/search_view_state.dart';
import 'package:myapp/services/download_service.dart';
import 'package:myapp/services/library_albums_service.dart';
import 'package:myapp/services/playlist_service.dart';
import 'package:myapp/video_player_manager.dart';
import 'package:myapp/widgets/app_back_circle_button.dart';
import 'package:myapp/widgets/favorites_star_badge.dart';
import 'package:myapp/widgets/ios_notice.dart';
import 'package:myapp/widgets/square_thumbnail.dart';
import 'package:provider/provider.dart';

enum _LibrarySection { playlist, albumes, videos, descargas }

class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key});

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  static const String _pinnedPlaylistsBoxName = 'library_pinned_playlists';
  static const String _pinnedPlaylistsKey = 'names';
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  _LibrarySection? _selectedSection;
  LibraryAlbum? _selectedLibraryAlbum;
  Playlist? _selectedPlaylist;
  bool _openedPlaylistFromPinnedShortcut = false;
  bool _isForwardTransition = true;
  List<String> _pinnedPlaylistNames = const <String>[];
  StreamSubscription<BoxEvent>? _pinnedPlaylistsSub;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_handleSearchChanged);
    unawaited(_loadPinnedPlaylists());
  }

  @override
  void dispose() {
    _pinnedPlaylistsSub?.cancel();
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

  Future<Box<dynamic>> get _pinnedPlaylistsBox async =>
      Hive.openBox<dynamic>(_pinnedPlaylistsBoxName);

  Future<void> _loadPinnedPlaylists() async {
    final box = await _pinnedPlaylistsBox;
    _pinnedPlaylistsSub?.cancel();
    _pinnedPlaylistsSub = box.watch(key: _pinnedPlaylistsKey).listen((_) {
      unawaited(_loadPinnedPlaylists());
    });
    final raw = box.get(_pinnedPlaylistsKey);
    final names = raw is List
        ? raw
              .map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .toList()
        : <String>[];
    if (!mounted) return;
    setState(() {
      _pinnedPlaylistNames = names;
    });
  }

  Future<void> _pinPlaylistShortcut(Playlist playlist) async {
    final name = playlist.name.trim();
    if (name.isEmpty) return;
    if (_pinnedPlaylistNames.any(
      (p) => p.toLowerCase() == name.toLowerCase(),
    )) {
      return;
    }
    final updated = <String>[name, ..._pinnedPlaylistNames];
    setState(() {
      _pinnedPlaylistNames = updated;
    });
    final box = await _pinnedPlaylistsBox;
    await box.put(_pinnedPlaylistsKey, updated);
  }

  Future<void> _unpinPlaylistShortcut(String playlistName) async {
    final normalized = playlistName.trim().toLowerCase();
    final updated = _pinnedPlaylistNames
        .where((name) => name.trim().toLowerCase() != normalized)
        .toList(growable: false);
    setState(() {
      _pinnedPlaylistNames = updated;
    });
    final box = await _pinnedPlaylistsBox;
    await box.put(_pinnedPlaylistsKey, updated);
  }

  Future<void> _openPinnedPlaylistByName(String playlistName) async {
    final service = context.read<PlaylistService>();
    final playlists = await service.getPlaylists();
    Playlist? target;
    for (final playlist in playlists) {
      if (playlist.name.toLowerCase() == playlistName.toLowerCase()) {
        target = playlist;
        break;
      }
    }
    if (!mounted || target == null) return;
    _setLibraryAppBarHidden(true);
    setState(() {
      _isForwardTransition = true;
      _selectedSection = _LibrarySection.playlist;
      _selectedPlaylist = target;
      _openedPlaylistFromPinnedShortcut = true;
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
        if (_selectedPlaylist != null) {
          final playlist = _selectedPlaylist!;
          return _LibraryEdgeSwipeBack(
            onBack: _closeEmbeddedPlaylist,
            child: PlaylistDetailPage(
              playlist: playlist,
              onBack: _closeEmbeddedPlaylist,
            ),
          );
        }
        return PlaylistsPage(
          onBack: _goBackToLibraryList,
          useSafeArea: true,
          onPinPlaylist: (playlist) {
            unawaited(_pinPlaylistShortcut(playlist));
          },
          onUnpinPlaylist: (playlist) {
            unawaited(_unpinPlaylistShortcut(playlist.name));
          },
          isPlaylistPinned: (playlist) {
            final normalized = playlist.name.trim().toLowerCase();
            return _pinnedPlaylistNames.any(
              (name) => name.trim().toLowerCase() == normalized,
            );
          },
          onOpenPlaylist: (playlist) {
            _setLibraryAppBarHidden(true);
            setState(() {
              _isForwardTransition = true;
              _selectedPlaylist = playlist;
              _openedPlaylistFromPinnedShortcut = false;
            });
          },
        );
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
    final accent = CupertinoColors.systemPink.resolveFrom(context);
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
        icon: CupertinoIcons.play_rectangle,
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

    return FutureBuilder<List<Playlist>>(
      future: context.read<PlaylistService>().getPlaylists(),
      builder: (context, snapshot) {
        final playlists = snapshot.data ?? const <Playlist>[];
        final byName = <String, Playlist>{
          for (final p in playlists) p.name.toLowerCase(): p,
        };

        final cards = <Widget>[
          if (_pinnedPlaylistNames.isNotEmpty)
            _buildPinnedPlaylistsStrip(byName: byName, accent: accent),
          ...sections.map((section) {
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
                        Icon(section.icon, size: 22, color: accent),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            section.title,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: CupertinoColors.label.resolveFrom(
                                    context,
                                  ),
                                ),
                          ),
                        ),
                        Icon(
                          CupertinoIcons.chevron_forward,
                          size: 16,
                          color: accent,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }),
        ];

        return ListView.separated(
          padding: EdgeInsets.fromLTRB(12, 14, 12, 14 + bottomReserve),
          itemBuilder: (context, index) => cards[index],
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemCount: cards.length,
        );
      },
    );
  }

  Widget _buildPinnedPlaylistCard({
    required String playlistName,
    required Playlist? playlist,
    required Color accent,
    double cardWidth = 110,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark
        ? Colors.black
        : CupertinoColors.secondarySystemGroupedBackground.resolveFrom(context);
    final border = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : CupertinoColors.separator
              .resolveFrom(context)
              .withValues(alpha: 0.12);

    final isFavorites = playlist != null
        ? PlaylistService.isFavoritesPlaylistName(playlist.name)
        : PlaylistService.isFavoritesPlaylistName(playlistName);
    final subtitle = playlist == null
        ? 'Playlist anclada'
        : isFavorites
        ? '${playlist.videos.length} canciones guardadas'
        : '${playlist.videos.length} canciones';
    final fallback = Container(
      color: CupertinoColors.tertiarySystemFill.resolveFrom(context),
      alignment: Alignment.center,
      child: Icon(
        isFavorites ? CupertinoIcons.star_fill : CupertinoIcons.music_note_list,
        color: accent,
      ),
    );

    Widget artwork = fallback;
    var cover = playlist?.coverUrl?.trim() ?? '';
    if (cover.isEmpty && playlist != null) {
      for (final video in playlist.videos) {
        final thumb = video.thumbnailUrl.trim();
        if (thumb.isNotEmpty) {
          cover = thumb;
          break;
        }
      }
    }
    if (cover.isNotEmpty) {
      if (cover.startsWith('/')) {
        artwork = SquareThumbnail.file(
          filePath: cover,
          size: 64,
          borderRadius: 10,
          fallback: fallback,
        );
      } else {
        artwork = SquareThumbnail.network(
          imageUrl: cover,
          size: 64,
          borderRadius: 10,
          fallback: fallback,
        );
      }
    }

    final tile = SizedBox(
      width: cardWidth,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Material(
          color: cardColor,
          surfaceTintColor: Colors.transparent,
          child: InkWell(
            onTap: () {
              unawaited(_openPinnedPlaylistByName(playlistName));
            },
            child: Container(
              decoration: BoxDecoration(
                color: cardColor,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: border, width: 0.6),
              ),
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Stack(
                    children: [
                      SizedBox(
                        width: 94,
                        height: 94,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: artwork,
                        ),
                      ),
                      Positioned(
                        top: 6,
                        right: 6,
                        child: Container(
                          padding: const EdgeInsets.all(5),
                          decoration: BoxDecoration(
                            color: accent,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            CupertinoIcons.pin_fill,
                            size: 12,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    playlistName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: '.SF Pro Text',
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: CupertinoColors.label.resolveFrom(context),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: '.SF Pro Text',
                      fontSize: 10,
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
    return tile;
  }

  Widget _buildPinnedPlaylistsStrip({
    required Map<String, Playlist> byName,
    required Color accent,
  }) {
    final visiblePinned = _pinnedPlaylistNames.take(6).toList(growable: false);
    final rowCount = ((visiblePinned.length + 2) ~/ 3).clamp(0, 2);
    const horizontalPadding = 4.0;
    const spacing = 10.0;
    const fallbackCardWidth = 110.0;
    const cardHeight = 144.0;
    const bottomSafetyGap = 12.0;
    final gridHeight = rowCount == 0
        ? 0.0
        : (rowCount * cardHeight) +
              ((rowCount - 1) * spacing) +
              bottomSafetyGap;
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth - (horizontalPadding * 2);
        final computedWidth = (available - (spacing * 2)) / 3;
        final cardWidth = computedWidth.isFinite && computedWidth > 60
            ? computedWidth
            : fallbackCardWidth;

        return SizedBox(
          height: gridHeight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              horizontalPadding,
              0,
              horizontalPadding,
              bottomSafetyGap,
            ),
            child: Stack(
              children: [
                for (var index = 0; index < visiblePinned.length; index++)
                  AnimatedPositioned(
                    key: ValueKey('pinned_pos_${visiblePinned[index]}'),
                    duration: const Duration(milliseconds: 240),
                    curve: Curves.easeOutCubic,
                    left: (index % 3) * (cardWidth + spacing),
                    top: (index ~/ 3) * (cardHeight + spacing),
                    width: cardWidth,
                    height: cardHeight,
                    child: _PinnedShortcutDraggableCard(
                      key: ValueKey('pinned_${visiblePinned[index]}'),
                      playlistName: visiblePinned[index],
                      cardWidth: cardWidth,
                      child: _buildPinnedPlaylistCard(
                        playlistName: visiblePinned[index],
                        playlist: byName[visiblePinned[index].toLowerCase()],
                        accent: accent,
                        cardWidth: cardWidth,
                      ),
                      onOpen: () {
                        unawaited(
                          _openPinnedPlaylistByName(visiblePinned[index]),
                        );
                      },
                      onUnpin: () {
                        unawaited(_unpinPlaylistShortcut(visiblePinned[index]));
                      },
                      onReorder: (from, to) {
                        final current = List<String>.from(_pinnedPlaylistNames);
                        final fromIndex = current.indexOf(from);
                        final toIndex = current.indexOf(to);
                        if (fromIndex < 0 ||
                            toIndex < 0 ||
                            fromIndex == toIndex) {
                          return;
                        }
                        final moved = current.removeAt(fromIndex);
                        current.insert(toIndex, moved);
                        HapticFeedback.selectionClick();
                        setState(() {
                          _pinnedPlaylistNames = current;
                        });
                        unawaited(
                          _pinnedPlaylistsBox.then(
                            (box) => box.put(_pinnedPlaylistsKey, current),
                          ),
                        );
                      },
                      canReorder: (from, to) {
                        final current = _pinnedPlaylistNames;
                        final fromIndex = current.indexOf(from);
                        final toIndex = current.indexOf(to);
                        return fromIndex >= 0 &&
                            toIndex >= 0 &&
                            fromIndex != toIndex;
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
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
        _buildSectionHeader(
          title,
          topPadding: _albumsHeaderTopPadding(context),
        ),
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
                  : CupertinoColors.secondarySystemGroupedBackground
                        .resolveFrom(context);
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
        _buildSectionHeader(
          'Descargas',
          topPadding: _albumsHeaderTopPadding(context),
        ),
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
                return const Center(
                  child: CupertinoActivityIndicator(radius: 14),
                );
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
    final themedLabel = CupertinoColors.label.resolveFrom(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(8, topPadding, 8, 0),
      child: Row(
        children: [
          AppBackCircleButton(onPressed: _goBackToLibraryList),
          const SizedBox(width: 4),
          Text(
            title,
            style: TextStyle(
              fontFamily: '.SF Pro Display',
              fontSize: 24,
              fontWeight: FontWeight.w700,
              color: themedLabel,
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
      _selectedPlaylist = null;
      _openedPlaylistFromPinnedShortcut = false;
      _selectedSection = null;
      _searchController.clear();
      _searchQuery = '';
    });
  }

  void _closeEmbeddedPlaylist() {
    if (_openedPlaylistFromPinnedShortcut) {
      _goBackToLibraryList();
      return;
    }
    _setLibraryAppBarHidden(false);
    setState(() {
      _isForwardTransition = false;
      _selectedPlaylist = null;
      _openedPlaylistFromPinnedShortcut = false;
    });
  }

  void _closeEmbeddedLibraryAlbum() {
    setState(() {
      _isForwardTransition = false;
      _selectedLibraryAlbum = null;
    });
  }

  void _openLibrarySection(_LibrarySection section) {
    _setLibraryAppBarHidden(true);
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
                    showIosNotice(
                      context,
                      'No se encontró el archivo local de esta descarga.',
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
                      SizedBox(
                        width: 14,
                        child: Center(
                          child: FavoritesStarBadge(videoId: song.videoId),
                        ),
                      ),
                      const SizedBox(width: 6),
                      IconButton(
                        icon: const Icon(
                          CupertinoIcons.delete,
                          color: CupertinoColors.systemRed,
                        ),
                        tooltip: 'Eliminar descarga',
                        onPressed: () async {
                          await downloadService.deleteVideo(song.videoId);
                          if (!context.mounted) return;
                          showIosNotice(
                            context,
                            'Canción eliminada de descargas.',
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

class _PinnedShortcutDraggableCard extends StatefulWidget {
  final String playlistName;
  final double cardWidth;
  final Widget child;
  final VoidCallback onOpen;
  final VoidCallback onUnpin;
  final void Function(String from, String to) onReorder;
  final bool Function(String from, String to)? canReorder;

  const _PinnedShortcutDraggableCard({
    super.key,
    required this.playlistName,
    required this.cardWidth,
    required this.child,
    required this.onOpen,
    required this.onUnpin,
    required this.onReorder,
    this.canReorder,
  });

  @override
  State<_PinnedShortcutDraggableCard> createState() =>
      _PinnedShortcutDraggableCardState();
}

class _PinnedShortcutDraggableCardState
    extends State<_PinnedShortcutDraggableCard> {
  bool _isDragging = false;
  double _jigglePhase = -1.0;
  Timer? _jiggleTimer;
  String? _lastHoverSource;

  void _setDragging(bool value, {double? phase}) {
    if (!mounted) return;
    setState(() {
      _isDragging = value;
      if (phase != null) _jigglePhase = phase;
    });
  }

  void _startJiggle() {
    _jiggleTimer?.cancel();
    _jiggleTimer = Timer.periodic(const Duration(milliseconds: 110), (timer) {
      if (!mounted || !_isDragging) return;
      setState(() {
        _jigglePhase = _jigglePhase > 0 ? -1.0 : 1.0;
      });
    });
  }

  void _stopJiggle() {
    _jiggleTimer?.cancel();
    _jiggleTimer = null;
    if (!mounted) return;
    setState(() {
      _jigglePhase = 0.0;
    });
  }

  @override
  void dispose() {
    _jiggleTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) =>
          details.data.trim().isNotEmpty && details.data != widget.playlistName,
      onMove: (details) {
        final from = details.data;
        final to = widget.playlistName;
        if (from == to) return;
        if (!(widget.canReorder?.call(from, to) ?? true)) return;
        if (_lastHoverSource == from) return;
        _lastHoverSource = from;
        widget.onReorder(from, to);
      },
      onLeave: (_) {
        _lastHoverSource = null;
      },
      onAcceptWithDetails: (details) {
        _lastHoverSource = null;
        widget.onReorder(details.data, widget.playlistName);
      },
      builder: (context, candidateData, rejectedData) {
        final highlighted = candidateData.isNotEmpty;
        final jiggleAngle = _isDragging ? (_jigglePhase * 0.012) : 0.0;
        final card = AnimatedRotation(
          duration: const Duration(milliseconds: 100),
          turns: jiggleAngle / (2 * 3.141592653589793),
          child: AnimatedScale(
            duration: const Duration(milliseconds: 150),
            scale: highlighted ? 0.96 : 1.0,
            child: widget.child,
          ),
        );

        final interactiveCard = Draggable<String>(
          data: widget.playlistName,
          onDragStarted: () {
            _setDragging(true, phase: 1.0);
            HapticFeedback.lightImpact();
            _startJiggle();
          },
          onDragEnd: (details) {
            _setDragging(false);
            _stopJiggle();
          },
          onDraggableCanceled: (velocity, offset) {
            _setDragging(false);
            _stopJiggle();
          },
          onDragCompleted: () {
            _setDragging(false);
            _stopJiggle();
          },
          feedback: Material(
            type: MaterialType.transparency,
            child: Opacity(
              opacity: 0.92,
              child: SizedBox(width: widget.cardWidth, child: widget.child),
            ),
          ),
          childWhenDragging: Opacity(opacity: 0.35, child: card),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onOpen,
            child: card,
          ),
        );

        if (!Platform.isIOS && !Platform.isMacOS) return interactiveCard;
        return CupertinoContextMenu(
          enableHapticFeedback: true,
          actions: [
            CupertinoContextMenuAction(
              isDestructiveAction: true,
              trailingIcon: CupertinoIcons.pin_slash_fill,
              onPressed: () {
                Navigator.of(context).pop();
                widget.onUnpin();
              },
              child: const Text('Desanclar Playlist'),
            ),
          ],
          child: interactiveCard,
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
