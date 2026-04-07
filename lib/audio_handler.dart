
import 'package:audio_service/audio_service.dart';

Future<AudioHandler> initAudioService() async {
  return await AudioService.init(
    builder: () => MyAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.mycompany.myapp.audio',
      androidNotificationChannelName: 'Audio Service',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
    ),
  );
}

class SilentAudioHandler extends BaseAudioHandler {}

class MyAudioHandler extends BaseAudioHandler {
  Future<void> Function()? _onPlayRequested;
  Future<void> Function()? _onPauseRequested;
  Future<void> Function()? _onSkipNextRequested;
  Future<void> Function()? _onSkipPreviousRequested;
  Future<void> Function(Duration position)? _onSeekRequested;
  Future<void> Function()? _onStopRequested;

  bool _isPlaying = false;
  AudioProcessingState _processing = AudioProcessingState.idle;
  Duration _position = Duration.zero;
  Duration _bufferedPosition = Duration.zero;
  double _speed = 1.0;

  MyAudioHandler() {
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          MediaControl.play,
          MediaControl.pause,
          MediaControl.skipToNext,
          MediaControl.stop,
        ],
        systemActions: {
          MediaAction.seek,
          MediaAction.skipToNext,
          MediaAction.skipToPrevious,
          MediaAction.play,
          MediaAction.pause,
          MediaAction.stop,
        },
        processingState: AudioProcessingState.idle,
        playing: false,
        updatePosition: Duration.zero,
        bufferedPosition: Duration.zero,
        speed: 1.0,
      ),
    );
  }

  void bindCallbacks({
    Future<void> Function()? onPlayRequested,
    Future<void> Function()? onPauseRequested,
    Future<void> Function()? onSkipNextRequested,
    Future<void> Function()? onSkipPreviousRequested,
    Future<void> Function(Duration position)? onSeekRequested,
    Future<void> Function()? onStopRequested,
  }) {
    _onPlayRequested = onPlayRequested;
    _onPauseRequested = onPauseRequested;
    _onSkipNextRequested = onSkipNextRequested;
    _onSkipPreviousRequested = onSkipPreviousRequested;
    _onSeekRequested = onSeekRequested;
    _onStopRequested = onStopRequested;
  }

  void syncNowPlaying({
    required String id,
    required String title,
    required String artist,
    Uri? artUri,
    Duration? duration,
    Map<String, dynamic>? extras,
  }) {
    final item = MediaItem(
      id: id,
      title: title,
      artist: artist,
      artUri: artUri,
      duration: duration,
      extras: extras,
    );
    mediaItem.add(item);
    queue.add([item]);
  }

  void clearNowPlaying() {
    mediaItem.add(null);
    queue.add(const []);
  }

  void syncPlaybackState({
    required bool playing,
    required bool buffering,
    required Duration position,
    required Duration bufferedPosition,
    double speed = 1.0,
  }) {
    _isPlaying = playing;
    _processing = buffering
        ? AudioProcessingState.buffering
        : (playing ? AudioProcessingState.ready : AudioProcessingState.ready);
    _position = position;
    _bufferedPosition = bufferedPosition;
    _speed = speed;
    _emitPlaybackState();
  }

  void syncStopped() {
    _isPlaying = false;
    _processing = AudioProcessingState.idle;
    _position = Duration.zero;
    _bufferedPosition = Duration.zero;
    _speed = 1.0;
    _emitPlaybackState();
  }

  void _emitPlaybackState() {
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          _isPlaying ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.stop,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.skipToNext,
          MediaAction.skipToPrevious,
          MediaAction.play,
          MediaAction.pause,
          MediaAction.stop,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: _processing,
        playing: _isPlaying,
        updatePosition: _position,
        bufferedPosition: _bufferedPosition,
        speed: _speed,
        updateTime: DateTime.now(),
      ),
    );
  }

  @override
  Future<void> play() async {
    await _onPlayRequested?.call();
  }

  @override
  Future<void> pause() async {
    await _onPauseRequested?.call();
  }

  @override
  Future<void> seek(Duration position) async {
    await _onSeekRequested?.call(position);
  }

  @override
  Future<void> skipToNext() async {
    await _onSkipNextRequested?.call();
  }

  @override
  Future<void> skipToPrevious() async {
    await _onSkipPreviousRequested?.call();
  }

  @override
  Future<void> stop() async {
    await _onStopRequested?.call();
    syncStopped();
  }
}
