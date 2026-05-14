import 'dart:async';

import 'package:hive/hive.dart';
import 'package:myapp/models/playlist.dart';
import 'package:myapp/models/video_history.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class PlaylistService {
  static const String _boxName = 'playlists';
  static const String _syncMetaBoxName = 'playlist_sync_meta';
  static const String _cloudOwnerIdKey = 'cloud_owner_id';
  static const String _cloudPlaylistsTable = 'user_playlists';
  static const String _cloudPlaylistItemsTable = 'user_playlist_items';
  static const String favoritesPlaylistName = 'Favoritos';
  static const String _legacyFavoritesPlaylistName = 'Videos favoritos';
  bool _startupSyncQueued = false;

  Future<Box<Playlist>> get _box async =>
      await Hive.openBox<Playlist>(_boxName);
  Future<Box<dynamic>> get _syncMetaBox async =>
      await Hive.openBox<dynamic>(_syncMetaBoxName);

  SupabaseClient? get _db {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  void startAutoSync() {
    if (_startupSyncQueued) return;
    _startupSyncQueued = true;
    unawaited(_runStartupSync());
  }

  Future<void> _runStartupSync() async {
    try {
      await getPlaylists();
      await _syncLocalPlaylistsToCloudBestEffort();
    } catch (_) {
      // Best effort.
    }
  }

  static bool isFavoritesPlaylistName(String name) {
    final normalized = name.trim().toLowerCase();
    return normalized == favoritesPlaylistName.toLowerCase() ||
        normalized == _legacyFavoritesPlaylistName.toLowerCase();
  }

  String _normalizePlaylistName(String name) {
    if (isFavoritesPlaylistName(name)) return favoritesPlaylistName;
    return name;
  }

  String? _favoritesCoverFromVideos(List<VideoHistory> videos) {
    if (videos.isEmpty) return null;
    final thumb = videos.first.thumbnailUrl.trim();
    return thumb.isEmpty ? null : thumb;
  }

  Future<void> createPlaylist(
    String name, {
    String? coverUrl,
    String? description,
  }) async {
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
    final cleanCover = (coverUrl ?? '').trim();
    final cleanDescription = (description ?? '').trim();
    await box.add(
      Playlist(
        name: normalizedName,
        videos: [],
        coverUrl: cleanCover.isEmpty ? null : cleanCover,
        description: cleanDescription.isEmpty ? null : cleanDescription,
      ),
    );
    await _syncLocalPlaylistsToCloudBestEffort();
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
        final updatedVideos = List<VideoHistory>.from(playlist.videos)..add(video);
        final updated = Playlist(
          name: playlist.name,
          videos: updatedVideos,
          coverUrl: isFavoritesPlaylistName(playlist.name)
              ? _favoritesCoverFromVideos(updatedVideos)
              : playlist.coverUrl,
          description: playlist.description,
        );
        await box.put(playlistKey, updated);
        await _syncLocalPlaylistsToCloudBestEffort();
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

    final updatedVideos = List<VideoHistory>.from(playlist.videos);
    final existingIds = updatedVideos.map((v) => v.videoId).toSet();
    var added = 0;
    for (final video in videos) {
      if (existingIds.add(video.videoId)) {
        updatedVideos.add(video);
        added++;
      }
    }
    if (added > 0) {
      final updated = Playlist(
        name: playlist.name,
        videos: updatedVideos,
        coverUrl: isFavoritesPlaylistName(playlist.name)
            ? _favoritesCoverFromVideos(updatedVideos)
            : playlist.coverUrl,
        description: playlist.description,
      );
      await box.put(playlistKey, updated);
      await _syncLocalPlaylistsToCloudBestEffort();
    }
    return added;
  }

  Future<void> removeVideoFromPlaylist(
    String playlistName,
    String videoId,
  ) async {
    final box = await _box;
    final normalizedName = _normalizePlaylistName(playlistName);
    dynamic playlistKey;
    Playlist? playlist;
    for (final entry in box.toMap().entries) {
      if (entry.value.name == normalizedName) {
        playlistKey = entry.key;
        playlist = entry.value;
        break;
      }
    }
    if (playlist == null || playlistKey == null) return;
    final updatedVideos = List<VideoHistory>.from(playlist.videos)
      ..removeWhere((v) => v.videoId == videoId);
    final updated = Playlist(
      name: playlist.name,
      videos: updatedVideos,
      coverUrl: isFavoritesPlaylistName(playlist.name)
          ? _favoritesCoverFromVideos(updatedVideos)
          : playlist.coverUrl,
      description: playlist.description,
    );
    await box.put(playlistKey, updated);
    await _syncLocalPlaylistsToCloudBestEffort();
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
    await _syncLocalPlaylistsToCloudBestEffort();
  }

  Future<Playlist> updatePlaylistDetails({
    required String currentName,
    required String newName,
    String? coverUrl,
    String? description,
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
    final cleanDescription = (description ?? currentPlaylist.description ?? '')
        .trim();
    final updated = Playlist(
      name: normalizedNew,
      videos: List<VideoHistory>.from(currentPlaylist.videos),
      coverUrl: cleanCover.isEmpty ? null : cleanCover,
      description: cleanDescription.isEmpty ? null : cleanDescription,
    );
    await box.put(targetKey, updated);
    await _syncLocalPlaylistsToCloudBestEffort();
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

  Future<void> setCloudOwnerId(String? ownerId) async {
    final box = await _syncMetaBox;
    final clean = (ownerId ?? '').trim();
    if (clean.isEmpty) {
      await box.delete(_cloudOwnerIdKey);
      return;
    }
    await box.put(_cloudOwnerIdKey, clean);
  }

  Future<String?> _effectiveCloudOwnerId() async {
    final meta = await _syncMetaBox;
    final explicit = (meta.get(_cloudOwnerIdKey) as String?)?.trim();
    if ((explicit ?? '').isNotEmpty) return explicit;
    final db = _db;
    return db?.auth.currentUser?.id;
  }

  Future<void> replaceLocalPlaylistsFromCloud({
    required String ownerId,
  }) async {
    final db = _db;
    if (db == null) return;
    final cleanOwner = ownerId.trim();
    if (cleanOwner.isEmpty) return;

    final rows = await db
        .from(_cloudPlaylistsTable)
        .select('id, name, cover_url, description, is_favorites, updated_at')
        .eq('owner_id', cleanOwner)
        .order('updated_at', ascending: true);
    final cloudPlaylists = (rows as List)
        .map((e) => Map<String, dynamic>.from(e))
        .toList(growable: false);

    final playlistIds = cloudPlaylists
        .map((e) => (e['id'] ?? '').toString().trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    final itemsByPlaylistId = <String, List<Map<String, dynamic>>>{};
    if (playlistIds.isNotEmpty) {
      final itemRows = await db
          .from(_cloudPlaylistItemsTable)
          .select('playlist_id, position, video_id, title, artist')
          .inFilter('playlist_id', playlistIds)
          .order('position', ascending: true);
      for (final raw in (itemRows as List)) {
        final map = Map<String, dynamic>.from(raw);
        final playlistId = (map['playlist_id'] ?? '').toString().trim();
        if (playlistId.isEmpty) continue;
        itemsByPlaylistId.putIfAbsent(playlistId, () => <Map<String, dynamic>>[]);
        itemsByPlaylistId[playlistId]!.add(map);
      }
    }

    final box = await _box;
    await box.clear();
    for (final p in cloudPlaylists) {
      final playlistId = (p['id'] ?? '').toString().trim();
      final name = (p['name'] ?? '').toString().trim();
      if (name.isEmpty) continue;
      final itemRows = itemsByPlaylistId[playlistId] ?? const <Map<String, dynamic>>[];
      final videos = itemRows.map((row) {
        final videoId = (row['video_id'] ?? '').toString();
        final thumbUrl = videoId.trim().isEmpty
            ? ''
            : 'https://i.ytimg.com/vi/$videoId/maxresdefault.jpg';
        return VideoHistory(
          videoId: videoId,
          title: (row['title'] ?? '').toString(),
          thumbnailUrl: thumbUrl,
          channelTitle: (row['artist'] ?? '').toString(),
          watchedAt: DateTime.now(),
        );
      }).where((v) => v.videoId.trim().isNotEmpty).toList(growable: false);

      await box.add(
        Playlist(
          name: _normalizePlaylistName(name),
          videos: videos,
          coverUrl: (p['cover_url'] as String?)?.trim().isEmpty == true
              ? null
              : p['cover_url'] as String?,
          description: (p['description'] as String?)?.trim().isEmpty == true
              ? null
              : p['description'] as String?,
        ),
      );
    }

    await getPlaylists();
    await setCloudOwnerId(cleanOwner);
  }

  Future<void> _syncLocalPlaylistsToCloudBestEffort() async {
    final db = _db;
    if (db == null) return;
    final ownerId = await _effectiveCloudOwnerId();
    final cleanOwner = (ownerId ?? '').trim();
    if (cleanOwner.isEmpty) return;

    try {
      final box = await _box;
      final local = box.values.toList(growable: false);

      await db.from(_cloudPlaylistsTable).delete().eq('owner_id', cleanOwner);

      for (final playlist in local) {
        final inserted = await db
            .from(_cloudPlaylistsTable)
            .insert({
              'owner_id': cleanOwner,
              'name': playlist.name,
              'cover_url': (playlist.coverUrl ?? '').trim().isEmpty
                  ? null
                  : playlist.coverUrl!.trim(),
              'description': (playlist.description ?? '').trim().isEmpty
                  ? null
                  : playlist.description!.trim(),
              'is_favorites': isFavoritesPlaylistName(playlist.name),
              'updated_at': DateTime.now().toUtc().toIso8601String(),
            })
            .select('id')
            .single();
        final playlistId = (inserted['id'] ?? '').toString().trim();
        if (playlistId.isEmpty) continue;
        if (playlist.videos.isEmpty) continue;
        final itemPayload = <Map<String, dynamic>>[];
        for (var i = 0; i < playlist.videos.length; i++) {
          final video = playlist.videos[i];
          itemPayload.add({
            'playlist_id': playlistId,
            'position': i,
            'video_id': video.videoId,
            'title': video.title,
            'artist': video.channelTitle,
          });
        }
        await db.from(_cloudPlaylistItemsTable).insert(itemPayload);
      }
    } catch (_) {
      // Best effort: no bloqueamos la app por fallas de red/RLS.
    }
  }
}
