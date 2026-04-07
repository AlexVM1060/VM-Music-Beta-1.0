import 'package:youtube_explode_dart/youtube_explode_dart.dart';

String bestThumbnailForVideo(Video video) {
  final fallback = video.thumbnails.highResUrl.isNotEmpty
      ? video.thumbnails.highResUrl
      : video.thumbnails.mediumResUrl;
  final candidates = buildThumbnailCandidates(
    videoId: video.id.value,
    thumbnailUrl: fallback,
  );
  return candidates.isNotEmpty ? candidates.first : fallback;
}

List<String> buildThumbnailCandidates({
  String? videoId,
  String? thumbnailUrl,
}) {
  final id = (videoId != null && videoId.trim().isNotEmpty)
      ? videoId.trim()
      : extractYoutubeVideoIdFromThumbnailUrl(thumbnailUrl);
  final urls = <String>[];
  if (id != null && id.isNotEmpty) {
    urls.addAll([
      'https://i.ytimg.com/vi/$id/maxresdefault.jpg',
      'https://i.ytimg.com/vi/$id/sddefault.jpg',
      'https://i.ytimg.com/vi/$id/hqdefault.jpg',
      'https://i.ytimg.com/vi/$id/mqdefault.jpg',
      'https://i.ytimg.com/vi/$id/default.jpg',
    ]);
  }
  if (thumbnailUrl != null && thumbnailUrl.trim().isNotEmpty) {
    urls.add(thumbnailUrl.trim());
  }

  final deduped = <String>[];
  final seen = <String>{};
  for (final url in urls) {
    if (seen.add(url)) deduped.add(url);
  }
  return deduped;
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
