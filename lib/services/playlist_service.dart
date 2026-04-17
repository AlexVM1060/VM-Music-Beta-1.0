import 'package:hive/hive.dart';
import 'package:myapp/models/playlist.dart';
import 'package:myapp/models/video_history.dart';

class PlaylistService {
  static const String _boxName = 'playlists';
  static const String favoritesPlaylistName = 'Favoritos';
  static const String _legacyFavoritesPlaylistName = 'Videos favoritos';

  Future<Box<Playlist>> get _box async =>
      await Hive.openBox<Playlist>(_boxName);

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
    final normalizedName = _normalizePlaylistName(name.trim());
    if (normalizedName.isEmpty) {
      throw Exception('El nombre de la playlist no puede estar vacío');
    }
    if (box.values.any(
      (p) => p.name.toLowerCase() == normalizedName.toLowerCase(),
    )) {
      throw Exception('Ya existe una playlist con este nombre');
    }
    await box.add(Playlist(name: normalizedName, videos: []));
  }

  Future<void> addVideoToPlaylist(
    String playlistName,
    VideoHistory video,
  ) async {
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

  Future<int> addVideosToPlaylist(
    String playlistName,
    List<VideoHistory> videos,
  ) async {
    if (videos.isEmpty) return 0;
    final box = await _box;
    final normalizedName = _normalizePlaylistName(playlistName);
    Playlist? playlist;
    dynamic playlistKey;

    for (final entry in box.toMap().entries) {
      if (entry.value.name == normalizedName) {
        playlist = entry.value;
        playlistKey = entry.key;
        break;
      }
    }

    if (playlist == null) {
      await createPlaylist(normalizedName);
      for (final entry in box.toMap().entries) {
        if (entry.value.name == normalizedName) {
          playlist = entry.value;
          playlistKey = entry.key;
          break;
        }
      }
    }

    if (playlist == null || playlistKey == null) return 0;

    final existingIds = playlist.videos.map((v) => v.videoId).toSet();
    var added = 0;
    for (final video in videos) {
      if (existingIds.add(video.videoId)) {
        playlist.videos.add(video);
        added++;
      }
    }
    if (added > 0) {
      await box.put(playlistKey, playlist);
    }
    return added;
  }

  Future<void> removeVideoFromPlaylist(
    String playlistName,
    String videoId,
  ) async {
    final box = await _box;
    final normalizedName = _normalizePlaylistName(playlistName);
    final playlist = box.values.firstWhere((p) => p.name == normalizedName);
    playlist.videos.removeWhere((v) => v.videoId == videoId);
    await playlist.save();
  }

  Future<void> deletePlaylist(String playlistName) async {
    final box = await _box;
    final normalizedName = _normalizePlaylistName(playlistName.trim());
    if (isFavoritesPlaylistName(normalizedName)) {
      throw Exception('No se puede eliminar la playlist Favoritos');
    }

    dynamic playlistKey;
    for (final entry in box.toMap().entries) {
      if (entry.value.name == normalizedName) {
        playlistKey = entry.key;
        break;
      }
    }
    if (playlistKey == null) {
      throw Exception('No se encontró la playlist');
    }
    await box.delete(playlistKey);
  }

  Future<Playlist> updatePlaylistDetails({
    required String currentName,
    required String newName,
    String? coverUrl,
  }) async {
    final box = await _box;
    final normalizedCurrent = _normalizePlaylistName(currentName.trim());
    if (isFavoritesPlaylistName(normalizedCurrent)) {
      throw Exception('No se puede editar la playlist Favoritos');
    }

    final desiredName = newName.trim();
    if (desiredName.isEmpty) {
      throw Exception('El nombre de la playlist no puede estar vacío');
    }
    if (isFavoritesPlaylistName(desiredName)) {
      throw Exception('Ese nombre está reservado');
    }

    final normalizedNew = _normalizePlaylistName(desiredName);
    dynamic targetKey;
    Playlist? currentPlaylist;
    for (final entry in box.toMap().entries) {
      if (entry.value.name == normalizedCurrent) {
        targetKey = entry.key;
        currentPlaylist = entry.value;
        break;
      }
    }
    if (targetKey == null || currentPlaylist == null) {
      throw Exception('No se encontró la playlist');
    }

    final nameChanged =
        normalizedCurrent.toLowerCase() != normalizedNew.toLowerCase();
    if (nameChanged) {
      final duplicate = box.values.any(
        (playlist) =>
            playlist.name.toLowerCase() == normalizedNew.toLowerCase(),
      );
      if (duplicate) {
        throw Exception('Ya existe una playlist con este nombre');
      }
    }

    final cleanCover = (coverUrl ?? '').trim();
    final updated = Playlist(
      name: normalizedNew,
      videos: List<VideoHistory>.from(currentPlaylist.videos),
      coverUrl: cleanCover.isEmpty ? null : cleanCover,
    );
    await box.put(targetKey, updated);
    return updated;
  }

  Future<List<Playlist>> getPlaylists() async {
    final box = await _box;
    await _migrateLegacyFavoritesPlaylist(box);

    final playlists = box.values.toList();
    // Se asegura de que exista la playlist "Favoritos"
    if (!playlists.any((p) => p.name == favoritesPlaylistName)) {
      await box.add(
        Playlist(name: favoritesPlaylistName, videos: [], coverUrl: null),
      );
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
        Playlist(
          name: favoritesPlaylistName,
          videos: List.from(legacy.videos),
          coverUrl: legacy.coverUrl,
        ),
      );
      return;
    }

    final existingFavorites = favorites;
    final mergedVideos = <VideoHistory>[
      ...existingFavorites.videos,
      ...legacy.videos.where(
        (video) => !existingFavorites.videos.any(
          (existing) => existing.videoId == video.videoId,
        ),
      ),
    ];

    await box.put(
      favoritesKey,
      Playlist(
        name: favoritesPlaylistName,
        videos: mergedVideos,
        coverUrl: existingFavorites.coverUrl ?? legacy.coverUrl,
      ),
    );
    await box.delete(legacyKey);
  }
}
