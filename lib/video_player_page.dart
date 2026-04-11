import 'dart:async';
import 'dart:developer';
import 'dart:io';

import 'package:chewie/chewie.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:myapp/models/video_history.dart';
import 'package:myapp/services/app_settings_service.dart';
import 'package:myapp/services/download_service.dart';
import 'package:myapp/services/playlist_service.dart';
import 'package:myapp/utils/thumbnail_quality.dart';
import 'package:myapp/video_player_manager.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class VideoPlayerPage extends StatefulWidget {
  final String videoId;

  const VideoPlayerPage({super.key, required this.videoId});

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  VideoPlayerController? _videoPlayerController;
  ChewieController? _chewieController;
  final _ytExplode = YoutubeExplode();
  String _videoTitle = '';
  Video? _video;
  Offset _dragOffset = const Offset(200, 400);
  bool _isLoading = true;

  late final VideoPlayerManager _manager;

  List<MuxedStreamInfo> _muxedStreamInfos = [];
  MuxedStreamInfo? _selectedStreamInfo;

  @override
  void initState() {
    super.initState();
    _manager = Provider.of<VideoPlayerManager>(context, listen: false);
    _manager.init();
    _initializePlayer();
  }

  Future<void> _initializePlayer() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
    });

    try {
      final settings = context.read<AppSettingsService?>();
      final targetHeight = _targetVideoHeightForQuality(settings?.audioQuality);
      await _manager.play(widget.videoId);
      final manifestFuture = _runYoutubeWithRetry(
        () => _ytExplode.videos.streamsClient.getManifest(widget.videoId),
      );
      final videoFuture = _runYoutubeWithRetry(
        () => _ytExplode.videos.get(VideoId(widget.videoId)),
      );

      final manifest = await manifestFuture;
      _video = await videoFuture;

      if (mounted) {
        _videoTitle = _video!.title;
      }

      final allMuxedStreams = manifest.muxed.toList()
        ..sort((a, b) {
          final aHeight = a.videoResolution.height;
          final bHeight = b.videoResolution.height;
          if (targetHeight == null) {
            final heightCompare = bHeight.compareTo(aHeight);
            if (heightCompare != 0) return heightCompare;
          } else {
            final aWithinTarget = aHeight <= targetHeight;
            final bWithinTarget = bHeight <= targetHeight;
            if (aWithinTarget != bWithinTarget) {
              return aWithinTarget ? -1 : 1;
            }
            if (aWithinTarget) {
              final heightCompare = bHeight.compareTo(aHeight);
              if (heightCompare != 0) return heightCompare;
            } else {
              final heightCompare = aHeight.compareTo(bHeight);
              if (heightCompare != 0) return heightCompare;
            }
          }
          final frameRateCompare = b.videoQuality.index.compareTo(
            a.videoQuality.index,
          );
          if (frameRateCompare != 0) return frameRateCompare;
          return b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond);
        });
      final mp4Streams = allMuxedStreams
          .where((stream) => stream.container.name.toLowerCase() == 'mp4')
          .toList();

      // iOS (AVPlayer) es más estricto con codecs/contenedores; priorizamos MP4.
      _muxedStreamInfos = Platform.isIOS ? mp4Streams : allMuxedStreams;

      // Fallback por si no hay MP4 en el manifiesto.
      if (_muxedStreamInfos.isEmpty) {
        _muxedStreamInfos = allMuxedStreams;
      }

      if (_muxedStreamInfos.isEmpty) {
        throw Exception('No muxed streams found');
      }

      await _buildPlayerWithFallback();

      _fetchRelatedVideos(_video!);
    } catch (e) {
      log('Error initializing player: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Error al reproducir el video.')),
        );
        _manager.close();
      }
    }
  }

  Future<T> _runYoutubeWithRetry<T>(
    Future<T> Function() action, {
    int maxAttempts = 3,
  }) async {
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await action();
      } on RequestLimitExceededException {
        rethrow;
      } on SocketException catch (e) {
        lastError = e;
      } on HttpException catch (e) {
        lastError = e;
      } catch (e) {
        lastError = e;
      }
      if (attempt < maxAttempts) {
        await Future<void>.delayed(Duration(seconds: attempt * 2));
      }
    }
    throw lastError ?? Exception('Error de red al consultar YouTube');
  }

  Future<void> _buildPlayerWithStream(
    MuxedStreamInfo streamInfo, {
    Duration startAt = Duration.zero,
    bool showError = true,
  }) async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
    });

    try {
      await _disposeControllers();

      _videoPlayerController = VideoPlayerController.networkUrl(streamInfo.url);
      await _videoPlayerController!.initialize();
      await _videoPlayerController!.seekTo(startAt);

      if (mounted) {
        _manager.setPlayerData(
          videoId: widget.videoId,
          controller: _videoPlayerController!,
          streamUrl: streamInfo.url.toString(),
          title: _videoTitle,
          thumbnailUrl: _bestQualityThumbnail(_video!),
          channelTitle: _video!.author,
          duration: _video!.duration, // Se pasa la duración del video
        );

        _chewieController = ChewieController(
          videoPlayerController: _videoPlayerController!,
          autoPlay: true,
          looping: false,
          aspectRatio: 16 / 9,
          allowFullScreen: true,
          allowedScreenSleep: false,
          autoInitialize: true,
        );

        _selectedStreamInfo = streamInfo;

        setState(() {
          _isLoading = false;
        });
      }
    } catch (e) {
      log('Error building player: $e');
      if (mounted && showError) {
        setState(() {
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al cambiar de calidad: $e')),
        );
      }
      rethrow;
    }
  }

  Future<void> _buildPlayerWithFallback() async {
    Object? lastError;
    for (final stream in _muxedStreamInfos) {
      try {
        await _buildPlayerWithStream(stream, showError: false);
        return;
      } catch (e) {
        lastError = e;
      }
    }
    throw Exception(
      'No se pudo inicializar ninguna calidad de video: $lastError',
    );
  }

  Future<void> _changeQuality(MuxedStreamInfo newStreamInfo) async {
    if (_selectedStreamInfo?.videoQuality == newStreamInfo.videoQuality) {
      return;
    }

    final currentPosition =
        _videoPlayerController?.value.position ?? Duration.zero;
    try {
      await _buildPlayerWithStream(newStreamInfo, startAt: currentPosition);
    } catch (_) {
      // El error ya fue mostrado al usuario en _buildPlayerWithStream.
    }
  }

  void _showQualityOptions(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Seleccionar Calidad'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: _muxedStreamInfos.map((streamInfo) {
                final isSelected =
                    streamInfo.videoQuality ==
                    _selectedStreamInfo?.videoQuality;
                return ListTile(
                  title: Text(
                    '${streamInfo.videoResolution.height}p',
                    style: TextStyle(
                      fontWeight: isSelected
                          ? FontWeight.bold
                          : FontWeight.normal,
                      color: isSelected ? Theme.of(context).primaryColor : null,
                    ),
                  ),
                  onTap: () {
                    Navigator.of(context).pop();
                    _changeQuality(streamInfo);
                  },
                );
              }).toList(),
            ),
          ),
        );
      },
    );
  }

  Future<void> _fetchRelatedVideos(Video video) async {
    // Eliminado: funcionalidad de videos relacionados
  }

  int? _targetVideoHeightForQuality(AudioQualityPreference? quality) {
    return switch (quality) {
      AudioQualityPreference.low => 240,
      AudioQualityPreference.normal => 420,
      AudioQualityPreference.high => 720,
      AudioQualityPreference.veryHigh => null,
      AudioQualityPreference.automatic => 420,
      null => 420,
    };
  }

  @override
  void didUpdateWidget(covariant VideoPlayerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoId != widget.videoId) {
      _disposeControllers();
      _initializePlayer();
    }
  }

  Future<void> _disposeControllers() async {
    await _videoPlayerController?.dispose();
    _chewieController?.dispose();
  }

  @override
  void dispose() {
    _disposeControllers();
    _ytExplode.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isMinimized = _manager.isMinimized;

    const double minimizedWidth = 250.0;
    const double minimizedHeight = 140.6;

    final playerWidget =
        _chewieController != null &&
            _chewieController!.videoPlayerController.value.isInitialized
        ? Chewie(controller: _chewieController!)
        : const Center(child: CupertinoActivityIndicator());

    if (_isLoading && !isMinimized) {
      return Scaffold(body: Center(child: playerWidget));
    }

    return AnimatedPositioned(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      top: isMinimized ? _dragOffset.dy : 0,
      left: isMinimized ? _dragOffset.dx : 0,
      right: isMinimized ? null : 0,
      bottom: isMinimized ? null : 0,
      child: Draggable(
        feedback: Material(
          elevation: 8.0,
          child: _buildMinimizedLayout(
            minimizedWidth,
            minimizedHeight,
            playerWidget,
          ),
        ),
        maxSimultaneousDrags: isMinimized ? 1 : 0,
        onDragEnd: (details) {
          final size = MediaQuery.of(context).size;
          double dx = details.offset.dx;
          double dy = details.offset.dy;

          if (dx < 0) dx = 0;
          if (dx > size.width - minimizedWidth) {
            dx = size.width - minimizedWidth;
          }
          if (dy < 0) dy = 0;
          if (dy > size.height - minimizedHeight) {
            dy = size.height - minimizedHeight;
          }

          setState(() {
            _dragOffset = Offset(dx, dy);
          });
        },
        child: _buildPlayerContent(
          isMinimized,
          minimizedWidth,
          minimizedHeight,
          playerWidget,
        ),
      ),
    );
  }

  Widget _buildPlayerContent(
    bool isMinimized,
    double minWidth,
    double minHeight,
    Widget player,
  ) {
    final screenSize = MediaQuery.of(context).size;

    return GestureDetector(
      onTap: isMinimized ? _manager.maximize : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
        width: isMinimized ? minWidth : screenSize.width,
        height: isMinimized ? minHeight : screenSize.height,
        child: Material(
          elevation: 4.0,
          child: isMinimized
              ? _buildMinimizedLayout(minWidth, minHeight, player)
              : _buildMaximizedLayout(player),
        ),
      ),
    );
  }

  Widget _buildMaximizedLayout(Widget player) {
    final playlistService = Provider.of<PlaylistService>(
      context,
      listen: false,
    );

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Portada de álbum (en vez de video)
              if (_video != null)
                Padding(
                  padding: const EdgeInsets.only(
                    top: 24.0,
                    left: 24.0,
                    right: 24.0,
                    bottom: 8.0,
                  ),
                  child: Center(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Transform.scale(
                        scale: 1.06,
                        child: Image.network(
                          _bestQualityThumbnail(_video!),
                          width: 260,
                          height: 260,
                          fit: BoxFit.cover,
                          alignment: Alignment.center,
                          errorBuilder: (context, error, stackTrace) =>
                              Container(
                                width: 260,
                                height: 260,
                                color: Colors.grey[300],
                                child: const Icon(
                                  Icons.music_note,
                                  size: 80,
                                  color: Colors.grey,
                                ),
                              ),
                        ),
                      ),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        _videoTitle,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 16),
                    DownloadButton(videoId: widget.videoId, video: _video),
                    IconButton(
                      icon: const Icon(Icons.favorite_border),
                      tooltip: 'Añadir a favoritos',
                      onPressed: () async {
                        if (_video == null) return;
                        final downloadService = Provider.of<DownloadService>(
                          context,
                          listen: false,
                        );
                        final videoHistory = VideoHistory(
                          videoId: _video!.id.value,
                          title: _video!.title,
                          thumbnailUrl: _bestQualityThumbnail(_video!),
                          channelTitle: _video!.author,
                          watchedAt: DateTime.now(),
                        );
                        await playlistService.addVideoToPlaylist(
                          PlaylistService.favoritesPlaylistName,
                          videoHistory,
                        );
                        await downloadService.autoDownloadIfEnabledUsingClone(
                          PlaylistService.favoritesPlaylistName,
                          videoHistory,
                          videoManager: _manager,
                        );
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Añadido a favoritos')),
                        );
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.settings),
                      tooltip: 'Cambiar Calidad',
                      onPressed: () {
                        if (_muxedStreamInfos.isNotEmpty) {
                          _showQualityOptions(context);
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'No hay otras calidades disponibles.',
                              ),
                            ),
                          );
                        }
                      },
                    ),
                  ],
                ),
              ),
              // Mini player (barra de controles)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: player,
              ),
              // Lyrics (placeholder, puedes conectar a API de lyrics si lo deseas)
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Letra',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.grey[100],
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text(
                        'Aquí aparecerá la letra de la canción (lyrics).',
                        style: TextStyle(fontSize: 16, color: Colors.black87),
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

  Widget _buildMinimizedLayout(double width, double height, Widget player) {
    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        alignment: Alignment.center,
        children: [
          player,
          Positioned(
            top: 0,
            right: 0,
            child: CupertinoButton(
              padding: const EdgeInsets.all(4),
              onPressed: () => _manager.close(),
              child: const Icon(
                CupertinoIcons.xmark,
                color: Colors.white,
                size: 20,
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            child: CupertinoButton(
              padding: const EdgeInsets.all(4),
              onPressed: _manager.maximize,
              child: const Icon(
                Icons.open_in_full,
                color: Colors.white,
                size: 20,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class DownloadButton extends StatelessWidget {
  final String videoId;
  final Video? video;

  const DownloadButton({super.key, required this.videoId, this.video});

  @override
  Widget build(BuildContext context) {
    final downloadService = context.watch<DownloadService>();
    final status = downloadService.getDownloadStatus(videoId);

    switch (status) {
      case DownloadStatus.downloading:
        final progress = downloadService.getDownloadProgress(videoId);
        return Stack(
          alignment: Alignment.center,
          children: [
            CircularProgressIndicator(value: progress),
            const Icon(Icons.downloading, size: 20),
          ],
        );
      case DownloadStatus.downloaded:
        return const Icon(Icons.check_circle, color: Colors.green);
      case DownloadStatus.error:
        return const Icon(Icons.error, color: Colors.red);
      case DownloadStatus.notDownloaded:
        return IconButton(
          icon: const Icon(Icons.download),
          tooltip: 'Descargar video',
          onPressed: () {
            if (video == null) return;
            downloadService.downloadVideo(
              videoId,
              video!.title,
              _bestQualityThumbnail(video!),
              video!.author,
            );
          },
        );
    }
  }
}

String _bestQualityThumbnail(Video video) {
  return bestThumbnailForVideo(video);
}
