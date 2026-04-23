import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';

class SongStreamCacheService {
  static const String _boxName = 'song_stream_cache';
  static const String _entriesKey = 'entries_v1';
  static const Duration _ttl = Duration(days: 1);
  static const int _maxEntries = 30;
  static const int _maxFileBytes = 90 * 1024 * 1024;
  static const int _maxTotalBytes = 900 * 1024 * 1024;

  static final Map<String, Future<void>> _inFlightWrites =
      <String, Future<void>>{};
  static bool _loaded = false;
  static List<_SongStreamCacheEntry> _entries = <_SongStreamCacheEntry>[];

  static Future<String?> resolveFreshFilePath(String videoId) async {
    final normalized = videoId.trim();
    if (normalized.isEmpty) return null;
    await _ensureLoaded();
    final idx = _entries.indexWhere((entry) => entry.videoId == normalized);
    if (idx == -1) return null;
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
      return null;
    }
    return entry.filePath;
  }

  static Future<void> warmFromStreamUrl({
    required String videoId,
    required Uri streamUri,
  }) async {
    final normalized = videoId.trim();
    if (normalized.isEmpty) return;
    if (!(streamUri.scheme == 'https' || streamUri.scheme == 'http')) return;
    if (!streamUri.host.toLowerCase().contains('googlevideo.com')) return;
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
    final target = File(
      '${dir.path}/$videoId-${DateTime.now().millisecondsSinceEpoch}.m4a',
    );

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.getUrl(streamUri).timeout(
        const Duration(seconds: 10),
      );
      req.headers.set(
        HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)',
      );
      final res = await req.close().timeout(const Duration(seconds: 18));
      if (res.statusCode < 200 || res.statusCode >= 300) return;

      final sink = target.openWrite(mode: FileMode.writeOnly);
      var totalBytes = 0;
      await for (final chunk in res) {
        totalBytes += chunk.length;
        if (totalBytes > _maxFileBytes) {
          await sink.flush();
          await sink.close();
          try {
            if (await target.exists()) await target.delete();
          } catch (_) {}
          return;
        }
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();

      if (!await target.exists()) return;
      final sizeBytes = await target.length();
      if (sizeBytes <= 0 || sizeBytes > _maxFileBytes) {
        try {
          await target.delete();
        } catch (_) {}
        return;
      }

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
    } catch (_) {
      // Best effort.
    } finally {
      client.close(force: true);
    }
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
