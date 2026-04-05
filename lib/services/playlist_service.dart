import 'package:hive/hive.dart';
import 'package:myapp/models/playlist.dart';
import 'package:myapp/models/video_history.dart';

class PlaylistService {
  static const String _boxName = 'playlists';

  Future<Box<Playlist>> get _box async => await Hive.openBox<Playlist>(_boxName);

  Future<void> createPlaylist(String name) async {
    final box = await _box;
    if (box.values.any((p) => p.name == name)) {
      throw Exception('Ya existe una playlist con este nombre');
    }
    await box.add(Playlist(name: name, videos: []));
  }

  Future<void> addVideoToPlaylist(String playlistName, VideoHistory video) async {
    final box = await _box;
    Playlist? playlist;
    dynamic playlistKey;

    // Busca la playlist por nombre
    for (var entry in box.toMap().entries) {
      if (entry.value.name == playlistName) {
        playlist = entry.value;
        playlistKey = entry.key;
        break;
      }
    }

    if (playlist == null) {
      // Si no se encuentra, la crea
      await createPlaylist(playlistName);
      // Vuelve a buscarla después de crearla
      for (var entry in box.toMap().entries) {
        if (entry.value.name == playlistName) {
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
    final playlist = box.values.firstWhere((p) => p.name == playlistName);
    playlist.videos.removeWhere((v) => v.videoId == videoId);
    await playlist.save();
  }

  Future<List<Playlist>> getPlaylists() async {
    final box = await _box;
    final playlists = box.values.toList();
    
    // Se asegura de que exista la playlist "Videos favoritos"
    if (!playlists.any((p) => p.name == 'Videos favoritos')) {
      await box.add(Playlist(name: 'Videos favoritos', videos: []));
      // Vuelve a cargar la lista después de la creación
      return box.values.toList();
    }
    
    return playlists;
  }
}
