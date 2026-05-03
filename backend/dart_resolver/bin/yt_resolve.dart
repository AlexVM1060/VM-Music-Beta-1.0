import 'dart:convert';
import 'dart:io';

import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class _CookieYoutubeHttpClient extends YoutubeHttpClient {
  final String cookieHeader;

  _CookieYoutubeHttpClient(this.cookieHeader);

  @override
  Map<String, String> get headers => {
    ...YoutubeHttpClient.defaultHeaders,
    'cookie': cookieHeader,
  };
}

String? _argValue(List<String> args, String key) {
  final idx = args.indexOf(key);
  if (idx >= 0 && idx + 1 < args.length) return args[idx + 1];
  return null;
}

String? _normalizeCookieHeader(String? raw) {
  final value = (raw ?? '').trim();
  if (value.isEmpty) return null;
  final compact = value.replaceAll('\n', '; ').replaceAll('\r', '; ').trim();
  if (compact.isEmpty) return null;
  if (!compact.contains('=')) return null;

  final hasConsent = RegExp(r'(^|;\s*)CONSENT=').hasMatch(compact);
  if (hasConsent) return compact;
  // Mantiene la cookie de consentimiento por defecto del cliente
  // para mejorar compatibilidad cuando no viene incluida.
  return 'CONSENT=YES+cb; $compact';
}

String? _cookieFromEnvironment() {
  final direct = _normalizeCookieHeader(
    Platform.environment['YTEXPLODE_COOKIE'],
  );
  if (direct != null) return direct;

  final legacy = _normalizeCookieHeader(
    Platform.environment['YOUTUBE_COOKIE'],
  );
  if (legacy != null) return legacy;

  final b64 = (Platform.environment['YTEXPLODE_COOKIE_B64'] ?? '').trim();
  if (b64.isEmpty) return null;
  try {
    final decoded = utf8.decode(base64Decode(b64));
    return _normalizeCookieHeader(decoded);
  } catch (_) {
    return null;
  }
}

Map<String, dynamic>? _audioInfo(StreamManifest manifest) {
  if (manifest.audioOnly.isEmpty) return null;
  final sorted = manifest.audioOnly.toList()
    ..sort((a, b) {
      final aContainer = a.container.name.toLowerCase();
      final bContainer = b.container.name.toLowerCase();
      final aIosPreferred = (aContainer == 'mp4' || aContainer == 'm4a') ? 1 : 0;
      final bIosPreferred = (bContainer == 'mp4' || bContainer == 'm4a') ? 1 : 0;
      if (aIosPreferred != bIosPreferred) {
        return bIosPreferred.compareTo(aIosPreferred);
      }
      return b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond);
    });
  final best = sorted.first;
  return {
    'url': best.url.toString(),
    'bitrate': best.bitrate.bitsPerSecond,
    'mimeType': best.codec.mimeType,
  };
}

Map<String, dynamic>? _muxedInfo(StreamManifest manifest) {
  if (manifest.muxed.isEmpty) return null;
  final sorted = manifest.muxed.toList()
    ..sort((a, b) {
      final aContainer = a.container.name.toLowerCase();
      final bContainer = b.container.name.toLowerCase();
      final aIosPreferred = aContainer == 'mp4' ? 1 : 0;
      final bIosPreferred = bContainer == 'mp4' ? 1 : 0;
      if (aIosPreferred != bIosPreferred) {
        return bIosPreferred.compareTo(aIosPreferred);
      }
      return b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond);
    });
  final best = sorted.first;
  return {
    'url': best.url.toString(),
    'bitrate': best.bitrate.bitsPerSecond,
    'qualityLabel': best.qualityLabel,
    'mimeType': 'video/${best.container.name}',
  };
}

Future<void> main(List<String> args) async {
  final rawId = _argValue(args, '--video-id') ?? (args.isNotEmpty ? args.first : null);
  final videoId = (rawId ?? '').trim();

  if (!RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(videoId)) {
    stdout.writeln(jsonEncode({
      'ok': false,
      'error': 'invalid_video_id',
      'detail': 'Expected 11-char YouTube video id',
    }));
    exit(2);
  }

  final cookieHeader = _cookieFromEnvironment();
  final yt = YoutubeExplode(
    httpClient: cookieHeader == null
        ? YoutubeHttpClient()
        : _CookieYoutubeHttpClient(cookieHeader),
  );
  try {
    final video = await yt.videos.get(videoId);
    final manifest = await yt.videos.streamsClient.getManifest(videoId);

    final audio = _audioInfo(manifest);
    final muxed = _muxedInfo(manifest);

    if (audio == null && muxed == null) {
      stdout.writeln(jsonEncode({
        'ok': false,
        'error': 'no_playable_formats',
        'detail': 'youtube_explode_dart_no_playable_formats',
      }));
      exit(3);
    }

    final sourceUrl = (audio?['url'] ?? muxed?['url'] ?? '').toString();
    final thumbnails = <String?>[
      video.thumbnails.maxResUrl,
      video.thumbnails.highResUrl,
      video.thumbnails.standardResUrl,
      video.thumbnails.mediumResUrl,
      video.thumbnails.lowResUrl,
    ]
        .whereType<String>()
        .where((u) => u.isNotEmpty)
        .toSet()
        .toList(growable: false);

    stdout.writeln(jsonEncode({
      'ok': true,
      'resolver': 'youtube_explode_dart',
      'videoId': videoId,
      'sourceUrl': sourceUrl,
      'isVideoSource': audio == null,
      'audio': audio,
      'muxed': muxed,
      'title': video.title,
      'author': video.author,
      'channelId': video.channelId.value,
      'durationSeconds': video.duration?.inSeconds,
      'thumbnails': thumbnails,
      'isLiveContent': video.isLive,
      'publishDate': video.uploadDate?.toIso8601String(),
      'viewCount': video.engagement.viewCount,
    }));
  } catch (error) {
    stdout.writeln(jsonEncode({
      'ok': false,
      'error': 'youtube_explode_dart_failed',
      'detail': error.toString(),
    }));
    exit(4);
  } finally {
    yt.close();
  }
}
