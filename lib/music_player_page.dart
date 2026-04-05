import 'dart:math' as math;
import 'dart:ui' show FontFeature, ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:myapp/models/video_history.dart';
import 'package:myapp/models/playlist.dart';
import 'package:myapp/services/download_service.dart';
import 'package:myapp/services/playlist_service.dart';
import 'package:myapp/video_player_manager.dart';
import 'package:provider/provider.dart';

class MusicPlayerPage extends StatelessWidget {
  const MusicPlayerPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<VideoPlayerManager>(
      builder: (context, manager, child) {
        if (manager.currentVideoId == null) {
          return const SizedBox.shrink();
        }

        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 420),
          reverseDuration: const Duration(milliseconds: 320),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          layoutBuilder: (currentChild, previousChildren) {
            return Stack(
              children: [
                ...previousChildren,
                if (currentChild != null) currentChild,
              ],
            );
          },
          transitionBuilder: (child, animation) {
            final slide = Tween<Offset>(
              begin: const Offset(0, 0.08),
              end: Offset.zero,
            ).animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
            );
            final scale = Tween<double>(begin: 0.985, end: 1).animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOutQuart),
            );
            return FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: slide,
                child: ScaleTransition(scale: scale, child: child),
              ),
            );
          },
          child: manager.isMinimized
              ? _MiniPlayer(
                  key: const ValueKey('mini_player'),
                  manager: manager,
                )
              : _FullPlayer(
                  key: const ValueKey('full_player'),
                  manager: manager,
                ),
        );
      },
    );
  }
}

class _MiniPlayer extends StatelessWidget {
  final VideoPlayerManager manager;

  const _MiniPlayer({super.key, required this.manager});

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    const miniPlayerHeight = 56.0;
    const miniPlayerBottomNavReserve = 72.0;

    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          12,
          0,
          12,
          miniPlayerBottomNavReserve + bottomInset,
        ),
        child: ClipRRect(
          clipBehavior: Clip.antiAlias,
          borderRadius: BorderRadius.circular(22),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 34, sigmaY: 34),
            child: CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: manager.maximize,
              child: Container(
                height: miniPlayerHeight,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      CupertinoColors.systemBackground
                          .resolveFrom(context)
                          .withValues(alpha: 0.40),
                      CupertinoColors.systemGrey6
                          .resolveFrom(context)
                          .withValues(alpha: 0.28),
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: CupertinoColors.black.withValues(alpha: 0.08),
                      blurRadius: 22,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: [
                    _ArtworkImage(url: manager.trackThumbnailUrl, size: 44),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            manager.trackTitle ?? 'Reproduciendo',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: CupertinoTheme.of(context).textTheme.textStyle.copyWith(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                          Text(
                            manager.trackArtist ?? 'Artista desconocido',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: CupertinoTheme.of(context).textTheme.textStyle.copyWith(
                                  fontSize: 12,
                                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                                ),
                          ),
                        ],
                      ),
                    ),
                    CupertinoButton(
                      padding: EdgeInsets.zero,
                      onPressed: manager.togglePlayPause,
                      child: Icon(
                        manager.isPlaying
                            ? CupertinoIcons.pause_circle_fill
                            : CupertinoIcons.play_circle_fill,
                        size: 28,
                        color: CupertinoColors.label.resolveFrom(context),
                      ),
                    ),
                    const SizedBox(width: 6),
                    CupertinoButton(
                      padding: EdgeInsets.zero,
                      onPressed: manager.close,
                      child: Icon(
                        CupertinoIcons.xmark_circle_fill,
                        size: 22,
                        color: CupertinoColors.secondaryLabel.resolveFrom(context),
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

class _FullPlayer extends StatelessWidget {
  final VideoPlayerManager manager;

  const _FullPlayer({super.key, required this.manager});

  @override
  Widget build(BuildContext context) {
    final downloadService = context.watch<DownloadService>();
    final playlistService = context.read<PlaylistService>();
    final videoId = manager.currentVideoId;
    final canDownload = videoId != null && !manager.isLocal;
    final canAddToPlaylist = videoId != null;

    return SizedBox.expand(
      child: Material(
        color: Colors.transparent,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Theme.of(context).colorScheme.primaryContainer,
                Theme.of(context).colorScheme.surface,
                Theme.of(context).colorScheme.surface,
              ],
            ),
          ),
          child: SafeArea(
            child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    _TopGlassIconButton(
                      icon: CupertinoIcons.chevron_down,
                      onPressed: manager.minimize,
                    ),
                    const Spacer(),
                    _TopGlassLabelButton(
                      label: 'Lyrics',
                      onPressed: () => _showLyricsComingSoon(context),
                    ),
                    const SizedBox(width: 8),
                    if (canAddToPlaylist)
                      _TopGlassIconButton(
                        icon: CupertinoIcons.add,
                        onPressed: () => _showAddToPlaylistSheet(
                          context: context,
                          playlistService: playlistService,
                          manager: manager,
                        ),
                      ),
                    if (canDownload)
                      _DownloadButton(
                        videoId: videoId,
                        title: manager.trackTitle ?? 'Sin título',
                        thumbnailUrl: manager.trackThumbnailUrl ?? '',
                        channelTitle: manager.trackArtist ?? '',
                        sourceUrl: manager.currentStreamUrl,
                        isVideoSource: manager.isUsingVideoFallback,
                        downloadService: downloadService,
                      ),
                    _TopGlassIconButton(
                      icon: CupertinoIcons.xmark,
                      onPressed: manager.close,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
                  child: Column(
                    children: [
                      _ArtworkImage(url: manager.trackThumbnailUrl, size: 310),
                      const SizedBox(height: 28),
                      Text(
                        manager.trackTitle ?? 'Cargando canción...',
                        textAlign: TextAlign.center,
                        style: CupertinoTheme.of(context)
                            .textTheme
                            .navLargeTitleTextStyle
                            .copyWith(
                              fontSize: 34,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        manager.trackArtist ?? 'Artista desconocido',
                        textAlign: TextAlign.center,
                        style: CupertinoTheme.of(context)
                            .textTheme
                            .textStyle
                            .copyWith(
                              fontSize: 20,
                              color: CupertinoColors.secondaryLabel.resolveFrom(
                                context,
                              ),
                            ),
                      ),
                      if (manager.errorMessage != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          manager.errorMessage!,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: Theme.of(context).colorScheme.error,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      if (manager.isLoading)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 20),
                          child: CircularProgressIndicator(),
                        )
                      else ...[
                        _ProgressSection(manager: manager),
                        const SizedBox(height: 16),
                        _GlassControlsGroup(
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              _NativeControlButton(
                                icon: CupertinoIcons.backward_end_fill,
                                onPressed: () => manager.seekTo(
                                  manager.position - const Duration(seconds: 10),
                                ),
                              ),
                              _NativePrimaryPlayButton(
                                isPlaying: manager.isPlaying,
                                onPressed: manager.togglePlayPause,
                              ),
                              _NativeControlButton(
                                icon: CupertinoIcons.forward_end_fill,
                                onPressed: () => manager.seekTo(
                                  manager.position + const Duration(seconds: 10),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showAddToPlaylistSheet({
    required BuildContext context,
    required PlaylistService playlistService,
    required VideoPlayerManager manager,
  }) async {
    final playlists = await playlistService.getPlaylists();
    if (!context.mounted) return;

    if (playlists.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No hay playlists disponibles.')),
      );
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(
                title: Text(
                  'Añadir a playlist',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              ...playlists.map(
                (playlist) => ListTile(
                  leading: const Icon(Icons.queue_music),
                  title: Text(playlist.name),
                  subtitle: Text('${playlist.videos.length} canciones'),
                  onTap: () => _addCurrentTrackToPlaylist(
                    context: context,
                    sheetContext: sheetContext,
                    playlistService: playlistService,
                    manager: manager,
                    playlist: playlist,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _addCurrentTrackToPlaylist({
    required BuildContext context,
    required BuildContext sheetContext,
    required PlaylistService playlistService,
    required VideoPlayerManager manager,
    required Playlist playlist,
  }) async {
    final videoId = manager.currentVideoId;
    if (videoId == null) return;

    final track = VideoHistory(
      videoId: videoId,
      title: manager.trackTitle ?? 'Sin título',
      thumbnailUrl: manager.trackThumbnailUrl ?? '',
      channelTitle: manager.trackArtist ?? '',
      watchedAt: DateTime.now(),
    );

    await playlistService.addVideoToPlaylist(playlist.name, track);
    if (sheetContext.mounted) {
      Navigator.of(sheetContext).pop();
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Añadida a ${playlist.name}')),
      );
    }
  }

  void _showLyricsComingSoon(BuildContext context) {
    showCupertinoDialog<void>(
      context: context,
      builder: (context) {
        return CupertinoAlertDialog(
          title: const Text('Lyrics'),
          content: const Text('Próximamente podrás ver la letra sincronizada.'),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }
}

class _TopGlassIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;

  const _TopGlassIconButton({
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      padding: EdgeInsets.zero,
      onPressed: onPressed,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: CupertinoColors.systemGrey6.resolveFrom(context).withValues(alpha: 0.58),
          shape: BoxShape.circle,
          border: Border.all(
            color: CupertinoColors.white.withValues(alpha: 0.2),
            width: 0.5,
          ),
        ),
        child: Icon(
          icon,
          size: 18,
          color: CupertinoColors.label.resolveFrom(context),
        ),
      ),
    );
  }
}

class _TopGlassLabelButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;

  const _TopGlassLabelButton({
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      padding: EdgeInsets.zero,
      onPressed: onPressed,
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: CupertinoColors.systemGrey6.resolveFrom(context).withValues(alpha: 0.58),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: CupertinoColors.white.withValues(alpha: 0.2),
            width: 0.5,
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: CupertinoTheme.of(context).textTheme.textStyle.copyWith(
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
        ),
      ),
    );
  }
}

class _GlassControlsGroup extends StatelessWidget {
  final Widget child;

  const _GlassControlsGroup({required this.child});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(36),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: CupertinoColors.systemBackground.resolveFrom(context).withValues(alpha: 0.46),
            borderRadius: BorderRadius.circular(36),
            border: Border.all(
              color: CupertinoColors.white.withValues(alpha: 0.24),
              width: 0.5,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

class _NativeControlButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;

  const _NativeControlButton({
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      padding: EdgeInsets.zero,
      onPressed: onPressed,
      child: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: CupertinoColors.systemGrey5.resolveFrom(context).withValues(alpha: 0.62),
          shape: BoxShape.circle,
          border: Border.all(
            color: CupertinoColors.white.withValues(alpha: 0.22),
            width: 0.5,
          ),
        ),
        child: Icon(
          icon,
          size: 21,
          color: CupertinoColors.label.resolveFrom(context),
        ),
      ),
    );
  }
}

class _NativePrimaryPlayButton extends StatelessWidget {
  final bool isPlaying;
  final VoidCallback onPressed;

  const _NativePrimaryPlayButton({
    required this.isPlaying,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      padding: EdgeInsets.zero,
      onPressed: onPressed,
      child: Container(
        width: 74,
        height: 74,
        decoration: BoxDecoration(
          color: CupertinoColors.white.withValues(alpha: 0.97),
          shape: BoxShape.circle,
          border: Border.all(
            color: CupertinoColors.white.withValues(alpha: 0.34),
            width: 0.8,
          ),
          boxShadow: [
            BoxShadow(
              color: CupertinoColors.black.withValues(alpha: 0.16),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Icon(
          isPlaying ? CupertinoIcons.pause_fill : CupertinoIcons.play_fill,
          size: 34,
          color: CupertinoColors.black,
        ),
      ),
    );
  }
}

class _ProgressSection extends StatelessWidget {
  final VideoPlayerManager manager;

  const _ProgressSection({required this.manager});

  @override
  Widget build(BuildContext context) {
    final totalMs = manager.trackDuration.inMilliseconds;
    final safeTotal = math.max(
      1,
      math.max(
        totalMs,
        math.max(
          manager.position.inMilliseconds,
          manager.bufferedPosition.inMilliseconds,
        ),
      ),
    );
    final positionMs = manager.position.inMilliseconds.clamp(0, safeTotal);
    final bufferedMs = manager.bufferedPosition.inMilliseconds.clamp(
      positionMs,
      safeTotal,
    );
    final playedRatio = positionMs / safeTotal;
    final bufferedRatio = bufferedMs / safeTotal;

    return Column(
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: CupertinoColors.systemGrey6.resolveFrom(context).withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: CupertinoColors.white.withValues(alpha: 0.2),
                    width: 0.5,
                  ),
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final maxWidth = constraints.maxWidth;
                    final thumbLeft =
                        (maxWidth * playedRatio - 6).clamp(0.0, maxWidth - 12);

                    void seekByDx(double localDx) {
                      if (safeTotal <= 1) return;
                      final ratio = (localDx / maxWidth).clamp(0.0, 1.0);
                      manager.seekTo(
                        Duration(milliseconds: (safeTotal * ratio).round()),
                      );
                    }

                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (details) => seekByDx(details.localPosition.dx),
                      onHorizontalDragUpdate: (details) =>
                          seekByDx(details.localPosition.dx),
                      child: SizedBox(
                        height: 18,
                        child: Stack(
                          alignment: Alignment.centerLeft,
                          children: [
                            Container(
                              height: 5,
                              decoration: BoxDecoration(
                                color: CupertinoColors.systemGrey4
                                    .resolveFrom(context)
                                    .withValues(alpha: 0.52),
                                borderRadius: BorderRadius.circular(999),
                              ),
                            ),
                            FractionallySizedBox(
                              widthFactor: bufferedRatio,
                              child: Container(
                                height: 5,
                                decoration: BoxDecoration(
                                  color: CupertinoColors.systemGrey2
                                      .resolveFrom(context)
                                      .withValues(alpha: 0.72),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                              ),
                            ),
                            FractionallySizedBox(
                              widthFactor: playedRatio,
                              child: Container(
                                height: 5,
                                decoration: BoxDecoration(
                                  color: CupertinoColors.white.withValues(alpha: 0.96),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                              ),
                            ),
                            Positioned(
                              left: thumbLeft,
                              child: Container(
                                width: 12,
                                height: 12,
                                decoration: BoxDecoration(
                                  color: CupertinoColors.white,
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: CupertinoColors.black
                                          .withValues(alpha: 0.22),
                                      blurRadius: 8,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
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
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              _formatDuration(manager.position),
              style: CupertinoTheme.of(context).textTheme.textStyle.copyWith(
                    fontSize: 13,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
            ),
            Text(
              _formatDuration(Duration(milliseconds: safeTotal)),
              style: CupertinoTheme.of(context).textTheme.textStyle.copyWith(
                    fontSize: 13,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
            ),
          ],
        ),
      ],
    );
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (hours > 0) {
      return '$hours:$minutes:$seconds';
    }
    return '${duration.inMinutes}:$seconds';
  }
}

class _ArtworkImage extends StatelessWidget {
  final String? url;
  final double size;

  const _ArtworkImage({required this.url, required this.size});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: size,
        height: size,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: url == null || url!.isEmpty
            ? Icon(
                Icons.music_note_rounded,
                size: size * 0.4,
                color: Theme.of(context).colorScheme.primary,
              )
            : Image.network(
                url!,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => Icon(
                  Icons.music_note_rounded,
                  size: size * 0.4,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
      ),
    );
  }
}

class _DownloadButton extends StatelessWidget {
  final String videoId;
  final String title;
  final String thumbnailUrl;
  final String channelTitle;
  final String? sourceUrl;
  final bool isVideoSource;
  final DownloadService downloadService;

  const _DownloadButton({
    required this.videoId,
    required this.title,
    required this.thumbnailUrl,
    required this.channelTitle,
    required this.sourceUrl,
    required this.isVideoSource,
    required this.downloadService,
  });

  @override
  Widget build(BuildContext context) {
    final status = downloadService.getDownloadStatus(videoId);
    final hasSource = sourceUrl != null && sourceUrl!.isNotEmpty;

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        return FadeTransition(
          opacity: animation,
          child: ScaleTransition(scale: animation, child: child),
        );
      },
      child: switch (status) {
        DownloadStatus.downloading => _buildCupertinoStatusButton(
            key: const ValueKey('download_loading'),
            context: context,
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                value: downloadService.getDownloadProgress(videoId),
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            onPressed: null,
          ),
        DownloadStatus.downloaded => _buildCupertinoStatusButton(
            key: const ValueKey('download_done'),
            context: context,
            child: Icon(
              CupertinoIcons.check_mark_circled_solid,
              color: CupertinoColors.systemGreen.resolveFrom(context),
              size: 20,
            ),
            onPressed: null,
          ),
        DownloadStatus.error => _buildCupertinoStatusButton(
            key: const ValueKey('download_error'),
            context: context,
            child: Icon(
              CupertinoIcons.exclamationmark_circle_fill,
              color: CupertinoColors.systemRed.resolveFrom(context),
              size: 20,
            ),
            onPressed: () => _showDownloadErrorDialog(context),
          ),
        DownloadStatus.notDownloaded => _buildCupertinoStatusButton(
            key: const ValueKey('download_idle'),
            context: context,
            child: Icon(
              CupertinoIcons.arrow_down_circle,
              color: hasSource
                  ? CupertinoColors.label.resolveFrom(context)
                  : CupertinoColors.tertiaryLabel.resolveFrom(context),
              size: 20,
            ),
            onPressed: hasSource ? _triggerDownload : null,
          ),
      },
    );
  }

  void _triggerDownload() {
    final url = sourceUrl;
    if (url == null || url.isEmpty) return;
    downloadService.downloadFromPlaybackSource(
      videoId: videoId,
      title: title,
      thumbnailUrl: thumbnailUrl,
      channelTitle: channelTitle,
      sourceUrl: url,
      isVideoSource: isVideoSource,
    );
  }

  Widget _buildCupertinoStatusButton({
    required Key key,
    required BuildContext context,
    required Widget child,
    required VoidCallback? onPressed,
  }) {
    return CupertinoButton(
      key: key,
      padding: EdgeInsets.zero,
      minimumSize: const Size(34, 34),
      onPressed: onPressed,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: CupertinoColors.systemGrey6.resolveFrom(context).withValues(alpha: 0.58),
          shape: BoxShape.circle,
          border: Border.all(
            color: CupertinoColors.white.withValues(alpha: 0.2),
            width: 0.5,
          ),
        ),
        alignment: Alignment.center,
        child: child,
      ),
    );
  }

  void _showDownloadErrorDialog(BuildContext context) {
    final detail =
        downloadService.getDownloadError(videoId) ?? 'No se registró detalle del error.';
    showCupertinoDialog<void>(
      context: context,
      builder: (dialogContext) {
        return CupertinoAlertDialog(
          title: const Text('Error de descarga'),
          content: Text(detail),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cerrar'),
            ),
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () {
                Navigator.of(dialogContext).pop();
                _triggerDownload();
              },
              child: const Text('Reintentar'),
            ),
          ],
        );
      },
    );
  }
}
