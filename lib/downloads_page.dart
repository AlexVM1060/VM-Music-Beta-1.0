import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:myapp/models/downloaded_video.dart';
import 'package:myapp/services/download_service.dart';
import 'package:myapp/video_player_manager.dart';
import 'package:myapp/widgets/square_thumbnail.dart';
import 'package:provider/provider.dart';

class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key});

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_handleSearchChanged);
  }

  @override
  void dispose() {
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

    return Scaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground.resolveFrom(
        context,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
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
      ),
    );
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
