import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:myapp/models/downloaded_video.dart';
import 'package:myapp/models/playlist.dart';
import 'package:myapp/models/video_history.dart';
import 'package:myapp/services/download_service.dart';
import 'package:myapp/services/playlist_service.dart';
import 'package:myapp/video_player_manager.dart';
import 'package:myapp/widgets/square_thumbnail.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:collection/collection.dart';

class PlaylistDetailPage extends StatefulWidget {
  final Playlist playlist;
  final VoidCallback? onBack;

  const PlaylistDetailPage({super.key, required this.playlist, this.onBack});

  @override
  State<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends State<PlaylistDetailPage> {
  late Playlist _currentPlaylist;
  bool _autoSyncRunning = false;
  bool get _isFavoritesPlaylist {
    return PlaylistService.isFavoritesPlaylistName(_currentPlaylist.name);
  }

  @override
  void initState() {
    super.initState();
    _currentPlaylist = Playlist(
      name: widget.playlist.name,
      videos: List.from(widget.playlist.videos),
      coverUrl: widget.playlist.coverUrl,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final downloadService = context.read<DownloadService>();
      final videoManager = context.read<VideoPlayerManager>();
      if (downloadService.isPlaylistAutoDownload(_currentPlaylist.name)) {
        unawaited(
          _syncPlaylistAutoDownloads(
            downloadService: downloadService,
            videoManager: videoManager,
            showSnackBar: false,
          ),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final trackCardColor = isDark
        ? Colors.black
        : CupertinoColors.secondarySystemGroupedBackground.resolveFrom(context);
    final trackCardBorder = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : CupertinoColors.separator
              .resolveFrom(context)
              .withValues(alpha: 0.12);
    final playlistService = Provider.of<PlaylistService>(
      context,
      listen: false,
    );
    final downloadService = Provider.of<DownloadService>(context);
    final videoManager = Provider.of<VideoPlayerManager>(
      context,
      listen: false,
    );
    final isAutoDownload = downloadService.isPlaylistAutoDownload(
      _currentPlaylist.name,
    );

    return Scaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground.resolveFrom(
        context,
      ),
      appBar: CupertinoNavigationBar(
        transitionBetweenRoutes: false,
        backgroundColor: CupertinoColors.systemGroupedBackground
            .resolveFrom(context)
            .withValues(alpha: 0.92),
        border: Border(
          bottom: BorderSide(
            color: CupertinoColors.separator
                .resolveFrom(context)
                .withValues(alpha: 0.18),
            width: 0.0,
          ),
        ),
        leading: widget.onBack != null
            ? CupertinoButton(
                padding: EdgeInsets.zero,
                minimumSize: const Size(28, 28),
                onPressed: widget.onBack,
                child: const Icon(CupertinoIcons.back, size: 22),
              )
            : null,
        middle: Text(
          _currentPlaylist.name,
          style: const TextStyle(
            fontFamily: '.SF Pro Text',
            fontWeight: FontWeight.w700,
            fontSize: 17,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: _isFavoritesPlaylist
            ? null
            : CupertinoButton(
                padding: EdgeInsets.zero,
                minimumSize: const Size(28, 28),
                onPressed: () =>
                    _showEditPlaylistDialog(playlistService: playlistService),
                child: const Icon(CupertinoIcons.pencil, size: 20),
              ),
      ),
      body: FutureBuilder<List<DownloadedVideo>>(
        future: downloadService.getDownloadedVideos(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CupertinoActivityIndicator(radius: 14));
          }
          final downloadedVideos = snapshot.data!;
          final downloadedById = <String, DownloadedVideo>{
            for (final item in downloadedVideos) item.videoId: item,
          };
          final videos = _currentPlaylist.videos;
          final displayVideos = _isFavoritesPlaylist
              ? videos.reversed.toList(growable: false)
              : videos;
          final isEmpty = displayVideos.isEmpty;

          return ListView.builder(
            padding: EdgeInsets.only(bottom: _bottomOverlayReserve(context)),
            itemCount: isEmpty ? 3 : displayVideos.length + 2,
            itemBuilder: (context, index) {
              if (index == 0) {
                return _buildPlaylistCoverHeader(
                  context,
                  displayVideos: displayVideos,
                  downloadedById: downloadedById,
                  downloadService: downloadService,
                  videoManager: videoManager,
                );
              }

              if (index == 1) {
                return _buildAutoDownloadCard(
                  context: context,
                  downloadService: downloadService,
                  videoManager: videoManager,
                  isAutoDownload: isAutoDownload,
                );
              }

              if (isEmpty) {
                return const Padding(
                  padding: EdgeInsets.fromLTRB(12, 36, 12, 12),
                  child: Center(
                    child: Text('Esta playlist no contiene canciones.'),
                  ),
                );
              }

              final videoIndex = index - 2;
              final video = displayVideos[videoIndex];
              final downloadedVideo = downloadedVideos.firstWhereOrNull(
                (v) => v.videoId == video.videoId,
              );
              final localThumbPath = downloadedVideo?.localThumbnailPath;
              final hasLocalThumb =
                  localThumbPath != null &&
                  localThumbPath.isNotEmpty &&
                  File(localThumbPath).existsSync();

              return Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 2,
                ),
                child: Dismissible(
                  key: ValueKey('playlist_track_${video.videoId}_$videoIndex'),
                  direction: DismissDirection.startToEnd,
                  dismissThresholds: const {DismissDirection.startToEnd: 0.28},
                  confirmDismiss: (_) async {
                    final added = downloadedVideo != null
                        ? videoManager.addLocalTrackToPlaybackQueue(
                            videoId: downloadedVideo.videoId,
                            title: downloadedVideo.title,
                            thumbnailUrl:
                                (downloadedVideo.localThumbnailPath != null &&
                                    downloadedVideo
                                        .localThumbnailPath!
                                        .isNotEmpty)
                                ? downloadedVideo.localThumbnailPath!
                                : downloadedVideo.thumbnailUrl,
                            artist: downloadedVideo.channelTitle,
                            filePath: downloadedVideo.filePath,
                            localPlainLyrics: downloadedVideo.plainLyrics,
                            localSyncedLyrics: downloadedVideo.syncedLyrics,
                          )
                        : videoManager.addOnlineTrackToPlaybackQueue(
                            videoId: video.videoId,
                            title: video.title,
                            thumbnailUrl: video.thumbnailUrl,
                            artist: video.channelTitle,
                          );
                    if (context.mounted) {
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
                    return false;
                  },
                  background: Container(
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      color: CupertinoColors.systemGreen.withValues(
                        alpha: 0.18,
                      ),
                      border: Border.all(
                        color: CupertinoColors.systemGreen.withValues(
                          alpha: 0.36,
                        ),
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
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Material(
                      color: trackCardColor,
                      surfaceTintColor: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () async {
                          final local = await _resolveLocalVideoForPlayback(
                            downloadService: downloadService,
                            videoId: video.videoId,
                            cached: downloadedVideo,
                          );
                          if (!context.mounted) return;

                          if (local != null) {
                            final thumb =
                                (local.localThumbnailPath != null &&
                                    local.localThumbnailPath!.isNotEmpty)
                                ? local.localThumbnailPath!
                                : local.thumbnailUrl;
                            await videoManager.playLocalFileFromUserSelection(
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

                          await videoManager.playFromUserSelection(
                            context,
                            video.videoId,
                            preferredThumbnailUrl: video.thumbnailUrl,
                            preferredTitle: video.title,
                            preferredArtist: video.channelTitle,
                          );
                        },
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: trackCardBorder,
                              width: 0.5,
                            ),
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
                                      zoom: 1,
                                      fallback: Container(
                                        color: CupertinoColors
                                            .tertiarySystemFill
                                            .resolveFrom(context),
                                        alignment: Alignment.center,
                                        child: const Icon(
                                          CupertinoIcons.music_note,
                                        ),
                                      ),
                                    )
                                  : SquareThumbnail.network(
                                      imageUrl: video.thumbnailUrl,
                                      size: 64,
                                      borderRadius: 10,
                                      zoom: 1,
                                      fallback: Container(
                                        color: CupertinoColors
                                            .tertiarySystemFill
                                            .resolveFrom(context),
                                        alignment: Alignment.center,
                                        child: const Icon(
                                          CupertinoIcons.music_note,
                                        ),
                                      ),
                                    ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      video.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      video.channelTitle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: CupertinoColors.secondaryLabel
                                            .resolveFrom(context),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              _DownloadStatusIndicator(
                                status: downloadService.getDownloadStatus(
                                  video.videoId,
                                ),
                                progress: downloadService.getDownloadProgress(
                                  video.videoId,
                                ),
                                isDownloaded: downloadedVideo != null,
                                onPressed: downloadedVideo != null
                                    ? null
                                    : () async {
                                        if (downloadService.isDownloading(
                                          video.videoId,
                                        )) {
                                          if (!context.mounted) return;
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            const SnackBar(
                                              content: Text(
                                                'Esta canción ya se está descargando.',
                                              ),
                                            ),
                                          );
                                          return;
                                        }

                                        final alreadyDownloaded =
                                            await downloadService
                                                .isVideoDownloaded(
                                                  video.videoId,
                                                );
                                        if (alreadyDownloaded) {
                                          if (!context.mounted) return;
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            const SnackBar(
                                              content: Text(
                                                'Esta canción ya está descargada.',
                                              ),
                                            ),
                                          );
                                          return;
                                        }

                                        final started =
                                            await _downloadUsingLargePlayerMethod(
                                              downloadService: downloadService,
                                              videoManager: videoManager,
                                              video: video,
                                            );
                                        if (!context.mounted) return;
                                        if (!started) {
                                          final err = downloadService
                                              .getDownloadError(video.videoId);
                                          final fallbackMessage =
                                              downloadService.isDownloading(
                                                video.videoId,
                                              )
                                              ? 'La descarga ya está en curso.'
                                              : 'No se pudo iniciar la descarga.';
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            SnackBar(
                                              content: Text(
                                                err ?? fallbackMessage,
                                              ),
                                            ),
                                          );
                                        }
                                      },
                              ),
                              IconButton(
                                icon: const Icon(
                                  CupertinoIcons.delete,
                                  color: CupertinoColors.systemRed,
                                ),
                                onPressed: () async {
                                  final wasDownloaded = await downloadService
                                      .isVideoDownloaded(video.videoId);
                                  await downloadService.deleteVideo(
                                    video.videoId,
                                  );
                                  await playlistService.removeVideoFromPlaylist(
                                    _currentPlaylist.name,
                                    video.videoId,
                                  );

                                  if (!context.mounted) return;

                                  setState(() {
                                    _currentPlaylist.videos.removeWhere(
                                      (v) => v.videoId == video.videoId,
                                    );
                                  });
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        wasDownloaded
                                            ? 'Canción eliminada de la playlist y de descargas locales.'
                                            : 'Canción eliminada de la playlist.',
                                      ),
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
                ),
              );
            },
          );
        },
      ),
    );
  }

  double _bottomOverlayReserve(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    // Dejamos un margen más compacto para que la lista fluya visualmente
    // detrás del mini player/nav, sin crear un hueco grande al final.
    const baseReserve = 108.0;
    return baseReserve + bottomInset;
  }

  Widget _buildAutoDownloadCard({
    required BuildContext context,
    required DownloadService downloadService,
    required VideoPlayerManager videoManager,
    required bool isAutoDownload,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final subtitleColor = isDark
        ? Colors.white
        : CupertinoColors.secondaryLabel;
    final cardColor = isDark
        ? Colors.black
        : CupertinoColors.secondarySystemGroupedBackground.resolveFrom(context);
    final cardBorder = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : CupertinoColors.separator
              .resolveFrom(context)
              .withValues(alpha: 0.12);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Container(
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: cardBorder, width: 0.5),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              const Icon(CupertinoIcons.arrow_down_circle, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Descarga automática',
                      style: TextStyle(
                        fontFamily: '.SF Pro Text',
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Las nuevas canciones se descargan automáticamente',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: '.SF Pro Text',
                        fontSize: 12,
                        color: subtitleColor,
                      ),
                    ),
                  ],
                ),
              ),
              CupertinoSwitch(
                value: isAutoDownload,
                onChanged: (value) async {
                  await downloadService.setPlaylistAutoDownload(
                    _currentPlaylist.name,
                    value,
                  );
                  if (!context.mounted) return;
                  if (value) {
                    await _syncPlaylistAutoDownloads(
                      downloadService: downloadService,
                      videoManager: videoManager,
                      showSnackBar: true,
                    );
                    return;
                  }
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Auto-descarga desactivada.')),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPlaylistCoverHeader(
    BuildContext context, {
    required List<VideoHistory> displayVideos,
    required Map<String, DownloadedVideo> downloadedById,
    required DownloadService downloadService,
    required VideoPlayerManager videoManager,
  }) {
    final fallback = CupertinoColors.tertiarySystemFill.resolveFrom(context);
    final coverStroke = CupertinoColors.separator
        .resolveFrom(context)
        .withValues(alpha: 0.28);
    final coverFallbackIcon = CupertinoColors.secondaryLabel.resolveFrom(
      context,
    );
    final favoritesOverlay = CupertinoColors.systemBackground
        .resolveFrom(context)
        .withValues(alpha: 0.20);
    final favoritesBorder = CupertinoColors.systemBackground
        .resolveFrom(context)
        .withValues(alpha: 0.38);
    final favoritesIcon = CupertinoColors.label.resolveFrom(context);
    var cover = _currentPlaylist.coverUrl?.trim();
    String? localCoverPath =
        (cover != null &&
            cover.isNotEmpty &&
            cover.startsWith('/') &&
            File(cover).existsSync())
        ? cover
        : null;
    if (cover == null || cover.isEmpty) {
      for (final video in _currentPlaylist.videos) {
        cover ??= video.thumbnailUrl;
        final localPath = downloadedById[video.videoId]?.localThumbnailPath;
        if (localPath != null &&
            localPath.isNotEmpty &&
            File(localPath).existsSync()) {
          localCoverPath = localPath;
          break;
        }
      }
    }
    final hasLocalCover = localCoverPath != null;
    final coverSize = (MediaQuery.of(context).size.width * 0.54)
        .clamp(170.0, 228.0)
        .toDouble();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 2),
      child: Column(
        children: [
          Align(
            alignment: Alignment.center,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: Container(
                width: coverSize,
                height: coverSize,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: coverStroke, width: 0.8),
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (hasLocalCover)
                      SquareThumbnail.file(
                        filePath: localCoverPath,
                        size: coverSize,
                        borderRadius: 0,
                        zoom: 1,
                        fallback: Container(
                          color: fallback,
                          alignment: Alignment.center,
                          child: Icon(
                            CupertinoIcons.music_note_list,
                            size: 54,
                            color: coverFallbackIcon,
                          ),
                        ),
                      )
                    else if (cover != null && cover.isNotEmpty)
                      SquareThumbnail.network(
                        imageUrl: cover,
                        size: coverSize,
                        borderRadius: 0,
                        zoom: 1.34,
                        fallback: Container(
                          color: fallback,
                          alignment: Alignment.center,
                          child: Icon(
                            CupertinoIcons.music_note_list,
                            size: 54,
                            color: coverFallbackIcon,
                          ),
                        ),
                      )
                    else
                      Container(
                        color: fallback,
                        alignment: Alignment.center,
                        child: Icon(
                          CupertinoIcons.music_note_list,
                          size: 54,
                          color: coverFallbackIcon,
                        ),
                      ),
                    if (_isFavoritesPlaylist)
                      Center(
                        child: Container(
                          width: 84,
                          height: 84,
                          decoration: BoxDecoration(
                            color: favoritesOverlay,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: favoritesBorder,
                              width: 1,
                            ),
                          ),
                          child: Icon(
                            CupertinoIcons.star_fill,
                            color: favoritesIcon,
                            size: 38,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  _currentPlaylist.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: '.SF Pro Display',
                    fontWeight: FontWeight.w700,
                    fontSize: 24,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
              if (_isFavoritesPlaylist) ...[
                const SizedBox(width: 8),
                const Icon(
                  CupertinoIcons.star_fill,
                  size: 18,
                  color: Color(0xFFFFD24A),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _PlaylistActionButton(
                  icon: CupertinoIcons.play_fill,
                  label: 'Reproducir',
                  isPrimary: true,
                  onPressed: () async {
                    await _playPlaylistFromHeader(
                      downloadService: downloadService,
                      videoManager: videoManager,
                      displayVideos: displayVideos,
                      downloadedById: downloadedById,
                      shuffle: false,
                    );
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _PlaylistActionButton(
                  icon: CupertinoIcons.shuffle,
                  label: 'Aleatorio',
                  onPressed: () async {
                    await _playPlaylistFromHeader(
                      downloadService: downloadService,
                      videoManager: videoManager,
                      displayVideos: displayVideos,
                      downloadedById: downloadedById,
                      shuffle: true,
                    );
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<List<PlaybackQueueItem>> _buildPlaylistQueueItems({
    required DownloadService downloadService,
    required List<VideoHistory> displayVideos,
    required Map<String, DownloadedVideo> downloadedById,
  }) async {
    final items = <PlaybackQueueItem>[];
    for (final video in displayVideos) {
      final local = await _resolveLocalVideoForPlayback(
        downloadService: downloadService,
        videoId: video.videoId,
        cached: downloadedById[video.videoId],
      );
      final localPath = local?.filePath.trim() ?? '';
      final canPlayLocal = localPath.isNotEmpty && File(localPath).existsSync();
      if (canPlayLocal && local != null) {
        items.add(
          PlaybackQueueItem(
            videoId: local.videoId,
            title: local.title,
            thumbnailUrl:
                (local.localThumbnailPath != null &&
                    local.localThumbnailPath!.isNotEmpty)
                ? local.localThumbnailPath!
                : local.thumbnailUrl,
            artist: local.channelTitle,
            isLocal: true,
            localFilePath: local.filePath,
            localPlainLyrics: local.plainLyrics,
            localSyncedLyrics: local.syncedLyrics,
          ),
        );
      } else {
        items.add(
          PlaybackQueueItem(
            videoId: video.videoId,
            title: video.title,
            thumbnailUrl: video.thumbnailUrl,
            artist: video.channelTitle,
            isLocal: false,
          ),
        );
      }
    }
    return items;
  }

  Future<void> _playPlaylistFromHeader({
    required DownloadService downloadService,
    required VideoPlayerManager videoManager,
    required List<VideoHistory> displayVideos,
    required Map<String, DownloadedVideo> downloadedById,
    required bool shuffle,
  }) async {
    if (displayVideos.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Esta playlist no contiene canciones.')),
      );
      return;
    }
    final queueItems = await _buildPlaylistQueueItems(
      downloadService: downloadService,
      displayVideos: displayVideos,
      downloadedById: downloadedById,
    );
    if (queueItems.isEmpty) return;

    final ordered = List<PlaybackQueueItem>.from(queueItems);
    if (shuffle) {
      ordered.shuffle(math.Random());
    }

    final first = ordered.first;
    final rest = ordered.skip(1).toList(growable: false);
    final queueLabel = shuffle
        ? 'Aleatorio · ${_currentPlaylist.name}'
        : 'Playlist · ${_currentPlaylist.name}';
    videoManager.replaceManualPlaybackQueue(rest, queueTitle: queueLabel);
    await videoManager.playQueueItem(first);
  }

  Future<bool> _downloadUsingLargePlayerMethod({
    required DownloadService downloadService,
    required VideoPlayerManager videoManager,
    required VideoHistory video,
  }) async {
    try {
      return downloadService.downloadVideoUsingClone(
        video: video,
        videoManager: videoManager,
      );
    } catch (_) {
      return false;
    }
  }

  Future<DownloadedVideo?> _resolveLocalVideoForPlayback({
    required DownloadService downloadService,
    required String videoId,
    required DownloadedVideo? cached,
  }) async {
    if (cached != null) {
      final cachedPath = cached.filePath.trim();
      if (cachedPath.isNotEmpty && File(cachedPath).existsSync()) {
        return cached;
      }
    }
    return downloadService.resolvePlayableDownloadedVideo(videoId);
  }

  Future<void> _showEditPlaylistDialog({
    required PlaylistService playlistService,
  }) async {
    final nameController = TextEditingController(text: _currentPlaylist.name);
    String? errorText;
    var selectedCover = (_currentPlaylist.coverUrl ?? '').trim();
    final pendingDeletes = <String>{};

    try {
      await showCupertinoDialog<void>(
        context: context,
        builder: (dialogContext) {
          return StatefulBuilder(
            builder: (dialogContext, setDialogState) {
              final hasCover = selectedCover.isNotEmpty;
              final isLocalCover = hasCover && selectedCover.startsWith('/');
              final localFile = isLocalCover ? File(selectedCover) : null;
              final hasLocalFile = localFile != null && localFile.existsSync();

              return CupertinoAlertDialog(
                title: const Text('Editar playlist'),
                content: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Column(
                    children: [
                      CupertinoTextField(
                        controller: nameController,
                        autofocus: true,
                        placeholder: 'Nombre de la playlist',
                        textCapitalization: TextCapitalization.words,
                        style: const TextStyle(fontFamily: '.SF Pro Text'),
                      ),
                      const SizedBox(height: 10),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: SizedBox(
                          width: 88,
                          height: 88,
                          child: hasCover
                              ? (hasLocalFile
                                    ? Image.file(localFile, fit: BoxFit.cover)
                                    : (!isLocalCover
                                          ? Image.network(
                                              selectedCover,
                                              fit: BoxFit.cover,
                                              errorBuilder: (_, _, _) =>
                                                  Container(
                                                    color: CupertinoColors
                                                        .tertiarySystemFill
                                                        .resolveFrom(context),
                                                    alignment: Alignment.center,
                                                    child: const Icon(
                                                      CupertinoIcons.photo,
                                                    ),
                                                  ),
                                            )
                                          : Container(
                                              color: CupertinoColors
                                                  .tertiarySystemFill
                                                  .resolveFrom(context),
                                              alignment: Alignment.center,
                                              child: const Icon(
                                                CupertinoIcons.photo,
                                              ),
                                            )))
                              : Container(
                                  color: CupertinoColors.tertiarySystemFill
                                      .resolveFrom(context),
                                  alignment: Alignment.center,
                                  child: const Icon(CupertinoIcons.photo),
                                ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      CupertinoButton(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        minimumSize: const Size(30, 30),
                        onPressed: () async {
                          try {
                            final picker = ImagePicker();
                            final picked = await picker.pickImage(
                              source: ImageSource.gallery,
                              imageQuality: 92,
                            );
                            if (picked == null) return;
                            final copiedPath = await _persistPlaylistCoverImage(
                              pickedFilePath: picked.path,
                              playlistName: nameController.text.trim().isEmpty
                                  ? _currentPlaylist.name
                                  : nameController.text.trim(),
                            );
                            if (!dialogContext.mounted) return;
                            setDialogState(() {
                              if (selectedCover.startsWith('/')) {
                                pendingDeletes.add(selectedCover);
                              }
                              selectedCover = copiedPath;
                              errorText = null;
                            });
                          } catch (_) {
                            if (!dialogContext.mounted) return;
                            setDialogState(() {
                              errorText =
                                  'No se pudo seleccionar la imagen de la galería.';
                            });
                          }
                        },
                        child: const Text('Elegir de galería'),
                      ),
                      if (hasCover)
                        CupertinoButton(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          minimumSize: const Size(26, 26),
                          onPressed: () {
                            setDialogState(() {
                              if (selectedCover.startsWith('/')) {
                                pendingDeletes.add(selectedCover);
                              }
                              selectedCover = '';
                            });
                          },
                          child: const Text(
                            'Quitar portada',
                            style: TextStyle(color: CupertinoColors.systemRed),
                          ),
                        ),
                      if (errorText != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          errorText!,
                          style: const TextStyle(
                            color: CupertinoColors.systemRed,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                actions: [
                  CupertinoDialogAction(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: const Text('Cancelar'),
                  ),
                  CupertinoDialogAction(
                    isDefaultAction: true,
                    onPressed: () async {
                      final trimmedName = nameController.text.trim();
                      if (trimmedName.isEmpty) {
                        setDialogState(() {
                          errorText = 'Escribe un nombre válido.';
                        });
                        return;
                      }
                      try {
                        final updated = await playlistService
                            .updatePlaylistDetails(
                              currentName: _currentPlaylist.name,
                              newName: trimmedName,
                              coverUrl: selectedCover,
                            );
                        for (final path in pendingDeletes) {
                          if (path == updated.coverUrl) continue;
                          unawaited(_deletePlaylistCoverIfOwned(path));
                        }
                        if (!mounted) return;
                        setState(() {
                          _currentPlaylist = Playlist(
                            name: updated.name,
                            videos: List.from(_currentPlaylist.videos),
                            coverUrl: updated.coverUrl,
                          );
                        });
                        if (!dialogContext.mounted) return;
                        Navigator.of(dialogContext).pop();
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Playlist actualizada correctamente.',
                            ),
                          ),
                        );
                      } catch (e) {
                        setDialogState(() {
                          errorText = e.toString().replaceFirst(
                            'Exception: ',
                            '',
                          );
                        });
                      }
                    },
                    child: const Text('Guardar'),
                  ),
                ],
              );
            },
          );
        },
      );
    } finally {
      nameController.dispose();
    }
  }

  Future<String> _persistPlaylistCoverImage({
    required String pickedFilePath,
    required String playlistName,
  }) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final coverDir = Directory(p.join(docsDir.path, 'playlist_covers'));
    if (!await coverDir.exists()) {
      await coverDir.create(recursive: true);
    }

    final source = File(pickedFilePath);
    final ext = p.extension(pickedFilePath).trim().toLowerCase();
    final safeExt = ext.isEmpty ? '.jpg' : ext;
    final safeName = playlistName
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    final fileName =
        '${safeName.isEmpty ? 'playlist' : safeName}_${DateTime.now().millisecondsSinceEpoch}$safeExt';
    final destination = File(p.join(coverDir.path, fileName));
    await source.copy(destination.path);
    return destination.path;
  }

  Future<void> _deletePlaylistCoverIfOwned(String? maybePath) async {
    final path = (maybePath ?? '').trim();
    if (path.isEmpty || !path.startsWith('/')) return;
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final coverDir = Directory(
        p.normalize(p.join(docsDir.path, 'playlist_covers')),
      );
      final normalizedPath = p.normalize(path);
      if (!normalizedPath.startsWith(coverDir.path)) return;
      final file = File(normalizedPath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  Future<void> _syncPlaylistAutoDownloads({
    required DownloadService downloadService,
    required VideoPlayerManager videoManager,
    required bool showSnackBar,
  }) async {
    if (_autoSyncRunning) return;
    _autoSyncRunning = true;

    var queued = 0;
    var alreadyDownloaded = 0;
    var alreadyInProgress = 0;

    try {
      final summary = await downloadService.downloadPlaylistVideosUsingClone(
        _currentPlaylist.videos,
        videoManager: videoManager,
      );
      queued = summary.queued;
      alreadyDownloaded = summary.alreadyDownloaded;
      alreadyInProgress = summary.alreadyInProgress;
    } finally {
      _autoSyncRunning = false;
    }

    if (!mounted || !showSnackBar) return;
    final message = queued > 0
        ? 'Auto-descarga activa. $queued canciones en cola.'
        : alreadyInProgress > 0
        ? 'Auto-descarga activa. $alreadyInProgress ya se están descargando.'
        : alreadyDownloaded > 0
        ? 'Auto-descarga activa. Ya estaban descargadas.'
        : 'Auto-descarga activa.';
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _DownloadStatusIndicator extends StatelessWidget {
  final DownloadStatus status;
  final double progress;
  final bool isDownloaded;
  final VoidCallback? onPressed;

  const _DownloadStatusIndicator({
    required this.status,
    required this.progress,
    required this.isDownloaded,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    Widget child;

    if (isDownloaded || status == DownloadStatus.downloaded) {
      child = const Icon(
        CupertinoIcons.check_mark_circled_solid,
        color: CupertinoColors.systemGreen,
      );
    } else if (status == DownloadStatus.downloading) {
      child = SizedBox(
        width: 18,
        height: 18,
        child: CupertinoActivityIndicator.partiallyRevealed(
          progress: progress.clamp(0.0, 1.0),
          radius: 9,
        ),
      );
    } else if (status == DownloadStatus.error) {
      child = const Icon(
        CupertinoIcons.exclamationmark_circle,
        color: CupertinoColors.systemRed,
      );
    } else {
      child = Icon(
        CupertinoIcons.arrow_down_circle,
        color: onPressed == null
            ? CupertinoColors.tertiaryLabel.resolveFrom(context)
            : CupertinoColors.label.resolveFrom(context),
      );
    }

    return CupertinoButton(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      minimumSize: const Size(30, 30),
      onPressed:
          (status == DownloadStatus.downloading ||
              status == DownloadStatus.downloaded)
          ? null
          : onPressed,
      child: child,
    );
  }
}

class _PlaylistActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isPrimary;
  final VoidCallback onPressed;

  const _PlaylistActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.isPrimary = false,
  });

  @override
  Widget build(BuildContext context) {
    final border = CupertinoColors.separator
        .resolveFrom(context)
        .withValues(alpha: 0.32);
    final labelColor = isPrimary
        ? CupertinoColors.white
        : CupertinoColors.label.resolveFrom(context);

    return CupertinoButton(
      padding: EdgeInsets.zero,
      minimumSize: const Size(0, 44),
      onPressed: onPressed,
      child: Container(
        height: 42,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: border, width: 0.6),
          gradient: isPrimary
              ? const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF1DB954), Color(0xFF0C9C4A)],
                )
              : LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    CupertinoColors.systemGrey6
                        .resolveFrom(context)
                        .withValues(alpha: 0.88),
                    CupertinoColors.systemGrey5
                        .resolveFrom(context)
                        .withValues(alpha: 0.78),
                  ],
                ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: labelColor),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontFamily: '.SF Pro Text',
                fontWeight: FontWeight.w700,
                fontSize: 14,
                color: labelColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void _showQueueIosToast(
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
              child: _QueueIosToast(message: message, icon: icon),
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

class _QueueIosToast extends StatefulWidget {
  final String message;
  final IconData icon;

  const _QueueIosToast({required this.message, required this.icon});

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
    final background = CupertinoDynamicColor.resolve(
      CupertinoColors.systemGrey6.withValues(alpha: 0.96),
      context,
    );
    final border = CupertinoDynamicColor.resolve(
      CupertinoColors.separator.withValues(alpha: 0.32),
      context,
    );
    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(
        position: _slide,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: border, width: 0.6),
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
                  style: const TextStyle(
                    fontFamily: '.SF Pro Text',
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
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
