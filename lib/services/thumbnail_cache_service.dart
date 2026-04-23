import 'dart:async';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';

class ThumbnailCacheService {
  static final CacheManager _cacheManager = CacheManager(
    Config(
      'vmmusic_thumbnail_cache_v1',
      stalePeriod: const Duration(days: 2),
      maxNrOfCacheObjects: 1800,
    ),
  );

  static Stream<FileResponse> streamFor(String url) {
    return _cacheManager.getFileStream(url, withProgress: false);
  }

  static Future<void> prefetchUrls(
    Iterable<String> urls, {
    int maxItems = 24,
  }) async {
    final normalized = <String>[];
    final seen = <String>{};

    for (final raw in urls) {
      final value = raw.trim();
      if (value.isEmpty || value.startsWith('/')) continue;
      if (!value.startsWith('http://') && !value.startsWith('https://')) {
        continue;
      }
      if (!seen.add(value)) continue;
      normalized.add(value);
      if (normalized.length >= maxItems) break;
    }
    if (normalized.isEmpty) return;

    for (final url in normalized) {
      try {
        await _cacheManager.getSingleFile(url).timeout(
          const Duration(seconds: 8),
        );
      } catch (_) {
        // Best effort.
      }
    }
  }
}
