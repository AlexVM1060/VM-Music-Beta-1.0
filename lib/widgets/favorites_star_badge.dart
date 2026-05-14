import 'package:flutter/cupertino.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:myapp/models/playlist.dart';
import 'package:myapp/services/playlist_service.dart';

class FavoritesStarBadge extends StatelessWidget {
  final String videoId;
  final double size;

  const FavoritesStarBadge({super.key, required this.videoId, this.size = 15});

  static String _canonicalId(String raw) {
    final id = raw.trim();
    if (id.startsWith('ytmxmv:')) return id.substring(7).trim();
    if (id.startsWith('ytmx:')) return id.substring(5).trim();
    return id;
  }

  static bool _isFavoriteVideo(Box<Playlist> box, String videoId) {
    final target = _canonicalId(videoId);
    if (target.isEmpty) return false;
    for (final playlist in box.values) {
      if (!PlaylistService.isFavoritesPlaylistName(playlist.name)) continue;
      return playlist.videos.any((v) => _canonicalId(v.videoId) == target);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (!Hive.isBoxOpen('playlists')) return const SizedBox.shrink();
    final box = Hive.box<Playlist>('playlists');
    return ValueListenableBuilder<Box<Playlist>>(
      valueListenable: box.listenable(),
      builder: (context, playlistsBox, _) {
        if (!_isFavoriteVideo(playlistsBox, videoId)) {
          return const SizedBox.shrink();
        }
        return Icon(
          CupertinoIcons.star_fill,
          size: size,
          color: const Color(0xFFFFA726),
        );
      },
    );
  }
}
