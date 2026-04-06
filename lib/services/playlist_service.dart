import 'package:hive/hive.dart';
import 'package:myapp/models/playlist.dart';
import 'package:myapp/models/video_history.dart';

class PlaylistService {
  static const String _boxName = 'playlists';
  static const String favoritesPlaylistName = 'Favoritos';
  static const String _legacyFavoritesPlaylistName = 'Videos favoritos';

  Future<Box<Playlist>> get _box async => await Hive.openBox<Playlist>(_boxName);

  static bool isFavoritesPlaylistName(String name) {
    final normalized = name.trim().toLowerCase();
    return normalized == favoritesPlaylistName.toLowerCase() ||
        normalized == _legacyFavoritesPlaylistName.toLowerCase();
  }

  String _normalizePlaylistName(String name) {
    if (isFavoritesPlaylistName(name)) return favoritesPlaylistName;
    return name;
  }

  Future<void> createPlaylist(String name) async {
    final box = await _box;
    final normalizedName = _normalizePlaylistName(name);
    if (box.values.any((p) => p.name == normalizedName)) {
      throw Exception('Ya existe una playlist con este nombre');
    }
    await box.add(Playlist(name: normalizedName, videos: []));
  }

  Future<void> addVideoToPlaylist(String playlistName, VideoHistory video) async {
    final box = await _box;
    final normalizedName = _normalizePlaylistName(playlistName);
    Playlist? playlist;
    dynamic playlistKey;

    // Busca la playlist por nombre
    for (var entry in box.toMap().entries) {
      if (entry.value.name == normalizedName) {
        playlist = entry.value;
        playlistKey = entry.key;
        break;
      }
    }

    if (playlist == null) {
      // Si no se encuentra, la crea
      await createPlaylist(normalizedName);
      // Vuelve a buscarla después de crearla
      for (var entry in box.toMap().entries) {
        if (entry.value.name == normalizedName) {
          playlist = entry.value;
          playlistKey = entry.key;
          break;
        }
      }
    }

    if (playlist != null && playlistKey != null) {
      if (!playlist.videos.any((v) => v.videoId == video.videoId)) {
        playlist.videos.add(video);
        // Vuelve a guardar la playlist actualizada en su clave
        await box.put(playlistKey, playlist);
      }
    }
  }

  Future<void> removeVideoFromPlaylist(String playlistName, String videoId) async {
    final box = await _box;
    final normalizedName = _normalizePlaylistName(playlistName);
    final playlist = box.values.firstWhere((p) => p.name == normalizedName);
    playlist.videos.removeWhere((v) => v.videoId == videoId);
    await playlist.save();
  }

  Future<List<Playlist>> getPlaylists() async {
    final box = await _box;
    await _migrateLegacyFavoritesPlaylist(box);

    final playlists = box.values.toList();
    // Se asegura de que exista la playlist "Favoritos"
    if (!playlists.any((p) => p.name == favoritesPlaylistName)) {
      await box.add(Playlist(name: favoritesPlaylistName, videos: []));
      return box.values.toList();
    }

    return playlists;
  }

  Future<void> _migrateLegacyFavoritesPlaylist(Box<Playlist> box) async {
    dynamic legacyKey;
    Playlist? legacy;
    dynamic favoritesKey;
    Playlist? favorites;

    for (final entry in box.toMap().entries) {
      if (entry.value.name == _legacyFavoritesPlaylistName) {
        legacyKey = entry.key;
        legacy = entry.value;
      } else if (entry.value.name == favoritesPlaylistName) {
        favoritesKey = entry.key;
        favorites = entry.value;
      }
    }

    if (legacy == null) return;

    if (favorites == null) {
      await box.put(
        legacyKey,
        Playlist(name: favoritesPlaylistName, videos: List.from(legacy.videos)),
      );
      return;
    }

    final existingFavorites = favorites;
    final mergedVideos = <VideoHistory>[
      ...existingFavorites.videos,
      ...legacy.videos.where(
        (video) =>
            !existingFavorites.videos.any((existing) => existing.videoId == video.videoId),
      ),
    ];

    await box.put(
      favoritesKey,
      Playlist(name: favoritesPlaylistName, videos: mergedVideos),
    );
    await box.delete(legacyKey);
  }
}
