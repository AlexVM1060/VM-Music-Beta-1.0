import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:myapp/models/downloaded_video.dart';
import 'package:myapp/models/playlist.dart';
import 'package:myapp/services/download_service.dart';
import 'package:myapp/services/playlist_service.dart';
import 'package:myapp/video_player_manager.dart';
import 'package:myapp/widgets/square_thumbnail.dart';
import 'package:provider/provider.dart';

class PlaylistsPage extends StatefulWidget {
  final ValueChanged<Playlist>? onOpenPlaylist;
  final VoidCallback? onBack;
  final bool useSafeArea;

  const PlaylistsPage({
    super.key,
    this.onOpenPlaylist,
    this.onBack,
    this.useSafeArea = true,
  });

  @override
  State<PlaylistsPage> createState() => _PlaylistsPageState();
}

class _PlaylistsPageState extends State<PlaylistsPage> {
  late Future<List<Playlist>> _playlistsFuture;

  double _accountBottomOverlayReserve(
    BuildContext context, {
    required bool hasMiniPlayer,
  }) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    const baseReserve = 108.0;
    const miniPlayerReserve = 64.0;
    return baseReserve + (hasMiniPlayer ? miniPlayerReserve : 0) + bottomInset;
  }

  @override
  void initState() {
    super.initState();
    _loadPlaylists();
  }

  void _loadPlaylists() {
    setState(() {
      _playlistsFuture = Provider.of<PlaylistService>(
        context,
        listen: false,
      ).getPlaylists();
    });
  }

  void _createPlaylist() {
    final controller = TextEditingController();
    showCupertinoDialog(
      context: context,
      builder: (context) {
        return CupertinoAlertDialog(
          title: const Text('Nueva playlist'),
          content: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: CupertinoTextField(
              controller: controller,
              autofocus: true,
              placeholder: 'Nombre de la playlist',
              textCapitalization: TextCapitalization.words,
              style: const TextStyle(fontFamily: '.SF Pro Text'),
            ),
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancelar'),
            ),
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () async {
                if (controller.text.isEmpty) return;
                await Provider.of<PlaylistService>(
                  context,
                  listen: false,
                ).createPlaylist(controller.text);
                if (!context.mounted) return;
                Navigator.of(context).pop();
                _loadPlaylists();
              },
              child: const Text('Crear'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final downloadService = context.watch<DownloadService>();
    final hasMiniPlayer = context.select<VideoPlayerManager, bool>(
      (playerManager) =>
          playerManager.currentVideoId != null && playerManager.isMinimized,
    );

    return FutureBuilder<List<Playlist>>(
      future: _playlistsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CupertinoActivityIndicator(radius: 14));
        }
        if (snapshot.hasError) {
          return const Center(
            child: Text('No se pudieron cargar las playlists.'),
          );
        }

        final playlists = snapshot.data ?? const <Playlist>[];
        return FutureBuilder<List<DownloadedVideo>>(
          future: downloadService.getDownloadedVideos(),
          builder: (context, downloadedSnapshot) {
            final downloadedVideos =
                downloadedSnapshot.data ?? const <DownloadedVideo>[];
            final downloadedById = <String, DownloadedVideo>{
              for (final item in downloadedVideos) item.videoId: item,
            };

            final content = Column(
              children: [
                if (widget.onBack != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                    child: Row(
                      children: [
                        CupertinoButton(
                          padding: EdgeInsets.zero,
                          minimumSize: const Size(34, 34),
                          onPressed: widget.onBack,
                          child: Icon(
                            CupertinoIcons.chevron_left,
                            color: CupertinoColors.label.resolveFrom(context),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Tus playlists',
                            style: TextStyle(
                              fontFamily: '.SF Pro Display',
                              fontSize: 24,
                              fontWeight: FontWeight.w700,
                              color: CupertinoColors.label.resolveFrom(context),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    12,
                    widget.onBack != null ? 4 : 22,
                    12,
                    8,
                  ),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: CupertinoButton(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      minimumSize: const Size(30, 30),
                      color: CupertinoColors.tertiarySystemFill.resolveFrom(
                        context,
                      ),
                      borderRadius: BorderRadius.circular(12),
                      onPressed: _createPlaylist,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            CupertinoIcons.add,
                            size: 16,
                            color: CupertinoColors.systemPink.resolveFrom(
                              context,
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Text(
                            'Nueva playlist',
                            style: TextStyle(
                              fontFamily: '.SF Pro Text',
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: playlists.isEmpty
                      ? const Center(child: Text('No tienes playlists.'))
                      : ListView.builder(
                          padding: EdgeInsets.fromLTRB(
                            12,
                            14,
                            12,
                            _accountBottomOverlayReserve(
                              context,
                              hasMiniPlayer: hasMiniPlayer,
                            ),
                          ),
                          itemCount: playlists.length,
                          itemBuilder: (context, index) {
                            final isDark =
                                Theme.of(context).brightness == Brightness.dark;
                            final cardColor = isDark
                                ? Colors.black
                                : CupertinoColors
                                      .secondarySystemGroupedBackground
                                      .resolveFrom(context);
                            final cardBorder = isDark
                                ? Colors.white.withValues(alpha: 0.12)
                                : CupertinoColors.separator
                                      .resolveFrom(context)
                                      .withValues(alpha: 0.12);
                            final playlist = playlists[index];
                            final isFavorites =
                                PlaylistService.isFavoritesPlaylistName(
                                  playlist.name,
                                );
                            var cover = playlist.coverUrl?.trim();
                            String? localCoverPath =
                                (cover != null &&
                                    cover.isNotEmpty &&
                                    cover.startsWith('/') &&
                                    File(cover).existsSync())
                                ? cover
                                : null;

                            if (cover == null || cover.isEmpty) {
                              for (final video in playlist.videos) {
                                cover ??= video.thumbnailUrl;
                                final localPath = downloadedById[video.videoId]
                                    ?.localThumbnailPath;
                                if (localPath != null &&
                                    localPath.isNotEmpty &&
                                    File(localPath).existsSync()) {
                                  localCoverPath = localPath;
                                  break;
                                }
                              }
                            }

                            final fallback = Container(
                              color: CupertinoColors.tertiarySystemFill
                                  .resolveFrom(context),
                              alignment: Alignment.center,
                              child: Icon(
                                isFavorites
                                    ? CupertinoIcons.star_fill
                                    : CupertinoIcons.music_note_list,
                              ),
                            );

                            Widget artwork;
                            if ((cover == null || cover.isEmpty) &&
                                localCoverPath == null) {
                              artwork = fallback;
                            } else if (localCoverPath != null) {
                              artwork = SquareThumbnail.file(
                                filePath: localCoverPath,
                                size: 74,
                                borderRadius: 0,
                                fallback: cover == null || cover.isEmpty
                                    ? fallback
                                    : SquareThumbnail.network(
                                        imageUrl: cover,
                                        size: 74,
                                        borderRadius: 0,
                                        fallback: fallback,
                                      ),
                              );
                            } else {
                              artwork = SquareThumbnail.network(
                                imageUrl: cover!,
                                size: 74,
                                borderRadius: 0,
                                fallback: fallback,
                              );
                            }

                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(14),
                                child: Material(
                                  color: cardColor,
                                  surfaceTintColor: Colors.transparent,
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(14),
                                    onTap: () {
                                      if (widget.onOpenPlaylist != null) {
                                        widget.onOpenPlaylist!(playlist);
                                        return;
                                      }
                                      context
                                          .push('/playlist', extra: playlist)
                                          .then((_) => _loadPlaylists());
                                    },
                                    child: Container(
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(14),
                                        border: Border.all(
                                          color: cardBorder,
                                          width: 0.5,
                                        ),
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 5,
                                      ),
                                      child: Row(
                                        children: [
                                          ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              10,
                                            ),
                                            child: SizedBox(
                                              width: 64,
                                              height: 64,
                                              child: artwork,
                                            ),
                                          ),
                                          const SizedBox(width: 16),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  playlist.name,
                                                  maxLines: 2,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontFamily: '.SF Pro Text',
                                                    fontSize: 16,
                                                    fontWeight: FontWeight.w700,
                                                    letterSpacing: -0.1,
                                                  ),
                                                ),
                                                const SizedBox(height: 4),
                                                Text(
                                                  '${playlist.videos.length} canciones',
                                                  style: TextStyle(
                                                    fontFamily: '.SF Pro Text',
                                                    fontSize: 13,
                                                    color: CupertinoColors
                                                        .secondaryLabel
                                                        .resolveFrom(context),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Icon(
                                            CupertinoIcons.chevron_right,
                                            size: 18,
                                            color: CupertinoColors.tertiaryLabel
                                                .resolveFrom(context),
                                          ),
                                        ],
                                      ),
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

            final wrappedContent = widget.onBack == null
                ? content
                : _IosEdgeSwipeBack(onBack: widget.onBack!, child: content);
            if (!widget.useSafeArea) return wrappedContent;
            return SafeArea(bottom: false, child: wrappedContent);
          },
        );
      },
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
