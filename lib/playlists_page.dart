import 'dart:ui' show ImageFilter;
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:myapp/models/downloaded_video.dart';
import 'package:myapp/models/playlist.dart';
import 'package:myapp/services/download_service.dart';
import 'package:myapp/services/playlist_service.dart';
import 'package:myapp/widgets/square_thumbnail.dart';
import 'package:provider/provider.dart';

class PlaylistsPage extends StatefulWidget {
  final ValueChanged<Playlist>? onOpenPlaylist;

  const PlaylistsPage({super.key, this.onOpenPlaylist});

  @override
  State<PlaylistsPage> createState() => _PlaylistsPageState();
}

class _PlaylistsPageState extends State<PlaylistsPage> {
  late Future<List<Playlist>> _playlistsFuture;

  double _accountBottomOverlayReserve(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    const baseReserve = 108.0;
    return baseReserve + bottomInset;
  }

  @override
  void initState() {
    super.initState();
    _loadPlaylists();
  }

  void _loadPlaylists() {
    setState(() {
      _playlistsFuture =
          Provider.of<PlaylistService>(context, listen: false).getPlaylists();
    });
  }

  void _createPlaylist() {
    final TextEditingController controller = TextEditingController();
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
                if (controller.text.isNotEmpty) {
                  await Provider.of<PlaylistService>(context, listen: false)
                      .createPlaylist(controller.text);
                  
                  // Comprobación de seguridad
                  if (!context.mounted) return;
                  
                  Navigator.of(context).pop();
                  _loadPlaylists();
                }
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
    return FutureBuilder<List<Playlist>>(
      future: _playlistsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return const Center(child: Text('No se pudieron cargar las playlists.'));
        }

        final playlists = snapshot.data ?? const <Playlist>[];
        return FutureBuilder<List<DownloadedVideo>>(
          future: downloadService.getDownloadedVideos(),
          builder: (context, downloadedSnapshot) {
            final downloadedVideos = downloadedSnapshot.data ?? const <DownloadedVideo>[];
            final downloadedById = <String, DownloadedVideo>{
              for (final item in downloadedVideos) item.videoId: item,
            };
            return Column(
              children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
              child: Align(
                alignment: Alignment.centerRight,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                    child: Material(
                      color: Theme.of(context).brightness == Brightness.dark
                          ? Colors.white.withValues(alpha: 0.10)
                          : Colors.white.withValues(alpha: 0.65),
                      child: InkWell(
                        onTap: _createPlaylist,
                        borderRadius: BorderRadius.circular(18),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.28),
                              width: 0.6,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                CupertinoIcons.add,
                                size: 17,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 6),
                              const Text(
                                'Nueva playlist',
                                style: TextStyle(
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
                        8,
                        12,
                        _accountBottomOverlayReserve(context),
                      ),
                      itemCount: playlists.length,
                      itemBuilder: (context, index) {
                        final playlist = playlists[index];
                        final isFavorites =
                            PlaylistService.isFavoritesPlaylistName(playlist.name);
                        String? cover;
                        String? localCoverPath;
                        for (final video in playlist.videos) {
                          cover ??= video.thumbnailUrl;
                          final localPath = downloadedById[video.videoId]?.localThumbnailPath;
                          if (localPath != null &&
                              localPath.isNotEmpty &&
                              File(localPath).existsSync()) {
                            localCoverPath = localPath;
                            break;
                          }
                        }
                        final hasLocalCover = localCoverPath != null;
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2.0),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(14),
                            child: BackdropFilter(
                              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                              child: Material(
                                color: Colors.white.withValues(alpha: 0.035),
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
                                          borderRadius: BorderRadius.circular(10.0),
                                          child: SizedBox(
                                            width: 64,
                                            height: 64,
                                            child: Stack(
                                              fit: StackFit.expand,
                                              children: [
                                                (cover == null || cover.isEmpty) && !hasLocalCover
                                                    ? Container(
                                                        color: Theme.of(context)
                                                            .colorScheme
                                                            .surfaceContainerHighest,
                                                        alignment: Alignment.center,
                                                        child: Icon(
                                                          isFavorites
                                                              ? CupertinoIcons.star_fill
                                                              : CupertinoIcons.music_note_list,
                                                        ),
                                                      )
                                                    : hasLocalCover
                                                        ? SquareThumbnail.file(
                                                            filePath: localCoverPath,
                                                            size: 74,
                                                            borderRadius: 0,
                                                            fallback:
                                                                cover == null || cover.isEmpty
                                                                    ? Container(
                                                                        color: Theme.of(context)
                                                                            .colorScheme
                                                                            .surfaceContainerHighest,
                                                                        alignment: Alignment.center,
                                                                        child: Icon(
                                                                          isFavorites
                                                                              ? CupertinoIcons.star_fill
                                                                              : CupertinoIcons.music_note_list,
                                                                        ),
                                                                      )
                                                                    : SquareThumbnail.network(
                                                                        imageUrl: cover,
                                                                        size: 74,
                                                                        borderRadius: 0,
                                                                        fallback: Container(
                                                                          color: Theme.of(context)
                                                                              .colorScheme
                                                                              .surfaceContainerHighest,
                                                                        ),
                                                                      ),
                                                          )
                                                        : SquareThumbnail.network(
                                                            imageUrl: cover!,
                                                            size: 74,
                                                            borderRadius: 0,
                                                            fallback: Container(
                                                              color: Theme.of(context)
                                                                  .colorScheme
                                                                  .surfaceContainerHighest,
                                                              alignment: Alignment.center,
                                                              child: Icon(
                                                                isFavorites
                                                                    ? CupertinoIcons.star_fill
                                                                    : CupertinoIcons.music_note_list,
                                                              ),
                                                            ),
                                                          ),
                                                if (isFavorites)
                                                  Align(
                                                    alignment: Alignment.topRight,
                                                    child: Container(
                                                      margin: const EdgeInsets.all(4),
                                                      width: 16,
                                                      height: 16,
                                                      decoration: BoxDecoration(
                                                        color: Colors.black.withValues(alpha: 0.4),
                                                        shape: BoxShape.circle,
                                                      ),
                                                      child: const Icon(
                                                        CupertinoIcons.star_fill,
                                                        color: Colors.white,
                                                        size: 10,
                                                      ),
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 16),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                playlist.name,
                                                style: const TextStyle(
                                                  fontFamily: '.SF Pro Text',
                                                  fontSize: 16,
                                                  fontWeight: FontWeight.w700,
                                                  letterSpacing: -0.1,
                                                ),
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              const SizedBox(height: 4),
                                              Text(
                                                '${playlist.videos.length} canciones',
                                                style: TextStyle(
                                                  fontFamily: '.SF Pro Text',
                                                  fontSize: 13,
                                                  color: Theme.of(context)
                                                      .textTheme
                                                      .bodySmall
                                                      ?.color,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Icon(
                                          CupertinoIcons.chevron_right,
                                          size: 18,
                                          color: Theme.of(context).colorScheme.outline,
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
                    ),
            ),
              ],
            );
          },
        );
      },
    );
  }
}
