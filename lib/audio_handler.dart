

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

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
  final _player = AudioPlayer();
  final List<MediaItem> _items = [];

  MyAudioHandler() {
    _player.playbackEventStream.map(_transformEvent).pipe(playbackState);
    _listenForCurrentSongIndexChanges();
  }

  void _listenForCurrentSongIndexChanges() {
    _player.currentIndexStream.listen((index) {
      if (index != null && mediaItem.value != null) {
        mediaItem.add(mediaItem.value);
      }
    });
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> addQueueItem(MediaItem mediaItem) async {
    final audioSource = _createAudioSource(mediaItem);
    await _player.setAudioSource(audioSource);
    _items
      ..clear()
      ..add(mediaItem);
    queue.add(List.unmodifiable(_items));
    this.mediaItem.add(mediaItem);
  }

  @override
  Future<void> updateQueue(List<MediaItem> queue) async {
    _items
      ..clear()
      ..addAll(queue);
    final audioSources = queue.map(_createAudioSource).toList();
    await _player.setAudioSources(audioSources);
    this.queue.add(queue);
  }


  AudioSource _createAudioSource(MediaItem mediaItem) {
  // Support for online and offline playback
  if (mediaItem.extras?['isLocal'] == true) {
    return AudioSource.file(mediaItem.id, tag: mediaItem);
  } else {
    return AudioSource.uri(Uri.parse(mediaItem.id), tag: mediaItem);
  }
}


  PlaybackState _transformEvent(PlaybackEvent event) {
    return PlaybackState(
      controls: [
        MediaControl.rewind,
        if (_player.playing) MediaControl.pause else MediaControl.play,
        MediaControl.stop,
        MediaControl.fastForward,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 3],
      processingState: _mapProcessingState(_player.processingState),
      playing: _player.playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: event.currentIndex,
      // Announce the update time to the system so it knows when the state was last updated.
      updateTime: DateTime.now(),
    );
  }

  AudioProcessingState _mapProcessingState(ProcessingState processingState) {
    switch (processingState) {
      case ProcessingState.idle:
        return AudioProcessingState.idle;
      case ProcessingState.loading:
        return AudioProcessingState.loading;
      case ProcessingState.buffering:
        return AudioProcessingState.buffering;
      case ProcessingState.ready:
        return AudioProcessingState.ready;
      case ProcessingState.completed:
        return AudioProcessingState.completed;
    }
  }
}
