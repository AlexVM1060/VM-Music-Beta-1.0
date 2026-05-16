import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:image_picker/image_picker.dart';
import 'package:myapp/models/downloaded_video.dart';
import 'package:myapp/models/playlist.dart';
import 'package:myapp/models/video_history.dart';
import 'package:myapp/services/download_service.dart';
import 'package:myapp/services/playlist_service.dart';
import 'package:myapp/search_view_state.dart';
import 'package:myapp/video_player_manager.dart';
import 'package:myapp/widgets/app_back_circle_button.dart';
import 'package:myapp/widgets/favorites_star_badge.dart';
import 'package:myapp/widgets/ios_notice.dart';
import 'package:myapp/widgets/playlist_picker_sheet.dart';
import 'package:myapp/widgets/queue_swipe_action_button.dart';
import 'package:myapp/widgets/square_thumbnail.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart'
    show YoutubeExplode;
import 'package:collection/collection.dart';

class PlaylistDetailPage extends StatefulWidget {
  final Playlist playlist;
  final VoidCallback? onBack;
  final bool readOnly;
  final Future<void> Function(Playlist playlist)? onSaveToMyPlaylists;
  final Future<bool> Function(Playlist playlist)? isAlreadySavedToMyPlaylists;

  const PlaylistDetailPage({
    super.key,
    required this.playlist,
    this.onBack,
    this.readOnly = false,
    this.onSaveToMyPlaylists,
    this.isAlreadySavedToMyPlaylists,
  });

  @override
  State<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends State<PlaylistDetailPage> {
  late Playlist _currentPlaylist;
  final YoutubeExplode _yt = YoutubeExplode();
  bool _autoSyncRunning = false;
  bool _savedToMyPlaylists = false;
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
      description: widget.playlist.description,
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
    unawaited(_syncSavedState());
  }

  Future<void> _syncSavedState() async {
    if (!widget.readOnly || widget.isAlreadySavedToMyPlaylists == null) return;
    final already = await widget.isAlreadySavedToMyPlaylists!(widget.playlist);
    if (!mounted) return;
    setState(() {
      _savedToMyPlaylists = already;
    });
  }

  @override
  void dispose() {
    _yt.close();
    super.dispose();
  }

  Rect _shareOriginFromContext(BuildContext context) {
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox != null && renderBox.hasSize) {
      return renderBox.localToGlobal(Offset.zero) & renderBox.size;
    }
    return const Rect.fromLTWH(1, 1, 1, 1);
  }

  Future<void> _addVideoToFavorites(VideoHistory video) async {
    final playlistService = context.read<PlaylistService>();
    final downloadService = context.read<DownloadService>();
    final videoManager = context.read<VideoPlayerManager>();
    await playlistService.addVideoToPlaylist(
      PlaylistService.favoritesPlaylistName,
      video,
    );
    await downloadService.autoDownloadIfEnabledUsingClone(
      PlaylistService.favoritesPlaylistName,
      video,
      videoManager: videoManager,
    );
    if (!mounted) return;
    _showQueueIosToast(
      context,
      message: 'Añadida a Favoritos',
      icon: CupertinoIcons.star_fill,
    );
  }

  Future<void> _removeVideoFromFavorites(String videoId) async {
    final cleanId = videoId.trim();
    if (cleanId.isEmpty) return;
    final playlistService = context.read<PlaylistService>();
    await playlistService.removeVideoFromPlaylist(
      PlaylistService.favoritesPlaylistName,
      cleanId,
    );
    if (!mounted) return;
    _showQueueIosToast(
      context,
      message: 'Eliminada de Favoritos',
      icon: CupertinoIcons.star_lefthalf_fill,
    );
  }

  Future<void> _addVideoToAnyPlaylist(VideoHistory video) async {
    final playlistService = context.read<PlaylistService>();
    final playlists = await playlistService.getPlaylists();
    if (!mounted || playlists.isEmpty) return;
    final selectedName = await showGlassPlaylistPickerSheet(
      context: context,
      playlists: playlists,
      subtitle: video.title,
    );
    if (!mounted || selectedName == null || selectedName.isEmpty) return;
    final downloadService = context.read<DownloadService>();
    final videoManager = context.read<VideoPlayerManager>();
    await playlistService.addVideoToPlaylist(selectedName, video);
    await downloadService.autoDownloadIfEnabledUsingClone(
      selectedName,
      video,
      videoManager: videoManager,
    );
    if (!mounted) return;
    _showQueueIosToast(
      context,
      message: PlaylistService.isFavoritesPlaylistName(selectedName)
          ? 'Añadida a Favoritos'
          : 'Añadida a $selectedName',
      icon: PlaylistService.isFavoritesPlaylistName(selectedName)
          ? CupertinoIcons.star_fill
          : CupertinoIcons.check_mark_circled_solid,
    );
  }

  Future<void> _shareVideoDeepLink(VideoHistory video) async {
    final videoId = video.videoId.trim();
    if (videoId.isEmpty) return;
    final title = video.title.trim();
    final artist = video.channelTitle.trim();
    final thumbnailUrl = video.thumbnailUrl.trim();
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

  Future<void> _openArtistFromVideo(VideoHistory video) async {
    final videoId = video.videoId.trim();
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
      Navigator.of(context).maybePop();
    } catch (_) {
      if (!mounted) return;
      showIosNotice(context, 'No se pudo abrir el perfil del artista.');
    }
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

    return _IosEdgeSwipeBack(
      onBack: _handleBackFromEdgeSwipe,
      child: Scaffold(
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
              ? AppBackCircleButton(onPressed: widget.onBack)
              : null,
          trailing: widget.readOnly && widget.onSaveToMyPlaylists != null
              ? CupertinoButton(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(34, 34),
                  onPressed: _savedToMyPlaylists
                      ? null
                      : () async {
                          await widget.onSaveToMyPlaylists!(_currentPlaylist);
                          if (!mounted) return;
                          setState(() {
                            _savedToMyPlaylists = true;
                          });
                        },
                  child: Icon(
                    _savedToMyPlaylists
                        ? CupertinoIcons.check_mark_circled_solid
                        : CupertinoIcons.add_circled_solid,
                    size: 22,
                    color: _savedToMyPlaylists
                        ? CupertinoColors.systemGreen.resolveFrom(context)
                        : CupertinoColors.activeBlue.resolveFrom(context),
                  ),
                )
              : (_isFavoritesPlaylist
                    ? null
                    : AppCircleOutlineIconButton(
                        onPressed: () => _openEditPlaylistPage(
                          playlistService: playlistService,
                          downloadService: downloadService,
                        ),
                        child: const Icon(CupertinoIcons.pencil, size: 19),
                      )),
        ),
        body: FutureBuilder<List<DownloadedVideo>>(
          future: downloadService.getDownloadedVideos(),
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const Center(
                child: CupertinoActivityIndicator(radius: 14),
              );
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
            final indexOffset = widget.readOnly ? 1 : 2;

            return ListView.builder(
              padding: EdgeInsets.only(bottom: _bottomOverlayReserve(context)),
              itemCount: isEmpty
                  ? (widget.readOnly ? 2 : 3)
                  : displayVideos.length + indexOffset,
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

                if (index == 1 && !widget.readOnly) {
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

                final videoIndex = index - indexOffset;
                final video = displayVideos[videoIndex];
                final downloadedVideo = downloadedVideos.firstWhereOrNull(
                  (v) => v.videoId == video.videoId,
                );
                final downloadStatus = downloadService.getDownloadStatus(
                  video.videoId,
                );
                final isDownloading =
                    downloadStatus == DownloadStatus.downloading;
                final isDownloaded =
                    downloadStatus == DownloadStatus.downloaded ||
                    downloadedVideo != null;
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
                  child: Slidable(
                    key: ValueKey(
                      'playlist_track_${video.videoId}_$videoIndex',
                    ),
                    startActionPane: ActionPane(
                      motion: const StretchMotion(),
                      extentRatio: 0.46,
                      dismissible: DismissiblePane(
                        onDismissed: () {},
                        closeOnCancel: true,
                        confirmDismiss: () async {
                          final added = _queuePlaylistVideo(
                            video,
                            downloadedVideo: downloadedVideo,
                            insertMode: ManualQueueInsertMode.next,
                          );
                          _showQueueIosToast(
                            context,
                            message: added
                                ? 'Se añadió como siguiente'
                                : 'Esta canción ya está en cola',
                            icon: added
                                ? CupertinoIcons.check_mark_circled_solid
                                : CupertinoIcons.info_circle_fill,
                          );
                          return false;
                        },
                      ),
                      children: [
                        QueueSwipeActionButton(
                          onTap: () {
                            final added = _queuePlaylistVideo(
                              video,
                              downloadedVideo: downloadedVideo,
                              insertMode: ManualQueueInsertMode.next,
                            );
                            _showQueueIosToast(
                              context,
                              message: added
                                  ? 'Se añadió como siguiente'
                                  : 'Esta canción ya está en cola',
                              icon: added
                                  ? CupertinoIcons.check_mark_circled_solid
                                  : CupertinoIcons.info_circle_fill,
                            );
                          },
                          baseColor: CupertinoColors.systemPink.resolveFrom(
                            context,
                          ),
                          icon: CupertinoIcons.text_insert,
                          label: 'Siguiente',
                        ),
                        QueueSwipeActionButton(
                          onTap: () {
                            final added = _queuePlaylistVideo(
                              video,
                              downloadedVideo: downloadedVideo,
                              insertMode: ManualQueueInsertMode.end,
                            );
                            _showQueueIosToast(
                              context,
                              message: added
                                  ? 'Se ha añadido a la cola'
                                  : 'Esta canción ya está en cola',
                              icon: added
                                  ? CupertinoIcons.check_mark_circled_solid
                                  : CupertinoIcons.info_circle_fill,
                            );
                          },
                          baseColor: CupertinoColors.systemBlue.resolveFrom(
                            context,
                          ),
                          icon: CupertinoIcons.text_append,
                          label: 'Al final',
                        ),
                      ],
                    ),
                    child: CupertinoContextMenu(
                      enableHapticFeedback: true,
                      actions: [
                        CupertinoContextMenuAction(
                          onPressed: () {},
                          child: _PlaylistContextQuickActionsRow(
                            videoId: video.videoId,
                            onFavorite: () {
                              Navigator.of(context).pop();
                              unawaited(_addVideoToFavorites(video));
                            },
                            onUnfavorite: () {
                              Navigator.of(context).pop();
                              unawaited(_removeVideoFromFavorites(video.videoId));
                            },
                            onQueueNext: () {
                              Navigator.of(context).pop();
                              final added = _queuePlaylistVideo(
                                video,
                                downloadedVideo: downloadedVideo,
                                insertMode: ManualQueueInsertMode.next,
                              );
                              _showQueueIosToast(
                                context,
                                message: added
                                    ? 'Se añadió como siguiente'
                                    : 'Esta canción ya está en cola',
                                icon: added
                                    ? CupertinoIcons.check_mark_circled_solid
                                    : CupertinoIcons.info_circle_fill,
                              );
                            },
                            onAddToPlaylist: () {
                              Navigator.of(context).pop();
                              unawaited(_addVideoToAnyPlaylist(video));
                            },
                            onShare: () {
                              Navigator.of(context).pop();
                              unawaited(_shareVideoDeepLink(video));
                            },
                          ),
                        ),
                        CupertinoContextMenuAction(
                          onPressed: () {
                            Navigator.of(context).pop();
                            final added = _queuePlaylistVideo(
                              video,
                              downloadedVideo: downloadedVideo,
                              insertMode: ManualQueueInsertMode.end,
                            );
                            _showQueueIosToast(
                              context,
                              message: added
                                  ? 'Se ha añadido a la cola'
                                  : 'Esta canción ya está en cola',
                              icon: added
                                  ? CupertinoIcons.check_mark_circled_solid
                                  : CupertinoIcons.info_circle_fill,
                            );
                          },
                          child: _PlaylistContextMenuActionContent(
                            label: 'Añadir al final',
                            icon: CupertinoIcons.text_append,
                          ),
                        ),
                        CupertinoContextMenuAction(
                          onPressed: () {
                            Navigator.of(context).pop();
                            unawaited(_openArtistFromVideo(video));
                          },
                          child: _PlaylistContextMenuActionContent(
                            label: 'Ir al artista',
                            icon: CupertinoIcons.person_crop_circle,
                          ),
                        ),
                        CupertinoContextMenuAction(
                          onPressed: () {
                            Navigator.of(context).pop();
                            showIosNotice(
                              context,
                              'Abrir álbum estará disponible aquí pronto.',
                            );
                          },
                          child: _PlaylistContextMenuActionContent(
                            label: 'Ir al álbum',
                            icon: CupertinoIcons.rectangle_stack_fill,
                          ),
                        ),
                        if (!widget.readOnly)
                          CupertinoContextMenuAction(
                            isDestructiveAction: true,
                            onPressed: () async {
                              Navigator.of(context).pop();
                              await _removeTrackFromPlaylistAndLocal(
                                video: video,
                                playlistService: playlistService,
                                downloadService: downloadService,
                              );
                            },
                            child: _PlaylistContextMenuActionContent(
                              label: 'Eliminar de la playlist',
                              icon: CupertinoIcons.trash,
                              destructive: true,
                            ),
                          ),
                      ],
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Material(
                          color: trackCardColor,
                          surfaceTintColor: Colors.transparent,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () async {
                              await _playPlaylistTrackAtIndex(
                                downloadService: downloadService,
                                videoManager: videoManager,
                                displayVideos: displayVideos,
                                downloadedById: downloadedById,
                                startIndex: videoIndex,
                              );
                            },
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                final previewWidth =
                                    (MediaQuery.of(context).size.width - 32)
                                        .clamp(240.0, 420.0)
                                        .toDouble();
                                final cardWidth = constraints.hasBoundedWidth
                                    ? double.infinity
                                    : previewWidth;
                                return Container(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: trackCardBorder,
                                      width: 0.6,
                                    ),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  child: SizedBox(
                                    width: cardWidth,
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            hasLocalThumb
                                                ? SquareThumbnail.file(
                                                    filePath: localThumbPath,
                                                    size: 56,
                                                    borderRadius: 10,
                                                    zoom: 1,
                                                    fallback: Container(
                                                      color: CupertinoColors
                                                          .tertiarySystemFill
                                                          .resolveFrom(context),
                                                      alignment:
                                                          Alignment.center,
                                                      child: const Icon(
                                                        CupertinoIcons
                                                            .music_note,
                                                      ),
                                                    ),
                                                  )
                                                : SquareThumbnail.network(
                                                    imageUrl:
                                                        video.thumbnailUrl,
                                                    size: 56,
                                                    borderRadius: 10,
                                                    zoom: 1,
                                                    fallback: Container(
                                                      color: CupertinoColors
                                                          .tertiarySystemFill
                                                          .resolveFrom(context),
                                                      alignment:
                                                          Alignment.center,
                                                      child: const Icon(
                                                        CupertinoIcons
                                                            .music_note,
                                                      ),
                                                    ),
                                                  ),
                                            const SizedBox(width: 8),
                                            ConstrainedBox(
                                              constraints: const BoxConstraints(
                                                maxWidth: 228,
                                              ),
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                children: [
                                                  Text(
                                                    video.title,
                                                    maxLines: 2,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                      fontFamily:
                                                          '.SF Pro Text',
                                                      fontSize: 13,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 2),
                                                  Text(
                                                    video.channelTitle,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      fontFamily:
                                                          '.SF Pro Text',
                                                      fontSize: 11,
                                                      color: CupertinoColors
                                                          .secondaryLabel
                                                          .resolveFrom(context),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                        SizedBox(
                                          width: 40,
                                          child: Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.end,
                                            children: [
                                              if (isDownloading)
                                                const CupertinoActivityIndicator(
                                                  radius: 8,
                                                )
                                              else if (isDownloaded)
                                                const Icon(
                                                  CupertinoIcons
                                                      .arrow_down_circle_fill,
                                                  size: 14,
                                                  color: CupertinoColors
                                                      .systemGreen,
                                                )
                                              else
                                                const SizedBox(width: 14),
                                              const SizedBox(width: 6),
                                              SizedBox(
                                                width: 14,
                                                child: Center(
                                                  child: FavoritesStarBadge(
                                                    videoId: video.videoId,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
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
      ),
    );
  }

  void _handleBackFromEdgeSwipe() {
    if (widget.onBack != null) {
      widget.onBack!();
      return;
    }
    Navigator.of(context).maybePop();
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
                  _showQueueIosToast(
                    context,
                    message: 'Auto-descarga desactivada.',
                    icon: CupertinoIcons.arrow_down_circle,
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
          if ((_currentPlaylist.description ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22),
              child: Text(
                _currentPlaylist.description!.trim(),
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: '.SF Pro Text',
                  fontSize: 13,
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              ),
            ),
          ],
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

  bool _queuePlaylistVideo(
    VideoHistory video, {
    required DownloadedVideo? downloadedVideo,
    ManualQueueInsertMode insertMode = ManualQueueInsertMode.end,
  }) {
    final videoManager = context.read<VideoPlayerManager>();
    return downloadedVideo != null
        ? videoManager.addLocalTrackToPlaybackQueue(
            videoId: downloadedVideo.videoId,
            title: downloadedVideo.title,
            thumbnailUrl:
                (downloadedVideo.localThumbnailPath != null &&
                    downloadedVideo.localThumbnailPath!.isNotEmpty)
                ? downloadedVideo.localThumbnailPath!
                : downloadedVideo.thumbnailUrl,
            artist: downloadedVideo.channelTitle,
            filePath: downloadedVideo.filePath,
            localPlainLyrics: downloadedVideo.plainLyrics,
            localSyncedLyrics: downloadedVideo.syncedLyrics,
            insertMode: insertMode,
          )
        : videoManager.addOnlineTrackToPlaybackQueue(
            videoId: video.videoId,
            title: video.title,
            thumbnailUrl: video.thumbnailUrl,
            artist: video.channelTitle,
            insertMode: insertMode,
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
      showIosNotice(context, 'Esta playlist no contiene canciones.');
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

  Future<void> _playPlaylistTrackAtIndex({
    required DownloadService downloadService,
    required VideoPlayerManager videoManager,
    required List<VideoHistory> displayVideos,
    required Map<String, DownloadedVideo> downloadedById,
    required int startIndex,
  }) async {
    if (displayVideos.isEmpty) return;
    final queueItems = await _buildPlaylistQueueItems(
      downloadService: downloadService,
      displayVideos: displayVideos,
      downloadedById: downloadedById,
    );
    if (queueItems.isEmpty) return;

    final safeStart = startIndex.clamp(0, queueItems.length - 1);
    final ordered = <PlaybackQueueItem>[
      ...queueItems.skip(safeStart),
      ...queueItems.take(safeStart),
    ];
    final first = ordered.first;
    final rest = ordered.skip(1).toList(growable: false);
    final queueLabel = 'Playlist · ${_currentPlaylist.name}';
    videoManager.replaceManualPlaybackQueue(rest, queueTitle: queueLabel);
    await videoManager.playQueueItem(first);
  }

  Future<void> _removeTrackFromPlaylistAndLocal({
    required VideoHistory video,
    required PlaylistService playlistService,
    required DownloadService downloadService,
  }) async {
    final wasDownloaded = await downloadService.isVideoDownloaded(
      video.videoId,
    );
    await downloadService.deleteVideo(video.videoId);
    await playlistService.removeVideoFromPlaylist(
      _currentPlaylist.name,
      video.videoId,
    );
    if (!mounted) return;
    setState(() {
      _currentPlaylist.videos.removeWhere((v) => v.videoId == video.videoId);
    });
    _showQueueIosToast(
      context,
      message: wasDownloaded
          ? 'Canción eliminada de playlist y descargas locales.'
          : 'Canción eliminada de la playlist.',
      icon: CupertinoIcons.check_mark_circled_solid,
    );
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

  Future<void> _openEditPlaylistPage({
    required PlaylistService playlistService,
    required DownloadService downloadService,
  }) async {
    final result = await Navigator.of(context).push<_PlaylistEditorResult>(
      CupertinoPageRoute<_PlaylistEditorResult>(
        builder: (_) => _EditPlaylistPage(
          initialPlaylist: _currentPlaylist,
          allowDelete: !_isFavoritesPlaylist,
        ),
      ),
    );
    if (!mounted || result == null) return;
    if (result.deleteRequested) {
      await _deletePlaylistAndLocalData(
        playlistService: playlistService,
        downloadService: downloadService,
      );
      return;
    }
    final trimmedName = result.name.trim();
    if (trimmedName.isEmpty) {
      _showQueueIosToast(
        context,
        message: 'Escribe un nombre válido.',
        icon: CupertinoIcons.exclamationmark_triangle_fill,
      );
      return;
    }
    try {
      final updated = await playlistService.updatePlaylistDetails(
        currentName: _currentPlaylist.name,
        newName: trimmedName,
        coverUrl: result.coverUrl,
        description: result.description,
      );
      if (!mounted) return;
      setState(() {
        _currentPlaylist = Playlist(
          name: updated.name,
          videos: List.from(_currentPlaylist.videos),
          coverUrl: updated.coverUrl,
          description: updated.description,
        );
      });
      _showQueueIosToast(
        context,
        message: 'Playlist actualizada correctamente.',
        icon: CupertinoIcons.check_mark_circled_solid,
      );
    } catch (e) {
      if (!mounted) return;
      _showQueueIosToast(
        context,
        message: e.toString().replaceFirst('Exception: ', ''),
        icon: CupertinoIcons.exclamationmark_triangle_fill,
      );
    }
  }

  Future<void> _deletePlaylistAndLocalData({
    required PlaylistService playlistService,
    required DownloadService downloadService,
  }) async {
    if (_isFavoritesPlaylist) {
      throw Exception('No se puede eliminar la playlist Favoritos');
    }

    final playlistName = _currentPlaylist.name;
    final videos = List<VideoHistory>.from(_currentPlaylist.videos);
    final coverPath = _currentPlaylist.coverUrl;

    await downloadService.setPlaylistAutoDownload(playlistName, false);
    for (final video in videos) {
      await downloadService.deleteVideo(video.videoId);
    }
    await playlistService.deletePlaylist(playlistName);
    await _deletePlaylistCoverIfOwned(coverPath);

    if (!mounted) return;
    if (widget.onBack != null) {
      widget.onBack!();
    } else {
      Navigator.of(context).maybePop();
    }
    if (!mounted) return;
    _showQueueIosToast(
      context,
      message: 'Playlist eliminada y descargas locales borradas.',
      icon: CupertinoIcons.trash_fill,
    );
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
    _showQueueIosToast(
      context,
      message: message,
      icon: CupertinoIcons.check_mark_circled_solid,
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
    final borderRadius = BorderRadius.circular(14);
    final primaryColor = const Color(0xFFE83C64);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isShuffleLabel = label.trim().toLowerCase() == 'aleatorio';
    final labelColor = (!isDark && isShuffleLabel)
        ? CupertinoColors.systemGrey
        : Colors.white;
    final iconColor = (!isDark && isShuffleLabel)
        ? CupertinoColors.systemGrey
        : Colors.white;
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
                Icon(icon, size: 14, color: iconColor),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontFamily: '.SF Pro Text',
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    color: labelColor,
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

class _PlaylistContextQuickActionsRow extends StatefulWidget {
  final String videoId;
  final VoidCallback onFavorite;
  final VoidCallback onUnfavorite;
  final VoidCallback onQueueNext;
  final VoidCallback onAddToPlaylist;
  final VoidCallback onShare;

  const _PlaylistContextQuickActionsRow({
    required this.videoId,
    required this.onFavorite,
    required this.onUnfavorite,
    required this.onQueueNext,
    required this.onAddToPlaylist,
    required this.onShare,
  });

  @override
  State<_PlaylistContextQuickActionsRow> createState() =>
      _PlaylistContextQuickActionsRowState();
}

class _PlaylistContextQuickActionsRowState
    extends State<_PlaylistContextQuickActionsRow> {
  bool _isFavorite = false;
  bool _isInAnyPlaylist = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadPlaylistMembershipFlags());
  }

  Future<void> _loadPlaylistMembershipFlags() async {
    final cleanId = widget.videoId.trim();
    if (cleanId.isEmpty) return;
    try {
      final playlistService = context.read<PlaylistService>();
      final playlists = await playlistService.getPlaylists();
      if (!mounted) return;
      var isFavorite = false;
      var isInAnyPlaylist = false;
      for (final playlist in playlists) {
        final containsVideo = playlist.videos.any((v) => v.videoId == cleanId);
        if (!containsVideo) continue;
        isInAnyPlaylist = true;
        if (PlaylistService.isFavoritesPlaylistName(playlist.name)) {
          isFavorite = true;
        }
      }
      if (!mounted) return;
      setState(() {
        _isFavorite = isFavorite;
        _isInAnyPlaylist = isInAnyPlaylist;
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final iconColor = CupertinoColors.systemGrey.resolveFrom(context);

    Widget quickButton({
      required IconData icon,
      required VoidCallback onTap,
      String? semanticLabel,
    }) {
      return CupertinoButton(
        padding: EdgeInsets.zero,
        minimumSize: const Size(36, 36),
        onPressed: onTap,
        child: Icon(
          icon,
          size: 24,
          color: iconColor,
          semanticLabel: semanticLabel,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          quickButton(
            icon: _isFavorite ? CupertinoIcons.star_fill : CupertinoIcons.star,
            onTap: () {
              final wasFavorite = _isFavorite;
              setState(() {
                _isFavorite = !wasFavorite;
                if (!wasFavorite) _isInAnyPlaylist = true;
              });
              if (wasFavorite) {
                widget.onUnfavorite();
              } else {
                widget.onFavorite();
              }
            },
            semanticLabel: 'Añadir a Favoritos',
          ),
          quickButton(
            icon: CupertinoIcons.text_insert,
            onTap: widget.onQueueNext,
            semanticLabel: 'Añadir como siguiente',
          ),
          quickButton(
            icon: _isInAnyPlaylist
                ? CupertinoIcons.check_mark
                : CupertinoIcons.plus,
            onTap: () {
              if (_isInAnyPlaylist) return;
              widget.onAddToPlaylist();
            },
            semanticLabel: _isInAnyPlaylist
                ? 'Ya está en playlist'
                : 'Añadir a playlist',
          ),
          quickButton(
            icon: CupertinoIcons.square_arrow_up,
            onTap: widget.onShare,
            semanticLabel: 'Compartir',
          ),
        ],
      ),
    );
  }
}

class _PlaylistContextMenuActionContent extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool destructive;

  const _PlaylistContextMenuActionContent({
    required this.label,
    required this.icon,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = destructive
        ? CupertinoColors.systemRed.resolveFrom(context)
        : (isDark ? CupertinoColors.white : CupertinoColors.black);
    final iconColor = destructive
        ? CupertinoColors.systemRed.resolveFrom(context)
        : CupertinoColors.systemGrey.resolveFrom(context);
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

class _PlaylistEditorResult {
  final String name;
  final String? coverUrl;
  final String? description;
  final bool deleteRequested;

  const _PlaylistEditorResult({
    required this.name,
    this.coverUrl,
    this.description,
    this.deleteRequested = false,
  });
}

class _EditPlaylistPage extends StatefulWidget {
  final Playlist initialPlaylist;
  final bool allowDelete;

  const _EditPlaylistPage({
    required this.initialPlaylist,
    required this.allowDelete,
  });

  @override
  State<_EditPlaylistPage> createState() => _EditPlaylistPageState();
}

class _EditPlaylistPageState extends State<_EditPlaylistPage> {
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  String? _coverPath;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialPlaylist.name);
    _descriptionController = TextEditingController(
      text: widget.initialPlaylist.description ?? '',
    );
    _coverPath = widget.initialPlaylist.coverUrl?.trim();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _pickCover() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 92,
      maxWidth: 2000,
      maxHeight: 2000,
    );
    if (picked == null || !mounted) return;
    final copiedPath = await _persistCoverImage(picked.path);
    if (!mounted) return;
    setState(() {
      _coverPath = copiedPath;
    });
  }

  Future<String> _persistCoverImage(String sourcePath) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final coverDir = Directory(p.join(docsDir.path, 'playlist_covers'));
    if (!await coverDir.exists()) {
      await coverDir.create(recursive: true);
    }
    final ext = p.extension(sourcePath).trim().toLowerCase();
    final safeExt = ext.isEmpty ? '.jpg' : ext;
    final safeName = _nameController.text
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    final fileName =
        '${safeName.isEmpty ? 'playlist' : safeName}_${DateTime.now().millisecondsSinceEpoch}$safeExt';
    final destination = File(p.join(coverDir.path, fileName));
    await File(sourcePath).copy(destination.path);
    return destination.path;
  }

  void _save() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(
      _PlaylistEditorResult(
        name: name,
        coverUrl: (_coverPath ?? '').trim().isEmpty ? null : _coverPath!.trim(),
        description: _descriptionController.text.trim(),
      ),
    );
  }

  Future<void> _requestDelete() async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('Eliminar playlist'),
        content: const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text(
            'Esto eliminará la playlist y también todas las descargas locales de sus canciones.',
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    Navigator.of(
      context,
    ).pop(const _PlaylistEditorResult(name: '', deleteRequested: true));
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = CupertinoColors.systemPink.resolveFrom(context);
    return Scaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground.resolveFrom(
        context,
      ),
      appBar: CupertinoNavigationBar(
        transitionBetweenRoutes: false,
        backgroundColor: CupertinoColors.systemGroupedBackground.resolveFrom(
          context,
        ),
        middle: const Text('Editar playlist'),
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text(
            'Cancelar',
            style: TextStyle(color: CupertinoColors.systemRed),
          ),
        ),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: _save,
          child: const Text(
            'Guardar',
            style: TextStyle(color: CupertinoColors.activeBlue),
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
          children: [
            const SizedBox(height: 4),
            Center(
              child: Container(
                width: 188,
                height: 188,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: isDark ? 0.42 : 0.18,
                      ),
                      blurRadius: 26,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: (_coverPath ?? '').isEmpty
                      ? Container(
                          color: CupertinoColors.tertiarySystemFill.resolveFrom(
                            context,
                          ),
                          alignment: Alignment.center,
                          child: Icon(
                            CupertinoIcons.music_note_list,
                            size: 52,
                            color: CupertinoColors.secondaryLabel.resolveFrom(
                              context,
                            ),
                          ),
                        )
                      : ((_coverPath!.startsWith('/') &&
                                File(_coverPath!).existsSync())
                            ? Image.file(File(_coverPath!), fit: BoxFit.cover)
                            : Image.network(
                                _coverPath!,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => Container(
                                  color: CupertinoColors.tertiarySystemFill
                                      .resolveFrom(context),
                                  alignment: Alignment.center,
                                  child: const Icon(CupertinoIcons.photo),
                                ),
                              )),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Center(
              child: CupertinoButton(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                borderRadius: BorderRadius.circular(20),
                color: CupertinoColors.tertiarySystemFill.resolveFrom(context),
                onPressed: _pickCover,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(CupertinoIcons.photo, size: 16, color: accent),
                    const SizedBox(width: 8),
                    Text(
                      (_coverPath ?? '').isEmpty
                          ? 'Agregar portada'
                          : 'Cambiar portada',
                      style: TextStyle(
                        fontFamily: '.SF Pro Text',
                        fontWeight: FontWeight.w600,
                        color: accent,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if ((_coverPath ?? '').isNotEmpty)
              Center(
                child: CupertinoButton(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  onPressed: () {
                    setState(() {
                      _coverPath = null;
                    });
                  },
                  child: const Text(
                    'Quitar portada',
                    style: TextStyle(color: CupertinoColors.systemRed),
                  ),
                ),
              ),
            const SizedBox(height: 6),
            CupertinoTextField(
              controller: _nameController,
              placeholder: 'Nombre de la playlist',
              textCapitalization: TextCapitalization.words,
              style: const TextStyle(
                fontFamily: '.SF Pro Text',
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
              placeholderStyle: TextStyle(
                fontFamily: '.SF Pro Text',
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              prefix: Padding(
                padding: const EdgeInsets.only(left: 10),
                child: Icon(
                  CupertinoIcons.music_note_list,
                  size: 18,
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              ),
              decoration: BoxDecoration(
                color: CupertinoColors.tertiarySystemFill.resolveFrom(context),
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            const SizedBox(height: 10),
            CupertinoTextField(
              controller: _descriptionController,
              placeholder: 'Agregar descripción (opcional)',
              maxLines: 4,
              minLines: 4,
              style: const TextStyle(fontFamily: '.SF Pro Text'),
              placeholderStyle: TextStyle(
                fontFamily: '.SF Pro Text',
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(
                color: CupertinoColors.tertiarySystemFill.resolveFrom(context),
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            if (widget.allowDelete) ...[
              const SizedBox(height: 18),
              CupertinoButton(
                color: const Color(0xFFFF2D2D),
                borderRadius: BorderRadius.circular(18),
                onPressed: _requestDelete,
                child: const Text(
                  'Eliminar playlist',
                  style: TextStyle(
                    color: CupertinoColors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _IosEdgeSwipeBack extends StatefulWidget {
  final Widget child;
  final VoidCallback onBack;

  const _IosEdgeSwipeBack({required this.child, required this.onBack});

  @override
  State<_IosEdgeSwipeBack> createState() => _IosEdgeSwipeBackState();
}

class _IosEdgeSwipeBackState extends State<_IosEdgeSwipeBack> {
  static const double _edgeWidth = 24;
  static const double _distanceThreshold = 72;
  static const double _velocityThreshold = 700;
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
  Timer(const Duration(milliseconds: 1900), () {
    entry.remove();
  });
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
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
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
