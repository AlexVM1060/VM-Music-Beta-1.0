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

    var dragAccumulated = 0.0;
    return SizedBox.expand(
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragUpdate: (details) {
          if (details.delta.dy <= 0) return;
          dragAccumulated += details.delta.dy;
          if (dragAccumulated >= 72) {
            manager.minimize();
            dragAccumulated = 0;
          }
        },
        onVerticalDragEnd: (details) {
          final velocity = details.primaryVelocity ?? 0;
          if (velocity > 720) {
            manager.minimize();
          }
          dragAccumulated = 0;
        },
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
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(top: 2, bottom: 6),
                  decoration: BoxDecoration(
                    color: CupertinoColors.systemGrey3.resolveFrom(context).withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
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
                      label: manager.autoplayEnabled ? 'Autoplay On' : 'Autoplay Off',
                      onPressed: manager.toggleAutoplay,
                    ),
                    const SizedBox(width: 8),
                    _TopGlassIconButton(
                      icon: CupertinoIcons.list_bullet,
                      onPressed: () => _showQueueSheet(context),
                    ),
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
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 420),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        transitionBuilder: (child, animation) {
                          final slide = Tween<Offset>(
                            begin: const Offset(0, 0.06),
                            end: Offset.zero,
                          ).animate(
                            CurvedAnimation(
                              parent: animation,
                              curve: Curves.easeOutCubic,
                            ),
                          );
                          return FadeTransition(
                            opacity: animation,
                            child: SlideTransition(position: slide, child: child),
                          );
                        },
                        child: manager.isLyricsLayout
                            ? _CompactNowPlayingHeader(
                                key: const ValueKey('compact_now_playing_header'),
                                manager: manager,
                              )
                            : _DefaultNowPlayingHero(
                                key: const ValueKey('default_now_playing_hero'),
                                manager: manager,
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
                      if (manager.isLyricsLayout) ...[
                        const SizedBox(height: 14),
                        _LyricsPanel(manager: manager),
                      ],
                      const SizedBox(height: 24),
                      if (manager.isLoading)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 20),
                          child: _IosLoadingControls(),
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
                                onPressed: manager.playPreviousInQueue,
                              ),
                              _NativePrimaryPlayButton(
                                isPlaying: manager.isPlaying,
                                onPressed: manager.togglePlayPause,
                              ),
                              _NativeControlButton(
                                icon: CupertinoIcons.forward_end_fill,
                                onPressed: manager.playNextInQueue,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: _InlineLyricsButton(
                            isActive: manager.isLyricsLayout,
                            onPressed: manager.toggleLyricsLayout,
                          ),
                        ),
                      ],
                      const SizedBox(height: 26),
                      _QueueSection(manager: manager),
                    ],
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

  Future<void> _showQueueSheet(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Consumer<VideoPlayerManager>(
            builder: (context, manager, _) {
              final queue = manager.playbackQueue;
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Cola de reproducción',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      manager.queueTitle,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    if (manager.isQueueLoading)
                      const _IosLoadingControls()
                    else if (queue.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text('No hay elementos en la cola por ahora.'),
                      )
                    else
                      Flexible(
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: queue.length,
                          itemBuilder: (context, index) {
                            final item = queue[index];
                            return _QueueRow(item: item, manager: manager);
                          },
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _InlineLyricsButton extends StatefulWidget {
  final bool isActive;
  final VoidCallback onPressed;

  const _InlineLyricsButton({
    required this.isActive,
    required this.onPressed,
  });

  @override
  State<_InlineLyricsButton> createState() => _InlineLyricsButtonState();
}

class _InlineLyricsButtonState extends State<_InlineLyricsButton>
    with TickerProviderStateMixin {
  AnimationController? _rainbowController;

  @override
  void initState() {
    super.initState();
    _ensureController();
  }

  @override
  void didUpdateWidget(covariant _InlineLyricsButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    _ensureController();
    if (oldWidget.isActive == widget.isActive) return;
    _rainbowController!.duration = widget.isActive
        ? const Duration(milliseconds: 1350)
        : const Duration(milliseconds: 2600);
    _rainbowController!
      ..reset()
      ..repeat();
  }

  @override
  void dispose() {
    _rainbowController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _ensureController();
    return AnimatedBuilder(
      animation: _rainbowController!,
      builder: (context, _) {
        final borderRadius = BorderRadius.circular(14);
        return CupertinoButton(
          padding: EdgeInsets.zero,
          minimumSize: Size.zero,
          onPressed: widget.onPressed,
          child: Container(
            padding: const EdgeInsets.all(1.25),
            decoration: BoxDecoration(
              borderRadius: borderRadius,
              gradient: SweepGradient(
                transform: GradientRotation(_rainbowController!.value * 6.28318530718),
                colors: const [
                  Color(0xFFFF004D),
                  Color(0xFFFF7A00),
                  Color(0xFFFFD500),
                  Color(0xFF2DFF6A),
                  Color(0xFF00D1FF),
                  Color(0xFF7A5CFF),
                  Color(0xFFFF00C8),
                  Color(0xFFFF004D),
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFFF4D00).withValues(alpha: widget.isActive ? 0.3 : 0.16),
                  blurRadius: widget.isActive ? 16 : 10,
                  spreadRadius: widget.isActive ? 0.6 : 0.0,
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
                    color: (widget.isActive
                            ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.2)
                            : CupertinoColors.systemGrey6.resolveFrom(context).withValues(alpha: 0.52)),
                    borderRadius: borderRadius,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        CupertinoIcons.text_alignleft,
                        size: 14,
                        color: widget.isActive
                            ? Theme.of(context).colorScheme.primary
                            : CupertinoColors.label.resolveFrom(context),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Lyrics',
                        style: CupertinoTheme.of(context).textTheme.textStyle.copyWith(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: widget.isActive ? Theme.of(context).colorScheme.primary : null,
                            ),
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

  void _ensureController() {
    if (_rainbowController != null) return;
    _rainbowController = AnimationController(
      vsync: this,
      duration: widget.isActive
          ? const Duration(milliseconds: 1350)
          : const Duration(milliseconds: 2600),
    )..repeat();
  }
}

class _DefaultNowPlayingHero extends StatelessWidget {
  final VideoPlayerManager manager;

  const _DefaultNowPlayingHero({
    super.key,
    required this.manager,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      key: key,
      children: [
        _ArtworkImage(url: manager.trackThumbnailUrl, size: 310),
        const SizedBox(height: 28),
        Text(
          manager.trackTitle ?? 'Cargando canción...',
          textAlign: TextAlign.center,
          style: CupertinoTheme.of(context).textTheme.navLargeTitleTextStyle.copyWith(
                fontSize: 34,
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 8),
        Text(
          manager.trackArtist ?? 'Artista desconocido',
          textAlign: TextAlign.center,
          style: CupertinoTheme.of(context).textTheme.textStyle.copyWith(
                fontSize: 20,
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
        ),
      ],
    );
  }
}

class _CompactNowPlayingHeader extends StatelessWidget {
  final VideoPlayerManager manager;

  const _CompactNowPlayingHeader({
    super.key,
    required this.manager,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      key: key,
      borderRadius: BorderRadius.circular(18),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: CupertinoColors.systemGrey6.resolveFrom(context).withValues(alpha: 0.38),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: CupertinoColors.white.withValues(alpha: 0.2),
              width: 0.5,
            ),
          ),
          child: Row(
            children: [
              _ArtworkImage(url: manager.trackThumbnailUrl, size: 62),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      manager.trackTitle ?? 'Cargando canción...',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: CupertinoTheme.of(context).textTheme.textStyle.copyWith(
                            fontSize: 19,
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      manager.trackArtist ?? 'Artista desconocido',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: CupertinoTheme.of(context).textTheme.textStyle.copyWith(
                            fontSize: 14,
                            color: CupertinoColors.secondaryLabel.resolveFrom(context),
                          ),
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

class _IosLoadingControls extends StatelessWidget {
  const _IosLoadingControls();

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: CupertinoColors.systemGrey6.resolveFrom(context).withValues(alpha: 0.48),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: CupertinoColors.white.withValues(alpha: 0.22),
              width: 0.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CupertinoActivityIndicator(radius: 9),
              const SizedBox(width: 10),
              Text(
                'Cargando...',
                style: CupertinoTheme.of(context).textTheme.textStyle.copyWith(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: CupertinoColors.secondaryLabel.resolveFrom(context),
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QueueSection extends StatelessWidget {
  final VideoPlayerManager manager;

  const _QueueSection({required this.manager});

  @override
  Widget build(BuildContext context) {
    final queue = manager.playbackQueue;

    if (manager.isQueueLoading) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Cola de reproducción',
            style: CupertinoTheme.of(context).textTheme.textStyle.copyWith(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 10),
          const _IosLoadingControls(),
        ],
      );
    }

    if (queue.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Cola de reproducción',
          style: CupertinoTheme.of(context).textTheme.textStyle.copyWith(
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 4),
        Text(
          manager.queueTitle,
          style: CupertinoTheme.of(context).textTheme.textStyle.copyWith(
                fontSize: 13,
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
        ),
        const SizedBox(height: 10),
        ...queue.take(12).map((item) => _QueueRow(item: item, manager: manager)),
      ],
    );
  }
}

class _QueueRow extends StatelessWidget {
  final PlaybackQueueItem item;
  final VideoPlayerManager manager;

  const _QueueRow({
    required this.item,
    required this.manager,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Material(
          color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.58),
          child: InkWell(
            onTap: () => manager.playQueueItem(item),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      item.thumbnailUrl,
                      width: 78,
                      height: 46,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) => Container(
                        width: 78,
                        height: 46,
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        alignment: Alignment.center,
                        child: const Icon(Icons.music_note_rounded),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: CupertinoTheme.of(context).textTheme.textStyle.copyWith(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          item.artist,
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
                  const SizedBox(width: 8),
                  Icon(
                    item.isLocal ? CupertinoIcons.tray_fill : CupertinoIcons.sparkles,
                    size: 18,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
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

class _LyricsPanel extends StatefulWidget {
  final VideoPlayerManager manager;

  const _LyricsPanel({required this.manager});

  @override
  State<_LyricsPanel> createState() => _LyricsPanelState();
}

class _LyricsPanelState extends State<_LyricsPanel> {
  final ScrollController _syncedScrollController = ScrollController();
  int _lastSyncedIndex = -1;
  String? _lastVideoId;

  @override
  void dispose() {
    _syncedScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final manager = widget.manager;
    if (_lastVideoId != manager.currentVideoId) {
      _lastVideoId = manager.currentVideoId;
      _lastSyncedIndex = -1;
    }
    final textStyle = CupertinoTheme.of(context).textTheme.textStyle.copyWith(
          fontSize: 17,
          height: 1.45,
          color: CupertinoColors.label.resolveFrom(context),
          fontWeight: FontWeight.w500,
        );

    Widget content;
    if (manager.isLyricsLoading) {
      content = const Padding(
        padding: EdgeInsets.symmetric(vertical: 28),
        child: Center(child: CupertinoActivityIndicator(radius: 11)),
      );
    } else if (manager.lyricsError != null) {
      content = Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          manager.lyricsError!,
          textAlign: TextAlign.left,
          style: textStyle.copyWith(
            color: CupertinoColors.secondaryLabel.resolveFrom(context),
          ),
        ),
      );
    } else if (manager.hasSyncedLyrics) {
      final currentIndex = manager.currentSyncedLyricIndex;
      _scrollToCurrentLyric(currentIndex);
      content = ListView.builder(
        key: ValueKey('synced_${manager.currentVideoId}'),
        controller: _syncedScrollController,
        physics: const BouncingScrollPhysics(),
        itemCount: manager.syncedLyrics.length,
        itemBuilder: (context, index) {
          final line = manager.syncedLyrics[index];
          final isActive = index == currentIndex;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeInOutCubic,
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
              opacity: isActive ? 1 : 0.86,
              child: AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 320),
                curve: Curves.easeInOutCubic,
                style: textStyle.copyWith(
                  fontSize: isActive ? 22 : 17,
                  fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                  color: isActive
                      ? Theme.of(context).colorScheme.primary
                      : CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
                child: Text(
                  line.text,
                  textAlign: TextAlign.left,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          );
        },
      );
    } else {
      content = Text(
        manager.lyricsText ?? '',
        style: textStyle,
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 210, maxHeight: 390),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: CupertinoColors.systemGrey6.resolveFrom(context).withValues(alpha: 0.40),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: CupertinoColors.white.withValues(alpha: 0.2),
              width: 0.5,
            ),
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: manager.hasSyncedLyrics
                ? content
                : SingleChildScrollView(
                    key: ValueKey('${manager.isLyricsLoading}-${manager.lyricsError}-${manager.lyricsText}'),
                    physics: const BouncingScrollPhysics(),
                    child: content,
                  ),
          ),
        ),
      ),
    );
  }

  void _scrollToCurrentLyric(int currentIndex) {
    if (currentIndex < 0 || currentIndex == _lastSyncedIndex) return;
    _lastSyncedIndex = currentIndex;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_syncedScrollController.hasClients) return;
      const itemExtent = 46.0;
      final viewport = _syncedScrollController.position.viewportDimension;
      final target = (currentIndex * itemExtent) - (viewport / 2) + (itemExtent / 2);
      final max = _syncedScrollController.position.maxScrollExtent;
      _syncedScrollController.animateTo(
        target.clamp(0.0, max),
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeInOutCubicEmphasized,
      );
    });
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
