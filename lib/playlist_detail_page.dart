import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:myapp/models/downloaded_video.dart';
import 'package:myapp/models/playlist.dart';
import 'package:myapp/models/video_history.dart';
import 'package:myapp/services/download_service.dart';
import 'package:myapp/services/playlist_service.dart';
import 'package:myapp/video_player_manager.dart';
import 'package:provider/provider.dart';
import 'package:collection/collection.dart';

class PlaylistDetailPage extends StatefulWidget {
  final Playlist playlist;
  final VoidCallback? onBack;

  const PlaylistDetailPage({
    super.key,
    required this.playlist,
    this.onBack,
  });

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
    final playlistService = Provider.of<PlaylistService>(context, listen: false);
    final downloadService = Provider.of<DownloadService>(context);
    final videoManager = Provider.of<VideoPlayerManager>(context, listen: false);
    final isAutoDownload = downloadService.isPlaylistAutoDownload(_currentPlaylist.name);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        leading: widget.onBack != null
            ? IconButton(
                icon: const Icon(CupertinoIcons.back),
                onPressed: widget.onBack,
              )
            : null,
        title: const SizedBox.shrink(),
      ),
      body: FutureBuilder<List<DownloadedVideo>>(
        future: downloadService.getDownloadedVideos(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final downloadedVideos = snapshot.data!;
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
                return _buildPlaylistCoverHeader(context);
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

              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                    child: Material(
                      color: Colors.white.withValues(alpha: 0.035),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () async {
                          final local = await downloadService.getDownloadedVideoById(
                            video.videoId,
                          );
                          if (!context.mounted) return;

                          if (local != null) {
                            await videoManager.playLocalFile(
                              id: local.videoId,
                              filePath: local.filePath,
                              title: local.title,
                              thumbnailUrl: local.thumbnailUrl,
                              artist: local.channelTitle,
                              localPlainLyrics: local.plainLyrics,
                              localSyncedLyrics: local.syncedLyrics,
                            );
                            return;
                          }

                          await videoManager.play(
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
                                borderRadius: BorderRadius.circular(10),
                                child: Image.network(
                                  video.thumbnailUrl,
                                  width: 64,
                                  height: 64,
                                  fit: BoxFit.cover,
                                  alignment: Alignment.center,
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
                                        color: Theme.of(context).textTheme.bodySmall?.color,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              _DownloadStatusIndicator(
                                status: downloadService.getDownloadStatus(video.videoId),
                                progress: downloadService.getDownloadProgress(video.videoId),
                                isDownloaded: downloadedVideo != null,
                                onPressed: downloadedVideo != null
                                    ? null
                                    : () async {
                                        if (downloadService.isDownloading(video.videoId)) {
                                          if (!context.mounted) return;
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            const SnackBar(
                                              content: Text('Esta canción ya se está descargando.'),
                                            ),
                                          );
                                          return;
                                        }

                                        final alreadyDownloaded = await downloadService
                                            .isVideoDownloaded(video.videoId);
                                        if (alreadyDownloaded) {
                                          if (!context.mounted) return;
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            const SnackBar(
                                              content: Text('Esta canción ya está descargada.'),
                                            ),
                                          );
                                          return;
                                        }

                                        final started = await _downloadUsingLargePlayerMethod(
                                          downloadService: downloadService,
                                          videoManager: videoManager,
                                          video: video,
                                        );
                                        if (!context.mounted) return;
                                        if (!started) {
                                          final err = downloadService.getDownloadError(video.videoId);
                                          final fallbackMessage = downloadService.isDownloading(video.videoId)
                                              ? 'La descarga ya está en curso.'
                                              : 'No se pudo iniciar la descarga.';
                                          ScaffoldMessenger.of(context).showSnackBar(
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
                                icon: const Icon(CupertinoIcons.delete, color: Colors.red),
                                onPressed: () async {
                                  final wasDownloaded = await downloadService
                                      .isVideoDownloaded(video.videoId);
                                  await downloadService.deleteVideo(video.videoId);
                                  await playlistService.removeVideoFromPlaylist(
                                    _currentPlaylist.name,
                                    video.videoId,
                                  );

                                  if (!context.mounted) return;

                                  setState(() {
                                    _currentPlaylist.videos
                                        .removeWhere((v) => v.videoId == video.videoId);
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
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
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                const Icon(CupertinoIcons.arrow_down_circle, size: 20),
                const SizedBox(width: 10),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
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
                          color: Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ),
                CupertinoSwitch(
                  value: isAutoDownload,
                  onChanged: (value) async {
                    await downloadService.setPlaylistAutoDownload(_currentPlaylist.name, value);
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
      ),
    );
  }

  Widget _buildPlaylistCoverHeader(BuildContext context) {
    final fallback = Theme.of(context).colorScheme.surfaceContainerHighest;
    final cover = _currentPlaylist.videos.isNotEmpty
        ? _currentPlaylist.videos.first.thumbnailUrl
        : null;
    final coverSize = (MediaQuery.of(context).size.width * 0.54).clamp(170.0, 228.0);
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
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.20),
                    width: 0.8,
                  ),
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (cover != null && cover.isNotEmpty)
                      Image.network(
                        cover,
                        fit: BoxFit.cover,
                        alignment: Alignment.center,
                      )
                    else
                      Container(
                        color: fallback,
                        alignment: Alignment.center,
                        child: const Icon(
                          CupertinoIcons.music_note_list,
                          size: 54,
                          color: Colors.white70,
                        ),
                      ),
                    if (_isFavoritesPlaylist)
                      Center(
                        child: Container(
                          width: 84,
                          height: 84,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.16),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.35),
                              width: 1,
                            ),
                          ),
                          child: const Icon(
                            CupertinoIcons.star_fill,
                            color: Colors.white,
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
        ],
      ),
    );
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
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
      child = const Icon(CupertinoIcons.check_mark_circled_solid, color: Colors.green);
    } else if (status == DownloadStatus.downloading) {
      child = SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(
          value: progress > 0 ? progress : null,
          strokeWidth: 2,
        ),
      );
    } else if (status == DownloadStatus.error) {
      child = const Icon(CupertinoIcons.exclamationmark_circle, color: Colors.red);
    } else {
      final isDark = Theme.of(context).brightness == Brightness.dark;
      child = Icon(
        CupertinoIcons.arrow_down_circle,
        color: onPressed == null
            ? (isDark ? Colors.white54 : Colors.black54)
            : (isDark ? Colors.white : Colors.black),
      );
    }

    return CupertinoButton(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      minimumSize: const Size(30, 30),
      onPressed: (status == DownloadStatus.downloading ||
              status == DownloadStatus.downloaded)
          ? null
          : onPressed,
      child: child,
    );
  }
}
