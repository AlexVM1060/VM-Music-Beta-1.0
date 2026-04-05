
import 'package:hive/hive.dart';

part 'video_history.g.dart';

@HiveType(typeId: 1)
class VideoHistory extends HiveObject {
  @HiveField(0)
  final String videoId;

  @HiveField(1)
  final String title;

  @HiveField(2)
  final String thumbnailUrl;

  @HiveField(3)
  final String channelTitle;

  @HiveField(4)
  final DateTime watchedAt;

  VideoHistory({
    required this.videoId,
    required this.title,
    required this.thumbnailUrl,
    required this.channelTitle,
    required this.watchedAt,
  });
}
