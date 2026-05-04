import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:myapp/services/profile_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SocialUser {
  final String id;
  final String name;
  final String username;
  final String? photoUrl;
  final String note;
  final String currentSong;
  final String currentArtist;
  final bool isPlaying;
  final DateTime? updatedAt;

  const SocialUser({
    required this.id,
    required this.name,
    required this.username,
    required this.photoUrl,
    required this.note,
    required this.currentSong,
    required this.currentArtist,
    required this.isPlaying,
    required this.updatedAt,
  });

  factory SocialUser.fromMap(Map<String, dynamic> map) {
    return SocialUser(
      id: (map['id'] ?? '').toString(),
      name: (map['name'] ?? '').toString(),
      username: (map['username'] ?? '').toString(),
      photoUrl: (map['photo_url'] as String?)?.trim().isEmpty == true
          ? null
          : map['photo_url'] as String?,
      note: (map['note_profile'] ?? '').toString(),
      currentSong: (map['current_song'] ?? '').toString(),
      currentArtist: (map['current_artist'] ?? '').toString(),
      isPlaying: map['is_playing'] == true,
      updatedAt: DateTime.tryParse((map['updated_at'] ?? '').toString()),
    );
  }
}

class SocialService extends ChangeNotifier {
  bool _isReady = false;
  static const String _profilePhotosBucket = 'profile-photos';

  bool get isReady => _isReady;
  SupabaseClient get _db {
    try {
      return Supabase.instance.client;
    } catch (_) {
      throw Exception(
        'Supabase no está configurado. Inicia la app con --dart-define=SUPABASE_URL=... y --dart-define=SUPABASE_ANON_KEY=...',
      );
    }
  }
  String? get myUserId => _db.auth.currentUser?.id;

  Future<void> ensureReady() async {
    if (_isReady) return;
    if (_db.auth.currentUser == null) {
      await _db.auth.signInAnonymously();
    }
    _isReady = true;
  }

  Future<void> publishProfile({
    required ProfileService profile,
    required String currentSong,
    required String currentArtist,
    required bool isPlaying,
  }) async {
    await ensureReady();
    final userId = myUserId;
    if (userId == null) {
      throw Exception('No fue posible identificar tu sesión.');
    }

    final photoUrl = await _uploadProfilePhotoIfAvailable(
      userId: userId,
      localPhotoPath: profile.photoPath,
    );

    final username = profile.username.trim().replaceFirst('@', '');
    await _db.from('users').upsert({
      'id': userId,
      'name': profile.name.trim(),
      'username': username,
      'photo_url': photoUrl,
      'note_profile': profile.bio.trim(),
      'current_song': currentSong.trim(),
      'current_artist': currentArtist.trim(),
      'is_playing': isPlaying,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<void> syncNowPlaying({
    required ProfileService profile,
    required String currentSong,
    required String currentArtist,
    required bool isPlaying,
  }) async {
    await ensureReady();
    final userId = myUserId;
    if (userId == null) return;
    final username = profile.username.trim().replaceFirst('@', '');

    await _db.from('users').upsert(
      {
        'id': userId,
        'name': profile.name.trim(),
        'username': username,
        'note_profile': profile.bio.trim(),
        'current_song': currentSong.trim(),
        'current_artist': currentArtist.trim(),
        'is_playing': isPlaying,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      onConflict: 'id',
    );
  }

  Future<String?> _uploadProfilePhotoIfAvailable({
    required String userId,
    required String? localPhotoPath,
  }) async {
    final path = (localPhotoPath ?? '').trim();
    if (path.isEmpty) return null;
    final file = File(path);
    if (!await file.exists()) return null;

    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return null;

    final storagePath =
        '$userId/avatar_${DateTime.now().millisecondsSinceEpoch}.jpg';
    await _db.storage.from(_profilePhotosBucket).uploadBinary(
          storagePath,
          bytes,
          fileOptions: const FileOptions(
            upsert: true,
            contentType: 'image/jpeg',
          ),
        );
    return _db.storage.from(_profilePhotosBucket).getPublicUrl(storagePath);
  }

  Future<List<SocialUser>> searchUsersByUsername(String query) async {
    await ensureReady();
    final clean = query.trim().replaceFirst('@', '');
    if (clean.isEmpty) return const <SocialUser>[];

    final rows = await _db
        .from('users')
        .select()
        .ilike('username', '%$clean%')
        .order('updated_at', ascending: false)
        .limit(20);

    return (rows as List)
        .map((e) => SocialUser.fromMap(Map<String, dynamic>.from(e)))
        .where((u) => u.id != myUserId)
        .toList();
  }

  Future<void> followUser(String followedId) async {
    await ensureReady();
    final userId = myUserId;
    if (userId == null || followedId.trim().isEmpty) return;

    await _db.from('follows').upsert({
      'follower_id': userId,
      'followed_id': followedId.trim(),
    });
  }

  Future<void> unfollowUser(String followedId) async {
    await ensureReady();
    final userId = myUserId;
    if (userId == null || followedId.trim().isEmpty) return;

    await _db
        .from('follows')
        .delete()
        .eq('follower_id', userId)
        .eq('followed_id', followedId.trim());
  }

  Future<List<SocialUser>> getFollowingUsers() async {
    await ensureReady();
    final userId = myUserId;
    if (userId == null) return const <SocialUser>[];

    final followRows = await _db
        .from('follows')
        .select('followed_id, created_at')
        .eq('follower_id', userId)
        .order('created_at', ascending: false);

    final followedIds = (followRows as List)
        .map((e) => (e['followed_id'] ?? '').toString().trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    if (followedIds.isEmpty) return const <SocialUser>[];

    final userRows =
        await _db.from('users').select().inFilter('id', followedIds);
    final byId = <String, SocialUser>{};
    for (final row in (userRows as List)) {
      final user = SocialUser.fromMap(Map<String, dynamic>.from(row));
      byId[user.id] = user;
    }

    final ordered = <SocialUser>[];
    for (final id in followedIds) {
      final user = byId[id];
      if (user != null) ordered.add(user);
    }
    return ordered;
  }

  Future<Set<String>> getFollowingIds() async {
    await ensureReady();
    final userId = myUserId;
    if (userId == null) return <String>{};
    final rows = await _db
        .from('follows')
        .select('followed_id')
        .eq('follower_id', userId);
    return (rows as List)
        .map((e) => (e['followed_id'] ?? '').toString())
        .where((id) => id.isNotEmpty)
        .toSet();
  }
}
