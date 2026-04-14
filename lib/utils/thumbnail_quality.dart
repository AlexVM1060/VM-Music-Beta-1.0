import 'package:youtube_explode_dart/youtube_explode_dart.dart';

String bestThumbnailForVideo(Video video, {bool preferLowResolution = false}) {
  final fallback = video.thumbnails.highResUrl.isNotEmpty
      ? video.thumbnails.highResUrl
      : (video.thumbnails.mediumResUrl.isNotEmpty
            ? video.thumbnails.mediumResUrl
            : video.thumbnails.lowResUrl);
  final candidates = buildThumbnailCandidates(
    videoId: video.id.value,
    thumbnailUrl: fallback,
    preferLowResolution: preferLowResolution,
  );
  if (candidates.isNotEmpty) return candidates.first;
  return optimizeYoutubeThumbnailUrl(
    fallback,
    preferLowResolution: preferLowResolution,
  );
}

List<String> buildThumbnailCandidates({
  String? videoId,
  String? thumbnailUrl,
  bool preferLowResolution = false,
}) {
  final id = (videoId != null && videoId.trim().isNotEmpty)
      ? videoId.trim()
      : extractYoutubeVideoIdFromThumbnailUrl(thumbnailUrl);
  final urls = <String>[];
  if (id != null && id.isNotEmpty) {
    if (preferLowResolution) {
      urls.addAll([
        'https://i.ytimg.com/vi/$id/mqdefault.jpg',
        'https://i.ytimg.com/vi/$id/hqdefault.jpg',
        'https://i.ytimg.com/vi/$id/default.jpg',
      ]);
    } else {
      urls.addAll([
        'https://i.ytimg.com/vi/$id/maxresdefault.jpg',
        'https://i.ytimg.com/vi/$id/sddefault.jpg',
        'https://i.ytimg.com/vi/$id/hqdefault.jpg',
        'https://i.ytimg.com/vi/$id/mqdefault.jpg',
        'https://i.ytimg.com/vi/$id/default.jpg',
      ]);
    }
  }
  if (thumbnailUrl != null && thumbnailUrl.trim().isNotEmpty) {
    final normalized = thumbnailUrl.trim();
    if (preferLowResolution) {
      urls.add(
        optimizeYoutubeThumbnailUrl(normalized, preferLowResolution: true),
      );
    }
    urls.add(normalized);
  }

  final deduped = <String>[];
  final seen = <String>{};
  for (final url in urls) {
    if (seen.add(url)) deduped.add(url);
  }
  return deduped;
}

String optimizeYoutubeThumbnailUrl(
  String url, {
  bool preferLowResolution = false,
}) {
  final trimmed = url.trim();
  if (trimmed.isEmpty || !preferLowResolution) return trimmed;
  final id = extractYoutubeVideoIdFromThumbnailUrl(trimmed);
  if (id == null || id.isEmpty) return trimmed;
  return 'https://i.ytimg.com/vi/$id/mqdefault.jpg';
}

String? extractYoutubeVideoIdFromThumbnailUrl(String? url) {
  if (url == null || url.trim().isEmpty) return null;
  try {
    final uri = Uri.parse(url.trim());
    final segments = uri.pathSegments;
    for (var i = 0; i < segments.length - 1; i++) {
      if (segments[i] == 'vi' || segments[i] == 'vi_webp') {
        final id = segments[i + 1].trim();
        if (id.isNotEmpty) return id;
      }
    }
  } catch (_) {
    return null;
  }
  return null;
}
