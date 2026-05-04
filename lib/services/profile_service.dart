import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

class ProfileService extends ChangeNotifier {
  static const String _boxName = 'user_profile';
  static const String _nameKey = 'name';
  static const String _usernameKey = 'username';
  static const String _bioKey = 'bio';
  static const String _photoPathKey = 'photo_path';
  static const String _frameUrlKey = 'frame_url';
  static const String _followersKey = 'followers_count';
  static const String _isPublicProfileKey = 'is_public_profile';

  Box<dynamic>? _box;
  bool _isReady = false;

  String _name = 'Tu nombre';
  String _username = '@usuario';
  String _bio = 'Escribe una biografia para tu perfil.';
  String? _photoPath;
  String? _frameUrl;
  int _followersCount = 0;
  bool _isPublicProfile = false;

  bool get isReady => _isReady;
  String get name => _name;
  String get username => _username;
  String get bio => _bio;
  String? get photoPath => _photoPath;
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
    _photoPath = (rawPhoto == null || rawPhoto.isEmpty) ? null : rawPhoto;
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
      _photoPath = clean;
      await box.put(_photoPathKey, clean);
    }
    notifyListeners();
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
}
