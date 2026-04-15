import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show FontFeature, ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:myapp/app_tab_state.dart';
import 'package:myapp/models/video_history.dart';
import 'package:myapp/models/playlist.dart' as app_models;
import 'package:myapp/search_view_state.dart';
import 'package:myapp/services/app_settings_service.dart';
import 'package:myapp/services/ai_cover_animation_service.dart';
import 'package:myapp/services/download_service.dart';
import 'package:myapp/services/ios_live_lyrics_alignment_service.dart';
import 'package:myapp/services/lyrics_service.dart';
import 'package:myapp/services/playlist_service.dart';
import 'package:myapp/utils/artwork_subject_cutout_service.dart';
import 'package:myapp/utils/thumbnail_quality.dart';
import 'package:myapp/video_player_manager.dart';
import 'package:myapp/widgets/playlist_picker_sheet.dart';
import 'package:myapp/widgets/square_thumbnail.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class MusicPlayerPage extends StatefulWidget {
  const MusicPlayerPage({super.key});

  @override
  State<MusicPlayerPage> createState() => _MusicPlayerPageState();
}

class _MusicPlayerPageState extends State<MusicPlayerPage> {
  bool _isShowingPlaybackErrorDialog = false;

  @override
  Widget build(BuildContext context) {
    return Consumer<VideoPlayerManager>(
      builder: (context, manager, child) {
        final error = manager.errorMessage;
        if (error != null && error.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _showPlaybackErrorDialog(error);
          });
        }

        if (manager.currentVideoId == null) {
          return const SizedBox.shrink();
        }

        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 620),
          reverseDuration: const Duration(milliseconds: 500),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          layoutBuilder: (currentChild, previousChildren) {
            return Stack(
              fit: StackFit.expand,
              alignment: Alignment.bottomCenter,
              children: [
                ...previousChildren,
                if (currentChild != null) currentChild,
              ],
            );
          },
          transitionBuilder: (child, animation) {
            final isMini = child.key == const ValueKey('mini_player');
            final curved = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );
            final fade = Tween<double>(begin: 0.0, end: 1.0).animate(curved);
            final slide = Tween<Offset>(
              begin: isMini ? const Offset(0, 0.22) : const Offset(0, 0.08),
              end: Offset.zero,
            ).animate(curved);
            final scale = Tween<double>(
              begin: isMini ? 0.965 : 0.99,
              end: 1.0,
            ).animate(curved);
            return ClipRect(
              child: FadeTransition(
                opacity: fade,
                child: SlideTransition(
                  position: slide,
                  child: ScaleTransition(scale: scale, child: child),
                ),
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

  Future<void> _showPlaybackErrorDialog(String message) async {
    if (!mounted || _isShowingPlaybackErrorDialog) return;
    _isShowingPlaybackErrorDialog = true;
    try {
      await showCupertinoDialog<void>(
        context: context,
        builder: (dialogContext) => CupertinoAlertDialog(
          title: const Text('No se pudo reproducir'),
          content: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(message),
          ),
          actions: [
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Entendido'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) {
        context.read<VideoPlayerManager>().clearErrorMessage();
      }
      _isShowingPlaybackErrorDialog = false;
    }
  }
}

class _MiniPlayer extends StatefulWidget {
  final VideoPlayerManager manager;

  const _MiniPlayer({super.key, required this.manager});

  @override
  State<_MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<_MiniPlayer> {
  double _dragLift = 0.0;
  bool _isOpening = false;
  static const double _maxDragLift = 52.0;

  double get _dragProgress => (_dragLift / _maxDragLift).clamp(0.0, 1.0);

  void _setDragLift(double value) {
    if (!mounted) return;
    setState(() {
      _dragLift = value.clamp(0.0, _maxDragLift);
    });
  }

  Future<void> _openWithGestureAnimation() async {
    if (_isOpening) return;
    _isOpening = true;
    _setDragLift(_maxDragLift);
    HapticFeedback.lightImpact();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    if (!mounted) return;
    widget.manager.maximize();
    _isOpening = false;
    _setDragLift(0.0);
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    const miniPlayerHeight = 56.0;
    const miniPlayerBottomNavReserve = 54.0;
    final progress = _dragProgress;
    final dynamicRadius = 22 - (4 * progress);
    final dynamicShadowOpacity = 0.08 + (0.12 * progress);
    final dynamicShadowBlur = 22 + (18 * progress);
    final dynamicShadowYOffset = 8 - (4 * progress);

    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          12,
          0,
          12,
          miniPlayerBottomNavReserve + bottomInset,
        ),
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onVerticalDragUpdate: (details) {
            if (_isOpening) return;
            if (details.delta.dy < 0) {
              _setDragLift(_dragLift + ((-details.delta.dy) * 1.15));
            } else if (_dragLift > 0) {
              _setDragLift(_dragLift - (details.delta.dy * 1.25));
            }
          },
          onVerticalDragEnd: (details) {
            if (_isOpening) return;
            final velocity = details.primaryVelocity ?? 0;
            final shouldOpen = velocity < -340 || _dragProgress > 0.36;
            if (shouldOpen) {
              unawaited(_openWithGestureAnimation());
              return;
            }
            _setDragLift(0.0);
          },
          onVerticalDragCancel: () {
            if (_isOpening) return;
            _setDragLift(0.0);
          },
          child: AnimatedSlide(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutBack,
            offset: Offset(0, -(0.32 * progress)),
            child: AnimatedScale(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutBack,
              scale: 1 + (0.03 * progress),
              child: ClipRRect(
                clipBehavior: Clip.antiAlias,
                borderRadius: BorderRadius.circular(dynamicRadius),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 34, sigmaY: 34),
                  child: CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: widget.manager.maximize,
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
                            color: CupertinoColors.black.withValues(
                              alpha: dynamicShadowOpacity,
                            ),
                            blurRadius: dynamicShadowBlur,
                            offset: Offset(0, dynamicShadowYOffset),
                          ),
                        ],
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Row(
                        children: [
                          _ArtworkImage(
                            url: widget.manager.trackThumbnailUrl,
                            size: 44,
                            borderRadius: 10,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  widget.manager.trackTitle ?? 'Reproduciendo',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: CupertinoTheme.of(context)
                                      .textTheme
                                      .textStyle
                                      .copyWith(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                      ),
                                ),
                                Text(
                                  widget.manager.trackArtist ??
                                      'Artista desconocido',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: CupertinoTheme.of(context)
                                      .textTheme
                                      .textStyle
                                      .copyWith(
                                        fontSize: 12,
                                        color: CupertinoColors.secondaryLabel
                                            .resolveFrom(context),
                                      ),
                                ),
                              ],
                            ),
                          ),
                          CupertinoButton(
                            padding: EdgeInsets.zero,
                            onPressed: widget.manager.togglePlayPause,
                            child: Icon(
                              widget.manager.isPlaying
                                  ? CupertinoIcons.pause_circle_fill
                                  : CupertinoIcons.play_circle_fill,
                              size: 28,
                              color: CupertinoColors.label.resolveFrom(context),
                            ),
                          ),
                          const SizedBox(width: 6),
                          CupertinoButton(
                            padding: EdgeInsets.zero,
                            onPressed: widget.manager.close,
                            child: Icon(
                              CupertinoIcons.xmark_circle_fill,
                              size: 22,
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
            ),
          ),
        ),
      ),
    );
  }
}

class _FullPlayer extends StatefulWidget {
  final VideoPlayerManager manager;

  const _FullPlayer({super.key, required this.manager});

  @override
  State<_FullPlayer> createState() => _FullPlayerState();
}

class _FullPlayerState extends State<_FullPlayer> {
  static const double _pullToMinimizeThreshold = 76;
  final ScrollController _contentScrollController = ScrollController();
  double _pullDownAccumulated = 0;
  bool _didTriggerMinimizeInGesture = false;

  VideoPlayerManager get manager => widget.manager;

  @override
  void dispose() {
    _contentScrollController.dispose();
    super.dispose();
  }

  bool _isAtTop(ScrollMetrics metrics) {
    return metrics.pixels <= (metrics.minScrollExtent + 0.5);
  }

  void _accumulatePullToMinimize(double pullDelta) {
    if (pullDelta <= 0 || _didTriggerMinimizeInGesture) return;
    _pullDownAccumulated += pullDelta;
    if (_pullDownAccumulated < _pullToMinimizeThreshold) return;
    _didTriggerMinimizeInGesture = true;
    _pullDownAccumulated = 0;
    unawaited(HapticFeedback.mediumImpact());
    manager.minimize();
  }

  bool _handleContentScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification) {
      _pullDownAccumulated = 0;
      _didTriggerMinimizeInGesture = false;
      return false;
    }

    if (notification is ScrollUpdateNotification) {
      final dragDy = notification.dragDetails?.delta.dy;
      if (dragDy == null) return false;
      if (_isAtTop(notification.metrics) && dragDy > 0) {
        _accumulatePullToMinimize(dragDy);
      } else if (dragDy < 0) {
        _pullDownAccumulated = 0;
      }
      return false;
    }

    if (notification is OverscrollNotification) {
      final dragDy = notification.dragDetails?.delta.dy;
      if (dragDy == null) return false;
      if (_isAtTop(notification.metrics) && dragDy > 0) {
        _accumulatePullToMinimize(dragDy);
      } else if (dragDy < 0) {
        _pullDownAccumulated = 0;
      }
      return false;
    }

    if (notification is ScrollEndNotification) {
      _pullDownAccumulated = 0;
      _didTriggerMinimizeInGesture = false;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final downloadService = context.watch<DownloadService>();
    final settings = context.watch<AppSettingsService?>();
    final playlistService = context.read<PlaylistService>();
    final videoId = manager.currentVideoId;
    final canDownload = videoId != null && !manager.isLocal;
    final canAddToPlaylist = videoId != null;
    final animatedCoverEnabled = settings?.animatedCutoutCovers ?? true;

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
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(top: 2, bottom: 6),
                    decoration: BoxDecoration(
                      color: CupertinoColors.systemGrey3
                          .resolveFrom(context)
                          .withValues(alpha: 0.7),
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
                      _TopGlassIconButton(
                        icon: CupertinoIcons.list_bullet,
                        onPressed: () => _showQueueSheet(context),
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
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final screenWidth = MediaQuery.sizeOf(context).width;
                      final maxArtworkWidth = math.max(220.0, screenWidth - 48);
                      final halfViewportSize = constraints.maxHeight * 0.5;
                      final animatedArtworkSize = math
                          .min(halfViewportSize, maxArtworkWidth)
                          .clamp(220.0, 560.0)
                          .toDouble();
                      final defaultArtworkSize = animatedCoverEnabled
                          ? animatedArtworkSize
                          : 310.0;
                      return NotificationListener<ScrollNotification>(
                        onNotification: _handleContentScrollNotification,
                        child: SingleChildScrollView(
                          controller: _contentScrollController,
                          physics: const ClampingScrollPhysics(
                            parent: AlwaysScrollableScrollPhysics(),
                          ),
                          clipBehavior: Clip.none,
                          padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              minHeight: constraints.maxHeight - 40,
                            ),
                            child: Column(
                              children: [
                                TweenAnimationBuilder<double>(
                                  key: ValueKey(
                                    'full-hero-entry-${manager.currentVideoId}-${manager.isLyricsLayout}',
                                  ),
                                  tween: Tween<double>(begin: 0, end: 1),
                                  duration: const Duration(milliseconds: 440),
                                  curve: Curves.easeOutCubic,
                                  builder: (context, value, child) {
                                    final lift = (1 - value) * 40;
                                    final scale = 0.90 + (0.10 * value);
                                    return Opacity(
                                      opacity: value,
                                      child: Transform.translate(
                                        offset: Offset(0, lift),
                                        child: Transform.scale(
                                          alignment: Alignment.topCenter,
                                          scale: scale,
                                          child: child,
                                        ),
                                      ),
                                    );
                                  },
                                  child: AnimatedSwitcher(
                                    duration: const Duration(milliseconds: 420),
                                    switchInCurve: Curves.easeOutCubic,
                                    switchOutCurve: Curves.easeInCubic,
                                    layoutBuilder:
                                        (currentChild, previousChildren) {
                                          return Stack(
                                            clipBehavior: Clip.none,
                                            alignment: Alignment.topCenter,
                                            children: <Widget>[
                                              ...previousChildren,
                                              if (currentChild != null)
                                                currentChild,
                                            ],
                                          );
                                        },
                                    transitionBuilder: (child, animation) {
                                      final slide =
                                          Tween<Offset>(
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
                                        child: SlideTransition(
                                          position: slide,
                                          child: child,
                                        ),
                                      );
                                    },
                                    child: manager.isLyricsLayout
                                        ? _CompactNowPlayingHeader(
                                            key: const ValueKey(
                                              'compact_now_playing_header',
                                            ),
                                            manager: manager,
                                            onArtistTap: () =>
                                                _openArtistProfile(context),
                                            canAddToPlaylist: canAddToPlaylist,
                                            onAddToPlaylist: () =>
                                                _showAddToPlaylistSheet(
                                                  context: context,
                                                  playlistService:
                                                      playlistService,
                                                  downloadService:
                                                      downloadService,
                                                  manager: manager,
                                                ),
                                            onAddToFavorites: () =>
                                                _addCurrentTrackToFavorites(
                                                  context: context,
                                                  playlistService:
                                                      playlistService,
                                                  downloadService:
                                                      downloadService,
                                                  manager: manager,
                                                ),
                                          )
                                        : _DefaultNowPlayingHero(
                                            key: const ValueKey(
                                              'default_now_playing_hero',
                                            ),
                                            manager: manager,
                                            artworkSize: defaultArtworkSize,
                                            onArtistTap: () =>
                                                _openArtistProfile(context),
                                            canAddToPlaylist: canAddToPlaylist,
                                            onAddToPlaylist: () =>
                                                _showAddToPlaylistSheet(
                                                  context: context,
                                                  playlistService:
                                                      playlistService,
                                                  downloadService:
                                                      downloadService,
                                                  manager: manager,
                                                ),
                                            onAddToFavorites: () =>
                                                _addCurrentTrackToFavorites(
                                                  context: context,
                                                  playlistService:
                                                      playlistService,
                                                  downloadService:
                                                      downloadService,
                                                  manager: manager,
                                                ),
                                          ),
                                  ),
                                ),
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
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceEvenly,
                                      children: [
                                        _NativeControlButton(
                                          icon:
                                              CupertinoIcons.backward_end_fill,
                                          onPressed:
                                              manager.playPreviousInQueue,
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
                                  Row(
                                    children: [
                                      _InlineLyricsButton(
                                        isActive: manager.isLyricsLayout,
                                        onPressed: manager.toggleLyricsLayout,
                                      ),
                                      const Spacer(),
                                      _InlineAutoplayButton(
                                        isActive: manager.autoplayEnabled,
                                        onPressed: manager.toggleAutoplay,
                                      ),
                                    ],
                                  ),
                                ],
                                const SizedBox(height: 26),
                                _QueueSection(manager: manager),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
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
    required DownloadService downloadService,
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

    final selectedName = await showGlassPlaylistPickerSheet(
      context: context,
      playlists: playlists,
      subtitle: manager.trackTitle,
    );
    if (!context.mounted || selectedName == null || selectedName.isEmpty) {
      return;
    }
    final selected = playlists.firstWhere(
      (playlist) => playlist.name == selectedName,
      orElse: () => app_models.Playlist(name: selectedName),
    );
    await _addCurrentTrackToPlaylist(
      context: context,
      playlistService: playlistService,
      downloadService: downloadService,
      manager: manager,
      playlist: selected,
    );
  }

  Future<void> _addCurrentTrackToPlaylist({
    required BuildContext context,
    required PlaylistService playlistService,
    required DownloadService downloadService,
    required VideoPlayerManager manager,
    required app_models.Playlist playlist,
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
    await downloadService.autoDownloadIfEnabledUsingClone(
      playlist.name,
      track,
      videoManager: manager,
    );
    if (!context.mounted) return;
    _showIosTopToast(
      context,
      message: 'Añadida a ${playlist.name}',
      icon: CupertinoIcons.check_mark_circled_solid,
    );
  }

  Future<void> _addCurrentTrackToFavorites({
    required BuildContext context,
    required PlaylistService playlistService,
    required DownloadService downloadService,
    required VideoPlayerManager manager,
  }) async {
    final playlists = await playlistService.getPlaylists();
    final favorites = playlists.firstWhere(
      (playlist) => PlaylistService.isFavoritesPlaylistName(playlist.name),
      orElse: () =>
          app_models.Playlist(name: PlaylistService.favoritesPlaylistName),
    );

    final videoId = manager.currentVideoId;
    if (videoId == null) return;

    final track = VideoHistory(
      videoId: videoId,
      title: manager.trackTitle ?? 'Sin título',
      thumbnailUrl: manager.trackThumbnailUrl ?? '',
      channelTitle: manager.trackArtist ?? '',
      watchedAt: DateTime.now(),
    );

    await playlistService.addVideoToPlaylist(favorites.name, track);
    await downloadService.autoDownloadIfEnabledUsingClone(
      favorites.name,
      track,
      videoManager: manager,
    );
    if (!context.mounted) return;
    _showIosTopToast(
      context,
      message: 'Añadida a Favoritos',
      icon: CupertinoIcons.star_fill,
    );
  }

  void _showIosTopToast(
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
                child: _IosTopToast(message: message, icon: icon),
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

  Future<void> _showQueueSheet(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Consumer<VideoPlayerManager>(
            builder: (context, manager, _) => SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: _QueueSection(manager: manager),
            ),
          ),
        );
      },
    );
  }

  Future<void> _openArtistProfile(BuildContext context) async {
    final rawArtist = manager.trackArtist?.trim();
    if (rawArtist == null || rawArtist.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se encontró el nombre del artista.')),
      );
      return;
    }

    final normalizedArtist = rawArtist
        .replaceAll(RegExp(r'\s*[-–—]\s*topic$', caseSensitive: false), '')
        .trim()
        .toLowerCase();

    final yt = YoutubeExplode();
    try {
      final raw = await yt.search.searchContent(
        rawArtist,
        filter: TypeFilters.channel,
      );
      final channels = raw.whereType<SearchChannel>().take(12).toList();
      if (channels.isEmpty) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No se encontró un perfil para este artista.'),
          ),
        );
        return;
      }

      SearchChannel best = channels.first;
      var bestScore = -1;
      for (final channel in channels) {
        final name = channel.name.toLowerCase();
        final description = channel.description.toLowerCase();
        var score = 0;
        if (name.contains(normalizedArtist)) score += 5;
        if (description.contains(normalizedArtist)) score += 2;
        if (name.endsWith('- topic') || name.endsWith('topic')) score += 6;
        if (score > bestScore) {
          bestScore = score;
          best = channel;
        }
      }

      final thumb = best.thumbnails.isNotEmpty
          ? best.thumbnails.first.url.toString()
          : (manager.trackThumbnailUrl ?? '');
      if (!context.mounted) return;
      context.read<SearchViewState>().requestOpenArtistProfile(
        PendingArtistProfile(
          channelId: best.id.value,
          channelName: best.name,
          channelThumbnailUrl: thumb,
        ),
      );
      context.read<AppTabState?>()?.setIndex(0);
      manager.minimize();
    } catch (e, s) {
      developer.log(
        'Error al abrir perfil del artista',
        error: e,
        stackTrace: s,
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No se pudo abrir el perfil del artista.'),
        ),
      );
    } finally {
      yt.close();
    }
  }
}

class _InlineLyricsButton extends StatefulWidget {
  final bool isActive;
  final VoidCallback onPressed;

  const _InlineLyricsButton({required this.isActive, required this.onPressed});

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
                transform: GradientRotation(
                  _rainbowController!.value * 6.28318530718,
                ),
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
                  color: const Color(
                    0xFFFF4D00,
                  ).withValues(alpha: widget.isActive ? 0.3 : 0.16),
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
                        ? Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.2)
                        : CupertinoColors.systemGrey6
                              .resolveFrom(context)
                              .withValues(alpha: 0.52)),
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
                        style: CupertinoTheme.of(context).textTheme.textStyle
                            .copyWith(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: widget.isActive
                                  ? Theme.of(context).colorScheme.primary
                                  : null,
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

class _InlineAutoplayButton extends StatefulWidget {
  final bool isActive;
  final VoidCallback onPressed;

  const _InlineAutoplayButton({
    required this.isActive,
    required this.onPressed,
  });

  @override
  State<_InlineAutoplayButton> createState() => _InlineAutoplayButtonState();
}

class _InlineAutoplayButtonState extends State<_InlineAutoplayButton>
    with TickerProviderStateMixin {
  AnimationController? _ringController;

  @override
  void initState() {
    super.initState();
    _ensureController();
  }

  @override
  void didUpdateWidget(covariant _InlineAutoplayButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    _ensureController();
    if (oldWidget.isActive == widget.isActive) return;
    _ringController!.duration = widget.isActive
        ? const Duration(milliseconds: 1350)
        : const Duration(milliseconds: 2600);
    _ringController!
      ..reset()
      ..repeat();
  }

  @override
  void dispose() {
    _ringController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _ensureController();
    return AnimatedBuilder(
      animation: _ringController!,
      builder: (context, _) {
        final borderRadius = BorderRadius.circular(14);
        final activeColor = const Color(0xFF1FBF64);
        return CupertinoButton(
          padding: EdgeInsets.zero,
          minimumSize: Size.zero,
          onPressed: widget.onPressed,
          child: Container(
            padding: const EdgeInsets.all(1.25),
            decoration: BoxDecoration(
              borderRadius: borderRadius,
              gradient: SweepGradient(
                transform: GradientRotation(
                  _ringController!.value * 6.28318530718,
                ),
                colors: const [
                  Color(0xFF1FBF64),
                  Color(0xFF4ADE80),
                  Color(0xFF9CA3AF),
                  Color(0xFF6B7280),
                  Color(0xFF22C55E),
                  Color(0xFF1FBF64),
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: activeColor.withValues(
                    alpha: widget.isActive ? 0.26 : 0.14,
                  ),
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
                    color: widget.isActive
                        ? activeColor.withValues(alpha: 0.2)
                        : CupertinoColors.systemGrey6
                              .resolveFrom(context)
                              .withValues(alpha: 0.52),
                    borderRadius: borderRadius,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        CupertinoIcons.dot_radiowaves_left_right,
                        size: 14,
                        color: widget.isActive
                            ? activeColor
                            : CupertinoColors.label.resolveFrom(context),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Autoplay',
                        style: CupertinoTheme.of(context).textTheme.textStyle
                            .copyWith(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: widget.isActive ? activeColor : null,
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
    if (_ringController != null) return;
    _ringController = AnimationController(
      vsync: this,
      duration: widget.isActive
          ? const Duration(milliseconds: 1350)
          : const Duration(milliseconds: 2600),
    )..repeat();
  }
}

class _DefaultNowPlayingHero extends StatelessWidget {
  final VideoPlayerManager manager;
  final double artworkSize;
  final VoidCallback onArtistTap;
  final bool canAddToPlaylist;
  final VoidCallback onAddToPlaylist;
  final VoidCallback onAddToFavorites;

  const _DefaultNowPlayingHero({
    super.key,
    required this.manager,
    required this.artworkSize,
    required this.onArtistTap,
    required this.canAddToPlaylist,
    required this.onAddToPlaylist,
    required this.onAddToFavorites,
  });

  @override
  Widget build(BuildContext context) {
    final motionEnergy = _estimateTrackMotionEnergy(
      manager.trackTitle,
      manager.trackArtist,
    );
    return Column(
      key: key,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) {
              return FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween<double>(
                    begin: 0.985,
                    end: 1.0,
                  ).animate(animation),
                  child: child,
                ),
              );
            },
            child: _ArtworkImage(
              key: ValueKey('hero-artwork-${manager.trackThumbnailUrl ?? ''}'),
              url: manager.trackThumbnailUrl,
              size: artworkSize,
              animated: true,
              isPlaying: manager.isPlaying,
              motionEnergy: motionEnergy,
            ),
          ),
        ),
        const SizedBox(height: 28),
        SizedBox(
          width: double.infinity,
          child: _AutoScrollText(
            text: manager.trackTitle ?? 'Cargando canción...',
            style: CupertinoTheme.of(context).textTheme.navLargeTitleTextStyle
                .copyWith(fontSize: 34, fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onArtistTap,
                child: _AutoScrollText(
                  text: manager.trackArtist ?? 'Artista desconocido',
                  style: CupertinoTheme.of(context).textTheme.textStyle
                      .copyWith(
                        fontSize: 20,
                        color: CupertinoColors.secondaryLabel.resolveFrom(
                          context,
                        ),
                      ),
                ),
              ),
            ),
            if (canAddToPlaylist) ...[
              const SizedBox(width: 8),
              _InlineArtistActionButton(
                icon: CupertinoIcons.add,
                onPressed: onAddToPlaylist,
              ),
              const SizedBox(width: 6),
              _InlineArtistActionButton(
                icon: CupertinoIcons.star_fill,
                onPressed: onAddToFavorites,
              ),
            ],
          ],
        ),
      ],
    );
  }
}

double _estimateTrackMotionEnergy(String? title, String? artist) {
  final text = '${title ?? ''} ${artist ?? ''}'.toLowerCase();
  var score = 1.0;

  const highEnergyHints = <String>[
    'remix',
    'live',
    'edm',
    'hardstyle',
    'phonk',
    'trap',
    'drill',
    'dnb',
    'techno',
    'house',
    'rock',
    'metal',
    'boosted',
    'nightcore',
    'sped up',
  ];
  const lowEnergyHints = <String>[
    'acoustic',
    'piano',
    'ballad',
    'slowed',
    'reverb',
    'instrumental',
    'lofi',
    'lo-fi',
    'ambient',
    'soft',
    'calm',
    'sleep',
  ];

  for (final hint in highEnergyHints) {
    if (text.contains(hint)) score += 0.06;
  }
  for (final hint in lowEnergyHints) {
    if (text.contains(hint)) score -= 0.07;
  }

  final exclamations = '!'.allMatches(text).length;
  if (exclamations > 0) score += (exclamations * 0.02).clamp(0, 0.08);
  if (text.contains('feat.') || text.contains(' ft ')) score += 0.03;

  return score.clamp(0.78, 1.32);
}

class _AutoScrollText extends StatefulWidget {
  final String text;
  final TextStyle style;

  const _AutoScrollText({required this.text, required this.style});

  @override
  State<_AutoScrollText> createState() => _AutoScrollTextState();
}

class _AutoScrollTextState extends State<_AutoScrollText>
    with TickerProviderStateMixin {
  AnimationController? _scrollController;
  AnimationController? _fadeController;
  double _overflow = 0;
  String _lastText = '';
  Duration _scrollDuration = const Duration(milliseconds: 4200);
  double _travel = 0;
  int _cycleEpoch = 0;
  bool _cycleRunning = false;

  @override
  void dispose() {
    _cycleEpoch++;
    _scrollController?.dispose();
    _fadeController?.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _AutoScrollText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _lastText = '';
      _restartCycle();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          maxLines: 1,
          textDirection: Directionality.of(context),
        )..layout(minWidth: 0, maxWidth: double.infinity);

        final textWidth = painter.width;
        final textHeight = painter.height;
        _overflow = (textWidth - maxWidth).clamp(0.0, double.infinity);
        if (_overflow <= 1) {
          _cycleEpoch++;
          _cycleRunning = false;
          _scrollController?.stop();
          _fadeController?.stop();
          _scrollController?.value = 0;
          _fadeController?.value = 1;
          return Text(
            widget.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.left,
            style: widget.style,
          );
        }

        _ensureControllers();

        final ms = ((_overflow / 26) * 1000).clamp(2200, 9000).round();
        final duration = Duration(milliseconds: ms);
        _travel = _overflow + 36.0;
        if (_scrollDuration != duration) {
          _scrollDuration = duration;
          _restartCycle();
        }
        if (_lastText != widget.text) {
          _lastText = widget.text;
          _restartCycle();
        }

        _startCycleIfNeeded();
        const gap = 36.0;
        return ClipRect(
          child: AnimatedBuilder(
            animation: Listenable.merge([_scrollController!, _fadeController!]),
            builder: (context, _) {
              final eased = Curves.easeInOutCubic.transform(
                _scrollController!.value,
              );
              return Transform.translate(
                offset: Offset(-_travel * eased, 0),
                child: SizedBox(
                  height: textHeight,
                  child: Opacity(
                    opacity: _fadeController!.value,
                    child: OverflowBox(
                      minHeight: textHeight,
                      maxHeight: textHeight,
                      maxWidth: double.infinity,
                      alignment: Alignment.centerLeft,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: textWidth,
                            child: Text(
                              widget.text,
                              maxLines: 1,
                              softWrap: false,
                              style: widget.style,
                              textAlign: TextAlign.left,
                            ),
                          ),
                          const SizedBox(width: gap),
                          SizedBox(
                            width: textWidth,
                            child: Text(
                              widget.text,
                              maxLines: 1,
                              softWrap: false,
                              style: widget.style,
                              textAlign: TextAlign.left,
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
        );
      },
    );
  }

  void _ensureControllers() {
    _scrollController ??= AnimationController(
      vsync: this,
      duration: _scrollDuration,
      value: 0,
    );
    _fadeController ??= AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      value: 1,
    );
  }

  void _restartCycle() {
    _cycleEpoch++;
    _cycleRunning = false;
    _scrollController?.stop();
    _fadeController?.stop();
    _scrollController?.value = 0;
    _fadeController?.value = 1;
  }

  void _startCycleIfNeeded() {
    if (_cycleRunning) return;
    _cycleRunning = true;
    final token = _cycleEpoch;
    unawaited(_runCycle(token));
  }

  Future<void> _runCycle(int token) async {
    var firstPass = true;
    while (mounted && token == _cycleEpoch && _overflow > 1) {
      if (!firstPass) {
        await Future<void>.delayed(const Duration(seconds: 15));
        if (!mounted || token != _cycleEpoch || _overflow <= 1) return;
      }
      firstPass = false;

      try {
        await _scrollController!.animateTo(
          1,
          duration: _scrollDuration,
          curve: Curves.easeInOutCubic,
        );
      } catch (_) {
        return;
      }
      if (!mounted || token != _cycleEpoch) return;

      try {
        await _fadeController!.animateTo(
          0,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        );
      } catch (_) {
        return;
      }
      if (!mounted || token != _cycleEpoch) return;

      _scrollController!.value = 0;

      try {
        await _fadeController!.animateTo(
          1,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeInCubic,
        );
      } catch (_) {
        return;
      }
    }
    if (token == _cycleEpoch) {
      _cycleRunning = false;
    }
  }
}

class _CompactNowPlayingHeader extends StatelessWidget {
  final VideoPlayerManager manager;
  final VoidCallback onArtistTap;
  final bool canAddToPlaylist;
  final VoidCallback onAddToPlaylist;
  final VoidCallback onAddToFavorites;

  const _CompactNowPlayingHeader({
    super.key,
    required this.manager,
    required this.onArtistTap,
    required this.canAddToPlaylist,
    required this.onAddToPlaylist,
    required this.onAddToFavorites,
  });

  @override
  Widget build(BuildContext context) {
    final motionEnergy = _estimateTrackMotionEnergy(
      manager.trackTitle,
      manager.trackArtist,
    );
    return ClipRRect(
      key: key,
      borderRadius: BorderRadius.circular(18),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: CupertinoColors.systemGrey6
                .resolveFrom(context)
                .withValues(alpha: 0.38),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: CupertinoColors.white.withValues(alpha: 0.2),
              width: 0.5,
            ),
          ),
          child: Row(
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) {
                  return FadeTransition(opacity: animation, child: child);
                },
                child: _ArtworkImage(
                  key: ValueKey(
                    'compact-artwork-${manager.trackThumbnailUrl ?? ''}',
                  ),
                  url: manager.trackThumbnailUrl,
                  size: 62,
                  animated: true,
                  isPlaying: manager.isPlaying,
                  motionEnergy: motionEnergy,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      manager.trackTitle ?? 'Cargando canción...',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: CupertinoTheme.of(context).textTheme.textStyle
                          .copyWith(fontSize: 19, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: onArtistTap,
                            child: Text(
                              manager.trackArtist ?? 'Artista desconocido',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: CupertinoTheme.of(context)
                                  .textTheme
                                  .textStyle
                                  .copyWith(
                                    fontSize: 14,
                                    color: CupertinoColors.secondaryLabel
                                        .resolveFrom(context),
                                  ),
                            ),
                          ),
                        ),
                        if (canAddToPlaylist) ...[
                          const SizedBox(width: 8),
                          _InlineArtistActionButton(
                            icon: CupertinoIcons.add,
                            onPressed: onAddToPlaylist,
                            compact: true,
                          ),
                          const SizedBox(width: 6),
                          _InlineArtistActionButton(
                            icon: CupertinoIcons.star_fill,
                            onPressed: onAddToFavorites,
                            compact: true,
                          ),
                        ],
                      ],
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

class _InlineArtistActionButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;
  final bool compact;

  const _InlineArtistActionButton({
    required this.icon,
    required this.onPressed,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final size = compact ? 26.0 : 30.0;
    final iconSize = compact ? 14.0 : 16.0;
    return CupertinoButton(
      padding: EdgeInsets.zero,
      minimumSize: Size(size, size),
      onPressed: onPressed,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: CupertinoColors.systemGrey6
              .resolveFrom(context)
              .withValues(alpha: 0.58),
          shape: BoxShape.circle,
          border: Border.all(
            color: CupertinoColors.white.withValues(alpha: 0.2),
            width: 0.5,
          ),
        ),
        child: Icon(
          icon,
          size: iconSize,
          color: CupertinoColors.label.resolveFrom(context),
        ),
      ),
    );
  }
}

class _IosTopToast extends StatefulWidget {
  final String message;
  final IconData icon;

  const _IosTopToast({required this.message, required this.icon});

  @override
  State<_IosTopToast> createState() => _IosTopToastState();
}

class _IosTopToastState extends State<_IosTopToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      reverseDuration: const Duration(milliseconds: 240),
    );
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    _slide = Tween<Offset>(
      begin: const Offset(0, -0.06),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _controller.forward();
    Timer(const Duration(milliseconds: 1400), () {
      if (mounted) {
        _controller.reverse();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: _slide,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 330),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: Theme.of(context).brightness == Brightness.dark
                    ? Colors.black.withValues(alpha: 0.72)
                    : Colors.white.withValues(alpha: 0.86),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Colors.white.withValues(alpha: 0.14)
                      : Colors.black.withValues(alpha: 0.08),
                  width: 0.6,
                ),
              ),
              child: Text(
                widget.message,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: '.SF Pro Text',
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Colors.white
                      : Colors.black,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TopGlassIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;

  const _TopGlassIconButton({required this.icon, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      padding: EdgeInsets.zero,
      onPressed: onPressed,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: Colors.transparent,
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
            color: CupertinoColors.systemBackground
                .resolveFrom(context)
                .withValues(alpha: 0.46),
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
            color: CupertinoColors.systemGrey6
                .resolveFrom(context)
                .withValues(alpha: 0.48),
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

class _QueueSection extends StatefulWidget {
  final VideoPlayerManager manager;

  const _QueueSection({required this.manager});

  @override
  State<_QueueSection> createState() => _QueueSectionState();
}

class _QueueSectionState extends State<_QueueSection> {
  static const double _reorderHapticStepPx = 66;
  bool _isTrackingReorderDrag = false;
  double _dragAccumulatorPx = 0;

  void _onReorderStart(int _) {
    _isTrackingReorderDrag = true;
    _dragAccumulatorPx = 0;
    unawaited(HapticFeedback.mediumImpact());
  }

  void _onReorderEnd(int _) {
    _isTrackingReorderDrag = false;
    _dragAccumulatorPx = 0;
    unawaited(HapticFeedback.selectionClick());
  }

  void _onReorder(int oldIndex, int newIndex) {
    widget.manager.reorderPlaybackQueue(oldIndex, newIndex);
    unawaited(HapticFeedback.lightImpact());
  }

  void _onDragPointerMove(PointerMoveEvent event) {
    if (!_isTrackingReorderDrag) return;
    _dragAccumulatorPx += event.delta.dy;
    while (_dragAccumulatorPx.abs() >= _reorderHapticStepPx) {
      _dragAccumulatorPx += _dragAccumulatorPx > 0
          ? -_reorderHapticStepPx
          : _reorderHapticStepPx;
      unawaited(HapticFeedback.selectionClick());
    }
  }

  @override
  Widget build(BuildContext context) {
    final manager = widget.manager;
    final queue = manager.playbackQueue;
    final textTheme = CupertinoTheme.of(context).textTheme;
    final titleColor = CupertinoColors.label.resolveFrom(context);
    final subtitleColor = CupertinoColors.secondaryLabel.resolveFrom(context);

    if (manager.isQueueLoading) {
      return _QueueShell(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Cola de reproducción',
              style: textTheme.textStyle.copyWith(
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            const _IosLoadingControls(),
          ],
        ),
      );
    }

    if (queue.isEmpty) {
      return const SizedBox.shrink();
    }

    return _QueueShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'A continuación',
                  style: textTheme.textStyle.copyWith(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: titleColor,
                  ),
                ),
              ),
              CupertinoButton(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
                minimumSize: const Size(34, 34),
                onPressed: queue.length > 1
                    ? () {
                        unawaited(HapticFeedback.lightImpact());
                        manager.shufflePlaybackQueue();
                      }
                    : null,
                child: Icon(
                  CupertinoIcons.shuffle,
                  size: 18,
                  color: queue.length > 1
                      ? titleColor
                      : CupertinoColors.tertiaryLabel.resolveFrom(context),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${manager.queueTitle} · ${queue.length} canciones',
            style: textTheme.textStyle.copyWith(
              fontSize: 13,
              color: subtitleColor,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Mantén y arrastra para reordenar.',
            style: textTheme.textStyle.copyWith(
              fontSize: 12,
              color: subtitleColor.withValues(alpha: 0.88),
            ),
          ),
          const SizedBox(height: 12),
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: queue.length,
            buildDefaultDragHandles: false,
            proxyDecorator: (child, index, animation) {
              return FadeTransition(
                opacity: Tween<double>(begin: 0.96, end: 1).animate(animation),
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.992, end: 1).animate(animation),
                  child: child,
                ),
              );
            },
            onReorderStart: _onReorderStart,
            onReorderEnd: _onReorderEnd,
            onReorder: _onReorder,
            itemBuilder: (context, index) {
              final item = queue[index];
              return _QueueRow(
                key: ValueKey(
                  'queue_${item.videoId}_${item.isLocal}_${item.localFilePath ?? ''}',
                ),
                item: item,
                manager: manager,
                index: index,
                onDragPointerMove: _onDragPointerMove,
              );
            },
          ),
        ],
      ),
    );
  }
}

class _QueueRow extends StatelessWidget {
  final PlaybackQueueItem item;
  final VideoPlayerManager manager;
  final int index;
  final ValueChanged<PointerMoveEvent>? onDragPointerMove;

  const _QueueRow({
    super.key,
    required this.item,
    required this.manager,
    required this.index,
    this.onDragPointerMove,
  });

  @override
  Widget build(BuildContext context) {
    final titleColor = CupertinoColors.white.withValues(alpha: 0.96);
    final subtitleColor = CupertinoColors.white.withValues(alpha: 0.70);
    final rowColor = CupertinoColors.black.withValues(alpha: 0.78);
    final rowBorder = CupertinoColors.white.withValues(alpha: 0.16);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Material(
            color: rowColor,
            child: Ink(
              decoration: BoxDecoration(
                border: Border.all(color: rowBorder, width: 0.6),
                borderRadius: BorderRadius.circular(16),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    CupertinoColors.white.withValues(alpha: 0.10),
                    CupertinoColors.white.withValues(alpha: 0.02),
                  ],
                ),
              ),
              child: InkWell(
                onTap: () {
                  unawaited(HapticFeedback.selectionClick());
                  unawaited(manager.playQueueItem(item));
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Listener(
                        onPointerMove: onDragPointerMove,
                        child: ReorderableDelayedDragStartListener(
                          index: index,
                          child: Padding(
                            padding: const EdgeInsets.only(right: 8, left: 2),
                            child: Container(
                              width: 24,
                              height: 24,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: CupertinoColors.white.withValues(
                                  alpha: 0.08,
                                ),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(
                                CupertinoIcons.line_horizontal_3,
                                size: 15,
                                color: subtitleColor,
                              ),
                            ),
                          ),
                        ),
                      ),
                      item.thumbnailUrl.startsWith('/')
                          ? SquareThumbnail.file(
                              filePath: item.thumbnailUrl,
                              size: 56,
                              borderRadius: 10,
                              zoom: 1,
                              fallback: Container(
                                width: 56,
                                height: 56,
                                color: Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerHighest,
                                alignment: Alignment.center,
                                child: const Icon(Icons.music_note_rounded),
                              ),
                            )
                          : SquareThumbnail.network(
                              imageUrl: item.thumbnailUrl,
                              size: 56,
                              borderRadius: 10,
                              zoom: 1,
                              fallback: Container(
                                width: 56,
                                height: 56,
                                color: Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerHighest,
                                alignment: Alignment.center,
                                child: const Icon(Icons.music_note_rounded),
                              ),
                            ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (index == 0)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 3),
                                child: Text(
                                  'Siguiente',
                                  style: CupertinoTheme.of(context)
                                      .textTheme
                                      .textStyle
                                      .copyWith(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                        color: CupertinoColors.systemPink
                                            .resolveFrom(context),
                                      ),
                                ),
                              ),
                            Text(
                              item.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: CupertinoTheme.of(context)
                                  .textTheme
                                  .textStyle
                                  .copyWith(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: titleColor,
                                  ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              item.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: CupertinoTheme.of(context)
                                  .textTheme
                                  .textStyle
                                  .copyWith(fontSize: 12, color: subtitleColor),
                            ),
                          ],
                        ),
                      ),
                      CupertinoButton(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 0,
                        ),
                        minimumSize: const Size(28, 28),
                        onPressed: () {
                          unawaited(HapticFeedback.lightImpact());
                          unawaited(_showActionsMenu(context));
                        },
                        child: Icon(
                          CupertinoIcons.ellipsis,
                          size: 18,
                          color: titleColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showActionsMenu(BuildContext context) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(26),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                child: Container(
                  decoration: BoxDecoration(
                    color: CupertinoColors.systemGrey6
                        .resolveFrom(sheetContext)
                        .withValues(alpha: 0.82),
                    borderRadius: BorderRadius.circular(26),
                    border: Border.all(
                      color: CupertinoColors.white.withValues(alpha: 0.24),
                      width: 0.7,
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(height: 8),
                      Container(
                        width: 42,
                        height: 4,
                        decoration: BoxDecoration(
                          color: CupertinoColors.systemGrey3
                              .resolveFrom(sheetContext)
                              .withValues(alpha: 0.75),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                item.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: CupertinoTheme.of(sheetContext)
                                    .textTheme
                                    .navTitleTextStyle
                                    .copyWith(fontWeight: FontWeight.w700),
                              ),
                            ),
                            const SizedBox(width: 8),
                            CupertinoButton(
                              padding: EdgeInsets.zero,
                              minimumSize: const Size(34, 34),
                              onPressed: () => Navigator.of(sheetContext).pop(),
                              child: Icon(
                                CupertinoIcons.xmark_circle_fill,
                                size: 24,
                                color: CupertinoColors.secondaryLabel
                                    .resolveFrom(sheetContext),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(10, 0, 10, 14),
                        child: Column(
                          children: [
                            _QueueGlassSheetActionRow(
                              icon: CupertinoIcons.play_fill,
                              label: 'Reproducir ahora',
                              onTap: () =>
                                  Navigator.of(sheetContext).pop('play'),
                            ),
                            const SizedBox(height: 8),
                            _QueueGlassSheetActionRow(
                              icon: CupertinoIcons.star_fill,
                              label: 'Añadir a Favoritos',
                              onTap: () =>
                                  Navigator.of(sheetContext).pop('favorites'),
                            ),
                            const SizedBox(height: 8),
                            _QueueGlassSheetActionRow(
                              icon: CupertinoIcons.music_note_list,
                              label: 'Añadir a playlist',
                              onTap: () =>
                                  Navigator.of(sheetContext).pop('playlist'),
                            ),
                            const SizedBox(height: 8),
                            _QueueGlassSheetActionRow(
                              icon: CupertinoIcons.minus_circle_fill,
                              label: 'Quitar de la cola',
                              isDestructive: true,
                              onTap: () =>
                                  Navigator.of(sheetContext).pop('remove'),
                            ),
                          ],
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
    if (!context.mounted || action == null) return;
    unawaited(HapticFeedback.selectionClick());
    switch (action) {
      case 'play':
        await manager.playQueueItem(item);
        return;
      case 'favorites':
        await _addItemToFavorites(context);
        return;
      case 'playlist':
        await _addItemToPlaylist(context);
        return;
      case 'remove':
        unawaited(HapticFeedback.mediumImpact());
        manager.removeQueueItem(item);
        _showQueueSnackBar(context, 'Quitada de la cola');
        return;
    }
  }

  Future<void> _addItemToFavorites(BuildContext context) async {
    final playlistService = context.read<PlaylistService>();
    final downloadService = context.read<DownloadService>();
    final videoManager = context.read<VideoPlayerManager>();
    final playlists = await playlistService.getPlaylists();
    final favorites = playlists.firstWhere(
      (playlist) => PlaylistService.isFavoritesPlaylistName(playlist.name),
      orElse: () =>
          app_models.Playlist(name: PlaylistService.favoritesPlaylistName),
    );
    final track = _toVideoHistory();
    await playlistService.addVideoToPlaylist(favorites.name, track);
    if (!item.isLocal) {
      await downloadService.autoDownloadIfEnabledUsingClone(
        favorites.name,
        track,
        videoManager: videoManager,
      );
    }
    if (!context.mounted) return;
    _showQueueSnackBar(context, 'Añadida a Favoritos');
  }

  Future<void> _addItemToPlaylist(BuildContext context) async {
    final playlistService = context.read<PlaylistService>();
    final downloadService = context.read<DownloadService>();
    final videoManager = context.read<VideoPlayerManager>();
    final playlists = await playlistService.getPlaylists();
    if (!context.mounted) return;
    if (playlists.isEmpty) {
      _showQueueSnackBar(context, 'No hay playlists disponibles.');
      return;
    }
    final selectedName = await showGlassPlaylistPickerSheet(
      context: context,
      playlists: playlists,
      subtitle: item.title,
    );
    if (!context.mounted || selectedName == null || selectedName.isEmpty) {
      return;
    }
    final track = _toVideoHistory();
    await playlistService.addVideoToPlaylist(selectedName, track);
    if (!item.isLocal) {
      await downloadService.autoDownloadIfEnabledUsingClone(
        selectedName,
        track,
        videoManager: videoManager,
      );
    }
    if (!context.mounted) return;
    _showQueueSnackBar(context, 'Añadida a $selectedName');
  }

  VideoHistory _toVideoHistory() {
    return VideoHistory(
      videoId: item.videoId,
      title: item.title,
      thumbnailUrl: item.thumbnailUrl,
      channelTitle: item.artist,
      watchedAt: DateTime.now(),
    );
  }

  void _showQueueSnackBar(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _QueueShell extends StatelessWidget {
  final Widget child;

  const _QueueShell({required this.child});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                CupertinoColors.systemGrey6
                    .resolveFrom(context)
                    .withValues(alpha: 0.72),
                CupertinoColors.systemGrey5
                    .resolveFrom(context)
                    .withValues(alpha: 0.52),
              ],
            ),
            border: Border.all(
              color: CupertinoColors.white.withValues(alpha: 0.20),
              width: 0.6,
            ),
            boxShadow: [
              BoxShadow(
                color: CupertinoColors.black.withValues(alpha: 0.10),
                blurRadius: 14,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

class _QueueGlassSheetActionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isDestructive;

  const _QueueGlassSheetActionRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.isDestructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final destructiveColor = CupertinoColors.destructiveRed.resolveFrom(
      context,
    );
    final iconColor = isDestructive
        ? destructiveColor
        : CupertinoColors.label.resolveFrom(context);
    final textColor = isDestructive
        ? destructiveColor
        : CupertinoColors.label.resolveFrom(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Material(
          color: Colors.white.withValues(alpha: 0.05),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () {
              unawaited(HapticFeedback.selectionClick());
              onTap();
            },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: CupertinoColors.white.withValues(alpha: 0.18),
                  width: 0.6,
                ),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withValues(alpha: 0.08),
                    Colors.white.withValues(alpha: 0.02),
                  ],
                ),
              ),
              child: Row(
                children: [
                  Icon(icon, size: 18, color: iconColor),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontFamily: '.SF Pro Text',
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: textColor,
                      ),
                    ),
                  ),
                  Icon(
                    CupertinoIcons.chevron_right,
                    size: 17,
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

  const _NativeControlButton({required this.icon, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      padding: EdgeInsets.zero,
      onPressed: onPressed,
      child: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: CupertinoColors.systemGrey5
              .resolveFrom(context)
              .withValues(alpha: 0.62),
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: CupertinoColors.systemGrey6
                      .resolveFrom(context)
                      .withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: CupertinoColors.white.withValues(alpha: 0.2),
                    width: 0.5,
                  ),
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final maxWidth = constraints.maxWidth;
                    final thumbLeft = (maxWidth * playedRatio - 6).clamp(
                      0.0,
                      maxWidth - 12,
                    );

                    void seekByDx(double localDx) {
                      if (safeTotal <= 1) return;
                      final ratio = (localDx / maxWidth).clamp(0.0, 1.0);
                      manager.seekTo(
                        Duration(milliseconds: (safeTotal * ratio).round()),
                      );
                    }

                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (details) =>
                          seekByDx(details.localPosition.dx),
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
                                  color: CupertinoColors.white.withValues(
                                    alpha: 0.96,
                                  ),
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
                                      color: CupertinoColors.black.withValues(
                                        alpha: 0.22,
                                      ),
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
  final IosLiveLyricsAlignmentService _iosAlignmentService =
      IosLiveLyricsAlignmentService();
  final Map<int, GlobalKey> _syncedLineKeys = <int, GlobalKey>{};
  int _lastSyncedIndex = -1;
  int _lastSyncedLength = 0;
  String? _lastVideoId;
  bool _isAligningWords = false;
  DateTime _lastFollowScrollAt = DateTime.fromMillisecondsSinceEpoch(0);
  String? _alignedTrackKey;
  List<LiveLyricWordTiming> _alignedWords = const [];

  @override
  void dispose() {
    _syncedScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final manager = widget.manager;
    final settings = context.watch<AppSettingsService?>();
    final liveLyricsEnabled = settings?.liveLyrics ?? true;
    unawaited(
      _syncIosWordAlignment(
        manager: manager,
        liveLyricsEnabled: liveLyricsEnabled,
      ),
    );
    if (_lastVideoId != manager.currentVideoId) {
      _lastVideoId = manager.currentVideoId;
      _lastSyncedIndex = -1;
      _lastSyncedLength = 0;
      _syncedLineKeys.clear();
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
      final syncedLyrics = List.of(manager.syncedLyrics);
      if (syncedLyrics.isEmpty) {
        content = Text(manager.lyricsText ?? '', style: textStyle);
      } else {
        if (_lastSyncedLength != syncedLyrics.length) {
          _lastSyncedLength = syncedLyrics.length;
          _syncedLineKeys.clear();
        }
        final rawCurrentIndex = manager.currentSyncedLyricIndex;
        final currentIndex = _resolveDisplayedCurrentIndex(
          baseIndex: rawCurrentIndex.clamp(-1, syncedLyrics.length - 1),
          lyrics: syncedLyrics,
          now: manager.position,
          trackDuration: manager.trackDuration,
          liveLyricsEnabled: liveLyricsEnabled,
        );
        _scrollToCurrentLyric(currentIndex);
        content = ListView.builder(
          key: ValueKey('synced_${manager.currentVideoId}'),
          controller: _syncedScrollController,
          physics: const BouncingScrollPhysics(),
          itemCount: syncedLyrics.length,
          itemBuilder: (context, index) {
            final line = syncedLyrics[index];
            final isActive = index == currentIndex;
            final lineKey = _syncedLineKeys.putIfAbsent(
              index,
              () => GlobalKey(),
            );
            double liveProgress = 0.0;
            if (isActive) {
              final lineStart = line.timestamp;
              final lineEnd = _resolveLineEnd(
                index: index,
                lyrics: syncedLyrics,
                trackDuration: manager.trackDuration,
              );
              final temporalProgress = _temporalProgressForLine(
                lineStart: lineStart,
                lineEnd: lineEnd,
                now: manager.position,
              );
              liveProgress = temporalProgress;
              if (liveLyricsEnabled) {
                final wordBased = _wordProgressForLine(
                  lineText: line.text,
                  lineStart: lineStart,
                  lineEnd: lineEnd,
                  now: manager.position,
                  fallbackProgress: temporalProgress,
                );
                if (wordBased != null) {
                  // Priorizamos progreso por palabra cuando la señal es confiable.
                  liveProgress = wordBased;
                }
              }
            }
            return KeyedSubtree(
              key: lineKey,
              child: AnimatedContainer(
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
                    child: isActive && liveLyricsEnabled
                        ? _LiveLyricSweepText(
                            key: ValueKey(
                              'live_${manager.currentVideoId}_$index',
                            ),
                            text: line.text,
                            progress: liveProgress,
                            baseStyle: textStyle.copyWith(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              color: CupertinoColors.secondaryLabel.resolveFrom(
                                context,
                              ),
                            ),
                            activeStyle: textStyle.copyWith(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          )
                        : Text(
                            line.text,
                            textAlign: TextAlign.left,
                            softWrap: true,
                          ),
                  ),
                ),
              ),
            );
          },
        );
      }
    } else {
      content = Text(manager.lyricsText ?? '', style: textStyle);
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
            color: CupertinoColors.systemGrey6
                .resolveFrom(context)
                .withValues(alpha: 0.40),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: CupertinoColors.white.withValues(alpha: 0.2),
              width: 0.5,
            ),
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 34),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    child: manager.hasSyncedLyrics
                        ? content
                        : SingleChildScrollView(
                            key: ValueKey(
                              '${manager.isLyricsLoading}-${manager.lyricsError}-${manager.lyricsText}',
                            ),
                            physics: const BouncingScrollPhysics(),
                            child: content,
                          ),
                  ),
                ),
              ),
              if (manager.isKaraokeSupported)
                Positioned(
                  right: 2,
                  bottom: 2,
                  child: _LyricsKaraokeButton(
                    isActive: manager.karaokeModeEnabled,
                    isLoading: manager.isAiStemsLoading,
                    onPressed: manager.toggleKaraokeMode,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Duration _resolveLineEnd({
    required int index,
    required List<SyncedLyricLine> lyrics,
    required Duration trackDuration,
  }) {
    final lineStart = lyrics[index].timestamp;
    final nominalEnd = _resolveNominalLineEnd(
      index: index,
      lyrics: lyrics,
      trackDuration: trackDuration,
    );
    final voiceAwareEnd = _resolveVoiceAlignedLineEnd(
      lineText: lyrics[index].text,
      lineStart: lineStart,
      nominalLineEnd: nominalEnd,
    );
    final activityAwareEnd = _resolveVoiceActivityLineEnd(
      lineStart: lineStart,
      nominalLineEnd: nominalEnd,
    );
    Duration resolved = nominalEnd;
    if (voiceAwareEnd != null && voiceAwareEnd > lineStart) {
      resolved = voiceAwareEnd < resolved ? voiceAwareEnd : resolved;
    }
    if (activityAwareEnd != null && activityAwareEnd > lineStart) {
      resolved = activityAwareEnd < resolved ? activityAwareEnd : resolved;
    }
    return resolved;
  }

  Duration _resolveNominalLineEnd({
    required int index,
    required List<SyncedLyricLine> lyrics,
    required Duration trackDuration,
  }) {
    final lineStart = lyrics[index].timestamp;
    for (var i = index + 1; i < lyrics.length; i++) {
      final nextTs = lyrics[i].timestamp;
      if (nextTs > lineStart + const Duration(milliseconds: 120)) {
        return nextTs;
      }
    }
    if (trackDuration > lineStart) return trackDuration;
    return lineStart + const Duration(seconds: 3);
  }

  Duration? _resolveVoiceAlignedLineEnd({
    required String lineText,
    required Duration lineStart,
    required Duration nominalLineEnd,
  }) {
    if (_alignedWords.isEmpty) return null;
    final lineWords = _normalizeWord(
      lineText,
    ).split(' ').where((w) => w.isNotEmpty).toList(growable: false);
    if (lineWords.isEmpty) return null;

    final windowStart = lineStart - const Duration(milliseconds: 700);
    final safeWindowStart = windowStart > Duration.zero
        ? windowStart
        : Duration.zero;
    final windowEnd = nominalLineEnd + const Duration(milliseconds: 350);
    final candidateWords = _alignedWords
        .where(
          (w) =>
              w.end >= safeWindowStart &&
              w.start <= windowEnd &&
              w.confidence >= 0.22,
        )
        .toList(growable: false);
    if (candidateWords.isEmpty) return null;

    final candidateNormalized = candidateWords
        .map((w) => _normalizeWord(w.word))
        .toList(growable: false);
    final matches = _alignLyricWordsToCandidates(
      lineWords: lineWords,
      candidateWords: candidateNormalized,
      candidateSegments: candidateWords,
    );

    var matchedCount = 0;
    var matchedSimilarity = 0.0;
    Duration? lastMatchedEnd;
    for (var i = 0; i < lineWords.length; i++) {
      final mapped = matches[i];
      if (mapped < 0 || mapped >= candidateWords.length) continue;
      final similarity = _wordSimilarity(
        lineWords[i],
        candidateNormalized[mapped],
      );
      if (similarity < 0.54) continue;
      matchedCount++;
      matchedSimilarity += similarity;
      final end = candidateWords[mapped].end;
      if (lastMatchedEnd == null || end > lastMatchedEnd) {
        lastMatchedEnd = end;
      }
    }
    if (matchedCount == 0 || lastMatchedEnd == null) return null;

    final coverage = matchedCount / lineWords.length;
    final avgSimilarity = matchedSimilarity / matchedCount;
    if (coverage < 0.34 && avgSimilarity < 0.68) return null;

    // Ajuste para que la línea termine cuando acaba la última palabra cantada,
    // sin arrastrar silencios hasta el siguiente timestamp.
    final voiceEnd = lastMatchedEnd + const Duration(milliseconds: 95);
    final minValidEnd = lineStart + const Duration(milliseconds: 220);
    if (voiceEnd < minValidEnd) return null;
    if (voiceEnd < nominalLineEnd) {
      return voiceEnd;
    }
    return nominalLineEnd;
  }

  Duration? _resolveVoiceActivityLineEnd({
    required Duration lineStart,
    required Duration nominalLineEnd,
  }) {
    if (_alignedWords.isEmpty) return null;
    final windowStart = lineStart - const Duration(milliseconds: 160);
    final safeWindowStart = windowStart > Duration.zero
        ? windowStart
        : Duration.zero;
    final candidates = _alignedWords
        .where(
          (w) =>
              w.end >= safeWindowStart &&
              w.start <= nominalLineEnd &&
              w.confidence >= 0.16,
        )
        .toList(growable: false);
    if (candidates.isEmpty) return null;

    Duration? lastSpeechEnd;
    for (final w in candidates) {
      final end = w.end <= nominalLineEnd ? w.end : nominalLineEnd;
      if (end < lineStart + const Duration(milliseconds: 140)) continue;
      if (lastSpeechEnd == null || end > lastSpeechEnd) {
        lastSpeechEnd = end;
      }
    }
    if (lastSpeechEnd == null) return null;

    final trailingGap = nominalLineEnd - lastSpeechEnd;
    // Si al final de la línea hay hueco largo sin voz, terminamos antes
    // aunque siga instrumental/fondo.
    if (trailingGap >= const Duration(milliseconds: 520)) {
      final clamped = lastSpeechEnd + const Duration(milliseconds: 85);
      final minValid = lineStart + const Duration(milliseconds: 220);
      if (clamped > minValid) return clamped;
    }
    return null;
  }

  double _temporalProgressForLine({
    required Duration lineStart,
    required Duration lineEnd,
    required Duration now,
  }) {
    final spanMs = (lineEnd - lineStart).inMilliseconds;
    if (spanMs <= 0) return 1.0;
    final elapsedMs = (now - lineStart).inMilliseconds;
    return (elapsedMs / spanMs).clamp(0.0, 1.0);
  }

  int _resolveDisplayedCurrentIndex({
    required int baseIndex,
    required List<SyncedLyricLine> lyrics,
    required Duration now,
    required Duration trackDuration,
    required bool liveLyricsEnabled,
  }) {
    if (lyrics.isEmpty) return -1;
    if (!liveLyricsEnabled || _alignedWords.isEmpty) return baseIndex;

    // Antes del primer timestamp: si ya detectamos la primera línea en voz,
    // activamos de inmediato para evitar que el barrido entre tarde.
    if (baseIndex < 0) {
      final firstEnd = _resolveLineEnd(
        index: 0,
        lyrics: lyrics,
        trackDuration: trackDuration,
      );
      final firstProgress = _wordProgressForLine(
        lineText: lyrics.first.text,
        lineStart: lyrics.first.timestamp,
        lineEnd: firstEnd,
        now: now,
        fallbackProgress: 0.0,
      );
      if ((firstProgress ?? 0.0) >= 0.06) return 0;
      return -1;
    }

    if (baseIndex >= lyrics.length - 1) return baseIndex;
    final currentLine = lyrics[baseIndex];
    final nextLine = lyrics[baseIndex + 1];
    final currentEnd = _resolveLineEnd(
      index: baseIndex,
      lyrics: lyrics,
      trackDuration: trackDuration,
    );
    final nextEnd = _resolveLineEnd(
      index: baseIndex + 1,
      lyrics: lyrics,
      trackDuration: trackDuration,
    );
    final currentTemporal = _temporalProgressForLine(
      lineStart: currentLine.timestamp,
      lineEnd: currentEnd,
      now: now,
    );
    final nextTemporal = _temporalProgressForLine(
      lineStart: nextLine.timestamp,
      lineEnd: nextEnd,
      now: now,
    );
    final currentWord =
        _wordProgressForLine(
          lineText: currentLine.text,
          lineStart: currentLine.timestamp,
          lineEnd: currentEnd,
          now: now,
          fallbackProgress: currentTemporal,
        ) ??
        currentTemporal;
    final nextWord = _wordProgressForLine(
      lineText: nextLine.text,
      lineStart: nextLine.timestamp,
      lineEnd: nextEnd,
      now: now,
      fallbackProgress: nextTemporal,
    );

    final remainingToCurrentEnd = currentEnd - now;
    final remainingToNext = nextLine.timestamp - now;
    final nearTransition =
        remainingToCurrentEnd <= const Duration(milliseconds: 1400);
    final currentDone = currentWord >= 0.93 || currentTemporal >= 0.985;
    final nextHasLead = (nextWord ?? 0.0) >= 0.08;

    if (now >= currentEnd + const Duration(milliseconds: 110)) {
      return baseIndex + 1;
    }
    if (nearTransition && currentDone && nextHasLead) {
      return baseIndex + 1;
    }
    if (currentWord >= 0.985 &&
        remainingToNext > Duration.zero &&
        remainingToNext <= const Duration(milliseconds: 900)) {
      return baseIndex + 1;
    }
    return baseIndex;
  }

  void _scrollToCurrentLyric(int currentIndex) {
    if (currentIndex < 0) return;
    final now = DateTime.now();
    final sameIndex = currentIndex == _lastSyncedIndex;
    final canResolveTargetNow = _canResolveLyricTarget(currentIndex);
    final minFollowGap = canResolveTargetNow
        ? const Duration(milliseconds: 650)
        : const Duration(milliseconds: 180);
    if (sameIndex && now.difference(_lastFollowScrollAt) < minFollowGap) {
      return;
    }
    _lastSyncedIndex = currentIndex;
    _lastFollowScrollAt = now;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_syncedScrollController.hasClients) return;
      final targetKey = _syncedLineKeys[currentIndex];
      final targetContext = targetKey?.currentContext;
      final targetRenderObject = targetContext?.findRenderObject();
      if (targetRenderObject != null) {
        try {
          _syncedScrollController.position.ensureVisible(
            targetRenderObject,
            alignment: 0.35,
            duration: const Duration(milliseconds: 420),
            curve: Curves.easeInOutCubicEmphasized,
          );
          return;
        } catch (_) {
          // Intentamos fallback por offset aproximado.
        }
      }
      _scrollTowardsCurrentLyricFallback(currentIndex);
    });
  }

  bool _canResolveLyricTarget(int index) {
    final key = _syncedLineKeys[index];
    final ctx = key?.currentContext;
    if (ctx == null) return false;
    return ctx.findRenderObject() != null;
  }

  void _scrollTowardsCurrentLyricFallback(int currentIndex) {
    if (!_syncedScrollController.hasClients) return;
    final position = _syncedScrollController.position;
    if (!position.hasContentDimensions) return;

    const estimatedLineExtent = 44.0;
    const desiredAlignment = 0.35;
    final viewport = position.viewportDimension;
    final estimatedOffset =
        (currentIndex * estimatedLineExtent) - (viewport * desiredAlignment);
    final targetOffset = estimatedOffset.clamp(0.0, position.maxScrollExtent);
    final currentOffset = _syncedScrollController.offset;
    if ((targetOffset - currentOffset).abs() < 6) return;

    _syncedScrollController.animateTo(
      targetOffset,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _syncIosWordAlignment({
    required VideoPlayerManager manager,
    required bool liveLyricsEnabled,
  }) async {
    if (_isAligningWords) return;
    final shouldRun =
        liveLyricsEnabled &&
        manager.isLyricsLayout &&
        manager.hasSyncedLyrics &&
        manager.isPlaying &&
        manager.isLocal &&
        !kIsWeb &&
        Platform.isIOS;
    if (!shouldRun) {
      _alignedTrackKey = null;
      _alignedWords = const [];
      return;
    }

    final filePath = manager.currentStreamUrl?.trim() ?? '';
    final trackId = manager.currentVideoId?.trim() ?? '';
    if (filePath.isEmpty || trackId.isEmpty) return;
    final key = '$trackId::$filePath';
    if (_alignedTrackKey == key && _alignedWords.isNotEmpty) return;

    _isAligningWords = true;
    try {
      final words = await _iosAlignmentService.transcribeLocalFile(
        filePath: filePath,
      );
      if (!mounted) return;
      _alignedTrackKey = key;
      _alignedWords = words;
      setState(() {});
    } finally {
      _isAligningWords = false;
    }
  }

  String _normalizeWord(String value) {
    return _stripDiacritics(value.toLowerCase())
        .toLowerCase()
        .replaceAll(RegExp(r"[^\p{L}\p{N}\s]", unicode: true), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _stripDiacritics(String value) {
    return value
        .replaceAll(RegExp(r'[àáâãäåāăą]'), 'a')
        .replaceAll(RegExp(r'[èéêëēĕėęě]'), 'e')
        .replaceAll(RegExp(r'[ìíîïĩīĭįı]'), 'i')
        .replaceAll(RegExp(r'[òóôõöøōŏő]'), 'o')
        .replaceAll(RegExp(r'[ùúûüũūŭůűų]'), 'u')
        .replaceAll(RegExp(r'[ýÿŷ]'), 'y')
        .replaceAll(RegExp(r'[ñ]'), 'n')
        .replaceAll(RegExp(r'[ç]'), 'c');
  }

  double _wordSimilarity(String a, String b) {
    if (a == b) return 1.0;
    if (a.isEmpty || b.isEmpty) return 0.0;
    if (a.length >= 4 &&
        b.length >= 4 &&
        (a.startsWith(b) || b.startsWith(a))) {
      return 0.92;
    }
    final distance = _levenshteinDistance(a, b);
    final longest = math.max(a.length, b.length);
    if (longest == 0) return 0.0;
    return (1.0 - (distance / longest)).clamp(0.0, 1.0);
  }

  int _levenshteinDistance(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    final prev = List<int>.generate(b.length + 1, (j) => j);
    final curr = List<int>.filled(b.length + 1, 0);
    for (var i = 1; i <= a.length; i++) {
      curr[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        curr[j] = math.min(
          math.min(curr[j - 1] + 1, prev[j] + 1),
          prev[j - 1] + cost,
        );
      }
      for (var j = 0; j <= b.length; j++) {
        prev[j] = curr[j];
      }
    }
    return prev[b.length];
  }

  List<int> _alignLyricWordsToCandidates({
    required List<String> lineWords,
    required List<String> candidateWords,
    required List<LiveLyricWordTiming> candidateSegments,
  }) {
    final n = lineWords.length;
    final m = candidateWords.length;
    if (n == 0 || m == 0) return List<int>.filled(n, -1);

    const skipLyricPenalty = -0.30;
    const skipCandidatePenalty = -0.18;
    const minMatchScore = 0.46;
    const lowMatchPenalty = -0.50;

    final dp = List<List<double>>.generate(
      n + 1,
      (_) => List<double>.filled(m + 1, 0.0),
    );
    final backtrack = List<List<int>>.generate(
      n + 1,
      (_) => List<int>.filled(m + 1, 0),
    );

    for (var i = 1; i <= n; i++) {
      dp[i][0] = i * skipLyricPenalty;
      backtrack[i][0] = 2;
    }
    for (var j = 1; j <= m; j++) {
      dp[0][j] = j * skipCandidatePenalty;
      backtrack[0][j] = 3;
    }

    for (var i = 1; i <= n; i++) {
      for (var j = 1; j <= m; j++) {
        final similarity = _wordSimilarity(
          lineWords[i - 1],
          candidateWords[j - 1],
        );
        final confidence = candidateSegments[j - 1].confidence;
        final matchBonus = similarity >= minMatchScore
            ? similarity * (0.78 + (confidence * 0.35))
            : lowMatchPenalty;
        final diag = dp[i - 1][j - 1] + matchBonus;
        final up = dp[i - 1][j] + skipLyricPenalty;
        final left = dp[i][j - 1] + skipCandidatePenalty;

        if (diag >= up && diag >= left) {
          dp[i][j] = diag;
          backtrack[i][j] = 1;
        } else if (up >= left) {
          dp[i][j] = up;
          backtrack[i][j] = 2;
        } else {
          dp[i][j] = left;
          backtrack[i][j] = 3;
        }
      }
    }

    final matches = List<int>.filled(n, -1);
    var i = n;
    var j = m;
    while (i > 0 || j > 0) {
      final action = backtrack[i][j];
      if (action == 1 && i > 0 && j > 0) {
        final similarity = _wordSimilarity(
          lineWords[i - 1],
          candidateWords[j - 1],
        );
        if (similarity >= minMatchScore) {
          matches[i - 1] = j - 1;
        }
        i--;
        j--;
      } else if (action == 2 && i > 0) {
        i--;
      } else if (action == 3 && j > 0) {
        j--;
      } else {
        break;
      }
    }
    return matches;
  }

  double? _wordProgressForLine({
    required String lineText,
    required Duration lineStart,
    required Duration lineEnd,
    required Duration now,
    required double fallbackProgress,
  }) {
    if (_alignedWords.isEmpty) return null;
    final windowStart = lineStart - const Duration(milliseconds: 700);
    final safeWindowStart = windowStart > Duration.zero
        ? windowStart
        : Duration.zero;
    final windowEnd = lineEnd + const Duration(milliseconds: 550);
    final candidateWords = _alignedWords
        .where(
          (w) =>
              w.end >= safeWindowStart &&
              w.start <= windowEnd &&
              w.confidence >= 0.26,
        )
        .toList(growable: false);
    if (candidateWords.isEmpty) return null;

    final lineWords = _normalizeWord(
      lineText,
    ).split(' ').where((w) => w.isNotEmpty).toList(growable: false);
    if (lineWords.isEmpty) return null;

    final candidateNormalized = candidateWords
        .map((w) => _normalizeWord(w.word))
        .toList(growable: false);
    final matches = _alignLyricWordsToCandidates(
      lineWords: lineWords,
      candidateWords: candidateNormalized,
      candidateSegments: candidateWords,
    );

    final lineSpanMs = math.max(850, (lineEnd - lineStart).inMilliseconds);
    final lineStartMs = lineStart.inMilliseconds;
    final wordCount = lineWords.length;

    var weightedProgress = 0.0;
    var totalWeight = 0.0;
    var matchedTotal = 0;
    var matchedSimilarity = 0.0;

    for (var idx = 0; idx < wordCount; idx++) {
      final matchedIndex = matches[idx];
      double partialProgress;
      double weight;

      if (matchedIndex >= 0 && matchedIndex < candidateWords.length) {
        final segment = candidateWords[matchedIndex];
        final spanMs = math.max(
          90,
          (segment.end - segment.start).inMilliseconds,
        );
        final elapsedMs = (now - segment.start).inMilliseconds;
        partialProgress = (elapsedMs / spanMs).clamp(0.0, 1.0);
        final similarity = _wordSimilarity(
          lineWords[idx],
          candidateNormalized[matchedIndex],
        );
        matchedSimilarity += similarity;
        matchedTotal++;
        final confidenceWeight =
            0.72 + (segment.confidence.clamp(0.0, 1.0) * 0.38);
        final similarityWeight = 0.65 + (similarity * 0.45);
        weight = confidenceWeight * similarityWeight;
      } else {
        final startMs = lineStartMs + ((lineSpanMs * idx) ~/ wordCount);
        final endMs = lineStartMs + ((lineSpanMs * (idx + 1)) ~/ wordCount);
        final spanMs = math.max(90, endMs - startMs);
        final elapsedMs = now.inMilliseconds - startMs;
        partialProgress = (elapsedMs / spanMs).clamp(0.0, 1.0);
        weight = 0.52;
      }

      weightedProgress += partialProgress * weight;
      totalWeight += weight;
    }

    if (matchedTotal == 0 || totalWeight <= 0.0) return null;
    final coverage = matchedTotal / wordCount;
    final avgSimilarity = matchedSimilarity / matchedTotal;
    if (coverage < 0.20 && avgSimilarity < 0.58) return null;

    final wordProgress = (weightedProgress / totalWeight).clamp(0.0, 1.0);
    final trust = ((coverage * 0.72) + (avgSimilarity * 0.28)).clamp(0.0, 1.0);
    final fallbackWeight = (0.58 - (trust * 0.46)).clamp(0.14, 0.58);
    final blended =
        (wordProgress * (1 - fallbackWeight)) +
        (fallbackProgress * fallbackWeight);
    final maxAhead = (fallbackProgress + 0.12 + (trust * 0.16)).clamp(0.0, 1.0);
    final minBehind = (fallbackProgress - 0.28).clamp(0.0, 1.0);
    return blended.clamp(minBehind, maxAhead);
  }
}

class _LyricsKaraokeButton extends StatefulWidget {
  final bool isActive;
  final bool isLoading;
  final VoidCallback onPressed;

  const _LyricsKaraokeButton({
    required this.isActive,
    required this.isLoading,
    required this.onPressed,
  });

  @override
  State<_LyricsKaraokeButton> createState() => _LyricsKaraokeButtonState();
}

class _LyricsKaraokeButtonState extends State<_LyricsKaraokeButton>
    with TickerProviderStateMixin {
  AnimationController? _ringController;

  @override
  void initState() {
    super.initState();
    _ensureController();
  }

  @override
  void didUpdateWidget(covariant _LyricsKaraokeButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    _ensureController();
    if (oldWidget.isActive == widget.isActive) return;
    _ringController!.duration = widget.isActive
        ? const Duration(milliseconds: 1200)
        : const Duration(milliseconds: 2300);
    _ringController!
      ..reset()
      ..repeat();
  }

  @override
  void dispose() {
    _ringController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _ensureController();
    return AnimatedBuilder(
      animation: _ringController!,
      builder: (context, _) {
        final borderRadius = BorderRadius.circular(16);
        const activeColor = Color(0xFFFF4778);
        const activeSecondary = Color(0xFFFF9B54);
        return CupertinoButton(
          padding: EdgeInsets.zero,
          minimumSize: Size.zero,
          onPressed: widget.onPressed,
          child: Container(
            padding: const EdgeInsets.all(1.35),
            decoration: BoxDecoration(
              borderRadius: borderRadius,
              gradient: SweepGradient(
                transform: GradientRotation(_ringController!.value * 6.2831853),
                colors: const [
                  Color(0xFFFF4778),
                  Color(0xFFFF6B4A),
                  Color(0xFFFFA43D),
                  Color(0xFFFF4778),
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: activeColor.withValues(
                    alpha: widget.isActive ? 0.36 : 0.16,
                  ),
                  blurRadius: widget.isActive ? 16 : 9,
                  spreadRadius: widget.isActive ? 0.8 : 0.0,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: borderRadius,
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: widget.isActive
                        ? activeColor.withValues(alpha: 0.24)
                        : CupertinoColors.systemGrey6
                              .resolveFrom(context)
                              .withValues(alpha: 0.52),
                    borderRadius: borderRadius,
                  ),
                  child: widget.isLoading
                      ? CupertinoActivityIndicator(
                          radius: 8,
                          color: widget.isActive
                              ? activeSecondary
                              : CupertinoColors.label.resolveFrom(context),
                        )
                      : Icon(
                          CupertinoIcons.mic_fill,
                          size: 18,
                          color: widget.isActive
                              ? activeSecondary
                              : CupertinoColors.label.resolveFrom(context),
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
    if (_ringController != null) return;
    _ringController = AnimationController(
      vsync: this,
      duration: widget.isActive
          ? const Duration(milliseconds: 1200)
          : const Duration(milliseconds: 2300),
    )..repeat();
  }
}

class _LiveLyricSweepText extends StatelessWidget {
  final String text;
  final double progress;
  final TextStyle baseStyle;
  final TextStyle activeStyle;

  const _LiveLyricSweepText({
    super.key,
    required this.text,
    required this.progress,
    required this.baseStyle,
    required this.activeStyle,
  });

  static const Duration _sweepAnimationDuration = Duration(milliseconds: 280);
  static const double _sweepFeather = 0.11;

  @override
  Widget build(BuildContext context) {
    final targetProgress = progress.clamp(0.0, 1.0);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: targetProgress),
      duration: _sweepAnimationDuration,
      curve: Curves.easeOutCubic,
      builder: (context, animatedProgress, _) {
        final p = animatedProgress.clamp(0.0, 1.0);
        return LayoutBuilder(
          builder: (context, constraints) {
            final maxWidth = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : MediaQuery.sizeOf(context).width;

            final lines = _wrapIntoLines(
              text: text,
              style: activeStyle,
              maxWidth: maxWidth,
              textDirection: Directionality.of(context),
            );
            if (lines.isEmpty) {
              return Text(
                text,
                textAlign: TextAlign.left,
                softWrap: true,
                style: baseStyle,
              );
            }

            final weights = lines
                .map((line) => math.max(1, line.trim().runes.length))
                .toList(growable: false);
            final totalWeight = weights.fold<int>(0, (sum, w) => sum + w);

            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < lines.length; i++)
                  _buildSweepLine(
                    line: lines[i],
                    globalProgress: p,
                    lineWeight: weights[i],
                    cumulativeWeightBefore: weights
                        .take(i)
                        .fold<int>(0, (sum, w) => sum + w),
                    totalWeight: totalWeight,
                  ),
              ],
            );
          },
        );
      },
    );
  }

  List<String> _wrapIntoLines({
    required String text,
    required TextStyle style,
    required double maxWidth,
    required TextDirection textDirection,
  }) {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) return const [];
    final words = normalized.split(' ').where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return const [];

    double widthFor(String value) {
      final painter = TextPainter(
        text: TextSpan(text: value, style: style),
        textDirection: textDirection,
        maxLines: 1,
      )..layout(maxWidth: double.infinity);
      return painter.width;
    }

    final lines = <String>[];
    var current = '';
    var index = 0;
    while (index < words.length) {
      final word = words[index];
      final candidate = current.isEmpty ? word : '$current $word';
      final fits = widthFor(candidate) <= maxWidth || current.isEmpty;

      if (fits) {
        current = candidate;
        index++;
        continue;
      }

      lines.add(current);
      current = '';
    }

    if (current.isNotEmpty) {
      lines.add(current);
    }
    return lines;
  }

  Widget _buildSweepLine({
    required String line,
    required double globalProgress,
    required int lineWeight,
    required int cumulativeWeightBefore,
    required int totalWeight,
  }) {
    final startShare = cumulativeWeightBefore / totalWeight;
    final endShare = (cumulativeWeightBefore + lineWeight) / totalWeight;
    final span = math.max(0.0001, endShare - startShare);
    final localProgress = ((globalProgress - startShare) / span).clamp(
      0.0,
      1.0,
    );
    final easedProgress = Curves.easeInOutCubic.transform(localProgress);

    final softFeather = (_sweepFeather + ((1 - easedProgress) * 0.03)).clamp(
      0.09,
      0.15,
    );
    final softStart = (easedProgress - softFeather).clamp(0.0, 1.0);
    final softMidLeft = (easedProgress - (softFeather * 0.42)).clamp(0.0, 1.0);
    final softMidRight = (easedProgress + (softFeather * 0.42)).clamp(0.0, 1.0);
    final softEdge = (easedProgress + softFeather).clamp(0.0, 1.0);

    final glowHalf = (0.075 + ((1 - easedProgress) * 0.02)).clamp(0.06, 0.11);
    final glowStart = (easedProgress - glowHalf).clamp(0.0, 1.0);
    final glowInnerStart = (easedProgress - (glowHalf * 0.4)).clamp(0.0, 1.0);
    final glowInnerEnd = (easedProgress + (glowHalf * 0.4)).clamp(0.0, 1.0);
    final glowEnd = (easedProgress + glowHalf).clamp(0.0, 1.0);
    final baseActiveColor = activeStyle.color ?? const Color(0xFFFFFFFF);

    return Padding(
      padding: const EdgeInsets.only(bottom: 1),
      child: Stack(
        children: [
          Text(
            line,
            textAlign: TextAlign.left,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: baseStyle,
          ),
          ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (rect) {
              return LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: const [
                  Color(0xFFFFFFFF),
                  Color(0xFFFFFFFF),
                  Color(0xF3FFFFFF),
                  Color(0xD6FFFFFF),
                  Color(0x8AFFFFFF),
                  Color(0x00000000),
                  Color(0x00000000),
                ],
                stops: [
                  0.0,
                  softStart,
                  softMidLeft,
                  easedProgress,
                  softMidRight,
                  softEdge,
                  1.0,
                ],
              ).createShader(rect);
            },
            child: Text(
              line,
              textAlign: TextAlign.left,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: activeStyle,
            ),
          ),
          // Banda de brillo sutil en el frente del barrido.
          ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (rect) {
              return LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: const [
                  Color(0x00000000),
                  Color(0x33FFFFFF),
                  Color(0xE0FFFFFF),
                  Color(0x33FFFFFF),
                  Color(0x00000000),
                ],
                stops: [
                  glowStart,
                  glowInnerStart,
                  easedProgress,
                  glowInnerEnd,
                  glowEnd,
                ],
              ).createShader(rect);
            },
            child: Text(
              line,
              textAlign: TextAlign.left,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: activeStyle.copyWith(
                color: Colors.white.withValues(alpha: 0.90),
                shadows: [
                  Shadow(
                    color: baseActiveColor.withValues(alpha: 0.40),
                    blurRadius: 14,
                  ),
                  Shadow(
                    color: Colors.white.withValues(alpha: 0.22),
                    blurRadius: 8,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ArtworkImage extends StatefulWidget {
  final String? url;
  final double size;
  final bool animated;
  final bool isPlaying;
  final double motionEnergy;
  final double borderRadius;

  const _ArtworkImage({
    super.key,
    required this.url,
    required this.size,
    this.animated = false,
    this.isPlaying = false,
    this.motionEnergy = 1.0,
    this.borderRadius = 20,
  });

  @override
  State<_ArtworkImage> createState() => _ArtworkImageState();
}

class _SubjectMotionProfile {
  final Alignment alignment;
  final double moveScale;
  final double tiltScale;
  final double zoomBoost;
  final int styleVariant;

  const _SubjectMotionProfile({
    required this.alignment,
    required this.moveScale,
    required this.tiltScale,
    required this.zoomBoost,
    required this.styleVariant,
  });
}

class _FocusObjectLayer {
  final Uint8List bytes;
  final Alignment alignment;
  final double areaRatio;

  const _FocusObjectLayer({
    required this.bytes,
    required this.alignment,
    required this.areaRatio,
  });
}

class _ArtworkImageState extends State<_ArtworkImage>
    with TickerProviderStateMixin {
  AnimationController? _motionController;
  AnimationController? _pulseController;
  // 0 desactiva por completo la capa de sujeto; 1.0 mantiene tamaño natural.
  static const double _subjectSizeMultiplier = 0.0;
  static const int _maxArtworkCacheEntries = 120;
  static final AiCoverAnimationService _aiCoverAnimationService =
      AiCoverAnimationService();
  static final Map<String, Color> _paletteCache = <String, Color>{};
  static final Map<String, Future<Color?>> _paletteRequests =
      <String, Future<Color?>>{};
  static final Map<String, Uint8List?> _subjectCutoutCache =
      <String, Uint8List?>{};
  static final Map<String, Future<Uint8List?>> _subjectCutoutRequests =
      <String, Future<Uint8List?>>{};
  static final Map<String, Uint8List?> _imageBytesCache =
      <String, Uint8List?>{};
  static final Map<String, Future<Uint8List?>> _imageBytesRequests =
      <String, Future<Uint8List?>>{};
  static final Map<String, _SubjectMotionProfile?> _subjectProfileCache =
      <String, _SubjectMotionProfile?>{};
  static final Map<String, Future<_SubjectMotionProfile?>>
  _subjectProfileRequests = <String, Future<_SubjectMotionProfile?>>{};
  static final Map<String, _FocusObjectLayer?> _focusObjectCache =
      <String, _FocusObjectLayer?>{};
  static final Map<String, Future<_FocusObjectLayer?>> _focusObjectRequests =
      <String, Future<_FocusObjectLayer?>>{};
  Color _dominantColor = CupertinoColors.systemBlue;
  String? _lastPaletteUrl;
  Uint8List? _subjectCutoutBytes;
  String? _lastSubjectUrl;
  _SubjectMotionProfile? _subjectMotionProfile;
  String? _lastSubjectProfileUrl;
  _FocusObjectLayer? _focusObjectLayer;
  String? _lastFocusObjectUrl;
  String? _aiAnimatedCoverUrl;
  String? _lastAiCoverSource;
  bool _isResolvingAiCover = false;
  DateTime _lastAiCoverAttemptAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _aiCoverRetryDelay = Duration(seconds: 12);
  VideoPlayerController? _aiVideoControllerA;
  VideoPlayerController? _aiVideoControllerB;
  VideoPlayerController? _aiActiveVideoController;
  VideoPlayerController? _aiStandbyVideoController;
  AnimationController? _aiLoopBlendController;
  Timer? _aiLoopSwapTimer;
  int _aiLoopToken = 0;
  static const Duration _aiLoopCrossfadeDuration = Duration(milliseconds: 280);
  static const Duration _aiLoopSwapLeadTime = Duration(milliseconds: 360);
  String? _aiVideoSource;
  bool _aiVideoReady = false;

  @override
  void initState() {
    super.initState();
    _syncAnimationControllers(initial: true);
    if (widget.animated) {
      unawaited(_resolveAiAnimatedCover());
      unawaited(_resolveArtworkColor());
      unawaited(_resolveSubjectCutout());
    }
  }

  @override
  void didUpdateWidget(covariant _ArtworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animated != widget.animated ||
        oldWidget.isPlaying != widget.isPlaying) {
      _syncAnimationControllers();
    }
    if (oldWidget.url != widget.url) {
      if (widget.animated) {
        unawaited(_resolveAiAnimatedCover());
        unawaited(_resolveArtworkColor());
        unawaited(_resolveSubjectCutout());
      } else {
        _aiAnimatedCoverUrl = null;
        _lastAiCoverSource = null;
        _aiVideoReady = false;
        _aiVideoSource = null;
        _aiLoopToken++;
        unawaited(_disposeAiVideoControllers());
        _lastPaletteUrl = null;
        _lastSubjectUrl = null;
        _lastSubjectProfileUrl = null;
        _subjectMotionProfile = null;
        _lastFocusObjectUrl = null;
        _focusObjectLayer = null;
        if (_subjectCutoutBytes != null && mounted) {
          setState(() {
            _subjectCutoutBytes = null;
          });
        } else {
          _subjectCutoutBytes = null;
        }
      }
    } else if (!oldWidget.animated && widget.animated) {
      unawaited(_resolveAiAnimatedCover());
    } else if (oldWidget.animated && !widget.animated) {
      _aiVideoReady = false;
      _aiVideoSource = null;
      _aiLoopToken++;
      unawaited(_disposeAiVideoControllers());
    }
  }

  @override
  void dispose() {
    _motionController?.dispose();
    _pulseController?.dispose();
    _aiLoopToken++;
    _aiLoopSwapTimer?.cancel();
    _aiLoopBlendController?.dispose();
    unawaited(_disposeAiVideoControllers());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettingsService?>();
    final dataSaverMode = settings?.dataSaverMode ?? false;
    _maybeResolveAiAnimatedCover();
    final displayImageSource = _displayArtworkSourceUrl();
    final hasImage = displayImageSource.isNotEmpty;
    final isAiVideoSource = _looksLikeVideoSource(displayImageSource);
    final fallbackStillSource = widget.url?.trim() ?? '';
    _syncAiVideoControllerForSource(displayImageSource);
    final animatedCutoutEnabled = settings?.animatedCutoutCovers ?? true;
    final hasAiAnimatedCandidate =
        widget.animated &&
        (_aiAnimatedCoverUrl != null && _aiAnimatedCoverUrl!.trim().isNotEmpty);
    // Cuando ya existe resultado IA, evitamos el parallax manual para no
    // enmascarar la animación generativa de objetos/personas.
    final enableMotion =
        widget.animated &&
        hasImage &&
        animatedCutoutEnabled &&
        !hasAiAnimatedCandidate;
    final enableObjectMotion =
        widget.animated && hasImage && animatedCutoutEnabled;

    if (!widget.animated) {
      return _buildStaticArtworkFrame(
        context,
        imageSource: displayImageSource,
        hasImage: hasImage,
        preferLowResolution: dataSaverMode,
      );
    }
    final motionController = _motionController;
    final pulseController = _pulseController;
    if (motionController == null || pulseController == null) {
      return _buildStaticArtworkFrame(
        context,
        imageSource: displayImageSource,
        hasImage: hasImage,
        preferLowResolution: dataSaverMode,
      );
    }

    final artworkChild = hasImage
        ? (isAiVideoSource && _aiVideoReady && _aiActiveVideoController != null
              ? _buildAnimatedVideoCover()
              : _buildArtworkImage(
                  context,
                  imageSource: isAiVideoSource
                      ? (fallbackStillSource.isNotEmpty
                            ? fallbackStillSource
                            : displayImageSource)
                      : displayImageSource,
                  preferLowResolution: dataSaverMode,
                ))
        : Icon(
            Icons.music_note_rounded,
            size: widget.size * 0.4,
            color: Theme.of(context).colorScheme.primary,
          );
    if (animatedCutoutEnabled &&
        widget.animated &&
        hasImage &&
        _subjectCutoutBytes == null) {
      unawaited(_resolveSubjectCutout());
    }

    return SizedBox.square(
      dimension: widget.size,
      child: AnimatedBuilder(
        animation: Listenable.merge([motionController, pulseController]),
        child: artworkChild,
        builder: (context, child) {
          final turn = motionController.value * math.pi * 2;
          final playFactor = widget.isPlaying ? 1.0 : 0.38;
          final energy = widget.motionEnergy.clamp(0.78, 1.32);
          final motionGain = playFactor * energy;
          final glowColor = _enhanceGlowColor(_dominantColor);
          final profile = _subjectMotionProfile;
          final subjectMoveScale = profile?.moveScale ?? 1.0;
          final subjectTiltScale = profile?.tiltScale ?? 1.0;
          final subjectZoomBoost = profile?.zoomBoost ?? 0.0;
          final subjectStyle =
              profile?.styleVariant ?? _subjectMotionStyleForUrl(widget.url);
          final motionSeedX = _stableNoiseFromString(widget.url, salt: 1);
          final motionSeedY = _stableNoiseFromString(widget.url, salt: 2);
          final phaseA = motionSeedX * math.pi * 2;
          final phaseB = motionSeedY * math.pi * 2;

          final dx = enableMotion
              ? ((math.sin(turn * 0.86 + phaseA) * widget.size * 0.0096) +
                        (math.sin(turn * 1.73 + phaseB) *
                            widget.size *
                            0.0038)) *
                    motionGain *
                    subjectMoveScale
              : 0.0;
          final dy = enableMotion
              ? ((math.cos(turn * 0.92 + phaseB) * widget.size * 0.0084) +
                        (math.cos(turn * 1.61 + phaseA) *
                            widget.size *
                            0.0035)) *
                    motionGain *
                    subjectMoveScale
              : 0.0;
          // Overscan base para evitar huecos en bordes al aplicar translate/tilt.
          final baseArtworkScale = enableMotion
              ? (1.10 + ((energy - 0.78) * 0.03)).clamp(1.10, 1.16)
              : 1.0;
          final zoom = enableMotion
              ? baseArtworkScale +
                    (math.sin(turn * 0.94 + phaseA) * 0.020 * motionGain) +
                    (subjectZoomBoost * 0.018)
              : 1.0;
          final tilt = enableMotion
              ? math.sin(turn * 1.92 + phaseB) *
                    0.012 *
                    motionGain *
                    subjectTiltScale
              : 0.0;
          final warpX = enableMotion
              ? math.sin(turn * 2.84 + phaseA) *
                    0.018 *
                    motionGain *
                    subjectTiltScale
              : 0.0;
          final warpY = enableMotion
              ? math.cos(turn * 1.76 + phaseB) *
                    0.015 *
                    motionGain *
                    subjectTiltScale
              : 0.0;
          final glow = enableMotion
              ? (0.36 + (pulseController.value * 0.34)) *
                    (widget.isPlaying ? 1.0 : 0.56) *
                    (0.86 + (energy - 0.78) * 0.42)
              : 0.0;
          final baseAlignment = profile?.alignment ?? Alignment.center;
          final focusAlignment = Alignment(
            (baseAlignment.x * 0.40) +
                (enableMotion
                    ? math.sin(turn * 0.78 + phaseA) * 0.16 * motionGain
                    : 0),
            (baseAlignment.y * 0.34) +
                (enableMotion
                    ? math.cos(turn * 0.74 + phaseB) * 0.13 * motionGain
                    : 0),
          );
          final focusObjectLayer = _focusObjectLayer;
          final hasFocusObjectLayer =
              enableObjectMotion && focusObjectLayer != null;
          final hasSubjectLayer =
              enableMotion &&
              _subjectCutoutBytes != null &&
              !hasFocusObjectLayer;

          var subjectRotXFreq = 2.0;
          var subjectRotYFreq = 3.0;
          var subjectRotXAmp = 0.022;
          var subjectRotYAmp = 0.024;
          var subjectMoveXFreq = 2.0;
          var subjectMoveYFreq = 1.0;
          var subjectMoveXAmp = widget.size * 0.014;
          var subjectMoveYAmp = widget.size * 0.010;
          var subjectAlignment = focusAlignment;

          switch (subjectStyle) {
            case 0:
              // Orbit suave.
              subjectRotXFreq = 1.0;
              subjectRotYFreq = 2.0;
              subjectMoveXFreq = 1.0;
              subjectMoveYFreq = 2.0;
              subjectMoveXAmp = widget.size * 0.016;
              subjectMoveYAmp = widget.size * 0.012;
              break;
            case 1:
              // Flotación vertical.
              subjectRotXFreq = 2.0;
              subjectRotYFreq = 1.0;
              subjectMoveXFreq = 3.0;
              subjectMoveYFreq = 1.0;
              subjectMoveXAmp = widget.size * 0.010;
              subjectMoveYAmp = widget.size * 0.018;
              break;
            case 2:
              // Drift lateral.
              subjectRotXFreq = 1.0;
              subjectRotYFreq = 1.0;
              subjectMoveXFreq = 1.0;
              subjectMoveYFreq = 4.0;
              subjectMoveXAmp = widget.size * 0.020;
              subjectMoveYAmp = widget.size * 0.006;
              subjectAlignment = Alignment(
                focusAlignment.x * 0.7,
                focusAlignment.y * 0.5,
              );
              break;
            case 3:
              // Pulso frontal.
              subjectRotXFreq = 3.0;
              subjectRotYFreq = 2.0;
              subjectMoveXFreq = 2.0;
              subjectMoveYFreq = 2.0;
              subjectMoveXAmp = widget.size * 0.009;
              subjectMoveYAmp = widget.size * 0.009;
              break;
            case 4:
              // Swing diagonal.
              subjectRotXFreq = 2.0;
              subjectRotYFreq = 4.0;
              subjectMoveXFreq = 4.0;
              subjectMoveYFreq = 1.0;
              subjectMoveXAmp = widget.size * 0.017;
              subjectMoveYAmp = widget.size * 0.014;
              subjectAlignment = Alignment(
                (focusAlignment.x * 0.8) + 0.05,
                focusAlignment.y * 0.8,
              );
              break;
          }

          final objectGain = (widget.isPlaying ? 1.0 : 0.44) * energy;
          final focusAreaRatio = focusObjectLayer?.areaRatio ?? 0.0;
          final areaBoost = (1.0 - focusAreaRatio).clamp(0.22, 1.0);
          final objectDepthScale = (1.01 + ((1.0 - focusAreaRatio) * 0.06))
              .clamp(1.0, 1.08);
          final objectDriftX =
              ((math.sin(turn * 1.34 + phaseB) * 0.008) +
                  (math.sin(turn * 2.38 + phaseA) * 0.004)) *
              widget.size *
              objectGain *
              areaBoost;
          final objectDriftY =
              ((math.cos(turn * 1.18 + phaseA) * 0.006) +
                  (math.cos(turn * 2.04 + phaseB) * 0.003)) *
              widget.size *
              objectGain *
              areaBoost;
          final objectRotX =
              math.sin(turn * 1.22 + phaseA) * 0.034 * objectGain * areaBoost;
          final objectRotY =
              math.cos(turn * 1.51 + phaseB) * 0.031 * objectGain * areaBoost;
          final objectRotZ =
              math.sin(turn * 0.82 + phaseB) * 0.020 * objectGain * areaBoost;

          return Stack(
            clipBehavior: Clip.none,
            children: [
              if (enableMotion)
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(widget.borderRadius),
                      boxShadow: [
                        BoxShadow(
                          color: glowColor.withValues(alpha: glow * 0.58),
                          blurRadius: widget.size * 0.24,
                          spreadRadius: widget.size * 0.014,
                          offset: const Offset(0, -10),
                        ),
                        BoxShadow(
                          color: glowColor.withValues(alpha: glow * 0.60),
                          blurRadius: widget.size * 0.22,
                          spreadRadius: widget.size * 0.012,
                          offset: const Offset(0, 12),
                        ),
                        BoxShadow(
                          color: glowColor.withValues(alpha: glow * 0.44),
                          blurRadius: widget.size * 0.12,
                          spreadRadius: widget.size * 0.005,
                          offset: const Offset(0, 5),
                        ),
                      ],
                    ),
                  ),
                ),
              ClipRRect(
                borderRadius: BorderRadius.circular(widget.borderRadius),
                child: ColoredBox(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: hasImage
                      ? Stack(
                          fit: StackFit.expand,
                          children: [
                            Transform(
                              alignment: focusAlignment,
                              transform: Matrix4.identity()
                                ..setEntry(3, 2, 0.00115)
                                ..rotateX(warpY)
                                ..rotateY(warpX)
                                ..rotateZ(tilt),
                              child: Transform.translate(
                                offset: Offset(dx, dy),
                                child: Transform.scale(
                                  scale: zoom,
                                  child: Align(
                                    alignment: focusAlignment,
                                    child: child,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        )
                      : child,
                ),
              ),
              if (enableMotion)
                Positioned(
                  top: -widget.size * 0.26 * _subjectSizeMultiplier,
                  left: -widget.size * 0.20 * _subjectSizeMultiplier,
                  right: -widget.size * 0.20 * _subjectSizeMultiplier,
                  bottom: -widget.size * 0.28 * _subjectSizeMultiplier,
                  child: IgnorePointer(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 280),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      transitionBuilder: (child, animation) {
                        return FadeTransition(opacity: animation, child: child);
                      },
                      child: hasSubjectLayer
                          ? Opacity(
                              key: const ValueKey('subject-layer-on'),
                              opacity: 0.94 * (widget.isPlaying ? 1.0 : 0.76),
                              child: Transform(
                                alignment: subjectAlignment,
                                transform: Matrix4.identity()
                                  ..setEntry(3, 2, 0.0018)
                                  ..rotateX(
                                    math.sin(turn * subjectRotXFreq) *
                                        subjectRotXAmp *
                                        motionGain,
                                  )
                                  ..rotateY(
                                    math.cos(turn * subjectRotYFreq) *
                                        subjectRotYAmp *
                                        motionGain,
                                  ),
                                child: Transform.translate(
                                  offset: Offset(
                                    math.sin(turn * subjectMoveXFreq) *
                                        subjectMoveXAmp *
                                        motionGain,
                                    math.cos(turn * subjectMoveYFreq) *
                                        subjectMoveYAmp *
                                        motionGain,
                                  ),
                                  child: Transform.scale(
                                    scale: _subjectSizeMultiplier,
                                    child: ClipRect(
                                      child: Align(
                                        alignment: Alignment.center,
                                        widthFactor: 0.93,
                                        child: Image.memory(
                                          _subjectCutoutBytes!,
                                          fit: BoxFit.contain,
                                          filterQuality: FilterQuality.high,
                                          gaplessPlayback: true,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            )
                          : const SizedBox(key: ValueKey('subject-layer-off')),
                    ),
                  ),
                ),
              if (hasFocusObjectLayer)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Opacity(
                      opacity: 0.96 * (widget.isPlaying ? 1.0 : 0.78),
                      child: Transform(
                        alignment: focusObjectLayer.alignment,
                        transform: Matrix4.identity()
                          ..setEntry(3, 2, 0.0016)
                          ..rotateX(objectRotX)
                          ..rotateY(objectRotY)
                          ..rotateZ(objectRotZ),
                        child: Transform.translate(
                          offset: Offset(objectDriftX, objectDriftY),
                          child: Transform.scale(
                            alignment: focusObjectLayer.alignment,
                            scale: objectDepthScale,
                            child: Image.memory(
                              focusObjectLayer.bytes,
                              fit: BoxFit.contain,
                              filterQuality: FilterQuality.high,
                              gaplessPlayback: true,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  String _displayArtworkSourceUrl() {
    if (!widget.animated) return widget.url?.trim() ?? '';
    final animated = _aiAnimatedCoverUrl?.trim() ?? '';
    if (animated.isNotEmpty) return animated;
    return widget.url?.trim() ?? '';
  }

  String _stableTrackIdForSource(String raw) {
    var hash = 0x811C9DC5;
    for (var i = 0; i < raw.length; i++) {
      hash ^= raw.codeUnitAt(i);
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash.toRadixString(16);
  }

  void _maybeResolveAiAnimatedCover() {
    if (!widget.animated || _aiAnimatedCoverUrl != null) return;
    if (_isResolvingAiCover) return;
    if (!_aiCoverAnimationService.isConfigured) return;
    final source = widget.url?.trim() ?? '';
    if (source.isEmpty) return;
    final now = DateTime.now();
    if (now.difference(_lastAiCoverAttemptAt) < _aiCoverRetryDelay) return;
    unawaited(_resolveAiAnimatedCover());
  }

  Future<void> _resolveAiAnimatedCover() async {
    if (!widget.animated || !_aiCoverAnimationService.isConfigured) {
      if (!mounted) return;
      if (_aiAnimatedCoverUrl != null || _lastAiCoverSource != null) {
        setState(() {
          _aiAnimatedCoverUrl = null;
          _lastAiCoverSource = null;
        });
      }
      return;
    }

    final source = widget.url?.trim() ?? '';
    if (source.isEmpty) {
      if (!mounted) return;
      if (_aiAnimatedCoverUrl != null || _lastAiCoverSource != source) {
        setState(() {
          _aiAnimatedCoverUrl = null;
          _lastAiCoverSource = source;
        });
      }
      return;
    }

    if (source == _lastAiCoverSource && _aiAnimatedCoverUrl != null) return;
    _lastAiCoverSource = source;
    if (_aiAnimatedCoverUrl != null && mounted) {
      setState(() {
        _aiAnimatedCoverUrl = null;
      });
    }
    _isResolvingAiCover = true;
    _lastAiCoverAttemptAt = DateTime.now();
    final trackId = _stableTrackIdForSource(source);
    Uint8List? sourceBytes;
    String? sourceFilename;
    if (source.startsWith('/')) {
      sourceBytes = await _loadImageBytes(source);
      if (sourceBytes == null || sourceBytes.isEmpty) {
        _isResolvingAiCover = false;
        if (!mounted || _lastAiCoverSource != source) return;
        setState(() {
          _aiAnimatedCoverUrl = null;
        });
        return;
      }
      sourceFilename = source.split('/').last.trim();
      if (sourceFilename.isEmpty) {
        sourceFilename = 'cover.jpg';
      }
    } else {
      sourceBytes = await _loadImageBytes(source);
      try {
        final uri = Uri.parse(source);
        if (uri.pathSegments.isNotEmpty) {
          sourceFilename = uri.pathSegments.last.trim();
        }
      } catch (_) {}
      if (sourceFilename == null || sourceFilename.isEmpty) {
        sourceFilename = 'cover.jpg';
      }
    }
    String? animatedUrl;
    try {
      animatedUrl = await _aiCoverAnimationService.requestAnimatedCoverUrl(
        trackId: trackId,
        sourceUrl: source,
        sourceBytes: sourceBytes,
        sourceFilename: sourceFilename,
      );
    } catch (_) {
      animatedUrl = null;
    } finally {
      _isResolvingAiCover = false;
    }

    if (!mounted || _lastAiCoverSource != source) return;
    final normalized = (animatedUrl ?? '').trim();
    final next = normalized.isEmpty ? null : normalized;
    if (next == _aiAnimatedCoverUrl) return;
    setState(() {
      _aiAnimatedCoverUrl = next;
    });
  }

  bool _looksLikeVideoSource(String source) {
    final value = source.trim().toLowerCase();
    if (value.isEmpty) return false;
    if (RegExp(r'\.(mp4|mov|m3u8|webm|m4v|mkv)(\?|#|$)').hasMatch(value) ||
        value.contains('/video/') ||
        value.contains('/videos/') ||
        value.contains('/gradio_api/file=') ||
        value.contains('/file=')) {
      return true;
    }
    return false;
  }

  void _syncAiVideoControllerForSource(String source) {
    final aiUrl = _aiAnimatedCoverUrl?.trim() ?? '';
    final shouldTryAsVideo =
        _looksLikeVideoSource(source) ||
        (aiUrl.isNotEmpty &&
            source == aiUrl &&
            (source.startsWith('http://') || source.startsWith('https://')));
    if (!shouldTryAsVideo) {
      if (_aiActiveVideoController != null ||
          _aiVideoReady ||
          _aiVideoSource != null) {
        _aiLoopToken++;
        _aiVideoReady = false;
        _aiVideoSource = null;
        unawaited(_disposeAiVideoControllers());
      }
      return;
    }
    if (source == _aiVideoSource && _aiVideoReady) return;
    _aiVideoSource = source;
    _aiVideoReady = false;
    _aiLoopToken++;
    unawaited(_prepareAiVideoController(source));
  }

  Future<void> _prepareAiVideoController(String source) async {
    final token = _aiLoopToken;
    await _disposeAiVideoControllers();
    _ensureAiLoopBlendController();
    _aiLoopBlendController?.value = 0;
    final controllerA = VideoPlayerController.networkUrl(Uri.parse(source));
    final controllerB = VideoPlayerController.networkUrl(Uri.parse(source));
    _aiVideoControllerA = controllerA;
    _aiVideoControllerB = controllerB;
    try {
      await controllerA.initialize();
      await controllerB.initialize();
      await controllerA.setLooping(false);
      await controllerB.setLooping(false);
      await controllerA.setVolume(0);
      await controllerB.setVolume(0);
      await controllerB.seekTo(Duration.zero);
      await controllerB.pause();
      await controllerA.play();

      if (!mounted || _aiVideoSource != source || token != _aiLoopToken) {
        await _disposeVideoControllerSafe(controllerA);
        await _disposeVideoControllerSafe(controllerB);
        return;
      }

      _aiActiveVideoController = controllerA;
      _aiStandbyVideoController = controllerB;
      setState(() {
        _aiVideoReady = true;
      });
      _scheduleAiLoopSwap(source: source, token: token);
    } catch (_) {
      await _disposeVideoControllerSafe(controllerA);
      await _disposeVideoControllerSafe(controllerB);
      if (!mounted || _aiVideoSource != source || token != _aiLoopToken) return;
      await _prepareSingleAiVideoController(source, token: token);
    }
  }

  Future<void> _prepareSingleAiVideoController(
    String source, {
    required int token,
  }) async {
    final controller = VideoPlayerController.networkUrl(Uri.parse(source));
    _aiVideoControllerA = controller;
    try {
      await controller.initialize();
      await controller.setLooping(true);
      await controller.setVolume(0);
      await controller.play();
      if (!mounted || _aiVideoSource != source || token != _aiLoopToken) {
        await _disposeVideoControllerSafe(controller);
        return;
      }
      _aiActiveVideoController = controller;
      _aiStandbyVideoController = null;
      setState(() {
        _aiVideoReady = true;
      });
    } catch (_) {
      await _disposeVideoControllerSafe(controller);
      if (!mounted || _aiVideoSource != source || token != _aiLoopToken) return;
      setState(() {
        _aiVideoReady = false;
      });
    }
  }

  void _ensureAiLoopBlendController() {
    if (_aiLoopBlendController != null) return;
    _aiLoopBlendController =
        AnimationController(
          vsync: this,
          duration: _aiLoopCrossfadeDuration,
          value: 0,
        )..addListener(() {
          if (!mounted) return;
          setState(() {});
        });
  }

  void _scheduleAiLoopSwap({required String source, required int token}) {
    _aiLoopSwapTimer?.cancel();
    final active = _aiActiveVideoController;
    if (active == null || !active.value.isInitialized) return;
    final duration = active.value.duration;
    if (duration <= Duration.zero) return;
    var delay = duration - _aiLoopSwapLeadTime;
    if (delay < const Duration(milliseconds: 180)) {
      delay = Duration(
        milliseconds: math.max(120, duration.inMilliseconds ~/ 2),
      );
    }
    _aiLoopSwapTimer = Timer(
      delay,
      () => unawaited(_performAiLoopSwap(source: source, token: token)),
    );
  }

  Future<void> _performAiLoopSwap({
    required String source,
    required int token,
  }) async {
    if (!mounted || token != _aiLoopToken || _aiVideoSource != source) return;
    final active = _aiActiveVideoController;
    final standby = _aiStandbyVideoController;
    final blend = _aiLoopBlendController;
    if (active == null || standby == null || blend == null) return;

    try {
      await standby.seekTo(Duration.zero);
      await standby.setVolume(0);
      await standby.play();
      if (!mounted || token != _aiLoopToken || _aiVideoSource != source) return;

      blend
        ..stop()
        ..value = 0;
      await blend.forward();
      if (!mounted || token != _aiLoopToken || _aiVideoSource != source) return;

      await active.pause();
      await active.seekTo(Duration.zero);
      _aiActiveVideoController = standby;
      _aiStandbyVideoController = active;
      blend.value = 0;
      _scheduleAiLoopSwap(source: source, token: token);
    } catch (_) {
      // Si falla el crossfade, mantenemos loop normal del activo.
      try {
        await active.setLooping(true);
      } catch (_) {}
    }
  }

  Future<void> _disposeAiVideoControllers() async {
    _aiLoopSwapTimer?.cancel();
    _aiLoopSwapTimer = null;
    _aiLoopBlendController?.stop();
    _aiLoopBlendController?.value = 0;

    final controllers = <VideoPlayerController>{
      if (_aiVideoControllerA != null) _aiVideoControllerA!,
      if (_aiVideoControllerB != null) _aiVideoControllerB!,
      if (_aiActiveVideoController != null) _aiActiveVideoController!,
      if (_aiStandbyVideoController != null) _aiStandbyVideoController!,
    };
    _aiVideoControllerA = null;
    _aiVideoControllerB = null;
    _aiActiveVideoController = null;
    _aiStandbyVideoController = null;

    for (final controller in controllers) {
      await _disposeVideoControllerSafe(controller);
    }
  }

  Future<void> _disposeVideoControllerSafe(
    VideoPlayerController controller,
  ) async {
    try {
      await controller.pause();
    } catch (_) {}
    try {
      await controller.dispose();
    } catch (_) {}
  }

  Widget _buildAnimatedVideoCover() {
    final active = _aiActiveVideoController;
    if (active == null || !active.value.isInitialized) {
      return const SizedBox.expand();
    }
    final standby = _aiStandbyVideoController;
    final blend = (_aiLoopBlendController?.value ?? 0.0).clamp(0.0, 1.0);
    final showStandby =
        standby != null && standby.value.isInitialized && blend > 0.001;
    return Stack(
      fit: StackFit.expand,
      children: [
        _buildVideoCoverLayer(
          active,
          opacity: showStandby ? (1.0 - blend) : 1.0,
        ),
        if (showStandby) _buildVideoCoverLayer(standby, opacity: blend),
      ],
    );
  }

  Widget _buildVideoCoverLayer(
    VideoPlayerController controller, {
    required double opacity,
  }) {
    final value = controller.value;
    if (!value.isInitialized) return const SizedBox.expand();
    final videoAspect = value.aspectRatio > 0 ? value.aspectRatio : 1.0;
    return Opacity(
      opacity: opacity.clamp(0.0, 1.0),
      child: SizedBox.expand(
        child: FittedBox(
          fit: BoxFit.cover,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            width: widget.size * videoAspect,
            height: widget.size,
            child: VideoPlayer(controller),
          ),
        ),
      ),
    );
  }

  Future<void> _resolveArtworkColor() async {
    if (!widget.animated) return;
    final resolved = _processingArtworkSourceUrl();
    if (resolved == null || resolved.isEmpty || resolved == _lastPaletteUrl) {
      return;
    }
    _lastPaletteUrl = resolved;

    final cached = _paletteCache[resolved];
    if (cached != null) {
      if (mounted && _lastPaletteUrl == resolved) {
        setState(() {
          _dominantColor = cached;
        });
      } else {
        _dominantColor = cached;
      }
      return;
    }

    Future<Color?> request =
        _paletteRequests[resolved] ??
        () async {
          try {
            final ImageProvider provider = resolved.startsWith('/')
                ? FileImage(File(resolved))
                : NetworkImage(resolved);
            final palette = await PaletteGenerator.fromImageProvider(
              provider,
              size: const Size(96, 96),
              maximumColorCount: 16,
            );
            final color =
                palette.vibrantColor?.color ??
                palette.lightVibrantColor?.color ??
                palette.dominantColor?.color ??
                palette.mutedColor?.color;
            if (color != null) {
              _rememberPaletteColor(resolved, color);
            }
            return color;
          } catch (_) {
            return null;
          }
        }();
    _paletteRequests[resolved] = request;

    try {
      final color = await request;
      if (!mounted || _lastPaletteUrl != resolved) return;
      if (color != null) {
        setState(() {
          _dominantColor = color;
        });
      }
    } catch (_) {
      // Si falla extracción de color, mantenemos fallback.
    } finally {
      if (identical(_paletteRequests[resolved], request)) {
        _paletteRequests.remove(resolved);
      }
    }
  }

  Future<void> _resolveSubjectCutout() async {
    if (!widget.animated) return;
    final settings = context.read<AppSettingsService?>();
    if (settings != null && !settings.animatedCutoutCovers) {
      if (mounted && _subjectCutoutBytes != null) {
        setState(() {
          _subjectCutoutBytes = null;
          _lastSubjectUrl = null;
          _subjectMotionProfile = null;
          _lastSubjectProfileUrl = null;
          _focusObjectLayer = null;
          _lastFocusObjectUrl = null;
        });
      } else {
        _lastSubjectUrl = null;
        _subjectMotionProfile = null;
        _lastSubjectProfileUrl = null;
        _focusObjectLayer = null;
        _lastFocusObjectUrl = null;
      }
      return;
    }
    final resolved = _processingArtworkSourceUrl();
    if (kDebugMode) {
      debugPrint('[cutout] resolve start url=$resolved');
    }
    if (resolved == null || resolved.isEmpty) {
      if (mounted && _subjectCutoutBytes != null) {
        setState(() {
          _subjectCutoutBytes = null;
          _lastSubjectUrl = null;
          _subjectMotionProfile = null;
          _lastSubjectProfileUrl = null;
          _focusObjectLayer = null;
          _lastFocusObjectUrl = null;
        });
      }
      if (kDebugMode) {
        debugPrint('[cutout] resolve abort empty url');
      }
      return;
    }
    if (resolved == _lastSubjectUrl) return;
    _lastSubjectUrl = resolved;

    if (_subjectCutoutCache.containsKey(resolved)) {
      final cached = _subjectCutoutCache[resolved];
      if (!mounted || _lastSubjectUrl != resolved) return;
      setState(() {
        _subjectCutoutBytes = cached;
      });
      unawaited(_resolveSubjectMotionProfile(resolved, cached));
      unawaited(_resolveFocusObjectLayer(resolved, cached));
      return;
    }

    Future<Uint8List?> request =
        _subjectCutoutRequests[resolved] ??
        () async {
          try {
            final bytes = await _loadImageBytes(resolved);
            if (kDebugMode) {
              debugPrint(
                '[cutout] source bytes loaded url=$resolved bytes=${bytes?.length ?? 0}',
              );
            }
            if (bytes == null || bytes.isEmpty) return null;
            final cutout = await ArtworkSubjectCutoutService.buildCutout(
              cacheKey: 'v11:$resolved:native-validated',
              sourceBytes: bytes,
              viewportZoom: 1.0,
            );
            _rememberSubjectCutout(resolved, cutout);
            return cutout;
          } catch (_) {
            _rememberSubjectCutout(resolved, null);
            return null;
          }
        }();
    _subjectCutoutRequests[resolved] = request;

    try {
      final cutout = await request;
      if (!mounted || _lastSubjectUrl != resolved) return;
      setState(() {
        _subjectCutoutBytes = cutout;
      });
      unawaited(_resolveSubjectMotionProfile(resolved, cutout));
      unawaited(_resolveFocusObjectLayer(resolved, cutout));
      if (kDebugMode) {
        debugPrint(
          '[cutout] resolve done url=$resolved outBytes=${cutout?.length ?? 0}',
        );
      }
    } catch (_) {
      if (!mounted || _lastSubjectUrl != resolved) return;
      setState(() {
        _subjectCutoutBytes = null;
        _subjectMotionProfile = null;
        _lastSubjectProfileUrl = null;
        _focusObjectLayer = null;
        _lastFocusObjectUrl = null;
      });
      if (kDebugMode) {
        debugPrint('[cutout] resolve failed url=$resolved');
      }
    } finally {
      if (identical(_subjectCutoutRequests[resolved], request)) {
        _subjectCutoutRequests.remove(resolved);
      }
    }
  }

  Future<void> _resolveSubjectMotionProfile(
    String sourceKey,
    Uint8List? cutoutBytes,
  ) async {
    if (cutoutBytes == null || cutoutBytes.isEmpty) {
      if (!mounted) return;
      setState(() {
        _subjectMotionProfile = null;
        _lastSubjectProfileUrl = sourceKey;
      });
      return;
    }
    _lastSubjectProfileUrl = sourceKey;
    final cached = _subjectProfileCache[sourceKey];
    if (cached != null || _subjectProfileCache.containsKey(sourceKey)) {
      if (!mounted || _lastSubjectProfileUrl != sourceKey) return;
      setState(() {
        _subjectMotionProfile = cached;
      });
      return;
    }

    final request =
        _subjectProfileRequests[sourceKey] ??
        compute<Uint8List, Map<String, num>?>(
          _buildSubjectMotionProfileWorker,
          cutoutBytes,
        ).then((raw) {
          if (raw == null) return null;
          return _SubjectMotionProfile(
            alignment: Alignment(
              ((raw['alignmentX']?.toDouble() ?? 0.0).clamp(-0.55, 0.55)),
              ((raw['alignmentY']?.toDouble() ?? 0.0).clamp(-0.55, 0.55)),
            ),
            moveScale: (raw['moveScale']?.toDouble() ?? 1.0).clamp(0.85, 1.42),
            tiltScale: (raw['tiltScale']?.toDouble() ?? 1.0).clamp(0.82, 1.30),
            zoomBoost: (raw['zoomBoost']?.toDouble() ?? 0.0).clamp(0.0, 0.26),
            styleVariant: ((raw['style']?.toInt() ?? 0) % 5).clamp(0, 4),
          );
        });

    _subjectProfileRequests[sourceKey] = request;
    try {
      final profile = await request;
      _subjectProfileCache[sourceKey] = profile;
      if (!mounted || _lastSubjectProfileUrl != sourceKey) return;
      setState(() {
        _subjectMotionProfile = profile;
      });
    } catch (_) {
      _subjectProfileCache[sourceKey] = null;
      if (!mounted || _lastSubjectProfileUrl != sourceKey) return;
      setState(() {
        _subjectMotionProfile = null;
      });
    } finally {
      if (identical(_subjectProfileRequests[sourceKey], request)) {
        _subjectProfileRequests.remove(sourceKey);
      }
    }
  }

  Future<void> _resolveFocusObjectLayer(
    String sourceKey,
    Uint8List? cutoutBytes,
  ) async {
    if (cutoutBytes == null || cutoutBytes.isEmpty) {
      if (!mounted) return;
      setState(() {
        _focusObjectLayer = null;
        _lastFocusObjectUrl = sourceKey;
      });
      return;
    }
    _lastFocusObjectUrl = sourceKey;
    final cached = _focusObjectCache[sourceKey];
    if (cached != null || _focusObjectCache.containsKey(sourceKey)) {
      if (!mounted || _lastFocusObjectUrl != sourceKey) return;
      setState(() {
        _focusObjectLayer = cached;
      });
      return;
    }

    final request =
        _focusObjectRequests[sourceKey] ??
        compute<Uint8List, Map<String, Object?>?>(
          _buildFocusObjectLayerWorker,
          cutoutBytes,
        ).then((raw) {
          if (raw == null) return null;
          final bytes = raw['bytes'];
          if (bytes is! Uint8List || bytes.isEmpty) return null;
          final alignmentX = ((raw['alignmentX'] as num?)?.toDouble() ?? 0.0)
              .clamp(-0.95, 0.95);
          final alignmentY = ((raw['alignmentY'] as num?)?.toDouble() ?? 0.0)
              .clamp(-0.95, 0.95);
          final areaRatio = ((raw['areaRatio'] as num?)?.toDouble() ?? 0.0)
              .clamp(0.0, 1.0);
          return _FocusObjectLayer(
            bytes: bytes,
            alignment: Alignment(alignmentX, alignmentY),
            areaRatio: areaRatio,
          );
        });
    _focusObjectRequests[sourceKey] = request;

    try {
      final layer = await request;
      _rememberFocusObjectLayer(sourceKey, layer);
      if (!mounted || _lastFocusObjectUrl != sourceKey) return;
      setState(() {
        _focusObjectLayer = layer;
      });
    } catch (_) {
      _rememberFocusObjectLayer(sourceKey, null);
      if (!mounted || _lastFocusObjectUrl != sourceKey) return;
      setState(() {
        _focusObjectLayer = null;
      });
    } finally {
      if (identical(_focusObjectRequests[sourceKey], request)) {
        _focusObjectRequests.remove(sourceKey);
      }
    }
  }

  Future<Uint8List?> _loadImageBytes(String raw) async {
    if (_imageBytesCache.containsKey(raw)) {
      return _imageBytesCache[raw];
    }
    final inFlight = _imageBytesRequests[raw];
    if (inFlight != null) {
      return inFlight;
    }
    final request = _readImageBytes(raw);
    _imageBytesRequests[raw] = request;
    try {
      final bytes = await request;
      _rememberImageBytes(raw, bytes);
      return bytes;
    } finally {
      if (identical(_imageBytesRequests[raw], request)) {
        _imageBytesRequests.remove(raw);
      }
    }
  }

  Future<Uint8List?> _readImageBytes(String raw) async {
    if (raw.startsWith('/')) {
      final file = File(raw);
      if (!await file.exists()) {
        if (kDebugMode) {
          debugPrint('[cutout] local file not found path=$raw');
        }
        return null;
      }
      return file.readAsBytes();
    }
    final client = HttpClient();
    try {
      final uri = Uri.parse(raw);
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.userAgentHeader, 'VMMusic/1.0 (Flutter)');
      final res = await req.close();
      if (res.statusCode < 200 || res.statusCode >= 300) {
        if (kDebugMode) {
          debugPrint('[cutout] http image status=${res.statusCode} url=$raw');
        }
        return null;
      }
      final chunks = <int>[];
      await for (final c in res) {
        chunks.addAll(c);
      }
      return Uint8List.fromList(chunks);
    } catch (_) {
      if (kDebugMode) {
        debugPrint('[cutout] http image load exception url=$raw');
      }
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Widget _buildStaticArtworkFrame(
    BuildContext context, {
    required String imageSource,
    required bool hasImage,
    required bool preferLowResolution,
  }) {
    return SizedBox.square(
      dimension: widget.size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        child: ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: hasImage
              ? _buildArtworkImage(
                  context,
                  imageSource: imageSource,
                  preferLowResolution: preferLowResolution,
                )
              : Icon(
                  Icons.music_note_rounded,
                  size: widget.size * 0.4,
                  color: Theme.of(context).colorScheme.primary,
                ),
        ),
      ),
    );
  }

  void _syncAnimationControllers({bool initial = false}) {
    if (!widget.animated) {
      _motionController?.stop();
      _pulseController?.stop();
      return;
    }

    _motionController ??= AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 11500),
    )..repeat();

    _pulseController ??= AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    );

    final pulse = _pulseController!;
    if (widget.isPlaying) {
      if (!pulse.isAnimating) {
        pulse.repeat(reverse: true);
      }
      return;
    }

    pulse.stop();
    if (initial) {
      pulse.value = 0.35;
      return;
    }
    pulse.animateTo(
      0.35,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  void _rememberPaletteColor(String key, Color value) {
    _paletteCache[key] = value;
    while (_paletteCache.length > _maxArtworkCacheEntries) {
      _paletteCache.remove(_paletteCache.keys.first);
    }
  }

  void _rememberSubjectCutout(String key, Uint8List? value) {
    _subjectCutoutCache[key] = value;
    while (_subjectCutoutCache.length > _maxArtworkCacheEntries) {
      _subjectCutoutCache.remove(_subjectCutoutCache.keys.first);
    }
  }

  void _rememberImageBytes(String key, Uint8List? value) {
    _imageBytesCache[key] = value;
    while (_imageBytesCache.length > _maxArtworkCacheEntries) {
      _imageBytesCache.remove(_imageBytesCache.keys.first);
    }
  }

  void _rememberFocusObjectLayer(String key, _FocusObjectLayer? value) {
    _focusObjectCache[key] = value;
    while (_focusObjectCache.length > _maxArtworkCacheEntries) {
      _focusObjectCache.remove(_focusObjectCache.keys.first);
    }
  }

  Color _enhanceGlowColor(Color base) {
    final hsl = HSLColor.fromColor(base);
    final boosted = hsl
        .withSaturation((hsl.saturation + 0.16).clamp(0.35, 1.0))
        .withLightness((hsl.lightness + 0.08).clamp(0.25, 0.72));
    return boosted.toColor();
  }

  int _subjectMotionStyleForUrl(String? raw) {
    final s = raw?.trim();
    if (s == null || s.isEmpty) return 0;
    var hash = 0;
    for (var i = 0; i < s.length; i++) {
      hash = ((hash * 31) + s.codeUnitAt(i)) & 0x7fffffff;
    }
    return hash % 5;
  }

  double _stableNoiseFromString(String? raw, {int salt = 0}) {
    final text = raw?.trim() ?? '';
    if (text.isEmpty) return 0.0;
    var hash = 17 + (salt * 131);
    for (var i = 0; i < text.length; i++) {
      hash = (hash * 37 + text.codeUnitAt(i)) & 0x7fffffff;
    }
    return (hash % 10000) / 10000.0;
  }

  String? _preferredArtworkSourceUrl({required bool preferLowResolution}) {
    final raw = widget.url?.trim();
    if (raw == null || raw.isEmpty || raw.startsWith('/')) {
      return raw;
    }
    final candidates = buildThumbnailCandidates(
      thumbnailUrl: raw,
      preferLowResolution: preferLowResolution,
    );
    if (candidates.isNotEmpty) return candidates.first;
    return optimizeYoutubeThumbnailUrl(
      raw,
      preferLowResolution: preferLowResolution,
    );
  }

  String? _processingArtworkSourceUrl() {
    // Usamos una variante liviana para análisis visual (palette/cutout) y así
    // evitamos decodificar imágenes enormes durante transiciones.
    return _preferredArtworkSourceUrl(preferLowResolution: true);
  }

  Widget _buildArtworkImage(
    BuildContext context, {
    required String imageSource,
    required bool preferLowResolution,
  }) {
    final trimmed = imageSource.trim();
    final isYoutubeThumb =
        trimmed.contains('ytimg.com') || trimmed.contains('youtube.com');
    final raw = isYoutubeThumb
        ? optimizeYoutubeThumbnailUrl(
            trimmed,
            preferLowResolution: preferLowResolution,
          )
        : trimmed;
    final looksLikeLocalPath = raw.startsWith('/');
    final fallback = Icon(
      Icons.music_note_rounded,
      size: widget.size * 0.4,
      color: Theme.of(context).colorScheme.primary,
    );
    if (looksLikeLocalPath) {
      return Transform.scale(
        scale: 1.0,
        child: SquareThumbnail.file(
          filePath: raw,
          size: widget.size,
          borderRadius: 0,
          zoom: 1.0,
          fallback: fallback,
        ),
      );
    }
    return Transform.scale(
      scale: 1.0,
      child: SquareThumbnail.network(
        imageUrl: raw,
        size: widget.size,
        borderRadius: 0,
        zoom: 1.0,
        fallback: fallback,
      ),
    );
  }
}

Map<String, num>? _buildSubjectMotionProfileWorker(Uint8List cutoutBytes) {
  final image = img.decodeImage(cutoutBytes);
  if (image == null) return null;
  final w = image.width;
  final h = image.height;
  if (w <= 8 || h <= 8) return null;
  final total = w * h;

  var count = 0;
  var weightedX = 0.0;
  var weightedY = 0.0;
  var minX = w;
  var minY = h;
  var maxX = -1;
  var maxY = -1;

  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final alpha = image.getPixel(x, y).a;
      if (alpha <= 22) continue;
      count++;
      final weight = alpha / 255.0;
      weightedX += x * weight;
      weightedY += y * weight;
      if (x < minX) minX = x;
      if (y < minY) minY = y;
      if (x > maxX) maxX = x;
      if (y > maxY) maxY = y;
    }
  }

  if (count < total * 0.008 || maxX < minX || maxY < minY) {
    return null;
  }

  final coverage = count / total;
  final denom = count.toDouble();
  final centerX = weightedX / denom;
  final centerY = weightedY / denom;
  final alignX = ((centerX / (w - 1)) * 2.0 - 1.0).clamp(-1.0, 1.0);
  final alignY = ((centerY / (h - 1)) * 2.0 - 1.0).clamp(-1.0, 1.0);
  final bboxW = ((maxX - minX + 1) / w).clamp(0.01, 1.0);
  final bboxH = ((maxY - minY + 1) / h).clamp(0.01, 1.0);

  final compactness = (coverage / (bboxW * bboxH)).clamp(0.05, 1.0);
  final moveScale =
      (1.10 + (1.0 - coverage) * 0.38 + (1.0 - compactness) * 0.14).clamp(
        0.86,
        1.42,
      );
  final tiltScale = (0.90 + (bboxW * 0.32) + ((1.0 - bboxH) * 0.24)).clamp(
    0.82,
    1.30,
  );
  final zoomBoost = (0.06 + (1.0 - coverage) * 0.26).clamp(0.0, 0.26);

  var seed = 97;
  seed += (alignX * 1000).round();
  seed += (alignY * 1400).round();
  seed += (coverage * 10000).round();
  seed += ((bboxW + bboxH) * 1300).round();
  final style = seed.abs() % 5;

  return <String, num>{
    'alignmentX': alignX,
    'alignmentY': alignY,
    'moveScale': moveScale,
    'tiltScale': tiltScale,
    'zoomBoost': zoomBoost,
    'style': style,
  };
}

Map<String, Object?>? _buildFocusObjectLayerWorker(Uint8List cutoutBytes) {
  final image = img.decodeImage(cutoutBytes);
  if (image == null) return null;
  final w = image.width;
  final h = image.height;
  if (w <= 16 || h <= 16) return null;
  final total = w * h;

  final alphaMask = Uint8List(total);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final alpha = image.getPixel(x, y).a;
      if (alpha > 26) {
        alphaMask[y * w + x] = 1;
      }
    }
  }

  final visited = Uint8List(total);
  final queue = List<int>.filled(total, 0, growable: false);
  _FocusComponent? best;
  var bestScore = -1.0;

  for (var i = 0; i < total; i++) {
    if (alphaMask[i] == 0 || visited[i] == 1) continue;

    var head = 0;
    var tail = 0;
    queue[tail++] = i;
    visited[i] = 1;

    final pixels = <int>[];
    var minX = w;
    var minY = h;
    var maxX = 0;
    var maxY = 0;
    var sumX = 0.0;
    var sumY = 0.0;

    while (head < tail) {
      final idx = queue[head++];
      pixels.add(idx);
      final x = idx % w;
      final y = idx ~/ w;
      sumX += x;
      sumY += y;
      if (x < minX) minX = x;
      if (y < minY) minY = y;
      if (x > maxX) maxX = x;
      if (y > maxY) maxY = y;

      void push(int nx, int ny) {
        if (nx < 0 || ny < 0 || nx >= w || ny >= h) return;
        final n = ny * w + nx;
        if (visited[n] == 1 || alphaMask[n] == 0) return;
        visited[n] = 1;
        queue[tail++] = n;
      }

      push(x - 1, y);
      push(x + 1, y);
      push(x, y - 1);
      push(x, y + 1);
    }

    final area = pixels.length;
    if (area < math.max(18, (total * 0.0018).round())) continue;
    final areaRatio = area / total;
    final bboxW = (maxX - minX + 1).toDouble();
    final bboxH = (maxY - minY + 1).toDouble();
    final bboxArea = bboxW * bboxH;
    if (bboxArea <= 0) continue;
    final compactness = (area / bboxArea).clamp(0.05, 1.0);
    final aspect = (bboxW / bboxH).clamp(0.2, 5.0);
    final circularity = (1.0 - ((aspect - 1.0).abs() / 1.2)).clamp(0.0, 1.0);

    final cx = sumX / area;
    final cy = sumY / area;
    final nx = ((cx / (w - 1)) * 2.0 - 1.0).clamp(-1.0, 1.0);
    final ny = ((cy / (h - 1)) * 2.0 - 1.0).clamp(-1.0, 1.0);
    final centerDist = math.sqrt(nx * nx + ny * ny).clamp(0.0, 1.8);
    final centerScore = (1.0 - (centerDist / 1.8)).clamp(0.0, 1.0);

    // Priorizamos objetos medianos/compactos (pelotas, elementos sueltos)
    // en vez del sujeto completo.
    final areaPref = (1.0 - ((areaRatio - 0.045).abs() / 0.060)).clamp(
      0.0,
      1.0,
    );
    final score =
        areaPref * 0.38 +
        circularity * 0.30 +
        compactness * 0.22 +
        centerScore * 0.10;

    if (score > bestScore) {
      bestScore = score;
      best = _FocusComponent(
        pixels: pixels,
        centerX: cx,
        centerY: cy,
        areaRatio: areaRatio,
      );
    }
  }

  if (best == null || bestScore < 0.24) return null;
  final out = img.Image(width: w, height: h, numChannels: 4);
  for (final idx in best.pixels) {
    final x = idx % w;
    final y = idx ~/ w;
    final p = image.getPixel(x, y);
    out.setPixelRgba(x, y, p.r, p.g, p.b, p.a);
  }
  img.gaussianBlur(out, radius: 1);
  final encoded = Uint8List.fromList(img.encodePng(out, level: 5));
  final alignmentX = ((best.centerX / (w - 1)) * 2.0 - 1.0).clamp(-1.0, 1.0);
  final alignmentY = ((best.centerY / (h - 1)) * 2.0 - 1.0).clamp(-1.0, 1.0);
  return <String, Object?>{
    'bytes': encoded,
    'alignmentX': alignmentX,
    'alignmentY': alignmentY,
    'areaRatio': best.areaRatio,
  };
}

class _FocusComponent {
  final List<int> pixels;
  final double centerX;
  final double centerY;
  final double areaRatio;

  const _FocusComponent({
    required this.pixels,
    required this.centerX,
    required this.centerY,
    required this.areaRatio,
  });
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
          color: Colors.transparent,
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
        downloadService.getDownloadError(videoId) ??
        'No se registró detalle del error.';
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
