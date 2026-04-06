import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:myapp/models/downloaded_video.dart';
import 'package:myapp/services/download_service.dart';
import 'package:myapp/video_player_manager.dart';
import 'package:provider/provider.dart';

class DownloadsPage extends StatelessWidget {
  const DownloadsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final downloadService = context.watch<DownloadService>();
    final manager = context.read<VideoPlayerManager>();

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: FutureBuilder<List<DownloadedVideo>>(
        future: downloadService.getDownloadedVideos(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (!snapshot.hasData || snapshot.data!.isEmpty) {
            return const Center(
              child: Text('Aún no has descargado música.'),
            );
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
                            manager.playLocalFile(
                              id: song.videoId,
                              filePath: song.filePath,
                              title: song.title,
                              thumbnailUrl: song.thumbnailUrl,
                              artist: song.channelTitle,
                              localPlainLyrics: song.plainLyrics,
                              localSyncedLyrics: song.syncedLyrics,
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
                                  borderRadius: BorderRadius.circular(10.0),
                                  child: Image.network(
                                    song.thumbnailUrl,
                                    width: 64,
                                    height: 64,
                                    fit: BoxFit.cover,
                                    alignment: Alignment.center,
                                    errorBuilder: (context, error, stackTrace) => Container(
                                      width: 64,
                                      height: 64,
                                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                      alignment: Alignment.center,
                                      child: const Icon(Icons.music_note_rounded),
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
                                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                              fontWeight: FontWeight.bold,
                                            ),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        song.channelTitle,
                                        style: Theme.of(context).textTheme.bodySmall,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline),
                                  tooltip: 'Eliminar descarga',
                                  onPressed: () async {
                                    await downloadService.deleteVideo(song.videoId);
                                    if (!context.mounted) return;
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('Canción eliminada de descargas.'),
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
            ),
          );
        },
      ),
    );
  }
}
