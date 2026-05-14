import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:myapp/models/downloaded_video.dart';
import 'package:myapp/models/playlist.dart';
import 'package:myapp/services/download_service.dart';
import 'package:myapp/services/playlist_service.dart';
import 'package:myapp/video_player_manager.dart';
import 'package:myapp/widgets/app_back_circle_button.dart';
import 'package:myapp/widgets/ios_notice.dart';
import 'package:myapp/widgets/square_thumbnail.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

class PlaylistsPage extends StatefulWidget {
  final ValueChanged<Playlist>? onOpenPlaylist;
  final ValueChanged<Playlist>? onPinPlaylist;
  final ValueChanged<Playlist>? onUnpinPlaylist;
  final bool Function(Playlist playlist)? isPlaylistPinned;
  final VoidCallback? onBack;
  final bool useSafeArea;

  const PlaylistsPage({
    super.key,
    this.onOpenPlaylist,
    this.onPinPlaylist,
    this.onUnpinPlaylist,
    this.isPlaylistPinned,
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

  Future<void> _createPlaylist() async {
    final payload = await Navigator.of(context).push<_NewPlaylistPayload>(
      CupertinoPageRoute<_NewPlaylistPayload>(
        builder: (_) => const _CreatePlaylistPage(),
      ),
    );
    if (!mounted || payload == null) return;
    try {
      await context.read<PlaylistService>().createPlaylist(
        payload.name,
        coverUrl: payload.coverUrl,
        description: payload.description,
      );
      _loadPlaylists();
    } catch (e) {
      if (!mounted) return;
      showIosNotice(context, e.toString().replaceFirst('Exception: ', ''));
    }
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
                        AppBackCircleButton(onPressed: widget.onBack),
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
                      onPressed: () {
                        unawaited(_createPlaylist());
                      },
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

                            final tile = Padding(
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
                                      width:
                                          MediaQuery.sizeOf(context).width - 24,
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

                            if (!Platform.isIOS) return tile;
                            final isPinned =
                                widget.isPlaylistPinned?.call(playlist) ??
                                false;
                            return CupertinoContextMenu(
                              enableHapticFeedback: true,
                              actions: [
                                CupertinoContextMenuAction(
                                  trailingIcon: isPinned
                                      ? CupertinoIcons.pin_slash_fill
                                      : CupertinoIcons.pin_fill,
                                  onPressed: () {
                                    Navigator.of(context).pop();
                                    if (isPinned) {
                                      widget.onUnpinPlaylist?.call(playlist);
                                    } else {
                                      widget.onPinPlaylist?.call(playlist);
                                    }
                                  },
                                  child: Text(
                                    isPinned
                                        ? 'Desanclar Playlist'
                                        : 'Anclar Playlist',
                                  ),
                                ),
                              ],
                              child: tile,
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

class _NewPlaylistPayload {
  final String name;
  final String? coverUrl;
  final String? description;

  const _NewPlaylistPayload({
    required this.name,
    this.coverUrl,
    this.description,
  });
}

class _CreatePlaylistPage extends StatefulWidget {
  const _CreatePlaylistPage();

  @override
  State<_CreatePlaylistPage> createState() => _CreatePlaylistPageState();
}

class _CreatePlaylistPageState extends State<_CreatePlaylistPage> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  String? _coverPath;
  bool _saving = false;

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _pickCover() async {
    final picker = ImagePicker();
    final file = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 90,
      maxWidth: 1800,
      maxHeight: 1800,
    );
    if (file == null || !mounted) return;
    setState(() {
      _coverPath = file.path;
    });
  }

  Future<String?> _persistCoverIfNeeded(String? sourcePath) async {
    final raw = sourcePath?.trim() ?? '';
    if (raw.isEmpty || !raw.startsWith('/')) return null;
    final source = File(raw);
    if (!await source.exists()) return null;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/playlist_covers');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final ext = p.extension(raw).toLowerCase();
    final safeExt = ext.isEmpty ? '.jpg' : ext;
    final fileName = 'cover_${DateTime.now().millisecondsSinceEpoch}$safeExt';
    final target = File('${dir.path}/$fileName');
    await source.copy(target.path);
    return target.path;
  }

  Future<void> _submit() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      showIosNotice(context, 'Escribe un nombre para la playlist.');
      return;
    }
    if (_saving) return;
    setState(() {
      _saving = true;
    });
    try {
      final persistedCover = await _persistCoverIfNeeded(_coverPath);
      if (!mounted) return;
      Navigator.of(context).pop(
        _NewPlaylistPayload(
          name: name,
          coverUrl: persistedCover,
          description: _descriptionController.text.trim(),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
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
        middle: const Text('Nueva playlist'),
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
          onPressed: _saving ? null : _submit,
          child: _saving
              ? const CupertinoActivityIndicator(radius: 10)
              : const Text(
                  'Crear',
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
                  child: _coverPath == null
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
                      : Image.file(File(_coverPath!), fit: BoxFit.cover),
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
                      _coverPath == null
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
            const SizedBox(height: 18),
            CupertinoTextField(
              controller: _nameController,
              autofocus: true,
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
          ],
        ),
      ),
    );
  }
}
