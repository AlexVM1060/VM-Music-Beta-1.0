import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

enum AudioQualityPreference { automatic, low, normal, high, veryHigh }

enum TransitionMode { off, crossfade, dj }

class AppSettingsService extends ChangeNotifier {
  static const String _boxName = 'app_settings';
  static const String _audioQualityKey = 'audio_quality';
  static const String _normalizeVolumeKey = 'normalize_volume';
  static const String _crossfadeKey = 'crossfade';
  static const String _djModeKey = 'dj_mode';
  static const String _downloadOnlyOnWifiKey = 'download_only_on_wifi';
  static const String _explicitContentKey = 'explicit_content';
  static const String _animatedCutoutCoversKey = 'animated_cutout_covers';
  static const String _liveLyricsKey = 'live_lyrics';
  static const String _vmMusicSingEnabledKey = 'vm_music_sing_enabled';
  static const String _dataSaverModeKey = 'data_saver_mode';
  static const String _backendOnlyPlaybackKey = 'backend_only_playback';

  late final Box _box;
  bool _initialized = false;
  bool _persistenceAvailable = false;
  Future<void>? _initFuture;

  AudioQualityPreference _audioQuality = AudioQualityPreference.high;
  bool _normalizeVolume = true;
  bool _crossfade = false;
  bool _djMode = false;
  bool _downloadOnlyOnWifi = true;
  bool _allowExplicitContent = true;
  bool _animatedCutoutCovers = true;
  bool _liveLyrics = true;
  bool _vmMusicSingEnabled = false;
  bool _dataSaverMode = false;
  bool _backendOnlyPlayback = false;

  bool get initialized => _initialized;
  AudioQualityPreference get audioQuality => _audioQuality;
  bool get normalizeVolume => _normalizeVolume;
  bool get crossfade => _crossfade;
  bool get djMode => _djMode;
  TransitionMode get transitionMode {
    if (_djMode) return TransitionMode.dj;
    if (_crossfade) return TransitionMode.crossfade;
    return TransitionMode.off;
  }

  bool get downloadOnlyOnWifi => _downloadOnlyOnWifi;
  bool get allowExplicitContent => _allowExplicitContent;
  bool get animatedCutoutCovers => _animatedCutoutCovers;
  bool get liveLyrics => _liveLyrics;
  bool get vmMusicSingEnabled => _vmMusicSingEnabled;
  bool get dataSaverMode => _dataSaverMode;
  bool get backendOnlyPlayback => _backendOnlyPlayback;

  Future<void> init() async {
    if (_initialized) return;
    final pendingInit = _initFuture;
    if (pendingInit != null) {
      await pendingInit;
      return;
    }

    _initFuture = _initInternal();
    try {
      await _initFuture;
    } finally {
      _initFuture = null;
    }
  }

  Future<void> _initInternal() async {
    if (_initialized) return;

    try {
      if (Hive.isBoxOpen(_boxName)) {
        _box = Hive.box(_boxName);
      } else {
        _box = await Hive.openBox(_boxName);
      }
      _persistenceAvailable = true;
    } on FileSystemException catch (_) {
      // If another instance still holds the lock, keep the app running with defaults.
      _persistenceAvailable = false;
      _initialized = true;
      return;
    }
    _audioQuality = _audioQualityFromRaw(
      _box.get(
        _audioQualityKey,
        defaultValue: AudioQualityPreference.high.name,
      ),
    );
    _normalizeVolume =
        _box.get(_normalizeVolumeKey, defaultValue: true) == true;
    _crossfade = _box.get(_crossfadeKey, defaultValue: false) == true;
    _djMode = _box.get(_djModeKey, defaultValue: false) == true;
    if (_djMode && !_crossfade) {
      _crossfade = true;
      await _box.put(_crossfadeKey, true);
    }
    _downloadOnlyOnWifi =
        _box.get(_downloadOnlyOnWifiKey, defaultValue: true) == true;
    _allowExplicitContent =
        _box.get(_explicitContentKey, defaultValue: true) == true;
    _animatedCutoutCovers =
        _box.get(_animatedCutoutCoversKey, defaultValue: true) == true;
    _liveLyrics = _box.get(_liveLyricsKey, defaultValue: true) == true;
    _vmMusicSingEnabled =
        _box.get(_vmMusicSingEnabledKey, defaultValue: false) == true;
    _dataSaverMode = _box.get(_dataSaverModeKey, defaultValue: false) == true;
    _backendOnlyPlayback =
        _box.get(_backendOnlyPlaybackKey, defaultValue: false) == true;
    _initialized = true;
  }

  Future<void> _put(String key, Object? value) async {
    if (!_persistenceAvailable) return;
    await _box.put(key, value);
  }

  AudioQualityPreference _audioQualityFromRaw(Object? raw) {
    final value = raw?.toString().trim() ?? '';
    for (final option in AudioQualityPreference.values) {
      if (option.name == value) return option;
    }
    return AudioQualityPreference.high;
  }

  Future<void> setAudioQuality(AudioQualityPreference value) async {
    if (_audioQuality == value) return;
    _audioQuality = value;
    await _put(_audioQualityKey, value.name);
    notifyListeners();
  }

  Future<void> setNormalizeVolume(bool value) async {
    if (_normalizeVolume == value) return;
    _normalizeVolume = value;
    await _put(_normalizeVolumeKey, value);
    notifyListeners();
  }

  Future<void> setCrossfade(bool value) async {
    await setTransitionMode(
      value ? TransitionMode.crossfade : TransitionMode.off,
    );
  }

  Future<void> setDjMode(bool value) async {
    await setTransitionMode(value ? TransitionMode.dj : TransitionMode.off);
  }

  Future<void> setTransitionMode(TransitionMode mode) async {
    if (transitionMode == mode) return;
    switch (mode) {
      case TransitionMode.off:
        _crossfade = false;
        _djMode = false;
        break;
      case TransitionMode.crossfade:
        _crossfade = true;
        _djMode = false;
        break;
      case TransitionMode.dj:
        _crossfade = true; // Requerido internamente para mezclar.
        _djMode = true;
        break;
    }
    await _put(_crossfadeKey, _crossfade);
    await _put(_djModeKey, _djMode);
    notifyListeners();
  }

  Future<void> setDownloadOnlyOnWifi(bool value) async {
    if (_downloadOnlyOnWifi == value) return;
    _downloadOnlyOnWifi = value;
    await _put(_downloadOnlyOnWifiKey, value);
    notifyListeners();
  }

  Future<void> setAllowExplicitContent(bool value) async {
    if (_allowExplicitContent == value) return;
    _allowExplicitContent = value;
    await _put(_explicitContentKey, value);
    notifyListeners();
  }

  Future<void> setAnimatedCutoutCovers(bool value) async {
    if (_animatedCutoutCovers == value) return;
    _animatedCutoutCovers = value;
    await _put(_animatedCutoutCoversKey, value);
    notifyListeners();
  }

  Future<void> setLiveLyrics(bool value) async {
    if (_liveLyrics == value) return;
    _liveLyrics = value;
    await _put(_liveLyricsKey, value);
    notifyListeners();
  }

  Future<void> setVmMusicSingEnabled(bool value) async {
    if (_vmMusicSingEnabled == value) return;
    _vmMusicSingEnabled = value;
    await _put(_vmMusicSingEnabledKey, value);
    notifyListeners();
  }

  Future<void> setDataSaverMode(bool value) async {
    if (_dataSaverMode == value) return;
    _dataSaverMode = value;
    await _put(_dataSaverModeKey, value);
    notifyListeners();
  }

  Future<void> setBackendOnlyPlayback(bool value) async {
    if (_backendOnlyPlayback == value) return;
    _backendOnlyPlayback = value;
    await _put(_backendOnlyPlaybackKey, value);
    notifyListeners();
  }
}
