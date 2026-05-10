import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';

class SongStreamCacheService {
  static const String _boxName = 'song_stream_cache';
  static const String _entriesKey = 'entries_v1';
  static const Duration _ttl = Duration(days: 3);
  static const int _maxEntries = 120;
  static const int _maxFileBytes = 220 * 1024 * 1024;
  static const int _maxTotalBytes = 2 * 1024 * 1024 * 1024;
  static const Map<String, String> _youtubeHeaders = {
    'User-Agent':
        'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
    'Accept': '*/*',
    'Origin': 'https://www.youtube.com',
    'Referer': 'https://www.youtube.com/',
    'Connection': 'keep-alive',
  };
  static final Dio _dio = Dio();
  static const Set<String> _safeAudioExtensions = {
    'm4a',
    'mp4',
    'webm',
    'mp3',
    'aac',
    'ogg',
  };

  static final Map<String, Future<void>> _inFlightWrites =
      <String, Future<void>>{};
  static bool _loaded = false;
  static List<_SongStreamCacheEntry> _entries = <_SongStreamCacheEntry>[];

  static Future<String?> resolveFreshFilePath(String videoId) async {
    final normalized = videoId.trim();
    if (normalized.isEmpty) return null;
    await _ensureLoaded();
    final idx = _entries.indexWhere((entry) => entry.videoId == normalized);
    if (idx == -1) {
      log('[song-cache] miss videoId=$normalized reason=no_entry');
      return null;
    }
    final entry = _entries[idx];
    final file = File(entry.filePath);
    if (!_isEntryFresh(entry) || !await file.exists()) {
      _entries.removeAt(idx);
      await _persistEntries();
      try {
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
      log('[song-cache] miss videoId=$normalized reason=stale_or_missing_file');
      return null;
    }
    log('[song-cache] hit videoId=$normalized file=${entry.filePath}');
    return entry.filePath;
  }

  static Future<void> warmFromStreamUrl({
    required String videoId,
    required Uri streamUri,
  }) async {
    final normalized = videoId.trim();
    if (normalized.isEmpty) return;
    if (!(streamUri.scheme == 'https' || streamUri.scheme == 'http')) return;
    await _ensureLoaded();
    final fresh = await resolveFreshFilePath(normalized);
    if (fresh != null) return;

    final existing = _inFlightWrites[normalized];
    if (existing != null) return existing;

    final write = _downloadAndStore(
      videoId: normalized,
      streamUri: streamUri,
    );
    _inFlightWrites[normalized] = write;
    try {
      await write;
    } finally {
      _inFlightWrites.remove(normalized);
    }
  }

  static Future<void> evictVideoId(String videoId) async {
    final normalized = videoId.trim();
    if (normalized.isEmpty) return;
    await _ensureLoaded();
    final removed = _entries.where((entry) => entry.videoId == normalized).toList(
      growable: false,
    );
    if (removed.isEmpty) return;
    _entries.removeWhere((entry) => entry.videoId == normalized);
    await _persistEntries();
    for (final entry in removed) {
      try {
        final file = File(entry.filePath);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {
        // Best effort.
      }
    }
  }

  static Future<String?> waitForFreshFilePath(
    String videoId, {
    Duration maxWait = const Duration(seconds: 2),
  }) async {
    final normalized = videoId.trim();
    if (normalized.isEmpty) return null;
    await _ensureLoaded();
    final inFlight = _inFlightWrites[normalized];
    if (inFlight != null) {
      try {
        await inFlight.timeout(maxWait);
      } catch (_) {
        // Best effort.
      }
    }
    return resolveFreshFilePath(normalized);
  }

  static bool _isEntryFresh(_SongStreamCacheEntry entry) {
    final savedAt = DateTime.fromMillisecondsSinceEpoch(entry.savedAtMs);
    return DateTime.now().difference(savedAt) <= _ttl;
  }

  static Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final box = await Hive.openBox<String>(_boxName);
      final raw = box.get(_entriesKey);
      if (raw == null || raw.isEmpty) {
        _entries = <_SongStreamCacheEntry>[];
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        _entries = <_SongStreamCacheEntry>[];
        return;
      }
      final parsed = <_SongStreamCacheEntry>[];
      for (final row in decoded.whereType<Map>()) {
        final map = Map<String, dynamic>.from(row.cast<dynamic, dynamic>());
        final entry = _SongStreamCacheEntry.fromMap(map);
        if (entry == null) continue;
        parsed.add(entry);
      }
      _entries = parsed;
      await _pruneAndPersist();
    } catch (_) {
      _entries = <_SongStreamCacheEntry>[];
    }
  }

  static Future<void> _downloadAndStore({
    required String videoId,
    required Uri streamUri,
  }) async {
    final dir = await _cacheDirectory();
    await dir.create(recursive: true);
    final uriFallbackExt = _inferFileExtensionFromUri(streamUri, fallback: 'mp4');
    var target = File('${dir.path}/$videoId.$uriFallbackExt');
    if (await target.exists()) {
      try {
        await target.delete();
      } catch (_) {}
    }

    final tempTarget = File('${target.path}.part');
    if (await tempTarget.exists()) {
      try {
        await tempTarget.delete();
      } catch (_) {}
    }

    try {
      final response = await _dio.getUri<ResponseBody>(
        streamUri,
        options: Options(
          headers: _youtubeHeaders,
          responseType: ResponseType.stream,
          followRedirects: true,
          receiveTimeout: const Duration(minutes: 3),
          sendTimeout: const Duration(minutes: 1),
        ),
      );
      final contentType = (response.headers.value(Headers.contentTypeHeader) ?? '')
          .toLowerCase();
      final headerExt = _inferExtensionFromContentType(contentType);
      if (headerExt != null && headerExt != uriFallbackExt) {
        target = File('${dir.path}/$videoId.$headerExt');
      }
      final realTempTarget = File('${target.path}.part');
      if (await realTempTarget.exists()) {
        try {
          await realTempTarget.delete();
        } catch (_) {}
      }
      final sink = realTempTarget.openWrite(mode: FileMode.writeOnly);
      var totalBytes = 0;
      final stream = response.data?.stream;
      if (stream == null) {
        await sink.flush();
        await sink.close();
        return;
      }
      await for (final chunk in stream) {
        totalBytes += chunk.length;
        if (totalBytes > _maxFileBytes) {
          await sink.flush();
          await sink.close();
          try {
            if (await realTempTarget.exists()) await realTempTarget.delete();
          } catch (_) {}
          log('[song-cache] write_skipped videoId=$videoId reason=file_too_large bytes=$totalBytes');
          return;
        }
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      if (!await realTempTarget.exists()) return;
      final sizeBytes = await realTempTarget.length();
      if (sizeBytes <= 0 || sizeBytes > _maxFileBytes) {
        try {
          await realTempTarget.delete();
        } catch (_) {}
        return;
      }
      if (await target.exists()) {
        try {
          await target.delete();
        } catch (_) {}
      }
      await realTempTarget.rename(target.path);
      if (!await target.exists()) return;

      _entries.removeWhere((entry) => entry.videoId == videoId);
      _entries.insert(
        0,
        _SongStreamCacheEntry(
          videoId: videoId,
          filePath: target.path,
          sizeBytes: sizeBytes,
          savedAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      await _pruneAndPersist();
      log('[song-cache] write_ok videoId=$videoId file=${target.path} bytes=$sizeBytes contentType=$contentType');
    } catch (e) {
      log(
        '[song-cache] write_failed videoId=$videoId urlHost=${streamUri.host} error=$e',
      );
    } finally {
      try {
        if (await tempTarget.exists()) {
          await tempTarget.delete();
        }
      } catch (_) {}
    }
  }

  static String _inferFileExtensionFromUri(Uri uri, {String fallback = 'm4a'}) {
    final ext = uri.pathSegments.isEmpty
        ? ''
        : uri.pathSegments.last.split('.').last.toLowerCase();
    if (_safeAudioExtensions.contains(ext)) return ext;
    return fallback;
  }

  static String? _inferExtensionFromContentType(String contentType) {
    if (contentType.contains('audio/mp4') || contentType.contains('video/mp4')) {
      return 'mp4';
    }
    if (contentType.contains('audio/mpeg')) return 'mp3';
    if (contentType.contains('audio/webm') || contentType.contains('video/webm')) {
      return 'webm';
    }
    if (contentType.contains('audio/aac')) return 'aac';
    if (contentType.contains('audio/ogg') || contentType.contains('application/ogg')) {
      return 'ogg';
    }
    return null;
  }

  static Future<Directory> _cacheDirectory() async {
    final root = await getApplicationDocumentsDirectory();
    return Directory('${root.path}/song_stream_cache');
  }

  static Future<void> _pruneAndPersist() async {
    final now = DateTime.now();
    final kept = <_SongStreamCacheEntry>[];
    for (final entry in _entries) {
      final file = File(entry.filePath);
      final isFresh =
          now.difference(DateTime.fromMillisecondsSinceEpoch(entry.savedAtMs)) <=
          _ttl;
      if (!isFresh || !await file.exists()) {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
        continue;
      }
      kept.add(entry);
    }
    _entries = kept;

    while (_entries.length > _maxEntries) {
      final removed = _entries.removeLast();
      try {
        final file = File(removed.filePath);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }

    var total = _entries.fold<int>(0, (sum, e) => sum + e.sizeBytes);
    while (total > _maxTotalBytes && _entries.isNotEmpty) {
      final removed = _entries.removeLast();
      total -= removed.sizeBytes;
      try {
        final file = File(removed.filePath);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }

    await _persistEntries();
  }

  static Future<void> _persistEntries() async {
    try {
      final box = await Hive.openBox<String>(_boxName);
      final payload = jsonEncode(
        _entries.map((entry) => entry.toMap()).toList(growable: false),
      );
      await box.put(_entriesKey, payload);
    } catch (_) {
      // Best effort.
    }
  }
}

class _SongStreamCacheEntry {
  final String videoId;
  final String filePath;
  final int sizeBytes;
  final int savedAtMs;

  const _SongStreamCacheEntry({
    required this.videoId,
    required this.filePath,
    required this.sizeBytes,
    required this.savedAtMs,
  });

  Map<String, dynamic> toMap() => <String, dynamic>{
    'videoId': videoId,
    'filePath': filePath,
    'sizeBytes': sizeBytes,
    'savedAtMs': savedAtMs,
  };

  static _SongStreamCacheEntry? fromMap(Map<String, dynamic> map) {
    final videoId = (map['videoId'] ?? '').toString().trim();
    final filePath = (map['filePath'] ?? '').toString().trim();
    final sizeBytes = (map['sizeBytes'] as num?)?.toInt() ?? 0;
    final savedAtMs = (map['savedAtMs'] as num?)?.toInt() ?? 0;
    if (videoId.isEmpty || filePath.isEmpty || sizeBytes <= 0 || savedAtMs <= 0) {
      return null;
    }
    return _SongStreamCacheEntry(
      videoId: videoId,
      filePath: filePath,
      sizeBytes: sizeBytes,
      savedAtMs: savedAtMs,
    );
  }
}
