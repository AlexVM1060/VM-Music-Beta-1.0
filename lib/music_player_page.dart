import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show FontFeature, ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:myapp/app_tab_state.dart';
import 'package:myapp/models/video_history.dart';
import 'package:myapp/models/playlist.dart' as app_models;
import 'package:myapp/search_view_state.dart';
import 'package:myapp/services/download_service.dart';
import 'package:myapp/services/playlist_service.dart';
import 'package:myapp/video_player_manager.dart';
import 'package:provider/provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

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
                    return SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: constraints.maxHeight - 40,
                        ),
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
                                onArtistTap: () => _openArtistProfile(context),
                                canAddToPlaylist: canAddToPlaylist,
                                onAddToPlaylist: () => _showAddToPlaylistSheet(
                                  context: context,
                                  playlistService: playlistService,
                                  downloadService: downloadService,
                                  manager: manager,
                                ),
                                onAddToFavorites: () => _addCurrentTrackToFavorites(
                                  context: context,
                                  playlistService: playlistService,
                                  downloadService: downloadService,
                                  manager: manager,
                                ),
                              )
                            : _DefaultNowPlayingHero(
                                key: const ValueKey('default_now_playing_hero'),
                                manager: manager,
                                onArtistTap: () => _openArtistProfile(context),
                                canAddToPlaylist: canAddToPlaylist,
                                onAddToPlaylist: () => _showAddToPlaylistSheet(
                                  context: context,
                                  playlistService: playlistService,
                                  downloadService: downloadService,
                                  manager: manager,
                                ),
                                onAddToFavorites: () => _addCurrentTrackToFavorites(
                                  context: context,
                                  playlistService: playlistService,
                                  downloadService: downloadService,
                                  manager: manager,
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
                    );
                  },
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

    await showModalBottomSheet<void>(
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
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(sheetContext).size.height * 0.78,
                  ),
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
                            Text(
                              'Añadir a playlist',
                              style: CupertinoTheme.of(sheetContext)
                                  .textTheme
                                  .navTitleTextStyle
                                  .copyWith(fontWeight: FontWeight.w700),
                            ),
                            const Spacer(),
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
                      Flexible(
                        child: ListView.builder(
                          shrinkWrap: true,
                          padding: const EdgeInsets.fromLTRB(10, 0, 10, 14),
                          itemCount: playlists.length,
                          itemBuilder: (context, index) {
                            final playlist = playlists[index];
                            final cover = playlist.videos.isNotEmpty
                                ? playlist.videos.first.thumbnailUrl
                                : null;
                            final isFavorites =
                                PlaylistService.isFavoritesPlaylistName(playlist.name);
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 3),
                              child: _PlaylistPickerRow(
                                name: playlist.name,
                                songsCount: playlist.videos.length,
                                coverUrl: cover,
                                isFavorites: isFavorites,
                                onTap: () {
                                  Navigator.of(sheetContext).pop();
                                  _addCurrentTrackToPlaylist(
                                    context: context,
                                    playlistService: playlistService,
                                    downloadService: downloadService,
                                    manager: manager,
                                    playlist: playlist,
                                  );
                                },
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
          ),
        );
      },
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
      orElse: () => app_models.Playlist(name: PlaylistService.favoritesPlaylistName),
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
          const SnackBar(content: Text('No se encontró un perfil para este artista.')),
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

      final wikiArtistPhoto = await _resolveArtistImageFromInternet(
        normalizedArtist.isEmpty ? rawArtist : normalizedArtist,
      );
      final thumb = best.thumbnails.isNotEmpty
          ? (wikiArtistPhoto ?? best.thumbnails.first.url.toString())
          : (wikiArtistPhoto ?? manager.trackThumbnailUrl ?? '');
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
      developer.log('Error al abrir perfil del artista', error: e, stackTrace: s);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo abrir el perfil del artista.')),
      );
    } finally {
      yt.close();
    }
  }

  Future<String?> _resolveArtistImageFromInternet(String rawArtistName) async {
    final cleaned = rawArtistName
        .replaceAll(RegExp(r'\s*[-–—]\s*topic$', caseSensitive: false), '')
        .replaceAll(RegExp(r'\btopic\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\bvevo\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\bofficial\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\brecords?\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\bmusic\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.isEmpty) return null;

    final candidates = <String>{
      cleaned,
      cleaned
          .replaceAll(RegExp(r'\s*[\(\[\{].*?[\)\]\}]'), '')
          .trim(),
      cleaned.split(RegExp(r'\s+(feat\.?|ft\.?|x|&)\s+', caseSensitive: false)).first.trim(),
    }.where((name) => name.isNotEmpty).toList();

    for (final candidate in candidates) {
      try {
        final title = await _resolveWikipediaTitle(candidate);
        if (title == null || title.isEmpty) continue;
        final image = await _resolveWikipediaThumbnail(title);
        if (image != null && image.isNotEmpty) return image;
      } catch (_) {
        // Seguimos probando con el siguiente candidato.
      }
    }

    return null;
  }

  Future<String?> _resolveWikipediaTitle(String artistName) async {
    final uri = Uri.https('en.wikipedia.org', '/w/api.php', {
      'action': 'opensearch',
      'search': artistName,
      'limit': '1',
      'namespace': '0',
      'format': 'json',
    });
    final data = await _getJsonFromInternet(uri);
    if (data is! List || data.length < 2) return null;
    final titles = data[1];
    if (titles is! List || titles.isEmpty) return null;
    return titles.first?.toString();
  }

  Future<String?> _resolveWikipediaThumbnail(String title) async {
    final uri = Uri.https('en.wikipedia.org', '/w/api.php', {
      'action': 'query',
      'format': 'json',
      'prop': 'pageimages',
      'piprop': 'thumbnail',
      'pithumbsize': '600',
      'titles': title,
    });

    final data = await _getJsonFromInternet(uri);
    if (data is! Map<String, dynamic>) return null;
    final query = data['query'];
    if (query is! Map<String, dynamic>) return null;
    final pages = query['pages'];
    if (pages is! Map<String, dynamic>) return null;

    for (final page in pages.values) {
      if (page is! Map<String, dynamic>) continue;
      final thumbnail = page['thumbnail'];
      if (thumbnail is! Map<String, dynamic>) continue;
      final source = thumbnail['source'];
      if (source is String && source.isNotEmpty) return source;
    }
    return null;
  }

  Future<dynamic> _getJsonFromInternet(Uri uri) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, 'VMMusic/1.0');
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}', uri: uri);
      }
      final body = await response.transform(utf8.decoder).join();
      return jsonDecode(body);
    } finally {
      client.close(force: true);
    }
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
  final VoidCallback onArtistTap;
  final bool canAddToPlaylist;
  final VoidCallback onAddToPlaylist;
  final VoidCallback onAddToFavorites;

  const _DefaultNowPlayingHero({
    super.key,
    required this.manager,
    required this.onArtistTap,
    required this.canAddToPlaylist,
    required this.onAddToPlaylist,
    required this.onAddToFavorites,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      key: key,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(child: _ArtworkImage(url: manager.trackThumbnailUrl, size: 310)),
        const SizedBox(height: 28),
        SizedBox(
          width: double.infinity,
          child: _AutoScrollText(
            text: manager.trackTitle ?? 'Cargando canción...',
            style: CupertinoTheme.of(context).textTheme.navLargeTitleTextStyle.copyWith(
                  fontSize: 34,
                  fontWeight: FontWeight.w700,
                ),
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
                  style: CupertinoTheme.of(context).textTheme.textStyle.copyWith(
                        fontSize: 20,
                        color: CupertinoColors.secondaryLabel.resolveFrom(context),
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

class _AutoScrollText extends StatefulWidget {
  final String text;
  final TextStyle style;

  const _AutoScrollText({
    required this.text,
    required this.style,
  });

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
              final eased = Curves.easeInOutCubic.transform(_scrollController!.value);
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
                              style: CupertinoTheme.of(context).textTheme.textStyle.copyWith(
                                    fontSize: 14,
                                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
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
          color: CupertinoColors.systemGrey6.resolveFrom(context).withValues(alpha: 0.58),
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

class _PlaylistPickerRow extends StatelessWidget {
  final String name;
  final int songsCount;
  final String? coverUrl;
  final bool isFavorites;
  final VoidCallback onTap;

  const _PlaylistPickerRow({
    required this.name,
    required this.songsCount,
    required this.coverUrl,
    required this.isFavorites,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Material(
          color: Colors.white.withValues(alpha: 0.05),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
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
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox(
                      width: 52,
                      height: 52,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          coverUrl == null || coverUrl!.isEmpty
                              ? Container(
                                  color: CupertinoColors.systemGrey4.resolveFrom(context),
                                  alignment: Alignment.center,
                                  child: Icon(
                                    isFavorites
                                        ? CupertinoIcons.star_fill
                                        : CupertinoIcons.music_note_list,
                                    size: 20,
                                    color: CupertinoColors.white,
                                  ),
                                )
                              : Image.network(
                                  coverUrl!,
                                  fit: BoxFit.cover,
                                  alignment: Alignment.center,
                                  errorBuilder: (context, _, stackTrace) => Container(
                                    color: CupertinoColors.systemGrey4.resolveFrom(context),
                                    alignment: Alignment.center,
                                    child: Icon(
                                      isFavorites
                                          ? CupertinoIcons.star_fill
                                          : CupertinoIcons.music_note_list,
                                      size: 20,
                                      color: CupertinoColors.white,
                                    ),
                                  ),
                                ),
                          if (isFavorites)
                            Align(
                              alignment: Alignment.topRight,
                              child: Container(
                                margin: const EdgeInsets.all(3),
                                width: 15,
                                height: 15,
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.42),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  CupertinoIcons.star_fill,
                                  size: 9,
                                  color: Color(0xFFFFD24A),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: '.SF Pro Text',
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '$songsCount canciones',
                          style: TextStyle(
                            fontFamily: '.SF Pro Text',
                            fontSize: 12,
                            color: CupertinoColors.secondaryLabel.resolveFrom(context),
                          ),
                        ),
                      ],
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

class _IosTopToast extends StatefulWidget {
  final String message;
  final IconData icon;

  const _IosTopToast({
    required this.message,
    required this.icon,
  });

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
                    borderRadius: BorderRadius.circular(10),
                    child: Image.network(
                      item.thumbnailUrl,
                      width: 56,
                      height: 56,
                      fit: BoxFit.cover,
                      alignment: Alignment.center,
                      errorBuilder: (context, error, stackTrace) => Container(
                        width: 56,
                        height: 56,
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
    return SizedBox.square(
      dimension: size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: url == null || url!.isEmpty
              ? Icon(
                  Icons.music_note_rounded,
                  size: size * 0.4,
                  color: Theme.of(context).colorScheme.primary,
                )
              : Image.network(
                  url!,
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                  alignment: Alignment.center,
                  errorBuilder: (context, error, stackTrace) => Icon(
                    Icons.music_note_rounded,
                    size: size * 0.4,
                    color: Theme.of(context).colorScheme.primary,
                  ),
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
