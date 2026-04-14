import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:myapp/models/downloaded_video.dart';
import 'package:myapp/services/download_service.dart';
import 'package:myapp/video_player_manager.dart';
import 'package:myapp/widgets/square_thumbnail.dart';
import 'package:provider/provider.dart';

class DownloadsPage extends StatelessWidget {
  const DownloadsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final downloadService = context.watch<DownloadService>();
    final manager = context.read<VideoPlayerManager>();

    return Scaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground.resolveFrom(
        context,
      ),
      body: FutureBuilder<List<DownloadedVideo>>(
        future: downloadService.getDownloadedVideos(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CupertinoActivityIndicator(radius: 14));
          }

          if (!snapshot.hasData || snapshot.data!.isEmpty) {
            return const Center(child: Text('Aún no has descargado música.'));
          }

          final songs = snapshot.data!;
          return RefreshIndicator(
            onRefresh: () async {
              await downloadService.loadDownloadedVideos();
            },
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 20),
              itemCount: songs.length,
              itemBuilder: (context, index) {
                final song = songs[index];
                final localThumbPath = song.localThumbnailPath;
                final hasLocalThumb =
                    localThumbPath != null &&
                    localThumbPath.isNotEmpty &&
                    File(localThumbPath).existsSync();
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2.0),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Material(
                      color: CupertinoColors.secondarySystemGroupedBackground
                          .resolveFrom(context),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () async {
                          await manager.playLocalFileFromUserSelection(
                            context,
                            id: song.videoId,
                            filePath: song.filePath,
                            title: song.title,
                            thumbnailUrl: hasLocalThumb
                                ? localThumbPath
                                : song.thumbnailUrl,
                            artist: song.channelTitle,
                            localPlainLyrics: song.plainLyrics,
                            localSyncedLyrics: song.syncedLyrics,
                          );
                        },
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: CupertinoColors.separator
                                  .resolveFrom(context)
                                  .withValues(alpha: 0.12),
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
                                      fallback: Container(
                                        width: 64,
                                        height: 64,
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
                                      imageUrl: song.thumbnailUrl,
                                      size: 64,
                                      borderRadius: 10,
                                      fallback: Container(
                                        width: 64,
                                        height: 64,
                                        color: CupertinoColors
                                            .tertiarySystemFill
                                            .resolveFrom(context),
                                        alignment: Alignment.center,
                                        child: const Icon(
                                          CupertinoIcons.music_note,
                                        ),
                                      ),
                                    ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      song.title,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                          ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      song.channelTitle,
                                      style: TextStyle(
                                        color: CupertinoColors.secondaryLabel
                                            .resolveFrom(context),
                                        fontSize: 12,
                                        fontFamily: '.SF Pro Text',
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton(
                                icon: const Icon(
                                  CupertinoIcons.delete,
                                  color: CupertinoColors.systemRed,
                                ),
                                tooltip: 'Eliminar descarga',
                                onPressed: () async {
                                  await downloadService.deleteVideo(
                                    song.videoId,
                                  );
                                  if (!context.mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Canción eliminada de descargas.',
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
                );
              },
            ),
          );
        },
      ),
    );
  }
}
