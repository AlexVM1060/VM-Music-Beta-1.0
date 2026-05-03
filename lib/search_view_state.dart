import 'package:flutter/foundation.dart';

class PendingArtistProfile {
  final String channelId;
  final String channelName;
  final String channelThumbnailUrl;

  const PendingArtistProfile({
    required this.channelId,
    required this.channelName,
    required this.channelThumbnailUrl,
  });
}

class SearchViewState extends ChangeNotifier {
  bool _isArtistFullscreen = false;
  bool _isLibraryAlbumFullscreen = false;
  PendingArtistProfile? _pendingArtistProfile;

  bool get isArtistFullscreen => _isArtistFullscreen;
  bool get isLibraryAlbumFullscreen => _isLibraryAlbumFullscreen;

  void setArtistFullscreen(bool value) {
    if (_isArtistFullscreen == value) return;
    _isArtistFullscreen = value;
    notifyListeners();
  }

  void setLibraryAlbumFullscreen(bool value) {
    if (_isLibraryAlbumFullscreen == value) return;
    _isLibraryAlbumFullscreen = value;
    notifyListeners();
  }

  void requestOpenArtistProfile(PendingArtistProfile request) {
    _pendingArtistProfile = request;
    notifyListeners();
  }

  PendingArtistProfile? consumePendingArtistProfile() {
    final current = _pendingArtistProfile;
    _pendingArtistProfile = null;
    return current;
  }
}
