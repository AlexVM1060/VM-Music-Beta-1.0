import 'package:flutter/material.dart';
import 'package:myapp/models/downloaded_video.dart';
import 'package:myapp/models/playlist.dart';
import 'package:myapp/services/download_service.dart';
import 'package:myapp/services/playlist_service.dart';
import 'package:myapp/video_player_manager.dart';
import 'package:provider/provider.dart';
import 'package:collection/collection.dart';

class PlaylistDetailPage extends StatefulWidget {
  final Playlist playlist;

  const PlaylistDetailPage({super.key, required this.playlist});

  @override
  State<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends State<PlaylistDetailPage> {
  late Playlist _currentPlaylist;

  @override
  void initState() {
    super.initState();
    _currentPlaylist = Playlist(
      name: widget.playlist.name,
      videos: List.from(widget.playlist.videos),
    );
  }

  @override
  Widget build(BuildContext context) {
    final playlistService = Provider.of<PlaylistService>(context, listen: false);
    final downloadService = Provider.of<DownloadService>(context);
    final videoManager = Provider.of<VideoPlayerManager>(context, listen: false);
    final isAutoDownload = downloadService.isPlaylistAutoDownload(_currentPlaylist.name);

    return Scaffold(
      appBar: AppBar(
        title: Text(_currentPlaylist.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.download_for_offline),
            tooltip: 'Descargar todo',
            onPressed: () async {
              final summary = await downloadService.downloadPlaylistVideos(
                _currentPlaylist.videos,
              );
              if (!context.mounted) return;
              final message = summary.queued > 0
                  ? 'Descargando ${summary.queued} canciones. ${summary.alreadyDownloaded} ya estaban descargadas.'
                  : summary.alreadyInProgress > 0
                      ? 'Ya hay ${summary.alreadyInProgress} canciones descargándose.'
                      : 'No hay canciones nuevas por descargar.';
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(message)),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          SwitchListTile(
            title: const Text('Descarga automática'),
            subtitle: const Text('Las nuevas canciones se descargarán automáticamente'),
            value: isAutoDownload,
            onChanged: (bool value) {
              downloadService.setPlaylistAutoDownload(_currentPlaylist.name, value);
            },
          ),
          Expanded(
            child: FutureBuilder<List<DownloadedVideo>>(
              future: downloadService.getDownloadedVideos(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final downloadedVideos = snapshot.data!;
                return _currentPlaylist.videos.isEmpty
                    ? const Center(child: Text('Esta playlist no contiene canciones.'))
                    : ListView.builder(
                        itemCount: _currentPlaylist.videos.length,
                        itemBuilder: (context, index) {
                          final video = _currentPlaylist.videos[index];
                          final downloadedVideo = downloadedVideos.firstWhereOrNull(
                            (v) => v.videoId == video.videoId,
                          );

                          return ListTile(
                            leading: Image.network(video.thumbnailUrl, width: 100, fit: BoxFit.cover),
                            title: Text(video.title),
                            subtitle: Text(video.channelTitle),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _DownloadStatusIndicator(
                                  status: downloadService.getDownloadStatus(video.videoId),
                                  progress: downloadService.getDownloadProgress(video.videoId),
                                  isDownloaded: downloadedVideo != null,
                                ),
                                IconButton(
                                  icon: const Icon(Icons.download_for_offline_outlined),
                                  tooltip: 'Descargar',
                                  onPressed: downloadedVideo != null
                                      ? null
                                      : () {
                                          downloadService.downloadVideo(
                                            video.videoId,
                                            video.title,
                                            video.thumbnailUrl,
                                            video.channelTitle,
                                          );
                                        },
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete, color: Colors.red),
                                  onPressed: () async {
                                    // Si existe descarga local, también la eliminamos.
                                    await downloadService.deleteVideo(video.videoId);
                                    await playlistService.removeVideoFromPlaylist(
                                        _currentPlaylist.name, video.videoId);

                                    // Comprobación de seguridad
                                    if (!context.mounted) return;

                                    setState(() {
                                      _currentPlaylist.videos.removeAt(index);
                                    });
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                          content: Text('Canción eliminada de la playlist')),
                                    );
                                  },
                                ),
                              ],
                            ),
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
                                );
                                return;
                              }

                              await videoManager.play(video.videoId);
                            },
                          );
                        },
                      );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _DownloadStatusIndicator extends StatelessWidget {
  final DownloadStatus status;
  final double progress;
  final bool isDownloaded;

  const _DownloadStatusIndicator({
    required this.status,
    required this.progress,
    required this.isDownloaded,
  });

  @override
  Widget build(BuildContext context) {
    if (isDownloaded || status == DownloadStatus.downloaded) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 4),
        child: Icon(Icons.check_circle, color: Colors.green),
      );
    }

    if (status == DownloadStatus.downloading) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            value: progress > 0 ? progress : null,
            strokeWidth: 2,
          ),
        ),
      );
    }

    if (status == DownloadStatus.error) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 4),
        child: Icon(Icons.error, color: Colors.red),
      );
    }

    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 4),
      child: Icon(Icons.cloud_download_outlined, color: Colors.grey),
    );
  }
}
