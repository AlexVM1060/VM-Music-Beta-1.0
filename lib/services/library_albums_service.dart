import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

class LibraryAlbum {
  final String playlistId;
  final String title;
  final String artist;
  final String thumbnailUrl;

  const LibraryAlbum({
    required this.playlistId,
    required this.title,
    required this.artist,
    required this.thumbnailUrl,
  });

  Map<String, dynamic> toMap() => <String, dynamic>{
    'playlistId': playlistId,
    'title': title,
    'artist': artist,
    'thumbnailUrl': thumbnailUrl,
  };

  factory LibraryAlbum.fromMap(Map<dynamic, dynamic> map) {
    return LibraryAlbum(
      playlistId: (map['playlistId'] ?? '').toString(),
      title: (map['title'] ?? '').toString(),
      artist: (map['artist'] ?? '').toString(),
      thumbnailUrl: (map['thumbnailUrl'] ?? '').toString(),
    );
  }
}

class LibraryAlbumsService extends ChangeNotifier {
  static const String _boxName = 'library_albums';
  static const String _albumsKey = 'albums_v1';

  List<LibraryAlbum> _albums = const <LibraryAlbum>[];

  List<LibraryAlbum> get albums => _albums;

  Future<void> init() async {
    await _load();
  }

  Future<bool> addAlbum({
    required String playlistId,
    required String title,
    required String artist,
    required String thumbnailUrl,
  }) async {
    final normalizedId = playlistId.trim();
    if (normalizedId.isEmpty) return false;
    if (_albums.any((a) => a.playlistId == normalizedId)) return false;

    final item = LibraryAlbum(
      playlistId: normalizedId,
      title: title.trim().isEmpty ? 'Álbum' : title.trim(),
      artist: artist.trim(),
      thumbnailUrl: thumbnailUrl.trim(),
    );
    _albums = <LibraryAlbum>[item, ..._albums];
    notifyListeners();
    await _persist();
    return true;
  }

  Future<void> _load() async {
    try {
      final box = await Hive.openBox<String>(_boxName);
      final raw = box.get(_albumsKey) ?? '';
      if (raw.isEmpty) {
        _albums = const <LibraryAlbum>[];
        notifyListeners();
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        _albums = const <LibraryAlbum>[];
        notifyListeners();
        return;
      }
      _albums = decoded
          .whereType<Map>()
          .map((item) => LibraryAlbum.fromMap(item.cast<dynamic, dynamic>()))
          .where((item) => item.playlistId.trim().isNotEmpty)
          .toList(growable: false);
      notifyListeners();
    } catch (_) {
      _albums = const <LibraryAlbum>[];
      notifyListeners();
    }
  }

  Future<void> _persist() async {
    final box = await Hive.openBox<String>(_boxName);
    final payload = jsonEncode(_albums.map((a) => a.toMap()).toList());
    await box.put(_albumsKey, payload);
  }
}
