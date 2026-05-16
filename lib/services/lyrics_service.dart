import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

class SyncedLyricLine {
  final Duration timestamp;
  final String text;

  const SyncedLyricLine({required this.timestamp, required this.text});
}

class LyricsResult {
  final String plainLyrics;
  final List<SyncedLyricLine> syncedLyrics;
  final String? rawSyncedLyrics;

  const LyricsResult({
    required this.plainLyrics,
    required this.syncedLyrics,
    this.rawSyncedLyrics,
  });

  bool get hasSyncedLyrics => syncedLyrics.isNotEmpty;
}

class LyricsService {
  LyricsService({Dio? dio}) : _dio = dio ?? Dio() {
    final adapter = _dio.httpClientAdapter;
    if (adapter is IOHttpClientAdapter) {
      adapter.createHttpClient = () {
        final client = HttpClient();
        client.badCertificateCallback = (cert, host, port) {
          // Bypass SSL temporal solo para LRCLIB.
          return host == 'lrclib.net';
        };
        return client;
      };
    }
  }

  final Dio _dio;

  Future<LyricsResult?> fetchLyrics({
    required String title,
    required String artist,
  }) async {
    final cleanedTitle = _cleanTitle(title);
    final cleanedArtist = _cleanArtist(artist);

    final primary = await _fetchGet(cleanedTitle, cleanedArtist);
    if (primary != null && primary.plainLyrics.isNotEmpty) {
      return primary;
    }

    final fromSearch = await _fetchSearch(cleanedTitle, cleanedArtist);
    if (fromSearch != null && fromSearch.plainLyrics.isNotEmpty) {
      return fromSearch;
    }

    // Fallback con extracción de "Artista - Canción" desde el título.
    final split = _splitArtistTitle(cleanedTitle);
    if (split != null) {
      final altGet = await _fetchGet(split.$2, split.$1);
      if (altGet != null && altGet.plainLyrics.isNotEmpty) {
        return altGet;
      }
      final altSearch = await _fetchSearch(split.$2, split.$1);
      if (altSearch != null && altSearch.plainLyrics.isNotEmpty) {
        return altSearch;
      }
    }

    return null;
  }

  Future<LyricsResult?> _fetchGet(String title, String artist) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        'https://lrclib.net/api/get',
        queryParameters: {'track_name': title, 'artist_name': artist},
        options: Options(
          sendTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 12),
        ),
      );
      final data = response.data;
      if (data == null) return null;
      return _pickLyrics(data);
    } catch (_) {
      return null;
    }
  }

  Future<LyricsResult?> _fetchSearch(String title, String artist) async {
    try {
      final response = await _dio.get<List<dynamic>>(
        'https://lrclib.net/api/search',
        queryParameters: {'track_name': title, 'artist_name': artist},
        options: Options(
          sendTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 12),
        ),
      );
      final list = response.data;
      if (list == null || list.isEmpty) return null;
      for (final item in list) {
        if (item is! Map<String, dynamic>) continue;
        final lyrics = _pickLyrics(item);
        if (lyrics != null && lyrics.plainLyrics.isNotEmpty) {
          return lyrics;
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  LyricsResult? _pickLyrics(Map<String, dynamic> data) {
    final plain = (data['plainLyrics'] as String?)?.trim();
    final synced = (data['syncedLyrics'] as String?)?.trim();
    final syncedLines = (synced != null && synced.isNotEmpty)
        ? parseSyncedLyrics(synced)
        : <SyncedLyricLine>[];

    if (plain != null && plain.isNotEmpty) {
      return LyricsResult(
        plainLyrics: plain,
        syncedLyrics: syncedLines,
        rawSyncedLyrics: synced,
      );
    }
    if (synced != null && synced.isNotEmpty) {
      return LyricsResult(
        plainLyrics: _stripLrcTimestamps(synced),
        syncedLyrics: syncedLines,
        rawSyncedLyrics: synced,
      );
    }
    return null;
  }

  String _cleanTitle(String input) {
    var out = input.trim();
    out = out.replaceAll(RegExp(r'\[[^\]]*\]'), ' ');
    out = out.replaceAll(RegExp(r'\([^)]*\)'), ' ');
    out = out.replaceAll(
      RegExp(
        r'\b(official|video|audio|lyrics?|lyric video)\b',
        caseSensitive: false,
      ),
      ' ',
    );
    out = out.replaceAll(RegExp(r'\s+'), ' ').trim();
    return out;
  }

  String _cleanArtist(String input) {
    var out = input.trim();
    if (out.isEmpty) return out;
    out = out.replaceAll(
      RegExp(r'\b(topic|official|vevo)\b', caseSensitive: false),
      ' ',
    );
    out = out.replaceAll(RegExp(r'\s+'), ' ').trim();
    return out;
  }

  (String, String)? _splitArtistTitle(String title) {
    final parts = title.split(RegExp(r'\s-\s'));
    if (parts.length < 2) return null;
    final artist = parts.first.trim();
    final song = parts.sublist(1).join(' - ').trim();
    if (artist.isEmpty || song.isEmpty) return null;
    return (artist, song);
  }

  String _stripLrcTimestamps(String lrc) {
    return lrc
        .split('\n')
        .map((line) => line.replaceAll(RegExp(r'\[[0-9:.]+\]'), '').trim())
        .where((line) => line.isNotEmpty)
        .join('\n');
  }

  List<SyncedLyricLine> parseSyncedLyrics(String lrc) {
    final output = <SyncedLyricLine>[];
    final timestampRegex = RegExp(r'\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\]');

    for (final rawLine in lrc.split('\n')) {
      final matches = timestampRegex.allMatches(rawLine).toList();
      if (matches.isEmpty) continue;

      final text = rawLine.replaceAll(timestampRegex, '').trim();
      if (text.isEmpty) continue;

      for (final match in matches) {
        final min = int.tryParse(match.group(1) ?? '0') ?? 0;
        final sec = int.tryParse(match.group(2) ?? '0') ?? 0;
        final fracRaw = match.group(3) ?? '0';
        final frac = int.tryParse(fracRaw) ?? 0;
        final millis = fracRaw.length == 3
            ? frac
            : (fracRaw.length == 2 ? frac * 10 : frac * 100);

        output.add(
          SyncedLyricLine(
            timestamp: Duration(
              minutes: min,
              seconds: sec,
              milliseconds: millis,
            ),
            text: text,
          ),
        );
      }
    }

    output.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return output;
  }
}
