import 'dart:convert';
import 'dart:io';

import 'package:youtube_explode_dart/youtube_explode_dart.dart';

String? _argValue(List<String> args, String key) {
  final idx = args.indexOf(key);
  if (idx >= 0 && idx + 1 < args.length) return args[idx + 1];
  return null;
}

Future<void> main(List<String> args) async {
  final query = (_argValue(args, '--query') ?? '').trim();
  final limitRaw = (_argValue(args, '--limit') ?? '30').trim();
  final limit = int.tryParse(limitRaw) ?? 30;
  final cappedLimit = limit.clamp(1, 80);

  if (query.isEmpty) {
    stdout.writeln(jsonEncode({
      'ok': false,
      'error': 'missing_query',
    }));
    exit(2);
  }

  final yt = YoutubeExplode();
  try {
    final results = await yt.search.search(query);
    final seen = <String>{};
    final items = <Map<String, dynamic>>[];
    for (final video in results) {
      final id = video.id.value.trim();
      if (id.isEmpty || !seen.add(id)) continue;
      items.add({
        'videoId': id,
        'title': video.title,
        'author': video.author,
        'channelId': video.channelId.value,
        'durationSeconds': video.duration?.inSeconds,
        'viewCount': video.engagement.viewCount,
      });
      if (items.length >= cappedLimit) break;
    }

    stdout.writeln(jsonEncode({
      'ok': true,
      'query': query,
      'items': items,
    }));
  } catch (error) {
    stdout.writeln(jsonEncode({
      'ok': false,
      'error': 'youtube_explode_dart_search_failed',
      'detail': error.toString(),
    }));
    exit(4);
  } finally {
    yt.close();
  }
}
