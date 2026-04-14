import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum AppleMusicAuthorizationStatus {
  notDetermined,
  denied,
  restricted,
  authorized,
}

class AppleMusicLibraryPlaylist {
  final String id;
  final String name;
  final int trackCount;

  const AppleMusicLibraryPlaylist({
    required this.id,
    required this.name,
    required this.trackCount,
  });
}

class AppleMusicLibraryTrack {
  final String title;
  final String artist;
  final String album;

  const AppleMusicLibraryTrack({
    required this.title,
    required this.artist,
    required this.album,
  });
}

class AppleMusicLibraryService {
  static const MethodChannel _channel = MethodChannel(
    'com.vm.music.beta/apple_music_migration',
  );

  bool get isSupportedPlatform =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  Future<AppleMusicAuthorizationStatus> getAuthorizationStatus() async {
    if (!isSupportedPlatform) return AppleMusicAuthorizationStatus.restricted;
    try {
      final raw = await _channel.invokeMethod<String>('getAuthorizationStatus');
      return _mapAuthorizationStatus(raw);
    } on PlatformException catch (e) {
      debugPrint('[apple_music] status error: ${e.code} ${e.message}');
      return AppleMusicAuthorizationStatus.notDetermined;
    } catch (e) {
      debugPrint('[apple_music] status error: $e');
      return AppleMusicAuthorizationStatus.notDetermined;
    }
  }

  Future<AppleMusicAuthorizationStatus> requestAuthorization() async {
    if (!isSupportedPlatform) return AppleMusicAuthorizationStatus.restricted;
    try {
      final raw = await _channel.invokeMethod<String>('requestAuthorization');
      return _mapAuthorizationStatus(raw);
    } on PlatformException catch (e) {
      debugPrint('[apple_music] request auth error: ${e.code} ${e.message}');
      return AppleMusicAuthorizationStatus.denied;
    } catch (e) {
      debugPrint('[apple_music] request auth error: $e');
      return AppleMusicAuthorizationStatus.denied;
    }
  }

  Future<List<AppleMusicLibraryPlaylist>> fetchUserPlaylists() async {
    if (!isSupportedPlatform) return const [];
    try {
      final dynamic raw = await _channel.invokeMethod('fetchUserPlaylists');
      if (raw is! List) return const [];
      final output = <AppleMusicLibraryPlaylist>[];
      for (final item in raw) {
        if (item is! Map) continue;
        final id = (item['id'] ?? '').toString().trim();
        final name = (item['name'] ?? '').toString().trim();
        if (id.isEmpty || name.isEmpty) continue;
        final trackCount = (item['trackCount'] as num?)?.toInt() ?? 0;
        output.add(
          AppleMusicLibraryPlaylist(
            id: id,
            name: name,
            trackCount: trackCount < 0 ? 0 : trackCount,
          ),
        );
      }
      return output;
    } on PlatformException catch (e) {
      debugPrint('[apple_music] fetch playlists error: ${e.code} ${e.message}');
      return const [];
    } catch (e) {
      debugPrint('[apple_music] fetch playlists error: $e');
      return const [];
    }
  }

  Future<List<AppleMusicLibraryTrack>> fetchPlaylistTracks(
    String playlistId,
  ) async {
    final id = playlistId.trim();
    if (!isSupportedPlatform || id.isEmpty) return const [];
    try {
      final dynamic raw = await _channel.invokeMethod('fetchPlaylistTracks', {
        'playlistId': id,
      });
      if (raw is! List) return const [];
      final output = <AppleMusicLibraryTrack>[];
      for (final item in raw) {
        if (item is! Map) continue;
        final title = (item['title'] ?? '').toString().trim();
        if (title.isEmpty) continue;
        final artist = (item['artist'] ?? 'Artista desconocido')
            .toString()
            .trim();
        final album = (item['album'] ?? '').toString().trim();
        output.add(
          AppleMusicLibraryTrack(
            title: title,
            artist: artist.isEmpty ? 'Artista desconocido' : artist,
            album: album,
          ),
        );
      }
      return output;
    } on PlatformException catch (e) {
      debugPrint('[apple_music] fetch tracks error: ${e.code} ${e.message}');
      return const [];
    } catch (e) {
      debugPrint('[apple_music] fetch tracks error: $e');
      return const [];
    }
  }

  AppleMusicAuthorizationStatus _mapAuthorizationStatus(String? raw) {
    switch ((raw ?? '').trim()) {
      case 'authorized':
        return AppleMusicAuthorizationStatus.authorized;
      case 'denied':
        return AppleMusicAuthorizationStatus.denied;
      case 'restricted':
        return AppleMusicAuthorizationStatus.restricted;
      case 'notDetermined':
      default:
        return AppleMusicAuthorizationStatus.notDetermined;
    }
  }
}
