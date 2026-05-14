import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class ProfileService extends ChangeNotifier {
  static const String _boxName = 'user_profile';
  static const String _nameKey = 'name';
  static const String _usernameKey = 'username';
  static const String _bioKey = 'bio';
  static const String _photoPathKey = 'photo_path';
  static const String _photoUrlKey = 'photo_url';
  static const String _frameUrlKey = 'frame_url';
  static const String _followersKey = 'followers_count';
  static const String _isPublicProfileKey = 'is_public_profile';

  Box<dynamic>? _box;
  bool _isReady = false;

  String _name = 'Tu nombre';
  String _username = '@usuario';
  String _bio = 'Escribe una biografia para tu perfil.';
  String? _photoPath;
  String? _photoUrl;
  String? _frameUrl;
  int _followersCount = 0;
  bool _isPublicProfile = false;

  bool get isReady => _isReady;
  String get name => _name;
  String get username => _username;
  String get bio => _bio;
  String? get photoPath => _photoPath;
  String? get photoUrl => _photoUrl;
  String? get frameUrl => _frameUrl;
  int get followersCount => _followersCount;
  bool get isPublicProfile => _isPublicProfile;

  Future<void> init() async {
    if (_isReady) return;
    _box = await Hive.openBox(_boxName);
    _name = (_box!.get(_nameKey) as String?)?.trim().isNotEmpty == true
        ? (_box!.get(_nameKey) as String).trim()
        : _name;
    _username = (_box!.get(_usernameKey) as String?)?.trim().isNotEmpty == true
        ? (_box!.get(_usernameKey) as String).trim()
        : _username;
    _bio = (_box!.get(_bioKey) as String?)?.trim().isNotEmpty == true
        ? (_box!.get(_bioKey) as String).trim()
        : _bio;
    final rawPhoto = (_box!.get(_photoPathKey) as String?)?.trim();
    _photoPath = await _resolveStoredPhotoPath(rawPhoto);
    final remotePhoto = (_box!.get(_photoUrlKey) as String?)?.trim();
    _photoUrl = (remotePhoto == null || remotePhoto.isEmpty)
        ? null
        : remotePhoto;
    if ((_photoPath ?? '').isNotEmpty) {
      final canonicalToken = await _toStoredPhotoToken(_photoPath);
      if (canonicalToken != null && canonicalToken != rawPhoto) {
        await _box!.put(_photoPathKey, canonicalToken);
      }
    } else if ((rawPhoto ?? '').isNotEmpty) {
      await _box!.delete(_photoPathKey);
    }
    final rawFrame = (_box!.get(_frameUrlKey) as String?)?.trim();
    _frameUrl = (rawFrame == null || rawFrame.isEmpty) ? null : rawFrame;
    _followersCount = (_box!.get(_followersKey) as int?) ?? 0;
    _isPublicProfile = (_box!.get(_isPublicProfileKey) as bool?) ?? false;
    _isReady = true;
    notifyListeners();
  }

  Future<void> updateProfile({
    required String name,
    required String username,
    required String bio,
  }) async {
    final box = _box;
    if (box == null) return;

    final cleanName = name.trim();
    final cleanUsername = username.trim();
    final cleanBio = bio.trim();

    _name = cleanName.isEmpty ? _name : cleanName;
    _username = cleanUsername.isEmpty
        ? _username
        : (cleanUsername.startsWith('@') ? cleanUsername : '@$cleanUsername');
    _bio = cleanBio.isEmpty
        ? 'Escribe una biografia para tu perfil.'
        : cleanBio;

    await box.put(_nameKey, _name);
    await box.put(_usernameKey, _username);
    await box.put(_bioKey, _bio);
    notifyListeners();
  }

  Future<void> updatePhotoPath(String? path) async {
    final box = _box;
    if (box == null) return;

    final clean = path?.trim();
    if (clean == null || clean.isEmpty) {
      _photoPath = null;
      await box.delete(_photoPathKey);
    } else {
      _photoPath = await _resolveStoredPhotoPath(clean);
      final token = await _toStoredPhotoToken(clean);
      await box.put(_photoPathKey, token ?? clean);
      _photoUrl = null;
      await box.delete(_photoUrlKey);
    }
    notifyListeners();
  }

  Future<void> applyRemoteProfile({
    required String name,
    required String username,
    required String bio,
    required String? photoUrl,
    required String? frameUrl,
  }) async {
    final box = _box;
    if (box == null) return;

    final cleanName = name.trim();
    final cleanUsername = username.trim();
    final cleanBio = bio.trim();
    final cleanPhotoUrl = (photoUrl ?? '').trim();
    final cleanFrameUrl = (frameUrl ?? '').trim();

    _name = cleanName.isEmpty ? _name : cleanName;
    _username = cleanUsername.isEmpty
        ? _username
        : (cleanUsername.startsWith('@') ? cleanUsername : '@$cleanUsername');
    _bio = cleanBio.isEmpty ? 'Escribe una biografia para tu perfil.' : cleanBio;
    _frameUrl = cleanFrameUrl.isEmpty ? null : cleanFrameUrl;
    _photoPath = null;
    _photoUrl = cleanPhotoUrl.isEmpty ? null : cleanPhotoUrl;

    await box.put(_nameKey, _name);
    await box.put(_usernameKey, _username);
    await box.put(_bioKey, _bio);
    await box.delete(_photoPathKey);
    if (_photoUrl == null) {
      await box.delete(_photoUrlKey);
    } else {
      await box.put(_photoUrlKey, _photoUrl);
    }
    if (_frameUrl == null) {
      await box.delete(_frameUrlKey);
    } else {
      await box.put(_frameUrlKey, _frameUrl);
    }

    notifyListeners();
  }

  Future<String?> _resolveStoredPhotoPath(String? raw) async {
    final token = (raw ?? '').trim();
    if (token.isEmpty) return null;
    final docs = await getApplicationDocumentsDirectory();
    final docsPath = docs.path;

    String candidate;
    if (token.startsWith('rel:')) {
      final rel = token.substring(4).trim();
      if (rel.isEmpty) return null;
      candidate = p.normalize(p.join(docsPath, rel));
    } else {
      candidate = token;
    }

    final directFile = File(candidate);
    if (await directFile.exists()) return candidate;

    // Migración de rutas absolutas antiguas: intentar por basename en Documents actual.
    final base = p.basename(token);
    if (base.isEmpty || base == token) return null;
    final migrated = p.join(docsPath, base);
    final migratedFile = File(migrated);
    if (await migratedFile.exists()) return migrated;
    return null;
  }

  Future<String?> _toStoredPhotoToken(String? absoluteOrTokenPath) async {
    final clean = (absoluteOrTokenPath ?? '').trim();
    if (clean.isEmpty) return null;
    if (clean.startsWith('rel:')) return clean;

    final docs = await getApplicationDocumentsDirectory();
    final docsPath = p.normalize(docs.path);
    final normalized = p.normalize(clean);
    if (p.isWithin(docsPath, normalized)) {
      final rel = p.relative(normalized, from: docsPath).trim();
      if (rel.isNotEmpty) return 'rel:$rel';
    }
    return clean;
  }

  Future<void> updateFrameUrl(String? url) async {
    final box = _box;
    if (box == null) return;

    final clean = url?.trim();
    if (clean == null || clean.isEmpty) {
      _frameUrl = null;
      await box.delete(_frameUrlKey);
    } else {
      _frameUrl = clean;
      await box.put(_frameUrlKey, clean);
    }
    notifyListeners();
  }

  Future<void> setPublicProfileEnabled(bool enabled) async {
    final box = _box;
    if (box == null) return;
    _isPublicProfile = enabled;
    await box.put(_isPublicProfileKey, enabled);
    notifyListeners();
  }

  Future<void> resetToDefaults() async {
    final box = _box;
    if (box == null) return;
    _name = 'Tu nombre';
    _username = '@usuario';
    _bio = 'Escribe una biografia para tu perfil.';
    _photoPath = null;
    _photoUrl = null;
    _frameUrl = null;
    _followersCount = 0;
    _isPublicProfile = false;
    await box.delete(_nameKey);
    await box.delete(_usernameKey);
    await box.delete(_bioKey);
    await box.delete(_photoPathKey);
    await box.delete(_photoUrlKey);
    await box.delete(_frameUrlKey);
    await box.delete(_followersKey);
    await box.delete(_isPublicProfileKey);
    notifyListeners();
  }
}
