import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hive/hive.dart';
import 'package:just_audio/just_audio.dart';
import 'package:myapp/audio_handler.dart';
import 'package:myapp/models/downloaded_video.dart';
import 'package:myapp/models/playlist.dart' as app_models;
import 'package:myapp/models/video_history.dart';
import 'package:myapp/services/ai_stems_service.dart';
import 'package:myapp/services/app_settings_service.dart';
import 'package:myapp/services/history_service.dart';
import 'package:myapp/services/lyrics_service.dart';
import 'package:myapp/services/now_playing_artwork_service.dart';
import 'package:myapp/services/song_stream_cache_service.dart';
import 'package:myapp/utils/artist_name_utils.dart';
import 'package:myapp/services/playlist_service.dart';
import 'package:myapp/services/thumbnail_cache_service.dart';
import 'package:myapp/utils/thumbnail_quality.dart';
import 'package:video_player/video_player.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class PlaybackQueueItem {
  final String videoId;
  final String title;
  final String thumbnailUrl;
  final String artist;
  final bool isLocal;
  final String? localFilePath;
  final String? localPlainLyrics;
  final String? localSyncedLyrics;

  const PlaybackQueueItem({
    required this.videoId,
    required this.title,
    required this.thumbnailUrl,
    required this.artist,
    required this.isLocal,
    this.localFilePath,
    this.localPlainLyrics,
    this.localSyncedLyrics,
  });
}

enum LocalPlaybackQueueStrategy { downloads, recommendations }

enum ManualQueueInsertMode { next, end }

class DownloadSourceInfo {
  final String sourceUrl;
  final bool isVideoSource;

  const DownloadSourceInfo({
    required this.sourceUrl,
    required this.isVideoSource,
  });
}

class _RecommendationSignals {
  final List<String> currentTitleTokens;
  final List<String> currentArtistTokens;
  final List<String> relatedTitleTokens;
  final List<String> coListenArtists;
  final List<String> genreHints;
  final List<String> genreTokens;

  const _RecommendationSignals({
    required this.currentTitleTokens,
    required this.currentArtistTokens,
    required this.relatedTitleTokens,
    required this.coListenArtists,
    required this.genreHints,
    required this.genreTokens,
  });
}

class _SearchVideosCacheEntry {
  final DateTime createdAt;
  final List<Video> videos;

  const _SearchVideosCacheEntry({
    required this.createdAt,
    required this.videos,
  });
}

class _YouTubeMusicQueueCandidate {
  final String videoId;
  final String title;
  final String artist;
  final String thumbnailUrl;
  final bool isExplicit;

  const _YouTubeMusicQueueCandidate({
    required this.videoId,
    required this.title,
    required this.artist,
    required this.thumbnailUrl,
    required this.isExplicit,
  });
}

class _CookieAwareYoutubeHttpClient extends YoutubeHttpClient {
  final String? cookieHeader;

  _CookieAwareYoutubeHttpClient({this.cookieHeader});

  @override
  Map<String, String> get headers {
    final merged = <String, String>{...YoutubeHttpClient.defaultHeaders};
    final cookie = (cookieHeader ?? '').trim();
    if (cookie.isNotEmpty) {
      merged['cookie'] = cookie;
    }
    return merged;
  }
}

class _DjTransitionPlan {
  final Duration preferredMixDuration;
  final Duration preferredTriggerLeadTime;
  final Duration? preferredIncomingStartOffset;
  final double? preferredOutgoingSpeed;
  final double? preferredIncomingSpeed;
  final double incomingCurvePower;
  final double outgoingCurvePower;

  const _DjTransitionPlan({
    required this.preferredMixDuration,
    required this.preferredTriggerLeadTime,
    required this.preferredIncomingStartOffset,
    required this.preferredOutgoingSpeed,
    required this.preferredIncomingSpeed,
    required this.incomingCurvePower,
    required this.outgoingCurvePower,
  });
}

// Mantiene el nombre para no romper imports, pero ahora gestiona audio estilo app musical.
class VideoPlayerManager extends ChangeNotifier with WidgetsBindingObserver {
  static const String _playerSessionBoxName = 'player_session';
  static const String _lastTrackSessionKey = 'last_track_session_v1';
  static const String _relatedQueueSessionKey = 'related_queue_session_v1';
  static const MethodChannel _iosAudioEffectsChannel = MethodChannel(
    'com.vm.music.beta/ios_bass_boost',
  );
  static const MethodChannel _iosLockScreenFavoriteChannel = MethodChannel(
    'com.vm.music.beta/ios_lock_screen_favorite',
  );
  static const MethodChannel _songShareChannel = MethodChannel(
    'com.vm.music.beta/song_share',
  );
  static const MethodChannel _iosSiriChannel = MethodChannel(
    'com.vm.music.beta/siri',
  );
  static const MethodChannel _iosPowerModeChannel = MethodChannel(
    'com.vm.music.beta/power_mode',
  );
  final HistoryService _historyService = HistoryService();
  final PlaylistService _playlistService = PlaylistService();
  final AudioHandler _audioHandler;
  final AppSettingsService _settingsService;
  late AudioPlayer _player;
  late AudioPlayer _crossfadePlayer;
  AndroidLoudnessEnhancer? _androidAudioEnhancer;
  AndroidEqualizer? _androidAudioEqualizer;
  bool _audioEffectsConfigured = false;
  late YoutubeExplode _ytExplode;
  final LyricsService _lyricsService = LyricsService();
  VideoPlayerController? _hiddenVideoController;

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _bufferedSub;
  StreamSubscription<Duration?>? _durationSub;
  StreamSubscription<PlayerState>? _playerStateSub;

  String? _currentVideoId;
  bool _isMinimized = false;
  bool _isFullScreen = false;
  bool _appInForeground = true;
  bool _isLowPowerModeEnabled = false;

  String? _trackTitle;
  String? _trackThumbnailUrl;
  String? _trackArtist;
  Duration _trackDuration = Duration.zero;
  bool _isLocal = false;
  bool _isLoading = false;
  String? _errorMessage;

  Duration _position = Duration.zero;
  Duration _bufferedPosition = Duration.zero;
  bool _isPlaying = false;
  bool _isBuffering = false;
  bool _usingHiddenVideo = false;
  bool _preferForegroundVideoPlayback = false;
  bool _autoplayEnabled = true;
  bool _karaokeModeEnabled = false;
  bool _isAiStemsLoading = false;
  bool _usingAiInstrumental = false;
  String? _karaokeOriginalStreamUrl;
  bool _isLyricsLayout = false;
  bool _isLyricsLoading = false;
  String? _lyricsText;
  String? _lyricsError;
  List<SyncedLyricLine> _syncedLyrics = const [];
  bool _isAdvancingQueue = false;
  bool _completionHandledForCurrent = false;
  bool _skipHistoryPushOnce = false;
  bool _isResettingEngines = false;
  Completer<void>? _resetEnginesCompleter;
  bool _isSwitchingEngine = false;
  bool _isTogglingPlayPause = false;
  String? _currentStreamUrl;
  List<PlaybackQueueItem> _manualPlaybackQueue = const [];
  List<PlaybackQueueItem> _playbackQueue = const [];
  bool _isQueueLoading = false;
  String _queueTitle = 'Siguiente';
  String? _queueSeedVideoId;
  int _queueEpoch = 0;
  final List<PlaybackQueueItem> _playbackHistory = [];
  final Set<String> _sessionPlayedVideoIds = <String>{};
  final Set<String> _recentRecommendedVideoIds = <String>{};
  final List<String> _recentRecommendedOrder = <String>[];
  final Map<String, StreamManifest> _manifestCache = {};
  final Map<String, Video> _videoCache = {};
  final Map<String, Future<StreamManifest>> _manifestRequests = {};
  final Map<String, Future<Video>> _videoRequests = {};
  final Map<String, List<PlaybackQueueItem>> _relatedQueueCache = {};
  final Map<String, Future<List<PlaybackQueueItem>>> _relatedQueueRequests = {};
  final Map<String, String> _lyricsCache = {};
  final Map<String, List<SyncedLyricLine>> _syncedLyricsCache = {};
  final Map<String, String> _aiInstrumentalCache = {};
  final Map<String, Duration?> _djFirstLyricOffsetCache = {};
  final Map<String, Future<Duration?>> _djFirstLyricOffsetRequests = {};
  final Map<String, _DjTransitionPlan> _djTransitionPlanCache = {};
  final Map<String, String> _searchThumbnailOverrides = {};
  final Map<String, _SearchVideosCacheEntry> _searchVideosCache = {};
  final Map<String, Future<List<Video>>> _searchVideosRequests = {};
  final NowPlayingArtworkService _nowPlayingArtworkService =
      NowPlayingArtworkService();
  final AiStemsService _aiStemsService = AiStemsService();
  final Map<String, Uri> _systemArtworkByVideoId = {};
  final Map<String, String> _systemArtworkSourceByVideoId = {};
  String? _lastNowPlayingArtVideoId;
  Uri? _lastNowPlayingArtUri;
  final MyAudioHandler? _appAudioHandler;
  DateTime _lastSystemPlaybackSync = DateTime.fromMillisecondsSinceEpoch(0);
  int _nowPlayingArtworkEpoch = 0;
  DateTime _lastPlaybackUiNotifyAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastPlaybackOpsTickAt = DateTime.fromMillisecondsSinceEpoch(0);
  Duration _lastNotifiedPosition = Duration.zero;
  Duration _lastNotifiedBufferedPosition = Duration.zero;
  bool _lastNotifiedPlaying = false;
  bool _lastNotifiedBuffering = false;
  int _volumeFadeEpoch = 0;
  bool _crossfadeTriggeredForCurrent = false;
  bool _isCrossfadeTransitioning = false;
  bool _isPreloadingNextTrack = false;
  String? _preloadedForCurrentVideoId;
  String? _preloadedNextQueueKey;
  String? _preloadedNextStreamUrl;
  String? _crossfadePreparedQueueKey;
  bool _crossfadePreparedPrimed = false;
  String? _crossfadeFailedForCurrentVideoId;
  String? _crossfadeFailedQueueKey;
  DateTime? _lastYoutubeRequestAt;
  DateTime? _youtubeSlowModeUntil;
  int _lyricsEpoch = 0;
  bool _iosLockScreenFavoriteBound = false;
  bool _songShareBound = false;
  bool _siriChannelBound = false;
  Timer? _backgroundEngineSwitchTimer;
  Timer? _resumeSharedSongTimer;
  Timer? _resumeSiriPlayTimer;
  bool _isConsumingPendingSharedSong = false;
  bool _isConsumingPendingSiriPlay = false;
  DateTime _lastPendingSharedSongConsumeAt =
      DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastPendingSiriPlayConsumeAt = DateTime.fromMillisecondsSinceEpoch(
    0,
  );
  Box? _playerSessionBox;
  bool _didAttemptSessionRestore = false;
  int _sessionRestoreEpoch = 0;
  DateTime _lastSessionPersistAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _lastSessionPersistedPositionMs = -1;
  static const Duration _youtubeMinRequestGap = Duration(milliseconds: 450);
  static const Duration _youtubeSlowRequestGap = Duration(milliseconds: 1650);
  static const Duration _youtubeRateLimitCooldown = Duration(seconds: 40);
  static const Duration _sessionRestoredStreamTtl = Duration(minutes: 45);
  static const Duration _relatedQueueSessionTtl = Duration(minutes: 45);
  static const int _autoplayQueueRefillThreshold = 4;
  static const Duration _playbackUiNotifyMinIntervalNormal = Duration(
    milliseconds: 620,
  );
  static const Duration _playbackUiNotifyMinIntervalLowPower = Duration(
    milliseconds: 750,
  );
  static const Duration _playbackUiNotifyMinPositionDeltaNormal = Duration(
    milliseconds: 520,
  );
  static const Duration _playbackUiNotifyMinPositionDeltaLowPower = Duration(
    milliseconds: 650,
  );
  static const Duration _playbackUiNotifyMinBufferedDelta = Duration(
    milliseconds: 950,
  );
  static const Duration _playbackOpsTickIntervalNormal = Duration(
    milliseconds: 820,
  );
  static const Duration _playbackOpsTickIntervalLowPower = Duration(
    milliseconds: 1000,
  );
  static const bool _forceLowPowerProfileInNormal = true;
  static const Duration _searchVideosCacheTtl = Duration(minutes: 12);
  static const int _searchVideosCacheMaxEntries = 220;
  static const double _defaultPlaybackVolume = 3;
  static const double _karaokeVolumeBoostMultiplier = 2.0;
  static const Duration _crossfadeDuration = Duration(seconds: 4);
  static const Duration _djMinMixDuration = Duration(seconds: 6);
  static const Duration _djMaxMixDuration = Duration(seconds: 12);
  static const Duration _crossfadeTriggerLeadTime = Duration(seconds: 7);
  static const Duration _crossfadePreloadLeadTime = Duration(seconds: 26);
  static const Duration _crossfadeAudibleStartTimeout = Duration(
    milliseconds: 1400,
  );
  static const Duration _crossfadeAudibleMinAdvance = Duration(
    milliseconds: 100,
  );
  static const String _youtubeiPlayerEndpoint =
      'https://www.youtube.com/youtubei/v1/player?key=AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8';
  static const String _youtubeiMusicNextEndpoint =
      'https://music.youtube.com/youtubei/v1/next?key=AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8';
  static const Map<String, String> _youtubeBaseHeaders = {
    'User-Agent':
        'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
    'Accept': '*/*',
    'Origin': 'https://www.youtube.com',
    'Referer': 'https://www.youtube.com/',
  };
  final String? _youtubeCookieHeader = _normalizeYoutubeCookie(
    'SIDCC=AKEyXzVLOVY7QzgJ1MHgnhr3VE4VOC14spiVDL6YlgyHu2PMrmKN1ESpl4kPtMLSOkz8vxutsw; __Secure-1PSIDCC=AKEyXzVaf3-L2UfWESYnHWnB42cHusbCa2_5_MPZ28ELoZEdsAqoISaX0k-Tgi-WX-xBt6vrfQ; __Secure-3PSIDCC=AKEyXzUCJA-zjanFMW0DEdZfJ-b5auglPQ0CMko3TTFJbHTfuvcxyYAoEYVT1GKiBefyQ3OJf14; VISITOR_INFO1_LIVE=K9gqegkdBV0; VISITOR_PRIVACY_METADATA=CgJNWBIEGgAgIQ%3D%3D; PREF=f4=4010000&f6=40000000&tz=America.Mexico_City&f7=100&repeat=NONE; ST-1tk58rr=itct=CJUCENE5IhMIiqjp2sz9kwMVGnXCAR123wIZMgdiZl9uZXh0SIubw6em3Mjt5QGaAQUIERD4HcoBBJLI5Yc%3D&csn=O12rkX_62jWXNr0b&session_logininfo=AFmmF2swRgIhANQ02E54188kKG16WB62lOXcUmOiVyNq70bMQM0ypvPCAiEAxPZdXDMrrh-kfxUx1quNeaWKzoTkoPAGzeA3BPIeLwI%3AQUQ3MjNmeWVtbk83THFtTi1YRjFTMWxCXzI5cHBwQkJDSk85X0t2WER6NFN6MXRZV19YZVpwMlJxSWIxNUk3d2ZzZmFWeXlzT0hxZlpqNGUwZ2Q5VFY1TTBBa3VQOXhLRG1tYUN0eGV3dU80dVlNdzVESFd6WDFVakJIR3NpNGZJeG5ZQWFiUWF0WVVNSVhGTGp6amhJNTdiUm1pZXM3cm5n&endpoint=%7B%22clickTrackingParams%22%3A%22CJUCENE5IhMIiqjp2sz9kwMVGnXCAR123wIZMgdiZl9uZXh0SIubw6em3Mjt5QGaAQUIERD4HcoBBJLI5Yc%3D%22%2C%22commandMetadata%22%3A%7B%22webCommandMetadata%22%3A%7B%22url%22%3A%22%2Fwatch%3Fv%3DsI2TE_hYFYQ%26list%3DRD5dsi4mTwzYs%26index%3D2%26pp%3D0gcJCagCnhUGBSbi%22%2C%22webPageType%22%3A%22WEB_PAGE_TYPE_WATCH%22%2C%22rootVe%22%3A3832%7D%7D%2C%22watchEndpoint%22%3A%7B%22videoId%22%3A%22sI2TE_hYFYQ%22%2C%22playlistId%22%3A%22RD5dsi4mTwzYs%22%2C%22index%22%3A1%2C%22params%22%3A%22EAIYATgBYgs1ZHNpNG1Ud3pZc2gAuAUB%22%2C%22playerParams%22%3A%220gcJCagCnhUGBSbi%22%2C%22loggingContext%22%3A%7B%22vssLoggingContext%22%3A%7B%22serializedContextData%22%3A%22Gg1SRDVkc2k0bVR3ellz%22%7D%7D%2C%22watchEndpointSupportedOnesieConfig%22%3A%7B%22html5PlaybackOnesieConfig%22%3A%7B%22commonConfig%22%3A%7B%22url%22%3A%22https%3A%2F%2Frr1---sn-hxb5j5cax-8xgd.googlevideo.com%2Finitplayback%3Fsource%3Dyoutube%26oeis%3D1%26c%3DWEB%26oad%3D3200%26ovd%3D3200%26oaad%3D11000%26oavd%3D11000%26ocs%3D700%26oewis%3D1%26oputc%3D1%26ofpcc%3D1%26siu%3D1%26msp%3D1%26odepv%3D1%26id%3Db08d9313f8581584%26ip%3D2806%253A268%253A7403%253A88b6%253Aad62%253A1788%253A58bf%253A2e67%26initcwndbps%3D2396250%26mt%3D1776727743%26oweuc%3D%26pxtags%3DCg4KAnR4Egg1MTgyODk2MA%26rxtags%3DCg4KAnR4Egg1MTgyODk1OQ%252CCg4KAnR4Egg1MTgyODk2MA%252CCg4KAnR4Egg1MTgyODk2MQ%22%7D%7D%7D%7D%7D; APISID=0Ue7Wnl7JlbIKZD8/Akfw1aCmFcAwvCpMl; HSID=AYBu10DLSap_MUpIV; LOGIN_INFO=AFmmF2swRgIhANQ02E54188kKG16WB62lOXcUmOiVyNq70bMQM0ypvPCAiEAxPZdXDMrrh-kfxUx1quNeaWKzoTkoPAGzeA3BPIeLwI:QUQ3MjNmeWVtbk83THFtTi1YRjFTMWxCXzI5cHBwQkJDSk85X0t2WER6NFN6MXRZV19YZVpwMlJxSWIxNUk3d2ZzZmFWeXlzT0hxZlpqNGUwZ2Q5VFY1TTBBa3VQOXhLRG1tYUN0eGV3dU80dVlNdzVESFd6WDFVakJIR3NpNGZJeG5ZQWFiUWF0WVVNSVhGTGp6amhJNTdiUm1pZXM3cm5n; SAPISID=ro4mJ0xKO0Q-Be3Q/AGjxKEu1AKwNvt9U2; SID=g.a0009AiszrmMkxnOzGHN3-AgUVa8_rarWA45h6lZ1JT1PjYStBGDr5zbk4Uuud6emERx9ngw0QACgYKAc8SARESFQHGX2MieKs2Vc5yGpH4ZX6zwaDrWBoVAUF8yKpHw8Z2bkkYGODnKJ9NXqQa0076; SSID=AaGYi4Pdw-BOOpKid; __Secure-1PAPISID=ro4mJ0xKO0Q-Be3Q/AGjxKEu1AKwNvt9U2; __Secure-1PSID=g.a0009AiszrmMkxnOzGHN3-AgUVa8_rarWA45h6lZ1JT1PjYStBGDf6PPoxl1Z4e53YnveWis5wACgYKAe4SARESFQHGX2MiMI7PJaul7xu97XbXqZfzlBoVAUF8yKo4tovC-QEsjTGQuwbDHE8A0076; __Secure-1PSIDTS=sidts-CjQBWhotCaOc8R5ePw7_aWzyXzXNAOHZwcPfB5xJ9RVY4OkF398oagC6jC-_xQOCwHQoxi0GEAA; __Secure-3PAPISID=ro4mJ0xKO0Q-Be3Q/AGjxKEu1AKwNvt9U2; __Secure-3PSID=g.a0009AiszrmMkxnOzGHN3-AgUVa8_rarWA45h6lZ1JT1PjYStBGDqpkCVaMhmrHfg34U0kCHswACgYKAUESARESFQHGX2MiCyHbs2Ux0c8EKftbrnKfZBoVAUF8yKrvS-5h6NPSKHlavYLx8gaD0076; __Secure-3PSIDTS=sidts-CjQBWhotCaOc8R5ePw7_aWzyXzXNAOHZwcPfB5xJ9RVY4OkF398oagC6jC-_xQOCwHQoxi0GEAA; CONSISTENCY=AH5K9rbvTT14tkSZMxYroc2gdn2totWUwZ0DESrQIUNbkaSbV5fszt6HYlOW0wjJZLcKolOGzO-NfmwGzvElbKRJ2iF1hA-FEpaUzv9S7EAsKotgR6pcv37MXvp_dTz8gK9Fp7AAZ1uwodOx7i3isElSHPLheN9CsOMUwwujPcEAvTeQXYUQ3p6Nb4y2qHK3tg87LaqMkfyt_rQcD9hmKtHOTKI43KksJKnwQX5G9BQSREoF; __Secure-ROLLOUT_TOKEN=CJypuOvf9ryu1gEQg8uGxrf9kwMYieqXxrf9kwM%3D; __Secure-YNID=17.YT=tHe6BUg-662G2iWC-xaJhi5AZOd-oGTXVsO-7GlKDhx63eOmDSkt3bnM5ikPZbqAF7pTPbx_O0pEhQrcU2Lw-SaMD_iHQd_S91m3dqBiwkAfM54tTxzj1gJik4bO2HjWbcR_KECP0SnigaVeY0TVf7esclUcONa0uz4Xq6s7TpDsiIWQ8aOftixDmKd16r8GLjIf-fj0SsXPXm2apMhgLzrv8XSCIFPJ0-Xvbg3A9Er_yTkjoCsAFu89RrZdqNfJnsqxAgpuxvVRXAaeA0VSKfCnQv2vc5SVgZgKWktgjr-c3igMC6jgOXFCIZAR8__2NKM1oKDcIIwGNypoI46zQQ; __Secure-ROLLOUT_TOKEN=CJmCgoHO9PCRWhCy9t_L_fSTAxiT_PPBs_2TAw%3D%3D; YSC=yGNlBS3rfqY; _gcl_au=1.1.935007768.1776529815; __Secure-BUCKET=CPEB',
  );

  VideoPlayerManager(this._audioHandler, this._settingsService)
    : _appAudioHandler = _audioHandler is MyAudioHandler
          ? _audioHandler
          : null {
    _ytExplode = _createYoutubeClient();
    if (!kIsWeb && Platform.isAndroid) {
      _androidAudioEnhancer = AndroidLoudnessEnhancer();
      _androidAudioEqualizer = AndroidEqualizer();
      _player = AudioPlayer(
        audioPipeline: AudioPipeline(
          androidAudioEffects: [
            _androidAudioEnhancer!,
            _androidAudioEqualizer!,
          ],
        ),
      );
      _crossfadePlayer = AudioPlayer();
    } else {
      _player = AudioPlayer();
      _crossfadePlayer = AudioPlayer();
    }
    _settingsService.addListener(_onSettingsChanged);
    unawaited(_applyUserAudioPreferences());
    _bindSystemMediaControls();
    _bindIosLockScreenFavoriteCommand();
    _bindSharedSongChannel();
    _bindSiriChannel();
    _bindIosPowerModeChannel();
    WidgetsBinding.instance.addObserver(this);
    _attachActivePlayerSubscriptions();
    unawaited(_refreshLowPowerModeStatus());
    unawaited(_initPlayerSessionPersistence());
  }

  static String? _normalizeYoutubeCookie(String? raw) {
    final trimmed = (raw ?? '').trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.toLowerCase().startsWith('cookie:')) {
      final stripped = trimmed.substring('cookie:'.length).trim();
      return stripped.isEmpty ? null : stripped;
    }
    return trimmed;
  }

  YoutubeExplode _createYoutubeClient() {
    return YoutubeExplode(
      httpClient: _CookieAwareYoutubeHttpClient(
        cookieHeader: _youtubeCookieHeader,
      ),
    );
  }

  Map<String, String> get _youtubeHeaders {
    final cookie = _youtubeCookieHeader;
    if (cookie == null || cookie.isEmpty) {
      return _youtubeBaseHeaders;
    }
    return <String, String>{
      ..._youtubeBaseHeaders,
      HttpHeaders.cookieHeader: cookie,
    };
  }

  void _applyYoutubeCookieToRequest(HttpHeaders headers) {
    final cookie = _youtubeCookieHeader;
    if (cookie == null || cookie.isEmpty) return;
    headers.set(HttpHeaders.cookieHeader, cookie);
  }

  Duration get _playbackUiNotifyMinInterval => _isLowPowerModeEnabled
      ? _playbackUiNotifyMinIntervalLowPower
      : (_forceLowPowerProfileInNormal
            ? _playbackUiNotifyMinIntervalLowPower
            : _playbackUiNotifyMinIntervalNormal);

  Duration get _playbackUiNotifyMinPositionDelta => _isLowPowerModeEnabled
      ? _playbackUiNotifyMinPositionDeltaLowPower
      : (_forceLowPowerProfileInNormal
            ? _playbackUiNotifyMinPositionDeltaLowPower
            : _playbackUiNotifyMinPositionDeltaNormal);

  Duration get _playbackOpsTickInterval => _isLowPowerModeEnabled
      ? _playbackOpsTickIntervalLowPower
      : (_forceLowPowerProfileInNormal
            ? _playbackOpsTickIntervalLowPower
            : _playbackOpsTickIntervalNormal);

  Duration _maxDuration(Duration a, Duration b) => a >= b ? a : b;

  Duration get _effectivePlaybackUiNotifyMinInterval {
    var value = _playbackUiNotifyMinInterval;
    if (!_appInForeground) {
      value = _maxDuration(value, const Duration(milliseconds: 1300));
    } else if (_isMinimized && !_isLyricsLayout) {
      value = _maxDuration(value, const Duration(milliseconds: 1200));
    }
    return value;
  }

  Duration get _effectivePlaybackUiNotifyMinPositionDelta {
    var value = _playbackUiNotifyMinPositionDelta;
    if (!_appInForeground) {
      value = _maxDuration(value, const Duration(milliseconds: 1000));
    } else if (_isMinimized && !_isLyricsLayout) {
      value = _maxDuration(value, const Duration(milliseconds: 900));
    }
    return value;
  }

  void _attachActivePlayerSubscriptions() {
    _detachActivePlayerSubscriptions();
    _lastPlaybackUiNotifyAt = DateTime.fromMillisecondsSinceEpoch(0);
    _lastPlaybackOpsTickAt = DateTime.fromMillisecondsSinceEpoch(0);
    _lastNotifiedPosition = _position;
    _lastNotifiedBufferedPosition = _bufferedPosition;
    _lastNotifiedPlaying = _isPlaying;
    _lastNotifiedBuffering = _isBuffering;

    _positionSub = _player
        .createPositionStream(
          steps: (_isLowPowerModeEnabled || _forceLowPowerProfileInNormal)
              ? 170
              : 220,
          minPeriod: Duration(
            milliseconds:
                (_isLowPowerModeEnabled || _forceLowPowerProfileInNormal)
                ? 620
                : 520,
          ),
          maxPeriod: const Duration(milliseconds: 1400),
        )
        .listen((position) {
          _position = position;
          final now = DateTime.now();
          if (now.difference(_lastPlaybackOpsTickAt) >=
              _playbackOpsTickInterval) {
            _lastPlaybackOpsTickAt = now;
            unawaited(_maybePreloadUpcomingQueueTrack());
            unawaited(_maybeTriggerCrossfadeAdvance());
          }
          _syncSystemPlaybackState();
          _persistPlaybackSessionThrottled();
          _notifyPlaybackUiListenersThrottled();
        });

    _bufferedSub = _player.bufferedPositionStream.listen((buffered) {
      _bufferedPosition = buffered;
      _syncSystemPlaybackState();
      _notifyPlaybackUiListenersThrottled();
    });

    _durationSub = _player.durationStream.listen((duration) {
      if (duration != null) {
        _trackDuration = duration;
        _syncSystemNowPlaying();
        _syncSystemPlaybackState(force: true);
        _notifyPlaybackUiListenersThrottled(force: true);
      }
    });

    _playerStateSub = _player.playerStateStream.listen((state) {
      _isPlaying = state.playing;
      _isBuffering =
          state.processingState == ProcessingState.buffering ||
          state.processingState == ProcessingState.loading;
      if (state.processingState == ProcessingState.completed) {
        _isPlaying = false;
        _onTrackCompleted();
      }
      _syncSystemPlaybackState(force: true);
      _notifyPlaybackUiListenersThrottled(force: true);
    });
  }

  void _notifyPlaybackUiListenersThrottled({bool force = false}) {
    final now = DateTime.now();
    final positionChangedEnough =
        (_position - _lastNotifiedPosition).abs() >=
        _effectivePlaybackUiNotifyMinPositionDelta;
    final bufferedChangedEnough =
        (_bufferedPosition - _lastNotifiedBufferedPosition).abs() >=
        _playbackUiNotifyMinBufferedDelta;
    final flagsChanged =
        _isPlaying != _lastNotifiedPlaying ||
        _isBuffering != _lastNotifiedBuffering;

    final intervalElapsed =
        now.difference(_lastPlaybackUiNotifyAt) >=
        _effectivePlaybackUiNotifyMinInterval;
    if (!force && !flagsChanged && !intervalElapsed) return;
    if (!force &&
        !flagsChanged &&
        !positionChangedEnough &&
        !bufferedChangedEnough) {
      return;
    }

    _lastPlaybackUiNotifyAt = now;
    _lastNotifiedPosition = _position;
    _lastNotifiedBufferedPosition = _bufferedPosition;
    _lastNotifiedPlaying = _isPlaying;
    _lastNotifiedBuffering = _isBuffering;
    notifyListeners();
  }

  void _detachActivePlayerSubscriptions() {
    _positionSub?.cancel();
    _positionSub = null;
    _bufferedSub?.cancel();
    _bufferedSub = null;
    _durationSub?.cancel();
    _durationSub = null;
    _playerStateSub?.cancel();
    _playerStateSub = null;
  }

  String? get currentVideoId => _currentVideoId;
  bool get isMinimized => _isMinimized;
  bool get isFullScreen => _isFullScreen;
  bool get isAppInForeground => _appInForeground;
  bool get isLowPowerModeEnabled => _isLowPowerModeEnabled;
  bool get shouldUseLightweightPlayerUi =>
      _settingsService.dataSaverMode ||
      _isMinimized ||
      !_appInForeground ||
      _isLowPowerModeEnabled ||
      _forceLowPowerProfileInNormal;
  String? get trackTitle => _trackTitle;
  String? get trackThumbnailUrl => _trackThumbnailUrl;
  String? get trackArtist {
    final artist = cleanArtistName(_trackArtist);
    return artist.isEmpty ? null : artist;
  }

  Duration get trackDuration => _trackDuration;
  Duration get position => _position;
  Duration get bufferedPosition => _bufferedPosition;
  bool get isPlaying => _isPlaying;
  bool get isBuffering => _isBuffering;
  bool get isLoading => _isLoading && !_isCrossfadeTransitioning;
  bool get isLocal => _isLocal;
  bool get isUsingVideoFallback => _usingHiddenVideo;
  bool get preferForegroundVideoPlayback => _preferForegroundVideoPlayback;
  VideoPlayerController? get foregroundVideoController =>
      _preferForegroundVideoPlayback && _usingHiddenVideo
      ? _hiddenVideoController
      : null;
  bool get autoplayEnabled => _autoplayEnabled;
  bool get karaokeModeEnabled => _karaokeModeEnabled && isKaraokeSupported;
  bool get isAiStemsLoading => isKaraokeSupported ? _isAiStemsLoading : false;
  bool get isKaraokeSupported =>
      _settingsService.vmMusicSingEnabled &&
      !kIsWeb &&
      (Platform.isAndroid || Platform.isIOS);
  bool get isLyricsLayout => _isLyricsLayout;
  bool get isLyricsLoading => _isLyricsLoading;
  String? get lyricsText => _lyricsText;
  String? get lyricsError => _lyricsError;
  List<SyncedLyricLine> get syncedLyrics => _syncedLyrics;
  bool get hasSyncedLyrics => _syncedLyrics.isNotEmpty;
  int get currentSyncedLyricIndex {
    if (_syncedLyrics.isEmpty) return -1;
    final current = _position;
    if (current < _syncedLyrics.first.timestamp) return -1;
    final lastIdx = _syncedLyrics.length - 1;
    if (current >= _syncedLyrics[lastIdx].timestamp) return lastIdx;

    var low = 0;
    var high = lastIdx;
    var answer = -1;
    while (low <= high) {
      final mid = low + ((high - low) >> 1);
      final ts = _syncedLyrics[mid].timestamp;
      if (ts <= current) {
        answer = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return answer;
  }

  String? get currentStreamUrl => _currentStreamUrl;
  String? get errorMessage => _errorMessage;
  List<PlaybackQueueItem> get playbackQueue => [
    ..._manualPlaybackQueue,
    ..._playbackQueue,
  ];
  bool get isQueueLoading => _isQueueLoading;
  String get queueTitle {
    if (_manualPlaybackQueue.isEmpty) return _queueTitle;
    if (_playbackQueue.isEmpty) return 'En cola';
    return 'En cola · luego $_queueTitle';
  }

  bool get isInBackground => false;

  void init() {}

  Future<List<PlaybackQueueItem>> fetchQueueStyleRecommendations({
    int limit = 24,
    String? seedVideoId,
  }) async {
    if (limit <= 0) return const <PlaybackQueueItem>[];

    final normalizedSeed = seedVideoId?.trim();
    if (normalizedSeed != null && normalizedSeed.isNotEmpty) {
      return _fetchQueueRecommendationsFromSeed(
        videoId: normalizedSeed,
        limit: limit,
      );
    }

    final fromQueue = _playbackQueue
        .where((item) => !item.isLocal && item.videoId.trim().isNotEmpty)
        .take(limit)
        .toList(growable: false);
    if (fromQueue.isNotEmpty) return fromQueue;

    final currentId = _currentVideoId?.trim();
    if (currentId == null || currentId.isEmpty || _isLocal) {
      return const <PlaybackQueueItem>[];
    }

    return _fetchQueueRecommendationsFromSeed(videoId: currentId, limit: limit);
  }

  Future<List<PlaybackQueueItem>> _fetchQueueRecommendationsFromSeed({
    required String videoId,
    required int limit,
  }) async {
    try {
      final persisted = await _readRelatedQueueFromSession(videoId);
      if (persisted.isNotEmpty) {
        _rememberRecommendedQueue(persisted);
        return persisted
            .where((item) => !item.isLocal && item.videoId.trim().isNotEmpty)
            .take(limit)
            .toList(growable: false);
      }
      final seedVideo = await _getVideoWithRetry(
        videoId,
      ).timeout(const Duration(seconds: 10));
      final related = await _getRelatedQueueWithRetry(seedVideo);
      if (related.isNotEmpty) {
        _rememberRecommendedQueue(related);
      }
      return related
          .where((item) => !item.isLocal && item.videoId.trim().isNotEmpty)
          .take(limit)
          .toList(growable: false);
    } catch (e, s) {
      log(
        'Error obteniendo recomendaciones tipo cola',
        error: e,
        stackTrace: s,
      );
      return const <PlaybackQueueItem>[];
    }
  }

  void clearErrorMessage() {
    if (_errorMessage == null) return;
    _errorMessage = null;
    notifyListeners();
  }

  bool _hasQueuedItems() =>
      _manualPlaybackQueue.isNotEmpty || _playbackQueue.isNotEmpty;

  bool _hasResolvedQueueForVideo(String videoId) {
    final normalized = videoId.trim();
    if (normalized.isEmpty) return false;
    return _queueSeedVideoId == normalized;
  }

  bool _shouldRefreshQueueForVideo(
    String videoId, {
    required bool preserveExistingQueue,
  }) {
    final remainingAutoplayItems = _playbackQueue.length;
    if (preserveExistingQueue) {
      return remainingAutoplayItems <= _autoplayQueueRefillThreshold;
    }
    final hasResolvedForCurrent = _hasResolvedQueueForVideo(videoId);
    if (!hasResolvedForCurrent) {
      return true;
    }
    return remainingAutoplayItems <= _autoplayQueueRefillThreshold;
  }

  bool _isTrackInQueue({required String videoId, required bool isLocal}) {
    final id = videoId.trim();
    if (id.isEmpty) return false;
    final inManual = _manualPlaybackQueue.any(
      (item) => item.videoId == id && item.isLocal == isLocal,
    );
    if (inManual) return true;
    return _playbackQueue.any(
      (item) => item.videoId == id && item.isLocal == isLocal,
    );
  }

  bool _shouldPromptQueueResetForUserSelection({
    required String targetVideoId,
    required bool targetIsLocal,
  }) {
    final targetId = targetVideoId.trim();
    if (targetId.isEmpty) return false;
    if (!_hasQueuedItems()) return false;
    final isCurrentTrack =
        _currentVideoId == targetId && _isLocal == targetIsLocal;
    if (isCurrentTrack) return false;
    if (_isTrackInQueue(videoId: targetId, isLocal: targetIsLocal)) {
      return false;
    }
    return true;
  }

  bool _shouldPreserveQueueForTarget({
    required String targetVideoId,
    required bool targetIsLocal,
  }) {
    final targetId = targetVideoId.trim();
    if (targetId.isEmpty || !_hasQueuedItems()) return false;
    final isCurrentTrack =
        _currentVideoId == targetId && _isLocal == targetIsLocal;
    if (isCurrentTrack) return true;
    return _isTrackInQueue(videoId: targetId, isLocal: targetIsLocal);
  }

  bool _removeTrackFromQueuesById({
    required String videoId,
    required bool isLocal,
  }) {
    final id = videoId.trim();
    if (id.isEmpty) return false;
    final manualBefore = _manualPlaybackQueue.length;
    final autoBefore = _playbackQueue.length;
    _manualPlaybackQueue = _manualPlaybackQueue
        .where((item) => !(item.videoId == id && item.isLocal == isLocal))
        .toList(growable: false);
    _playbackQueue = _playbackQueue
        .where((item) => !(item.videoId == id && item.isLocal == isLocal))
        .toList(growable: false);
    return manualBefore != _manualPlaybackQueue.length ||
        autoBefore != _playbackQueue.length;
  }

  void _clearAllPlaybackQueueForUserSelection() {
    ++_queueEpoch;
    _manualPlaybackQueue = const [];
    _playbackQueue = const [];
    _isQueueLoading = false;
    _queueTitle = 'Siguiente';
    _queueSeedVideoId = null;
    _clearPreloadedNextTrack();
  }

  Future<bool> _askToClearQueueForNewSong(BuildContext context) async {
    final accepted = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return CupertinoAlertDialog(
          title: const Text('Se limpiará la cola de reproducción'),
          content: const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'La canción seleccionada no está en la cola actual. '
              '¿Quieres limpiar la cola y generar recomendaciones nuevas?',
            ),
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancelar'),
            ),
            CupertinoDialogAction(
              isDestructiveAction: true,
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Limpiar cola'),
            ),
          ],
        );
      },
    );
    return accepted ?? false;
  }

  Future<bool> _prepareQueueForUserSelection(
    BuildContext context, {
    required String targetVideoId,
    required bool targetIsLocal,
  }) async {
    final shouldPrompt = _shouldPromptQueueResetForUserSelection(
      targetVideoId: targetVideoId,
      targetIsLocal: targetIsLocal,
    );
    if (shouldPrompt) {
      final accepted = await _askToClearQueueForNewSong(context);
      if (!accepted) return false;
      _clearAllPlaybackQueueForUserSelection();
      notifyListeners();
      return true;
    }

    final removed = _removeTrackFromQueuesById(
      videoId: targetVideoId,
      isLocal: targetIsLocal,
    );
    if (removed) {
      _clearPreloadedNextTrack();
      notifyListeners();
    }
    return true;
  }

  Future<void> playFromUserSelection(
    BuildContext context,
    String videoId, {
    String? preferredThumbnailUrl,
    String? preferredTitle,
    String? preferredArtist,
    Duration? preferredDuration,
    bool preferVideoPlayback = false,
  }) async {
    final preserveQueue = _shouldPreserveQueueForTarget(
      targetVideoId: videoId,
      targetIsLocal: false,
    );
    final proceed = await _prepareQueueForUserSelection(
      context,
      targetVideoId: videoId,
      targetIsLocal: false,
    );
    if (!proceed) return;
    await play(
      videoId,
      preferredThumbnailUrl: preferredThumbnailUrl,
      preferredTitle: preferredTitle,
      preferredArtist: preferredArtist,
      preferredDuration: preferredDuration,
      preserveExistingQueue: preserveQueue,
      preferVideoPlayback: preferVideoPlayback,
    );
  }

  Future<void> playLocalFileFromUserSelection(
    BuildContext context, {
    required String id,
    required String filePath,
    required String title,
    required String thumbnailUrl,
    required String artist,
    String? localPlainLyrics,
    String? localSyncedLyrics,
    LocalPlaybackQueueStrategy queueStrategy =
        LocalPlaybackQueueStrategy.downloads,
  }) async {
    final preserveQueue = _shouldPreserveQueueForTarget(
      targetVideoId: id,
      targetIsLocal: true,
    );
    final proceed = await _prepareQueueForUserSelection(
      context,
      targetVideoId: id,
      targetIsLocal: true,
    );
    if (!proceed) return;
    await playLocalFile(
      id: id,
      filePath: filePath,
      title: title,
      thumbnailUrl: thumbnailUrl,
      artist: artist,
      localPlainLyrics: localPlainLyrics,
      localSyncedLyrics: localSyncedLyrics,
      preserveExistingQueue: preserveQueue,
      queueStrategy: queueStrategy,
    );
  }

  void _bindSystemMediaControls() {
    _appAudioHandler?.bindCallbacks(
      onPlayRequested: () async {
        if (!_isPlaying) {
          await togglePlayPause();
        }
      },
      onPauseRequested: () async {
        if (_isPlaying) {
          await togglePlayPause();
        }
      },
      onSkipNextRequested: () async {
        await playNextInQueue();
      },
      onSkipPreviousRequested: () async {
        await playPreviousInQueue();
      },
      onSeekRequested: (position) async {
        await seekTo(position);
      },
      onStopRequested: () async {
        await close();
      },
    );
  }

  Uri? _cachedSystemArtUri({
    required String videoId,
    String? thumbnailSource,
    bool requireSourceMatch = true,
  }) {
    final cached = _systemArtworkByVideoId[videoId];
    if (cached == null) return null;
    if (cached.scheme == 'file') {
      final file = File.fromUri(cached);
      if (!file.existsSync()) {
        _systemArtworkByVideoId.remove(videoId);
        _systemArtworkSourceByVideoId.remove(videoId);
        return null;
      }
    }
    if (!requireSourceMatch) {
      return cached;
    }
    final source = thumbnailSource?.trim() ?? '';
    if (source.isEmpty) return null;
    final storedSource = _systemArtworkSourceByVideoId[videoId];
    if (storedSource == source) {
      return cached;
    }
    return null;
  }

  Future<Uri?> _prepareSystemArtwork({
    required String videoId,
    required String? thumbnailSource,
  }) async {
    final source = thumbnailSource?.trim() ?? '';
    if (videoId.trim().isEmpty || source.isEmpty) return null;
    final cached = _cachedSystemArtUri(
      videoId: videoId,
      thumbnailSource: source,
      requireSourceMatch: true,
    );
    if (cached != null) return cached;
    final processed = await _nowPlayingArtworkService.resolveNowPlayingArtUri(
      videoId: videoId,
      thumbnailSource: source,
    );
    if (processed != null) {
      _systemArtworkByVideoId[videoId] = processed;
      _systemArtworkSourceByVideoId[videoId] = source;
    }
    return processed;
  }

  Future<void> _precacheQueueArtwork(Iterable<PlaybackQueueItem> items) async {
    final thumbUrls = <String>[];
    for (final item in items) {
      thumbUrls.add(item.thumbnailUrl);
      try {
        await _prepareSystemArtwork(
          videoId: item.videoId,
          thumbnailSource: item.thumbnailUrl,
        );
      } catch (_) {
        // Best effort.
      }
    }
    unawaited(ThumbnailCacheService.prefetchUrls(thumbUrls, maxItems: 20));
  }

  Iterable<PlaybackQueueItem> _queueArtworkCandidates({int limit = 12}) sync* {
    var emitted = 0;
    for (final item in _manualPlaybackQueue) {
      if (emitted >= limit) return;
      yield item;
      emitted++;
    }
    for (final item in _playbackQueue) {
      if (emitted >= limit) return;
      yield item;
      emitted++;
    }
  }

  void _syncSystemNowPlaying() {
    final handler = _appAudioHandler;
    if (handler == null) return;
    final videoId = _currentVideoId;
    final title = (_trackTitle ?? '').trim();
    final artist = cleanArtistName(_trackArtist);
    final thumb = _trackThumbnailUrl;
    if (videoId == null || videoId.isEmpty || title.isEmpty) return;
    final cachedArtUri = _cachedSystemArtUri(
      videoId: videoId,
      thumbnailSource: thumb,
      requireSourceMatch: false,
    );
    final previousArtForSameVideo = _lastNowPlayingArtVideoId == videoId
        ? _lastNowPlayingArtUri
        : null;
    // Enviamos solamente carátula procesada (cuadrada/recortada). Si todavía
    // no está lista, mandamos metadata y actualizamos cuando termine de
    // procesarse, sin usar URL cruda del thumbnail.
    final initialArtUri = cachedArtUri ?? previousArtForSameVideo;
    handler.syncNowPlaying(
      id: videoId,
      title: title,
      artist: artist.isEmpty ? 'Artista desconocido' : artist,
      artUri: initialArtUri,
      duration: _trackDuration > Duration.zero ? _trackDuration : null,
      extras: {'isLocal': _isLocal},
    );
    if (initialArtUri != null) {
      _lastNowPlayingArtVideoId = videoId;
      _lastNowPlayingArtUri = initialArtUri;
    }
    unawaited(_syncIosLockScreenFavoriteState(videoIdOverride: videoId));

    final normalizedThumb = thumb?.trim() ?? '';
    if (normalizedThumb.isEmpty) return;

    final requestEpoch = ++_nowPlayingArtworkEpoch;
    unawaited(() async {
      final processedUri = await _prepareSystemArtwork(
        videoId: videoId,
        thumbnailSource: normalizedThumb,
      );
      if (processedUri == null) return;
      if (requestEpoch != _nowPlayingArtworkEpoch) return;
      if (_currentVideoId != videoId) return;
      if ((_trackThumbnailUrl ?? '').trim() != normalizedThumb) return;
      final latestTitle = (_trackTitle ?? '').trim();
      if (latestTitle.isEmpty) return;
      final latestArtist = cleanArtistName(_trackArtist);
      handler.syncNowPlaying(
        id: videoId,
        title: latestTitle,
        artist: latestArtist.isEmpty ? 'Artista desconocido' : latestArtist,
        artUri: processedUri,
        duration: _trackDuration > Duration.zero ? _trackDuration : null,
        extras: {'isLocal': _isLocal},
      );
      _lastNowPlayingArtVideoId = videoId;
      _lastNowPlayingArtUri = processedUri;
      unawaited(_syncIosLockScreenFavoriteState(videoIdOverride: videoId));
    }());
  }

  void _syncSystemPlaybackState({bool force = false}) {
    final handler = _appAudioHandler;
    if (handler == null) return;
    final now = DateTime.now();
    if (!force &&
        now.difference(_lastSystemPlaybackSync) <
            const Duration(milliseconds: 1200)) {
      return;
    }
    _lastSystemPlaybackSync = now;
    handler.syncPlaybackState(
      playing: _isPlaying,
      buffering: _isBuffering || _isLoading,
      position: _position,
      bufferedPosition: _bufferedPosition,
      speed: _isPlaying ? 1.0 : 0.0,
    );
  }

  void _clearSystemNowPlaying() {
    _nowPlayingArtworkEpoch++;
    _lastNowPlayingArtVideoId = null;
    _lastNowPlayingArtUri = null;
    _appAudioHandler?.clearNowPlaying();
    _appAudioHandler?.syncStopped();
    unawaited(_syncIosLockScreenFavoriteState(disable: true));
  }

  void _bindIosLockScreenFavoriteCommand() {
    if (kIsWeb || !Platform.isIOS || _iosLockScreenFavoriteBound) return;
    _iosLockScreenFavoriteBound = true;
    _iosLockScreenFavoriteChannel.setMethodCallHandler((call) async {
      if (call.method == 'onFavoritePressed') {
        await _addCurrentTrackToFavoritesFromLockScreen();
        return;
      }
      throw MissingPluginException('Método no implementado: ${call.method}');
    });
    unawaited(_syncIosLockScreenFavoriteState());
  }

  void _bindSharedSongChannel() {
    if (kIsWeb || (!Platform.isIOS && !Platform.isAndroid)) return;
    if (_songShareBound) return;
    _songShareBound = true;
    _songShareChannel.setMethodCallHandler((call) async {
      if (call.method == 'onSharedSongReceived') {
        final args = call.arguments;
        if (args is Map) {
          final payload = Map<String, dynamic>.from(
            args.cast<dynamic, dynamic>(),
          );
          await _playSharedSongPayload(payload);
        }
        return;
      }
      throw MissingPluginException('Método no implementado: ${call.method}');
    });
    unawaited(_consumePendingSharedSongRequest());
  }

  void _bindSiriChannel() {
    if (kIsWeb || !Platform.isIOS || _siriChannelBound) return;
    _siriChannelBound = true;
    _iosSiriChannel.setMethodCallHandler((call) async {
      if (call.method == 'onPlaySongRequested') {
        final args = call.arguments;
        if (args is Map) {
          final payload = Map<String, dynamic>.from(
            args.cast<dynamic, dynamic>(),
          );
          await _playFromSiriPayload(payload);
        }
        return;
      }
      throw MissingPluginException('Método no implementado: ${call.method}');
    });
    unawaited(_consumePendingSiriPlayRequest());
  }

  void _bindIosPowerModeChannel() {
    if (kIsWeb || !Platform.isIOS) return;
    _iosPowerModeChannel.setMethodCallHandler((call) async {
      if (call.method != 'onPowerModeChanged') {
        throw MissingPluginException('Método no implementado: ${call.method}');
      }
      final enabled = call.arguments == true;
      _handleLowPowerModeChanged(enabled);
    });
  }

  Future<void> _refreshLowPowerModeStatus() async {
    if (kIsWeb || !Platform.isIOS) {
      _handleLowPowerModeChanged(false);
      return;
    }
    try {
      final enabled = await _iosPowerModeChannel
          .invokeMethod<bool>('getLowPowerModeEnabled')
          .timeout(const Duration(milliseconds: 1200));
      _handleLowPowerModeChanged(enabled == true);
    } catch (_) {
      // Best effort.
    }
  }

  void _handleLowPowerModeChanged(bool enabled) {
    if (_isLowPowerModeEnabled == enabled) return;
    _isLowPowerModeEnabled = enabled;
    _attachActivePlayerSubscriptions();
    notifyListeners();
  }

  Future<void> _consumePendingSharedSongRequest() async {
    if (_isConsumingPendingSharedSong) return;
    final now = DateTime.now();
    if (now.difference(_lastPendingSharedSongConsumeAt) <
        const Duration(seconds: 2)) {
      return;
    }
    _isConsumingPendingSharedSong = true;
    _lastPendingSharedSongConsumeAt = now;
    try {
      final raw = await _songShareChannel
          .invokeMethod<Map<Object?, Object?>?>('consumePendingSharedSong')
          .timeout(const Duration(milliseconds: 900));
      if (raw == null) return;
      final payload = Map<String, dynamic>.from(raw);
      await _playSharedSongPayload(payload);
    } catch (_) {
      // Best effort: no bloqueamos retorno a la app por shared-song.
    } finally {
      _isConsumingPendingSharedSong = false;
    }
  }

  Future<void> _consumePendingSiriPlayRequest() async {
    if (_isConsumingPendingSiriPlay) return;
    final now = DateTime.now();
    if (now.difference(_lastPendingSiriPlayConsumeAt) <
        const Duration(seconds: 2)) {
      return;
    }
    _isConsumingPendingSiriPlay = true;
    _lastPendingSiriPlayConsumeAt = now;
    try {
      final raw = await _iosSiriChannel
          .invokeMethod<Map<Object?, Object?>?>('consumePendingSiriPlayRequest')
          .timeout(const Duration(milliseconds: 900));
      if (raw == null) return;
      final payload = Map<String, dynamic>.from(raw);
      await _playFromSiriPayload(payload);
    } catch (_) {
      // Best effort: Siri puede fallar silenciosamente sin bloquear la app.
    } finally {
      _isConsumingPendingSiriPlay = false;
    }
  }

  Future<void> _playSharedSongPayload(Map<String, dynamic> payload) async {
    final videoId = (payload['videoId'] ?? '').toString().trim();
    if (videoId.isEmpty) return;
    final title = (payload['title'] ?? '').toString().trim();
    final artist = (payload['artist'] ?? '').toString().trim();
    final thumbnailUrl = (payload['thumbnailUrl'] ?? '').toString().trim();
    final durationMsRaw = payload['durationMs'];
    Duration? preferredDuration;
    if (durationMsRaw is num && durationMsRaw > 0) {
      preferredDuration = Duration(milliseconds: durationMsRaw.round());
    }
    await play(
      videoId,
      preferredThumbnailUrl: thumbnailUrl.isEmpty ? null : thumbnailUrl,
      preferredTitle: title.isEmpty ? null : title,
      preferredArtist: artist.isEmpty ? null : artist,
      preferredDuration: preferredDuration,
    );
  }

  Future<void> _playFromSiriPayload(Map<String, dynamic> payload) async {
    final song = (payload['song'] ?? '').toString().trim();
    final artist = (payload['artist'] ?? '').toString().trim();
    final query = (payload['query'] ?? '').toString().trim();
    if (song.isNotEmpty) {
      await playBestMatchForVoiceRequest(
        songTitle: song,
        artistName: artist.isEmpty ? null : artist,
        fallbackQuery: query.isEmpty ? null : query,
      );
      return;
    }
    if (query.isEmpty) return;
    await playBestMatchForVoiceQuery(query);
  }

  Future<bool> playBestMatchForVoiceRequest({
    required String songTitle,
    String? artistName,
    String? fallbackQuery,
  }) async {
    final song = _sanitizeSearchQuery(songTitle);
    if (song.isEmpty) return false;
    final artist = _sanitizeSearchQuery(artistName ?? '');
    final query = artist.isEmpty ? song : '$song $artist';
    try {
      final results = await _safeSearchVideos(query, limit: 10);
      if (results.isEmpty) return false;
      final selected = _pickBestVoiceSearchResult(
        query: song,
        preferredArtist: artist.isEmpty ? null : artist,
        results: results,
      );
      await play(
        selected.id.value,
        preferredTitle: selected.title,
        preferredArtist: selected.author,
        preferredDuration: selected.duration,
      );
      return true;
    } catch (_) {
      final fallback = _sanitizeSearchQuery(fallbackQuery ?? '');
      if (fallback.isEmpty) return false;
      return playBestMatchForVoiceQuery(fallback);
    }
  }

  Future<bool> playBestMatchForVoiceQuery(String rawQuery) async {
    final query = _sanitizeSearchQuery(rawQuery);
    if (query.isEmpty) return false;
    try {
      final results = await _safeSearchVideos(query, limit: 10);
      if (results.isEmpty) return false;
      final selected = _pickBestVoiceSearchResult(
        query: query,
        preferredArtist: null,
        results: results,
      );
      await play(
        selected.id.value,
        preferredTitle: selected.title,
        preferredArtist: selected.author,
        preferredDuration: selected.duration,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Video _pickBestVoiceSearchResult({
    required String query,
    String? preferredArtist,
    required List<Video> results,
  }) {
    final normalizedQuery = _normalizeVoiceMatchText(query);
    final queryTokens = normalizedQuery
        .split(' ')
        .where((token) => token.trim().isNotEmpty)
        .toList(growable: false);
    final normalizedArtist = _normalizeVoiceMatchText(preferredArtist ?? '');
    final artistTokens = normalizedArtist
        .split(' ')
        .where((token) => token.trim().isNotEmpty)
        .toList(growable: false);
    var best = results.first;
    var bestScore = -1.0;

    for (final video in results) {
      final titleNorm = _normalizeVoiceMatchText(video.title);
      final authorNorm = _normalizeVoiceMatchText(video.author);
      var score = 0.0;

      final matchedTokens = queryTokens
          .where((token) => titleNorm.contains(token))
          .length;
      if (queryTokens.isNotEmpty) {
        score += (matchedTokens / queryTokens.length) * 65.0;
      }
      if (titleNorm.contains(normalizedQuery)) {
        score += 22.0;
      }
      if (artistTokens.isNotEmpty) {
        final matchedArtistTokens = artistTokens
            .where((token) => authorNorm.contains(token))
            .length;
        score += (matchedArtistTokens / artistTokens.length) * 42.0;
        if (authorNorm.contains(normalizedArtist)) {
          score += 20.0;
        }
      }
      if (_isPureYoutubeMusicAudio(video)) {
        score += 12.0;
      }
      if (authorNorm.contains('vevo') || authorNorm.contains('topic')) {
        score += 8.0;
      }
      final duration = video.duration;
      if (duration != null &&
          duration >= const Duration(seconds: 75) &&
          duration <= const Duration(minutes: 11)) {
        score += 4.0;
      }
      if (score > bestScore) {
        bestScore = score;
        best = video;
      }
    }
    return best;
  }

  String _normalizeVoiceMatchText(String value) {
    final lower = value.toLowerCase();
    final normalized = StringBuffer();
    for (final code in lower.runes) {
      switch (code) {
        case 225:
          normalized.write('a');
          break;
        case 233:
          normalized.write('e');
          break;
        case 237:
          normalized.write('i');
          break;
        case 243:
          normalized.write('o');
          break;
        case 250:
        case 252:
          normalized.write('u');
          break;
        case 241:
          normalized.write('n');
          break;
        default:
          normalized.writeCharCode(code);
      }
    }
    return normalized
        .toString()
        .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  Future<void> _addCurrentTrackToFavoritesFromLockScreen() async {
    final videoId = (_currentVideoId ?? '').trim();
    final title = (_trackTitle ?? '').trim();
    if (videoId.isEmpty || title.isEmpty) return;
    final thumbnail = (_trackThumbnailUrl ?? '').trim();
    final artist = cleanArtistName(_trackArtist);
    final playlists = await _playlistService.getPlaylists();
    final favoritesExists = playlists.any(
      (playlist) => PlaylistService.isFavoritesPlaylistName(playlist.name),
    );
    final favorites = favoritesExists
        ? playlists.firstWhere(
            (playlist) =>
                PlaylistService.isFavoritesPlaylistName(playlist.name),
          )
        : app_models.Playlist(name: PlaylistService.favoritesPlaylistName);
    final alreadyFavorite = favorites.videos.any(
      (item) => item.videoId == videoId,
    );

    if (alreadyFavorite) {
      await _playlistService.removeVideoFromPlaylist(
        PlaylistService.favoritesPlaylistName,
        videoId,
      );
      await _syncIosLockScreenFavoriteState(videoIdOverride: videoId);
      return;
    }

    final track = VideoHistory(
      videoId: videoId,
      title: title,
      thumbnailUrl: thumbnail,
      channelTitle: artist.isEmpty ? 'Artista desconocido' : artist,
      watchedAt: DateTime.now(),
    );
    await _playlistService.addVideoToPlaylist(
      PlaylistService.favoritesPlaylistName,
      track,
    );
    await _syncIosLockScreenFavoriteState(videoIdOverride: videoId);
  }

  Future<void> _syncIosLockScreenFavoriteState({
    String? videoIdOverride,
    bool disable = false,
  }) async {
    if (kIsWeb || !Platform.isIOS) return;
    final videoId = (videoIdOverride ?? _currentVideoId ?? '').trim();
    if (disable || videoId.isEmpty) {
      try {
        await _iosLockScreenFavoriteChannel.invokeMethod<void>(
          'setFavoriteState',
          <String, dynamic>{
            'enabled': false,
            'isFavorite': false,
            'title': 'Favorito',
          },
        );
      } catch (_) {}
      return;
    }

    try {
      final playlists = await _playlistService.getPlaylists();
      final favorites = playlists.firstWhere(
        (playlist) => PlaylistService.isFavoritesPlaylistName(playlist.name),
        orElse: () =>
            app_models.Playlist(name: PlaylistService.favoritesPlaylistName),
      );
      final isFavorite = favorites.videos.any(
        (item) => item.videoId == videoId,
      );
      await _iosLockScreenFavoriteChannel.invokeMethod<void>(
        'setFavoriteState',
        <String, dynamic>{
          'enabled': true,
          'isFavorite': isFavorite,
          'title': 'Favorito',
        },
      );
    } catch (_) {}
  }

  void registerSearchThumbnail(String videoId, String? thumbnailUrl) {
    if (thumbnailUrl == null || thumbnailUrl.trim().isEmpty) return;
    _searchThumbnailOverrides[videoId] = thumbnailUrl.trim();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    final nextForeground = state == AppLifecycleState.resumed;
    if (_appInForeground != nextForeground) {
      _appInForeground = nextForeground;
      notifyListeners();
    }
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshLowPowerModeStatus());
      _backgroundEngineSwitchTimer?.cancel();
      _resumeSharedSongTimer?.cancel();
      _resumeSharedSongTimer = Timer(const Duration(milliseconds: 380), () {
        unawaited(_consumePendingSharedSongRequest());
      });
      if (_preferForegroundVideoPlayback &&
          !_isLocal &&
          !_usingHiddenVideo &&
          (_currentVideoId?.trim().isNotEmpty ?? false)) {
        _backgroundEngineSwitchTimer = Timer(
          const Duration(milliseconds: 240),
          () => unawaited(switchToForegroundVideo()),
        );
      }
    }
    if ((state == AppLifecycleState.paused ||
            state == AppLifecycleState.inactive) &&
        _usingHiddenVideo) {
      _backgroundEngineSwitchTimer?.cancel();
      _backgroundEngineSwitchTimer = Timer(
        const Duration(milliseconds: 650),
        () => unawaited(_switchHiddenVideoToAudioEngine()),
      );
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      unawaited(_persistPlaybackSession(force: true));
    }
  }

  // Compatibilidad con pantallas legadas de video.
  void setPlayerData({
    required String videoId,
    required Object controller,
    String? streamUrl,
    required String title,
    required String thumbnailUrl,
    required String channelTitle,
    Duration? duration,
    bool isLocal = false,
  }) {}

  Future<void> play(
    String videoId, {
    bool isLocalVideo = false,
    String? preferredThumbnailUrl,
    String? preferredTitle,
    String? preferredArtist,
    Duration? preferredDuration,
    String? preloadedStreamUrl,
    bool isRecoveryAttempt = false,
    bool preserveExistingQueue = false,
    bool preferVideoPlayback = false,
  }) async {
    _sessionRestoreEpoch++;
    _rememberCurrentForHistory();
    _isAiStemsLoading = false;
    _usingAiInstrumental = false;
    _karaokeOriginalStreamUrl = null;
    await _resetEngines();
    await _applyPlaybackVolumeSetting();
    _isLoading = true;
    _errorMessage = null;
    _currentVideoId = videoId;
    _isLocal = isLocalVideo;
    _preferForegroundVideoPlayback = preferVideoPlayback && !isLocalVideo;
    _isMinimized = false;
    _isFullScreen = false;
    _position = Duration.zero;
    _bufferedPosition = Duration.zero;
    _completionHandledForCurrent = false;
    _crossfadeTriggeredForCurrent = false;
    _isCrossfadeTransitioning = false;
    _crossfadeFailedForCurrentVideoId = null;
    _crossfadeFailedQueueKey = null;
    _clearPreloadedNextTrack();
    if (!preserveExistingQueue) {
      _queueSeedVideoId = null;
    }
    _trackTitle = (preferredTitle != null && preferredTitle.trim().isNotEmpty)
        ? preferredTitle.trim()
        : null;
    _trackArtist = cleanArtistName(preferredArtist);
    if (_trackArtist != null && _trackArtist!.isEmpty) {
      _trackArtist = null;
    }
    _trackDuration = preferredDuration ?? Duration.zero;
    final dataSaverMode = _settingsService.dataSaverMode;
    final rawPreferredThumbnail =
        (preferredThumbnailUrl != null &&
            preferredThumbnailUrl.trim().isNotEmpty)
        ? preferredThumbnailUrl.trim()
        : _searchThumbnailOverrides[videoId];
    final effectivePreferredThumbnail =
        rawPreferredThumbnail != null && rawPreferredThumbnail.isNotEmpty
        ? optimizeYoutubeThumbnailUrl(
            rawPreferredThumbnail,
            preferLowResolution: dataSaverMode,
          )
        : null;
    if (rawPreferredThumbnail != null && rawPreferredThumbnail.isNotEmpty) {
      _searchThumbnailOverrides[videoId] = rawPreferredThumbnail;
    }
    _trackThumbnailUrl = null;
    if (effectivePreferredThumbnail != null &&
        effectivePreferredThumbnail.isNotEmpty) {
      _trackThumbnailUrl = effectivePreferredThumbnail;
    }
    _resetLyricsState();
    _syncSystemNowPlaying();
    _syncSystemPlaybackState(force: true);
    unawaited(_persistPlaybackSession(force: true));
    notifyListeners();

    try {
      final shouldFetchVideoMetadata =
          _trackTitle == null ||
          _trackArtist == null ||
          _trackThumbnailUrl == null ||
          _trackDuration == Duration.zero ||
          _autoplayEnabled;
      Future<StreamManifest>? manifestFuture;
      final Future<Video>? videoFuture = shouldFetchVideoMetadata
          ? _getVideoWithRetry(videoId)
          : null;

      Object? lastAudioError;
      var started = false;
      if (!isLocalVideo && !_preferForegroundVideoPlayback) {
        started = await _tryStartPlaybackFromSongCache(videoId);
      }
      if (preloadedStreamUrl != null && preloadedStreamUrl.trim().isNotEmpty) {
        try {
          final preloadedUri = Uri.parse(preloadedStreamUrl.trim());
          final headers =
              _headersForStreamUri(preloadedUri) ?? const <String, String>{};
          await _player.setAudioSource(
            AudioSource.uri(preloadedUri, headers: headers),
          );
          await _player.play();
          unawaited(_applyTrackStartFadeInIfEnabled());
          started = true;
          _usingHiddenVideo = false;
          _currentStreamUrl = preloadedUri.toString();
          unawaited(_warmSongCacheFromUri(videoId: videoId, uri: preloadedUri));
        } catch (e) {
          lastAudioError = e;
        }
      }

      if (!started && !_preferForegroundVideoPlayback) {
        manifestFuture ??= _getManifestWithRetry(videoId);
        final manifest = await manifestFuture;
        final audioStreams = manifest.audioOnly.toList();
        if (audioStreams.isEmpty) {
          throw Exception('No se encontraron streams de audio');
        }
        final orderedStreams = _prioritizeAudioStreams(audioStreams);
        for (final stream in orderedStreams) {
          try {
            await _player.setAudioSource(
              AudioSource.uri(stream.url, headers: _youtubeHeaders),
            );
            await _player.play();
            unawaited(_applyTrackStartFadeInIfEnabled());
            started = true;
            _usingHiddenVideo = false;
            _currentStreamUrl = stream.url.toString();
            unawaited(_warmSongCacheFromUri(videoId: videoId, uri: stream.url));
            break;
          } catch (e) {
            lastAudioError = e;
          }
        }
      }

      if (!started) {
        manifestFuture ??= _getManifestWithRetry(videoId);
        final manifest = await manifestFuture;
        final muxedStreams = _prioritizeMuxedStreams(manifest.muxed.toList());
        Object? lastMuxedError;
        for (final stream in muxedStreams) {
          try {
            final controller = VideoPlayerController.networkUrl(
              stream.url,
              httpHeaders: _youtubeHeaders,
            );
            await controller.initialize();
            await controller.play();
            _hiddenVideoController = controller;
            _usingHiddenVideo = true;
            _currentStreamUrl = stream.url.toString();
            _isPlaying = true;
            _isBuffering = false;
            _trackDuration = controller.value.duration;
            controller.addListener(_syncFromHiddenVideo);
            started = true;
            if (!_preferForegroundVideoPlayback) {
              unawaited(_switchHiddenVideoToAudioEngine());
            }
            break;
          } catch (e) {
            lastMuxedError = e;
          }
        }
        if (!started) {
          throw Exception(
            'No se pudo iniciar audio ni fallback de video: audio=$lastAudioError muxed=$lastMuxedError',
          );
        }
      }

      if (!_autoplayEnabled && !preserveExistingQueue) {
        _clearQueueForAutoplayDisabled();
      }
      unawaited(_applyAudioEffects());
      if (_autoplayEnabled && !isLocalVideo && !preserveExistingQueue) {
        unawaited(_warmUpAutoplayQueue(videoId));
      }

      _sessionPlayedVideoIds.add(videoId);
      _warmUpNextTrackPreloadNow();

      // Metadata/cola/historial en segundo plano para no bloquear inicio de reproducción.
      unawaited(() async {
        Video? video;
        try {
          if (videoFuture != null) {
            video = await videoFuture.timeout(const Duration(seconds: 8));
          }
        } catch (e, s) {
          log(
            'No se pudo resolver metadata de video a tiempo',
            error: e,
            stackTrace: s,
          );
        }

        if (_currentVideoId != videoId) return;

        if (video != null) {
          final metadataThumbnail = bestThumbnailForVideo(
            video,
            preferLowResolution: false,
          );
          _trackTitle = video.title;
          _trackThumbnailUrl = _mergeThumbnailKeepingMusicSquare(
            existing: _trackThumbnailUrl,
            candidate: metadataThumbnail.isNotEmpty
                ? metadataThumbnail
                : effectivePreferredThumbnail,
          );
          _trackArtist = cleanArtistName(video.author);
          _trackDuration = video.duration ?? Duration.zero;
          _syncSystemNowPlaying();
          _syncSystemPlaybackState(force: true);
          notifyListeners();
        }

        final hasLocalLyrics =
            (_lyricsText?.isNotEmpty ?? false) || _syncedLyrics.isNotEmpty;
        if (_isLyricsLayout && !hasLocalLyrics) {
          await _loadLyricsForCurrentTrack();
        }

        if (_autoplayEnabled && video == null && _currentVideoId == videoId) {
          try {
            video = await _getVideoWithRetry(
              videoId,
            ).timeout(const Duration(seconds: 20));
          } catch (e, s) {
            log(
              'No se pudo resolver metadata para cargar cola',
              error: e,
              stackTrace: s,
            );
          }
        }

        if (_autoplayEnabled && video != null && _currentVideoId == videoId) {
          if (_shouldRefreshQueueForVideo(
            videoId,
            preserveExistingQueue: preserveExistingQueue,
          )) {
            await _loadOnlineQueue(video, currentVideoId: videoId);
          }
        } else if (_autoplayEnabled &&
            video == null &&
            _currentVideoId == videoId) {
          if (_shouldRefreshQueueForVideo(
            videoId,
            preserveExistingQueue: preserveExistingQueue,
          )) {
            await _loadOnlineQueueFallbackFromCurrentContext(
              currentVideoId: videoId,
            );
          }
        }

        if (_currentVideoId == videoId) {
          await _addCurrentTrackToHistory(videoId);
        }
      }());
    } catch (e, s) {
      log('Error reproduciendo audio', error: e, stackTrace: s);
      if (e is RequestLimitExceededException &&
          !isRecoveryAttempt &&
          !isLocalVideo) {
        _activateYoutubeSlowMode(const Duration(minutes: 2));
        _manifestCache.remove(videoId);
        _videoCache.remove(videoId);
        _manifestRequests.remove(videoId);
        _videoRequests.remove(videoId);
        try {
          await Future<void>.delayed(const Duration(milliseconds: 1400));
          await _resetYoutubeClientForRecovery();
          await play(
            videoId,
            isLocalVideo: isLocalVideo,
            preferredThumbnailUrl: preferredThumbnailUrl,
            preferredTitle: preferredTitle,
            preferredArtist: preferredArtist,
            preferredDuration: preferredDuration,
            preloadedStreamUrl: preloadedStreamUrl,
            isRecoveryAttempt: true,
            preserveExistingQueue: preserveExistingQueue,
            preferVideoPlayback: preferVideoPlayback,
          );
          return;
        } catch (recoveryError, recoveryStack) {
          log(
            'Recuperacion por RequestLimitExceeded falló',
            error: recoveryError,
            stackTrace: recoveryStack,
          );
        }
      }
      if (!isLocalVideo &&
          (e is RequestLimitExceededException ||
              e is VideoUnavailableException ||
              e is HandshakeException ||
              e is SocketException ||
              e is HttpException)) {
        final altSource = await _resolveDownloadSourceViaYoutubei(videoId);
        if (altSource != null) {
          final played = await _attemptPlaybackFromDownloadSource(
            altSource,
            keepVideoEngine: _preferForegroundVideoPlayback,
          );
          if (played) {
            _errorMessage = null;
            _syncSystemNowPlaying();
            _syncSystemPlaybackState(force: true);
            return;
          }
        }
      }
      _errorMessage = _buildPlaybackErrorMessage(e);
      _isPlaying = false;
      _isBuffering = false;
      await _player.stop();
      _syncSystemPlaybackState(force: true);
    } finally {
      _isLoading = false;
      if (_errorMessage == null &&
          _currentVideoId == videoId &&
          _hasQueuedItems()) {
        _warmUpNextTrackPreloadNow();
      }
      _syncSystemPlaybackState(force: true);
      unawaited(_persistPlaybackSession(force: true));
      notifyListeners();
    }
  }

  Future<bool> _tryStartPlaybackFromSongCache(String videoId) async {
    try {
      final filePath = await SongStreamCacheService.resolveFreshFilePath(
        videoId,
      );
      if (filePath == null || filePath.isEmpty) return false;
      final file = File(filePath);
      if (!await file.exists()) return false;
      await _player.setAudioSource(AudioSource.file(file.path));
      await _player.play();
      unawaited(_applyTrackStartFadeInIfEnabled());
      _usingHiddenVideo = false;
      _currentStreamUrl = file.path;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _warmSongCacheFromUri({
    required String videoId,
    required Uri uri,
  }) async {
    try {
      await SongStreamCacheService.warmFromStreamUrl(
        videoId: videoId,
        streamUri: uri,
      );
    } catch (_) {
      // Best effort.
    }
  }

  Future<void> _addCurrentTrackToHistory(String videoId) async {
    final title = _trackTitle;
    final thumbnail = _trackThumbnailUrl;
    final artist = cleanArtistName(_trackArtist);
    if (title == null ||
        title.isEmpty ||
        thumbnail == null ||
        thumbnail.isEmpty ||
        artist.isEmpty) {
      return;
    }
    try {
      await _historyService.addVideoToHistory(
        VideoHistory(
          videoId: videoId,
          title: title,
          thumbnailUrl: thumbnail,
          channelTitle: artist,
          watchedAt: DateTime.now(),
        ),
      );
    } catch (e, s) {
      log('No se pudo guardar historial', error: e, stackTrace: s);
    }
  }

  Future<StreamManifest> _getManifestWithRetry(String videoId) async {
    final cached = _manifestCache[videoId];
    if (cached != null) return cached;
    final inFlight = _manifestRequests[videoId];
    if (inFlight != null) return inFlight;

    final future = _runYoutubeWithRetry(
      () => _ytExplode.videos.streamsClient.getManifest(videoId),
      maxAttempts: _isYoutubeSlowModeActive ? 4 : 3,
    );
    _manifestRequests[videoId] = future;
    try {
      final manifest = await future;
      _manifestCache[videoId] = manifest;
      return manifest;
    } finally {
      _manifestRequests.remove(videoId);
    }
  }

  Future<Video> _getVideoWithRetry(String videoId) async {
    final cached = _videoCache[videoId];
    if (cached != null) return cached;
    final inFlight = _videoRequests[videoId];
    if (inFlight != null) return inFlight;

    final future = _runYoutubeWithRetry(
      () => _ytExplode.videos.get(VideoId(videoId)),
      maxAttempts: _isYoutubeSlowModeActive ? 4 : 3,
    );
    _videoRequests[videoId] = future;
    try {
      final video = await future;
      _videoCache[videoId] = video;
      return video;
    } finally {
      _videoRequests.remove(videoId);
    }
  }

  Future<DownloadSourceInfo?> resolveDownloadSourceSilently(
    String videoId,
  ) async {
    try {
      final manifest = await _getManifestWithRetry(videoId);
      final audioStreams = manifest.audioOnly.toList();
      if (audioStreams.isNotEmpty) {
        final selectedAudio = _prioritizeAudioStreams(audioStreams).first;
        return DownloadSourceInfo(
          sourceUrl: selectedAudio.url.toString(),
          isVideoSource: false,
        );
      }

      final muxedStreams = manifest.muxed.toList();
      if (muxedStreams.isNotEmpty) {
        final selectedMuxed = _prioritizeMuxedStreams(muxedStreams).first;
        return DownloadSourceInfo(
          sourceUrl: selectedMuxed.url.toString(),
          isVideoSource: true,
        );
      }

      return null;
    } on RequestLimitExceededException {
      return _resolveDownloadSourceViaYoutubei(videoId);
    } catch (_) {
      return null;
    }
  }

  Future<DownloadSourceInfo?> resolveDownloadSourceIsolated(
    String videoId,
  ) async {
    try {
      final manifest = await _getManifestWithRetry(videoId);
      final audioStreams = _prioritizeAudioStreams(manifest.audioOnly.toList());
      for (final stream in audioStreams.take(6)) {
        final ok = await _probeAudioStreamSilently(stream.url);
        if (ok) {
          return DownloadSourceInfo(
            sourceUrl: stream.url.toString(),
            isVideoSource: false,
          );
        }
      }

      final muxedStreams = _prioritizeMuxedStreams(manifest.muxed.toList());
      for (final stream in muxedStreams.take(4)) {
        final ok = await _probeVideoStreamSilently(stream.url);
        if (ok) {
          return DownloadSourceInfo(
            sourceUrl: stream.url.toString(),
            isVideoSource: true,
          );
        }
      }

      // Fallback final: regresar mejor esfuerzo sin probe.
      return resolveDownloadSourceSilently(videoId);
    } on RequestLimitExceededException {
      return _resolveDownloadSourceViaYoutubei(videoId);
    } catch (_) {
      return null;
    }
  }

  Future<DownloadSourceInfo?> _resolveDownloadSourceViaYoutubei(
    String videoId,
  ) async {
    final client = HttpClient();
    try {
      final candidates = <Map<String, Object>>[
        {
          'name': 'WEB',
          'version': '2.20240224.11.00',
          'ua':
              'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        },
        {
          'name': 'ANDROID',
          'version': '19.09.37',
          'ua': 'com.google.android.youtube/19.09.37 (Linux; U; Android 14)',
        },
        {
          'name': 'IOS',
          'version': '19.09.3',
          'ua':
              'com.google.ios.youtube/19.09.3 (iPhone16,2; U; CPU iOS 17_3 like Mac OS X)',
        },
      ];

      for (final clientDef in candidates) {
        final req = await client.postUrl(Uri.parse(_youtubeiPlayerEndpoint));
        req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
        req.headers.set(HttpHeaders.acceptHeader, 'application/json');
        req.headers.set(HttpHeaders.userAgentHeader, clientDef['ua'] as String);
        _applyYoutubeCookieToRequest(req.headers);

        final payload = <String, Object>{
          'videoId': videoId,
          'context': {
            'client': {
              'clientName': clientDef['name'] as String,
              'clientVersion': clientDef['version'] as String,
            },
          },
          'contentCheckOk': true,
          'racyCheckOk': true,
        };
        req.add(utf8.encode(jsonEncode(payload)));

        final res = await req.close();
        if (res.statusCode < 200 || res.statusCode >= 300) {
          continue;
        }
        final body = await utf8.decoder.bind(res).join();
        final raw = jsonDecode(body);
        if (raw is! Map<String, dynamic>) continue;

        final streamingData = raw['streamingData'];
        if (streamingData is! Map<String, dynamic>) continue;

        String? pickedAudio;
        String? pickedMuxed;

        final adaptive = streamingData['adaptiveFormats'];
        if (adaptive is List) {
          final audioFormats =
              adaptive
                  .whereType<Map>()
                  .map((e) => Map<String, dynamic>.from(e))
                  .where((f) {
                    final mime = (f['mimeType']?.toString() ?? '')
                        .toLowerCase();
                    return mime.contains('audio/') &&
                        (f['url']?.toString().isNotEmpty ?? false);
                  })
                  .toList()
                ..sort(
                  (a, b) => (b['bitrate'] as num? ?? 0).compareTo(
                    a['bitrate'] as num? ?? 0,
                  ),
                );
          if (audioFormats.isNotEmpty) {
            final targetBitrate = _targetBitrateForCurrentQuality();
            if (targetBitrate == null) {
              pickedAudio = audioFormats.first['url']?.toString();
            } else {
              audioFormats.sort((a, b) {
                final aRate = (a['bitrate'] as num? ?? 0).toInt();
                final bRate = (b['bitrate'] as num? ?? 0).toInt();
                final aDistance = (aRate - targetBitrate).abs();
                final bDistance = (bRate - targetBitrate).abs();
                if (aDistance != bDistance) {
                  return aDistance.compareTo(bDistance);
                }
                return bRate.compareTo(aRate);
              });
              pickedAudio = audioFormats.first['url']?.toString();
            }
          }
        }

        final formats = streamingData['formats'];
        if (formats is List) {
          final targetHeight = _targetVideoHeightForCurrentQuality();
          final muxedFormats =
              formats
                  .whereType<Map>()
                  .map((e) => Map<String, dynamic>.from(e))
                  .where((f) {
                    final hasUrl = f['url']?.toString().isNotEmpty ?? false;
                    final mime = (f['mimeType']?.toString() ?? '')
                        .toLowerCase();
                    return hasUrl &&
                        (mime.contains('video/') || mime.contains('mp4'));
                  })
                  .toList()
                ..sort((a, b) {
                  final aHeight = (a['height'] as num? ?? 0).toInt();
                  final bHeight = (b['height'] as num? ?? 0).toInt();

                  if (targetHeight == null) {
                    final heightCompare = bHeight.compareTo(aHeight);
                    if (heightCompare != 0) return heightCompare;
                  } else {
                    final aWithinTarget = aHeight <= targetHeight;
                    final bWithinTarget = bHeight <= targetHeight;
                    if (aWithinTarget != bWithinTarget) {
                      return aWithinTarget ? -1 : 1;
                    }
                    if (aWithinTarget) {
                      final heightCompare = bHeight.compareTo(aHeight);
                      if (heightCompare != 0) return heightCompare;
                    } else {
                      final heightCompare = aHeight.compareTo(bHeight);
                      if (heightCompare != 0) return heightCompare;
                    }
                  }
                  return (b['bitrate'] as num? ?? 0).compareTo(
                    a['bitrate'] as num? ?? 0,
                  );
                });
          if (muxedFormats.isNotEmpty) {
            pickedMuxed = muxedFormats.first['url']?.toString();
          }
        }

        final hlsManifest = streamingData['hlsManifestUrl']?.toString();
        if (pickedAudio != null && pickedAudio.trim().isNotEmpty) {
          return DownloadSourceInfo(
            sourceUrl: pickedAudio.trim(),
            isVideoSource: false,
          );
        }
        if (pickedMuxed != null && pickedMuxed.trim().isNotEmpty) {
          return DownloadSourceInfo(
            sourceUrl: pickedMuxed.trim(),
            isVideoSource: true,
          );
        }
        if (hlsManifest != null && hlsManifest.trim().isNotEmpty) {
          return DownloadSourceInfo(
            sourceUrl: hlsManifest.trim(),
            isVideoSource: true,
          );
        }
      }

      return null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> _attemptPlaybackFromDownloadSource(
    DownloadSourceInfo source, {
    bool keepVideoEngine = false,
  }) async {
    final uri = Uri.parse(source.sourceUrl);
    final headers = _headersForStreamUri(uri) ?? const <String, String>{};

    if (!source.isVideoSource) {
      try {
        await _player.setAudioSource(AudioSource.uri(uri, headers: headers));
        unawaited(_applyAudioEffects());
        await _player.play();
        unawaited(_applyTrackStartFadeInIfEnabled());
        _usingHiddenVideo = false;
        _preferForegroundVideoPlayback = false;
        _currentStreamUrl = source.sourceUrl;
        _isPlaying = true;
        _isBuffering = false;
        final currentId = _currentVideoId?.trim() ?? '';
        if (currentId.isNotEmpty) {
          unawaited(_warmSongCacheFromUri(videoId: currentId, uri: uri));
        }
        _syncSystemPlaybackState(force: true);
        notifyListeners();
        return true;
      } catch (_) {}
    }

    try {
      final controller = VideoPlayerController.networkUrl(
        uri,
        httpHeaders: headers,
      );
      await controller.initialize();
      await controller.play();
      _hiddenVideoController = controller;
      _usingHiddenVideo = true;
      _currentStreamUrl = source.sourceUrl;
      _isPlaying = true;
      _isBuffering = false;
      _trackDuration = controller.value.duration;
      controller.addListener(_syncFromHiddenVideo);
      if (!keepVideoEngine) {
        unawaited(_switchHiddenVideoToAudioEngine());
      }
      _syncSystemPlaybackState(force: true);
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  Map<String, String>? _headersForStreamUri(Uri uri) {
    final host = uri.host.toLowerCase();
    if (host.contains('googlevideo.com')) {
      // En iOS, algunas URLs firmadas de googlevideo fallan cuando se fuerzan
      // headers tipo Origin/Referer en un segundo player (crossfade).
      if (!kIsWeb && Platform.isIOS) return null;
      return _youtubeHeaders;
    }
    if (host.contains('youtube.com') || host.contains('ytimg.com')) {
      return _youtubeHeaders;
    }
    return null;
  }

  List<Map<String, String>?> _crossfadeHeaderCandidatesForUri(Uri uri) {
    final preferred = _headersForStreamUri(uri);
    final host = uri.host.toLowerCase();
    final isGoogleVideo = host.contains('googlevideo.com');
    if (!kIsWeb && Platform.isIOS && isGoogleVideo) {
      // Probamos sin headers y luego con headers para maximizar compatibilidad
      // de AVFoundation en reproducción simultánea.
      if (preferred == null) {
        return <Map<String, String>?>[null];
      }
      return <Map<String, String>?>[null, preferred];
    }
    if (preferred == null) {
      return <Map<String, String>?>[null];
    }
    return <Map<String, String>?>[preferred];
  }

  Future<bool> _probeAudioStreamSilently(Uri url) async {
    final probe = AudioPlayer();
    try {
      await probe.setVolume(0);
      await probe.setAudioSource(
        AudioSource.uri(url, headers: _youtubeHeaders),
      );
      return true;
    } catch (_) {
      return false;
    } finally {
      await probe.dispose();
    }
  }

  Future<bool> _probeVideoStreamSilently(Uri url) async {
    VideoPlayerController? controller;
    try {
      controller = VideoPlayerController.networkUrl(
        url,
        httpHeaders: _youtubeHeaders,
      );
      await controller.initialize();
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        await controller?.dispose();
      } catch (_) {}
    }
  }

  Future<List<PlaybackQueueItem>> _getRelatedQueueWithRetry(Video video) async {
    const queueAlgoVersion = 'ytmusic-next-v3';
    final freshnessBucket = (_sessionPlayedVideoIds.length / 4).floor();
    final key = '$queueAlgoVersion:$freshnessBucket:${video.id.value}';
    final cached = _relatedQueueCache[key];
    if (cached != null) return cached;

    final inFlight = _relatedQueueRequests[key];
    if (inFlight != null) return inFlight;

    final persisted = await _readRelatedQueueFromSession(video.id.value);
    if (persisted.isNotEmpty) {
      _relatedQueueCache[key] = persisted;
      return persisted;
    }

    final future = () async {
      final queueFromYouTubeMusic = await _fetchQueueFromYoutubeMusicNext(
        video,
      );

      final excludeIds = Set<String>.from(
        queueFromYouTubeMusic.map((item) => item.videoId),
      );

      if (queueFromYouTubeMusic.length >= 22 &&
          !_isQueueArtistMonotone(queueFromYouTubeMusic)) {
        return queueFromYouTubeMusic.take(35).toList(growable: false);
      }

      final fallback = await _buildRelatedQueueFromYoutubeFallback(
        video,
        excludeIds: excludeIds,
      );
      final merged = <PlaybackQueueItem>[...queueFromYouTubeMusic, ...fallback];
      if (merged.length < 18) {
        final radioFallback = await _buildYoutubeMusicRadioPlaylistFallback(
          video,
          excludeIds: excludeIds,
        );
        merged.addAll(
          radioFallback.where((item) => excludeIds.add(item.videoId)),
        );
      }
      if (merged.isEmpty) return const <PlaybackQueueItem>[];
      return _diversifyQueueByArtist(merged).take(35).toList(growable: false);
    }();

    _relatedQueueRequests[key] = future;
    try {
      final list = await future;
      if (list.isNotEmpty) {
        _relatedQueueCache[key] = list;
        unawaited(_writeRelatedQueueToSession(video.id.value, list));
      }
      return list;
    } finally {
      _relatedQueueRequests.remove(key);
    }
  }

  Future<List<PlaybackQueueItem>> _fetchQueueFromYoutubeMusicNext(
    Video currentVideo,
  ) async {
    const clientProfiles = <Map<String, String>>[
      {
        'clientName': 'WEB_REMIX',
        'clientVersion': '1.20240226.01.00',
        'headerClientName': '67',
        'userAgent':
            'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
      },
      {
        'clientName': 'WEB',
        'clientVersion': '2.20240224.11.00',
        'headerClientName': '1',
        'userAgent':
            'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
      },
    ];

    final selected = <PlaybackQueueItem>[];
    final seenIds = <String>{};
    final discoveredPlaylistIds = <String>{};

    for (final profile in clientProfiles) {
      final firstPayload = await _fetchYoutubeMusicNextPayload(
        videoId: currentVideo.id.value,
        clientName: profile['clientName']!,
        clientVersion: profile['clientVersion']!,
        headerClientName: profile['headerClientName']!,
        userAgent: profile['userAgent']!,
      );
      if (firstPayload == null) continue;

      final payloads = <Map<String, dynamic>>[firstPayload];
      discoveredPlaylistIds.addAll(
        _extractRecommendationPlaylistIds(firstPayload),
      );
      var continuation = _extractContinuationToken(firstPayload);
      var continuationFetches = 0;
      while (continuation != null &&
          continuation.isNotEmpty &&
          continuationFetches < 5 &&
          payloads.length < 6 &&
          selected.length < 40) {
        final continuationPayload = await _fetchYoutubeMusicNextPayload(
          continuation: continuation,
          clientName: profile['clientName']!,
          clientVersion: profile['clientVersion']!,
          headerClientName: profile['headerClientName']!,
          userAgent: profile['userAgent']!,
        );
        continuationFetches += 1;
        if (continuationPayload == null) break;
        payloads.add(continuationPayload);
        discoveredPlaylistIds.addAll(
          _extractRecommendationPlaylistIds(continuationPayload),
        );
        final nextToken = _extractContinuationToken(continuationPayload);
        if (nextToken == continuation) break;
        continuation = nextToken;
      }

      _appendCandidatesFromPayloads(
        payloads,
        currentVideo: currentVideo,
        selected: selected,
        seenIds: seenIds,
      );

      if (selected.length < 35 && discoveredPlaylistIds.isNotEmpty) {
        await _appendFromNextPlaylistIds(
          currentVideo: currentVideo,
          playlistIds: discoveredPlaylistIds,
          clientName: profile['clientName']!,
          clientVersion: profile['clientVersion']!,
          headerClientName: profile['headerClientName']!,
          userAgent: profile['userAgent']!,
          selected: selected,
          seenIds: seenIds,
        );
      }

      if (selected.length >= 40) break;
    }

    if (selected.length < 20) {
      discoveredPlaylistIds.addAll(<String>[
        'RDAMVM${currentVideo.id.value}',
        'RDMM${currentVideo.id.value}',
      ]);
      await _appendFromNextPlaylistIds(
        currentVideo: currentVideo,
        playlistIds: discoveredPlaylistIds,
        clientName: 'WEB_REMIX',
        clientVersion: '1.20240226.01.00',
        headerClientName: '67',
        userAgent:
            'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        selected: selected,
        seenIds: seenIds,
      );
    }

    return _diversifyQueueByArtist(selected);
  }

  void _appendCandidatesFromPayloads(
    List<Map<String, dynamic>> payloads, {
    required Video currentVideo,
    required List<PlaybackQueueItem> selected,
    required Set<String> seenIds,
  }) {
    for (final payload in payloads) {
      final extracted = _extractYoutubeMusicQueueCandidates(
        payload,
        currentVideo: currentVideo,
      );
      _appendYoutubeMusicCandidates(
        extracted,
        currentVideo: currentVideo,
        selected: selected,
        seenIds: seenIds,
      );
      if (selected.length >= 40) return;
    }
  }

  void _appendYoutubeMusicCandidates(
    Iterable<_YouTubeMusicQueueCandidate> candidates, {
    required Video currentVideo,
    required List<PlaybackQueueItem> selected,
    required Set<String> seenIds,
  }) {
    for (final candidate in candidates) {
      final id = candidate.videoId.trim();
      if (id.isEmpty || id == currentVideo.id.value) continue;
      if (!seenIds.add(id)) continue;
      if (_sessionPlayedVideoIds.contains(id)) continue;
      if (!_settingsService.allowExplicitContent &&
          (candidate.isExplicit ||
              _isExplicitText('${candidate.title} ${candidate.artist}'))) {
        continue;
      }
      selected.add(
        PlaybackQueueItem(
          videoId: candidate.videoId,
          title: candidate.title,
          thumbnailUrl: candidate.thumbnailUrl,
          artist: cleanArtistName(candidate.artist),
          isLocal: false,
        ),
      );
      if (selected.length >= 40) return;
    }
  }

  Future<void> _appendFromNextPlaylistIds({
    required Video currentVideo,
    required Set<String> playlistIds,
    required String clientName,
    required String clientVersion,
    required String headerClientName,
    required String userAgent,
    required List<PlaybackQueueItem> selected,
    required Set<String> seenIds,
  }) async {
    if (playlistIds.isEmpty || selected.length >= 40) return;
    final ordered = playlistIds.toList(growable: false)
      ..sort((a, b) {
        final aPriority = a.startsWith('RDAMVM')
            ? 0
            : (a.startsWith('RDMM') ? 1 : 2);
        final bPriority = b.startsWith('RDAMVM')
            ? 0
            : (b.startsWith('RDMM') ? 1 : 2);
        if (aPriority != bPriority) return aPriority.compareTo(bPriority);
        return a.length.compareTo(b.length);
      });

    for (final playlistId in ordered.take(6)) {
      if (selected.length >= 40) break;
      final firstPayload = await _fetchYoutubeMusicNextPayload(
        videoId: currentVideo.id.value,
        playlistId: playlistId,
        clientName: clientName,
        clientVersion: clientVersion,
        headerClientName: headerClientName,
        userAgent: userAgent,
      );
      if (firstPayload == null) continue;

      final payloads = <Map<String, dynamic>>[firstPayload];
      var continuation = _extractContinuationToken(firstPayload);
      var continuationFetches = 0;
      while (continuation != null &&
          continuation.isNotEmpty &&
          continuationFetches < 3 &&
          payloads.length < 5 &&
          selected.length < 40) {
        final continuationPayload = await _fetchYoutubeMusicNextPayload(
          continuation: continuation,
          clientName: clientName,
          clientVersion: clientVersion,
          headerClientName: headerClientName,
          userAgent: userAgent,
        );
        continuationFetches += 1;
        if (continuationPayload == null) break;
        payloads.add(continuationPayload);
        final nextToken = _extractContinuationToken(continuationPayload);
        if (nextToken == continuation) break;
        continuation = nextToken;
      }

      _appendCandidatesFromPayloads(
        payloads,
        currentVideo: currentVideo,
        selected: selected,
        seenIds: seenIds,
      );
    }
  }

  Set<String> _extractRecommendationPlaylistIds(dynamic node, {int depth = 0}) {
    if (depth > 18 || node == null) return const <String>{};
    final ids = <String>{};

    void maybeAdd(String? raw) {
      final id = (raw ?? '').trim();
      if (id.isEmpty) return;
      if (_looksLikeRecommendationPlaylistId(id)) {
        ids.add(id);
      }
    }

    if (node is Map) {
      final direct = node['playlistId'];
      if (direct is String) {
        maybeAdd(direct);
      }

      final watchPlaylistEndpoint = node['watchPlaylistEndpoint'];
      if (watchPlaylistEndpoint is Map) {
        final endpointId = watchPlaylistEndpoint['playlistId'];
        if (endpointId is String) {
          maybeAdd(endpointId);
        }
      }

      final watchEndpoint = node['watchEndpoint'];
      if (watchEndpoint is Map) {
        final endpointId = watchEndpoint['playlistId'];
        if (endpointId is String) {
          maybeAdd(endpointId);
        }
        final nestedPlaylistEndpoint = watchEndpoint['watchPlaylistEndpoint'];
        if (nestedPlaylistEndpoint is Map) {
          final nestedId = nestedPlaylistEndpoint['playlistId'];
          if (nestedId is String) {
            maybeAdd(nestedId);
          }
        }
      }

      for (final value in node.values) {
        ids.addAll(_extractRecommendationPlaylistIds(value, depth: depth + 1));
      }
    } else if (node is List) {
      for (final value in node) {
        ids.addAll(_extractRecommendationPlaylistIds(value, depth: depth + 1));
      }
    }

    return ids;
  }

  bool _looksLikeRecommendationPlaylistId(String playlistId) {
    final value = playlistId.trim();
    if (value.isEmpty) return false;
    if (value.startsWith('RDAMVM')) return true;
    if (value.startsWith('RDMM')) return true;
    if (value.startsWith('RD')) return true;
    if (value.startsWith('VLRD')) return true;
    return false;
  }

  Future<Map<String, dynamic>?> _fetchYoutubeMusicNextPayload({
    String? videoId,
    String? playlistId,
    String? continuation,
    required String clientName,
    required String clientVersion,
    required String headerClientName,
    required String userAgent,
  }) async {
    final normalizedVideoId = (videoId ?? '').trim();
    final normalizedPlaylistId = (playlistId ?? '').trim();
    final normalizedContinuation = (continuation ?? '').trim();
    final hasVideoId = normalizedVideoId.isNotEmpty;
    final hasPlaylistId = normalizedPlaylistId.isNotEmpty;
    final hasContinuation = normalizedContinuation.isNotEmpty;
    if (!hasVideoId && !hasPlaylistId && !hasContinuation) return null;

    final payload = <String, Object?>{
      'context': {
        'client': {
          'clientName': clientName,
          'clientVersion': clientVersion,
          'hl': 'es',
          'gl': 'US',
        },
        'request': {'useSsl': true},
      },
      'contentCheckOk': true,
      'racyCheckOk': true,
    };
    if (hasContinuation) {
      payload['continuation'] = normalizedContinuation;
    } else {
      if (hasVideoId) {
        payload['videoId'] = normalizedVideoId;
      }
      if (hasPlaylistId) {
        payload['playlistId'] = normalizedPlaylistId;
      }
      payload['isAudioOnly'] = true;
      payload['enablePersistentPlaylistPanel'] = true;
      payload['tunerSettingValue'] = 'AUTOMIX_SETTING_NORMAL';
    }

    final referer = hasVideoId
        ? 'https://music.youtube.com/watch?v=$normalizedVideoId'
        : (hasPlaylistId
              ? 'https://music.youtube.com/playlist?list=$normalizedPlaylistId'
              : 'https://music.youtube.com/');

    try {
      return await _runYoutubeWithRetry(
        () => _postYoutubeMusicNextRequest(
          payload: payload,
          userAgent: userAgent,
          clientVersion: clientVersion,
          headerClientName: headerClientName,
          referer: referer,
        ),
        maxAttempts: _isYoutubeSlowModeActive ? 3 : 2,
      );
    } catch (e, s) {
      log('No se pudo consultar YouTube Music next', error: e, stackTrace: s);
      return null;
    }
  }

  Future<Map<String, dynamic>?> _postYoutubeMusicNextRequest({
    required Map<String, Object?> payload,
    required String userAgent,
    required String clientVersion,
    required String headerClientName,
    required String referer,
  }) async {
    final client = HttpClient();
    try {
      final req = await client.postUrl(Uri.parse(_youtubeiMusicNextEndpoint));
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      req.headers.set(HttpHeaders.userAgentHeader, userAgent);
      _applyYoutubeCookieToRequest(req.headers);
      req.headers.set('Origin', 'https://music.youtube.com');
      req.headers.set('Referer', referer);
      req.headers.set('X-Youtube-Client-Name', headerClientName);
      req.headers.set('X-Youtube-Client-Version', clientVersion);
      req.add(utf8.encode(jsonEncode(payload)));

      final res = await req.close();
      if (res.statusCode == 429 || res.statusCode >= 500) {
        throw HttpException(
          'YouTube Music next temporalmente no disponible: ${res.statusCode}',
        );
      }
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final body = await utf8.decoder.bind(res).join();
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded.cast<dynamic, dynamic>());
      }
      return null;
    } finally {
      client.close(force: true);
    }
  }

  List<_YouTubeMusicQueueCandidate> _extractYoutubeMusicQueueCandidates(
    Map<String, dynamic> payload, {
    required Video currentVideo,
  }) {
    final candidates = <_YouTubeMusicQueueCandidate>[];
    final seen = <String>{};
    final playlistRenderers = <Map<String, dynamic>>[];
    _collectPlaylistPanelVideoRenderers(payload, playlistRenderers);

    for (final renderer in playlistRenderers) {
      final videoId = (renderer['videoId'] ?? '').toString().trim();
      if (videoId.isEmpty || videoId == currentVideo.id.value) continue;
      if (!seen.add(videoId)) continue;

      final title = _extractYoutubeText(renderer['title']);
      final artist =
          _extractYoutubeText(renderer['longBylineText']).trim().isNotEmpty
          ? _extractYoutubeText(renderer['longBylineText'])
          : (_extractYoutubeText(renderer['shortBylineText']).trim().isNotEmpty
                ? _extractYoutubeText(renderer['shortBylineText'])
                : _extractYoutubeText(renderer['subtitle']));
      final thumbnail =
          _extractBestThumbnailFromNode(renderer['thumbnail']) ??
          _defaultThumbnailForVideoId(videoId);
      final explicitFromRenderer = _containsExplicitMarker(renderer['badges']);

      candidates.add(
        _YouTubeMusicQueueCandidate(
          videoId: videoId,
          title: title.trim().isEmpty ? currentVideo.title : title.trim(),
          artist: artist.trim().isEmpty ? 'Artista desconocido' : artist.trim(),
          thumbnailUrl: thumbnail,
          isExplicit: explicitFromRenderer || _isExplicitText('$title $artist'),
        ),
      );
    }

    final musicResponsiveRenderers = <Map<String, dynamic>>[];
    _collectMusicResponsiveListItemRenderers(payload, musicResponsiveRenderers);
    for (final renderer in musicResponsiveRenderers) {
      final parsed = _parseMusicResponsiveCandidate(
        renderer,
        currentVideoId: currentVideo.id.value,
      );
      if (parsed == null) continue;
      if (!seen.add(parsed.videoId)) continue;
      candidates.add(parsed);
    }
    return candidates;
  }

  void _collectPlaylistPanelVideoRenderers(
    dynamic node,
    List<Map<String, dynamic>> out, {
    int depth = 0,
  }) {
    if (depth > 18) return;
    if (node is Map) {
      final renderer = node['playlistPanelVideoRenderer'];
      if (renderer is Map) {
        out.add(Map<String, dynamic>.from(renderer.cast<dynamic, dynamic>()));
      }
      for (final value in node.values) {
        _collectPlaylistPanelVideoRenderers(value, out, depth: depth + 1);
      }
      return;
    }
    if (node is List) {
      for (final item in node) {
        _collectPlaylistPanelVideoRenderers(item, out, depth: depth + 1);
      }
    }
  }

  void _collectMusicResponsiveListItemRenderers(
    dynamic node,
    List<Map<String, dynamic>> out, {
    int depth = 0,
  }) {
    if (depth > 20) return;
    if (node is Map) {
      final renderer = node['musicResponsiveListItemRenderer'];
      if (renderer is Map) {
        out.add(Map<String, dynamic>.from(renderer.cast<dynamic, dynamic>()));
      }
      for (final value in node.values) {
        _collectMusicResponsiveListItemRenderers(value, out, depth: depth + 1);
      }
      return;
    }
    if (node is List) {
      for (final item in node) {
        _collectMusicResponsiveListItemRenderers(item, out, depth: depth + 1);
      }
    }
  }

  _YouTubeMusicQueueCandidate? _parseMusicResponsiveCandidate(
    Map<String, dynamic> renderer, {
    required String currentVideoId,
  }) {
    final videoId = _extractVideoIdFromNode(renderer)?.trim() ?? '';
    if (videoId.isEmpty || videoId == currentVideoId) return null;

    final flexColumns = renderer['flexColumns'];
    String title = '';
    String artist = '';
    if (flexColumns is List) {
      final normalizedColumns = flexColumns
          .whereType<Map>()
          .map(
            (entry) =>
                Map<String, dynamic>.from(entry.cast<dynamic, dynamic>()),
          )
          .toList(growable: false);
      if (normalizedColumns.isNotEmpty) {
        final firstColumn = normalizedColumns
            .first['musicResponsiveListItemFlexColumnRenderer'];
        if (firstColumn is Map) {
          title = _extractYoutubeText(firstColumn['text']);
        }
      }
      if (normalizedColumns.length > 1) {
        final secondColumn =
            normalizedColumns[1]['musicResponsiveListItemFlexColumnRenderer'];
        if (secondColumn is Map) {
          artist = _extractYoutubeText(secondColumn['text']);
        }
      }
    }

    if (artist.trim().isNotEmpty && artist.contains('•')) {
      artist = artist.split('•').first.trim();
    }
    final thumbnail =
        _extractBestThumbnailFromNode(renderer['thumbnail']) ??
        _defaultThumbnailForVideoId(videoId);

    final fallbackTitle = _extractYoutubeText(renderer['title']);
    final effectiveTitle = title.trim().isNotEmpty
        ? title.trim()
        : (fallbackTitle.trim().isNotEmpty ? fallbackTitle.trim() : '');
    if (effectiveTitle.isEmpty) return null;

    final effectiveArtist = artist.trim().isNotEmpty
        ? artist.trim()
        : _extractYoutubeText(renderer['subtitle']).trim();

    return _YouTubeMusicQueueCandidate(
      videoId: videoId,
      title: effectiveTitle,
      artist: effectiveArtist.isEmpty ? 'Artista desconocido' : effectiveArtist,
      thumbnailUrl: thumbnail,
      isExplicit:
          _containsExplicitMarker(renderer['badges']) ||
          _isExplicitText('$effectiveTitle $effectiveArtist'),
    );
  }

  String? _extractVideoIdFromNode(dynamic node, {int depth = 0}) {
    if (depth > 12 || node == null) return null;
    if (node is Map) {
      final directVideoId = node['videoId'];
      if (directVideoId is String && directVideoId.trim().isNotEmpty) {
        return directVideoId.trim();
      }

      final watchEndpoint = node['watchEndpoint'];
      if (watchEndpoint is Map) {
        final endpointId = watchEndpoint['videoId'];
        if (endpointId is String && endpointId.trim().isNotEmpty) {
          return endpointId.trim();
        }
      }

      for (final value in node.values) {
        final nested = _extractVideoIdFromNode(value, depth: depth + 1);
        if (nested != null && nested.isNotEmpty) return nested;
      }
      return null;
    }
    if (node is List) {
      for (final value in node) {
        final nested = _extractVideoIdFromNode(value, depth: depth + 1);
        if (nested != null && nested.isNotEmpty) return nested;
      }
    }
    return null;
  }

  String _extractYoutubeText(dynamic node) {
    if (node == null) return '';
    if (node is String) return node.trim();
    if (node is Map) {
      final simpleText = node['simpleText'];
      if (simpleText is String && simpleText.trim().isNotEmpty) {
        return simpleText.trim();
      }
      final textValue = node['text'];
      if (textValue is String && textValue.trim().isNotEmpty) {
        return textValue.trim();
      }
      final runs = node['runs'];
      if (runs is List) {
        final parts = <String>[];
        for (final run in runs) {
          if (run is! Map) continue;
          final text = run['text'];
          if (text is String && text.trim().isNotEmpty) {
            parts.add(text.trim());
          }
        }
        if (parts.isNotEmpty) return parts.join('');
      }
    }
    return '';
  }

  String? _extractBestThumbnailFromNode(dynamic node) {
    if (node == null) return null;
    final preferLowResolution = _settingsService.dataSaverMode;
    if (node is Map) {
      final thumbs = node['thumbnails'];
      if (thumbs is List) {
        final ordered = preferLowResolution
            ? thumbs
            : thumbs.reversed.toList(growable: false);
        for (final item in ordered) {
          if (item is! Map) continue;
          final url = item['url'];
          if (url is String && url.trim().isNotEmpty) {
            return optimizeYoutubeThumbnailUrl(
              url.trim(),
              preferLowResolution: preferLowResolution,
            );
          }
        }
      }
      for (final value in node.values) {
        final nested = _extractBestThumbnailFromNode(value);
        if (nested != null && nested.isNotEmpty) return nested;
      }
      return null;
    }
    if (node is List) {
      for (final item in node) {
        final nested = _extractBestThumbnailFromNode(item);
        if (nested != null && nested.isNotEmpty) return nested;
      }
    }
    return null;
  }

  String? _extractContinuationToken(dynamic node, {int depth = 0}) {
    if (depth > 18) return null;
    if (node is Map) {
      final nextData = node['nextContinuationData'];
      if (nextData is Map) {
        final token = nextData['continuation'];
        if (token is String && token.trim().isNotEmpty) {
          return token.trim();
        }
      }
      final reloadData = node['reloadContinuationData'];
      if (reloadData is Map) {
        final token = reloadData['continuation'];
        if (token is String && token.trim().isNotEmpty) {
          return token.trim();
        }
      }
      final continuationCommand = node['continuationCommand'];
      if (continuationCommand is Map) {
        final token = continuationCommand['token'];
        if (token is String && token.trim().isNotEmpty) {
          return token.trim();
        }
      }
      for (final value in node.values) {
        final nested = _extractContinuationToken(value, depth: depth + 1);
        if (nested != null && nested.isNotEmpty) return nested;
      }
      return null;
    }
    if (node is List) {
      for (final item in node) {
        final nested = _extractContinuationToken(item, depth: depth + 1);
        if (nested != null && nested.isNotEmpty) return nested;
      }
    }
    return null;
  }

  bool _containsExplicitMarker(dynamic node) {
    final text = _collectYoutubeNodeText(node).toLowerCase();
    if (text.isEmpty) return false;
    return text.contains('explicit') ||
        text.contains('explícito') ||
        text.contains('explicito');
  }

  String _collectYoutubeNodeText(dynamic node, {int depth = 0}) {
    if (depth > 8 || node == null) return '';
    if (node is String) return node;
    if (node is Map) {
      final buffer = StringBuffer();
      for (final value in node.values) {
        final chunk = _collectYoutubeNodeText(value, depth: depth + 1);
        if (chunk.trim().isEmpty) continue;
        buffer
          ..write(' ')
          ..write(chunk);
      }
      return buffer.toString();
    }
    if (node is List) {
      final buffer = StringBuffer();
      for (final value in node) {
        final chunk = _collectYoutubeNodeText(value, depth: depth + 1);
        if (chunk.trim().isEmpty) continue;
        buffer
          ..write(' ')
          ..write(chunk);
      }
      return buffer.toString();
    }
    return '';
  }

  bool _isExplicitText(String text) {
    final normalized = text.toLowerCase();
    return _explicitKeywords.any(normalized.contains);
  }

  bool _isQueueArtistMonotone(List<PlaybackQueueItem> queue) {
    if (queue.length < 8) return false;
    final topSlice = queue.take(12).toList(growable: false);
    final artistCounts = <String, int>{};
    for (final item in topSlice) {
      final key = _normalizeArtistName(item.artist);
      if (key.isEmpty) continue;
      artistCounts[key] = (artistCounts[key] ?? 0) + 1;
    }
    if (artistCounts.isEmpty) return false;
    final topCount = artistCounts.values.reduce(math.max);
    final uniqueArtists = artistCounts.length;
    return topCount >= 5 || uniqueArtists <= 3;
  }

  List<PlaybackQueueItem> _diversifyQueueByArtist(
    List<PlaybackQueueItem> queue,
  ) {
    if (queue.length < 3) return queue;

    final groups = <String, List<PlaybackQueueItem>>{};
    final order = <String>[];
    for (final item in queue) {
      var key = _normalizeArtistName(item.artist);
      if (key.isEmpty) {
        key = item.artist.toLowerCase().trim();
      }
      if (key.isEmpty) {
        key = 'artist:${item.videoId}';
      }
      final existing = groups[key];
      if (existing == null) {
        groups[key] = <PlaybackQueueItem>[item];
        order.add(key);
      } else {
        existing.add(item);
      }
    }

    final result = <PlaybackQueueItem>[];
    final frontWindow = math.min(18, queue.length);
    const maxPerArtistAtFront = 3;
    final artistFrontCount = <String, int>{};

    while (result.length < queue.length) {
      var addedSomething = false;
      for (final key in order) {
        final bucket = groups[key];
        if (bucket == null || bucket.isEmpty) continue;
        if (result.length < frontWindow) {
          final used = artistFrontCount[key] ?? 0;
          if (used >= maxPerArtistAtFront) continue;
          artistFrontCount[key] = used + 1;
        }
        result.add(bucket.removeAt(0));
        addedSomething = true;
      }

      if (!addedSomething) {
        for (final key in order) {
          final bucket = groups[key];
          if (bucket == null || bucket.isEmpty) continue;
          result.add(bucket.removeAt(0));
        }
      }
    }

    return result;
  }

  String _defaultThumbnailForVideoId(String videoId) {
    final qualitySuffix = _settingsService.dataSaverMode
        ? 'mqdefault'
        : 'hqdefault';
    return 'https://i.ytimg.com/vi/$videoId/$qualitySuffix.jpg';
  }

  bool _isYoutubeVideoFrameThumbnail(String? url) {
    final value = url?.trim() ?? '';
    if (value.isEmpty) return false;
    try {
      final uri = Uri.parse(value);
      final host = uri.host.toLowerCase();
      if (!host.contains('ytimg.com') && !host.contains('youtube.com')) {
        return false;
      }
      final path = uri.path.toLowerCase();
      return path.contains('/vi/') || path.contains('/vi_webp/');
    } catch (_) {
      return false;
    }
  }

  bool _isLikelyYoutubeMusicSquareThumbnail(String? url) {
    final value = url?.trim() ?? '';
    if (value.isEmpty) return false;
    try {
      final uri = Uri.parse(value);
      final host = uri.host.toLowerCase();
      final isMusicLikeHost =
          host.contains('googleusercontent.com') ||
          host.contains('ggpht.com') ||
          host.contains('yt3.ggpht.com');
      if (!isMusicLikeHost) return false;

      final full = '$value ${uri.path}';
      final match = RegExp(
        r'w(\d+)-h(\d+)',
        caseSensitive: false,
      ).firstMatch(full);
      if (match != null) {
        final w = int.tryParse(match.group(1) ?? '');
        final h = int.tryParse(match.group(2) ?? '');
        if (w != null && h != null && w > 0 && h > 0) {
          return (w - h).abs() <= 2;
        }
      }

      final wq = int.tryParse(uri.queryParameters['w'] ?? '');
      final hq = int.tryParse(uri.queryParameters['h'] ?? '');
      if (wq != null && hq != null && wq > 0 && hq > 0) {
        return (wq - hq).abs() <= 2;
      }

      return true;
    } catch (_) {
      return false;
    }
  }

  String? _mergeThumbnailKeepingMusicSquare({
    required String? existing,
    required String? candidate,
  }) {
    final current = existing?.trim() ?? '';
    final next = candidate?.trim() ?? '';
    if (next.isEmpty) return current.isEmpty ? null : current;
    if (current.isEmpty) return next;
    if (_isLikelyYoutubeMusicSquareThumbnail(current) &&
        _isYoutubeVideoFrameThumbnail(next)) {
      return current;
    }
    return next;
  }

  Future<List<PlaybackQueueItem>> _buildRelatedQueueFromYoutubeFallback(
    Video currentVideo, {
    required Set<String> excludeIds,
  }) async {
    final candidates = <Video>[];
    List<Video>? related;

    try {
      related = await _runYoutubeWithRetry(
        () => _ytExplode.videos.getRelatedVideos(currentVideo),
        maxAttempts: 2,
      );
    } catch (e, s) {
      log('Fallback related videos falló', error: e, stackTrace: s);
    }

    final firstHopIds = <String>{};
    final secondHopCoOccurrence = <String, int>{};
    if (related != null && related.isNotEmpty) {
      firstHopIds.addAll(related.map((item) => item.id.value));
      candidates.addAll(related.take(50));
    }

    final similarArtists = _buildSimilarArtistCandidates(
      primaryArtist: currentVideo.author,
      relatedVideos: related ?? const [],
    );
    final recommendationSignals = _buildRecommendationSignals(
      primaryArtist: currentVideo.author,
      currentTitle: currentVideo.title,
      relatedVideos: related ?? const [],
    );

    if (related != null && related.isNotEmpty) {
      final secondHop = await _collectSecondHopRelatedCandidates(
        currentVideo: currentVideo,
        firstHopRelated: related,
        signals: recommendationSignals,
      );
      candidates.addAll(secondHop.$1);
      for (final entry in secondHop.$2.entries) {
        secondHopCoOccurrence[entry.key] =
            (secondHopCoOccurrence[entry.key] ?? 0) + entry.value;
      }
    }

    if (candidates.length < 10) {
      final searchFallback = await _collectCurrentTrackFallbackCandidates(
        currentVideo,
      );
      candidates.addAll(searchFallback);
    }
    if (candidates.isEmpty && related != null && related.isNotEmpty) {
      candidates.addAll(related);
    }
    if (candidates.isEmpty) return const <PlaybackQueueItem>[];

    final expandedSimilarArtists = <String>{
      ...similarArtists.map(_normalizeArtistName),
      ...recommendationSignals.coListenArtists.map(_normalizeArtistName),
    }.where((value) => value.isNotEmpty).toList(growable: false);

    final smartQueue = _buildSmartQueue(
      candidates,
      currentVideoId: currentVideo.id.value,
      currentTitle: currentVideo.title,
      primaryArtist: currentVideo.author,
      relatedArtistHints: expandedSimilarArtists,
      signals: recommendationSignals,
      firstHopRelatedIds: firstHopIds,
      secondHopCoOccurrence: secondHopCoOccurrence,
    );
    final seenIds = Set<String>.from(excludeIds);
    final filteredSmartQueue = smartQueue
        .where((item) => seenIds.add(item.videoId))
        .toList(growable: false);

    if (filteredSmartQueue.length >= 22) {
      return _diversifyQueueByArtist(
        filteredSmartQueue,
      ).take(30).toList(growable: false);
    }

    final merged = <PlaybackQueueItem>[
      ...filteredSmartQueue,
      ..._buildLooseFallbackQueueFromCandidates(
        candidates,
        currentVideoId: currentVideo.id.value,
        seenIds: seenIds,
      ),
    ];
    return _diversifyQueueByArtist(merged).take(30).toList(growable: false);
  }

  List<PlaybackQueueItem> _buildLooseFallbackQueueFromCandidates(
    Iterable<Video> source, {
    required String currentVideoId,
    required Set<String> seenIds,
  }) {
    final sorted = source.toList(
      growable: false,
    )..sort((a, b) => b.engagement.viewCount.compareTo(a.engagement.viewCount));

    final queue = <PlaybackQueueItem>[];
    for (final item in sorted) {
      final id = item.id.value;
      if (id == currentVideoId) continue;
      if (!seenIds.add(id)) continue;
      if (_sessionPlayedVideoIds.contains(id)) continue;
      if (!_isLikelyMusicCandidate(item)) continue;
      if (!_settingsService.allowExplicitContent && _isExplicitTrack(item)) {
        continue;
      }
      queue.add(
        PlaybackQueueItem(
          videoId: id,
          title: item.title,
          thumbnailUrl: _bestThumbnailUrl(item),
          artist: cleanArtistName(item.author),
          isLocal: false,
        ),
      );
      if (queue.length >= 24) break;
    }
    return queue;
  }

  bool _isLikelyMusicCandidate(Video item) {
    final text = '${item.title} ${item.author} ${item.description}'
        .toLowerCase();
    if (_nonSongKeywords.any(text.contains)) return false;
    final duration = item.duration;
    if (duration != null) {
      final seconds = duration.inSeconds;
      if (seconds < 55 || seconds > 900) return false;
    }
    return true;
  }

  Future<List<PlaybackQueueItem>> _buildYoutubeMusicRadioPlaylistFallback(
    Video currentVideo, {
    required Set<String> excludeIds,
  }) async {
    final seenIds = Set<String>.from(excludeIds);
    final queue = <PlaybackQueueItem>[];
    final playlistIds = <String>[
      'RDAMVM${currentVideo.id.value}',
      'RDMM${currentVideo.id.value}',
    ];

    for (final playlistId in playlistIds) {
      List<Video> videos;
      try {
        videos = await _runYoutubeWithRetry(
          () async => _ytExplode.playlists
              .getVideos(PlaylistId(playlistId))
              .take(90)
              .toList(),
          maxAttempts: 2,
        );
      } catch (e, s) {
        log(
          'Fallback radio playlist falló: $playlistId',
          error: e,
          stackTrace: s,
        );
        continue;
      }

      for (final item in videos) {
        final id = item.id.value;
        if (id == currentVideo.id.value) continue;
        if (!seenIds.add(id)) continue;
        if (_sessionPlayedVideoIds.contains(id)) continue;
        if (!_isLikelyMusicCandidate(item)) continue;
        if (!_settingsService.allowExplicitContent && _isExplicitTrack(item)) {
          continue;
        }
        queue.add(
          PlaybackQueueItem(
            videoId: id,
            title: item.title,
            thumbnailUrl: _bestThumbnailUrl(item),
            artist: cleanArtistName(item.author),
            isLocal: false,
          ),
        );
        if (queue.length >= 30) break;
      }
      if (queue.length >= 30) break;
    }

    return _diversifyQueueByArtist(queue).take(30).toList(growable: false);
  }

  List<PlaybackQueueItem> _buildSmartQueue(
    Iterable<Video> source, {
    required String currentVideoId,
    required String currentTitle,
    required String primaryArtist,
    required List<String> relatedArtistHints,
    required _RecommendationSignals signals,
    required Set<String> firstHopRelatedIds,
    required Map<String, int> secondHopCoOccurrence,
  }) {
    final normalizedPrimary = _normalizeArtistName(primaryArtist);
    final similarArtists = relatedArtistHints
        .map(_normalizeArtistName)
        .where((value) => value.isNotEmpty)
        .toSet();
    similarArtists.remove(normalizedPrimary);
    final discoveryArtists = signals.coListenArtists
        .map(_normalizeArtistName)
        .where(
          (value) =>
              value.isNotEmpty &&
              value != normalizedPrimary &&
              !similarArtists.contains(value),
        )
        .take(10)
        .toSet();
    final hasStrongSignalContext =
        signals.coListenArtists.isNotEmpty ||
        signals.genreTokens.isNotEmpty ||
        signals.relatedTitleTokens.isNotEmpty ||
        firstHopRelatedIds.isNotEmpty ||
        secondHopCoOccurrence.isNotEmpty;
    final filtered = source
        .where((item) => item.id.value != currentVideoId)
        .where((item) => !_sessionPlayedVideoIds.contains(item.id.value))
        .where(_isPureYoutubeMusicAudio)
        .where((item) {
          final id = item.id.value;
          if (firstHopRelatedIds.contains(id)) return true;
          if (!hasStrongSignalContext) return true;
          final secondHopCount = secondHopCoOccurrence[id] ?? 0;
          return _passesRecommendationAnchor(
            item,
            signals,
            secondHopCount: secondHopCount,
          );
        })
        .where(
          (item) =>
              _settingsService.allowExplicitContent || !_isExplicitTrack(item),
        )
        .toList();

    bool isStronglyRelated(Video item) {
      final id = item.id.value;
      if (firstHopRelatedIds.contains(id)) return true;
      if ((secondHopCoOccurrence[id] ?? 0) >= 1) return true;
      if (_hasCoListenAuthorMatch(item.author, signals)) return true;
      return false;
    }

    final strongFiltered = filtered
        .where(isStronglyRelated)
        .toList(growable: false);
    final workingSet = strongFiltered.length >= 12 ? strongFiltered : filtered;

    final tier0 = <Video>[];
    final tier1 = <Video>[];
    final tier2 = <Video>[];
    final tier3 = <Video>[];
    for (final item in workingSet) {
      final tier = _artistPriorityTier(
        author: item.author,
        normalizedPrimary: normalizedPrimary,
        similarArtists: similarArtists,
        discoveryArtists: discoveryArtists,
      );
      if (tier == 0) {
        tier0.add(item);
      } else if (tier == 1) {
        tier1.add(item);
      } else if (tier == 2) {
        tier2.add(item);
      } else {
        tier3.add(item);
      }
    }

    void sortByScore(List<Video> list) {
      list.sort((a, b) {
        final scoreA = _recommendationScore(
          a,
          signals,
          isFirstHop: firstHopRelatedIds.contains(a.id.value),
          secondHopCount: secondHopCoOccurrence[a.id.value] ?? 0,
          wasRecentlyRecommended: _recentRecommendedVideoIds.contains(
            a.id.value,
          ),
        );
        final scoreB = _recommendationScore(
          b,
          signals,
          isFirstHop: firstHopRelatedIds.contains(b.id.value),
          secondHopCount: secondHopCoOccurrence[b.id.value] ?? 0,
          wasRecentlyRecommended: _recentRecommendedVideoIds.contains(
            b.id.value,
          ),
        );
        return scoreB.compareTo(scoreA);
      });
    }

    sortByScore(tier0);
    sortByScore(tier1);
    sortByScore(tier2);
    sortByScore(tier3);
    final ordered = <Video>[];
    const warmupTarget = 10;
    final warmup = <Video>[];
    final warmupIds = <String>{};

    bool hasGenreMatch(Video item) {
      if (signals.genreTokens.isEmpty) return false;
      final text =
          '${item.title.toLowerCase()} ${item.author.toLowerCase()} ${item.description.toLowerCase()}';
      for (final token in signals.genreTokens.take(8)) {
        if (token.length < 3) continue;
        if (text.contains(token)) return true;
      }
      return false;
    }

    void addWarmup(Iterable<Video> source, {required int maxFromSource}) {
      var taken = 0;
      for (final item in source) {
        if (warmup.length >= warmupTarget) return;
        if (taken >= maxFromSource) return;
        final id = item.id.value;
        if (!warmupIds.add(id)) continue;
        warmup.add(item);
        taken += 1;
      }
    }

    // Inicio tipo "radio": artistas similares + co-listen + mismo genero.
    addWarmup(tier0, maxFromSource: 6);
    addWarmup(tier2, maxFromSource: 4);
    addWarmup(tier3.where(hasGenreMatch), maxFromSource: 4);
    if (warmup.length < warmupTarget) {
      addWarmup(tier0, maxFromSource: warmupTarget);
    }
    if (warmup.length < warmupTarget) {
      addWarmup(tier2, maxFromSource: warmupTarget);
    }

    ordered.addAll(warmup);

    final buckets = <List<Video>>[
      tier0
          .where((item) => !warmupIds.contains(item.id.value))
          .toList(growable: false),
      tier2
          .where((item) => !warmupIds.contains(item.id.value))
          .toList(growable: false),
      tier1
          .where((item) => !warmupIds.contains(item.id.value))
          .toList(growable: false),
      tier3
          .where((item) => !warmupIds.contains(item.id.value))
          .toList(growable: false),
    ];
    final bucketIndex = List<int>.filled(buckets.length, 0);
    var keepMixing = true;
    while (keepMixing) {
      keepMixing = false;
      for (var i = 0; i < buckets.length; i++) {
        final bucket = buckets[i];
        final idx = bucketIndex[i];
        if (idx >= bucket.length) continue;
        ordered.add(bucket[idx]);
        bucketIndex[i] = idx + 1;
        keepMixing = true;
      }
    }

    final seenIds = <String>{};
    final seenNormalizedTitles = <String>{};
    final seenNormalizedLabels = <String>{};
    final keptNormalizedTitles = <String>[];
    final keptNormalizedLabels = <String>[];
    final normalizedCurrentTitle = _normalizeTitleForQueueDedup(currentTitle);
    final currentTitleTokens = normalizedCurrentTitle
        .split(' ')
        .where((token) => token.length >= 3)
        .where((token) => !_queueTokenStopwords.contains(token))
        .toSet();
    final artistUsage = <String, int>{};
    var acceptedSimilar = 0;
    var acceptedPrimary = 0;
    var acceptedDiscovery = 0;
    var acceptedExplore = 0;
    final output = <PlaybackQueueItem>[];

    for (final item in ordered) {
      final id = item.id.value;
      if (!seenIds.add(id)) continue;
      final tier = _artistPriorityTier(
        author: item.author,
        normalizedPrimary: normalizedPrimary,
        similarArtists: similarArtists,
        discoveryArtists: discoveryArtists,
      );
      if (tier == 0 && acceptedSimilar >= 14) continue;
      if (tier == 1 && acceptedPrimary >= 4) continue;
      if (tier == 2 && acceptedDiscovery >= 12) continue;
      if (tier == 3 && acceptedExplore >= 10) continue;
      final normalizedArtist = _normalizeArtistName(item.author);
      if (normalizedArtist.isNotEmpty) {
        final usage = artistUsage[normalizedArtist] ?? 0;
        final maxUsagePerArtist = tier == 1 ? 2 : 4;
        if (usage >= maxUsagePerArtist) continue;
        artistUsage[normalizedArtist] = usage + 1;
      }

      final normalizedTitle = _normalizeTitleForQueueDedup(item.title);
      final normalizedLabel = _normalizeTitleForQueueDedup(
        '${item.title} ${item.author}',
      );
      if (_looksLikeCurrentTrackClone(
        candidateLabel: normalizedLabel,
        normalizedCurrentTitle: normalizedCurrentTitle,
        currentTitleTokens: currentTitleTokens,
      )) {
        continue;
      }
      if (normalizedTitle.isNotEmpty) {
        if (_isSimilarQueueTitle(normalizedTitle, normalizedCurrentTitle)) {
          continue;
        }
        var tooSimilarToExisting = false;
        for (final kept in keptNormalizedTitles) {
          if (_isSimilarQueueTitle(normalizedTitle, kept)) {
            tooSimilarToExisting = true;
            break;
          }
        }
        if (tooSimilarToExisting ||
            !seenNormalizedTitles.add(normalizedTitle)) {
          continue;
        }
        keptNormalizedTitles.add(normalizedTitle);
      }
      if (normalizedLabel.isNotEmpty) {
        if (_isSimilarQueueTitle(normalizedLabel, normalizedCurrentTitle)) {
          continue;
        }
        var tooSimilarLabel = false;
        for (final kept in keptNormalizedLabels) {
          if (_isSimilarQueueTitle(normalizedLabel, kept)) {
            tooSimilarLabel = true;
            break;
          }
        }
        if (tooSimilarLabel || !seenNormalizedLabels.add(normalizedLabel)) {
          continue;
        }
        keptNormalizedLabels.add(normalizedLabel);
      }

      output.add(
        PlaybackQueueItem(
          videoId: id,
          title: item.title,
          thumbnailUrl: _bestThumbnailUrl(item),
          artist: cleanArtistName(item.author),
          isLocal: false,
        ),
      );
      if (tier == 0) {
        acceptedSimilar++;
      } else if (tier == 1) {
        acceptedPrimary++;
      } else if (tier == 2) {
        acceptedDiscovery++;
      } else {
        acceptedExplore++;
      }

      if (output.length >= 30) break;
    }

    if (output.length < 12) {
      final rescuePool = filtered.toList(growable: false)
        ..sort((a, b) {
          final scoreA = _recommendationScore(
            a,
            signals,
            isFirstHop: firstHopRelatedIds.contains(a.id.value),
            secondHopCount: secondHopCoOccurrence[a.id.value] ?? 0,
            wasRecentlyRecommended: _recentRecommendedVideoIds.contains(
              a.id.value,
            ),
          );
          final scoreB = _recommendationScore(
            b,
            signals,
            isFirstHop: firstHopRelatedIds.contains(b.id.value),
            secondHopCount: secondHopCoOccurrence[b.id.value] ?? 0,
            wasRecentlyRecommended: _recentRecommendedVideoIds.contains(
              b.id.value,
            ),
          );
          return scoreB.compareTo(scoreA);
        });

      for (final item in rescuePool) {
        if (output.length >= 30) break;
        final id = item.id.value;
        if (!seenIds.add(id)) continue;

        final normalizedTitle = _normalizeTitleForQueueDedup(item.title);
        final normalizedLabel = _normalizeTitleForQueueDedup(
          '${item.title} ${item.author}',
        );
        if (_looksLikeCurrentTrackClone(
          candidateLabel: normalizedLabel,
          normalizedCurrentTitle: normalizedCurrentTitle,
          currentTitleTokens: currentTitleTokens,
        )) {
          continue;
        }
        if (normalizedTitle.isNotEmpty &&
            !seenNormalizedTitles.add(normalizedTitle)) {
          continue;
        }
        if (normalizedLabel.isNotEmpty &&
            !seenNormalizedLabels.add(normalizedLabel)) {
          continue;
        }

        output.add(
          PlaybackQueueItem(
            videoId: id,
            title: item.title,
            thumbnailUrl: _bestThumbnailUrl(item),
            artist: cleanArtistName(item.author),
            isLocal: false,
          ),
        );
      }
    }

    // Failsafe final: si por filtros estrictos seguimos en vacío,
    // rellenamos con candidatos mínimos válidos del source actual.
    if (output.isEmpty) {
      for (final item in source) {
        if (output.length >= 20) break;
        final id = item.id.value;
        if (id == currentVideoId) continue;
        if (_sessionPlayedVideoIds.contains(id)) continue;
        if (!_isPureYoutubeMusicAudio(item)) continue;
        if (!_settingsService.allowExplicitContent && _isExplicitTrack(item)) {
          continue;
        }
        if (!seenIds.add(id)) continue;

        final normalizedLabel = _normalizeTitleForQueueDedup(
          '${item.title} ${item.author}',
        );
        if (normalizedLabel.isNotEmpty &&
            !seenNormalizedLabels.add(normalizedLabel)) {
          continue;
        }
        output.add(
          PlaybackQueueItem(
            videoId: id,
            title: item.title,
            thumbnailUrl: _bestThumbnailUrl(item),
            artist: cleanArtistName(item.author),
            isLocal: false,
          ),
        );
      }
    }

    return output;
  }

  int _artistPriorityTier({
    required String author,
    required String normalizedPrimary,
    required Set<String> similarArtists,
    required Set<String> discoveryArtists,
  }) {
    final normalizedAuthor = _normalizeArtistName(author);
    if (normalizedAuthor.isNotEmpty) {
      if (_matchesArtistGroup(normalizedAuthor, similarArtists)) return 0;
      if (_matchesArtistGroup(normalizedAuthor, {normalizedPrimary})) return 1;
      if (_matchesArtistGroup(normalizedAuthor, discoveryArtists)) return 2;
    }
    return 3;
  }

  bool _matchesArtistGroup(String normalizedAuthor, Set<String> group) {
    for (final artist in group) {
      if (artist.isEmpty) continue;
      if (normalizedAuthor.contains(artist) ||
          artist.contains(normalizedAuthor)) {
        return true;
      }
    }
    return false;
  }

  List<String> _buildSimilarArtistCandidates({
    required String primaryArtist,
    required List<Video> relatedVideos,
  }) {
    final normalizedPrimary = _normalizeArtistName(primaryArtist);
    final scores = <String, int>{};

    void addScore(String rawArtist, int score) {
      final normalized = _normalizeArtistName(rawArtist);
      if (normalized.isEmpty || normalized == normalizedPrimary) return;
      scores[normalized] = (scores[normalized] ?? 0) + score;
    }

    final topRelatedTopicAuthors = _extractTopRelatedTopicAuthors(
      relatedVideos: relatedVideos,
      normalizedPrimaryArtist: normalizedPrimary,
      limit: 10,
    );
    var relatedWeight = 170;
    for (final artist in topRelatedTopicAuthors) {
      addScore(artist, relatedWeight);
      if (relatedWeight > 88) relatedWeight -= 12;
    }

    for (final video in relatedVideos.take(50)) {
      if (!_isPureYoutubeMusicAudio(video)) continue;
      final boost = _isTopicAuthor(video.author.toLowerCase()) ? 74 : 52;
      addScore(video.author, boost);
    }

    final sorted = scores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.map((e) => e.key).take(12).toList();
  }

  List<String> _extractTopRelatedTopicAuthors({
    required List<Video> relatedVideos,
    required String normalizedPrimaryArtist,
    required int limit,
  }) {
    final counter = <String, int>{};
    for (final video in relatedVideos.take(70)) {
      final authorRaw = video.author.toLowerCase().trim();
      if (!_isTopicAuthor(authorRaw) ||
          _isBlockedRecommendationAuthor(authorRaw)) {
        continue;
      }
      if (!_isPureYoutubeMusicAudio(video)) continue;
      final normalized = _normalizeArtistName(video.author);
      if (normalized.isEmpty || normalized == normalizedPrimaryArtist) continue;
      counter[normalized] = (counter[normalized] ?? 0) + 1;
    }
    final sorted = counter.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.map((e) => e.key).take(limit).toList();
  }

  bool _passesRecommendationAnchor(
    Video item,
    _RecommendationSignals signals, {
    required int secondHopCount,
  }) {
    final noSignals =
        signals.coListenArtists.isEmpty &&
        signals.genreTokens.isEmpty &&
        signals.relatedTitleTokens.isEmpty;
    if (noSignals) return true;
    if (secondHopCount >= 1) return true;

    final title = item.title.toLowerCase();
    final author = item.author.toLowerCase();
    final description = item.description.toLowerCase();
    final text = '$title $author $description';

    final hasCoListenAuthor = signals.coListenArtists.take(8).any((artist) {
      if (artist.length < 3) return false;
      return author.contains(artist);
    });
    if (hasCoListenAuthor) return true;

    var genreHits = 0;
    for (final token in signals.genreTokens.take(8)) {
      if (token.length < 3) continue;
      if (text.contains(token)) genreHits += 1;
    }

    var relatedTitleHits = 0;
    for (final token in signals.relatedTitleTokens.take(8)) {
      if (token.length < 3) continue;
      if (title.contains(token)) relatedTitleHits += 1;
    }

    if (genreHits >= 2 && relatedTitleHits >= 1) return true;
    return false;
  }

  bool _hasCoListenAuthorMatch(
    String authorRaw,
    _RecommendationSignals signals,
  ) {
    final normalizedAuthor = _normalizeArtistName(authorRaw);
    if (normalizedAuthor.isEmpty) return false;
    for (final artist in signals.coListenArtists.take(10)) {
      if (artist.length < 3) continue;
      if (normalizedAuthor.contains(artist) ||
          artist.contains(normalizedAuthor)) {
        return true;
      }
    }
    return false;
  }

  Future<(List<Video>, Map<String, int>)> _collectSecondHopRelatedCandidates({
    required Video currentVideo,
    required List<Video> firstHopRelated,
    required _RecommendationSignals signals,
  }) async {
    if (firstHopRelated.isEmpty) {
      return (const <Video>[], const <String, int>{});
    }

    final seeds = firstHopRelated
        .where(_isPureYoutubeMusicAudio)
        .where((item) => item.id.value != currentVideo.id.value)
        .toList(growable: false);
    if (seeds.isEmpty) return (const <Video>[], const <String, int>{});

    int seedScore(Video item) {
      final text =
          '${item.title.toLowerCase()} ${item.author.toLowerCase()} ${item.description.toLowerCase()}';
      var score = 0;
      if (_isTopicAuthor(item.author.toLowerCase())) score += 140;
      if (_hasAutoGeneratedSignal(item)) score += 120;
      for (final token in signals.genreTokens.take(6)) {
        if (text.contains(token)) score += 30;
      }
      for (final artist in signals.coListenArtists.take(6)) {
        if (item.author.toLowerCase().contains(artist)) score += 70;
      }
      final views = item.engagement.viewCount;
      if (views > 0) score += (views / 300000).floor().clamp(0, 45);
      return score;
    }

    final rankedSeeds = seeds.toList()
      ..sort((a, b) => seedScore(b) - seedScore(a));
    final selectedSeeds = rankedSeeds.take(6).toList(growable: false);

    Future<(List<Video>, Map<String, int>)> fetchFromSeed(Video seed) async {
      try {
        final related = await _runYoutubeWithRetry(
          () => _ytExplode.videos.getRelatedVideos(seed),
          maxAttempts: 1,
        ).timeout(const Duration(seconds: 8));
        final collected = <Video>[];
        final coOccurrence = <String, int>{};
        for (final video in (related ?? const <Video>[]).take(24)) {
          final id = video.id.value;
          if (id == currentVideo.id.value || id == seed.id.value) continue;
          if (!_isPureYoutubeMusicAudio(video)) continue;
          collected.add(video);
          coOccurrence[id] = (coOccurrence[id] ?? 0) + 1;
        }
        return (collected, coOccurrence);
      } catch (_) {
        return (const <Video>[], const <String, int>{});
      }
    }

    final batches = await Future.wait(selectedSeeds.map(fetchFromSeed));
    final merged = <Video>[];
    final mergedCoOccurrence = <String, int>{};
    for (final batch in batches) {
      merged.addAll(batch.$1);
      for (final entry in batch.$2.entries) {
        mergedCoOccurrence[entry.key] =
            (mergedCoOccurrence[entry.key] ?? 0) + entry.value;
      }
    }

    return (merged, mergedCoOccurrence);
  }

  Future<List<Video>> _collectCurrentTrackFallbackCandidates(
    Video currentVideo,
  ) async {
    final queries = <Future<List<Video>>>[];
    final titleTokens = _extractRecommendationTokens(
      currentVideo.title,
      max: 4,
    );
    final artist = currentVideo.author.trim();

    if (artist.isNotEmpty) {
      queries.add(
        _safeSearchVideos('$artist topic', limit: 24, onlyTopic: true),
      );
      queries.add(
        _safeSearchVideos(
          '$artist provided to youtube by',
          limit: 20,
          onlyAutoGenerated: true,
        ),
      );
    }
    for (final token in titleTokens) {
      if (artist.isNotEmpty) {
        queries.add(
          _safeSearchVideos('$artist $token topic', limit: 12, onlyTopic: true),
        );
      }
    }
    if (queries.isEmpty) return const <Video>[];

    final batches = await Future.wait(queries.take(10));
    final seen = <String>{};
    final merged = <Video>[];
    for (final batch in batches) {
      for (final item in batch) {
        final id = item.id.value;
        if (!seen.add(id)) continue;
        if (!_isPureYoutubeMusicAudio(item)) continue;
        merged.add(item);
      }
    }
    return merged;
  }

  int _recommendationScore(
    Video item,
    _RecommendationSignals signals, {
    required bool isFirstHop,
    required int secondHopCount,
    required bool wasRecentlyRecommended,
  }) {
    final title = item.title.toLowerCase();
    final author = item.author.toLowerCase();
    final description = item.description.toLowerCase();
    final text = '$title $author $description';
    var score = 0;

    final isTopic = _isTopicAuthor(author);
    final isAutoGenerated = _hasAutoGeneratedSignal(item);
    if (isTopic) score += 280;
    if (isAutoGenerated) score += 220;
    if (isFirstHop) score += 950;
    if (secondHopCount > 0) {
      score += (secondHopCount * 220).clamp(0, 1400);
    }
    if (!isFirstHop && secondHopCount == 0) {
      score -= 260;
    }
    if (wasRecentlyRecommended) {
      score -= 700;
    }

    for (final token in signals.genreTokens.take(8)) {
      if (token.length < 3) continue;
      if (text.contains(token)) score += 42;
    }

    var matchedCoListenArtists = 0;
    for (final artist in signals.coListenArtists.take(8)) {
      if (artist.length < 3) continue;
      if (author.contains(artist)) {
        score += isTopic ? 220 : 130;
        matchedCoListenArtists += 1;
      }
      if (title.contains(artist)) {
        score += 86;
        matchedCoListenArtists += 1;
      }
    }

    final hasStrongCoreMatch = matchedCoListenArtists >= 1;
    if (!hasStrongCoreMatch) {
      // Penaliza resultados con poco match real contra la canción actual.
      score -= 460;
    }

    score += _musicKeywordScore(title, author);

    final views = item.engagement.viewCount;
    if (views > 0) {
      score += (views / 100000).floor().clamp(0, 500);
    }

    return score;
  }

  int _musicKeywordScore(String title, String author) {
    final text = '$title $author';
    var score = 0;
    for (final keyword in _musicKeywords) {
      if (text.contains(keyword)) score += 25;
    }
    return score;
  }

  bool _isExplicitTrack(Video item) {
    final text = '${item.title} ${item.author} ${item.description}'
        .toLowerCase();
    return _explicitKeywords.any(text.contains);
  }

  bool _isPureYoutubeMusicAudio(Video item) {
    final author = item.author.toLowerCase().trim();
    if (_isBlockedRecommendationAuthor(author)) return false;
    final title = item.title.toLowerCase();
    final description = item.description.toLowerCase();
    final text = '$title $author $description';
    if (_nonSongKeywords.any(text.contains)) return false;

    final duration = item.duration;
    if (duration != null) {
      final seconds = duration.inSeconds;
      if (seconds < 70 || seconds > 660) return false;
    }

    final topic = _isTopicAuthor(author);
    final autoGenerated = _hasAutoGeneratedSignal(item);
    final hasVideoLikeSignal = _videoLikeKeywords.any(text.contains);
    return (topic || autoGenerated) && !hasVideoLikeSignal;
  }

  bool _hasAutoGeneratedSignal(Video item) {
    final title = item.title.toLowerCase();
    final description = item.description.toLowerCase();
    return _autoGeneratedKeywords.any((keyword) {
      return title.contains(keyword) || description.contains(keyword);
    });
  }

  bool _isTopicAuthor(String authorLower) {
    final author = authorLower.trim();
    return author.endsWith('- topic') || author.endsWith('topic');
  }

  bool _isBlockedRecommendationAuthor(String authorLower) {
    final author = authorLower.trim();
    return author == 'release - topic' || author == 'release topic';
  }

  String _bestThumbnailUrl(Video video) {
    return bestThumbnailForVideo(
      video,
      preferLowResolution: _settingsService.dataSaverMode,
    );
  }

  String _normalizeTitleForQueueDedup(String title) {
    var normalized = title.toLowerCase();
    normalized = normalized.replaceAll(RegExp(r'\s*[\(\[\{].*?[\)\]\}]'), ' ');
    normalized = normalized.replaceAll(
      RegExp(
        r'\b(official|video|audio|lyric|lyrics|visualizer|live|session|en vivo|remix|feat\.?|ft\.?)\b',
      ),
      ' ',
    );
    normalized = normalized.replaceAll(RegExp(r'[^a-z0-9\s]'), ' ');
    normalized = normalized.replaceAll(RegExp(r'\s+'), ' ').trim();
    return normalized;
  }

  bool _isSimilarQueueTitle(String a, String b) {
    final left = a.trim();
    final right = b.trim();
    if (left.isEmpty || right.isEmpty) return false;
    if (left == right) return true;
    if (left.length >= 8 && right.length >= 8) {
      if (left.contains(right) || right.contains(left)) return true;
    }

    Set<String> tokens(String value) {
      return value
          .split(' ')
          .where((token) => token.length >= 3)
          .where((token) => !_queueTokenStopwords.contains(token))
          .toSet();
    }

    final leftTokens = tokens(left);
    final rightTokens = tokens(right);
    if (leftTokens.isEmpty || rightTokens.isEmpty) return false;

    var overlap = 0;
    for (final token in leftTokens) {
      if (rightTokens.contains(token)) overlap += 1;
    }
    if (overlap == 0) return false;

    final overlapLeft = overlap / leftTokens.length;
    final overlapRight = overlap / rightTokens.length;
    if (overlap >= 2 && (overlapLeft >= 0.75 || overlapRight >= 0.75)) {
      return true;
    }
    if (leftTokens.length <= 3 && rightTokens.length <= 3 && overlap >= 2) {
      return true;
    }
    return false;
  }

  bool _looksLikeCurrentTrackClone({
    required String candidateLabel,
    required String normalizedCurrentTitle,
    required Set<String> currentTitleTokens,
  }) {
    if (candidateLabel.isEmpty || normalizedCurrentTitle.isEmpty) return false;
    if (_isSimilarQueueTitle(candidateLabel, normalizedCurrentTitle)) {
      return true;
    }

    final candidateTokens = candidateLabel
        .split(' ')
        .where((token) => token.length >= 3)
        .where((token) => !_queueTokenStopwords.contains(token))
        .toSet();
    if (candidateTokens.isEmpty || currentTitleTokens.isEmpty) return false;

    var overlap = 0;
    for (final token in currentTitleTokens) {
      if (candidateTokens.contains(token)) overlap += 1;
    }
    if (overlap == 0) return false;

    final overlapCurrent = overlap / currentTitleTokens.length;
    final overlapCandidate = overlap / candidateTokens.length;
    if (overlap >= 2 && (overlapCurrent >= 0.7 || overlapCandidate >= 0.7)) {
      return true;
    }
    return false;
  }

  String _sanitizeSearchQuery(String query) {
    var normalized = query
        .replaceAll(RegExp(r'\s*[\(\[\{].*?[\)\]\}]'), ' ')
        .replaceAll(RegExp(r'\bofficial\b', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'\bvisualizer\b', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'\bvideo\b', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    if (normalized.isEmpty) return normalized;

    final seen = <String>{};
    final compact = <String>[];
    for (final token in normalized.split(' ')) {
      final key = token.toLowerCase();
      if (key.isEmpty) continue;
      if (!seen.add(key)) continue;
      compact.add(token);
      if (compact.length >= 8) break;
    }

    return compact.join(' ').trim();
  }

  Future<void> _waitForYoutubeRequestSlot() async {
    final now = DateTime.now();
    final slowModeActive =
        _youtubeSlowModeUntil != null && now.isBefore(_youtubeSlowModeUntil!);
    final effectiveGap = slowModeActive
        ? _youtubeSlowRequestGap
        : _youtubeMinRequestGap;
    final last = _lastYoutubeRequestAt;
    if (last == null) {
      _lastYoutubeRequestAt = now;
      return;
    }
    final elapsed = now.difference(last);
    if (elapsed < effectiveGap) {
      await Future<void>.delayed(effectiveGap - elapsed);
    }
    if (slowModeActive) {
      final jitterMs = 120 + math.Random().nextInt(420);
      await Future<void>.delayed(Duration(milliseconds: jitterMs));
    }
    _lastYoutubeRequestAt = DateTime.now();
  }

  bool get _isYoutubeSlowModeActive {
    final until = _youtubeSlowModeUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  void _activateYoutubeSlowMode([
    Duration duration = _youtubeRateLimitCooldown,
  ]) {
    final now = DateTime.now();
    final until = now.add(duration);
    if (_youtubeSlowModeUntil == null ||
        until.isAfter(_youtubeSlowModeUntil!)) {
      _youtubeSlowModeUntil = until;
    }
  }

  Future<void> _resetYoutubeClientForRecovery() async {
    try {
      _ytExplode.close();
    } catch (_) {}
    _ytExplode = _createYoutubeClient();
  }

  Future<List<Video>> _safeSearchVideos(
    String rawQuery, {
    required int limit,
    bool onlyTopic = false,
    bool onlyAutoGenerated = false,
  }) async {
    final query = _sanitizeSearchQuery(rawQuery);
    if (query.isEmpty) return const [];
    final cacheKey = _searchVideosCacheKey(
      query: query,
      limit: limit,
      onlyTopic: onlyTopic,
      onlyAutoGenerated: onlyAutoGenerated,
    );
    final now = DateTime.now();
    final cached = _searchVideosCache[cacheKey];
    if (cached != null &&
        now.difference(cached.createdAt) <= _searchVideosCacheTtl) {
      return cached.videos;
    }

    final inFlight = _searchVideosRequests[cacheKey];
    if (inFlight != null) {
      return inFlight;
    }

    final request = () async {
      try {
        final results = await _runYoutubeWithRetry(
          () => _ytExplode.search.search(query),
          maxAttempts: 2,
        );
        // Evita recorrer el stream completo: tomamos solo una ventana útil.
        final scanLimit = _searchVideosScanLimit(
          requestedLimit: limit,
          onlyTopic: onlyTopic,
          onlyAutoGenerated: onlyAutoGenerated,
        );
        final list = results.take(scanLimit).toList(growable: false);
        if (!onlyTopic) {
          if (!onlyAutoGenerated) {
            return list.take(limit).toList(growable: false);
          }
          return list
              .where(_hasAutoGeneratedSignal)
              .take(limit)
              .toList(growable: false);
        }
        Iterable<Video> filtered = list.where(
          (item) => _isTopicAuthor(item.author.toLowerCase()),
        );
        filtered = filtered.where(
          (item) => !_isBlockedRecommendationAuthor(item.author.toLowerCase()),
        );
        if (onlyAutoGenerated) {
          filtered = filtered.where(_hasAutoGeneratedSignal);
        }
        return filtered.take(limit).toList(growable: false);
      } catch (e, s) {
        log('Busqueda de recomendados falló: $query', error: e, stackTrace: s);
        return const <Video>[];
      }
    }();

    _searchVideosRequests[cacheKey] = request;
    try {
      final resolved = await request;
      _searchVideosCache[cacheKey] = _SearchVideosCacheEntry(
        createdAt: now,
        videos: resolved,
      );
      _trimSearchVideosCache();
      return resolved;
    } finally {
      _searchVideosRequests.remove(cacheKey);
    }
  }

  String _searchVideosCacheKey({
    required String query,
    required int limit,
    required bool onlyTopic,
    required bool onlyAutoGenerated,
  }) {
    return '$query|$limit|${onlyTopic ? 1 : 0}|${onlyAutoGenerated ? 1 : 0}';
  }

  int _searchVideosScanLimit({
    required int requestedLimit,
    required bool onlyTopic,
    required bool onlyAutoGenerated,
  }) {
    final base = requestedLimit.clamp(1, 80);
    if (!onlyTopic && !onlyAutoGenerated) return base;
    // Para filtros estrictos escaneamos más resultados sin irnos al stream entero.
    final boosted = math.max(36, base * 4);
    return boosted.clamp(24, 90);
  }

  void _trimSearchVideosCache() {
    final now = DateTime.now();
    _searchVideosCache.removeWhere(
      (_, entry) => now.difference(entry.createdAt) > _searchVideosCacheTtl,
    );
    if (_searchVideosCache.length <= _searchVideosCacheMaxEntries) return;
    final overflow = _searchVideosCache.length - _searchVideosCacheMaxEntries;
    final keysToDrop = _searchVideosCache.keys.take(overflow).toList();
    for (final key in keysToDrop) {
      _searchVideosCache.remove(key);
    }
  }

  _RecommendationSignals _buildRecommendationSignals({
    required String primaryArtist,
    String? currentTitle,
    required List<Video> relatedVideos,
  }) {
    const currentTokens = <String>[];
    const currentArtistTokens = <String>[];
    final relatedTitleTokens = <String>{};
    final excludedCurrentTitleTokens = _extractRecommendationTokens(
      currentTitle ?? _trackTitle ?? '',
      max: 10,
    ).toSet();
    final coListenArtistCounter = <String, int>{};
    final normalizedPrimary = _normalizeArtistName(primaryArtist);

    for (final video in relatedVideos.take(70)) {
      if (!_isPureYoutubeMusicAudio(video)) continue;

      final relatedArtist = _normalizeArtistName(video.author);
      if (relatedArtist.isNotEmpty && relatedArtist != normalizedPrimary) {
        coListenArtistCounter[relatedArtist] =
            (coListenArtistCounter[relatedArtist] ?? 0) + 1;
      }
      for (final token in _extractRecommendationTokens(video.title, max: 4)) {
        if (excludedCurrentTitleTokens.contains(token)) continue;
        relatedTitleTokens.add(token);
        if (relatedTitleTokens.length >= 10) break;
      }
    }

    final coListenArtists = coListenArtistCounter.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final genreHints = _inferGenreHints(relatedVideos: relatedVideos);
    final genreTokens = _extractGenreTokens(genreHints);

    return _RecommendationSignals(
      currentTitleTokens: currentTokens,
      currentArtistTokens: currentArtistTokens,
      relatedTitleTokens: relatedTitleTokens.toList(growable: false),
      coListenArtists: coListenArtists
          .map((e) => e.key)
          .take(10)
          .toList(growable: false),
      genreHints: genreHints,
      genreTokens: genreTokens,
    );
  }

  List<String> _extractRecommendationTokens(String text, {required int max}) {
    final cleaned = _normalizeTitleForQueueDedup(text);
    if (cleaned.isEmpty) return const [];
    final seen = <String>{};
    final tokens = <String>[];
    for (final token in cleaned.split(' ')) {
      if (token.length < 3) continue;
      if (_historyStopwords.contains(token)) continue;
      if (_queueTokenStopwords.contains(token)) continue;
      if (!seen.add(token)) continue;
      tokens.add(token);
      if (tokens.length >= max) break;
    }
    return tokens;
  }

  List<String> _inferGenreHints({required List<Video> relatedVideos}) {
    final corpus = StringBuffer()..write(' ');
    for (final video in relatedVideos.take(40)) {
      corpus
        ..write(' ')
        ..write(video.author.toLowerCase())
        ..write(' ')
        ..write(video.description.toLowerCase());
    }
    final text = corpus.toString();
    final scores = <String, int>{};

    for (final entry in _genreKeywordRules.entries) {
      final genre = entry.key;
      var points = 0;
      for (final keyword in entry.value) {
        if (text.contains(keyword)) points += 1;
      }
      if (points > 0) {
        scores[genre] = (scores[genre] ?? 0) + points * 30;
      }
    }

    final ordered = scores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return ordered.map((e) => e.key).take(6).toList(growable: false);
  }

  List<String> _extractGenreTokens(List<String> genreHints) {
    final tokens = <String>{};
    for (final genre in genreHints) {
      for (final token in genre.split(RegExp(r'\s+'))) {
        if (token.length < 3) continue;
        if (_queueTokenStopwords.contains(token)) continue;
        if (_historyStopwords.contains(token)) continue;
        tokens.add(token);
      }
    }
    return tokens.take(12).toList(growable: false);
  }

  String _normalizeArtistName(String input) {
    return input
        .toLowerCase()
        .replaceAll(RegExp(r'\s*[-–—]\s*topic$', caseSensitive: false), '')
        .replaceAll(RegExp(r'\btopic\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\bvevo\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\bofficial\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\brecords?\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\bmusic\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static const List<String> _musicKeywords = [
    'official audio',
    'audio',
    'lyric',
    'lyrics',
    'music video',
    'vevo',
    'official video',
    'visualizer',
    'live',
    'session',
    'en vivo',
    'acoustic',
    'remix',
  ];

  static const List<String> _autoGeneratedKeywords = [
    'provided to youtube by',
    'auto-generated by youtube',
  ];

  static const List<String> _videoLikeKeywords = [
    'official video',
    'music video',
    'video oficial',
    'live',
    'en vivo',
    'concert',
    'session',
    'visualizer',
    'performance',
    'clip oficial',
    'lyrics',
    'lyric',
  ];

  static const List<String> _explicitKeywords = [
    'explicit',
    'e version',
    'parental advisory',
    'uncensored',
    'dirty version',
    'contenido explicito',
    'explicita',
  ];

  static const List<String> _nonSongKeywords = [
    'podcast',
    'episode',
    'episodio',
    'ep.',
    ' ep ',
    'trailer',
    'interview',
    'entrevista',
    'audiobook',
    'audiolibro',
    'season',
    'temporada',
    'capitulo',
    'capítulo',
    'chapter',
    'sound effects',
    'ambience',
    'ambient sounds',
    'white noise',
    'meditation',
    'sleep sounds',
    'theme song',
    'main theme',
  ];

  static const Set<String> _queueTokenStopwords = {
    'the',
    'this',
    'that',
    'these',
    'those',
    'with',
    'from',
    'into',
    'onto',
    'over',
    'under',
    'between',
    'where',
    'when',
    'what',
    'who',
    'whom',
    'why',
    'how',
    'you',
    'your',
    'yours',
    'she',
    'her',
    'his',
    'him',
    'they',
    'them',
    'their',
    'ours',
    'ourselves',
    'my',
    'mine',
    'our',
    'its',
    'it',
    'are',
    'was',
    'were',
    'been',
    'being',
    'have',
    'has',
    'had',
    'and',
    'for',
    'but',
    'not',
    'all',
    'any',
    'out',
    'off',
    'mix',
    'radio',
    'version',
    'edit',
    'full',
    'album',
    'tema',
    'song',
    'track',
    'music',
    'musica',
    'cancion',
    'canciones',
    'top',
    'hits',
    'best',
    'tendencia',
    'tendencias',
    'mexico',
  };

  static const Map<String, List<String>> _genreKeywordRules = {
    'corridos tumbados': [
      'corrido',
      'corridos',
      'tumbado',
      'tumbados',
      'belico',
      'beli',
      'sierre',
    ],
    'regional mexicano': [
      'regional',
      'mexicano',
      'banda',
      'norteno',
      'norteño',
      'ranchera',
      'mariachi',
      'grupero',
    ],
    'reggaeton latino': [
      'reggaeton',
      'perreo',
      'urbano',
      'latin trap',
      'dembow',
    ],
    'trap latino': ['trap', 'trap latino', 'rap latino', 'drill'],
    'pop latino': ['pop', 'latin pop', 'balada pop'],
    'rock en espanol': [
      'rock',
      'rock en espanol',
      'rock en español',
      'alternativo',
      'indie rock',
    ],
    'bachata': ['bachata'],
    'salsa': ['salsa'],
    'cumbia': ['cumbia'],
    'electro pop': ['electro', 'electronic', 'edm', 'dance', 'house', 'techno'],
  };

  static const Set<String> _historyStopwords = {
    'the',
    'and',
    'this',
    'that',
    'these',
    'those',
    'when',
    'where',
    'what',
    'who',
    'why',
    'how',
    'you',
    'your',
    'she',
    'her',
    'him',
    'his',
    'they',
    'them',
    'their',
    'with',
    'from',
    'para',
    'con',
    'del',
    'de',
    'los',
    'las',
    'una',
    'uno',
    'official',
    'video',
    'audio',
    'lyrics',
    'lyric',
    'live',
    'topic',
  };

  Future<T> _runYoutubeWithRetry<T>(
    Future<T> Function() action, {
    int maxAttempts = 3,
  }) async {
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        await _waitForYoutubeRequestSlot();
        return await action();
      } on VideoUnavailableException catch (e) {
        lastError = e;
        // Algunas respuestas "unavailable" son transitorias por cambios de cliente/firma.
        if (attempt < maxAttempts) {
          await _resetYoutubeClientForRecovery();
        }
      } on RequestLimitExceededException catch (e) {
        lastError = e;
        _activateYoutubeSlowMode(Duration(seconds: 35 + (attempt * 18)));
        if (attempt < maxAttempts) {
          await _resetYoutubeClientForRecovery();
        }
      } on SocketException catch (e) {
        lastError = e;
      } on HandshakeException catch (e) {
        lastError = e;
      } on HttpException catch (e) {
        lastError = e;
      } catch (e) {
        lastError = e;
      }

      if (attempt < maxAttempts) {
        final waitSeconds = (lastError is RequestLimitExceededException)
            ? (4 + (attempt * 4))
            : (lastError is VideoUnavailableException)
            ? 1
            : (attempt * 3);
        final jitterMs = 120 + math.Random().nextInt(380);
        await Future<void>.delayed(
          Duration(seconds: waitSeconds, milliseconds: jitterMs),
        );
      }
    }
    throw lastError ?? Exception('Error desconocido al contactar YouTube');
  }

  Future<void> playLocalFile({
    required String id,
    required String filePath,
    required String title,
    required String thumbnailUrl,
    required String artist,
    String? localPlainLyrics,
    String? localSyncedLyrics,
    bool preserveExistingQueue = false,
    LocalPlaybackQueueStrategy queueStrategy =
        LocalPlaybackQueueStrategy.downloads,
  }) async {
    _sessionRestoreEpoch++;
    _rememberCurrentForHistory();
    _isAiStemsLoading = false;
    _usingAiInstrumental = false;
    _karaokeOriginalStreamUrl = null;
    await _resetEngines();
    await _applyPlaybackVolumeSetting();
    _isLoading = true;
    _errorMessage = null;
    _currentVideoId = id;
    _isLocal = true;
    _preferForegroundVideoPlayback = false;
    _isMinimized = false;
    _isFullScreen = false;
    _trackTitle = title;
    _trackThumbnailUrl = thumbnailUrl;
    _trackArtist = cleanArtistName(artist);
    _currentStreamUrl = filePath;
    _position = Duration.zero;
    _bufferedPosition = Duration.zero;
    _completionHandledForCurrent = false;
    _crossfadeTriggeredForCurrent = false;
    _isCrossfadeTransitioning = false;
    _crossfadeFailedForCurrentVideoId = null;
    _crossfadeFailedQueueKey = null;
    _clearPreloadedNextTrack();
    if (!preserveExistingQueue) {
      _queueSeedVideoId = null;
    }
    _resetLyricsState();

    String? resolvedPlainLyrics = localPlainLyrics;
    String? resolvedSyncedLyrics = localSyncedLyrics;
    final hasPassedLyrics =
        (resolvedPlainLyrics?.trim().isNotEmpty ?? false) ||
        (resolvedSyncedLyrics?.trim().isNotEmpty ?? false);
    if (!hasPassedLyrics) {
      try {
        final box = await Hive.openBox<DownloadedVideo>('downloads');
        final downloaded = box.get(id);
        if (downloaded != null) {
          resolvedPlainLyrics = downloaded.plainLyrics;
          resolvedSyncedLyrics = downloaded.syncedLyrics;
        }
      } catch (_) {
        // Ignoramos: si falla Hive, seguimos sin letra local.
      }
    }

    final hasAppliedLocalLyrics = _applyLocalLyrics(
      plainLyrics: resolvedPlainLyrics,
      syncedLyrics: resolvedSyncedLyrics,
    );
    _syncSystemNowPlaying();
    _syncSystemPlaybackState(force: true);
    unawaited(_persistPlaybackSession(force: true));
    notifyListeners();

    final localFile = File(filePath);
    if (!await localFile.exists()) {
      _errorMessage = 'El archivo local no existe.';
      _isLoading = false;
      _syncSystemPlaybackState(force: true);
      notifyListeners();
      return;
    }

    try {
      await _player.setAudioSource(AudioSource.file(filePath));
      unawaited(_applyAudioEffects());
      // No esperamos a que termine la reproducción para no bloquear la UI.
      unawaited(_playInBackgroundSafely(isLocalPlayback: true, fadeIn: true));
      _sessionPlayedVideoIds.add(id);
      _warmUpNextTrackPreloadNow();
      _usingHiddenVideo = false;
      if (_autoplayEnabled) {
        if (_shouldRefreshQueueForVideo(
          id,
          preserveExistingQueue: preserveExistingQueue,
        )) {
          if (queueStrategy == LocalPlaybackQueueStrategy.recommendations) {
            unawaited(
              _loadOnlineQueueFallbackFromCurrentContext(currentVideoId: id),
            );
          } else {
            unawaited(_loadLocalQueue(currentVideoId: id));
          }
        }
      } else if (!preserveExistingQueue) {
        _clearQueueForAutoplayDisabled();
      }
      if (_isLyricsLayout && !hasAppliedLocalLyrics) {
        unawaited(_loadLyricsForCurrentTrack());
      }
      _syncSystemPlaybackState(force: true);
    } catch (e, s) {
      log('Error reproduciendo archivo local', error: e, stackTrace: s);
      _errorMessage = _buildPlaybackErrorMessage(e, isLocalPlayback: true);
      _isPlaying = false;
      _isBuffering = false;
      _syncSystemPlaybackState(force: true);
    } finally {
      _isLoading = false;
      if (_errorMessage == null && _currentVideoId == id && _hasQueuedItems()) {
        _warmUpNextTrackPreloadNow();
      }
      _syncSystemPlaybackState(force: true);
      unawaited(_persistPlaybackSession(force: true));
      notifyListeners();
    }
  }

  Future<void> playQueueItem(
    PlaybackQueueItem item, {
    String? preloadedStreamUrl,
  }) async {
    _removeFromQueues(item);
    notifyListeners();
    try {
      await _prepareSystemArtwork(
        videoId: item.videoId,
        thumbnailSource: item.thumbnailUrl,
      ).timeout(const Duration(milliseconds: 500), onTimeout: () => null);
    } catch (e, s) {
      log('No se pudo preparar artwork para cola', error: e, stackTrace: s);
    }
    if (item.isLocal) {
      final path = item.localFilePath;
      if (path == null || path.isEmpty) return;
      await playLocalFile(
        id: item.videoId,
        filePath: path,
        title: item.title,
        thumbnailUrl: item.thumbnailUrl,
        artist: item.artist,
        localPlainLyrics: item.localPlainLyrics,
        localSyncedLyrics: item.localSyncedLyrics,
        preserveExistingQueue: true,
      );
      return;
    }
    await play(
      item.videoId,
      preferredThumbnailUrl: item.thumbnailUrl,
      preferredTitle: item.title,
      preferredArtist: item.artist,
      preloadedStreamUrl: preloadedStreamUrl,
      preserveExistingQueue: true,
      preferVideoPlayback: _preferForegroundVideoPlayback,
    );
  }

  bool addOnlineTrackToPlaybackQueue({
    required String videoId,
    required String title,
    required String thumbnailUrl,
    required String artist,
    ManualQueueInsertMode insertMode = ManualQueueInsertMode.end,
  }) {
    if (videoId.trim().isEmpty) return false;
    final item = PlaybackQueueItem(
      videoId: videoId,
      title: title,
      thumbnailUrl: thumbnailUrl,
      artist: cleanArtistName(artist),
      isLocal: false,
    );
    return _enqueueManualQueueItem(item, insertMode: insertMode);
  }

  bool addLocalTrackToPlaybackQueue({
    required String videoId,
    required String title,
    required String thumbnailUrl,
    required String artist,
    required String filePath,
    String? localPlainLyrics,
    String? localSyncedLyrics,
    ManualQueueInsertMode insertMode = ManualQueueInsertMode.end,
  }) {
    if (videoId.trim().isEmpty || filePath.trim().isEmpty) return false;
    final item = PlaybackQueueItem(
      videoId: videoId,
      title: title,
      thumbnailUrl: thumbnailUrl,
      artist: cleanArtistName(artist),
      isLocal: true,
      localFilePath: filePath,
      localPlainLyrics: localPlainLyrics,
      localSyncedLyrics: localSyncedLyrics,
    );
    return _enqueueManualQueueItem(item, insertMode: insertMode);
  }

  bool _enqueueManualQueueItem(
    PlaybackQueueItem item, {
    ManualQueueInsertMode insertMode = ManualQueueInsertMode.end,
  }) {
    final alreadyInManual = _manualPlaybackQueue.any(
      (entry) => entry.videoId == item.videoId && entry.isLocal == item.isLocal,
    );
    if (alreadyInManual) return false;
    if (insertMode == ManualQueueInsertMode.next) {
      _manualPlaybackQueue = [item, ..._manualPlaybackQueue];
    } else {
      _manualPlaybackQueue = [..._manualPlaybackQueue, item];
    }
    unawaited(
      _prepareSystemArtwork(
        videoId: item.videoId,
        thumbnailSource: item.thumbnailUrl,
      ),
    );
    unawaited(_precacheQueueArtwork(_queueArtworkCandidates()));
    unawaited(_maybePreloadUpcomingQueueTrack());
    notifyListeners();
    return true;
  }

  Future<void> playNextInQueue() async {
    if (_manualPlaybackQueue.isEmpty && _playbackQueue.isEmpty) {
      await _hydrateQueueForManualNext();
    }
    await _playNextFromQueue();
  }

  Future<void> _hydrateQueueForManualNext() async {
    final currentVideoId = _currentVideoId;
    if (currentVideoId == null) return;

    if (_isQueueLoading) {
      var attempts = 0;
      while (_isQueueLoading && attempts < 20) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
        attempts++;
      }
    }
    if (_manualPlaybackQueue.isNotEmpty || _playbackQueue.isNotEmpty) return;

    if (_isLocal) {
      await _loadLocalQueue(currentVideoId: currentVideoId);
    } else {
      await _loadOnlineQueueFallbackFromCurrentContext(
        currentVideoId: currentVideoId,
      );
    }
  }

  Future<void> playPreviousInQueue() async {
    if (_playbackHistory.isEmpty) {
      await seekTo(Duration.zero);
      return;
    }
    final previous = _playbackHistory.removeLast();
    _skipHistoryPushOnce = true;
    await playQueueItem(previous);
  }

  void shufflePlaybackQueue() {
    final combined = [..._manualPlaybackQueue, ..._playbackQueue];
    if (combined.length < 2) return;
    combined.shuffle(math.Random());
    _manualPlaybackQueue = combined;
    _playbackQueue = const [];
    _queueSeedVideoId = null;
    _queueTitle = 'En cola';
    _clearPreloadedNextTrack();
    unawaited(_precacheQueueArtwork(_queueArtworkCandidates()));
    unawaited(_maybePreloadUpcomingQueueTrack());
    notifyListeners();
  }

  void replaceManualPlaybackQueue(
    List<PlaybackQueueItem> items, {
    String queueTitle = 'En cola',
  }) {
    _manualPlaybackQueue = List<PlaybackQueueItem>.from(items);
    _queueSeedVideoId = null;
    _queueTitle = queueTitle;
    _clearPreloadedNextTrack();
    unawaited(_precacheQueueArtwork(_queueArtworkCandidates()));
    unawaited(_maybePreloadUpcomingQueueTrack());
    notifyListeners();
  }

  void reorderPlaybackQueue(int oldIndex, int newIndex) {
    final combined = [..._manualPlaybackQueue, ..._playbackQueue];
    if (combined.length < 2) return;
    if (oldIndex < 0 || oldIndex >= combined.length) return;
    if (newIndex < 0 || newIndex > combined.length) return;
    var targetIndex = newIndex;
    if (targetIndex > oldIndex) {
      targetIndex -= 1;
    }
    if (targetIndex == oldIndex) return;
    final item = combined.removeAt(oldIndex);
    combined.insert(targetIndex, item);
    _manualPlaybackQueue = combined;
    _playbackQueue = const [];
    _queueSeedVideoId = null;
    _queueTitle = 'En cola';
    _clearPreloadedNextTrack();
    unawaited(_precacheQueueArtwork(_queueArtworkCandidates()));
    unawaited(_maybePreloadUpcomingQueueTrack());
    notifyListeners();
  }

  void removeQueueItem(PlaybackQueueItem item) {
    final beforeCount = _manualPlaybackQueue.length + _playbackQueue.length;
    _removeFromQueues(item);
    final afterCount = _manualPlaybackQueue.length + _playbackQueue.length;
    if (afterCount == beforeCount) return;
    unawaited(_maybePreloadUpcomingQueueTrack());
    notifyListeners();
  }

  void toggleAutoplay() {
    _autoplayEnabled = !_autoplayEnabled;
    if (!_autoplayEnabled) {
      _clearQueueForAutoplayDisabled();
    } else {
      unawaited(_reloadQueueForCurrentTrack());
    }
    notifyListeners();
  }

  void toggleKaraokeMode() {
    if (!isKaraokeSupported) {
      final wasUsingAi = _usingAiInstrumental;
      _karaokeModeEnabled = false;
      if (wasUsingAi) {
        unawaited(_restoreOriginalAudioIfUsingAiStems());
      } else {
        _volumeFadeEpoch++;
        unawaited(_applyPlaybackVolumeSetting());
        unawaited(_applyAudioEffects());
      }
      notifyListeners();
      return;
    }
    _karaokeModeEnabled = !_karaokeModeEnabled;
    if (_karaokeModeEnabled) {
      unawaited(_tryActivateAiInstrumentalKaraoke());
    } else {
      unawaited(_restoreOriginalAudioIfUsingAiStems());
    }
    _volumeFadeEpoch++;
    unawaited(_applyPlaybackVolumeSetting());
    unawaited(_applyAudioEffects());
    notifyListeners();
  }

  Future<void> _applyAudioEffects() async {
    final singAvailable = isKaraokeSupported;
    if (kIsWeb) return;
    if (Platform.isIOS) {
      try {
        final effectsEnabled =
            singAvailable && _karaokeModeEnabled && !_usingAiInstrumental;
        await _iosAudioEffectsChannel.invokeMethod<void>(
          'setKaraokeMode',
          <String, Object>{
            'enabled': effectsEnabled,
            'amount': effectsEnabled ? 1.8 : 0.0,
          },
        );
        _audioEffectsConfigured = true;
      } catch (e, s) {
        log(
          'No se pudo aplicar efectos de audio en iOS',
          error: e,
          stackTrace: s,
        );
        if (_audioEffectsConfigured) return;
        _karaokeModeEnabled = false;
        _audioEffectsConfigured = true;
      }
      return;
    }
    if (!Platform.isAndroid) return;
    final enhancer = _androidAudioEnhancer;
    final equalizer = _androidAudioEqualizer;
    if (enhancer == null || equalizer == null) return;

    try {
      final effectsEnabled =
          singAvailable && _karaokeModeEnabled && !_usingAiInstrumental;
      await enhancer.setEnabled(effectsEnabled);
      await equalizer.setEnabled(effectsEnabled);

      final params = await equalizer.parameters;
      final minDb = params.minDecibels;
      final maxDb = params.maxDecibels;
      for (final band in params.bands) {
        double targetGain = 0.0;
        if (effectsEnabled) {
          final f = band.centerFrequency;
          if (f <= 120) {
            targetGain += -4.0;
          } else if (f <= 250) {
            targetGain += -2.3;
          } else if (f <= 500) {
            targetGain += 0.6;
          } else if (f <= 1200) {
            targetGain += 2.7;
          } else if (f <= 3000) {
            targetGain += 4.7;
          } else if (f <= 4500) {
            targetGain += 3.4;
          } else if (f <= 8000) {
            targetGain += 1.5;
          } else {
            targetGain += 0.2;
          }
        }
        await band.setGain(targetGain.clamp(minDb, maxDb).toDouble());
      }

      var enhancerGain = 0.0;
      if (effectsEnabled) enhancerGain += 2.2;
      await enhancer.setTargetGain(enhancerGain.clamp(0.0, 2.4));
      _audioEffectsConfigured = true;
    } catch (e, s) {
      log('No se pudo aplicar efectos de audio', error: e, stackTrace: s);
      if (_audioEffectsConfigured) return;
      _karaokeModeEnabled = false;
      _audioEffectsConfigured = true;
    }
  }

  Future<void> _tryActivateAiInstrumentalKaraoke() async {
    if (!isKaraokeSupported) return;
    if (!_karaokeModeEnabled) return;
    if (_isLocal || _usingHiddenVideo) return;
    if (_isAiStemsLoading) return;
    if (!_aiStemsService.isConfigured) return;

    final videoId = _currentVideoId?.trim() ?? '';
    final source = _currentStreamUrl?.trim() ?? '';
    if (videoId.isEmpty || source.isEmpty) return;
    if (!source.startsWith('http://') && !source.startsWith('https://')) return;

    final cacheKey = '$videoId::$source';
    final cached = _aiInstrumentalCache[cacheKey];
    if (cached != null && cached.isNotEmpty) {
      await _switchToAiInstrumental(cached);
      return;
    }

    _isAiStemsLoading = true;
    notifyListeners();
    try {
      final instrumental = await _aiStemsService.requestInstrumentalUrl(
        trackId: videoId,
        sourceUrl: source,
      );
      if (instrumental == null || instrumental.isEmpty) return;
      _aiInstrumentalCache[cacheKey] = instrumental;
      if (!isKaraokeSupported ||
          !_karaokeModeEnabled ||
          _currentVideoId != videoId) {
        return;
      }
      await _switchToAiInstrumental(instrumental);
    } catch (e, s) {
      log('No se pudo generar stem instrumental AI', error: e, stackTrace: s);
    } finally {
      _isAiStemsLoading = false;
      notifyListeners();
    }
  }

  Future<void> _switchToAiInstrumental(String instrumentalUrl) async {
    if (!isKaraokeSupported) return;
    if (_usingHiddenVideo) return;
    final current = _currentStreamUrl?.trim() ?? '';
    if (_karaokeOriginalStreamUrl == null && current.isNotEmpty) {
      _karaokeOriginalStreamUrl = current;
    }

    final uri = Uri.parse(instrumentalUrl);
    final wasPlaying = _isPlaying;
    final positionSnapshot = _position;
    final speedSnapshot = _player.speed;

    await _player.setAudioSource(AudioSource.uri(uri));
    if (positionSnapshot > Duration.zero) {
      await _player.seek(positionSnapshot);
    }
    if ((speedSnapshot - 1.0).abs() > 0.0001) {
      await _player.setSpeed(speedSnapshot);
    }
    if (wasPlaying) {
      await _player.play();
    } else {
      await _player.pause();
    }

    _usingAiInstrumental = true;
    unawaited(_applyAudioEffects());
    _syncSystemPlaybackState(force: true);
    notifyListeners();
  }

  Future<void> _restoreOriginalAudioIfUsingAiStems() async {
    if (!_usingAiInstrumental) return;
    final source = _karaokeOriginalStreamUrl?.trim() ?? '';
    if (source.isEmpty) {
      _usingAiInstrumental = false;
      _karaokeOriginalStreamUrl = null;
      return;
    }

    try {
      final uri = Uri.parse(source);
      final headers = _headersForStreamUri(uri) ?? const <String, String>{};
      final wasPlaying = _isPlaying;
      final positionSnapshot = _position;
      final speedSnapshot = _player.speed;
      await _player.setAudioSource(AudioSource.uri(uri, headers: headers));
      if (positionSnapshot > Duration.zero) {
        await _player.seek(positionSnapshot);
      }
      if ((speedSnapshot - 1.0).abs() > 0.0001) {
        await _player.setSpeed(speedSnapshot);
      }
      if (wasPlaying) {
        await _player.play();
      } else {
        await _player.pause();
      }
    } catch (e, s) {
      log(
        'No se pudo restaurar audio original tras stems AI',
        error: e,
        stackTrace: s,
      );
    } finally {
      _usingAiInstrumental = false;
      _karaokeOriginalStreamUrl = null;
      unawaited(_applyAudioEffects());
      _syncSystemPlaybackState(force: true);
      notifyListeners();
    }
  }

  void _onSettingsChanged() {
    unawaited(_syncKaraokeAvailabilityWithSettings());
    unawaited(_applyUserAudioPreferences());
  }

  Future<void> _syncKaraokeAvailabilityWithSettings() async {
    if (isKaraokeSupported) return;
    final hadKaraokeState =
        _karaokeModeEnabled || _usingAiInstrumental || _isAiStemsLoading;
    if (!hadKaraokeState) return;

    _karaokeModeEnabled = false;
    _isAiStemsLoading = false;
    if (_usingAiInstrumental) {
      await _restoreOriginalAudioIfUsingAiStems();
      return;
    }
    _usingAiInstrumental = false;
    _karaokeOriginalStreamUrl = null;
    _volumeFadeEpoch++;
    await _applyPlaybackVolumeSetting();
    await _applyAudioEffects();
    notifyListeners();
  }

  Future<void> _applyUserAudioPreferences() async {
    _volumeFadeEpoch++;
    await _applyPlaybackVolumeSetting();
    notifyListeners();
  }

  Future<void> _applyPlaybackVolumeSetting() async {
    try {
      final targetVolume = _targetPlaybackVolume();
      await _player.setVolume(targetVolume);
      await _crossfadePlayer.setVolume(0.0);
    } catch (_) {
      // Best effort: algunos backends pueden limitar o ignorar >1.0.
    }
  }

  bool get _isMixingEnabled =>
      _settingsService.crossfade || _settingsService.djMode;

  Duration _resolveMixDuration({
    required Duration outgoingDuration,
    required Duration outgoingPosition,
    required Duration incomingDuration,
    Duration? preferredDuration,
  }) {
    if (!_settingsService.djMode) return _crossfadeDuration;

    if (preferredDuration != null && preferredDuration > Duration.zero) {
      final remainingMs = (outgoingDuration - outgoingPosition).inMilliseconds;
      final safeMaxMs = math.max(
        2200,
        remainingMs - const Duration(milliseconds: 700).inMilliseconds,
      );
      final preferredMs = preferredDuration.inMilliseconds.clamp(
        _djMinMixDuration.inMilliseconds,
        _djMaxMixDuration.inMilliseconds,
      );
      return Duration(milliseconds: math.min(preferredMs, safeMaxMs));
    }

    final outgoingBasedMs = outgoingDuration > Duration.zero
        ? (outgoingDuration.inMilliseconds * 0.065).round()
        : _djMinMixDuration.inMilliseconds;
    final incomingBasedMs = incomingDuration > Duration.zero
        ? (incomingDuration.inMilliseconds * 0.045).round()
        : _djMinMixDuration.inMilliseconds;
    final blendedMs = ((outgoingBasedMs + incomingBasedMs) / 2).round();
    final clampedMs = blendedMs.clamp(
      _djMinMixDuration.inMilliseconds,
      _djMaxMixDuration.inMilliseconds,
    );

    final remainingMs = (outgoingDuration - outgoingPosition).inMilliseconds;
    final safeMaxMs = math.max(
      2000,
      remainingMs - const Duration(milliseconds: 700).inMilliseconds,
    );
    final safeMs = math.min(clampedMs, safeMaxMs);
    return Duration(milliseconds: safeMs);
  }

  Duration _effectiveCrossfadeTriggerLeadTime({Duration? preferred}) {
    if (!_settingsService.djMode) return _crossfadeTriggerLeadTime;
    if (preferred != null && preferred > Duration.zero) {
      final ms = preferred.inMilliseconds.clamp(6500, 14000);
      return Duration(milliseconds: ms);
    }
    if (_trackDuration <= Duration.zero) return const Duration(seconds: 9);
    final dynamicSeconds = (_trackDuration.inSeconds * 0.055).round().clamp(
      8,
      13,
    );
    return Duration(seconds: dynamicSeconds);
  }

  Duration _effectiveCrossfadePreloadLeadTime() {
    if (!_settingsService.djMode) return _crossfadePreloadLeadTime;
    return const Duration(seconds: 42);
  }

  Duration _resolveDjIncomingStartOffset({
    required Duration? firstLyricOffset,
    required Duration incomingDuration,
    required Duration mixDuration,
  }) {
    if (firstLyricOffset == null || firstLyricOffset <= Duration.zero) {
      return Duration.zero;
    }
    // Dejamos que la primera frase caiga cerca del final de la mezcla.
    const lyricLead = Duration(milliseconds: 350);
    var offset = firstLyricOffset - mixDuration + lyricLead;
    if (offset <= Duration.zero) return Duration.zero;

    if (incomingDuration > Duration.zero) {
      final maxOffset = incomingDuration - const Duration(seconds: 2);
      if (maxOffset <= Duration.zero) return Duration.zero;
      if (offset > maxOffset) {
        offset = maxOffset;
      }
    }
    return offset;
  }

  double _resolveDjIncomingSpeed({
    required Duration? firstLyricOffset,
    required Duration incomingStartOffset,
    required Duration mixDuration,
  }) {
    if (firstLyricOffset == null ||
        firstLyricOffset <= Duration.zero ||
        mixDuration <= Duration.zero) {
      return 1.0;
    }

    final remainingToLyric = firstLyricOffset - incomingStartOffset;
    if (remainingToLyric <= Duration(milliseconds: 120)) {
      return 1.0;
    }

    // Queremos que la primera línea caiga cerca del cierre de la mezcla.
    final desiredHitMs = math.max(300, mixDuration.inMilliseconds - 260);
    final requiredSpeed = remainingToLyric.inMilliseconds / desiredHitMs;
    return requiredSpeed.clamp(0.97, 1.04);
  }

  Future<double> _setPlayerSpeedSmooth(
    AudioPlayer player,
    double target, {
    required double minSpeed,
    required double maxSpeed,
  }) async {
    final safeTarget = target.clamp(minSpeed, maxSpeed).toDouble();
    double current = 1.0;
    try {
      current = player.speed;
    } catch (_) {}

    final delta = (safeTarget - current).abs();
    if (delta < 0.004) {
      try {
        await player.setSpeed(safeTarget);
      } catch (_) {}
      return safeTarget;
    }

    final steps = ((delta / 0.01).ceil()).clamp(3, 7);
    for (var i = 1; i <= steps; i++) {
      final ratio = i / steps;
      final eased = 1 - math.pow(1 - ratio, 2).toDouble();
      final nextSpeed = current + ((safeTarget - current) * eased);
      try {
        await player.setSpeed(nextSpeed);
      } catch (_) {
        return current;
      }
      await Future<void>.delayed(const Duration(milliseconds: 42));
    }
    return safeTarget;
  }

  Future<void> _applyTrackStartFadeInIfEnabled() async {
    if (!_isMixingEnabled) return;
    final fadeId = ++_volumeFadeEpoch;
    final targetVolume = _targetPlaybackVolume();
    try {
      await _player.setVolume(0.0);
      const stepCount = 8;
      for (var step = 1; step <= stepCount; step++) {
        if (fadeId != _volumeFadeEpoch) return;
        if (!_player.playing) return;
        await Future<void>.delayed(const Duration(milliseconds: 120));
        if (fadeId != _volumeFadeEpoch) return;
        final nextVolume = targetVolume * (step / stepCount);
        await _player.setVolume(nextVolume);
      }
    } catch (_) {
      await _applyPlaybackVolumeSetting();
    }
  }

  int? _targetBitrateForCurrentQuality() {
    final preferredBitrate = switch (_settingsService.audioQuality) {
      AudioQualityPreference.automatic => Platform.isIOS ? 160000 : 128000,
      AudioQualityPreference.low => 96000,
      AudioQualityPreference.normal => 160000,
      AudioQualityPreference.high => 320000,
      AudioQualityPreference.veryHigh => null,
    };
    if (!_settingsService.dataSaverMode) return preferredBitrate;
    if (preferredBitrate == null) return 128000;
    return math.min(preferredBitrate, 128000);
  }

  void toggleLyricsLayout() {
    _isLyricsLayout = !_isLyricsLayout;
    final hasCurrentLyrics =
        (_lyricsText?.trim().isNotEmpty ?? false) || _syncedLyrics.isNotEmpty;
    if (_isLyricsLayout && !hasCurrentLyrics) {
      unawaited(_loadLyricsForCurrentTrack());
    }
    notifyListeners();
  }

  List<AudioOnlyStreamInfo> _prioritizeAudioStreams(
    List<AudioOnlyStreamInfo> streams,
  ) {
    final targetBitrate = _targetBitrateForCurrentQuality();

    final sorted = [...streams]
      ..sort((a, b) {
        final aContainer = a.container.name.toLowerCase();
        final bContainer = b.container.name.toLowerCase();
        final aPreferredContainer = (aContainer == 'mp4' || aContainer == 'm4a')
            ? 1
            : 0;
        final bPreferredContainer = (bContainer == 'mp4' || bContainer == 'm4a')
            ? 1
            : 0;

        if (aPreferredContainer != bPreferredContainer) {
          return bPreferredContainer.compareTo(aPreferredContainer);
        }

        if (targetBitrate != null) {
          final aDistance = (a.bitrate.bitsPerSecond - targetBitrate).abs();
          final bDistance = (b.bitrate.bitsPerSecond - targetBitrate).abs();
          if (aDistance != bDistance) return aDistance.compareTo(bDistance);
        }

        return b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond);
      });
    return sorted;
  }

  Future<void> _playInBackgroundSafely({
    bool isLocalPlayback = false,
    bool fadeIn = false,
  }) async {
    try {
      await _player.play();
      if (fadeIn) {
        unawaited(_applyTrackStartFadeInIfEnabled());
      }
    } catch (e, s) {
      log('play() en background falló', error: e, stackTrace: s);
      _errorMessage = _buildPlaybackErrorMessage(
        e,
        isLocalPlayback: isLocalPlayback,
      );
      _isPlaying = false;
      _isBuffering = false;
      notifyListeners();
    }
  }

  double _targetPlaybackVolume() {
    final baseVolume = _settingsService.normalizeVolume
        ? 1.0
        : _defaultPlaybackVolume;
    if (!_karaokeModeEnabled || !isKaraokeSupported) return baseVolume;
    return baseVolume * _karaokeVolumeBoostMultiplier;
  }

  Future<void> _ensureAudibleAfterResume(AudioPlayer expectedPlayer) async {
    // Si el usuario pausó durante un fade-in, el volumen puede quedar en 0.
    // Al reanudar, lo recuperamos con una rampa corta para evitar "silencio".
    const maxChecks = 12;
    for (var i = 0; i < maxChecks; i++) {
      if (!identical(_player, expectedPlayer)) return;
      if (expectedPlayer.playing) break;
      await Future<void>.delayed(const Duration(milliseconds: 70));
    }
    if (!identical(_player, expectedPlayer) || !expectedPlayer.playing) return;

    final targetVolume = _targetPlaybackVolume();
    final currentVolume = expectedPlayer.volume;
    if (currentVolume >= (targetVolume * 0.72)) return;

    final fadeId = ++_volumeFadeEpoch;
    final startVolume = currentVolume.clamp(0.0, targetVolume);
    const steps = 6;
    for (var step = 1; step <= steps; step++) {
      if (fadeId != _volumeFadeEpoch) return;
      if (!identical(_player, expectedPlayer) || !expectedPlayer.playing) {
        return;
      }
      final nextVolume =
          startVolume + ((targetVolume - startVolume) * (step / steps));
      try {
        await expectedPlayer.setVolume(nextVolume);
      } catch (_) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 65));
    }
  }

  Future<void> togglePlayPause() async {
    if (_isResettingEngines || _isTogglingPlayPause) return;
    _isTogglingPlayPause = true;
    try {
      if (_usingHiddenVideo && _hiddenVideoController != null) {
        final controller = _hiddenVideoController!;
        final shouldPlay = !controller.value.isPlaying;

        // Feedback inmediato para que el botón cambie sin esperar al stream.
        _isPlaying = shouldPlay;
        notifyListeners();

        try {
          if (shouldPlay) {
            await controller.play();
          } else {
            await controller.pause();
          }
        } catch (e, s) {
          log('togglePlayPause en hidden video falló', error: e, stackTrace: s);
        } finally {
          final value = controller.value;
          _isPlaying = value.isPlaying;
          _isBuffering = value.isBuffering;
          unawaited(_persistPlaybackSession(force: true));
          notifyListeners();
        }
        return;
      }

      // Usamos el estado real del motor para evitar desincronizaciones del UI flag.
      final shouldPlay = !_player.playing;
      _isPlaying = shouldPlay;
      if (shouldPlay) {
        _isBuffering = true;
      }
      notifyListeners();

      try {
        if (shouldPlay) {
          final resumePlayer = _player;
          // En just_audio, play() puede mantener el Future vivo durante la reproducción.
          // No esperamos aquí para no bloquear taps siguientes.
          unawaited(_playInBackgroundSafely(isLocalPlayback: _isLocal));
          unawaited(_ensureAudibleAfterResume(resumePlayer));
        } else {
          _volumeFadeEpoch++;
          await _player.pause();
        }
      } catch (e, s) {
        log('togglePlayPause en audio falló', error: e, stackTrace: s);
      } finally {
        if (shouldPlay) {
          // Damos un frame para que el estado interno se sincronice.
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
        _isPlaying = _player.playing;
        _isBuffering = false;
        unawaited(_persistPlaybackSession(force: true));
        notifyListeners();
      }
    } finally {
      _isTogglingPlayPause = false;
    }
  }

  Future<void> seekTo(Duration newPosition) async {
    if (_isResettingEngines) return;
    final max = _trackDuration;
    final clamped = newPosition < Duration.zero
        ? Duration.zero
        : (newPosition > max ? max : newPosition);
    final hidden = _hiddenVideoController;
    if (_usingHiddenVideo && hidden != null) {
      try {
        await hidden.seekTo(clamped);
        _position = clamped;
        unawaited(_persistPlaybackSession(force: true));
      } catch (e, s) {
        log('seekTo en hidden video falló', error: e, stackTrace: s);
      }
      return;
    }
    try {
      await _player.seek(clamped);
      _position = clamped;
      unawaited(_persistPlaybackSession(force: true));
    } catch (e, s) {
      log('seekTo en audio falló', error: e, stackTrace: s);
    }
  }

  void minimize() {
    if (!_isMinimized) {
      _isMinimized = true;
      unawaited(_persistPlaybackSession(force: true));
      notifyListeners();
    }
  }

  void maximize() {
    if (_isMinimized) {
      _isMinimized = false;
      notifyListeners();
    }
  }

  Future<void> close() async {
    await _resetEngines();

    _currentVideoId = null;
    _isMinimized = false;
    _isFullScreen = false;
    _trackTitle = null;
    _trackThumbnailUrl = null;
    _trackArtist = null;
    _trackDuration = Duration.zero;
    _position = Duration.zero;
    _bufferedPosition = Duration.zero;
    _isPlaying = false;
    _isBuffering = false;
    _isLoading = false;
    _usingHiddenVideo = false;
    _preferForegroundVideoPlayback = false;
    _isLocal = false;
    _isLyricsLayout = false;
    _resetLyricsState();
    _errorMessage = null;
    _currentStreamUrl = null;
    _isAiStemsLoading = false;
    _usingAiInstrumental = false;
    _karaokeOriginalStreamUrl = null;
    _manualPlaybackQueue = const [];
    _playbackQueue = const [];
    _playbackHistory.clear();
    _isQueueLoading = false;
    _queueTitle = 'Siguiente';
    _queueSeedVideoId = null;
    _completionHandledForCurrent = false;
    await _clearPersistedPlaybackSession();

    _clearSystemNowPlaying();
    notifyListeners();
  }

  void setFullScreen(bool isFullScreen) {
    if (_isFullScreen != isFullScreen) {
      _isFullScreen = isFullScreen;
      notifyListeners();
    }
  }

  Future<void> switchToBackgroundAudio() async {
    _preferForegroundVideoPlayback = false;
    await _switchHiddenVideoToAudioEngine();
    notifyListeners();
  }

  Future<void> switchToForegroundVideo() async {
    final id = _currentVideoId?.trim() ?? '';
    if (id.isEmpty || _isLocal) return;
    final positionSnapshot = _maxDuration(_position, _player.position);
    final wasPlaying = _isPlaying;
    _preferForegroundVideoPlayback = true;
    if (_usingHiddenVideo && _hiddenVideoController != null) {
      notifyListeners();
      return;
    }
    await play(
      id,
      isLocalVideo: false,
      preferredThumbnailUrl: _trackThumbnailUrl,
      preferredTitle: _trackTitle,
      preferredArtist: _trackArtist,
      preferredDuration: _trackDuration,
      preserveExistingQueue: true,
      preferVideoPlayback: true,
    );
    await seekTo(positionSnapshot);
    if (!wasPlaying) {
      final hidden = _hiddenVideoController;
      if (hidden != null) {
        try {
          await hidden.pause();
        } catch (_) {}
      } else {
        try {
          await _player.pause();
        } catch (_) {}
      }
      _isPlaying = false;
      _isBuffering = false;
      _syncSystemPlaybackState(force: true);
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _backgroundEngineSwitchTimer?.cancel();
    _resumeSharedSongTimer?.cancel();
    unawaited(_persistPlaybackSession(force: true));
    _settingsService.removeListener(_onSettingsChanged);
    WidgetsBinding.instance.removeObserver(this);
    _positionSub?.cancel();
    _bufferedSub?.cancel();
    _durationSub?.cancel();
    _playerStateSub?.cancel();
    _hiddenVideoController?.removeListener(_syncFromHiddenVideo);
    _hiddenVideoController?.dispose();
    _player.dispose();
    _crossfadePlayer.dispose();
    _ytExplode.close();
    _clearSystemNowPlaying();
    _audioHandler.stop();
    super.dispose();
  }

  Future<void> _initPlayerSessionPersistence() async {
    if (_didAttemptSessionRestore) return;
    _didAttemptSessionRestore = true;
    try {
      _playerSessionBox = await Hive.openBox(_playerSessionBoxName);
      await _restoreLastPlaybackSession();
    } catch (e, s) {
      log(
        'No se pudo inicializar persistencia del reproductor',
        error: e,
        stackTrace: s,
      );
    }
  }

  void _persistPlaybackSessionThrottled() {
    if (_currentVideoId == null) return;
    final now = DateTime.now();
    final currentPosMs = _position.inMilliseconds;
    final movedEnough =
        (currentPosMs - _lastSessionPersistedPositionMs).abs() >= 1500;
    final elapsedEnough =
        now.difference(_lastSessionPersistAt) >= const Duration(seconds: 3);
    if (!movedEnough && !elapsedEnough) return;
    _lastSessionPersistAt = now;
    _lastSessionPersistedPositionMs = currentPosMs;
    unawaited(_persistPlaybackSession());
  }

  Future<void> _persistPlaybackSession({bool force = false}) async {
    final box = _playerSessionBox;
    if (box == null) return;
    final currentId = _currentVideoId?.trim() ?? '';
    if (currentId.isEmpty) {
      await _clearPersistedPlaybackSession();
      return;
    }

    final now = DateTime.now();
    if (!force &&
        now.difference(_lastSessionPersistAt) <
            const Duration(milliseconds: 800)) {
      return;
    }
    _lastSessionPersistAt = now;
    _lastSessionPersistedPositionMs = _position.inMilliseconds;

    final payload = <String, dynamic>{
      'videoId': currentId,
      'isLocal': _isLocal,
      'title': _trackTitle ?? '',
      'thumbnailUrl': _trackThumbnailUrl ?? '',
      'artist': _trackArtist ?? '',
      'streamUrl': _currentStreamUrl ?? '',
      'positionMs': _position.inMilliseconds,
      'savedAtMs': now.millisecondsSinceEpoch,
    };
    try {
      await box.put(_lastTrackSessionKey, payload);
    } catch (e, s) {
      log(
        'No se pudo persistir sesion del reproductor',
        error: e,
        stackTrace: s,
      );
    }
  }

  Future<void> _clearPersistedPlaybackSession() async {
    final box = _playerSessionBox;
    if (box == null) return;
    try {
      await box.delete(_lastTrackSessionKey);
    } catch (_) {}
  }

  bool _isWithinSessionTtl(int savedAtMs, Duration ttl) {
    if (savedAtMs <= 0) return false;
    final savedAt = DateTime.fromMillisecondsSinceEpoch(savedAtMs);
    if (savedAt.isAfter(DateTime.now())) return false;
    return DateTime.now().difference(savedAt) <= ttl;
  }

  Future<List<PlaybackQueueItem>> _readRelatedQueueFromSession(
    String videoId,
  ) async {
    final box = _playerSessionBox;
    if (box == null) return const <PlaybackQueueItem>[];
    final normalizedVideoId = videoId.trim();
    if (normalizedVideoId.isEmpty) return const <PlaybackQueueItem>[];

    try {
      final raw = box.get(_relatedQueueSessionKey);
      if (raw is! Map) return const <PlaybackQueueItem>[];
      final payload = Map<String, dynamic>.from(raw.cast<dynamic, dynamic>());
      final payloadVideoId = (payload['videoId'] ?? '').toString().trim();
      if (payloadVideoId != normalizedVideoId) {
        return const <PlaybackQueueItem>[];
      }
      final savedAtMs = (payload['savedAtMs'] as num?)?.toInt() ?? 0;
      if (!_isWithinSessionTtl(savedAtMs, _relatedQueueSessionTtl)) {
        return const <PlaybackQueueItem>[];
      }
      final itemsRaw = payload['items'];
      if (itemsRaw is! List) return const <PlaybackQueueItem>[];
      final restored = <PlaybackQueueItem>[];
      for (final row in itemsRaw.whereType<Map>()) {
        final map = Map<String, dynamic>.from(row.cast<dynamic, dynamic>());
        final id = (map['videoId'] ?? '').toString().trim();
        final title = (map['title'] ?? '').toString().trim();
        final artist = cleanArtistName((map['artist'] ?? '').toString());
        final thumbnailUrl = (map['thumbnailUrl'] ?? '').toString().trim();
        if (id.isEmpty || title.isEmpty || thumbnailUrl.isEmpty) continue;
        restored.add(
          PlaybackQueueItem(
            videoId: id,
            title: title,
            thumbnailUrl: thumbnailUrl,
            artist: artist,
            isLocal: false,
          ),
        );
        if (restored.length >= 40) break;
      }
      return restored;
    } catch (_) {
      return const <PlaybackQueueItem>[];
    }
  }

  Future<void> _writeRelatedQueueToSession(
    String videoId,
    List<PlaybackQueueItem> queue,
  ) async {
    final box = _playerSessionBox;
    if (box == null) return;
    final normalizedVideoId = videoId.trim();
    if (normalizedVideoId.isEmpty || queue.isEmpty) return;

    final payload = <String, dynamic>{
      'videoId': normalizedVideoId,
      'savedAtMs': DateTime.now().millisecondsSinceEpoch,
      'items': queue
          .where((item) => !item.isLocal && item.videoId.trim().isNotEmpty)
          .take(40)
          .map(
            (item) => <String, dynamic>{
              'videoId': item.videoId,
              'title': item.title,
              'artist': item.artist,
              'thumbnailUrl': item.thumbnailUrl,
            },
          )
          .toList(growable: false),
    };
    try {
      await box.put(_relatedQueueSessionKey, payload);
    } catch (_) {
      // Best effort.
    }
  }

  Future<void> _restoreLastPlaybackSession() async {
    final box = _playerSessionBox;
    if (box == null) return;
    final raw = box.get(_lastTrackSessionKey);
    if (raw is! Map) return;

    final videoId = (raw['videoId'] ?? '').toString().trim();
    if (videoId.isEmpty) return;

    final isLocal = raw['isLocal'] == true;
    final title = (raw['title'] ?? '').toString().trim();
    final thumbnailUrl = (raw['thumbnailUrl'] ?? '').toString().trim();
    final artist = cleanArtistName((raw['artist'] ?? '').toString());
    final streamUrl = (raw['streamUrl'] ?? '').toString().trim();
    final rawPositionMs = (raw['positionMs'] as num?)?.toInt() ?? 0;
    final targetPosition = Duration(
      milliseconds: rawPositionMs.clamp(0, 1000 * 60 * 60 * 24),
    );
    final restoreEpoch = ++_sessionRestoreEpoch;
    bool isStale() => restoreEpoch != _sessionRestoreEpoch;

    try {
      await _resetEngines();
      if (isStale()) return;
      await _applyPlaybackVolumeSetting();
      if (isStale()) return;

      _isLoading = true;
      _errorMessage = null;
      _currentVideoId = videoId;
      _isLocal = isLocal;
      _isMinimized = true;
      _isFullScreen = false;
      _trackTitle = title.isNotEmpty ? title : null;
      _trackThumbnailUrl = thumbnailUrl.isNotEmpty ? thumbnailUrl : null;
      _trackArtist = artist.isNotEmpty ? artist : null;
      _position = Duration.zero;
      _bufferedPosition = Duration.zero;
      _isPlaying = false;
      _isBuffering = false;
      _completionHandledForCurrent = false;
      _crossfadeTriggeredForCurrent = false;
      _isCrossfadeTransitioning = false;
      _crossfadeFailedForCurrentVideoId = null;
      _crossfadeFailedQueueKey = null;
      _clearPreloadedNextTrack();
      _resetLyricsState();
      if (isStale()) return;
      notifyListeners();

      if (isLocal) {
        final filePath = streamUrl;
        if (filePath.isEmpty || !await File(filePath).exists()) {
          if (isStale()) return;
          await _clearPersistedPlaybackSession();
          _isLoading = false;
          return;
        }
        _currentStreamUrl = filePath;
        await _player.setAudioSource(AudioSource.file(filePath));
      } else {
        final savedAtMs = (raw['savedAtMs'] as num?)?.toInt() ?? 0;
        var restoredFromSessionStream = false;
        if (streamUrl.isNotEmpty && streamUrl.startsWith('/')) {
          try {
            final cachedFile = File(streamUrl);
            if (await cachedFile.exists()) {
              await _player.setAudioSource(AudioSource.file(streamUrl));
              _currentStreamUrl = streamUrl;
              restoredFromSessionStream = true;
            }
          } catch (_) {
            restoredFromSessionStream = false;
          }
        }
        if (streamUrl.isNotEmpty &&
            !restoredFromSessionStream &&
            _isWithinSessionTtl(savedAtMs, _sessionRestoredStreamTtl)) {
          try {
            final streamUri = Uri.parse(streamUrl);
            await _player.setAudioSource(
              AudioSource.uri(
                streamUri,
                headers: _headersForStreamUri(streamUri) ?? _youtubeHeaders,
              ),
            );
            _currentStreamUrl = streamUrl;
            restoredFromSessionStream = true;
          } catch (_) {
            restoredFromSessionStream = false;
          }
        }
        if (!restoredFromSessionStream) {
          final manifest = await _getManifestWithRetry(
            videoId,
          ).timeout(const Duration(seconds: 6));
          if (isStale()) return;
          final audioStreams = _prioritizeAudioStreams(
            manifest.audioOnly.toList(),
          );
          if (audioStreams.isEmpty) {
            if (isStale()) return;
            await _clearPersistedPlaybackSession();
            _isLoading = false;
            return;
          }
          final stream = audioStreams.first;
          _currentStreamUrl = stream.url.toString();
          await _player.setAudioSource(
            AudioSource.uri(stream.url, headers: _youtubeHeaders),
          );
        }
      }

      await _player.seek(targetPosition);
      if (isStale()) return;
      await _player.pause();
      if (isStale()) return;
      _position = targetPosition;
      _isPlaying = false;
      _isBuffering = false;
      _syncSystemNowPlaying();
      _syncSystemPlaybackState(force: true);
      await _persistPlaybackSession(force: true);
    } catch (e, s) {
      if (isStale()) return;
      log(
        'No se pudo restaurar la ultima reproduccion',
        error: e,
        stackTrace: s,
      );
      await _clearPersistedPlaybackSession();
      _currentVideoId = null;
      _isMinimized = false;
      _trackTitle = null;
      _trackThumbnailUrl = null;
      _trackArtist = null;
      _position = Duration.zero;
      _bufferedPosition = Duration.zero;
      _isPlaying = false;
      _isBuffering = false;
      _currentStreamUrl = null;
    } finally {
      _isLoading = false;
      if (!isStale()) {
        notifyListeners();
      }
    }
  }

  List<MuxedStreamInfo> _prioritizeMuxedStreams(List<MuxedStreamInfo> streams) {
    final targetHeight = _targetVideoHeightForCurrentQuality();
    final sortedByQuality = [...streams]
      ..sort((a, b) {
        final aHeight = a.videoResolution.height;
        final bHeight = b.videoResolution.height;

        if (targetHeight == null) {
          final heightCompare = bHeight.compareTo(aHeight);
          if (heightCompare != 0) return heightCompare;
        } else {
          final aWithinTarget = aHeight <= targetHeight;
          final bWithinTarget = bHeight <= targetHeight;
          if (aWithinTarget != bWithinTarget) {
            return aWithinTarget ? -1 : 1;
          }
          if (aWithinTarget) {
            final heightCompare = bHeight.compareTo(aHeight);
            if (heightCompare != 0) return heightCompare;
          } else {
            final heightCompare = aHeight.compareTo(bHeight);
            if (heightCompare != 0) return heightCompare;
          }
        }

        final frameRateCompare = b.videoQuality.index.compareTo(
          a.videoQuality.index,
        );
        if (frameRateCompare != 0) return frameRateCompare;
        return b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond);
      });

    if (!Platform.isIOS) {
      return sortedByQuality;
    }

    final preferred = <MuxedStreamInfo>[];
    final fallback = <MuxedStreamInfo>[];
    for (final stream in sortedByQuality) {
      final container = stream.container.name.toLowerCase();
      if (container == 'mp4') {
        preferred.add(stream);
      } else {
        fallback.add(stream);
      }
    }
    return [...preferred, ...fallback];
  }

  int? _targetVideoHeightForCurrentQuality() {
    final preferredHeight = switch (_settingsService.audioQuality) {
      AudioQualityPreference.low => 240,
      AudioQualityPreference.normal => 420,
      AudioQualityPreference.high => 720,
      AudioQualityPreference.veryHigh => null,
      AudioQualityPreference.automatic => 420,
    };
    if (!_settingsService.dataSaverMode) return preferredHeight;
    if (preferredHeight == null) return 360;
    return math.min(preferredHeight, 360);
  }

  Future<void> _resetEngines() async {
    final inFlight = _resetEnginesCompleter;
    if (inFlight != null) {
      await inFlight.future;
      return;
    }

    final completer = Completer<void>();
    _resetEnginesCompleter = completer;
    _isResettingEngines = true;
    try {
      try {
        await _player.stop();
      } catch (e, s) {
        log('No se pudo detener player principal', error: e, stackTrace: s);
      }

      try {
        await _crossfadePlayer.stop();
      } catch (e, s) {
        log('No se pudo detener player crossfade', error: e, stackTrace: s);
      }

      _clearPreloadedNextTrack();
      final controller = _hiddenVideoController;
      _hiddenVideoController = null;
      _usingHiddenVideo = false;
      if (controller != null) {
        controller.removeListener(_syncFromHiddenVideo);
        try {
          await controller.pause();
        } catch (_) {}
        try {
          await controller.dispose();
        } catch (_) {}
      }
    } finally {
      _isResettingEngines = false;
      _resetEnginesCompleter = null;
      if (!completer.isCompleted) {
        completer.complete();
      }
    }
  }

  void _syncFromHiddenVideo() {
    final controller = _hiddenVideoController;
    if (controller == null) return;
    final value = controller.value;
    _position = value.position;
    _bufferedPosition = value.position;
    _trackDuration = value.duration;
    _isPlaying = value.isPlaying;
    _isBuffering = value.isBuffering;
    final remaining = value.duration - value.position;
    if (!value.isPlaying &&
        value.duration > Duration.zero &&
        remaining <= const Duration(milliseconds: 350)) {
      _onTrackCompleted();
    }
    final now = DateTime.now();
    final forceSync =
        now.difference(_lastPlaybackOpsTickAt) >= _playbackOpsTickInterval;
    if (forceSync) {
      _lastPlaybackOpsTickAt = now;
      _syncSystemPlaybackState(force: true);
    } else {
      _syncSystemPlaybackState();
    }
    _notifyPlaybackUiListenersThrottled();
  }

  Future<void> _switchHiddenVideoToAudioEngine() async {
    if (_isSwitchingEngine || _isResettingEngines) return;
    if (!_usingHiddenVideo || _hiddenVideoController == null) return;
    final streamUrl = _currentStreamUrl;
    if (streamUrl == null || streamUrl.isEmpty) return;

    _isSwitchingEngine = true;
    try {
      final hidden = _hiddenVideoController;
      if (hidden == null) return;
      final position = hidden.value.position;
      hidden.removeListener(_syncFromHiddenVideo);
      try {
        await hidden.pause();
      } catch (_) {}

      // Desacoplamos el motor de video antes de iniciar audio para evitar audio doble.
      _hiddenVideoController = null;
      _usingHiddenVideo = false;

      try {
        await _player.setAudioSource(
          AudioSource.uri(Uri.parse(streamUrl), headers: _youtubeHeaders),
        );
        unawaited(_applyAudioEffects());
        await _player.seek(position);
        await _player.play();
        unawaited(_applyTrackStartFadeInIfEnabled());
        _isPlaying = true;
        _isBuffering = false;
        _syncSystemPlaybackState(force: true);
      } catch (e, s) {
        // Si falla el motor de audio, recuperamos fallback de video.
        log(
          'Falló migración a audio, restaurando fallback',
          error: e,
          stackTrace: s,
        );
        _hiddenVideoController = hidden;
        _usingHiddenVideo = true;
        hidden.addListener(_syncFromHiddenVideo);
        try {
          await hidden.play();
        } catch (_) {}
      } finally {
        if (_hiddenVideoController == null) {
          try {
            await hidden.dispose();
          } catch (_) {}
        }
      }
      notifyListeners();
    } catch (e, s) {
      log(
        'No se pudo migrar de video oculto a audio en background',
        error: e,
        stackTrace: s,
      );
    } finally {
      _isSwitchingEngine = false;
    }
  }

  Future<void> _loadOnlineQueue(
    Video currentVideo, {
    required String currentVideoId,
  }) async {
    if (!_autoplayEnabled) {
      _clearQueueForAutoplayDisabled();
      return;
    }
    final queueRequestId = ++_queueEpoch;
    _queueTitle = 'Siguiente';
    _playbackQueue = const [];
    _queueSeedVideoId = null;
    _isQueueLoading = true;
    notifyListeners();

    try {
      final related = await _getRelatedQueueWithRetry(currentVideo);
      if (queueRequestId != _queueEpoch || _currentVideoId != currentVideoId) {
        return;
      }
      _playbackQueue = related;
      _queueSeedVideoId = currentVideoId;
      _rememberRecommendedQueue(_playbackQueue);
      unawaited(_precacheQueueArtwork(_queueArtworkCandidates()));
      unawaited(_maybePreloadUpcomingQueueTrack());
    } catch (e, s) {
      log('Error cargando recomendados', error: e, stackTrace: s);
      if (queueRequestId != _queueEpoch || _currentVideoId != currentVideoId) {
        return;
      }
      _playbackQueue = const [];
      _queueSeedVideoId = null;
    } finally {
      if (queueRequestId == _queueEpoch && _currentVideoId == currentVideoId) {
        _isQueueLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> _loadOnlineQueueFallbackFromCurrentContext({
    required String currentVideoId,
  }) async {
    if (!_autoplayEnabled) return;

    final queueRequestId = ++_queueEpoch;
    _queueTitle = 'Siguiente';
    _playbackQueue = const [];
    _queueSeedVideoId = null;
    _isQueueLoading = true;
    notifyListeners();

    try {
      final video = await _getVideoWithRetry(
        currentVideoId,
      ).timeout(const Duration(seconds: 10));
      final queue = await _getRelatedQueueWithRetry(video);

      if (queueRequestId != _queueEpoch || _currentVideoId != currentVideoId) {
        return;
      }
      _playbackQueue = queue;
      _queueSeedVideoId = currentVideoId;
      _rememberRecommendedQueue(_playbackQueue);
      unawaited(_precacheQueueArtwork(_queueArtworkCandidates()));
      unawaited(_maybePreloadUpcomingQueueTrack());
    } catch (e, s) {
      log(
        'Error cargando cola fallback por titulo/tendencia',
        error: e,
        stackTrace: s,
      );
      if (queueRequestId != _queueEpoch || _currentVideoId != currentVideoId) {
        return;
      }
      _playbackQueue = const [];
      _queueSeedVideoId = null;
    } finally {
      if (queueRequestId == _queueEpoch && _currentVideoId == currentVideoId) {
        _isQueueLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> _loadLocalQueue({required String currentVideoId}) async {
    if (!_autoplayEnabled) {
      _clearQueueForAutoplayDisabled();
      return;
    }
    final queueRequestId = ++_queueEpoch;
    _queueTitle = 'Descargas';
    _queueSeedVideoId = null;
    _isQueueLoading = true;
    notifyListeners();

    try {
      final box = await Hive.openBox<DownloadedVideo>('downloads');
      final queue = <PlaybackQueueItem>[];
      for (final item in box.values) {
        if (item.videoId == currentVideoId) continue;
        final file = File(item.filePath);
        if (!await file.exists()) continue;
        queue.add(
          PlaybackQueueItem(
            videoId: item.videoId,
            title: item.title,
            thumbnailUrl:
                (item.localThumbnailPath != null &&
                    item.localThumbnailPath!.isNotEmpty)
                ? item.localThumbnailPath!
                : item.thumbnailUrl,
            artist: cleanArtistName(item.channelTitle),
            isLocal: true,
            localFilePath: item.filePath,
            localPlainLyrics: item.plainLyrics,
            localSyncedLyrics: item.syncedLyrics,
          ),
        );
      }
      if (queueRequestId != _queueEpoch || _currentVideoId != currentVideoId) {
        return;
      }
      _playbackQueue = queue;
      _queueSeedVideoId = currentVideoId;
      unawaited(_precacheQueueArtwork(_queueArtworkCandidates()));
      unawaited(_maybePreloadUpcomingQueueTrack());
    } catch (e, s) {
      log('Error cargando cola local', error: e, stackTrace: s);
      if (queueRequestId != _queueEpoch || _currentVideoId != currentVideoId) {
        return;
      }
      _playbackQueue = const [];
      _queueSeedVideoId = null;
    } finally {
      if (queueRequestId == _queueEpoch && _currentVideoId == currentVideoId) {
        _isQueueLoading = false;
        notifyListeners();
      }
    }
  }

  void _onTrackCompleted() {
    if (_completionHandledForCurrent) return;
    final completedVideoId = _currentVideoId;
    if (completedVideoId == null) return;
    _completionHandledForCurrent = true;
    if (_autoplayEnabled) {
      unawaited(
        _advanceQueueAfterCompletion(
          expectedCompletedVideoId: completedVideoId,
        ),
      );
    }
  }

  Future<void> _advanceQueueAfterCompletion({
    required String expectedCompletedVideoId,
  }) async {
    var attempts = 0;
    while (_isAdvancingQueue && attempts < 30) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      attempts++;
    }
    if (_currentVideoId != expectedCompletedVideoId) {
      // El track ya cambió (p.ej. por crossfade/skip), ignoramos este callback
      // para evitar saltar una canción adicional de la cola.
      return;
    }
    if (_isCrossfadeTransitioning || _crossfadeTriggeredForCurrent) {
      return;
    }
    await _playNextFromQueue();
  }

  Future<void> _playNextFromQueue({bool triggeredByCrossfade = false}) async {
    if (_isAdvancingQueue) return;
    if (_manualPlaybackQueue.isEmpty && _playbackQueue.isEmpty) return;
    _isAdvancingQueue = true;
    try {
      if (!triggeredByCrossfade) {
        try {
          await _player.pause();
        } catch (_) {}
        _isPlaying = false;
        _isBuffering = true;
        _syncSystemPlaybackState(force: true);
        notifyListeners();
      }
      final PlaybackQueueItem next;
      final bool tookFromManualQueue;
      if (_manualPlaybackQueue.isNotEmpty) {
        next = _manualPlaybackQueue.first;
        tookFromManualQueue = true;
      } else {
        next = _playbackQueue.first;
        tookFromManualQueue = false;
      }
      final transitionedToPrepared = triggeredByCrossfade
          ? await _tryCrossfadeTransitionToPreparedItem(next)
          : await _tryInstantTransitionToPreparedItem(next);
      if (transitionedToPrepared) {
        if (tookFromManualQueue) {
          _manualPlaybackQueue = _manualPlaybackQueue.sublist(1);
        } else {
          _playbackQueue = _playbackQueue.sublist(1);
        }
        notifyListeners();
        return;
      }
      if (tookFromManualQueue) {
        _manualPlaybackQueue = _manualPlaybackQueue.sublist(1);
      } else {
        _playbackQueue = _playbackQueue.sublist(1);
      }
      final preloadedUrl = _consumePreloadedStreamForQueueItem(next);
      _crossfadeTriggeredForCurrent = false;
      notifyListeners();
      await playQueueItem(next, preloadedStreamUrl: preloadedUrl);
    } catch (e, s) {
      log('Error reproduciendo siguiente de la cola', error: e, stackTrace: s);
      if (triggeredByCrossfade) {
        _crossfadeTriggeredForCurrent = false;
        _completionHandledForCurrent = false;
      }
    } finally {
      _isAdvancingQueue = false;
    }
  }

  Future<bool> _tryInstantTransitionToPreparedItem(
    PlaybackQueueItem next,
  ) async {
    final currentVideoId = _currentVideoId;
    if (currentVideoId == null) return false;

    final queueKey = _queueItemKey(next);
    var isPrepared =
        _crossfadePreparedQueueKey == queueKey &&
        _preloadedForCurrentVideoId == currentVideoId &&
        _preloadedNextQueueKey == queueKey &&
        (_preloadedNextStreamUrl?.isNotEmpty ?? false);
    if (!isPrepared) {
      final prepared = await _prepareCrossfadePlayerForQueueItem(
        next,
        currentVideoId: currentVideoId,
      );
      if (!prepared) return false;
      isPrepared =
          _crossfadePreparedQueueKey == queueKey &&
          _preloadedForCurrentVideoId == currentVideoId &&
          _preloadedNextQueueKey == queueKey &&
          (_preloadedNextStreamUrl?.isNotEmpty ?? false);
      if (!isPrepared) return false;
    }
    if (!_crossfadePreparedPrimed) {
      final primed = await _primeCrossfadePlayerBuffer();
      if (!primed) return false;
    }

    final previousTitle = _trackTitle;
    final previousArtist = _trackArtist;
    final previousThumbnail = _trackThumbnailUrl;
    final previousDuration = _trackDuration;
    final previousStreamUrl = _currentStreamUrl;
    final previousIsPlaying = _isPlaying;
    final previousIsBuffering = _isBuffering;

    final currentPlayer = _player;
    final nextPlayer = _crossfadePlayer;
    try {
      _isCrossfadeTransitioning = true;
      await nextPlayer.setVolume(_targetPlaybackVolume());
      unawaited(nextPlayer.play());
      unawaited(() async {
        try {
          await currentPlayer.stop();
          await currentPlayer.seek(Duration.zero);
          await currentPlayer.setVolume(0.0);
        } catch (_) {}
      }());

      _rememberCurrentForHistory();
      _player = nextPlayer;
      _crossfadePlayer = currentPlayer;
      _attachActivePlayerSubscriptions();

      _currentVideoId = next.videoId;
      _isLocal = next.isLocal;
      _isMinimized = false;
      _isFullScreen = false;
      _trackTitle = next.title;
      _trackArtist = cleanArtistName(next.artist);
      _trackThumbnailUrl = next.thumbnailUrl;
      _trackDuration = Duration.zero;
      _currentStreamUrl = _preloadedNextStreamUrl ?? next.localFilePath;
      _position = Duration.zero;
      _bufferedPosition = Duration.zero;
      _completionHandledForCurrent = false;
      _crossfadeTriggeredForCurrent = false;
      _isPlaying = true;
      _isBuffering = false;
      _usingHiddenVideo = false;
      _resetLyricsState();
      final hasAppliedLocalLyrics = next.isLocal
          ? _applyLocalLyrics(
              plainLyrics: next.localPlainLyrics,
              syncedLyrics: next.localSyncedLyrics,
            )
          : false;
      _sessionPlayedVideoIds.add(next.videoId);
      _crossfadeFailedForCurrentVideoId = null;
      _crossfadeFailedQueueKey = null;
      _clearPreloadedNextTrack();

      if (_isLyricsLayout &&
          (!hasAppliedLocalLyrics ||
              ((_lyricsText?.trim().isEmpty ?? true) &&
                  _syncedLyrics.isEmpty))) {
        unawaited(_loadLyricsForCurrentTrack());
      }

      _isCrossfadeTransitioning = false;
      _syncSystemNowPlaying();
      _syncSystemPlaybackState(force: true);
      notifyListeners();

      unawaited(() async {
        if (next.isLocal) {
          if (_autoplayEnabled &&
              _playbackQueue.length <= _autoplayQueueRefillThreshold) {
            await _loadLocalQueue(currentVideoId: next.videoId);
          }
          final hasLyrics =
              (_lyricsText?.trim().isNotEmpty ?? false) ||
              _syncedLyrics.isNotEmpty;
          if (_isLyricsLayout && !hasAppliedLocalLyrics && !hasLyrics) {
            await _loadLyricsForCurrentTrack();
          }
          return;
        }

        try {
          final video = await _getVideoWithRetry(next.videoId);
          if (_currentVideoId != next.videoId) return;
          _trackTitle = video.title;
          _trackArtist = cleanArtistName(video.author);
          _trackThumbnailUrl = _mergeThumbnailKeepingMusicSquare(
            existing: _trackThumbnailUrl,
            candidate: bestThumbnailForVideo(
              video,
              preferLowResolution: _settingsService.dataSaverMode,
            ),
          );
          _trackDuration = video.duration ?? Duration.zero;
          _syncSystemNowPlaying();
          _syncSystemPlaybackState(force: true);
          notifyListeners();
          final hasLyrics =
              (_lyricsText?.trim().isNotEmpty ?? false) ||
              _syncedLyrics.isNotEmpty;
          if (_isLyricsLayout && !hasLyrics) {
            await _loadLyricsForCurrentTrack();
          }
          if (_autoplayEnabled &&
              _playbackQueue.length <= _autoplayQueueRefillThreshold) {
            await _loadOnlineQueue(video, currentVideoId: next.videoId);
          }
        } catch (_) {
          // Best effort metadata/queue refresh.
        }
      }());

      unawaited(_addCurrentTrackToHistory(next.videoId));
      _warmUpNextTrackPreloadNow();
      return true;
    } catch (_) {
      _trackTitle = previousTitle;
      _trackArtist = previousArtist;
      _trackThumbnailUrl = previousThumbnail;
      _trackDuration = previousDuration;
      _currentStreamUrl = previousStreamUrl;
      _isPlaying = previousIsPlaying;
      _isBuffering = previousIsBuffering;
      try {
        await nextPlayer.stop();
      } catch (_) {}
      _syncSystemNowPlaying();
      _syncSystemPlaybackState(force: true);
      notifyListeners();
      return false;
    } finally {
      if (_isCrossfadeTransitioning) {
        _isCrossfadeTransitioning = false;
        _syncSystemPlaybackState(force: true);
        notifyListeners();
      }
    }
  }

  PlaybackQueueItem? _peekNextQueueItem() {
    if (_manualPlaybackQueue.isNotEmpty) return _manualPlaybackQueue.first;
    if (_playbackQueue.isNotEmpty) return _playbackQueue.first;
    return null;
  }

  String _queueItemKey(PlaybackQueueItem item) {
    final localFlag = item.isLocal ? 'local' : 'online';
    return '$localFlag:${item.videoId}';
  }

  void _clearPreloadedNextTrack() {
    _preloadedForCurrentVideoId = null;
    _preloadedNextQueueKey = null;
    _preloadedNextStreamUrl = null;
    _crossfadePreparedQueueKey = null;
    _crossfadePreparedPrimed = false;
    unawaited(() async {
      try {
        await _crossfadePlayer.stop();
      } catch (_) {}
    }());
  }

  String? _consumePreloadedStreamForQueueItem(PlaybackQueueItem item) {
    final currentId = _currentVideoId;
    if (currentId == null) return null;
    final queueKey = _queueItemKey(item);
    if (_preloadedForCurrentVideoId != currentId) return null;
    if (_preloadedNextQueueKey != queueKey) return null;
    final stream = _preloadedNextStreamUrl;
    _clearPreloadedNextTrack();
    return stream;
  }

  void _warmUpNextTrackPreloadNow() {
    unawaited(_maybePreloadUpcomingQueueTrack());
    // Reintentos cortos para casos en que la cola llega justo despues
    // (p. ej. metadata/queue en background) y queremos que "siguiente"
    // ya esté caliente tanto en UI grande como en controles nativos.
    unawaited(() async {
      await Future<void>.delayed(const Duration(milliseconds: 520));
      await _maybePreloadUpcomingQueueTrack();
    }());
    unawaited(() async {
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      await _maybePreloadUpcomingQueueTrack();
    }());
  }

  Future<void> _maybePreloadUpcomingQueueTrack() async {
    final currentId = _currentVideoId;
    if (currentId == null ||
        _isLoading ||
        _isAdvancingQueue ||
        _isCrossfadeTransitioning) {
      return;
    }
    final next = _peekNextQueueItem();
    if (next == null) {
      _clearPreloadedNextTrack();
      return;
    }

    final queueKey = _queueItemKey(next);
    final alreadyFailedForCurrentAndQueue =
        _crossfadeFailedForCurrentVideoId == currentId &&
        _crossfadeFailedQueueKey == queueKey;
    if (alreadyFailedForCurrentAndQueue) return;
    final alreadyPreloaded =
        _preloadedForCurrentVideoId == currentId &&
        _preloadedNextQueueKey == queueKey &&
        (_preloadedNextStreamUrl?.isNotEmpty ?? false);
    if (alreadyPreloaded || _isPreloadingNextTrack) return;

    if (_isMixingEnabled && _trackDuration > Duration.zero) {
      final remaining = _trackDuration - _position;
      // Si faltan muchos segundos todavía, no hace falta insistir en cada tick.
      if (remaining > _effectiveCrossfadePreloadLeadTime()) {
        return;
      }
    }

    _isPreloadingNextTrack = true;
    try {
      final prepared = await _prepareCrossfadePlayerForQueueItem(
        next,
        currentVideoId: currentId,
      );
      if (!prepared) return;
      if (_settingsService.djMode) {
        unawaited(
          _resolveFirstLyricOffsetForQueueItem(next, allowNetwork: true),
        );
        unawaited(
          _resolveDjTransitionPlanForQueueItem(
            next,
            allowNetwork: true,
            incomingDuration: _crossfadePlayer.duration ?? Duration.zero,
            outgoingDuration: _trackDuration,
            outgoingPosition: _position,
          ),
        );
      }
      unawaited(
        _prepareSystemArtwork(
          videoId: next.videoId,
          thumbnailSource: next.thumbnailUrl,
        ),
      );
    } catch (_) {
      // Best effort: si falla preload, seguimos con carga normal.
    } finally {
      _isPreloadingNextTrack = false;
    }
  }

  Future<void> _maybeTriggerCrossfadeAdvance() async {
    if (!_isMixingEnabled || !_autoplayEnabled) return;
    if (_crossfadeTriggeredForCurrent ||
        _isAdvancingQueue ||
        _isLoading ||
        _isCrossfadeTransitioning) {
      return;
    }
    if (_usingHiddenVideo) return;
    if (!_isPlaying || _trackDuration <= Duration.zero) return;
    if (_manualPlaybackQueue.isEmpty && _playbackQueue.isEmpty) return;

    final remaining = _trackDuration - _position;
    Duration? preferredTriggerLead;
    if (_settingsService.djMode) {
      final next = _peekNextQueueItem();
      if (next != null) {
        final plan = await _resolveDjTransitionPlanForQueueItem(
          next,
          allowNetwork: false,
          incomingDuration: _crossfadePlayer.duration ?? Duration.zero,
          outgoingDuration: _trackDuration,
          outgoingPosition: _position,
        );
        preferredTriggerLead = plan?.preferredTriggerLeadTime;
      }
    }
    final triggerLeadTime = _effectiveCrossfadeTriggerLeadTime(
      preferred: preferredTriggerLead,
    );
    final lyricDrivenTrigger = _shouldTriggerDjFromLastLyric();
    if (!lyricDrivenTrigger && remaining > triggerLeadTime) return;
    if (!_crossfadePreparedPrimed) {
      // Intento síncrono final para evitar huecos al llegar al final.
      await _maybePreloadUpcomingQueueTrack();
      if (!_crossfadePreparedPrimed) {
        final next = _peekNextQueueItem();
        if (next != null) {
          final currentId = _currentVideoId;
          if (currentId != null) {
            await _prepareCrossfadePlayerForQueueItem(
              next,
              currentVideoId: currentId,
            );
          }
        }
      }
      if (!_crossfadePreparedPrimed &&
          remaining > const Duration(milliseconds: 900)) {
        return;
      }
    }

    _crossfadeTriggeredForCurrent = true;
    _completionHandledForCurrent = true;
    await _playNextFromQueue(triggeredByCrossfade: true);
  }

  bool _shouldTriggerDjFromLastLyric() {
    if (!_settingsService.djMode) return false;
    if (_syncedLyrics.isEmpty || _trackDuration <= Duration.zero) return false;
    if (_trackDuration.inMilliseconds <= 0) return false;

    final lastIndex = _syncedLyrics.length - 1;
    final currentIndex = currentSyncedLyricIndex;
    if (currentIndex < lastIndex) return false;

    final lastLyricTs = _syncedLyrics[lastIndex].timestamp;
    if (lastLyricTs <= Duration.zero) return false;

    // Evita disparos prematuros por letras mal sincronizadas.
    final lyricProgress =
        lastLyricTs.inMilliseconds / _trackDuration.inMilliseconds;
    if (lyricProgress < 0.55) return false;

    // Pequeña tolerancia para activar cerca del inicio de la última línea.
    final triggerAt = lastLyricTs - const Duration(milliseconds: 180);
    return _position >= (triggerAt > Duration.zero ? triggerAt : Duration.zero);
  }

  Future<void> _warmUpAutoplayQueue(String currentVideoId) async {
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (!_autoplayEnabled || _isLocal || _currentVideoId != currentVideoId) {
      return;
    }
    if (_hasResolvedQueueForVideo(currentVideoId)) return;
    if (_manualPlaybackQueue.isNotEmpty ||
        _playbackQueue.isNotEmpty ||
        _isQueueLoading) {
      return;
    }
    await _loadOnlineQueueFallbackFromCurrentContext(
      currentVideoId: currentVideoId,
    );
  }

  Future<bool> _tryCrossfadeTransitionToPreparedItem(
    PlaybackQueueItem next,
  ) async {
    if (!_isMixingEnabled) return false;
    if (_usingHiddenVideo) return false;
    final currentVideoId = _currentVideoId;
    if (currentVideoId == null) return false;
    final queueKey = _queueItemKey(next);
    final alreadyPrepared =
        _crossfadePreparedQueueKey == queueKey &&
        _preloadedForCurrentVideoId == currentVideoId &&
        _preloadedNextQueueKey == queueKey &&
        (_preloadedNextStreamUrl?.isNotEmpty ?? false);
    final previousTitle = _trackTitle;
    final previousArtist = _trackArtist;
    final previousThumbnail = _trackThumbnailUrl;
    final previousDuration = _trackDuration;
    final previousStreamUrl = _currentStreamUrl;
    final previousIsPlaying = _isPlaying;
    final previousIsBuffering = _isBuffering;
    final outgoingDurationSnapshot = _trackDuration;
    final outgoingPositionSnapshot = _position;

    final currentPlayer = _player;
    final nextPlayer = _crossfadePlayer;
    try {
      if (!alreadyPrepared) {
        final prepared = await _prepareCrossfadePlayerForQueueItem(
          next,
          currentVideoId: currentVideoId,
        );
        if (!prepared) return false;
      }
      if (!_crossfadePreparedPrimed) {
        final primed = await _primeCrossfadePlayerBuffer();
        if (!primed) return false;
      }

      _isCrossfadeTransitioning = true;
      final incomingDuration = nextPlayer.duration ?? Duration.zero;
      final incomingFirstLyricOffset = _settingsService.djMode
          ? await _resolveFirstLyricOffsetForQueueItem(
              next,
              allowNetwork: false,
            )
          : null;
      final djPlan = _settingsService.djMode
          ? await _resolveDjTransitionPlanForQueueItem(
              next,
              allowNetwork: false,
              incomingDuration: incomingDuration,
              outgoingDuration: outgoingDurationSnapshot,
              outgoingPosition: outgoingPositionSnapshot,
              incomingFirstLyricOffset: incomingFirstLyricOffset,
            )
          : null;
      var mixDuration = _resolveMixDuration(
        outgoingDuration: outgoingDurationSnapshot,
        outgoingPosition: outgoingPositionSnapshot,
        incomingDuration: incomingDuration,
        preferredDuration: djPlan?.preferredMixDuration,
      );
      if (_settingsService.djMode && mixDuration > Duration.zero) {
        // Evita forzar time-stretch agresivo: ampliamos un poco la mezcla
        // antes de tener que acelerar de forma audible.
        const maxNaturalOutgoingSpeed = 1.045;
        final remainingMs = math.max(
          1,
          (outgoingDurationSnapshot - outgoingPositionSnapshot).inMilliseconds,
        );
        final currentMixMs = mixDuration.inMilliseconds;
        final neededMixMs = (remainingMs / maxNaturalOutgoingSpeed).round();
        final safeUpperMixMs = math.min(
          _djMaxMixDuration.inMilliseconds,
          math.max(
            _djMinMixDuration.inMilliseconds,
            remainingMs - const Duration(milliseconds: 700).inMilliseconds,
          ),
        );
        if (neededMixMs > currentMixMs && neededMixMs <= safeUpperMixMs) {
          mixDuration = Duration(milliseconds: neededMixMs);
        }
      }
      Duration incomingStartOffset = Duration.zero;
      if (_settingsService.djMode) {
        incomingStartOffset = _resolveDjIncomingStartOffset(
          firstLyricOffset: incomingFirstLyricOffset,
          incomingDuration: incomingDuration,
          mixDuration: mixDuration,
        );
        final plannedOffset = djPlan?.preferredIncomingStartOffset;
        if (plannedOffset != null && plannedOffset > Duration.zero) {
          if (incomingStartOffset <= Duration.zero) {
            incomingStartOffset = plannedOffset;
          } else {
            final blendedMs =
                (incomingStartOffset.inMilliseconds * 0.72 +
                        plannedOffset.inMilliseconds * 0.28)
                    .round();
            incomingStartOffset = Duration(
              milliseconds: math.max(0, blendedMs),
            );
          }
        }
        if (incomingDuration > Duration.zero) {
          final maxOffset =
              incomingDuration - const Duration(milliseconds: 900);
          if (maxOffset > Duration.zero && incomingStartOffset > maxOffset) {
            incomingStartOffset = maxOffset;
          }
        }
        if (incomingStartOffset > Duration.zero) {
          try {
            await nextPlayer.seek(incomingStartOffset);
          } catch (_) {
            incomingStartOffset = Duration.zero;
          }
        }
      }

      await nextPlayer.setVolume(0.0);
      unawaited(nextPlayer.play());
      final ready = await _waitForPlayerReady(nextPlayer);
      if (!ready) return false;
      await _waitForPlayerAudibleStart(
        nextPlayer,
        expectedStart: incomingStartOffset,
      );

      // Refrescamos info visual al track entrante durante la mezcla,
      // pero sin cambiar todavía el id actual hasta completar el swap.
      _trackTitle = next.title;
      _trackArtist = cleanArtistName(next.artist);
      _trackThumbnailUrl = next.thumbnailUrl;
      _trackDuration = Duration.zero;
      _currentStreamUrl = _preloadedNextStreamUrl ?? next.localFilePath;
      _isLoading = false;
      _syncSystemNowPlaying();
      _syncSystemPlaybackState(force: true);
      notifyListeners();

      final targetVolume = _targetPlaybackVolume();
      final totalMs = mixDuration.inMilliseconds;
      final steps = math.max(16, (totalMs / 220).round());
      final stepDelay = Duration(
        milliseconds: math.max(1, (totalMs / steps).round()),
      );
      double outgoingSpeed = 1.0;
      double incomingSpeed = 1.0;
      var outgoingStoppedEarly = false;
      var outgoingCutEndMs = (totalMs * 0.87).round();
      var outgoingCutStartMs = math.max(0, outgoingCutEndMs - 220);
      if (_settingsService.djMode && totalMs > 0) {
        final remainingMs = math.max(
          1,
          (outgoingDurationSnapshot - outgoingPositionSnapshot).inMilliseconds,
        );
        final requiredSpeed = remainingMs / totalMs;
        outgoingSpeed = requiredSpeed.clamp(1.0, 1.055);
        if (outgoingSpeed > 1.005) {
          outgoingSpeed = await _setPlayerSpeedSmooth(
            currentPlayer,
            outgoingSpeed,
            minSpeed: 1.0,
            maxSpeed: 1.06,
          );
        }

        incomingSpeed = _resolveDjIncomingSpeed(
          firstLyricOffset: incomingFirstLyricOffset,
          incomingStartOffset: incomingStartOffset,
          mixDuration: mixDuration,
        );
        final preferredOutgoingSpeed = djPlan?.preferredOutgoingSpeed;
        if (preferredOutgoingSpeed != null && preferredOutgoingSpeed > 0) {
          outgoingSpeed =
              ((outgoingSpeed * 0.62) + (preferredOutgoingSpeed * 0.38)).clamp(
                1.0,
                1.06,
              );
          if (outgoingSpeed > 1.005) {
            outgoingSpeed = await _setPlayerSpeedSmooth(
              currentPlayer,
              outgoingSpeed,
              minSpeed: 1.0,
              maxSpeed: 1.06,
            );
          }
        }
        final preferredIncomingSpeed = djPlan?.preferredIncomingSpeed;
        if (preferredIncomingSpeed != null && preferredIncomingSpeed > 0) {
          incomingSpeed =
              ((incomingSpeed * 0.6) + (preferredIncomingSpeed * 0.4)).clamp(
                0.97,
                1.05,
              );
        }
        if ((incomingSpeed - 1.0).abs() > 0.005) {
          incomingSpeed = await _setPlayerSpeedSmooth(
            nextPlayer,
            incomingSpeed,
            minSpeed: 0.97,
            maxSpeed: 1.05,
          );
        }

        final lyricDistanceMs =
            incomingFirstLyricOffset == null ||
                incomingFirstLyricOffset <= Duration.zero
            ? null
            : (incomingFirstLyricOffset - incomingStartOffset).inMilliseconds;
        if (lyricDistanceMs != null && lyricDistanceMs > 0) {
          final lyricHitMs = (lyricDistanceMs / incomingSpeed).round();
          final clampedHitMs = lyricHitMs.clamp(
            (totalMs * 0.45).round(),
            (totalMs * 0.94).round(),
          );
          outgoingCutEndMs = (clampedHitMs + 140).clamp(
            (totalMs * 0.58).round(),
            (totalMs * 0.95).round(),
          );
          outgoingCutStartMs = math.max(
            (totalMs * 0.46).round(),
            outgoingCutEndMs - 260,
          );
        }
      }
      for (var step = 1; step <= steps; step++) {
        final ratio = step / steps;
        final incomingCurvePower = djPlan?.incomingCurvePower ?? 1.0;
        final outgoingCurvePower = djPlan?.outgoingCurvePower ?? 1.0;
        final curvedInRatio = math.pow(ratio, incomingCurvePower).toDouble();
        final curvedOutRatio = math.pow(ratio, outgoingCurvePower).toDouble();
        final inGain = _settingsService.djMode
            ? math.sin(curvedInRatio * math.pi / 2)
            : ratio;
        final outGain = _settingsService.djMode
            ? math.cos(curvedOutRatio * math.pi / 2)
            : (1.0 - ratio);
        final inVol = targetVolume * inGain;
        var outVol = targetVolume * outGain;
        if (_settingsService.djMode) {
          // En modo DJ mantenemos el track saliente al mismo volumen
          // durante casi toda la mezcla para una transición más "overlay".
          // Solo aplicamos un micro fade-out al final para evitar corte brusco.
          outVol = targetVolume;
          final elapsedMs = (ratio * totalMs).round();
          if (elapsedMs >= outgoingCutStartMs) {
            final fadeWindowMs = math.max(
              1,
              outgoingCutEndMs - outgoingCutStartMs,
            );
            final fadeProgress =
                ((elapsedMs - outgoingCutStartMs) / fadeWindowMs).clamp(
                  0.0,
                  1.0,
                );
            final fadeGain = math.cos(fadeProgress * math.pi / 2);
            outVol *= fadeGain;
          }
          if (!outgoingStoppedEarly && elapsedMs >= outgoingCutEndMs) {
            try {
              await currentPlayer.stop();
            } catch (_) {}
            try {
              await currentPlayer.seek(Duration.zero);
            } catch (_) {}
            try {
              await currentPlayer.setVolume(0.0);
            } catch (_) {}
            outgoingStoppedEarly = true;
          }
        }
        await nextPlayer.setVolume(inVol);
        if (!outgoingStoppedEarly) {
          await currentPlayer.setVolume(outVol);
        }
        await Future<void>.delayed(stepDelay);
      }
      await nextPlayer.setVolume(targetVolume);

      if (!outgoingStoppedEarly) {
        await currentPlayer.stop();
        await currentPlayer.seek(Duration.zero);
        await currentPlayer.setVolume(0.0);
      }
      if (outgoingSpeed > 1.0) {
        try {
          await _setPlayerSpeedSmooth(
            currentPlayer,
            1.0,
            minSpeed: 0.95,
            maxSpeed: 1.08,
          );
        } catch (_) {}
      }
      if ((incomingSpeed - 1.0).abs() > 0.01) {
        try {
          await _setPlayerSpeedSmooth(
            nextPlayer,
            1.0,
            minSpeed: 0.95,
            maxSpeed: 1.08,
          );
        } catch (_) {}
      }

      _rememberCurrentForHistory();
      _player = nextPlayer;
      _crossfadePlayer = currentPlayer;
      _attachActivePlayerSubscriptions();

      _currentVideoId = next.videoId;
      _isLocal = next.isLocal;
      _isMinimized = false;
      _isFullScreen = false;
      _position = Duration.zero;
      _bufferedPosition = Duration.zero;
      _completionHandledForCurrent = false;
      _crossfadeTriggeredForCurrent = false;
      _isPlaying = true;
      _isBuffering = false;
      _usingHiddenVideo = false;
      _resetLyricsState();
      final hasAppliedLocalLyrics = next.isLocal
          ? _applyLocalLyrics(
              plainLyrics: next.localPlainLyrics,
              syncedLyrics: next.localSyncedLyrics,
            )
          : false;
      _sessionPlayedVideoIds.add(next.videoId);
      _crossfadeFailedForCurrentVideoId = null;
      _crossfadeFailedQueueKey = null;
      _clearPreloadedNextTrack();

      if (_isLyricsLayout &&
          (!hasAppliedLocalLyrics ||
              ((_lyricsText?.trim().isEmpty ?? true) &&
                  _syncedLyrics.isEmpty))) {
        unawaited(_loadLyricsForCurrentTrack());
      }

      _isCrossfadeTransitioning = false;
      _syncSystemNowPlaying();
      _syncSystemPlaybackState(force: true);
      notifyListeners();

      unawaited(() async {
        if (next.isLocal) {
          if (_autoplayEnabled &&
              _playbackQueue.length <= _autoplayQueueRefillThreshold) {
            await _loadLocalQueue(currentVideoId: next.videoId);
          }
          final hasLyrics =
              (_lyricsText?.trim().isNotEmpty ?? false) ||
              _syncedLyrics.isNotEmpty;
          if (_isLyricsLayout && !hasAppliedLocalLyrics && !hasLyrics) {
            await _loadLyricsForCurrentTrack();
          }
          return;
        }

        try {
          final video = await _getVideoWithRetry(next.videoId);
          if (_currentVideoId != next.videoId) return;
          _trackTitle = video.title;
          _trackArtist = cleanArtistName(video.author);
          _trackThumbnailUrl = _mergeThumbnailKeepingMusicSquare(
            existing: _trackThumbnailUrl,
            candidate: bestThumbnailForVideo(
              video,
              preferLowResolution: _settingsService.dataSaverMode,
            ),
          );
          _trackDuration = video.duration ?? Duration.zero;
          _syncSystemNowPlaying();
          _syncSystemPlaybackState(force: true);
          notifyListeners();
          final hasLyrics =
              (_lyricsText?.trim().isNotEmpty ?? false) ||
              _syncedLyrics.isNotEmpty;
          if (_isLyricsLayout && !hasLyrics) {
            await _loadLyricsForCurrentTrack();
          }
          if (_autoplayEnabled &&
              _playbackQueue.length <= _autoplayQueueRefillThreshold) {
            await _loadOnlineQueue(video, currentVideoId: next.videoId);
          }
        } catch (_) {
          // Best effort metadata/queue refresh.
        }
      }());

      unawaited(_addCurrentTrackToHistory(next.videoId));
      unawaited(_maybePreloadUpcomingQueueTrack());
      return true;
    } catch (_) {
      _trackTitle = previousTitle;
      _trackArtist = previousArtist;
      _trackThumbnailUrl = previousThumbnail;
      _trackDuration = previousDuration;
      _currentStreamUrl = previousStreamUrl;
      _isPlaying = previousIsPlaying;
      _isBuffering = previousIsBuffering;
      try {
        await currentPlayer.setSpeed(1.0);
      } catch (_) {}
      try {
        await nextPlayer.setSpeed(1.0);
      } catch (_) {}
      try {
        await nextPlayer.stop();
      } catch (_) {}
      _syncSystemNowPlaying();
      _syncSystemPlaybackState(force: true);
      notifyListeners();
      return false;
    } finally {
      if (_isCrossfadeTransitioning) {
        _isCrossfadeTransitioning = false;
        _syncSystemPlaybackState(force: true);
        notifyListeners();
      }
    }
  }

  Future<bool> _prepareCrossfadePlayerForQueueItem(
    PlaybackQueueItem next, {
    required String currentVideoId,
  }) async {
    final queueKey = _queueItemKey(next);
    final alreadyFailedForCurrentAndQueue =
        _crossfadeFailedForCurrentVideoId == currentVideoId &&
        _crossfadeFailedQueueKey == queueKey;
    if (alreadyFailedForCurrentAndQueue) return false;
    final alreadyPrepared =
        _preloadedForCurrentVideoId == currentVideoId &&
        _preloadedNextQueueKey == queueKey &&
        (_preloadedNextStreamUrl?.isNotEmpty ?? false) &&
        _crossfadePreparedQueueKey == queueKey;
    if (alreadyPrepared) return true;

    if (next.isLocal) {
      final localPath = next.localFilePath?.trim() ?? '';
      if (localPath.isEmpty || kIsWeb) return false;
      final localFile = File(localPath);
      if (!await localFile.exists()) return false;
      try {
        await _crossfadePlayer.stop();
        await _crossfadePlayer.setVolume(0.0);
        await _crossfadePlayer.setAudioSource(AudioSource.file(localPath));
        final primed = await _primeCrossfadePlayerBuffer();
        if (!primed) return false;
        _preloadedForCurrentVideoId = currentVideoId;
        _preloadedNextQueueKey = queueKey;
        _preloadedNextStreamUrl = localPath;
        _crossfadePreparedQueueKey = queueKey;
        _crossfadePreparedPrimed = true;
        _crossfadeFailedForCurrentVideoId = null;
        _crossfadeFailedQueueKey = null;
        return true;
      } catch (e) {
        _preloadedForCurrentVideoId = null;
        _preloadedNextQueueKey = null;
        _preloadedNextStreamUrl = null;
        _crossfadePreparedQueueKey = null;
        _crossfadePreparedPrimed = false;
        _crossfadeFailedForCurrentVideoId = currentVideoId;
        _crossfadeFailedQueueKey = queueKey;
        log(
          'No se pudo preparar crossfade local para ${next.videoId}',
          error: e,
        );
        return false;
      }
    }

    final manifest = await _getManifestWithRetry(next.videoId);
    final audioStreams = manifest.audioOnly.toList();
    if (audioStreams.isEmpty && manifest.muxed.isEmpty) return false;
    final ordered = _prioritizeAudioStreams(audioStreams);
    final orderedMuxed = _prioritizeMuxedStreams(manifest.muxed.toList());

    final candidateUris = <Uri>[];
    final seenCandidateUrls = <String>{};
    for (final stream in ordered) {
      final key = stream.url.toString();
      if (seenCandidateUrls.add(key)) {
        candidateUris.add(stream.url);
      }
    }
    for (final stream in orderedMuxed) {
      final key = stream.url.toString();
      if (seenCandidateUrls.add(key)) {
        candidateUris.add(stream.url);
      }
    }
    if (candidateUris.isEmpty) return false;

    Object? lastError;
    for (final uri in candidateUris) {
      final headerCandidates = _crossfadeHeaderCandidatesForUri(uri);
      for (final headers in headerCandidates) {
        try {
          await _crossfadePlayer.stop();
          await _crossfadePlayer.setVolume(0.0);
          if (headers == null || headers.isEmpty) {
            await _crossfadePlayer.setAudioSource(AudioSource.uri(uri));
          } else {
            await _crossfadePlayer.setAudioSource(
              AudioSource.uri(uri, headers: headers),
            );
          }
          final primed = await _primeCrossfadePlayerBuffer();
          if (!primed) {
            lastError = Exception('Crossfade source not primed');
            continue;
          }
          _preloadedForCurrentVideoId = currentVideoId;
          _preloadedNextQueueKey = queueKey;
          _preloadedNextStreamUrl = uri.toString();
          _crossfadePreparedQueueKey = queueKey;
          _crossfadePreparedPrimed = true;
          _crossfadeFailedForCurrentVideoId = null;
          _crossfadeFailedQueueKey = null;
          return true;
        } catch (e) {
          lastError = e;
        }
      }
    }
    _preloadedForCurrentVideoId = null;
    _preloadedNextQueueKey = null;
    _preloadedNextStreamUrl = null;
    _crossfadePreparedQueueKey = null;
    _crossfadePreparedPrimed = false;
    _crossfadeFailedForCurrentVideoId = currentVideoId;
    _crossfadeFailedQueueKey = queueKey;
    if (lastError != null) {
      log(
        'No se pudo preparar player de crossfade para ${next.videoId}',
        error: lastError,
      );
    }
    return false;
  }

  Future<bool> _primeCrossfadePlayerBuffer() async {
    try {
      await _crossfadePlayer.load();
      await _crossfadePlayer.setVolume(0.0);
      await _crossfadePlayer.seek(Duration.zero);
      await _crossfadePlayer.pause();
      return await _waitForPlayerBuffered(_crossfadePlayer);
    } catch (_) {
      return false;
    }
  }

  Future<bool> _waitForPlayerBuffered(AudioPlayer player) async {
    final state = player.playerState;
    if (state.processingState != ProcessingState.idle &&
        state.processingState != ProcessingState.loading) {
      return true;
    }
    try {
      await player.playerStateStream
          .firstWhere(
            (s) =>
                s.processingState != ProcessingState.idle &&
                s.processingState != ProcessingState.loading,
          )
          .timeout(const Duration(seconds: 6));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _waitForPlayerReady(AudioPlayer player) async {
    final state = player.playerState;
    if (state.playing &&
        state.processingState != ProcessingState.idle &&
        state.processingState != ProcessingState.loading) {
      return true;
    }
    try {
      await player.playerStateStream
          .firstWhere(
            (s) =>
                s.playing &&
                s.processingState != ProcessingState.idle &&
                s.processingState != ProcessingState.loading,
          )
          .timeout(const Duration(seconds: 6));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _waitForPlayerAudibleStart(
    AudioPlayer player, {
    Duration expectedStart = Duration.zero,
  }) async {
    final startedAt = DateTime.now();
    final baseline = expectedStart > Duration.zero
        ? expectedStart
        : Duration.zero;
    while (DateTime.now().difference(startedAt) <
        _crossfadeAudibleStartTimeout) {
      final state = player.playerState;
      if (!state.playing) break;
      final advanced = player.position - baseline;
      if (advanced >= _crossfadeAudibleMinAdvance) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 45));
    }
  }

  void _rememberCurrentForHistory() {
    if (_skipHistoryPushOnce) {
      _skipHistoryPushOnce = false;
      return;
    }

    final currentId = _currentVideoId;
    final currentTitle = _trackTitle;
    final currentThumb = _trackThumbnailUrl;
    final currentArtist = cleanArtistName(_trackArtist);
    if (currentId == null ||
        currentTitle == null ||
        currentTitle.isEmpty ||
        currentThumb == null ||
        currentArtist.isEmpty) {
      return;
    }

    final item = PlaybackQueueItem(
      videoId: currentId,
      title: currentTitle,
      thumbnailUrl: currentThumb,
      artist: currentArtist,
      isLocal: _isLocal,
      localFilePath: _isLocal ? _currentStreamUrl : null,
    );

    if (_playbackHistory.isNotEmpty &&
        _playbackHistory.last.videoId == item.videoId &&
        _playbackHistory.last.isLocal == item.isLocal) {
      return;
    }
    _playbackHistory.add(item);
    if (_playbackHistory.length > 50) {
      _playbackHistory.removeAt(0);
    }
  }

  void _rememberRecommendedQueue(List<PlaybackQueueItem> queue) {
    if (queue.isEmpty) return;
    for (final item in queue.take(40)) {
      if (item.isLocal) continue;
      final id = item.videoId.trim();
      if (id.isEmpty) continue;
      if (_recentRecommendedVideoIds.add(id)) {
        _recentRecommendedOrder.add(id);
      }
    }
    while (_recentRecommendedOrder.length > 260) {
      final oldest = _recentRecommendedOrder.removeAt(0);
      _recentRecommendedVideoIds.remove(oldest);
    }
  }

  void _clearQueueForAutoplayDisabled() {
    ++_queueEpoch;
    _playbackQueue = const [];
    _isQueueLoading = false;
    _queueTitle = 'Siguiente';
    _queueSeedVideoId = null;
    _clearPreloadedNextTrack();
  }

  void _removeFromQueues(PlaybackQueueItem item) {
    _manualPlaybackQueue = _manualPlaybackQueue
        .where(
          (entry) =>
              !(entry.videoId == item.videoId && entry.isLocal == item.isLocal),
        )
        .toList(growable: false);
    _playbackQueue = _playbackQueue
        .where(
          (entry) =>
              !(entry.videoId == item.videoId && entry.isLocal == item.isLocal),
        )
        .toList(growable: false);
    final currentId = _currentVideoId;
    if (currentId != null &&
        _preloadedForCurrentVideoId == currentId &&
        _preloadedNextQueueKey == _queueItemKey(item)) {
      _clearPreloadedNextTrack();
    }
  }

  Future<void> _reloadQueueForCurrentTrack() async {
    final currentId = _currentVideoId;
    if (currentId == null || !_autoplayEnabled) return;

    if (_isLocal) {
      await _loadLocalQueue(currentVideoId: currentId);
      return;
    }

    try {
      final video = await _getVideoWithRetry(currentId);
      if (_currentVideoId != currentId || !_autoplayEnabled) return;
      await _loadOnlineQueue(video, currentVideoId: currentId);
    } catch (e, s) {
      log('Error recargando cola para autoplay', error: e, stackTrace: s);
    }
  }

  String _lyricsLookupKey({String? artist, String? title}) {
    final normalizedArtist = (artist ?? '').trim();
    final normalizedTitle = (title ?? '').trim();
    return '$normalizedArtist::$normalizedTitle'.toLowerCase();
  }

  Duration? _firstSyncedLyricOffset(List<SyncedLyricLine> lines) {
    for (final line in lines) {
      final ts = line.timestamp;
      if (ts > const Duration(milliseconds: 100) &&
          line.text.trim().isNotEmpty) {
        return ts;
      }
    }
    return null;
  }

  String _djTransitionPairKey(PlaybackQueueItem next) {
    final currentId = _currentVideoId?.trim();
    final currentScope = _isLocal ? 'local' : 'online';
    final current = currentId == null || currentId.isEmpty
        ? 'unknown'
        : '$currentScope:$currentId';
    final upcoming = _queueItemKey(next);
    return '$current=>$upcoming';
  }

  double _estimateTrackEnergyScore({
    required String title,
    required String artist,
  }) {
    final haystack = '$title $artist'.toLowerCase();
    const highEnergyHints = <String>{
      'remix',
      'club',
      'dance',
      'edm',
      'house',
      'techno',
      'dnb',
      'drum and bass',
      'hardstyle',
      'trap',
      'party',
      'mix',
      'radio edit',
    };
    const lowEnergyHints = <String>{
      'acoustic',
      'piano',
      'live',
      'ballad',
      'orchestral',
      'unplugged',
      'lofi',
      'chill',
      'instrumental',
      'version',
      'slow',
    };

    var score = 1.0;
    for (final hint in highEnergyHints) {
      if (haystack.contains(hint)) {
        score += 0.12;
      }
    }
    for (final hint in lowEnergyHints) {
      if (haystack.contains(hint)) {
        score -= 0.11;
      }
    }
    return score.clamp(0.72, 1.38);
  }

  _DjTransitionPlan _buildHeuristicDjTransitionPlan({
    required PlaybackQueueItem next,
    required Duration incomingDuration,
    required Duration outgoingDuration,
    required Duration outgoingPosition,
    required Duration? incomingFirstLyricOffset,
  }) {
    final currentTitle = _trackTitle ?? '';
    final currentArtist = cleanArtistName(_trackArtist);
    final outgoingEnergy = _estimateTrackEnergyScore(
      title: currentTitle,
      artist: currentArtist,
    );
    final incomingEnergy = _estimateTrackEnergyScore(
      title: next.title,
      artist: next.artist,
    );
    final energyDelta = incomingEnergy - outgoingEnergy;
    final hasLyricAnchor =
        incomingFirstLyricOffset != null &&
        incomingFirstLyricOffset > Duration.zero;

    final baseMix = _resolveMixDuration(
      outgoingDuration: outgoingDuration,
      outgoingPosition: outgoingPosition,
      incomingDuration: incomingDuration,
    );
    final adjustedMixMs = (baseMix.inMilliseconds + (energyDelta * 820).round())
        .clamp(
          _djMinMixDuration.inMilliseconds,
          _djMaxMixDuration.inMilliseconds,
        );
    final mixDuration = Duration(milliseconds: adjustedMixMs);

    var triggerMs = mixDuration.inMilliseconds + (hasLyricAnchor ? 1900 : 2400);
    if (energyDelta > 0.22) triggerMs += 450;
    if (energyDelta < -0.2) triggerMs -= 450;
    final triggerLeadTime = Duration(
      milliseconds: triggerMs.clamp(7000, 14000),
    );

    final incomingOffset = _resolveDjIncomingStartOffset(
      firstLyricOffset: incomingFirstLyricOffset,
      incomingDuration: incomingDuration,
      mixDuration: mixDuration,
    );

    final incomingCurvePower = (1.0 - (energyDelta * 0.33)).clamp(0.78, 1.22);
    final outgoingCurvePower = (1.0 + (energyDelta * 0.28)).clamp(0.78, 1.22);

    return _DjTransitionPlan(
      preferredMixDuration: mixDuration,
      preferredTriggerLeadTime: triggerLeadTime,
      preferredIncomingStartOffset: incomingOffset > Duration.zero
          ? incomingOffset
          : null,
      preferredOutgoingSpeed: null,
      preferredIncomingSpeed: null,
      incomingCurvePower: incomingCurvePower,
      outgoingCurvePower: outgoingCurvePower,
    );
  }

  Future<_DjTransitionPlan?> _resolveDjTransitionPlanForQueueItem(
    PlaybackQueueItem next, {
    required bool allowNetwork,
    required Duration incomingDuration,
    required Duration outgoingDuration,
    required Duration outgoingPosition,
    Duration? incomingFirstLyricOffset,
  }) async {
    if (!_settingsService.djMode) return null;
    final pairKey = _djTransitionPairKey(next);
    final cached = _djTransitionPlanCache[pairKey];
    if (cached != null) return cached;

    final resolvedIncomingFirstLyric =
        incomingFirstLyricOffset ??
        await _resolveFirstLyricOffsetForQueueItem(
          next,
          allowNetwork: allowNetwork,
        );
    final fallback = _buildHeuristicDjTransitionPlan(
      next: next,
      incomingDuration: incomingDuration,
      outgoingDuration: outgoingDuration,
      outgoingPosition: outgoingPosition,
      incomingFirstLyricOffset: resolvedIncomingFirstLyric,
    );
    _storeDjTransitionPlan(pairKey, fallback);
    return fallback;
  }

  void _storeDjTransitionPlan(String key, _DjTransitionPlan value) {
    _djTransitionPlanCache[key] = value;
    while (_djTransitionPlanCache.length > 260) {
      final oldest = _djTransitionPlanCache.keys.first;
      _djTransitionPlanCache.remove(oldest);
    }
  }

  Future<Duration?> _resolveFirstLyricOffsetForQueueItem(
    PlaybackQueueItem item, {
    required bool allowNetwork,
  }) async {
    final queueKey = _queueItemKey(item);
    if (_djFirstLyricOffsetCache.containsKey(queueKey)) {
      return _djFirstLyricOffsetCache[queueKey];
    }
    final inFlight = _djFirstLyricOffsetRequests[queueKey];
    if (inFlight != null) return inFlight;

    final request = () async {
      // 1) Fuente local directa (descargadas).
      final localSynced = item.localSyncedLyrics?.trim();
      if (localSynced != null && localSynced.isNotEmpty) {
        final parsed = _lyricsService.parseSyncedLyrics(localSynced);
        final first = _firstSyncedLyricOffset(parsed);
        _djFirstLyricOffsetCache[queueKey] = first;
        return first;
      }

      // 2) Caché global de letras sincronizadas.
      final lyricsKey = _lyricsLookupKey(
        artist: item.artist,
        title: item.title,
      );
      final cachedSynced = _syncedLyricsCache[lyricsKey];
      if (cachedSynced != null && cachedSynced.isNotEmpty) {
        final first = _firstSyncedLyricOffset(cachedSynced);
        _djFirstLyricOffsetCache[queueKey] = first;
        return first;
      }

      if (!allowNetwork) {
        _djFirstLyricOffsetCache[queueKey] = null;
        return null;
      }

      // 3) Best effort online con timeout corto para no bloquear.
      final result = await _lyricsService
          .fetchLyrics(title: item.title, artist: item.artist)
          .timeout(const Duration(seconds: 3), onTimeout: () => null);
      if (result == null) {
        _djFirstLyricOffsetCache[queueKey] = null;
        return null;
      }

      _lyricsCache[lyricsKey] = result.plainLyrics;
      _syncedLyricsCache[lyricsKey] = List<SyncedLyricLine>.from(
        result.syncedLyrics,
      );
      final first = _firstSyncedLyricOffset(result.syncedLyrics);
      _djFirstLyricOffsetCache[queueKey] = first;
      return first;
    }();

    _djFirstLyricOffsetRequests[queueKey] = request;
    try {
      return await request;
    } finally {
      _djFirstLyricOffsetRequests.remove(queueKey);
    }
  }

  void _resetLyricsState() {
    ++_lyricsEpoch;
    _isLyricsLoading = false;
    _lyricsText = null;
    _lyricsError = null;
    _syncedLyrics = const [];
  }

  Future<void> _loadLyricsForCurrentTrack() async {
    final requestVideoId = (_currentVideoId ?? '').trim();
    final title = _trackTitle?.trim();
    final artist = cleanArtistName(_trackArtist);
    if (title == null || title.isEmpty) {
      _lyricsText = null;
      _lyricsError = 'No se pudo identificar la canción para buscar letra.';
      _isLyricsLoading = false;
      notifyListeners();
      return;
    }

    final key = '$artist::$title'.toLowerCase();
    final cached = _lyricsCache[key];
    final cachedSynced = _syncedLyricsCache[key] ?? const <SyncedLyricLine>[];
    if (cached != null && cached.isNotEmpty) {
      _lyricsText = cached;
      _syncedLyrics = cachedSynced;
      _lyricsError = null;
      _isLyricsLoading = false;
      notifyListeners();
      // Si ya tenemos sincronizadas en caché, no hace falta pedir otra vez.
      if (cachedSynced.isNotEmpty) {
        return;
      }
      // Si solo hay letra plana en caché, seguimos y refrescamos en background
      // para intentar recuperar la versión sincronizada.
    }

    final hadCachedPlain = cached != null && cached.isNotEmpty;
    final requestId = ++_lyricsEpoch;
    if (!hadCachedPlain) {
      _isLyricsLoading = true;
      _lyricsError = null;
      _lyricsText = null;
      _syncedLyrics = const [];
      notifyListeners();
    }

    LyricsResult? result;
    try {
      result = await _lyricsService.fetchLyrics(title: title, artist: artist);
    } catch (e, s) {
      if (requestId != _lyricsEpoch) return;
      if ((_currentVideoId ?? '').trim() != requestVideoId) return;
      _isLyricsLoading = false;
      if (hadCachedPlain) {
        _lyricsError = null;
      } else {
        _lyricsText = null;
        _syncedLyrics = const [];
        _lyricsError =
            'No se pudo cargar la letra por un error temporal. Intenta de nuevo.';
      }
      notifyListeners();
      log('Error cargando letra', error: e, stackTrace: s);
      return;
    }

    if (requestId != _lyricsEpoch) return;
    if ((_currentVideoId ?? '').trim() != requestVideoId) return;
    _isLyricsLoading = false;

    if (result == null || result.plainLyrics.trim().isEmpty) {
      if (hadCachedPlain) {
        // Conservamos letra previa si existía.
        _lyricsError = null;
        notifyListeners();
        return;
      }
      _lyricsText = null;
      _syncedLyrics = const [];
      _lyricsError = 'No encontramos la letra de esta canción.';
      notifyListeners();
      return;
    }

    _lyricsCache[key] = result.plainLyrics;
    _syncedLyricsCache[key] = List<SyncedLyricLine>.from(result.syncedLyrics);
    _lyricsText = result.plainLyrics;
    _syncedLyrics = result.syncedLyrics;
    _lyricsError = null;
    notifyListeners();
  }

  bool _applyLocalLyrics({String? plainLyrics, String? syncedLyrics}) {
    final localPlain = plainLyrics?.trim();
    final localSynced = syncedLyrics?.trim();
    if ((localPlain == null || localPlain.isEmpty) &&
        (localSynced == null || localSynced.isEmpty)) {
      return false;
    }

    if (localSynced != null && localSynced.isNotEmpty) {
      final parsed = _lyricsService.parseSyncedLyrics(localSynced);
      if (parsed.isNotEmpty) {
        _syncedLyrics = parsed;
      }
      final cleaned = localPlain ?? _stripLrcTimestamps(localSynced);
      _lyricsText = cleaned;
      _lyricsError = null;
      _isLyricsLoading = false;
      return true;
    }

    if (localPlain != null && localPlain.isNotEmpty) {
      _lyricsText = localPlain;
      _lyricsError = null;
      _isLyricsLoading = false;
      return true;
    }
    return false;
  }

  String _stripLrcTimestamps(String lrc) {
    return lrc
        .split('\n')
        .map((line) => line.replaceAll(RegExp(r'\[[0-9:.]+\]'), '').trim())
        .where((line) => line.isNotEmpty)
        .join('\n');
  }

  String _buildPlaybackErrorMessage(
    Object error, {
    bool isLocalPlayback = false,
  }) {
    final raw = error.toString();
    if (error is RequestLimitExceededException) {
      return 'No se pudo reproducir porque YouTube limitó temporalmente la solicitud. Intenta de nuevo en unos minutos.';
    }
    if (error is SocketException) {
      return isLocalPlayback
          ? 'No se pudo reproducir el archivo local por un problema de acceso al sistema de archivos.'
          : 'No se pudo reproducir por un problema de conexión a internet.';
    }
    if (error is HandshakeException) {
      return 'No se pudo establecer una conexión segura (TLS) con el servidor de audio. Intenta de nuevo o cambia de red.';
    }
    if (error is HttpException) {
      return 'No se pudo reproducir porque el servidor respondió con un error de red.';
    }
    if (raw.contains('No se encontraron streams de audio')) {
      return 'No se pudo reproducir porque no se encontró un stream de audio compatible para esta canción.';
    }
    if (raw.contains('No se pudo iniciar audio ni fallback de video')) {
      return 'No se pudo reproducir porque falló tanto el stream de audio como el fallback de video.';
    }
    if (raw.contains('El archivo local no existe')) {
      return 'No se pudo reproducir porque el archivo descargado ya no existe en el dispositivo.';
    }
    if (raw.contains('No se pudo reproducir el archivo descargado')) {
      return 'No se pudo reproducir el archivo descargado. Puede estar dañado o incompleto.';
    }
    return isLocalPlayback
        ? 'No se pudo reproducir el archivo local: $raw'
        : 'No se pudo reproducir esta canción: $raw';
  }
}
