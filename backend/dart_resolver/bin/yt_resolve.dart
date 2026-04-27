import 'dart:convert';
import 'dart:io';

import 'package:youtube_explode_dart/youtube_explode_dart.dart';

String? _argValue(List<String> args, String key) {
  final idx = args.indexOf(key);
  if (idx >= 0 && idx + 1 < args.length) return args[idx + 1];
  return null;
}

Map<String, dynamic>? _audioInfo(StreamManifest manifest) {
  if (manifest.audioOnly.isEmpty) return null;
  final best = manifest.audioOnly.withHighestBitrate();
  return {
    'url': best.url.toString(),
    'bitrate': best.bitrate.bitsPerSecond,
    'mimeType': best.codec.mimeType,
  };
}

Map<String, dynamic>? _muxedInfo(StreamManifest manifest) {
  if (manifest.muxed.isEmpty) return null;
  final best = manifest.muxed.withHighestBitrate();
  return {
    'url': best.url.toString(),
    'bitrate': best.bitrate.bitsPerSecond,
    'qualityLabel': best.qualityLabel,
    'mimeType': best.container.mimeType,
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

  final yt = YoutubeExplode();
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
    final thumbnails = video.thumbnails
        .map((t) => t.url.toString())
        .where((u) => u.isNotEmpty)
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
