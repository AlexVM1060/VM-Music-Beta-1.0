import 'dart:async';

import 'package:myapp/services/profile_service.dart';
import 'package:myapp/services/social_service.dart';
import 'package:myapp/video_player_manager.dart';

class SocialPresenceSyncService {
  final SocialService socialService;
  final VideoPlayerManager playerManager;
  final ProfileService profileService;

  Timer? _debounce;
  Timer? _periodic;
  DateTime? _lastSyncAt;
  String _lastSignature = '';
  bool? _lastSentIsPlaying;
  bool _disposed = false;
  bool _isSyncing = false;
  bool _pendingSync = false;
  bool _forceNextSync = false;

  SocialPresenceSyncService({
    required this.socialService,
    required this.playerManager,
    required this.profileService,
  });

  void start() {
    playerManager.addListener(_scheduleSync);
    profileService.addListener(_scheduleSync);
    _periodic = Timer.periodic(const Duration(seconds: 12), (_) {
      _scheduleSync();
    });
    _scheduleSync();
  }

  void _scheduleSync() {
    if (_disposed) return;
    if (!playerManager.isAppInForeground) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), _syncNow);
  }

  Future<void> _syncNow() async {
    if (_disposed) return;
    if (_isSyncing) {
      _pendingSync = true;
      return;
    }

    final song = (playerManager.trackTitle ?? '').trim();
    final artist = (playerManager.trackArtist ?? '').trim();
    final currentVideoId = (playerManager.currentVideoId ?? '').trim();

    // Mismo criterio visual del espectro en Inicio:
    // active: hasTrack && isPlaying
    final hasTrack = song.isNotEmpty || currentVideoId.isNotEmpty;
    final isPlayingForPresence = hasTrack && playerManager.isPlaying;
    final shouldIdleSync =
        !isPlayingForPresence &&
        song.isEmpty &&
        artist.isEmpty &&
        currentVideoId.isEmpty;

    final signature =
        '${profileService.name.trim()}|${profileService.username.trim()}|${profileService.bio.trim()}|$currentVideoId|$song|$artist';

    final now = DateTime.now();
    final recentlySynced =
        _lastSyncAt != null &&
        now.difference(_lastSyncAt!) < const Duration(seconds: 2);
    final unchangedSignature = signature == _lastSignature;
    final samePlaying = _lastSentIsPlaying == isPlayingForPresence;

    if (shouldIdleSync &&
        !_forceNextSync &&
        _lastSentIsPlaying == false &&
        unchangedSignature) {
      return;
    }

    if (!_forceNextSync &&
        recentlySynced &&
        unchangedSignature &&
        samePlaying) {
      return;
    }
    _forceNextSync = false;

    _isSyncing = true;
    try {
      await socialService
          .syncNowPlaying(
            profile: profileService,
            currentSong: song,
            currentArtist: artist,
            currentVideoId: currentVideoId,
            isPlaying: isPlayingForPresence,
          )
          .timeout(const Duration(seconds: 10));
      _lastSignature = signature;
      _lastSyncAt = now;
      _lastSentIsPlaying = isPlayingForPresence;
      // ignore: avoid_print
      print(
        '[social_sync] sent is_playing=$isPlayingForPresence hasTrack=$hasTrack player=${playerManager.isPlaying} song="$song"',
      );
    } catch (e) {
      // ignore: avoid_print
      print('[social_sync] sync error: $e');
    } finally {
      _isSyncing = false;
      if (_pendingSync && !_disposed) {
        _pendingSync = false;
        _forceNextSync = true;
        unawaited(_syncNow());
      }
    }
  }

  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _periodic?.cancel();
    playerManager.removeListener(_scheduleSync);
    profileService.removeListener(_scheduleSync);
  }
}
