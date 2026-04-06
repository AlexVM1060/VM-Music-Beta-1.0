import 'package:hive/hive.dart';

part 'downloaded_video.g.dart';

@HiveType(typeId: 3)
class DownloadedVideo extends HiveObject {
  @HiveField(0)
  final String videoId;

  @HiveField(1)
  final String title;

  @HiveField(2)
  final String thumbnailUrl;

  @HiveField(3)
  final String channelTitle;

  @HiveField(4)
  final String filePath; // Path al archivo de vídeo descargado

  @HiveField(5)
  final String? plainLyrics;

  @HiveField(6)
  final String? syncedLyrics;

  @HiveField(7)
  final String? localThumbnailPath;

  DownloadedVideo({
    required this.videoId,
    required this.title,
    required this.thumbnailUrl,
    required this.channelTitle,
    required this.filePath,
    this.plainLyrics,
    this.syncedLyrics,
    this.localThumbnailPath,
  });
}
