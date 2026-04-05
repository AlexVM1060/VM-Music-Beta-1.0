
import 'package:hive/hive.dart';
import 'package:myapp/models/video_history.dart';

part 'playlist.g.dart';

@HiveType(typeId: 2)
class Playlist extends HiveObject {
  @HiveField(0)
  final String name;

  @HiveField(1)
  final List<VideoHistory> videos;

  Playlist({required this.name, this.videos = const []});
}
