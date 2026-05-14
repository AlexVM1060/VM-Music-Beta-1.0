import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:myapp/services/profile_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SocialUser {
  final String id;
  final String name;
  final String username;
  final String? photoUrl;
  final String? frameUrl;
  final String note;
  final String currentSong;
  final String currentArtist;
  final String? currentVideoId;
  final bool isPlaying;
  final DateTime? updatedAt;

  const SocialUser({
    required this.id,
    required this.name,
    required this.username,
    required this.photoUrl,
    required this.frameUrl,
    required this.note,
    required this.currentSong,
    required this.currentArtist,
    required this.currentVideoId,
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
      frameUrl: (map['frame_url'] as String?)?.trim().isEmpty == true
          ? null
          : map['frame_url'] as String?,
      note: (map['note_profile'] ?? '').toString(),
      currentSong: (map['current_song'] ?? '').toString(),
      currentArtist: (map['current_artist'] ?? '').toString(),
      currentVideoId:
          (map['current_video_id'] as String?)?.trim().isEmpty == true
          ? null
          : map['current_video_id'] as String?,
      isPlaying: map['is_playing'] == true,
      updatedAt: DateTime.tryParse((map['updated_at'] ?? '').toString()),
    );
  }
}

class MusicNoteReactionSummary {
  final String topEmoji;
  final int count;
  final String? myEmoji;

  const MusicNoteReactionSummary({
    required this.topEmoji,
    required this.count,
    required this.myEmoji,
  });
}

class MusicNoteReactionDetail {
  final String reactorId;
  final String reactorName;
  final String reactorUsername;
  final String emoji;

  const MusicNoteReactionDetail({
    required this.reactorId,
    required this.reactorName,
    required this.reactorUsername,
    required this.emoji,
  });
}

class SocialService extends ChangeNotifier {
  bool _isReady = false;
  static const String _profilePhotosBucket = 'profile-photos';
  static const String _musicNoteReactionsTable = 'music_note_reactions';
  static const String _rpcClaimSession = 'claim_profile_session';
  static const String _rpcSyncClaimedProfile = 'sync_claimed_profile';
  String? _activeProfileId;
  String? _activeProfileSessionToken;
  String? _activeProfileUsername;
  String? _activeProfilePassword;

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

  static String buildMusicNoteSongKey({
    required String? videoId,
    required String? song,
    required String? artist,
  }) {
    final cleanVideoId = (videoId ?? '').trim();
    if (cleanVideoId.isNotEmpty) return 'yt:$cleanVideoId';
    final cleanSong = (song ?? '').trim().toLowerCase();
    final cleanArtist = (artist ?? '').trim().toLowerCase();
    if (cleanSong.isEmpty && cleanArtist.isEmpty) return '';
    return 'meta:$cleanSong|$cleanArtist';
  }

  static String buildMusicNoteReactionMapKey({
    required String targetUserId,
    required String songKey,
  }) => '${targetUserId.trim()}|${songKey.trim()}';

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
    required String? currentVideoId,
    required bool isPlaying,
    String? profilePassword,
  }) async {
    await ensureReady();
    final authUserId = myUserId;
    final targetUserId = _activeProfileId ?? authUserId;
    if (targetUserId == null) {
      throw Exception('No fue posible identificar tu sesión.');
    }

    final photoUrl = await _uploadProfilePhotoIfAvailable(
      userId: targetUserId,
      localPhotoPath: profile.photoPath,
    );

    final username = profile.username.trim().replaceFirst('@', '');
    final payload = <String, dynamic>{
      'id': targetUserId,
      'name': profile.name.trim(),
      'username': username,
      'photo_url': photoUrl,
      'frame_url': (profile.frameUrl ?? '').trim().isEmpty
          ? null
          : profile.frameUrl!.trim(),
      'note_profile': profile.bio.trim(),
      'current_song': currentSong.trim(),
      'current_artist': currentArtist.trim(),
      'current_video_id': (currentVideoId ?? '').trim().isEmpty
          ? null
          : currentVideoId!.trim(),
      'is_playing': isPlaying,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    final cleanPassword = (profilePassword ?? '').trim();
    String? rotatedSessionToken;
    if (cleanPassword.isNotEmpty) {
      payload['password'] = cleanPassword;
      final ownerId = authUserId;
      if (ownerId != null) {
        rotatedSessionToken = _newSessionToken();
        payload['active_session_token'] = rotatedSessionToken;
        payload['active_session_owner_id'] = ownerId;
      }
    }
    if (_activeProfileId != null) {
      // Para cuentas reclamadas (de otra persona), sincronizamos via RPC
      // para evitar bloqueo por RLS al actualizar rows ajenos.
      final authId = myUserId;
      if (authId != null &&
          _activeProfileId != authId &&
          _activeProfileSessionToken != null) {
        await _syncClaimedProfileViaRpc(
          profileId: targetUserId,
          sessionToken: _activeProfileSessionToken!,
          payload: payload,
        );
        if (rotatedSessionToken != null) {
          _activeProfileId = targetUserId;
          _activeProfileSessionToken = rotatedSessionToken;
        }
        return;
      }

      Map<String, dynamic>? updated;
      if (_activeProfileSessionToken != null) {
        updated = await _db
            .from('users')
            .update(payload)
            .eq('id', targetUserId)
            .eq('active_session_token', _activeProfileSessionToken!)
            .select('id')
            .maybeSingle();
      } else if ((_activeProfileUsername ?? '').isNotEmpty &&
          (_activeProfilePassword ?? '').isNotEmpty) {
        updated = await _db
            .from('users')
            .update(payload)
            .eq('id', targetUserId)
            .eq('username', _activeProfileUsername!)
            .eq('password', _activeProfilePassword!)
            .select('id')
            .maybeSingle();
      }
      if (updated == null) {
        _clearClaimedProfileSession();
        throw Exception(
          'Tu sesión de perfil fue cerrada porque la cuenta se abrió en otro dispositivo.',
        );
      }
      if (rotatedSessionToken != null) {
        _activeProfileId = targetUserId;
        _activeProfileSessionToken = rotatedSessionToken;
      }
      return;
    }
    await _db.from('users').upsert(payload);
    if (rotatedSessionToken != null) {
      _activeProfileId = targetUserId;
      _activeProfileSessionToken = rotatedSessionToken;
    }
  }

  Future<void> syncNowPlaying({
    required ProfileService profile,
    required String currentSong,
    required String currentArtist,
    required String? currentVideoId,
    required bool isPlaying,
  }) async {
    await ensureReady();
    final authUserId = myUserId;
    final targetUserId = _activeProfileId ?? authUserId;
    if (targetUserId == null) return;
    final username = profile.username.trim().replaceFirst('@', '');
    final payload = <String, dynamic>{
      'id': targetUserId,
      'name': profile.name.trim(),
      'username': username,
      'frame_url': (profile.frameUrl ?? '').trim().isEmpty
          ? null
          : profile.frameUrl!.trim(),
      'note_profile': profile.bio.trim(),
      'current_song': currentSong.trim(),
      'current_artist': currentArtist.trim(),
      'current_video_id': (currentVideoId ?? '').trim().isEmpty
          ? null
          : currentVideoId!.trim(),
      'is_playing': isPlaying,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };

    if (_activeProfileId != null) {
      final authId = myUserId;
      if (authId != null &&
          _activeProfileId != authId &&
          _activeProfileSessionToken != null) {
        await _syncClaimedProfileViaRpc(
          profileId: targetUserId,
          sessionToken: _activeProfileSessionToken!,
          payload: payload,
        );
        return;
      }

      Map<String, dynamic>? updated;
      if (_activeProfileSessionToken != null) {
        updated = await _db
            .from('users')
            .update(payload)
            .eq('id', targetUserId)
            .eq('active_session_token', _activeProfileSessionToken!)
            .select('id')
            .maybeSingle();
      } else if ((_activeProfileUsername ?? '').isNotEmpty &&
          (_activeProfilePassword ?? '').isNotEmpty) {
        updated = await _db
            .from('users')
            .update(payload)
            .eq('id', targetUserId)
            .eq('username', _activeProfileUsername!)
            .eq('password', _activeProfilePassword!)
            .select('id')
            .maybeSingle();
      }
      if (updated == null) {
        _clearClaimedProfileSession();
        throw Exception(
          'Tu sesión de perfil fue cerrada porque la cuenta se abrió en otro dispositivo.',
        );
      }
      return;
    }

    await _db.from('users').upsert(payload, onConflict: 'id');
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
    await _db.storage
        .from(_profilePhotosBucket)
        .uploadBinary(
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

  Future<SocialUser?> loginWithUsernamePassword({
    required String username,
    required String password,
  }) async {
    await ensureReady();
    final cleanUsername = username.trim().replaceFirst('@', '');
    final cleanPassword = password.trim();
    if (cleanUsername.isEmpty || cleanPassword.isEmpty) return null;

    final rows = await _db
        .from('users')
        .select()
        .eq('username', cleanUsername)
        .eq('password', cleanPassword)
        .limit(1);
    final list = (rows as List)
        .map((e) => SocialUser.fromMap(Map<String, dynamic>.from(e)))
        .toList(growable: false);
    if (list.isEmpty) return null;
    final claimed = list.first;
    final sessionToken = _newSessionToken();
    final ownerId = myUserId;
    if (ownerId == null) return null;
    try {
      final updated = await _claimProfileSessionViaRpc(
        profileId: claimed.id,
        username: cleanUsername,
        password: cleanPassword,
        sessionToken: sessionToken,
        sessionOwnerId: ownerId,
      );
      if (updated == null) return null;
      _activeProfileId = claimed.id;
      _activeProfileSessionToken = sessionToken;
      _activeProfileUsername = cleanUsername;
      _activeProfilePassword = cleanPassword;
      return SocialUser.fromMap(Map<String, dynamic>.from(updated));
    } catch (_) {
      // Fallback: permite login aunque la política RLS impida rotar token.
      // En este modo no se aplica expulsión de sesión remota.
      _activeProfileId = claimed.id;
      _activeProfileSessionToken = null;
      _activeProfileUsername = cleanUsername;
      _activeProfilePassword = cleanPassword;
      return claimed;
    }
  }

  String _newSessionToken() {
    final random = Random.secure();
    final a = random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
    final b = random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
    final c = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    return '$a$b$c';
  }

  void _clearClaimedProfileSession() {
    _activeProfileId = null;
    _activeProfileSessionToken = null;
    _activeProfileUsername = null;
    _activeProfilePassword = null;
  }

  Future<bool> verifyClaimedSessionStillActive() async {
    await ensureReady();
    if (_activeProfileId == null) return true;
    final token = (_activeProfileSessionToken ?? '').trim();
    if (token.isEmpty) return true;
    final row = await _db
        .from('users')
        .select('active_session_token')
        .eq('id', _activeProfileId!)
        .maybeSingle();
    if (row == null) {
      _clearClaimedProfileSession();
      return false;
    }
    final currentToken = (row['active_session_token'] ?? '').toString().trim();
    final active = currentToken.isNotEmpty && currentToken == token;
    if (!active) {
      _clearClaimedProfileSession();
    }
    return active;
  }

  Future<Map<String, dynamic>?> _claimProfileSessionViaRpc({
    required String profileId,
    required String username,
    required String password,
    required String sessionToken,
    required String sessionOwnerId,
  }) async {
    final result = await _db.rpc(
      _rpcClaimSession,
      params: <String, dynamic>{
        'p_profile_id': profileId,
        'p_username': username,
        'p_password': password,
        'p_session_token': sessionToken,
        'p_session_owner_id': sessionOwnerId,
      },
    );
    if (result == null) return null;
    if (result is Map<String, dynamic>) return result;
    if (result is Map) {
      return Map<String, dynamic>.from(result);
    }
    return null;
  }

  Future<void> _syncClaimedProfileViaRpc({
    required String profileId,
    required String sessionToken,
    required Map<String, dynamic> payload,
  }) async {
    final result = await _db.rpc(
      _rpcSyncClaimedProfile,
      params: <String, dynamic>{
        'p_profile_id': profileId,
        'p_session_token': sessionToken,
        'p_name': payload['name'],
        'p_username': payload['username'],
        'p_photo_url': payload['photo_url'],
        'p_frame_url': payload['frame_url'],
        'p_note_profile': payload['note_profile'],
        'p_current_song': payload['current_song'],
        'p_current_artist': payload['current_artist'],
        'p_current_video_id': payload['current_video_id'],
        'p_is_playing': payload['is_playing'],
      },
    );
    final ok = result == true || result == 1 || result == '1';
    if (!ok) {
      _clearClaimedProfileSession();
      throw Exception(
        'Tu sesión de perfil fue cerrada porque la cuenta se abrió en otro dispositivo.',
      );
    }
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

    final userRows = await _db
        .from('users')
        .select()
        .inFilter('id', followedIds);
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

  Future<void> reactToMusicNote({
    required String targetUserId,
    required String targetSongKey,
    required String emoji,
  }) async {
    await ensureReady();
    final reactorId = myUserId;
    final target = targetUserId.trim();
    final songKey = targetSongKey.trim();
    final cleanEmoji = emoji.trim();
    if (reactorId == null ||
        target.isEmpty ||
        songKey.isEmpty ||
        cleanEmoji.isEmpty) {
      return;
    }

    await _db.from(_musicNoteReactionsTable).upsert({
      'reactor_id': reactorId,
      'target_user_id': target,
      'song_key': songKey,
      'emoji': cleanEmoji,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'reactor_id,target_user_id,song_key');

    // Mejor esfuerzo: notificación push para cuando el dueño de la nota está
    // fuera de la app. Requiere una Edge Function en Supabase.
    try {
      await _db.functions.invoke(
        'send-reaction-push',
        body: <String, dynamic>{
          'reactor_id': reactorId,
          'target_user_id': target,
          'song_key': songKey,
          'emoji': cleanEmoji,
        },
      );
    } catch (_) {
      // Si la función aún no existe, no rompemos el flujo de reacción.
    }
  }

  Future<Map<String, MusicNoteReactionSummary>> getMusicNoteReactionSummaries({
    required Map<String, String> targetSongKeyByUserId,
  }) async {
    await ensureReady();
    final reactorId = myUserId;
    if (reactorId == null) return const <String, MusicNoteReactionSummary>{};
    final normalizedTargetSongKeys = <String, String>{};
    targetSongKeyByUserId.forEach((key, value) {
      final userId = key.trim();
      final songKey = value.trim();
      if (userId.isEmpty || songKey.isEmpty) return;
      normalizedTargetSongKeys[userId] = songKey;
    });
    if (normalizedTargetSongKeys.isEmpty) {
      return const <String, MusicNoteReactionSummary>{};
    }
    final targets = normalizedTargetSongKeys.keys.toList(growable: false);

    final rows = await _db
        .from(_musicNoteReactionsTable)
        .select('target_user_id, reactor_id, song_key, emoji')
        .inFilter('target_user_id', targets);
    final byTargetSong = <String, List<Map<String, dynamic>>>{};
    for (final raw in (rows as List)) {
      final row = Map<String, dynamic>.from(raw);
      final targetUserId = (row['target_user_id'] ?? '').toString().trim();
      final songKey = (row['song_key'] ?? '').toString().trim();
      if (targetUserId.isEmpty || songKey.isEmpty) continue;
      final expectedSongKey = normalizedTargetSongKeys[targetUserId];
      if (expectedSongKey == null || expectedSongKey != songKey) continue;
      final mapKey = buildMusicNoteReactionMapKey(
        targetUserId: targetUserId,
        songKey: songKey,
      );
      byTargetSong.putIfAbsent(mapKey, () => <Map<String, dynamic>>[]).add(row);
    }

    final result = <String, MusicNoteReactionSummary>{};
    for (final targetUserId in targets) {
      final songKey = normalizedTargetSongKeys[targetUserId] ?? '';
      if (songKey.isEmpty) continue;
      final mapKey = buildMusicNoteReactionMapKey(
        targetUserId: targetUserId,
        songKey: songKey,
      );
      final entries = byTargetSong[mapKey] ?? const <Map<String, dynamic>>[];
      if (entries.isEmpty) continue;
      final counter = <String, int>{};
      String? mine;
      for (final entry in entries) {
        final emoji = (entry['emoji'] ?? '').toString().trim();
        if (emoji.isEmpty) continue;
        counter[emoji] = (counter[emoji] ?? 0) + 1;
        final reactor = (entry['reactor_id'] ?? '').toString().trim();
        if (reactor == reactorId) mine = emoji;
      }
      if (counter.isEmpty) continue;
      final top = counter.entries.reduce((a, b) => a.value >= b.value ? a : b);
      result[mapKey] = MusicNoteReactionSummary(
        topEmoji: top.key,
        count: entries.length,
        myEmoji: mine,
      );
    }
    return result;
  }

  Future<List<MusicNoteReactionDetail>> getMusicNoteReactionDetails({
    required String targetUserId,
    required String targetSongKey,
  }) async {
    await ensureReady();
    final targetId = targetUserId.trim();
    final songKey = targetSongKey.trim();
    if (targetId.isEmpty || songKey.isEmpty) {
      return const <MusicNoteReactionDetail>[];
    }

    final rows = await _db
        .from(_musicNoteReactionsTable)
        .select('reactor_id, emoji, updated_at')
        .eq('target_user_id', targetId)
        .eq('song_key', songKey)
        .order('updated_at', ascending: false);

    final reactorIds = (rows as List)
        .map((e) => (e['reactor_id'] ?? '').toString().trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (reactorIds.isEmpty) return const <MusicNoteReactionDetail>[];

    final usersRows = await _db
        .from('users')
        .select('id, name, username')
        .inFilter('id', reactorIds);
    final byId = <String, Map<String, dynamic>>{};
    for (final raw in (usersRows as List)) {
      final row = Map<String, dynamic>.from(raw);
      final id = (row['id'] ?? '').toString().trim();
      if (id.isEmpty) continue;
      byId[id] = row;
    }

    final details = <MusicNoteReactionDetail>[];
    for (final raw in rows) {
      final reactorId = (raw['reactor_id'] ?? '').toString().trim();
      final emoji = (raw['emoji'] ?? '').toString().trim();
      if (reactorId.isEmpty || emoji.isEmpty) continue;
      final user = byId[reactorId];
      final name = (user?['name'] ?? '').toString().trim();
      final username = (user?['username'] ?? '').toString().trim();
      details.add(
        MusicNoteReactionDetail(
          reactorId: reactorId,
          reactorName: name,
          reactorUsername: username,
          emoji: emoji,
        ),
      );
    }
    return details;
  }
}
