import 'dart:developer' as developer;
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter, Rect;
import 'package:cupertino_context_menu_plus/cupertino_context_menu_plus.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:hive/hive.dart';
import 'package:image/image.dart' as img;
import 'package:myapp/models/video_history.dart';
import 'package:myapp/search_view_state.dart';
import 'package:myapp/services/download_service.dart';
import 'package:myapp/services/app_lifecycle_service.dart';
import 'package:myapp/services/playlist_service.dart';
import 'package:myapp/services/library_albums_service.dart';
import 'package:myapp/services/app_settings_service.dart';
import 'package:myapp/utils/artist_name_utils.dart';
import 'package:myapp/utils/artwork_subject_cutout_service.dart';
import 'package:myapp/utils/thumbnail_quality.dart';
import 'package:myapp/video_player_manager.dart';
import 'package:myapp/widgets/ios_notice.dart';
import 'package:myapp/widgets/playlist_picker_sheet.dart';
import 'package:myapp/widgets/queue_swipe_action_button.dart';
import 'package:myapp/widgets/square_thumbnail.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

enum SearchState { initial, loading, success, error, noResults }

enum _SearchFilterMode { music, podcast, videos }

enum _SearchVideoContextAction {
  addToFavorites,
  addToPlaylist,
  addNext,
  addToEnd,
  share,
  openArtist,
  openAlbum,
}

class _AdaptiveBackdropFilter extends StatelessWidget {
  final ImageFilter filter;
  final Widget child;

  const _AdaptiveBackdropFilter({required this.filter, required this.child});

  @override
  Widget build(BuildContext context) {
    final appInForeground = context.select<AppLifecycleService?, bool>(
      (s) => s?.isForeground ?? true,
    );
    final dataSaverMode = context.select<AppSettingsService?, bool>(
      (s) => s?.dataSaverMode ?? false,
    );
    final disableBackdrop =
        dataSaverMode ||
        !appInForeground ||
        defaultTargetPlatform == TargetPlatform.iOS;
    if (disableBackdrop) return child;
    return BackdropFilter(filter: filter, child: child);
  }
}

String _bestQualityThumbnail(Video video) {
  return bestThumbnailForVideo(video);
}

Rect _shareOriginFromContext(BuildContext context) {
  final renderBox = context.findRenderObject() as RenderBox?;
  if (renderBox != null && renderBox.hasSize) {
    return renderBox.localToGlobal(Offset.zero) & renderBox.size;
  }
  return const Rect.fromLTWH(1, 1, 1, 1);
}

double _rootBottomOverlayReserve(
  BuildContext context, {
  required bool hasMiniPlayer,
}) {
  final bottomInset = MediaQuery.of(context).padding.bottom;
  // Reserva para la tab bar flotante del shell (Inicio/Buscar/Descargas/Cuenta).
  const tabBarReserve = 108.0;
  // Extra cuando el mini reproductor está visible.
  const miniPlayerReserve = 64.0;
  return tabBarReserve + (hasMiniPlayer ? miniPlayerReserve : 0) + bottomInset;
}

Future<void> _shareVideoDeepLink(
  Video video, {
  required Rect shareOrigin,
}) async {
  final videoId = video.id.value.trim();
  if (videoId.isEmpty) return;
  final title = video.title.trim();
  final artist = cleanArtistName(video.author);
  final thumbnailUrl = _bestQualityThumbnail(video).trim();
  final durationMs = (video.duration ?? Duration.zero).inMilliseconds;
  final safeId = videoId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
  final safeTitle = title
      .replaceAll(RegExp(r'\s+'), '_')
      .replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '')
      .trim();
  final baseName = safeTitle.isEmpty ? safeId : '${safeTitle}_$safeId';
  final deepLink = Uri(
    scheme: 'vmmusic',
    host: 'song',
    queryParameters: <String, String>{
      'videoId': videoId,
      if (title.isNotEmpty) 'title': title,
      if (artist.isNotEmpty) 'artist': artist,
      if (thumbnailUrl.isNotEmpty) 'thumbnailUrl': thumbnailUrl,
      if (durationMs > 0) 'durationMs': '$durationMs',
    },
  ).toString();

  XFile? artworkFile;
  try {
    final imageBytes = await _loadShareArtworkBytes(
      thumbnailUrl: thumbnailUrl,
      videoId: videoId,
    );
    if (imageBytes != null && imageBytes.isNotEmpty) {
      final tempDir = await getTemporaryDirectory();
      final isPng = _isPngBytes(imageBytes);
      final ext = isPng ? 'png' : 'jpg';
      final mimeType = isPng ? 'image/png' : 'image/jpeg';
      final imageFile = File('${tempDir.path}/${baseName}_cover.$ext');
      await imageFile.writeAsBytes(imageBytes, flush: true);
      artworkFile = XFile(
        imageFile.path,
        mimeType: mimeType,
        name: '${baseName}_cover.$ext',
      );
    }
  } catch (_) {}

  await SharePlus.instance.share(
    ShareParams(
      subject: 'VM Music',
      text: '${artist.isEmpty ? title : '$title · $artist'}\n$deepLink',
      sharePositionOrigin: shareOrigin,
      files: artworkFile != null ? <XFile>[artworkFile] : null,
    ),
  );
}

Future<Uint8List?> _loadShareArtworkBytes({
  required String thumbnailUrl,
  required String videoId,
}) async {
  final source = thumbnailUrl.trim();
  if (source.startsWith('/')) {
    final file = File(source);
    if (await file.exists()) {
      final bytes = await file.readAsBytes();
      final prepared = await compute(_prepareShareArtworkWorker, bytes);
      return prepared ?? bytes;
    }
  }

  final candidates = buildThumbnailCandidates(
    videoId: videoId,
    thumbnailUrl: source.isEmpty ? null : source,
    preferLowResolution: false,
  );
  if (candidates.isEmpty && source.isNotEmpty) {
    final uri = Uri.tryParse(source);
    if (uri != null) candidates.add(source);
  }

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
  try {
    for (final candidate in candidates) {
      final uri = Uri.tryParse(candidate);
      if (uri == null) continue;
      try {
        final req = await client
            .getUrl(uri)
            .timeout(const Duration(seconds: 12));
        req.headers.set(
          HttpHeaders.userAgentHeader,
          'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)',
        );
        req.headers.set(HttpHeaders.acceptHeader, 'image/*,*/*;q=0.8');
        final res = await req.close().timeout(const Duration(seconds: 16));
        if (res.statusCode < 200 || res.statusCode >= 300) continue;
        final bytes = await consolidateHttpClientResponseBytes(res);
        if (bytes.isEmpty) continue;
        final prepared = await compute(_prepareShareArtworkWorker, bytes);
        return prepared ?? bytes;
      } catch (_) {
        continue;
      }
    }
    return null;
  } finally {
    client.close(force: true);
  }
}

bool _isPngBytes(Uint8List bytes) {
  if (bytes.length < 8) return false;
  return bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0D &&
      bytes[5] == 0x0A &&
      bytes[6] == 0x1A &&
      bytes[7] == 0x0A;
}

Uint8List? _prepareShareArtworkWorker(Uint8List sourceBytes) {
  final decoded = img.decodeImage(sourceBytes);
  if (decoded == null) return null;

  final side = math.min(decoded.width, decoded.height);
  if (side <= 0) return null;
  final cropX = ((decoded.width - side) / 2).round();
  final cropY = ((decoded.height - side) / 2).round();
  final square = img.copyCrop(
    decoded,
    x: cropX,
    y: cropY,
    width: side,
    height: side,
  );

  const targetSide = 1024;
  final prepared = side > targetSide
      ? img.copyResize(
          square,
          width: targetSide,
          height: targetSide,
          interpolation: img.Interpolation.cubic,
        )
      : square;

  return Uint8List.fromList(img.encodePng(prepared, level: 6));
}

const String _youtubeiMusicNextEndpointForAlbum =
    'https://music.youtube.com/youtubei/v1/next?key=AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8';

class _ResolvedAlbumRef {
  final String playlistId;
  final String title;
  final String artist;
  final String thumbnailUrl;

  const _ResolvedAlbumRef({
    required this.playlistId,
    required this.title,
    required this.artist,
    this.thumbnailUrl = '',
  });
}

class _SearchAlbumResult {
  final String playlistId;
  final String title;
  final String artist;
  final String thumbnailUrl;

  const _SearchAlbumResult({
    required this.playlistId,
    required this.title,
    required this.artist,
    required this.thumbnailUrl,
  });
}

class _CachedVideoSnapshot {
  final String videoId;
  final String title;
  final String author;
  final String channelId;
  final String description;
  final int? durationMs;
  final int viewCount;
  final int? uploadDateMs;
  final int? publishDateMs;
  final bool isLive;

  const _CachedVideoSnapshot({
    required this.videoId,
    required this.title,
    required this.author,
    required this.channelId,
    required this.description,
    required this.durationMs,
    required this.viewCount,
    required this.uploadDateMs,
    required this.publishDateMs,
    required this.isLive,
  });

  factory _CachedVideoSnapshot.fromVideo(Video video) {
    return _CachedVideoSnapshot(
      videoId: video.id.value,
      title: video.title,
      author: video.author,
      channelId: video.channelId.value,
      description: video.description,
      durationMs: video.duration?.inMilliseconds,
      viewCount: video.engagement.viewCount,
      uploadDateMs: video.uploadDate?.millisecondsSinceEpoch,
      publishDateMs: video.publishDate?.millisecondsSinceEpoch,
      isLive: video.isLive,
    );
  }

  factory _CachedVideoSnapshot.fromMap(Map<String, dynamic> map) {
    return _CachedVideoSnapshot(
      videoId: (map['videoId'] ?? '').toString().trim(),
      title: (map['title'] ?? '').toString().trim(),
      author: (map['author'] ?? '').toString().trim(),
      channelId: (map['channelId'] ?? '').toString().trim(),
      description: (map['description'] ?? '').toString(),
      durationMs: (map['durationMs'] as num?)?.toInt(),
      viewCount: (map['viewCount'] as num?)?.toInt() ?? 0,
      uploadDateMs: (map['uploadDateMs'] as num?)?.toInt(),
      publishDateMs: (map['publishDateMs'] as num?)?.toInt(),
      isLive: map['isLive'] == true,
    );
  }

  Map<String, dynamic> toMap() => <String, dynamic>{
    'videoId': videoId,
    'title': title,
    'author': author,
    'channelId': channelId,
    'description': description,
    'durationMs': durationMs,
    'viewCount': viewCount,
    'uploadDateMs': uploadDateMs,
    'publishDateMs': publishDateMs,
    'isLive': isLive,
  };

  Video toVideo() {
    final safeVideoId = VideoId.validateVideoId(videoId)
        ? videoId
        : 'dQw4w9WgXcQ';
    final rawChannelId = channelId.trim();
    final safeChannelId = ChannelId.validateChannelId(rawChannelId)
        ? rawChannelId
        : 'UC_x5XG1OV2P6uZZ5FSM9Ttw';
    return Video(
      VideoId(safeVideoId),
      title.isEmpty ? 'Canción' : title,
      author.isEmpty ? 'Artista' : author,
      ChannelId(safeChannelId),
      uploadDateMs != null
          ? DateTime.fromMillisecondsSinceEpoch(uploadDateMs!)
          : null,
      null,
      publishDateMs != null
          ? DateTime.fromMillisecondsSinceEpoch(publishDateMs!)
          : null,
      description,
      durationMs != null ? Duration(milliseconds: durationMs!) : null,
      ThumbnailSet(safeVideoId),
      const <String>[],
      Engagement(viewCount, null, null),
      isLive,
    );
  }
}

const String _youtubeiMusicSearchEndpointForAlbums =
    'https://music.youtube.com/youtubei/v1/search?key=AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8';
const String _youtubeiMusicBrowseEndpointForArtistVideos =
    'https://music.youtube.com/youtubei/v1/browse?key=AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8';

// ignore: unused_element
Future<Map<String, dynamic>?> _fetchYoutubeMusicNextPayloadForAlbum(
  String videoId,
) async {
  final normalizedVideoId = videoId.trim();
  if (normalizedVideoId.isEmpty) return null;
  final client = HttpClient();
  try {
    final req = await client.postUrl(
      Uri.parse(_youtubeiMusicNextEndpointForAlbum),
    );
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    req.headers.set(
      HttpHeaders.userAgentHeader,
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
    );
    req.headers.set('Origin', 'https://music.youtube.com');
    req.headers.set(
      'Referer',
      'https://music.youtube.com/watch?v=$normalizedVideoId',
    );
    req.headers.set('X-Youtube-Client-Name', '67');
    req.headers.set('X-Youtube-Client-Version', '1.20240226.01.00');
    req.add(
      utf8.encode(
        jsonEncode(<String, Object?>{
          'videoId': normalizedVideoId,
          'isAudioOnly': true,
          'enablePersistentPlaylistPanel': true,
          'context': {
            'client': {
              'clientName': 'WEB_REMIX',
              'clientVersion': '1.20240226.01.00',
              'hl': 'es',
              'gl': 'US',
            },
            'request': {'useSsl': true},
          },
          'contentCheckOk': true,
          'racyCheckOk': true,
        }),
      ),
    );

    final res = await req.close();
    if (res.statusCode < 200 || res.statusCode >= 300) return null;
    final body = await utf8.decoder.bind(res).join();
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded.cast<dynamic, dynamic>());
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

Future<Map<String, dynamic>?> _fetchYoutubeMusicSearchPayloadForAlbums(
  String query, {
  bool albumsOnly = false,
  String? paramsOverride,
}) async {
  final normalizedQuery = query.trim();
  if (normalizedQuery.isEmpty) return null;
  final client = HttpClient();
  try {
    final req = await client.postUrl(
      Uri.parse(_youtubeiMusicSearchEndpointForAlbums),
    );
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    req.headers.set(
      HttpHeaders.userAgentHeader,
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
    );
    req.headers.set('Origin', 'https://music.youtube.com');
    req.headers.set(
      'Referer',
      'https://music.youtube.com/search?q=$normalizedQuery',
    );
    req.headers.set('X-Youtube-Client-Name', '67');
    req.headers.set('X-Youtube-Client-Version', '1.20240226.01.00');
    req.add(
      utf8.encode(
        jsonEncode(<String, Object?>{
          'query': normalizedQuery,
          'context': {
            'client': {
              'clientName': 'WEB_REMIX',
              'clientVersion': '1.20240226.01.00',
              'hl': 'es',
              'gl': 'US',
            },
            'request': {'useSsl': true},
          },
          if (paramsOverride != null && paramsOverride.trim().isNotEmpty)
            'params': paramsOverride.trim(),
          if ((paramsOverride == null || paramsOverride.trim().isEmpty) &&
              albumsOnly)
            'params': 'EgWKAQIYAWoKEAoQAxAEEAkQBQ==',
          'contentCheckOk': true,
          'racyCheckOk': true,
        }),
      ),
    );

    final res = await req.close();
    if (res.statusCode < 200 || res.statusCode >= 300) return null;
    final body = await utf8.decoder.bind(res).join();
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded.cast<dynamic, dynamic>());
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

const List<String> _youtubeMusicSongsFilterParamsCandidates = <String>[
  'EgWKAQIIAWoKEAoQAxAEEAkQBQ==',
  'EgWKAQIYAWoKEAoQAxAEEAkQBQ==',
];
const List<String> _youtubeMusicArtistsFilterParamsCandidates = <String>[
  'EgWKAQIgAWoKEAoQAxAEEAkQBQ==',
];

String? _extractJsonObjectAfterMarker(String source, String marker) {
  final markerIndex = source.indexOf(marker);
  if (markerIndex == -1) return null;
  final start = source.indexOf('{', markerIndex + marker.length);
  if (start == -1) return null;

  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var i = start; i < source.length; i++) {
    final char = source[i];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (char == r'\') {
      escaped = true;
      continue;
    }
    if (char == '"') {
      inString = !inString;
      continue;
    }
    if (inString) continue;
    if (char == '{') {
      depth++;
    } else if (char == '}') {
      depth--;
      if (depth == 0) {
        return source.substring(start, i + 1);
      }
    }
  }
  return null;
}

Future<Map<String, dynamic>?> _fetchYoutubeMusicSearchInitialDataForAlbums(
  String query,
) async {
  final normalizedQuery = query.trim();
  if (normalizedQuery.isEmpty) return null;
  final client = HttpClient();
  try {
    final uri = Uri.https('music.youtube.com', '/search', {
      'q': normalizedQuery,
    });
    final req = await client.getUrl(uri);
    req.headers.set(
      HttpHeaders.userAgentHeader,
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36',
    );
    req.headers.set(
      HttpHeaders.acceptHeader,
      'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    );
    req.headers.set(
      HttpHeaders.acceptLanguageHeader,
      'es-419,es;q=0.9,en;q=0.8',
    );
    final res = await req.close();
    if (res.statusCode < 200 || res.statusCode >= 300) return null;
    final html = await utf8.decoder.bind(res).join();

    final markers = <String>[
      'var ytInitialData =',
      'window["ytInitialData"] =',
      'ytInitialData =',
    ];
    for (final marker in markers) {
      final rawJson = _extractJsonObjectAfterMarker(html, marker);
      if (rawJson == null || rawJson.isEmpty) continue;
      final decoded = jsonDecode(rawJson);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded.cast<dynamic, dynamic>());
      }
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

String? _extractThumbnailFromNode(dynamic node, {int depth = 0}) {
  if (depth > 14 || node == null) return null;
  if (node is Map) {
    final thumbs = node['thumbnails'];
    if (thumbs is List) {
      for (final item in thumbs.reversed) {
        if (item is! Map) continue;
        final url = item['url'];
        if (url is String && url.trim().isNotEmpty) {
          return url.trim();
        }
      }
    }
    for (final value in node.values) {
      final nested = _extractThumbnailFromNode(value, depth: depth + 1);
      if (nested != null && nested.isNotEmpty) return nested;
    }
    return null;
  }
  if (node is List) {
    for (final value in node) {
      final nested = _extractThumbnailFromNode(value, depth: depth + 1);
      if (nested != null && nested.isNotEmpty) return nested;
    }
  }
  return null;
}

String _extractFlexColumnText(Map<String, dynamic> node, int index) {
  final columns = node['flexColumns'];
  if (columns is! List || index < 0 || index >= columns.length) return '';
  final raw = columns[index];
  if (raw is! Map) return '';
  final column = raw['musicResponsiveListItemFlexColumnRenderer'];
  if (column is! Map) return '';
  return _extractYouTubeText(column['text']).trim();
}

String _extractAlbumTitleFromRendererNode(Map<String, dynamic> node) {
  final direct = _extractYouTubeText(node['title']).trim();
  if (direct.isNotEmpty) return direct;
  final headline = _extractYouTubeText(node['headline']).trim();
  if (headline.isNotEmpty) return headline;
  final flexTitle = _extractFlexColumnText(node, 0);
  if (flexTitle.isNotEmpty) return flexTitle;
  return '';
}

String _extractAlbumArtistFromRendererNode(Map<String, dynamic> node) {
  var raw = _extractYouTubeText(node['subtitle']).trim();
  if (raw.isEmpty) {
    raw = _extractFlexColumnText(node, 1);
  }
  if (raw.isEmpty) return '';

  final parts = raw
      .split(RegExp(r'[•·]'))
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toList(growable: false);
  if (parts.isEmpty) return '';

  bool looksLikeNonArtistMeta(String value) {
    final normalized = _normalizeAlbumSearchText(value);
    if (normalized.isEmpty) return true;
    if (normalized.contains('album') ||
        normalized.contains('álbum') ||
        normalized.contains('ep') ||
        normalized.contains('single') ||
        normalized.contains('sencillo') ||
        normalized.contains('playlist') ||
        normalized.contains('cancion') ||
        normalized.contains('canciones') ||
        normalized.contains('song') ||
        normalized.contains('songs')) {
      return true;
    }
    if (RegExp(r'^\d{4}$').hasMatch(normalized)) return true;
    return false;
  }

  for (final part in parts) {
    if (!looksLikeNonArtistMeta(part)) {
      return part;
    }
  }

  // Fallback: si no detectamos metadatos claros, devolvemos el último segmento.
  return parts.last;
}

String _sanitizeAlbumThumbnailUrl(String url) {
  final raw = url.trim();
  if (raw.isEmpty) return '';
  final base = raw.split('?').first;
  final marker = base.indexOf('=');
  if (marker <= 0) return base;
  return base.substring(0, marker);
}

String _extractPageTypeFromNode(dynamic node, {int depth = 0}) {
  if (depth > 10 || node == null) return '';
  if (node is Map) {
    final pageType = node['pageType'];
    if (pageType is String && pageType.trim().isNotEmpty) {
      return pageType.trim().toUpperCase();
    }
    for (final value in node.values) {
      final nested = _extractPageTypeFromNode(value, depth: depth + 1);
      if (nested.isNotEmpty) return nested;
    }
    return '';
  }
  if (node is List) {
    for (final value in node) {
      final nested = _extractPageTypeFromNode(value, depth: depth + 1);
      if (nested.isNotEmpty) return nested;
    }
  }
  return '';
}

bool _rendererLooksLikeAlbumOrEp(Map<String, dynamic> node) {
  final title = _normalizeAlbumSearchText(
    _extractAlbumTitleFromRendererNode(node),
  );
  final subtitle = _normalizeAlbumSearchText(
    _extractYouTubeText(node['subtitle']),
  );
  final flexSubtitle = _normalizeAlbumSearchText(
    _extractFlexColumnText(node, 1),
  );
  final combined = '$title $subtitle $flexSubtitle';
  if (combined.contains('playlist') ||
      combined.contains('lista de reproduccion') ||
      combined.contains('podcast')) {
    return false;
  }

  final pageType = _extractPageTypeFromNode(node);
  if (pageType.contains('ALBUM') || pageType.contains('_EP')) return true;

  final ids = _extractPlaylistIdsFromNode(node);
  if (_pickBestAlbumPlaylistId(ids) != null &&
      (_looksLikeAlbumOrEpText(subtitle) ||
          _looksLikeAlbumOrEpText(flexSubtitle))) {
    return true;
  }

  return _looksLikeAlbumOrEpText(subtitle) ||
      _looksLikeAlbumOrEpText(flexSubtitle) ||
      _looksLikeAlbumOrEpText(title);
}

void _maybeCollectAlbumFromRendererNode(
  Map<String, dynamic> node,
  List<_SearchAlbumResult> out,
) {
  if (!_rendererLooksLikeAlbumOrEp(node)) return;
  final ids = _extractPlaylistIdsFromNode(node);
  final playlistId = _pickBestAlbumPlaylistId(ids);
  if (playlistId == null || playlistId.isEmpty) return;

  final title = _extractAlbumTitleFromRendererNode(node);
  if (title.isEmpty) return;
  final artist = _extractAlbumArtistFromRendererNode(node);
  final thumb = _sanitizeAlbumThumbnailUrl(
    _extractThumbnailFromNode(node) ?? '',
  );
  out.add(
    _SearchAlbumResult(
      playlistId: playlistId,
      title: title,
      artist: artist.isNotEmpty ? artist : 'Artista',
      thumbnailUrl: thumb,
    ),
  );
}

void _collectMusicResponsiveAlbumResults(
  dynamic node,
  List<_SearchAlbumResult> out, {
  int depth = 0,
}) {
  if (depth > 20 || node == null) return;
  if (node is Map) {
    final normalized = Map<String, dynamic>.from(node.cast<dynamic, dynamic>());
    _maybeCollectAlbumFromRendererNode(normalized, out);
    final responsive = normalized['musicResponsiveListItemRenderer'];
    if (responsive is Map) {
      _maybeCollectAlbumFromRendererNode(
        Map<String, dynamic>.from(responsive.cast<dynamic, dynamic>()),
        out,
      );
    }
    final twoRow = normalized['musicTwoRowItemRenderer'];
    if (twoRow is Map) {
      _maybeCollectAlbumFromRendererNode(
        Map<String, dynamic>.from(twoRow.cast<dynamic, dynamic>()),
        out,
      );
    }
    for (final value in node.values) {
      _collectMusicResponsiveAlbumResults(value, out, depth: depth + 1);
    }
    return;
  }
  if (node is List) {
    for (final value in node) {
      _collectMusicResponsiveAlbumResults(value, out, depth: depth + 1);
    }
  }
}

List<Map<String, dynamic>> _extractMusicShelfRenderers(
  dynamic node, {
  int depth = 0,
}) {
  if (depth > 20 || node == null) return const <Map<String, dynamic>>[];
  final out = <Map<String, dynamic>>[];
  if (node is Map) {
    final shelf = node['musicShelfRenderer'];
    if (shelf is Map) {
      out.add(Map<String, dynamic>.from(shelf.cast<dynamic, dynamic>()));
    }
    for (final value in node.values) {
      out.addAll(_extractMusicShelfRenderers(value, depth: depth + 1));
    }
    return out;
  }
  if (node is List) {
    for (final value in node) {
      out.addAll(_extractMusicShelfRenderers(value, depth: depth + 1));
    }
  }
  return out;
}

bool _looksLikeAlbumsShelfTitle(String title) {
  final normalized = _normalizeAlbumSearchText(title);
  return normalized.contains('album') ||
      RegExp(r'(^|\s)ep(s)?($|\s)').hasMatch(normalized);
}

bool _looksLikeAlbumOrEpText(String normalized) {
  final text = normalized.trim();
  if (text.isEmpty) return false;
  if (text.contains('album') || text.contains('ep')) return true;
  return RegExp(r'(^|\s)e p($|\s)').hasMatch(text);
}

void _collectAlbumResultsFromShelf(
  Map<String, dynamic> shelf,
  List<_SearchAlbumResult> out,
  Set<String> seenIds,
) {
  final contents = shelf['contents'];
  if (contents is! List) return;
  for (final item in contents) {
    if (item is! Map) continue;
    final normalized = Map<String, dynamic>.from(item.cast<dynamic, dynamic>());
    final extracted = <_SearchAlbumResult>[];
    _maybeCollectAlbumFromRendererNode(normalized, extracted);
    final responsive = normalized['musicResponsiveListItemRenderer'];
    if (responsive is Map) {
      _maybeCollectAlbumFromRendererNode(
        Map<String, dynamic>.from(responsive.cast<dynamic, dynamic>()),
        extracted,
      );
    }
    final twoRow = normalized['musicTwoRowItemRenderer'];
    if (twoRow is Map) {
      _maybeCollectAlbumFromRendererNode(
        Map<String, dynamic>.from(twoRow.cast<dynamic, dynamic>()),
        extracted,
      );
    }
    for (final album in extracted) {
      final id = album.playlistId.trim();
      if (id.isEmpty || !seenIds.add(id)) continue;
      out.add(album);
    }
  }
}

List<_SearchAlbumResult> _extractAlbumsInYoutubeMusicOrder(
  Map<String, dynamic> payload,
) {
  final shelves = _extractMusicShelfRenderers(payload);
  if (shelves.isEmpty) {
    final fallback = <_SearchAlbumResult>[];
    final seen = <String>{};
    _collectMusicResponsiveAlbumResults(payload, fallback);
    return fallback
        .where((album) => seen.add(album.playlistId.trim()))
        .toList();
  }

  final albums = <_SearchAlbumResult>[];
  final seen = <String>{};
  for (final shelf in shelves) {
    final title = _extractYouTubeText(shelf['title']);
    if (!_looksLikeAlbumsShelfTitle(title)) continue;
    _collectAlbumResultsFromShelf(shelf, albums, seen);
  }
  return albums;
}

Set<String> _extractPlaylistIdsFromNode(dynamic node, {int depth = 0}) {
  if (depth > 18 || node == null) return const <String>{};
  final ids = <String>{};

  void maybeAdd(dynamic value) {
    if (value is! String) return;
    final id = value.trim();
    if (id.isEmpty) return;
    ids.add(id);
    // En browse endpoints de YouTube Music es común ver "VL<playlistId>".
    if (id.startsWith('VL') && id.length > 2) {
      ids.add(id.substring(2));
    }
  }

  if (node is Map) {
    maybeAdd(node['playlistId']);
    maybeAdd(node['browseId']);
    final watchEndpoint = node['watchEndpoint'];
    if (watchEndpoint is Map) {
      maybeAdd(watchEndpoint['playlistId']);
      final nestedWatchPlaylist = watchEndpoint['watchPlaylistEndpoint'];
      if (nestedWatchPlaylist is Map) {
        maybeAdd(nestedWatchPlaylist['playlistId']);
      }
    }
    final watchPlaylistEndpoint = node['watchPlaylistEndpoint'];
    if (watchPlaylistEndpoint is Map) {
      maybeAdd(watchPlaylistEndpoint['playlistId']);
    }
    final browseEndpoint = node['browseEndpoint'];
    if (browseEndpoint is Map) {
      maybeAdd(browseEndpoint['browseId']);
    }
    for (final value in node.values) {
      ids.addAll(_extractPlaylistIdsFromNode(value, depth: depth + 1));
    }
    return ids;
  }
  if (node is List) {
    for (final value in node) {
      ids.addAll(_extractPlaylistIdsFromNode(value, depth: depth + 1));
    }
  }
  return ids;
}

bool _isAlbumLikePlaylistId(String playlistId) {
  final id = playlistId.trim();
  if (id.isEmpty) return false;
  if (id.startsWith('RD') ||
      id.startsWith('UU') ||
      id.startsWith('LL') ||
      id.startsWith('FL') ||
      id.startsWith('WL')) {
    return false;
  }
  return id.startsWith('OLAK') || id.startsWith('VL') || id.startsWith('MPRE');
}

String? _pickBestAlbumPlaylistId(Iterable<String> candidates) {
  final filtered = candidates.where(_isAlbumLikePlaylistId).toList();
  if (filtered.isEmpty) return null;
  filtered.sort((a, b) {
    int priority(String value) {
      if (value.startsWith('OLAK')) return 0;
      if (value.startsWith('VL')) return 1;
      return 2;
    }

    final p = priority(a).compareTo(priority(b));
    if (p != 0) return p;
    return a.length.compareTo(b.length);
  });
  return filtered.first;
}

bool _isLikelyPlayablePlaylistId(String playlistId) {
  final id = playlistId.trim();
  if (id.isEmpty) return false;
  if (id.startsWith('MPLYt_') ||
      id.startsWith('MPTRt_') ||
      id.startsWith('MPRE')) {
    return false;
  }
  return RegExp(r'^[0-9A-Za-z_-]{2,}$').hasMatch(id);
}

// ignore: unused_element
String? _pickBestPlayablePlaylistId(Iterable<String> candidates) {
  final filtered = candidates
      .map((id) => id.trim())
      .where(_isLikelyPlayablePlaylistId)
      .toSet()
      .toList();
  if (filtered.isEmpty) return null;
  filtered.sort((a, b) {
    int priority(String value) {
      if (value.startsWith('OLAK')) return 0;
      if (value.startsWith('PL')) return 1;
      if (value.startsWith('VL')) return 2;
      if (value.startsWith('RDAMVM')) return 3;
      if (value.startsWith('RD')) return 4;
      return 5;
    }

    final p = priority(a).compareTo(priority(b));
    if (p != 0) return p;
    return a.length.compareTo(b.length);
  });
  return filtered.first;
}

String _normalizeAlbumSearchText(String text) {
  return text
      .toLowerCase()
      .replaceAll('á', 'a')
      .replaceAll('é', 'e')
      .replaceAll('í', 'i')
      .replaceAll('ó', 'o')
      .replaceAll('ú', 'u')
      .replaceAll('ü', 'u')
      .replaceAll('ñ', 'n')
      .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

const Set<String> _albumSearchIgnoredTokens = <String>{
  'cancion',
  'canciones',
  'official',
  'audio',
  'video',
  'music',
  'lyrics',
  'lyric',
  'provided',
  'youtube',
  'topic',
  'full',
  'version',
  'remastered',
  'remaster',
  'deluxe',
  'edition',
  'song',
  'track',
  'album',
  'albums',
  'de',
  'del',
  'para',
  'con',
  'quiero',
  'buscar',
  'busca',
};

List<String> _tokenizeForAlbumSearch(String text) {
  final normalized = _normalizeAlbumSearchText(text);
  if (normalized.isEmpty) return const <String>[];
  final tokens = <String>[];
  for (final token in normalized.split(' ')) {
    if (token.length < 3) continue;
    if (_albumSearchIgnoredTokens.contains(token)) continue;
    tokens.add(token);
    if (tokens.length >= 10) break;
  }
  return tokens;
}

int _scoreAlbumPlaylistCandidate({
  required SearchPlaylist playlist,
  required Video video,
}) {
  final playlistId = playlist.id.value.trim();
  final playlistTitle = _normalizeAlbumSearchText(playlist.title);
  final artistTokens = _tokenizeForAlbumSearch(video.author);
  final titleTokens = _tokenizeForAlbumSearch(video.title);
  var score = 0;

  if (playlistId.startsWith('OLAK')) {
    score += 80;
  } else if (playlistId.startsWith('PL')) {
    score += 55;
  } else if (playlistId.startsWith('VL')) {
    score += 45;
  } else if (playlistId.startsWith('RDAMVM')) {
    score += 8;
  } else if (playlistId.startsWith('RD')) {
    score -= 25;
  } else {
    score += 12;
  }

  if (playlistTitle.contains('album')) score += 35;
  if (playlistTitle.contains('ep')) score += 8;
  if (playlistTitle.contains('mix') || playlistTitle.contains('radio')) {
    score -= 40;
  }

  for (final token in artistTokens.take(3)) {
    if (playlistTitle.contains(token)) score += 22;
  }
  for (final token in titleTokens.take(6)) {
    if (playlistTitle.contains(token)) score += 8;
  }

  final videos = playlist.videoCount;
  if (videos >= 5 && videos <= 40) {
    score += 18;
  } else if (videos >= 2 && videos <= 80) {
    score += 8;
  } else if (videos <= 1) {
    score -= 20;
  }
  return score;
}

// ignore: unused_element
Future<_ResolvedAlbumRef?> _resolveAlbumFromSearchFallback(
  YoutubeExplode youtubeExplode,
  Video video,
) async {
  final compactTitle = video.title.replaceAll(RegExp(r'\s+'), ' ').trim();
  final compactArtist = cleanArtistName(
    video.author,
  ).replaceAll(RegExp(r'\s+'), ' ');
  if (compactTitle.isEmpty && compactArtist.isEmpty) return null;

  final queries =
      <String>{
            '$compactTitle $compactArtist album',
            '$compactTitle $compactArtist full album',
            '$compactArtist $compactTitle album',
            '$compactArtist album',
          }
          .map((q) => q.replaceAll(RegExp(r'\s+'), ' ').trim())
          .where((q) => q.isNotEmpty)
          .toList();

  final seenIds = <String>{};
  final playlists = <SearchPlaylist>[];

  for (final query in queries) {
    try {
      final results = await youtubeExplode.search.searchContent(
        query,
        filter: TypeFilters.playlist,
      );
      for (final item in results.whereType<SearchPlaylist>().take(10)) {
        final id = item.id.value.trim();
        if (id.isEmpty || !seenIds.add(id)) continue;
        playlists.add(item);
      }
    } catch (_) {
      // Ignoramos un query fallido y continuamos con los siguientes.
    }
    if (playlists.length >= 24) break;
  }

  if (playlists.isEmpty) return null;
  final scored =
      playlists
          .map(
            (playlist) => (
              playlist: playlist,
              score: _scoreAlbumPlaylistCandidate(
                playlist: playlist,
                video: video,
              ),
            ),
          )
          .toList()
        ..sort((a, b) => b.score.compareTo(a.score));

  final best = scored.first;
  if (best.score < 35) return null;
  final resolvedTitle = best.playlist.title.trim();
  return _ResolvedAlbumRef(
    playlistId: best.playlist.id.value,
    title: resolvedTitle.isNotEmpty ? resolvedTitle : 'Álbum',
    artist: compactArtist.isNotEmpty
        ? compactArtist
        : cleanArtistName(video.author),
  );
}

Future<List<_SearchAlbumResult>> _searchAlbumsFromAppEngine(
  String query,
) async {
  final normalizedQuery = query.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalizedQuery.isEmpty) return const <_SearchAlbumResult>[];

  try {
    final initialData = await _fetchYoutubeMusicSearchInitialDataForAlbums(
      normalizedQuery,
    );
    if (initialData != null) {
      final ordered = _extractAlbumsInYoutubeMusicOrder(initialData);
      if (ordered.isNotEmpty) return ordered;
    }
  } catch (_) {}

  try {
    final defaultPayload = await _fetchYoutubeMusicSearchPayloadForAlbums(
      normalizedQuery,
    );
    if (defaultPayload != null) {
      final ordered = _extractAlbumsInYoutubeMusicOrder(defaultPayload);
      if (ordered.isNotEmpty) return ordered;
    }
  } catch (_) {}

  try {
    final albumsOnlyPayload = await _fetchYoutubeMusicSearchPayloadForAlbums(
      normalizedQuery,
      albumsOnly: true,
    );
    if (albumsOnlyPayload == null) return const <_SearchAlbumResult>[];
    return _extractAlbumsInYoutubeMusicOrder(albumsOnlyPayload);
  } catch (_) {
    return const <_SearchAlbumResult>[];
  }
}

Future<_ResolvedAlbumRef?> _resolveAlbumFromAppSearchEngine(Video video) async {
  final compactTitle = video.title.replaceAll(RegExp(r'\s+'), ' ').trim();
  final compactArtist = cleanArtistName(
    video.author,
  ).replaceAll(RegExp(r'\s+'), ' ').trim();
  if (compactTitle.isEmpty && compactArtist.isEmpty) return null;

  // Regla solicitada: buscar "cancion + artista" y abrir el primer album.
  final normalizedTitle = _normalizeAlbumSearchText(compactTitle);
  final normalizedArtist = _normalizeAlbumSearchText(compactArtist);
  final queryCandidates =
      <String>{
            '$compactTitle $compactArtist',
            if (normalizedArtist.isNotEmpty) '$compactTitle $normalizedArtist',
            if (normalizedTitle.isNotEmpty && normalizedArtist.isNotEmpty)
              '$normalizedTitle $normalizedArtist',
            compactTitle,
          }
          .map((q) => q.replaceAll(RegExp(r'\s+'), ' ').trim())
          .where((q) => q.isNotEmpty)
          .toList(growable: false);

  _SearchAlbumResult? best;
  for (final query in queryCandidates) {
    final results = await _searchAlbumsFromAppEngine(query);
    if (results.isNotEmpty) {
      best = results.first;
      break;
    }
  }
  if (best == null) return null;
  final title = best.title.trim();
  final artist = best.artist.trim();
  return _ResolvedAlbumRef(
    playlistId: best.playlistId,
    title: title.isNotEmpty ? title : 'Álbum',
    artist: artist.isNotEmpty
        ? artist
        : (compactArtist.isNotEmpty
              ? compactArtist
              : cleanArtistName(video.author)),
    thumbnailUrl: best.thumbnailUrl.trim(),
  );
}

Future<({String playlistId, String title, String artist, String thumbnailUrl})?>
resolveAlbumFromSongAndArtistLikeSearch({
  required String songTitle,
  required String artistName,
}) async {
  final compactTitle = songTitle.replaceAll(RegExp(r'\s+'), ' ').trim();
  final compactArtist = cleanArtistName(
    artistName,
  ).replaceAll(RegExp(r'\s+'), ' ').trim();
  if (compactTitle.isEmpty && compactArtist.isEmpty) return null;

  final normalizedTitle = _normalizeAlbumSearchText(compactTitle);
  final normalizedArtist = _normalizeAlbumSearchText(compactArtist);
  final queryCandidates =
      <String>{
            '$compactTitle $compactArtist',
            if (normalizedArtist.isNotEmpty) '$compactTitle $normalizedArtist',
            if (normalizedTitle.isNotEmpty && normalizedArtist.isNotEmpty)
              '$normalizedTitle $normalizedArtist',
            compactTitle,
          }
          .map((q) => q.replaceAll(RegExp(r'\s+'), ' ').trim())
          .where((q) => q.isNotEmpty)
          .toList(growable: false);

  _SearchAlbumResult? best;
  for (final query in queryCandidates) {
    final results = await _searchAlbumsFromAppEngine(query);
    if (results.isNotEmpty) {
      best = results.first;
      break;
    }
  }
  if (best == null) return null;
  final title = best.title.trim();
  final artist = best.artist.trim();
  return (
    playlistId: best.playlistId,
    title: title.isNotEmpty ? title : 'Álbum',
    artist: artist.isNotEmpty
        ? artist
        : (compactArtist.isNotEmpty
              ? compactArtist
              : cleanArtistName(artistName)),
    thumbnailUrl: best.thumbnailUrl.trim(),
  );
}

String _extractYouTubeText(dynamic node) {
  if (node == null) return '';
  if (node is String) return node.trim();
  if (node is Map) {
    final simpleText = node['simpleText'];
    if (simpleText is String && simpleText.trim().isNotEmpty) {
      return simpleText.trim();
    }
    final textValue = node['text'];
    if (textValue is String && textValue.trim().isNotEmpty) {
      return textValue.trim();
    }
    final runs = node['runs'];
    if (runs is List) {
      final parts = <String>[];
      for (final run in runs) {
        if (run is! Map) continue;
        final text = run['text'];
        if (text is String && text.trim().isNotEmpty) {
          parts.add(text.trim());
        }
      }
      if (parts.isNotEmpty) return parts.join('');
    }
  }
  return '';
}

// ignore: unused_element
String? _extractAlbumTitleFromNextPayload(dynamic node, {int depth = 0}) {
  if (depth > 18 || node == null) return null;
  if (node is Map) {
    final header = node['musicDetailHeaderRenderer'];
    if (header is Map) {
      final title = _extractYouTubeText(header['title']).trim();
      if (title.isNotEmpty) return title;
    }
    final title = _extractYouTubeText(node['title']).trim();
    final subtitle = _extractYouTubeText(node['subtitle']).trim();
    final pageType =
        (((node['browseEndpointContextSupportedConfigs']
                        as Map?)?['browseEndpointContextMusicConfig']
                    as Map?)?['pageType'] ??
                '')
            .toString();
    if (title.isNotEmpty &&
        (pageType.contains('ALBUM') || subtitle.contains('Album'))) {
      return title;
    }
    for (final value in node.values) {
      final nested = _extractAlbumTitleFromNextPayload(value, depth: depth + 1);
      if (nested != null && nested.isNotEmpty) return nested;
    }
  } else if (node is List) {
    for (final value in node) {
      final nested = _extractAlbumTitleFromNextPayload(value, depth: depth + 1);
      if (nested != null && nested.isNotEmpty) return nested;
    }
  }
  return null;
}

class SearchChannelWithSubscribers {
  final SearchChannel channel;
  final int? subscribersCount;
  final String? thumbnailUrlOverride;

  const SearchChannelWithSubscribers({
    required this.channel,
    required this.subscribersCount,
    this.thumbnailUrlOverride,
  });

  SearchChannelWithSubscribers copyWith({
    SearchChannel? channel,
    int? subscribersCount,
    String? thumbnailUrlOverride,
  }) {
    return SearchChannelWithSubscribers(
      channel: channel ?? this.channel,
      subscribersCount: subscribersCount ?? this.subscribersCount,
      thumbnailUrlOverride: thumbnailUrlOverride ?? this.thumbnailUrlOverride,
    );
  }
}

class _SearchTabTrackHistoryEntry {
  final String videoId;
  final String title;
  final String artist;
  final String thumbnailUrl;
  final bool isLocal;
  final String? localFilePath;
  final int touchedAtMs;

  const _SearchTabTrackHistoryEntry({
    required this.videoId,
    required this.title,
    required this.artist,
    required this.thumbnailUrl,
    required this.isLocal,
    this.localFilePath,
    required this.touchedAtMs,
  });

  factory _SearchTabTrackHistoryEntry.fromMap(Map<String, dynamic> map) {
    return _SearchTabTrackHistoryEntry(
      videoId: (map['videoId'] ?? '').toString().trim(),
      title: (map['title'] ?? '').toString().trim(),
      artist: cleanArtistName((map['artist'] ?? '').toString().trim()),
      thumbnailUrl: (map['thumbnailUrl'] ?? '').toString().trim(),
      isLocal: map['isLocal'] == true,
      localFilePath: (map['localFilePath'] ?? '').toString().trim().isEmpty
          ? null
          : (map['localFilePath'] ?? '').toString().trim(),
      touchedAtMs:
          (map['touchedAtMs'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
    );
  }

  Map<String, dynamic> toMap() => <String, dynamic>{
    'videoId': videoId,
    'title': title,
    'artist': artist,
    'thumbnailUrl': thumbnailUrl,
    'isLocal': isLocal,
    'localFilePath': localFilePath ?? '',
    'touchedAtMs': touchedAtMs,
  };
}

class _SearchTabArtistHistoryEntry {
  final String channelId;
  final String channelName;
  final String channelThumbnailUrl;
  final int touchedAtMs;

  const _SearchTabArtistHistoryEntry({
    required this.channelId,
    required this.channelName,
    required this.channelThumbnailUrl,
    required this.touchedAtMs,
  });

  factory _SearchTabArtistHistoryEntry.fromMap(Map<String, dynamic> map) {
    return _SearchTabArtistHistoryEntry(
      channelId: (map['channelId'] ?? '').toString().trim(),
      channelName: (map['channelName'] ?? '').toString().trim(),
      channelThumbnailUrl: (map['channelThumbnailUrl'] ?? '').toString().trim(),
      touchedAtMs:
          (map['touchedAtMs'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
    );
  }

  Map<String, dynamic> toMap() => <String, dynamic>{
    'channelId': channelId,
    'channelName': channelName,
    'channelThumbnailUrl': channelThumbnailUrl,
    'touchedAtMs': touchedAtMs,
  };
}

enum _SearchHistoryMixedItemType { artist, track }

class _SearchHistoryMixedItem {
  final _SearchHistoryMixedItemType type;
  final _SearchTabArtistHistoryEntry? artist;
  final _SearchTabTrackHistoryEntry? track;

  const _SearchHistoryMixedItem._({
    required this.type,
    this.artist,
    this.track,
  });

  factory _SearchHistoryMixedItem.artist(_SearchTabArtistHistoryEntry value) {
    return _SearchHistoryMixedItem._(
      type: _SearchHistoryMixedItemType.artist,
      artist: value,
    );
  }

  factory _SearchHistoryMixedItem.track(_SearchTabTrackHistoryEntry value) {
    return _SearchHistoryMixedItem._(
      type: _SearchHistoryMixedItemType.track,
      track: value,
    );
  }
}

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage>
    with SingleTickerProviderStateMixin {
  static const int _minimumSubscribers = 100000;
  static const int _maxChannelsToShow = 2;
  static const String _searchNetworkCacheBoxName = 'search_network_cache';
  static const String _searchAutocompleteCacheKey = 'autocomplete_v1';
  static const String _searchArtistByVideoCacheKey = 'artist_by_video_v1';
  static const String _searchAlbumByVideoCacheKey = 'album_by_video_v1';
  static const Duration _autocompletePersistentTtl = Duration(hours: 18);
  static const Duration _artistByVideoPersistentTtl = Duration(days: 14);
  static const Duration _albumByVideoPersistentTtl = Duration(days: 10);
  static const int _autocompletePersistentMaxEntries = 180;
  static const int _artistByVideoPersistentMaxEntries = 300;
  static const int _albumByVideoPersistentMaxEntries = 300;
  static const String _searchTabHistoryBoxName = 'search_tab_history';
  static const String _searchTabTrackHistoryKey = 'tracks_v1';
  static const String _searchTabArtistHistoryKey = 'artists_v1';
  static const int _searchTabTrackHistoryMaxEntries = 24;
  static const int _searchTabArtistHistoryMaxEntries = 16;
  final TextEditingController _textController = TextEditingController();
  final YoutubeExplode _youtubeExplode = YoutubeExplode();
  List<Video> _videos = [];
  List<SearchChannelWithSubscribers> _channels = [];
  List<_SearchAlbumResult> _albums = [];
  SearchState _searchState = SearchState.initial;
  final Map<String, List<Video>> _searchCache = {};
  final Map<String, List<_SearchAlbumResult>> _albumSearchCache = {};
  final Map<String, Object> _channelSearchCache = {};
  final Map<String, Future<List<Video>>> _searchInFlight = {};
  final Map<String, Future<List<_SearchAlbumResult>>> _albumSearchInFlight = {};
  final Map<String, Future<Object>> _channelSearchInFlight = {};
  final Map<String, int?> _subscriberCountCache = {};
  final Map<String, String?> _channelLogoCache = {};
  final FocusNode _searchFocusNode = FocusNode();
  int _searchEpoch = 0;
  int _autocompleteEpoch = 0;
  _SearchFilterMode _filterMode = _SearchFilterMode.music;
  bool _showArtists = true;
  bool _showAlbums = true;
  _SelectedArtistView? _selectedArtistView;
  _SelectedAlbumView? _selectedAlbumView;
  int _artistTransitionDirection = 1;
  bool _searchTabHistoryLoading = true;
  List<_SearchTabTrackHistoryEntry> _searchTabTrackHistory = const [];
  List<_SearchTabArtistHistoryEntry> _searchTabArtistHistory = const [];
  bool _autocompleteLoading = false;
  List<String> _autocompleteSuggestions = const [];
  final Map<String, List<String>> _autocompleteCache = {};
  final Map<String, PendingArtistProfile> _artistProfileByVideoIdCache = {};
  final Map<String, Future<PendingArtistProfile?>>
  _artistProfileByVideoIdInFlight = {};
  final Map<String, _ResolvedAlbumRef> _albumRefByVideoIdCache = {};
  final Map<String, Future<_ResolvedAlbumRef?>> _albumRefByVideoIdInFlight = {};
  Timer? _autocompleteDebounce;
  SearchViewState? _searchViewState;
  AnimationController? _searchBarGlowController;

  @override
  void initState() {
    super.initState();
    _textController.addListener(_onSearchTextChanged);
    _ensureSearchBarGlowController();
    _searchFocusNode.addListener(() {
      if (mounted) setState(() {});
    });
    unawaited(_loadSearchTabHistory());
    unawaited(_loadSearchNetworkCaches());
  }

  AnimationController _ensureSearchBarGlowController() {
    final existing = _searchBarGlowController;
    if (existing != null) return existing;
    final created = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    );
    _searchBarGlowController = created;
    return created;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextState = context.read<SearchViewState>();
    if (identical(_searchViewState, nextState)) return;
    _searchViewState?.removeListener(_handleSearchViewStateChanged);
    _searchViewState = nextState;
    _searchViewState?.addListener(_handleSearchViewStateChanged);
  }

  void _handleSearchViewStateChanged() {
    if (!mounted) return;
    final pending = _searchViewState?.consumePendingArtistProfile();
    if (pending == null) return;
    unawaited(
      _openArtistEmbedded(
        channelId: pending.channelId,
        channelName: pending.channelName,
        channelThumbnailUrl: pending.channelThumbnailUrl,
      ),
    );
  }

  void _syncEmbeddedSearchFullscreen() {
    final isFullscreenContentVisible =
        _selectedArtistView != null || _selectedAlbumView != null;
    _searchViewState?.setArtistFullscreen(isFullscreenContentVisible);
  }

  bool get _isMusicFilterMode => _filterMode == _SearchFilterMode.music;
  bool get _isPodcastFilterMode => _filterMode == _SearchFilterMode.podcast;
  bool get _isVideosFilterMode => _filterMode == _SearchFilterMode.videos;

  void _refreshSearchForCurrentQueryIfNeeded() {
    if (_textController.text.trim().isEmpty) return;
    unawaited(_searchVideos());
  }

  void _activateMusicFilters() {
    setState(() {
      _filterMode = _SearchFilterMode.music;
      _showArtists = true;
      _showAlbums = true;
    });
    _refreshSearchForCurrentQueryIfNeeded();
  }

  void _togglePodcastFilter() {
    setState(() {
      if (_isPodcastFilterMode) {
        _filterMode = _SearchFilterMode.music;
        _showArtists = true;
        _showAlbums = true;
      } else {
        _filterMode = _SearchFilterMode.podcast;
        _showArtists = false;
        _showAlbums = false;
      }
    });
    _refreshSearchForCurrentQueryIfNeeded();
  }

  void _toggleVideosFilter() {
    setState(() {
      if (_isVideosFilterMode) {
        _filterMode = _SearchFilterMode.music;
        _showArtists = true;
        _showAlbums = true;
      } else {
        _filterMode = _SearchFilterMode.videos;
        _showArtists = false;
        _showAlbums = false;
      }
    });
    _refreshSearchForCurrentQueryIfNeeded();
  }

  @override
  void reassemble() {
    super.reassemble();
    _channelSearchCache.clear();
    _channelSearchInFlight.clear();
    _channels = [];
  }

  Future<void> _searchVideos({String? forcedQuery}) async {
    final query = (forcedQuery ?? _textController.text).trim();
    if (query.isEmpty) return;
    if (forcedQuery != null) {
      _textController.value = TextEditingValue(
        text: query,
        selection: TextSelection.collapsed(offset: query.length),
      );
    }
    FocusScope.of(context).unfocus();
    _clearAutocompleteSuggestions();
    final epoch = ++_searchEpoch;
    final searchCacheKey = '${_filterMode.name}|$query';
    final cached = _searchCache[searchCacheKey];
    if (_isMusicFilterMode) {
      final cachedChannels = await _getCachedChannels(query);
      final cachedPrimaryArtist = cached != null && cached.isNotEmpty
          ? cleanArtistName(cached.first.author).trim()
          : '';
      final cachedAlbums = cachedPrimaryArtist.isNotEmpty
          ? _albumSearchCache[cachedPrimaryArtist]
          : _albumSearchCache[query];
      if (cached != null && cachedChannels != null && cachedAlbums != null) {
        setState(() {
          _videos = cached;
          _channels = cachedChannels;
          _albums = cachedAlbums;
          _searchState =
              cached.isEmpty && cachedChannels.isEmpty && cachedAlbums.isEmpty
              ? SearchState.noResults
              : SearchState.success;
        });
        return;
      }
    } else if (cached != null) {
      if (_isVideosFilterMode || _isPodcastFilterMode) {
        final cachedChannels = await _getCachedChannels(query);
        setState(() {
          _videos = cached;
          _channels = cachedChannels ?? const <SearchChannelWithSubscribers>[];
          _albums = const <_SearchAlbumResult>[];
          _searchState = _videos.isEmpty && _channels.isEmpty
              ? SearchState.noResults
              : SearchState.success;
        });
      } else {
        setState(() {
          _videos = cached;
          _channels = const <SearchChannelWithSubscribers>[];
          _albums = const <_SearchAlbumResult>[];
          _searchState = cached.isEmpty
              ? SearchState.noResults
              : SearchState.success;
        });
      }
      return;
    }

    setState(() {
      _searchState = SearchState.loading;
      _videos = [];
      _channels = [];
      _albums = [];
    });

    try {
      final videosFuture = _searchWithCache(query, mode: _filterMode);

      if (_isPodcastFilterMode) {
        final channelsFuture = _searchChannelsWithCache(query);
        final searchResult = await videosFuture;
        if (!mounted || epoch != _searchEpoch) return;
        setState(() {
          _videos = searchResult.toList(growable: false);
          _channels = const <SearchChannelWithSubscribers>[];
          _albums = const <_SearchAlbumResult>[];
          _searchState = _videos.isEmpty
              ? SearchState.noResults
              : SearchState.success;
        });

        final channelResult = await channelsFuture;
        if (!mounted || epoch != _searchEpoch) return;
        setState(() {
          _channels = channelResult.take(2).toList(growable: false);
          _searchState = _videos.isEmpty && _channels.isEmpty
              ? SearchState.noResults
              : SearchState.success;
        });
        return;
      }

      if (_isVideosFilterMode) {
        final channelsFuture = _searchChannelsWithCache(query);
        final searchResult = await videosFuture;
        if (!mounted || epoch != _searchEpoch) return;
        setState(() {
          _videos = searchResult.toList(growable: false);
          _channels = const <SearchChannelWithSubscribers>[];
          _albums = const <_SearchAlbumResult>[];
          _searchState = _videos.isEmpty
              ? SearchState.noResults
              : SearchState.success;
        });

        final channelResult = await channelsFuture;
        if (!mounted || epoch != _searchEpoch) return;
        setState(() {
          _channels = channelResult.take(2).toList(growable: false);
          _searchState = _videos.isEmpty && _channels.isEmpty
              ? SearchState.noResults
              : SearchState.success;
        });
        return;
      }

      final channelsFuture = _searchChannelsWithCache(query);

      // Mostramos el canal del artista tan pronto como esté listo.
      unawaited(() async {
        try {
          final channelResult = await channelsFuture;
          if (!mounted || epoch != _searchEpoch) return;
          setState(() {
            _channels = channelResult;
            _searchState =
                _videos.isEmpty && channelResult.isEmpty && _albums.isEmpty
                ? SearchState.noResults
                : SearchState.success;
          });
        } catch (_) {
          // Ignoramos: la búsqueda de videos puede seguir funcionando.
        }
      }());

      final searchResult = await videosFuture;
      if (!mounted || epoch != _searchEpoch) return;
      setState(() {
        _videos = searchResult.toList();
        _channels = _channels.isNotEmpty ? _channels : const [];
        _searchState = _videos.isEmpty && _channels.isEmpty && _albums.isEmpty
            ? SearchState.noResults
            : SearchState.success;
      });

      // Si canales aún no termina, esperamos su resultado final.
      final channelResult = await channelsFuture;
      if (!mounted || epoch != _searchEpoch) return;
      setState(() {
        _channels = channelResult;
        _searchState =
            _videos.isEmpty && channelResult.isEmpty && _albums.isEmpty
            ? SearchState.noResults
            : SearchState.success;
      });

      final primaryArtistQuery = searchResult.isNotEmpty
          ? cleanArtistName(searchResult.first.author).trim()
          : '';
      final normalizedPrimaryArtist = _normalizeAlbumSearchText(
        primaryArtistQuery,
      );
      final hasMeaningfulPrimaryArtist =
          normalizedPrimaryArtist.isNotEmpty &&
          normalizedPrimaryArtist != 'artista' &&
          normalizedPrimaryArtist != 'artist' &&
          normalizedPrimaryArtist != 'unknown artist';
      final albumQueryCandidates = <String>[
        if (hasMeaningfulPrimaryArtist) primaryArtistQuery,
        query,
      ].where((value) => value.trim().isNotEmpty).toSet().toList();
      List<_SearchAlbumResult> albumResult = const <_SearchAlbumResult>[];
      for (final albumQuery in albumQueryCandidates) {
        albumResult = await _searchAlbumsWithCache(albumQuery);
        if (albumResult.isNotEmpty) break;
      }
      if (!mounted || epoch != _searchEpoch) return;
      setState(() {
        _albums = albumResult;
        _searchState =
            _videos.isEmpty && _channels.isEmpty && albumResult.isEmpty
            ? SearchState.noResults
            : SearchState.success;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _searchState = SearchState.error);
      }
    }
  }

  Future<void> _loadSearchTabHistory() async {
    try {
      final box = await Hive.openBox<String>(_searchTabHistoryBoxName);
      final tracksRaw = box.get(_searchTabTrackHistoryKey);
      final artistsRaw = box.get(_searchTabArtistHistoryKey);

      List<_SearchTabTrackHistoryEntry> tracks = const [];
      List<_SearchTabArtistHistoryEntry> artists = const [];

      if (tracksRaw != null && tracksRaw.isNotEmpty) {
        final decoded = jsonDecode(tracksRaw);
        if (decoded is List) {
          tracks = decoded
              .whereType<Map>()
              .map(
                (item) => _SearchTabTrackHistoryEntry.fromMap(
                  Map<String, dynamic>.from(item.cast<dynamic, dynamic>()),
                ),
              )
              .where((item) => item.videoId.isNotEmpty && item.title.isNotEmpty)
              .take(_searchTabTrackHistoryMaxEntries)
              .toList(growable: false);
        }
      }

      if (artistsRaw != null && artistsRaw.isNotEmpty) {
        final decoded = jsonDecode(artistsRaw);
        if (decoded is List) {
          artists = decoded
              .whereType<Map>()
              .map(
                (item) => _SearchTabArtistHistoryEntry.fromMap(
                  Map<String, dynamic>.from(item.cast<dynamic, dynamic>()),
                ),
              )
              .where(
                (item) =>
                    item.channelId.isNotEmpty && item.channelName.isNotEmpty,
              )
              .take(_searchTabArtistHistoryMaxEntries)
              .toList(growable: false);
        }
      }

      if (!mounted) return;
      setState(() {
        _searchTabTrackHistory = tracks;
        _searchTabArtistHistory = artists;
        _searchTabHistoryLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _searchTabTrackHistory = const [];
        _searchTabArtistHistory = const [];
        _searchTabHistoryLoading = false;
      });
    }
  }

  bool _isWithinTtl(int savedAtMs, Duration ttl) {
    if (savedAtMs <= 0) return false;
    final savedAt = DateTime.fromMillisecondsSinceEpoch(savedAtMs);
    if (savedAt.isAfter(DateTime.now())) return false;
    return DateTime.now().difference(savedAt) <= ttl;
  }

  Future<void> _loadSearchNetworkCaches() async {
    try {
      final box = await Hive.openBox<String>(_searchNetworkCacheBoxName);
      final autocompleteRaw = box.get(_searchAutocompleteCacheKey);
      if (autocompleteRaw != null && autocompleteRaw.isNotEmpty) {
        _hydrateAutocompletePersistentCache(autocompleteRaw);
      }

      final artistRaw = box.get(_searchArtistByVideoCacheKey);
      if (artistRaw != null && artistRaw.isNotEmpty) {
        _hydrateArtistByVideoPersistentCache(artistRaw);
      }

      final albumRaw = box.get(_searchAlbumByVideoCacheKey);
      if (albumRaw != null && albumRaw.isNotEmpty) {
        _hydrateAlbumByVideoPersistentCache(albumRaw);
      }
    } catch (_) {
      // Best effort.
    }
  }

  void _hydrateAutocompletePersistentCache(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final map = Map<String, dynamic>.from(decoded.cast<dynamic, dynamic>());
      final items = map['items'];
      if (items is! List) return;

      for (final row in items.whereType<Map>()) {
        final item = Map<String, dynamic>.from(row.cast<dynamic, dynamic>());
        final query = (item['query'] ?? '').toString().trim();
        final savedAtMs = (item['savedAtMs'] as num?)?.toInt() ?? 0;
        if (query.isEmpty ||
            !_isWithinTtl(savedAtMs, _autocompletePersistentTtl)) {
          continue;
        }
        final suggestionsRaw = item['suggestions'];
        if (suggestionsRaw is! List) continue;
        final suggestions = suggestionsRaw
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .take(10)
            .toList(growable: false);
        if (suggestions.isEmpty) continue;
        _autocompleteCache[query] = suggestions;
      }
    } catch (_) {
      // Best effort.
    }
  }

  void _hydrateArtistByVideoPersistentCache(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final map = Map<String, dynamic>.from(decoded.cast<dynamic, dynamic>());
      final items = map['items'];
      if (items is! List) return;

      for (final row in items.whereType<Map>()) {
        final item = Map<String, dynamic>.from(row.cast<dynamic, dynamic>());
        final videoId = (item['videoId'] ?? '').toString().trim();
        final channelId = (item['channelId'] ?? '').toString().trim();
        final channelName = (item['channelName'] ?? '').toString().trim();
        final channelThumb = (item['channelThumbnailUrl'] ?? '')
            .toString()
            .trim();
        final savedAtMs = (item['savedAtMs'] as num?)?.toInt() ?? 0;
        if (videoId.isEmpty ||
            channelId.isEmpty ||
            channelName.isEmpty ||
            !_isWithinTtl(savedAtMs, _artistByVideoPersistentTtl)) {
          continue;
        }
        _artistProfileByVideoIdCache[videoId] = PendingArtistProfile(
          channelId: channelId,
          channelName: channelName,
          channelThumbnailUrl: channelThumb,
        );
      }
    } catch (_) {
      // Best effort.
    }
  }

  void _hydrateAlbumByVideoPersistentCache(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final map = Map<String, dynamic>.from(decoded.cast<dynamic, dynamic>());
      final items = map['items'];
      if (items is! List) return;

      for (final row in items.whereType<Map>()) {
        final item = Map<String, dynamic>.from(row.cast<dynamic, dynamic>());
        final videoId = (item['videoId'] ?? '').toString().trim();
        final playlistId = (item['playlistId'] ?? '').toString().trim();
        final title = (item['title'] ?? '').toString().trim();
        final artist = (item['artist'] ?? '').toString().trim();
        final thumbnailUrl = (item['thumbnailUrl'] ?? '').toString().trim();
        final savedAtMs = (item['savedAtMs'] as num?)?.toInt() ?? 0;
        if (videoId.isEmpty ||
            playlistId.isEmpty ||
            title.isEmpty ||
            !_isWithinTtl(savedAtMs, _albumByVideoPersistentTtl)) {
          continue;
        }
        _albumRefByVideoIdCache[videoId] = _ResolvedAlbumRef(
          playlistId: playlistId,
          title: title,
          artist: artist.isEmpty ? 'Artista' : artist,
          thumbnailUrl: thumbnailUrl,
        );
      }
    } catch (_) {
      // Best effort.
    }
  }

  Future<void> _persistAutocompletePersistentCache() async {
    try {
      final box = await Hive.openBox<String>(_searchNetworkCacheBoxName);
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final payload = jsonEncode({
        'savedAtMs': nowMs,
        'items': _autocompleteCache.entries
            .where((entry) => entry.key.trim().isNotEmpty)
            .take(_autocompletePersistentMaxEntries)
            .map(
              (entry) => {
                'query': entry.key,
                'suggestions': entry.value.take(10).toList(growable: false),
                'savedAtMs': nowMs,
              },
            )
            .toList(growable: false),
      });
      await box.put(_searchAutocompleteCacheKey, payload);
    } catch (_) {
      // Best effort.
    }
  }

  Future<void> _persistArtistByVideoPersistentCache() async {
    try {
      final box = await Hive.openBox<String>(_searchNetworkCacheBoxName);
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final payload = jsonEncode({
        'savedAtMs': nowMs,
        'items': _artistProfileByVideoIdCache.entries
            .where((entry) => entry.key.trim().isNotEmpty)
            .take(_artistByVideoPersistentMaxEntries)
            .map(
              (entry) => {
                'videoId': entry.key,
                'channelId': entry.value.channelId,
                'channelName': entry.value.channelName,
                'channelThumbnailUrl': entry.value.channelThumbnailUrl,
                'savedAtMs': nowMs,
              },
            )
            .toList(growable: false),
      });
      await box.put(_searchArtistByVideoCacheKey, payload);
    } catch (_) {
      // Best effort.
    }
  }

  Future<void> _persistAlbumByVideoPersistentCache() async {
    try {
      final box = await Hive.openBox<String>(_searchNetworkCacheBoxName);
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final payload = jsonEncode({
        'savedAtMs': nowMs,
        'items': _albumRefByVideoIdCache.entries
            .where((entry) => entry.key.trim().isNotEmpty)
            .take(_albumByVideoPersistentMaxEntries)
            .map(
              (entry) => {
                'videoId': entry.key,
                'playlistId': entry.value.playlistId,
                'title': entry.value.title,
                'artist': entry.value.artist,
                'thumbnailUrl': entry.value.thumbnailUrl,
                'savedAtMs': nowMs,
              },
            )
            .toList(growable: false),
      });
      await box.put(_searchAlbumByVideoCacheKey, payload);
    } catch (_) {
      // Best effort.
    }
  }

  Future<void> _persistSearchTabHistory() async {
    try {
      final box = await Hive.openBox<String>(_searchTabHistoryBoxName);
      final tracksPayload = jsonEncode(
        _searchTabTrackHistory
            .take(_searchTabTrackHistoryMaxEntries)
            .map((item) => item.toMap())
            .toList(growable: false),
      );
      final artistsPayload = jsonEncode(
        _searchTabArtistHistory
            .take(_searchTabArtistHistoryMaxEntries)
            .map((item) => item.toMap())
            .toList(growable: false),
      );
      await box.put(_searchTabTrackHistoryKey, tracksPayload);
      await box.put(_searchTabArtistHistoryKey, artistsPayload);
    } catch (_) {
      // Best effort.
    }
  }

  void _rememberSearchTrackHistory(_SearchTabTrackHistoryEntry entry) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final normalized = _SearchTabTrackHistoryEntry(
      videoId: entry.videoId.trim(),
      title: entry.title.trim().isEmpty ? 'Canción' : entry.title.trim(),
      artist: entry.artist.trim().isEmpty ? 'Artista' : entry.artist.trim(),
      thumbnailUrl: entry.thumbnailUrl.trim(),
      isLocal: entry.isLocal,
      localFilePath: entry.localFilePath?.trim(),
      touchedAtMs: nowMs,
    );
    final updated = <_SearchTabTrackHistoryEntry>[
      normalized,
      ..._searchTabTrackHistory.where(
        (item) => item.videoId != normalized.videoId,
      ),
    ];
    _searchTabTrackHistory = updated
        .take(_searchTabTrackHistoryMaxEntries)
        .toList(growable: false);
    _searchTabHistoryLoading = false;
    if (mounted && _searchState == SearchState.initial) {
      setState(() {});
    }
    unawaited(_persistSearchTabHistory());
  }

  void _rememberSearchArtistHistory(_SearchTabArtistHistoryEntry entry) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final normalized = _SearchTabArtistHistoryEntry(
      channelId: entry.channelId.trim(),
      channelName: entry.channelName.trim(),
      channelThumbnailUrl: entry.channelThumbnailUrl.trim(),
      touchedAtMs: nowMs,
    );
    final updated = <_SearchTabArtistHistoryEntry>[
      normalized,
      ..._searchTabArtistHistory.where(
        (item) => item.channelId != normalized.channelId,
      ),
    ];
    _searchTabArtistHistory = updated
        .take(_searchTabArtistHistoryMaxEntries)
        .toList(growable: false);
    _searchTabHistoryLoading = false;
    if (mounted && _searchState == SearchState.initial) {
      setState(() {});
    }
    unawaited(_persistSearchTabHistory());
  }

  void _onSearchTextChanged() {
    final raw = _textController.text;
    final query = raw.trim();
    _autocompleteDebounce?.cancel();
    final requestId = ++_autocompleteEpoch;

    if (query.isEmpty) {
      if (!mounted) return;
      setState(() {
        _autocompleteLoading = false;
        _autocompleteSuggestions = const [];
      });
      return;
    }

    _autocompleteDebounce = Timer(const Duration(milliseconds: 240), () async {
      if (!mounted) return;
      if (!_searchFocusNode.hasFocus) return;
      setState(() {
        _autocompleteLoading = true;
      });

      final suggestions = await _loadAutocompleteSuggestions(query);
      if (!mounted || requestId != _autocompleteEpoch) return;
      setState(() {
        _autocompleteSuggestions = suggestions;
        _autocompleteLoading = false;
      });
    });
  }

  Future<List<String>> _loadAutocompleteSuggestions(String query) async {
    final normalized = query.trim();
    if (normalized.isEmpty) return const <String>[];
    final cached = _autocompleteCache[normalized];
    if (cached != null) return cached;

    List<String> suggestions = await _fetchYoutubeAutocompleteSuggestions(
      normalized,
    );
    if (suggestions.isEmpty) {
      suggestions = _fallbackAutocompleteSuggestions(normalized);
    }

    final limited = suggestions.take(10).toList(growable: false);
    _autocompleteCache[normalized] = limited;
    unawaited(_persistAutocompletePersistentCache());
    return limited;
  }

  Future<List<String>> _fetchYoutubeAutocompleteSuggestions(
    String query,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 7);
    try {
      final uri = Uri.https('suggestqueries.google.com', '/complete/search', {
        'client': 'firefox',
        'ds': 'yt',
        'q': query,
      });
      final req = await client.getUrl(uri).timeout(const Duration(seconds: 7));
      req.headers.set(
        HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)',
      );
      final res = await req.close().timeout(const Duration(seconds: 8));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        return const <String>[];
      }
      final body = await utf8.decoder.bind(res).join();
      final decoded = jsonDecode(body);
      if (decoded is! List || decoded.length < 2 || decoded[1] is! List) {
        return const <String>[];
      }
      final seen = <String>{};
      final output = <String>[];
      for (final item in decoded[1] as List) {
        final suggestion = item.toString().trim();
        if (suggestion.isEmpty) continue;
        if (!seen.add(suggestion.toLowerCase())) continue;
        output.add(suggestion);
        if (output.length >= 12) break;
      }
      return output;
    } catch (_) {
      return const <String>[];
    } finally {
      client.close(force: true);
    }
  }

  List<String> _fallbackAutocompleteSuggestions(String query) {
    final normalized = query.toLowerCase();
    final seen = <String>{};
    final output = <String>[];
    for (final key in _searchCache.keys) {
      final value = key.trim();
      if (value.isEmpty) continue;
      final low = value.toLowerCase();
      if (!low.startsWith(normalized) && !low.contains(normalized)) continue;
      if (!seen.add(low)) continue;
      output.add(value);
      if (output.length >= 10) break;
    }
    return output;
  }

  void _clearAutocompleteSuggestions() {
    _autocompleteDebounce?.cancel();
    _autocompleteEpoch++;
    if (!mounted) return;
    setState(() {
      _autocompleteLoading = false;
      _autocompleteSuggestions = const [];
    });
  }

  Future<void> _clearSearchAndShowInitialRecommendations() async {
    _textController.clear();
    _clearAutocompleteSuggestions();
    if (!mounted) return;
    setState(() {
      _videos = const [];
      _channels = const [];
      _albums = const [];
      _searchState = SearchState.initial;
    });
  }

  Future<void> _applySuggestionAndSearch(String suggestion) async {
    await _searchVideos(forcedQuery: suggestion);
  }

  Future<void> _openChannel(SearchChannelWithSubscribers channelData) async {
    final channel = channelData.channel;
    _rememberSearchArtistHistory(
      _SearchTabArtistHistoryEntry(
        channelId: channel.id.value,
        channelName: channel.name,
        channelThumbnailUrl: _thumbnailOf(channelData) ?? '',
        touchedAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    await _openArtistEmbedded(
      channelId: channel.id.value,
      channelName: channel.name,
      channelThumbnailUrl: _thumbnailOf(channelData) ?? '',
    );
  }

  Future<void> _openArtistEmbedded({
    required String channelId,
    required String channelName,
    required String channelThumbnailUrl,
  }) async {
    if (!mounted) return;
    setState(() {
      _artistTransitionDirection = 1;
      _selectedArtistView = _SelectedArtistView(
        channelId: channelId,
        channelName: channelName,
        channelThumbnailUrl: channelThumbnailUrl,
      );
    });
    _syncEmbeddedSearchFullscreen();
  }

  void _closeArtistChannel() {
    setState(() {
      _artistTransitionDirection = -1;
      _selectedArtistView = null;
    });
    _syncEmbeddedSearchFullscreen();
  }

  Future<void> _openAlbumEmbedded({
    required String playlistId,
    required String albumTitle,
    required String artistName,
    required String seedThumbnailUrl,
  }) async {
    if (!mounted) return;
    setState(() {
      _artistTransitionDirection = 1;
      _selectedAlbumView = _SelectedAlbumView(
        playlistId: playlistId,
        albumTitle: albumTitle,
        artistName: artistName,
        seedThumbnailUrl: seedThumbnailUrl,
      );
    });
    _syncEmbeddedSearchFullscreen();
  }

  void _closeAlbumView() {
    setState(() {
      _artistTransitionDirection = -1;
      _selectedAlbumView = null;
    });
    _syncEmbeddedSearchFullscreen();
  }

  Future<void> _openVideoPlayer(
    String videoId, {
    String? thumbnailUrl,
    String? title,
    String? artist,
    bool forceVideoPlayback = false,
  }) async {
    try {
      final manager = Provider.of<VideoPlayerManager>(context, listen: false);
      manager.registerSearchThumbnail(videoId, thumbnailUrl);
      await manager.playFromUserSelection(
        context,
        videoId,
        preferredThumbnailUrl: thumbnailUrl,
        preferredTitle: title,
        preferredArtist: artist,
        preferVideoPlayback: forceVideoPlayback || _isVideosFilterMode,
        forceBackendResolver: forceVideoPlayback || _isVideosFilterMode,
      );
      _rememberSearchTrackHistory(
        _SearchTabTrackHistoryEntry(
          videoId: videoId.trim(),
          title: (title ?? '').trim(),
          artist: cleanArtistName(artist),
          thumbnailUrl: (thumbnailUrl ?? '').trim(),
          isLocal: false,
          touchedAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    } catch (e, s) {
      developer.log('Error al abrir reproductor', error: e, stackTrace: s);
      if (!mounted) return;
      showIosNotice(context, 'No se pudo iniciar la reproducción.');
    }
  }

  Future<void> _playVideoPreferLocal(Video video) async {
    final downloadService = context.read<DownloadService>();
    final videoManager = context.read<VideoPlayerManager>();
    final local = await downloadService.getDownloadedVideoById(video.id.value);

    if (!mounted) return;
    if (local != null) {
      final thumb =
          (local.localThumbnailPath != null &&
              local.localThumbnailPath!.isNotEmpty)
          ? local.localThumbnailPath!
          : local.thumbnailUrl;
      await videoManager.playLocalFileFromUserSelection(
        context,
        id: local.videoId,
        filePath: local.filePath,
        title: local.title,
        thumbnailUrl: thumb,
        artist: local.channelTitle,
        localPlainLyrics: local.plainLyrics,
        localSyncedLyrics: local.syncedLyrics,
        queueStrategy: LocalPlaybackQueueStrategy.recommendations,
      );
      _rememberSearchTrackHistory(
        _SearchTabTrackHistoryEntry(
          videoId: local.videoId.trim(),
          title: local.title.trim(),
          artist: cleanArtistName(local.channelTitle),
          thumbnailUrl: thumb.trim(),
          isLocal: true,
          localFilePath: local.filePath.trim(),
          touchedAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      return;
    }

    await _openVideoPlayer(
      video.id.value,
      thumbnailUrl: _bestQualityThumbnail(video),
      title: video.title,
      artist: cleanArtistName(video.author),
      forceVideoPlayback: _isVideosFilterMode,
    );
  }

  void _queueVideo(
    Video video, {
    ManualQueueInsertMode insertMode = ManualQueueInsertMode.end,
  }) {
    final manager = context.read<VideoPlayerManager>();
    final added = manager.addOnlineTrackToPlaybackQueue(
      videoId: video.id.value,
      title: video.title,
      thumbnailUrl: _bestQualityThumbnail(video),
      artist: cleanArtistName(video.author),
      insertMode: insertMode,
    );
    if (!mounted) return;
    _showIosTopToast(
      context,
      message: added
          ? (insertMode == ManualQueueInsertMode.next
                ? 'Se añadió como siguiente'
                : 'Se ha añadido a la cola')
          : 'Esta canción ya está en cola',
      icon: added
          ? CupertinoIcons.check_mark_circled_solid
          : CupertinoIcons.info_circle_fill,
    );
  }

  void _queueHistoryTrack(
    _SearchTabTrackHistoryEntry entry, {
    ManualQueueInsertMode insertMode = ManualQueueInsertMode.end,
  }) {
    final manager = context.read<VideoPlayerManager>();
    final localPath = (entry.localFilePath ?? '').trim();
    final canQueueLocal = entry.isLocal && localPath.isNotEmpty;
    final added = canQueueLocal
        ? manager.addLocalTrackToPlaybackQueue(
            videoId: entry.videoId,
            filePath: localPath,
            title: entry.title,
            thumbnailUrl: entry.thumbnailUrl,
            artist: entry.artist,
            localPlainLyrics: null,
            localSyncedLyrics: null,
            insertMode: insertMode,
          )
        : manager.addOnlineTrackToPlaybackQueue(
            videoId: entry.videoId,
            title: entry.title,
            thumbnailUrl: entry.thumbnailUrl,
            artist: entry.artist,
            insertMode: insertMode,
          );
    if (!mounted) return;
    _showIosTopToast(
      context,
      message: added
          ? (insertMode == ManualQueueInsertMode.next
                ? 'Se añadió como siguiente'
                : 'Se ha añadido a la cola')
          : 'Esta canción ya está en cola',
      icon: added
          ? CupertinoIcons.check_mark_circled_solid
          : CupertinoIcons.info_circle_fill,
    );
  }

  Future<void> _openArtistFromVideo(Video video) async {
    final videoId = video.id.value.trim();
    if (videoId.isEmpty) return;
    final cached = _artistProfileByVideoIdCache[videoId];
    if (cached != null) {
      _rememberSearchArtistHistory(
        _SearchTabArtistHistoryEntry(
          channelId: cached.channelId,
          channelName: cached.channelName,
          channelThumbnailUrl: cached.channelThumbnailUrl,
          touchedAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      await _openArtistEmbedded(
        channelId: cached.channelId,
        channelName: cached.channelName,
        channelThumbnailUrl: cached.channelThumbnailUrl,
      );
      return;
    }

    final inFlight = _artistProfileByVideoIdInFlight[videoId];
    if (inFlight != null) {
      final resolved = await inFlight;
      if (!mounted || resolved == null) return;
      _rememberSearchArtistHistory(
        _SearchTabArtistHistoryEntry(
          channelId: resolved.channelId,
          channelName: resolved.channelName,
          channelThumbnailUrl: resolved.channelThumbnailUrl,
          touchedAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      await _openArtistEmbedded(
        channelId: resolved.channelId,
        channelName: resolved.channelName,
        channelThumbnailUrl: resolved.channelThumbnailUrl,
      );
      return;
    }

    try {
      final fetch =
          _runYoutubeWithRetry(
            () => _youtubeExplode.channels.getByVideo(videoId),
            maxAttempts: 1,
          ).then<PendingArtistProfile?>((details) {
            final channelId = details.id.value.trim();
            if (channelId.isEmpty) return null;
            return PendingArtistProfile(
              channelId: channelId,
              channelName: details.title,
              channelThumbnailUrl: details.logoUrl,
            );
          });
      _artistProfileByVideoIdInFlight[videoId] = fetch;
      final resolved = await fetch;
      _artistProfileByVideoIdInFlight.remove(videoId);
      if (!mounted || resolved == null) return;
      _artistProfileByVideoIdCache[videoId] = resolved;
      unawaited(_persistArtistByVideoPersistentCache());
      _rememberSearchArtistHistory(
        _SearchTabArtistHistoryEntry(
          channelId: resolved.channelId,
          channelName: resolved.channelName,
          channelThumbnailUrl: resolved.channelThumbnailUrl,
          touchedAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      await _openArtistEmbedded(
        channelId: resolved.channelId,
        channelName: resolved.channelName,
        channelThumbnailUrl: resolved.channelThumbnailUrl,
      );
    } catch (_) {
      _artistProfileByVideoIdInFlight.remove(videoId);
      if (!mounted) return;
      showIosNotice(context, 'No se pudo abrir el perfil del artista.');
    }
  }

  Future<_ResolvedAlbumRef?> _resolveAlbumFromVideo(Video video) async {
    final videoId = video.id.value.trim();
    if (videoId.isEmpty) return _resolveAlbumFromAppSearchEngine(video);

    final cached = _albumRefByVideoIdCache[videoId];
    if (cached != null) return cached;
    final inFlight = _albumRefByVideoIdInFlight[videoId];
    if (inFlight != null) return inFlight;

    final future = _resolveAlbumFromAppSearchEngine(video);
    _albumRefByVideoIdInFlight[videoId] = future;
    try {
      final resolved = await future;
      if (resolved != null) {
        _albumRefByVideoIdCache[videoId] = resolved;
        unawaited(_persistAlbumByVideoPersistentCache());
      }
      return resolved;
    } finally {
      _albumRefByVideoIdInFlight.remove(videoId);
    }
  }

  Future<void> _openAlbumFromVideo(Video video) async {
    try {
      final album = await _resolveAlbumFromVideo(video);
      if (!mounted) return;
      if (album == null) {
        showIosNotice(
          context,
          'No se pudo identificar el álbum de esta canción.',
        );
        return;
      }
      await _openAlbumEmbedded(
        playlistId: album.playlistId,
        albumTitle: album.title,
        artistName: album.artist,
        seedThumbnailUrl: album.thumbnailUrl.isNotEmpty
            ? album.thumbnailUrl
            : _bestQualityThumbnail(video),
      );
    } catch (_) {
      if (!mounted) return;
      showIosNotice(context, 'No se pudo abrir el álbum.');
    }
  }

  Future<void> _openAlbumFromSearchResult(_SearchAlbumResult album) async {
    if (!mounted) return;
    await _openAlbumEmbedded(
      playlistId: album.playlistId,
      albumTitle: album.title,
      artistName: album.artist,
      seedThumbnailUrl: album.thumbnailUrl,
    );
  }

  Future<void> _runVideoContextAction(
    Video video,
    _SearchVideoContextAction action,
  ) async {
    if (action == _SearchVideoContextAction.addToFavorites) {
      await _addVideoToPlaylist(video, PlaylistService.favoritesPlaylistName);
      return;
    }
    if (action == _SearchVideoContextAction.addToPlaylist) {
      await _showPlaylistPicker(video);
      return;
    }
    if (action == _SearchVideoContextAction.addNext) {
      _queueVideo(video, insertMode: ManualQueueInsertMode.next);
      return;
    }
    if (action == _SearchVideoContextAction.addToEnd) {
      _queueVideo(video, insertMode: ManualQueueInsertMode.end);
      return;
    }
    if (action == _SearchVideoContextAction.share) {
      await _shareVideoDeepLink(
        video,
        shareOrigin: _shareOriginFromContext(context),
      );
      return;
    }
    if (action == _SearchVideoContextAction.openArtist) {
      await _openArtistFromVideo(video);
      return;
    }
    if (action == _SearchVideoContextAction.openAlbum) {
      await _openAlbumFromVideo(video);
    }
  }

  // ignore: unused_element
  Future<void> _showVideoOptionsMenu(Video video) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(26),
              child: _AdaptiveBackdropFilter(
                filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                child: Container(
                  decoration: BoxDecoration(
                    color: CupertinoColors.systemGrey6
                        .resolveFrom(sheetContext)
                        .withValues(alpha: 0.82),
                    borderRadius: BorderRadius.circular(26),
                    border: Border.all(
                      color: CupertinoColors.white.withValues(alpha: 0.24),
                      width: 0.7,
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(height: 8),
                      Container(
                        width: 42,
                        height: 4,
                        decoration: BoxDecoration(
                          color: CupertinoColors.systemGrey3
                              .resolveFrom(sheetContext)
                              .withValues(alpha: 0.75),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                video.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: CupertinoTheme.of(sheetContext)
                                    .textTheme
                                    .navTitleTextStyle
                                    .copyWith(fontWeight: FontWeight.w700),
                              ),
                            ),
                            const SizedBox(width: 8),
                            CupertinoButton(
                              padding: EdgeInsets.zero,
                              minimumSize: const Size(34, 34),
                              onPressed: () => Navigator.of(sheetContext).pop(),
                              child: Icon(
                                CupertinoIcons.xmark_circle_fill,
                                size: 24,
                                color: CupertinoColors.secondaryLabel
                                    .resolveFrom(sheetContext),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(10, 0, 10, 14),
                        child: Column(
                          children: [
                            _GlassSheetActionRow(
                              icon: CupertinoIcons.star_fill,
                              label: 'Añadir a Favoritos',
                              onTap: () =>
                                  Navigator.of(sheetContext).pop('favorites'),
                            ),
                            const SizedBox(height: 8),
                            _GlassSheetActionRow(
                              icon: CupertinoIcons.music_note_list,
                              label: 'Añadir a playlist',
                              onTap: () =>
                                  Navigator.of(sheetContext).pop('playlist'),
                            ),
                            const SizedBox(height: 8),
                            _GlassSheetActionRow(
                              icon: CupertinoIcons.text_insert,
                              label: 'Añadir como siguiente',
                              onTap: () =>
                                  Navigator.of(sheetContext).pop('queue_next'),
                            ),
                            const SizedBox(height: 8),
                            _GlassSheetActionRow(
                              icon: CupertinoIcons.text_append,
                              label: 'Añadir al final',
                              onTap: () =>
                                  Navigator.of(sheetContext).pop('queue_end'),
                            ),
                            const SizedBox(height: 8),
                            _GlassSheetActionRow(
                              icon: CupertinoIcons.square_arrow_up,
                              label: 'Compartir',
                              onTap: () =>
                                  Navigator.of(sheetContext).pop('share'),
                            ),
                            const SizedBox(height: 8),
                            _GlassSheetActionRow(
                              icon: CupertinoIcons.person_crop_circle,
                              label: 'Ir al artista',
                              onTap: () =>
                                  Navigator.of(sheetContext).pop('artist'),
                            ),
                            const SizedBox(height: 8),
                            _GlassSheetActionRow(
                              icon: CupertinoIcons.rectangle_stack_fill,
                              label: 'Ir al álbum',
                              onTap: () =>
                                  Navigator.of(sheetContext).pop('album'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );

    if (!mounted || action == null) return;
    if (action == 'favorites') {
      await _addVideoToPlaylist(video, PlaylistService.favoritesPlaylistName);
      return;
    }
    if (action == 'playlist') {
      await _showPlaylistPicker(video);
      return;
    }
    if (action == 'queue_next') {
      _queueVideo(video, insertMode: ManualQueueInsertMode.next);
      return;
    }
    if (action == 'queue_end') {
      _queueVideo(video, insertMode: ManualQueueInsertMode.end);
      return;
    }
    if (action == 'share') {
      await _shareVideoDeepLink(
        video,
        shareOrigin: _shareOriginFromContext(context),
      );
      return;
    }
    if (action == 'artist') {
      await _openArtistFromVideo(video);
      return;
    }
    if (action == 'album') {
      await _openAlbumFromVideo(video);
    }
  }

  Future<void> _showPlaylistPicker(Video video) async {
    final playlistService = context.read<PlaylistService>();
    final playlists = await playlistService.getPlaylists();
    if (!mounted || playlists.isEmpty) return;

    final selectedName = await showGlassPlaylistPickerSheet(
      context: context,
      playlists: playlists,
      subtitle: video.title,
    );
    if (!mounted || selectedName == null || selectedName.isEmpty) return;
    await _addVideoToPlaylist(video, selectedName);
  }

  Future<void> _addVideoToPlaylist(Video video, String playlistName) async {
    final playlistService = context.read<PlaylistService>();
    final downloadService = context.read<DownloadService>();
    final videoManager = context.read<VideoPlayerManager>();
    final track = VideoHistory(
      videoId: video.id.value,
      title: video.title,
      thumbnailUrl: _bestQualityThumbnail(video),
      channelTitle: cleanArtistName(video.author),
      watchedAt: DateTime.now(),
    );
    await playlistService.addVideoToPlaylist(playlistName, track);
    await downloadService.autoDownloadIfEnabledUsingClone(
      playlistName,
      track,
      videoManager: videoManager,
    );
    if (!mounted) return;
    final label = PlaylistService.isFavoritesPlaylistName(playlistName)
        ? 'Añadida a Favoritos'
        : 'Añadida a $playlistName';
    _showIosTopToast(
      context,
      message: label,
      icon: PlaylistService.isFavoritesPlaylistName(playlistName)
          ? CupertinoIcons.star_fill
          : CupertinoIcons.check_mark_circled_solid,
    );
  }

  Future<List<Video>> _searchWithCache(
    String query, {
    required _SearchFilterMode mode,
  }) async {
    final cacheKey = '${mode.name}|$query';
    final cached = _searchCache[cacheKey];
    if (cached != null) return cached;
    final inFlight = _searchInFlight[cacheKey];
    if (inFlight != null) return inFlight;

    late final Future<List<Video>> future;
    switch (mode) {
      case _SearchFilterMode.music:
        future = _runYoutubeWithRetry(() => _searchYoutubeMusicSongs(query));
      case _SearchFilterMode.podcast:
        future = _runYoutubeWithRetry(
          () => _searchPodcastMarkedVideos(query),
          maxAttempts: 1,
        );
      case _SearchFilterMode.videos:
        future = _runYoutubeWithRetry(
          () => _searchUnfilteredVideos(query),
          maxAttempts: 1,
        );
    }
    _searchInFlight[cacheKey] = future;
    try {
      final result = await future;
      _searchCache[cacheKey] = result;
      return result;
    } finally {
      _searchInFlight.remove(cacheKey);
    }
  }

  Future<List<Video>> _searchYoutubeMusicSongs(String query) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) return const <Video>[];

    for (final params in _youtubeMusicSongsFilterParamsCandidates) {
      final payload = await _runYoutubeWithRetry(
        () => _fetchYoutubeMusicSearchPayloadForAlbums(
          normalizedQuery,
          paramsOverride: params,
        ),
        maxAttempts: 1,
      );
      if (payload == null) continue;
      final extracted = _extractSongVideosFromYoutubeMusicPayload(payload);
      if (extracted.isNotEmpty) return extracted;
    }

    // Fallback suave para no dejar vacía la búsqueda si YouTube cambia el payload.
    return _searchAutoGeneratedTopicVideos(normalizedQuery);
  }

  List<Video> _extractSongVideosFromYoutubeMusicPayload(
    Map<String, dynamic> payload,
  ) {
    final out = <Video>[];
    final seen = <String>{};

    void collect(dynamic node, {int depth = 0, String? currentShelfTitle}) {
      if (depth > 20 || node == null) return;
      if (node is Map) {
        final shelf = node['musicShelfRenderer'];
        if (shelf is Map) {
          final shelfTitle = _normalizeAlbumSearchText(
            _extractYouTubeText(shelf['title']),
          );
          collect(shelf['contents'], depth: depth + 1, currentShelfTitle: shelfTitle);
        }

        final responsive = node['musicResponsiveListItemRenderer'];
        if (responsive is Map) {
          final video = _videoFromYoutubeMusicRenderer(
            Map<String, dynamic>.from(responsive.cast<dynamic, dynamic>()),
            currentShelfTitle: currentShelfTitle ?? '',
          );
          if (video != null && seen.add(video.id.value)) out.add(video);
        }

        for (final value in node.values) {
          collect(value, depth: depth + 1, currentShelfTitle: currentShelfTitle);
        }
        return;
      }
      if (node is List) {
        for (final value in node) {
          collect(value, depth: depth + 1, currentShelfTitle: currentShelfTitle);
        }
      }
    }

    collect(payload);
    return out;
  }

  Video? _videoFromYoutubeMusicRenderer(
    Map<String, dynamic> renderer, {
    required String currentShelfTitle,
  }) {
    String? readVideoId(dynamic node, {int depth = 0}) {
      if (depth > 12 || node == null) return null;
      if (node is Map) {
        final direct = (node['videoId'] ?? '').toString().trim();
        if (direct.isNotEmpty && VideoId.validateVideoId(direct)) return direct;
        for (final value in node.values) {
          final nested = readVideoId(value, depth: depth + 1);
          if (nested != null) return nested;
        }
        return null;
      }
      if (node is List) {
        for (final value in node) {
          final nested = readVideoId(value, depth: depth + 1);
          if (nested != null) return nested;
        }
      }
      return null;
    }

    final videoId = readVideoId(renderer);
    if (videoId == null || videoId.isEmpty) return null;

    final title = _extractFlexColumnText(renderer, 0).trim();
    final author = _extractAlbumArtistFromRendererNode(renderer).trim();
    if (title.isEmpty) return null;

    final shelfText = _normalizeAlbumSearchText(currentShelfTitle);
    final pageType = _extractPageTypeFromNode(renderer);
    final looksLikeSongShelf =
        shelfText.contains('cancion') || shelfText.contains('song');
    final looksLikeTrackPage =
        pageType.contains('TRACK') || pageType.contains('SONG');
    if (!looksLikeSongShelf && !looksLikeTrackPage) return null;

    return Video(
      VideoId(videoId),
      title,
      author.isEmpty ? 'Artista' : author,
      ChannelId('UC_x5XG1OV2P6uZZ5FSM9Ttw'),
      null,
      null,
      null,
      '',
      null,
      ThumbnailSet(videoId),
      const <String>[],
      const Engagement(0, null, null),
      false,
    );
  }

  Future<List<Video>> _searchUnfilteredVideos(String query) async {
    final raw = await _youtubeExplode.search.search(query);
    final seenIds = <String>{};
    final videos = <Video>[];
    for (final video in raw.take(80)) {
      final id = video.id.value.trim();
      if (id.isEmpty || !seenIds.add(id)) continue;
      videos.add(video);
    }
    return videos;
  }

  Future<List<Video>> _searchPodcastMarkedVideos(String query) async {
    final rawVideos = await _searchUnfilteredVideos(query);
    return rawVideos.where(_isPodcastMarkedVideo).toList(growable: false);
  }

  Future<List<_SearchAlbumResult>> _searchAlbumsWithCache(String query) async {
    final cached = _albumSearchCache[query];
    if (cached != null && cached.isNotEmpty) return cached;
    final inFlight = _albumSearchInFlight[query];
    if (inFlight != null) return inFlight;

    final future = _searchAlbumsFromYoutubeMusic(query);
    _albumSearchInFlight[query] = future;
    try {
      final result = await future;
      if (result.isNotEmpty) {
        _albumSearchCache[query] = result;
      } else {
        _albumSearchCache.remove(query);
      }
      return result;
    } finally {
      _albumSearchInFlight.remove(query);
    }
  }

  Future<List<_SearchAlbumResult>> _searchAlbumsFromYoutubeMusic(
    String query,
  ) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) return const <_SearchAlbumResult>[];

    final initialData = await _fetchYoutubeMusicSearchInitialDataForAlbums(
      normalizedQuery,
    );
    if (initialData != null) {
      final ordered = _extractAlbumsInYoutubeMusicOrder(initialData);
      if (ordered.isNotEmpty) return ordered;
    }

    final defaultPayload = await _runYoutubeWithRetry(
      () => _fetchYoutubeMusicSearchPayloadForAlbums(normalizedQuery),
      maxAttempts: 1,
    );
    if (defaultPayload != null) {
      final ordered = _extractAlbumsInYoutubeMusicOrder(defaultPayload);
      if (ordered.isNotEmpty) return ordered;
    }

    final albumsOnlyPayload = await _runYoutubeWithRetry(
      () => _fetchYoutubeMusicSearchPayloadForAlbums(
        normalizedQuery,
        albumsOnly: true,
      ),
      maxAttempts: 1,
    );
    if (albumsOnlyPayload == null) return const <_SearchAlbumResult>[];
    return _extractAlbumsInYoutubeMusicOrder(albumsOnlyPayload);
  }

  Future<List<Video>> _searchAutoGeneratedTopicVideos(String query) async {
    final queries = _buildAudioFocusedQueries(query);
    final videosById = <String, Video>{};
    final scoresById = <String, int>{};
    final phase1Count = queries.length >= 2 ? 2 : queries.length;
    final phase1 = List.generate(
      phase1Count,
      (index) => _collectSearchBatch(
        searchQuery: queries[index],
        queryIndex: index,
        originalQuery: query,
        videosById: videosById,
        scoresById: scoresById,
      ),
    );
    await Future.wait(phase1);

    // Si ya hay suficientes candidatos, devolvemos rápido.
    if (scoresById.length < 18 && queries.length > phase1Count) {
      final phase2 = List.generate(queries.length - phase1Count, (offset) {
        final index = phase1Count + offset;
        return _collectSearchBatch(
          searchQuery: queries[index],
          queryIndex: index,
          originalQuery: query,
          videosById: videosById,
          scoresById: scoresById,
        );
      });
      await Future.wait(phase2);
    }

    final ids = scoresById.keys.toList()
      ..sort((a, b) {
        final viewsA = videosById[a]?.engagement.viewCount ?? 0;
        final viewsB = videosById[b]?.engagement.viewCount ?? 0;
        if (viewsA != viewsB) return viewsB.compareTo(viewsA);
        return (scoresById[b] ?? 0).compareTo(scoresById[a] ?? 0);
      });
    return ids.map((id) => videosById[id]!).toList();
  }

  Future<void> _collectSearchBatch({
    required String searchQuery,
    required int queryIndex,
    required String originalQuery,
    required Map<String, Video> videosById,
    required Map<String, int> scoresById,
  }) async {
    try {
      final raw = await _runYoutubeWithRetry(
        () => _youtubeExplode.search.search(searchQuery),
        maxAttempts: 1,
      );
      for (final video in raw.take(40)) {
        if (!_isPureYoutubeMusicAudioSearchResult(video)) continue;
        final id = video.id.value;
        final score = _searchRelevanceScore(
          video: video,
          originalQuery: originalQuery,
          queryIndex: queryIndex,
        );
        final previous = scoresById[id];
        if (previous == null || score > previous) {
          scoresById[id] = score;
          videosById[id] = video;
        }
      }
    } catch (_) {
      // Ignoramos esta subconsulta y seguimos.
    }
  }

  List<String> _buildAudioFocusedQueries(String query) {
    final normalized = query.replaceAll(RegExp(r'\s+'), ' ').trim();
    final compact = normalized
        .replaceAll(RegExp(r'\s*[\(\[\{].*?[\)\]\}]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final set = <String>{
      normalized,
      '$compact topic',
      '$compact official audio',
      '$compact provided to youtube by',
      '$compact auto-generated by youtube',
    };

    // Si es "artista - cancion", reforzamos por artista.
    final dashParts = compact.split(RegExp(r'\s*-\s*'));
    if (dashParts.length >= 2) {
      final artist = dashParts.first.trim();
      if (artist.isNotEmpty) {
        set.add('$artist topic');
        set.add('$artist provided to youtube by');
      }
    }

    return set.where((q) => q.isNotEmpty).take(8).toList();
  }

  int _searchRelevanceScore({
    required Video video,
    required String originalQuery,
    required int queryIndex,
  }) {
    final title = video.title.toLowerCase();
    final author = video.author.toLowerCase();
    final description = video.description.toLowerCase();
    final text = '$title $author $description';
    final normalizedQuery = originalQuery.toLowerCase().trim();
    final tokens = normalizedQuery
        .split(RegExp(r'\s+'))
        .where((token) => token.length >= 3)
        .take(8)
        .toList();

    var score = 0;
    if (_isTopicVideo(video)) score += 120;
    if (_isAutoGeneratedVideo(video)) score += 100;
    if (text.contains(normalizedQuery)) score += 120;
    for (final token in tokens) {
      if (text.contains(token)) score += 22;
    }
    if (queryIndex == 0) score += 35;
    score -= queryIndex * 6;
    final views = video.engagement.viewCount;
    if (views > 0) {
      score += (views / 300000).floor().clamp(0, 50);
    }
    return score;
  }

  Future<SearchChannelWithSubscribers?>
  _searchPrimaryArtistFromYoutubeMusicFilter(String query) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) return null;

    for (final params in _youtubeMusicArtistsFilterParamsCandidates) {
      final payload = await _runYoutubeWithRetry(
        () => _fetchYoutubeMusicSearchPayloadForAlbums(
          normalizedQuery,
          paramsOverride: params,
        ),
        maxAttempts: 1,
      );
      if (payload == null) continue;
      final artist = _extractFirstArtistFromYoutubeMusicPayload(payload);
      if (artist != null) return artist;
    }
    return null;
  }

  SearchChannelWithSubscribers? _extractFirstArtistFromYoutubeMusicPayload(
    Map<String, dynamic> payload,
  ) {
    SearchChannelWithSubscribers? found;

    String? readBrowseId(dynamic node, {int depth = 0}) {
      if (depth > 12 || node == null) return null;
      if (node is Map) {
        final direct = (node['browseId'] ?? '').toString().trim();
        if (direct.isNotEmpty) return direct;
        final endpoint = node['browseEndpoint'];
        if (endpoint is Map) {
          final value = (endpoint['browseId'] ?? '').toString().trim();
          if (value.isNotEmpty) return value;
        }
        for (final value in node.values) {
          final nested = readBrowseId(value, depth: depth + 1);
          if (nested != null && nested.isNotEmpty) return nested;
        }
        return null;
      }
      if (node is List) {
        for (final value in node) {
          final nested = readBrowseId(value, depth: depth + 1);
          if (nested != null && nested.isNotEmpty) return nested;
        }
      }
      return null;
    }

    void scan(dynamic node, {int depth = 0, String? currentShelfTitle}) {
      if (found != null || depth > 20 || node == null) return;
      if (node is Map) {
        final shelf = node['musicShelfRenderer'];
        if (shelf is Map) {
          final shelfTitle = _normalizeAlbumSearchText(
            _extractYouTubeText(shelf['title']),
          );
          scan(shelf['contents'], depth: depth + 1, currentShelfTitle: shelfTitle);
        }

        final responsive = node['musicResponsiveListItemRenderer'];
        if (responsive is Map) {
          final normalizedRenderer = Map<String, dynamic>.from(
            responsive.cast<dynamic, dynamic>(),
          );
          final pageType = _extractPageTypeFromNode(normalizedRenderer);
          final shelfTitle = _normalizeAlbumSearchText(currentShelfTitle ?? '');
          final looksLikeArtistShelf =
              shelfTitle.contains('artista') || shelfTitle.contains('artist');
          if (pageType.contains('ARTIST') || looksLikeArtistShelf) {
            final name = _extractFlexColumnText(normalizedRenderer, 0).trim();
            final browseId = readBrowseId(normalizedRenderer)?.trim() ?? '';
            if (name.isNotEmpty && browseId.isNotEmpty) {
              final thumb = _extractThumbnailFromNode(normalizedRenderer);
              final uri = Uri.tryParse(thumb ?? '');
              final channel = SearchChannel(
                ChannelId(browseId),
                name,
                '',
                0,
                uri != null ? [Thumbnail(uri, 0, 0)] : const <Thumbnail>[],
              );
              found = SearchChannelWithSubscribers(
                channel: channel,
                subscribersCount: null,
                thumbnailUrlOverride: thumb?.trim().isNotEmpty == true
                    ? thumb!.trim()
                    : null,
              );
              return;
            }
          }
        }

        for (final value in node.values) {
          scan(value, depth: depth + 1, currentShelfTitle: currentShelfTitle);
          if (found != null) return;
        }
        return;
      }
      if (node is List) {
        for (final value in node) {
          scan(value, depth: depth + 1, currentShelfTitle: currentShelfTitle);
          if (found != null) return;
        }
      }
    }

    scan(payload);
    return found;
  }

  Future<List<SearchChannelWithSubscribers>> _searchChannelsWithCache(
    String query,
  ) async {
    final cached = await _getCachedChannels(query);
    if (cached != null) return cached;
    final inFlight = _channelSearchInFlight[query];
    if (inFlight != null) {
      final result = await inFlight;
      return _normalizeChannelResults(result);
    }

    final future = _runYoutubeWithRetry<Object>(() async {
      final primaryFromYoutubeMusicArtists =
          await _searchPrimaryArtistFromYoutubeMusicFilter(query);
      if (primaryFromYoutubeMusicArtists == null) {
        return const <SearchChannelWithSubscribers>[];
      }
      return <SearchChannelWithSubscribers>[primaryFromYoutubeMusicArtists];
    });
    _channelSearchInFlight[query] = future;
    try {
      final result = await future;
      final normalized = await _normalizeChannelResults(result);
      _channelSearchCache[query] = normalized;
      return normalized;
    } finally {
      _channelSearchInFlight.remove(query);
    }
  }

  Future<List<SearchChannelWithSubscribers>?> _getCachedChannels(
    String query,
  ) async {
    final cached = _channelSearchCache[query];
    if (cached == null) return null;
    final normalized = await _normalizeChannelResults(cached);
    _channelSearchCache[query] = normalized;
    return normalized;
  }

  Future<List<SearchChannelWithSubscribers>> _normalizeChannelResults(
    Object rawResult,
  ) async {
    if (rawResult is List<SearchChannelWithSubscribers>) {
      return rawResult.take(_maxChannelsToShow).toList(growable: false);
    }
    if (rawResult is List<SearchChannel>) {
      final resolved = await _resolveChannelsWithSubscribers(rawResult);
      return _hydrateTopicChannelPhotos(
        _filterChannelsBySubscribers(resolved),
        resolved,
        forcedTopicThumbnail: _topThumbnailFromResolved(resolved),
      );
    }
    return const [];
  }

  List<SearchChannelWithSubscribers> _prependPrimaryArtistChannel({
    required SearchChannelWithSubscribers? primary,
    required List<SearchChannelWithSubscribers> others,
  }) {
    if (others.isEmpty && primary == null) return const [];
    final ordered = <SearchChannelWithSubscribers>[];
    final seen = <String>{};

    void add(SearchChannelWithSubscribers item) {
      final id = item.channel.id.value.trim();
      if (id.isEmpty || !seen.add(id)) return;
      ordered.add(item);
    }

    if (primary != null) add(primary);
    for (final item in others) {
      add(item);
      if (ordered.length >= _maxChannelsToShow) break;
    }
    return ordered.take(_maxChannelsToShow).toList(growable: false);
  }

  Future<List<SearchChannelWithSubscribers>> _resolveChannelsWithSubscribers(
    List<SearchChannel> channels,
  ) async {
    final toResolve = channels.take(_maxChannelsToShow).toList();
    return Future.wait(toResolve.map(_resolveChannelSubscribers));
  }

  Future<List<SearchChannelWithSubscribers>> _resolveChannelsFromTopVideos(
    List<Video> videos,
  ) async {
    final resolved = <SearchChannelWithSubscribers>[];
    final seenIds = <String>{};
    final sourceVideos = videos.take(4).toList();

    for (var i = 0; i < sourceVideos.length; i++) {
      final video = sourceVideos[i];
      try {
        final details = await _runYoutubeWithRetry(
          () => _youtubeExplode.channels.getByVideo(video.id.value),
          maxAttempts: 1,
        );
        final channelId = details.id.value;
        if (seenIds.contains(channelId)) continue;
        seenIds.add(channelId);
        _subscriberCountCache[channelId] = details.subscribersCount;
        resolved.add(
          SearchChannelWithSubscribers(
            channel: SearchChannel(details.id, details.title, '', 0, [
              Thumbnail(Uri.parse(details.logoUrl), 0, 0),
            ]),
            subscribersCount: details.subscribersCount,
          ),
        );
      } catch (e, s) {
        developer.log(
          'No se pudo resolver canal desde video ${video.title}',
          error: e,
          stackTrace: s,
        );
      }
    }

    return resolved;
  }

  List<SearchChannelWithSubscribers> _mergeChannelCandidates(
    List<SearchChannelWithSubscribers> a,
    List<SearchChannelWithSubscribers> b,
  ) {
    final merged = <String, SearchChannelWithSubscribers>{};
    for (final item in [...a, ...b]) {
      final id = item.channel.id.value;
      final existing = merged[id];
      if (existing == null) {
        merged[id] = item;
      } else if ((item.subscribersCount ?? 0) >
          (existing.subscribersCount ?? 0)) {
        merged[id] = item;
      }
    }
    return merged.values.toList();
  }

  List<SearchChannelWithSubscribers> _filterChannelsBySubscribers(
    List<SearchChannelWithSubscribers> channels,
  ) {
    if (channels.isEmpty) return const [];
    final verified = channels
        .where((item) => (item.subscribersCount ?? 0) > _minimumSubscribers)
        .toList();

    if (verified.isNotEmpty) {
      return _prioritizeTopicFirst(verified).take(_maxChannelsToShow).toList();
    }

    final knownSubscribers = channels
        .where((item) => item.subscribersCount != null)
        .toList();
    if (knownSubscribers.isNotEmpty) {
      return _prioritizeTopicFirst(
        knownSubscribers,
      ).take(_maxChannelsToShow).toList();
    }

    // Fallback final: si YouTube no devuelve conteo de suscriptores.
    final fallback = channels
        .where((item) => item.subscribersCount == null)
        .toList();
    return _prioritizeTopicFirst(fallback).take(_maxChannelsToShow).toList();
  }

  List<SearchChannelWithSubscribers> _prioritizeTopicFirst(
    List<SearchChannelWithSubscribers> channels,
  ) {
    final prioritized = channels.toList();
    prioritized.sort((a, b) {
      final aTopic = _isTopicChannel(a.channel);
      final bTopic = _isTopicChannel(b.channel);
      if (aTopic == bTopic) return 0;
      return aTopic ? -1 : 1;
    });
    return prioritized;
  }

  bool _isTopicChannel(SearchChannel channel) {
    final name = channel.name.toLowerCase().trim();
    return RegExp(r'(\s*[-–—]\s*topic|\s+topic)\s*$').hasMatch(name);
  }

  Future<List<SearchChannelWithSubscribers>> _hydrateTopicChannelPhotos(
    List<SearchChannelWithSubscribers> selected,
    List<SearchChannelWithSubscribers> pool, {
    String? forcedTopicThumbnail,
  }) async {
    if (selected.isEmpty) return selected;
    final globalFallback =
        forcedTopicThumbnail ?? _bestArtistThumbnailFromPool(pool);
    final hydrated = <SearchChannelWithSubscribers>[];

    for (final item in selected) {
      if (!_isTopicChannel(item.channel)) {
        hydrated.add(item);
        continue;
      }

      final chosen = globalFallback ?? _thumbnailOf(item);
      hydrated.add(item.copyWith(thumbnailUrlOverride: chosen));
    }

    return hydrated;
  }

  String? _topThumbnailFromResolved(
    List<SearchChannelWithSubscribers> channels,
  ) {
    if (channels.isEmpty) return null;
    final sorted = channels.toList()
      ..sort(
        (a, b) => (b.subscribersCount ?? 0).compareTo(a.subscribersCount ?? 0),
      );
    for (final item in sorted) {
      final thumb = _thumbnailOf(item);
      if (thumb != null && thumb.isNotEmpty) return thumb;
    }
    return null;
  }

  String? _bestArtistThumbnailFromPool(
    List<SearchChannelWithSubscribers> pool,
  ) {
    final candidates =
        pool.where((item) => !_isTopicChannel(item.channel)).toList()..sort(
          (a, b) =>
              (b.subscribersCount ?? 0).compareTo(a.subscribersCount ?? 0),
        );
    for (final item in candidates) {
      final thumb = _thumbnailOf(item);
      if (thumb != null && thumb.isNotEmpty) return thumb;
    }
    return null;
  }

  String? _thumbnailOf(SearchChannelWithSubscribers item) {
    if (item.thumbnailUrlOverride != null &&
        item.thumbnailUrlOverride!.isNotEmpty) {
      return item.thumbnailUrlOverride;
    }
    if (item.channel.thumbnails.isEmpty) return null;
    final url = item.channel.thumbnails.first.url.toString();
    if (url.isEmpty) return null;
    return url;
  }

  Future<SearchChannelWithSubscribers> _resolveChannelSubscribers(
    SearchChannel channel,
  ) async {
    final channelId = channel.id.value;
    final cachedSubscribers = _subscriberCountCache[channelId];
    final cachedLogo = _channelLogoCache[channelId];
    if (_subscriberCountCache.containsKey(channelId) ||
        _channelLogoCache.containsKey(channelId)) {
      return SearchChannelWithSubscribers(
        channel: channel,
        subscribersCount: cachedSubscribers,
        thumbnailUrlOverride: cachedLogo,
      );
    }

    int? subscribersCount;
    String? logoUrl;
    try {
      final details = await _runYoutubeWithRetry(
        () => _youtubeExplode.channels.get(channelId),
        maxAttempts: 1,
      );
      subscribersCount = details.subscribersCount;
      logoUrl = details.logoUrl;
    } catch (e, s) {
      developer.log(
        'No se pudieron cargar los suscriptores del canal ${channel.name}',
        error: e,
        stackTrace: s,
      );
    }

    _subscriberCountCache[channelId] = subscribersCount;
    _channelLogoCache[channelId] = logoUrl;
    return SearchChannelWithSubscribers(
      channel: channel,
      subscribersCount: subscribersCount,
      thumbnailUrlOverride: logoUrl,
    );
  }

  String _formatSubscribers(int? subscribersCount) {
    if (subscribersCount == null) return 'Suscriptores no disponibles';
    if (subscribersCount >= 1000000) {
      final value = subscribersCount / 1000000;
      return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} M suscriptores';
    }
    if (subscribersCount >= 1000) {
      final value = subscribersCount / 1000;
      return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} k suscriptores';
    }
    return '$subscribersCount suscriptores';
  }

  Future<T> _runYoutubeWithRetry<T>(
    Future<T> Function() action, {
    int maxAttempts = 3,
  }) async {
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await action();
      } on RequestLimitExceededException {
        rethrow;
      } on SocketException catch (e) {
        lastError = e;
      } on HttpException catch (e) {
        lastError = e;
      } catch (e) {
        lastError = e;
      }

      if (attempt < maxAttempts) {
        final waitSeconds = attempt * 2;
        await Future<void>.delayed(Duration(seconds: waitSeconds));
      }
    }
    throw lastError ?? Exception('Error de red al consultar YouTube');
  }

  @override
  Widget build(BuildContext context) {
    final hasMiniPlayer = context.select<VideoPlayerManager, bool>(
      (playerManager) =>
          playerManager.currentVideoId != null && playerManager.isMinimized,
    );
    final selectedArtist = _selectedArtistView;
    final selectedAlbum = _selectedAlbumView;
    if (context.read<SearchViewState>().isArtistFullscreen &&
        selectedArtist == null &&
        selectedAlbum == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        context.read<SearchViewState>().setArtistFullscreen(false);
      });
    }

    return PopScope(
      canPop: selectedArtist == null && selectedAlbum == null,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && selectedAlbum != null) {
          _closeAlbumView();
          return;
        }
        if (!didPop && selectedArtist != null) {
          _closeArtistChannel();
        }
      },
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 520),
        reverseDuration: const Duration(milliseconds: 420),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        layoutBuilder: (currentChild, previousChildren) {
          return Stack(
            fit: StackFit.expand,
            children: [
              ...previousChildren,
              if (currentChild != null) currentChild,
            ],
          );
        },
        transitionBuilder: (child, animation) {
          final beginX = _artistTransitionDirection > 0 ? 0.22 : -0.18;
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          final slide = Tween<Offset>(
            begin: Offset(beginX, 0),
            end: Offset.zero,
          ).animate(curved);
          final scale = Tween<double>(begin: 0.94, end: 1.0).animate(curved);
          return FadeTransition(
            opacity: curved,
            child: ClipRect(
              child: SlideTransition(
                position: slide,
                child: ScaleTransition(scale: scale, child: child),
              ),
            ),
          );
        },
        child: selectedAlbum != null
            ? KeyedSubtree(
                key: ValueKey('album_${selectedAlbum.playlistId}'),
                child: _IosEdgeSwipeBack(
                  enabled: true,
                  onBack: _closeAlbumView,
                  child: AlbumTracksPage(
                    playlistId: selectedAlbum.playlistId,
                    albumTitle: selectedAlbum.albumTitle,
                    artistName: selectedAlbum.artistName,
                    seedThumbnailUrl: selectedAlbum.seedThumbnailUrl,
                    libraryAlbumsService: Provider.of<LibraryAlbumsService?>(
                      context,
                      listen: false,
                    ),
                    embedded: true,
                    onBack: _closeAlbumView,
                  ),
                ),
              )
            : selectedArtist == null
            ? KeyedSubtree(
                key: const ValueKey('search_home'),
                child: _buildSearchHomeScaffold(hasMiniPlayer: hasMiniPlayer),
              )
            : KeyedSubtree(
                key: ValueKey('artist_${selectedArtist.channelId}'),
                child: ChannelVideosPage(
                  channelId: selectedArtist.channelId,
                  channelName: selectedArtist.channelName,
                  channelThumbnailUrl: selectedArtist.channelThumbnailUrl,
                  embedded: true,
                  onBack: _closeArtistChannel,
                ),
              ),
      ),
    );
  }

  @override
  void dispose() {
    _autocompleteDebounce?.cancel();
    _textController.removeListener(_onSearchTextChanged);
    _searchViewState?.removeListener(_handleSearchViewStateChanged);
    _searchFocusNode.dispose();
    _searchBarGlowController?.dispose();
    _youtubeExplode.close();
    _textController.dispose();
    super.dispose();
  }

  Widget _buildSearchFilters() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          SearchModeButton(
            label: 'Canciones',
            icon: CupertinoIcons.music_note_2,
            isActive: _isMusicFilterMode,
            onPressed: _activateMusicFilters,
          ),
          const SizedBox(width: 10),
          SearchModeButton(
            label: 'Artistas',
            icon: CupertinoIcons.person_2,
            isActive: _isMusicFilterMode && _showArtists,
            onPressed: () {
              if (!_isMusicFilterMode) return;
              setState(() {
                _showArtists = !_showArtists;
              });
            },
          ),
          const SizedBox(width: 10),
          SearchModeButton(
            label: 'Álbumes',
            icon: CupertinoIcons.music_albums,
            isActive: _isMusicFilterMode && _showAlbums,
            onPressed: () {
              if (!_isMusicFilterMode) return;
              setState(() {
                _showAlbums = !_showAlbums;
              });
            },
          ),
          const SizedBox(width: 10),
          SearchModeButton(
            label: 'Podcast',
            icon: CupertinoIcons.mic_fill,
            isActive: _isPodcastFilterMode,
            onPressed: _togglePodcastFilter,
          ),
          const SizedBox(width: 10),
          SearchModeButton(
            label: 'Videos',
            icon: CupertinoIcons.play_rectangle_fill,
            isActive: _isVideosFilterMode,
            onPressed: _toggleVideosFilter,
          ),
        ],
      ),
    );
  }

  Widget _buildSearchHomeScaffold({required bool hasMiniPlayer}) {
    final mediaQuery = MediaQuery.of(context);
    final keyboardInset = mediaQuery.viewInsets.bottom;
    final safeBottomInset = mediaQuery.padding.bottom;
    const miniPlayerHeight = 58.0;
    const miniPlayerBottomNavReserve = 53.0;
    const tabBarTopReserve = 53.0;
    final bottomOverlayReserve =
        safeBottomInset +
        (hasMiniPlayer
            ? (miniPlayerBottomNavReserve + miniPlayerHeight)
            : tabBarTopReserve);
    final controlsBottomOffset = keyboardInset > 0
        ? math.max(keyboardInset, bottomOverlayReserve)
        : bottomOverlayReserve;
    const controlsBottomSpacing = 12.0;

    return MediaQuery(
      data: mediaQuery.removeViewInsets(removeBottom: true),
      child: Material(
        type: MaterialType.transparency,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: _buildBody(
                  additionalBottomPadding: -bottomOverlayReserve,
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: AnimatedPadding(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  padding: EdgeInsets.only(bottom: controlsBottomOffset),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildSearchFilters(),
                      const SizedBox(height: 10),
                      _buildSearchBar(),
                      const SizedBox(height: controlsBottomSpacing),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    final borderRadius = BorderRadius.circular(18);
    final focused = _searchFocusNode.hasFocus;
    final appInForeground = context.select<AppLifecycleService?, bool>(
      (s) => s?.isForeground ?? true,
    );
    final dataSaverMode = context.select<AppSettingsService?, bool>(
      (s) => s?.dataSaverMode ?? false,
    );
    final shouldUseLightweightUi =
        dataSaverMode ||
        !appInForeground ||
        defaultTargetPlatform == TargetPlatform.iOS;
    final glow = _ensureSearchBarGlowController();
    final shouldAnimateGlow = !shouldUseLightweightUi && focused;
    if (shouldAnimateGlow) {
      if (!glow.isAnimating) glow.repeat();
    } else if (glow.isAnimating) {
      glow.stop(canceled: false);
    }

    Widget buildSearchFieldShell(double rotation) {
      return Container(
        height: 42,
        padding: const EdgeInsets.all(1.25),
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          gradient: shouldUseLightweightUi
              ? const LinearGradient(
                  colors: [Color(0xFFFF4F7A), Color(0xFFFF8A00)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                )
              : SweepGradient(
                  transform: GradientRotation(rotation),
                  colors: const [
                    Color(0xFFFF004D),
                    Color(0xFFFF7A00),
                    Color(0xFF7A5CFF),
                    Color(0xFFFF004D),
                  ],
                ),
          boxShadow: [
            BoxShadow(
              color: const Color(
                0xFF581A95,
              ).withValues(alpha: focused ? 0.34 : 0.14),
              blurRadius: focused ? (shouldUseLightweightUi ? 14 : 20) : 10,
              spreadRadius: focused ? 0.9 : 0,
              offset: const Offset(0, 2),
            ),
            BoxShadow(
              color: const Color(
                0xFFFF2A6D,
              ).withValues(alpha: focused ? 0.24 : 0.08),
              blurRadius: focused ? (shouldUseLightweightUi ? 16 : 26) : 12,
              spreadRadius: focused ? 1.2 : 0,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: borderRadius,
          child: shouldUseLightweightUi
              ? _buildSearchFieldContent(borderRadius, focused)
              : _AdaptiveBackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                  child: _buildSearchFieldContent(borderRadius, focused),
                ),
        ),
      );
    }

    if (shouldUseLightweightUi) {
      return buildSearchFieldShell(0);
    }

    return AnimatedBuilder(
      animation: glow,
      builder: (context, _) => buildSearchFieldShell(glow.value * math.pi * 2),
    );
  }

  Widget _buildSearchFieldContent(BorderRadius borderRadius, bool focused) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0A0D14).withValues(alpha: 0.83),
        borderRadius: borderRadius,
      ),
      child: TextField(
        focusNode: _searchFocusNode,
        controller: _textController,
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => _searchVideos(),
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: Colors.white,
        ),
        decoration: InputDecoration(
          hintText: 'Buscar en VM Music...',
          hintStyle: TextStyle(
            color: Colors.white.withValues(alpha: 0.58),
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
          prefixIcon: Align(
            widthFactor: 1,
            heightFactor: 1,
            child: Icon(
              CupertinoIcons.search,
              size: 17,
              color: focused
                  ? const Color(0xFFFF7A9C)
                  : Colors.white.withValues(alpha: 0.75),
            ),
          ),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 36,
            minHeight: 42,
          ),
          suffixIcon: _textController.text.trim().isEmpty
              ? null
              : CupertinoButton(
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  onPressed: () {
                    unawaited(_clearSearchAndShowInitialRecommendations());
                  },
                  child: Icon(
                    CupertinoIcons.xmark_circle_fill,
                    size: 17,
                    color: Colors.white.withValues(alpha: 0.72),
                  ),
                ),
          suffixIconConstraints: const BoxConstraints(
            minWidth: 36,
            minHeight: 42,
          ),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            vertical: 12,
            horizontal: 4,
          ),
          border: InputBorder.none,
        ),
      ),
    );
  }

  Widget _buildBody({double additionalBottomPadding = 0}) {
    final hasMiniPlayer = context.select<VideoPlayerManager, bool>(
      (playerManager) =>
          playerManager.currentVideoId != null && playerManager.isMinimized,
    );
    final bottomReserve =
        _rootBottomOverlayReserve(context, hasMiniPlayer: hasMiniPlayer) +
        additionalBottomPadding;
    final query = _textController.text.trim();
    final showingAutocomplete =
        query.isNotEmpty &&
        (_searchFocusNode.hasFocus ||
            _autocompleteLoading ||
            _autocompleteSuggestions.isNotEmpty) &&
        (_autocompleteLoading || _autocompleteSuggestions.isNotEmpty);
    if (showingAutocomplete) {
      return _buildAutocompleteBody(query);
    }

    switch (_searchState) {
      case SearchState.loading:
        return const Center(child: CupertinoActivityIndicator(radius: 14));
      case SearchState.error:
        return const Center(
          child: Text('Error al buscar. Inténtalo de nuevo.'),
        );
      case SearchState.noResults:
        return const Center(child: Text('No se encontraron videos.'));
      case SearchState.initial:
        return _buildSearchTabHistoryBody(bottomReserve: bottomReserve);
      case SearchState.success:
        final prioritizedVideos = _isMusicFilterMode
            ? _prioritizedVideos(_videos)
            : List<Video>.from(_videos);
        final albumResults = _albums;
        final displayChannels = _orderedChannelsForDisplay(
          channels: _channels,
          videos: prioritizedVideos,
        );
        final primaryVideo = prioritizedVideos.isNotEmpty
            ? prioritizedVideos.first
            : null;
        final primaryArtistChannelThumb = primaryVideo == null
            ? null
            : _findChannelThumbnailForArtist(
                artistName: primaryVideo.author,
                channels: displayChannels,
              );
        return ListView(
          children: [
            if ((_isVideosFilterMode || _isPodcastFilterMode) &&
                displayChannels.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Canales principales',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              ...displayChannels
                  .take(2)
                  .map(
                    (channel) => ChannelCard(
                      channel: channel,
                      subscriberLabel: _formatSubscribers(
                        channel.subscribersCount,
                      ),
                      onTap: () => _openChannel(channel),
                    ),
                  ),
              const SizedBox(height: 14),
            ],
            if (_isMusicFilterMode &&
                _showArtists &&
                (primaryVideo != null || displayChannels.isNotEmpty)) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Artista principal',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (primaryVideo != null)
                _TopArtistFromVideoCard(
                  video: primaryVideo,
                  channelThumbnailUrl: primaryArtistChannelThumb,
                  onOpen: () => _openArtistFromVideo(primaryVideo),
                )
              else
                TopArtistCard(
                  channel: displayChannels.first,
                  subscriberLabel: _formatSubscribers(
                    displayChannels.first.subscribersCount,
                  ),
                  onOpenChannel: () => _openChannel(displayChannels.first),
                ),
              if (displayChannels.length > 1) ...[
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    'Canales relacionados',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                ...displayChannels
                    .skip(1)
                    .take(4)
                    .map(
                      (channel) => ChannelCard(
                        channel: channel,
                        subscriberLabel: _formatSubscribers(
                          channel.subscribersCount,
                        ),
                        onTap: () => _openChannel(channel),
                      ),
                    ),
              ],
              const SizedBox(height: 14),
            ],
            if (_isMusicFilterMode &&
                _showAlbums &&
                albumResults.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Álbumes',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              ...albumResults
                  .take(5)
                  .map(
                    (album) => _SearchAlbumCard(
                      album: album,
                      onTap: () => _openAlbumFromSearchResult(album),
                    ),
                  ),
              const SizedBox(height: 14),
            ],
            if (prioritizedVideos.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _isPodcastFilterMode
                      ? 'Podcast'
                      : (_isVideosFilterMode ? 'Videos' : 'Canciones'),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
            ...prioritizedVideos
                .take(20)
                .map(
                  (video) => (_isVideosFilterMode || _isPodcastFilterMode)
                      ? _YouTubeStyleVideoCard(
                          video: video,
                          onPlay: () => _playVideoPreferLocal(video),
                          onQueueNext: () => _queueVideo(
                            video,
                            insertMode: ManualQueueInsertMode.next,
                          ),
                          onQueueEnd: () => _queueVideo(
                            video,
                            insertMode: ManualQueueInsertMode.end,
                          ),
                          onContextAction: (action) =>
                              _runVideoContextAction(video, action),
                        )
                      : _VideoCard(
                          video: video,
                          onPlay: () => _playVideoPreferLocal(video),
                          onQueueNext: () => _queueVideo(
                            video,
                            insertMode: ManualQueueInsertMode.next,
                          ),
                          onQueueEnd: () => _queueVideo(
                            video,
                            insertMode: ManualQueueInsertMode.end,
                          ),
                          onContextAction: (action) =>
                              _runVideoContextAction(video, action),
                        ),
                ),
            SizedBox(height: bottomReserve),
          ],
        );
    }
  }

  Widget _buildAutocompleteBody(String query) {
    final baseTextStyle = CupertinoTheme.of(context).textTheme.textStyle;
    final hasMiniPlayer = context.select<VideoPlayerManager, bool>(
      (playerManager) =>
          playerManager.currentVideoId != null && playerManager.isMinimized,
    );
    final bottomReserve = _rootBottomOverlayReserve(
      context,
      hasMiniPlayer: hasMiniPlayer,
    );
    return ListView(
      children: [
        if (_autocompleteLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 18),
            child: Center(child: CupertinoActivityIndicator(radius: 12)),
          ),
        if (!_autocompleteLoading && _autocompleteSuggestions.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 18),
            child: Center(child: Text('Sin sugerencias por ahora.')),
          ),
        ..._autocompleteSuggestions.map(
          (suggestion) => InkWell(
            onTap: () async {
              await _applySuggestionAndSearch(suggestion);
            },
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    CupertinoIcons.search,
                    size: 17,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      suggestion,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: baseTextStyle.copyWith(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: CupertinoColors.label.resolveFrom(context),
                      ),
                    ),
                  ),
                  Icon(
                    CupertinoIcons.arrow_up_left,
                    size: 16,
                    color: CupertinoColors.tertiaryLabel.resolveFrom(context),
                  ),
                ],
              ),
            ),
          ),
        ),
        SizedBox(height: bottomReserve),
      ],
    );
  }

  Widget _buildSearchTabHistoryBody({required double bottomReserve}) {
    if (_searchTabHistoryLoading &&
        _searchTabTrackHistory.isEmpty &&
        _searchTabArtistHistory.isEmpty) {
      return const Center(child: CupertinoActivityIndicator(radius: 14));
    }

    if (_searchTabTrackHistory.isEmpty && _searchTabArtistHistory.isEmpty) {
      return Center(
        child: Text(
          'Tu actividad de Buscar aparecerá aquí.',
          style: Theme.of(context).textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
      );
    }

    final mixedItems = _buildMixedSearchHistoryItems();

    return ListView.separated(
      itemCount: mixedItems.length + 1,
      itemBuilder: (context, index) {
        if (index == mixedItems.length) {
          return SizedBox(height: bottomReserve);
        }
        final item = mixedItems[index];
        if (item.type == _SearchHistoryMixedItemType.artist) {
          final artist = item.artist!;
          return _SearchHistoryArtistCard(
            entry: artist,
            onTap: () => _openArtistFromSearchHistory(artist),
          );
        }
        final track = item.track!;
        return _SearchHistoryTrackCard(
          entry: track,
          onTap: () => _playFromSearchHistoryTrack(track),
          onQueueNext: () =>
              _queueHistoryTrack(track, insertMode: ManualQueueInsertMode.next),
          onQueueEnd: () =>
              _queueHistoryTrack(track, insertMode: ManualQueueInsertMode.end),
        );
      },
      separatorBuilder: (context, index) {
        if (index >= mixedItems.length - 1) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(left: 80),
          child: Container(
            height: 0.9,
            color: CupertinoColors.separator
                .resolveFrom(context)
                .withValues(alpha: 0.5),
          ),
        );
      },
    );
  }

  List<_SearchHistoryMixedItem> _buildMixedSearchHistoryItems() {
    final out = <_SearchHistoryMixedItem>[];
    out.addAll(_searchTabArtistHistory.map(_SearchHistoryMixedItem.artist));
    out.addAll(_searchTabTrackHistory.map(_SearchHistoryMixedItem.track));
    out.sort((a, b) {
      final aMs = a.type == _SearchHistoryMixedItemType.artist
          ? (a.artist?.touchedAtMs ?? 0)
          : (a.track?.touchedAtMs ?? 0);
      final bMs = b.type == _SearchHistoryMixedItemType.artist
          ? (b.artist?.touchedAtMs ?? 0)
          : (b.track?.touchedAtMs ?? 0);
      return bMs.compareTo(aMs);
    });
    return out;
  }

  Future<void> _openArtistFromSearchHistory(
    _SearchTabArtistHistoryEntry entry,
  ) async {
    _rememberSearchArtistHistory(entry);
    await _openArtistEmbedded(
      channelId: entry.channelId,
      channelName: entry.channelName,
      channelThumbnailUrl: entry.channelThumbnailUrl,
    );
  }

  Future<void> _playFromSearchHistoryTrack(
    _SearchTabTrackHistoryEntry entry,
  ) async {
    final manager = context.read<VideoPlayerManager>();
    if (entry.isLocal) {
      final localPath = entry.localFilePath?.trim() ?? '';
      if (localPath.isNotEmpty && await File(localPath).exists()) {
        if (!mounted) return;
        await manager.playLocalFileFromUserSelection(
          context,
          id: entry.videoId,
          filePath: localPath,
          title: entry.title,
          thumbnailUrl: entry.thumbnailUrl,
          artist: entry.artist,
          queueStrategy: LocalPlaybackQueueStrategy.recommendations,
        );
        _rememberSearchTrackHistory(entry);
        return;
      }
    }

    if (!mounted) return;
    await _openVideoPlayer(
      entry.videoId,
      thumbnailUrl: entry.thumbnailUrl,
      title: entry.title,
      artist: entry.artist,
      forceVideoPlayback: _isVideosFilterMode,
    );
  }

  List<SearchChannelWithSubscribers> _orderedChannelsForDisplay({
    required List<SearchChannelWithSubscribers> channels,
    required List<Video> videos,
  }) {
    if (channels.length <= 1 || videos.isEmpty) return channels;
    final primaryArtist = _normalizeArtistNameForMatch(videos.first.author);
    if (primaryArtist.isEmpty) return channels;

    final ranked =
        <({SearchChannelWithSubscribers item, int index, int score})>[];
    for (var i = 0; i < channels.length; i++) {
      final item = channels[i];
      final channelName = _normalizeArtistNameForMatch(item.channel.name);
      var score = 0;
      if (channelName == primaryArtist) score += 120;
      if (channelName.contains(primaryArtist)) score += 60;
      if (primaryArtist.contains(channelName)) score += 40;
      ranked.add((item: item, index: i, score: score));
    }

    ranked.sort((a, b) {
      if (a.score != b.score) return b.score.compareTo(a.score);
      return a.index.compareTo(b.index);
    });
    return ranked.map((e) => e.item).toList();
  }

  String _normalizeArtistNameForMatch(String input) {
    return input
        .toLowerCase()
        .replaceAll(RegExp(r'\s*[-–—]\s*topic$', caseSensitive: false), '')
        .replaceAll(RegExp(r'\btopic\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\bvevo\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\bofficial\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\brecords?\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\bmusic\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String? _findChannelThumbnailForArtist({
    required String artistName,
    required List<SearchChannelWithSubscribers> channels,
  }) {
    if (channels.isEmpty) return null;
    final normalizedArtist = _normalizeArtistNameForMatch(artistName);
    if (normalizedArtist.isEmpty) return null;

    SearchChannelWithSubscribers? best;
    var bestScore = -1;
    for (final channel in channels) {
      final normalizedChannel = _normalizeArtistNameForMatch(
        channel.channel.name,
      );
      if (normalizedChannel.isEmpty) continue;
      var score = 0;
      if (normalizedChannel == normalizedArtist) score += 120;
      if (normalizedChannel.contains(normalizedArtist)) score += 60;
      if (normalizedArtist.contains(normalizedChannel)) score += 40;
      if (score > bestScore) {
        bestScore = score;
        best = channel;
      }
    }
    if (best == null || bestScore <= 0) return null;
    if (best.thumbnailUrlOverride != null &&
        best.thumbnailUrlOverride!.isNotEmpty) {
      return best.thumbnailUrlOverride!;
    }
    if (best.channel.thumbnails.isNotEmpty) {
      return best.channel.thumbnails.first.url.toString();
    }
    return null;
  }

  List<Video> _prioritizedVideos(List<Video> source) {
    final dedup = <String, Video>{};
    for (final video in source) {
      dedup.putIfAbsent(video.id.value, () => video);
    }
    final ordered = dedup.values.toList()
      ..sort(
        (a, b) => b.engagement.viewCount.compareTo(a.engagement.viewCount),
      );
    return ordered;
  }

  bool _isTopicVideo(Video video) {
    final author = video.author.toLowerCase().trim();
    return author.endsWith('- topic') || author.endsWith('topic');
  }

  bool _isPureYoutubeMusicAudioSearchResult(Video video) {
    final author = video.author.toLowerCase().trim();
    if (_isBlockedSearchAuthor(author)) return false;
    final title = video.title.toLowerCase();
    final description = video.description.toLowerCase();
    final text = '$title $author $description';
    final topic = _isTopicVideo(video);
    final autoGenerated = _isAutoGeneratedVideo(video);
    final hasVideoLikeSignal = _searchVideoLikeKeywords.any(text.contains);
    return (topic || autoGenerated) && !hasVideoLikeSignal;
  }

  bool _isPodcastMarkedVideo(Video video) {
    final text = '${video.title} ${video.author} ${video.description}'
        .toLowerCase();
    return RegExp(r'(^|[^a-z])podcast(s)?([^a-z]|$)').hasMatch(text) ||
        text.contains('#podcast');
  }

  bool _isAutoGeneratedVideo(Video video) {
    final title = video.title.toLowerCase();
    final description = video.description.toLowerCase();
    return _searchAutoGeneratedKeywords.any((keyword) {
      return title.contains(keyword) || description.contains(keyword);
    });
  }

  bool _isBlockedSearchAuthor(String authorLower) {
    final author = authorLower.trim();
    return author == 'release - topic' || author == 'release topic';
  }

  static const List<String> _searchAutoGeneratedKeywords = [
    'provided to youtube by',
    'auto-generated by youtube',
  ];

  static const List<String> _searchVideoLikeKeywords = [
    'official video',
    'music video',
    'video oficial',
    'live',
    'en vivo',
    'concert',
    'session',
    'visualizer',
    'performance',
    'clip oficial',
    'lyrics',
    'lyric',
  ];
}

class _SelectedArtistView {
  final String channelId;
  final String channelName;
  final String channelThumbnailUrl;

  const _SelectedArtistView({
    required this.channelId,
    required this.channelName,
    required this.channelThumbnailUrl,
  });
}

class _SelectedAlbumView {
  final String playlistId;
  final String albumTitle;
  final String artistName;
  final String seedThumbnailUrl;

  const _SelectedAlbumView({
    required this.playlistId,
    required this.albumTitle,
    required this.artistName,
    required this.seedThumbnailUrl,
  });
}

class _SearchHistoryArtistCard extends StatelessWidget {
  final _SearchTabArtistHistoryEntry entry;
  final VoidCallback onTap;

  const _SearchHistoryArtistCard({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final thumb = entry.channelThumbnailUrl.trim();
    final artistName = cleanArtistName(entry.channelName);
    final avatarCachePx = (44 * MediaQuery.devicePixelRatioOf(context))
        .round()
        .clamp(72, 512)
        .toInt();
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: CupertinoColors.systemGrey4.resolveFrom(
                  context,
                ),
                foregroundImage: thumb.isNotEmpty
                    ? ResizeImage(
                        NetworkImage(thumb),
                        width: avatarCachePx,
                        height: avatarCachePx,
                      )
                    : null,
                child: thumb.isEmpty
                    ? Icon(
                        CupertinoIcons.person_fill,
                        color: CupertinoColors.secondaryLabel.resolveFrom(
                          context,
                        ),
                      )
                    : null,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  artistName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: CupertinoTheme.of(context).textTheme.textStyle
                      .copyWith(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SearchHistoryTrackCard extends StatelessWidget {
  final _SearchTabTrackHistoryEntry entry;
  final VoidCallback onTap;
  final VoidCallback? onQueueNext;
  final VoidCallback? onQueueEnd;

  const _SearchHistoryTrackCard({
    required this.entry,
    required this.onTap,
    this.onQueueNext,
    this.onQueueEnd,
  });

  @override
  Widget build(BuildContext context) {
    final card = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              entry.thumbnailUrl.startsWith('/')
                  ? SquareThumbnail.file(
                      filePath: entry.thumbnailUrl,
                      size: 48,
                      borderRadius: 8,
                      fallback: _buildTrackFallback(context),
                    )
                  : SquareThumbnail.network(
                      imageUrl: entry.thumbnailUrl,
                      size: 48,
                      borderRadius: 8,
                      fallback: _buildTrackFallback(context),
                    ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: CupertinoTheme.of(context).textTheme.textStyle
                          .copyWith(fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      entry.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: CupertinoTheme.of(context).textTheme.textStyle
                          .copyWith(
                            fontSize: 12.5,
                            color: CupertinoColors.secondaryLabel.resolveFrom(
                              context,
                            ),
                          ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (onQueueNext == null || onQueueEnd == null) return card;
    return Slidable(
      key: ValueKey('search_history_${entry.videoId}_${entry.touchedAtMs}'),
      startActionPane: ActionPane(
        motion: const StretchMotion(),
        extentRatio: 0.46,
        dismissible: DismissiblePane(
          onDismissed: () {},
          closeOnCancel: true,
          confirmDismiss: () async {
            onQueueNext?.call();
            return false;
          },
        ),
        children: [
          QueueSwipeActionButton(
            onTap: () => onQueueNext?.call(),
            baseColor: CupertinoColors.systemPink.resolveFrom(context),
            icon: CupertinoIcons.text_insert,
            label: 'Siguiente',
          ),
          QueueSwipeActionButton(
            onTap: () => onQueueEnd?.call(),
            baseColor: CupertinoColors.systemBlue.resolveFrom(context),
            icon: CupertinoIcons.text_append,
            label: 'Al final',
          ),
        ],
      ),
      child: card,
    );
  }

  Widget _buildTrackFallback(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      color: CupertinoColors.tertiarySystemFill.resolveFrom(context),
      alignment: Alignment.center,
      child: Icon(
        CupertinoIcons.music_note_2,
        size: 21,
        color: CupertinoColors.secondaryLabel.resolveFrom(context),
      ),
    );
  }
}

class ChannelCard extends StatelessWidget {
  final SearchChannelWithSubscribers channel;
  final String subscriberLabel;
  final VoidCallback onTap;

  const ChannelCard({
    super.key,
    required this.channel,
    required this.subscriberLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final thumb = _thumbnailUrl(channel);
    final avatarCachePx = (52 * MediaQuery.devicePixelRatioOf(context))
        .round()
        .clamp(72, 512)
        .toInt();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.0),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Material(
          color: Colors.white.withValues(alpha: 0.035),
          child: InkWell(
            onTap: onTap,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.14),
                  width: 0.6,
                ),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withValues(alpha: 0.075),
                    Colors.white.withValues(alpha: 0.02),
                  ],
                ),
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: 12.0,
                vertical: 7.0,
              ),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: Transform.scale(
                      scale: 1.05,
                      child: Image.network(
                        thumb,
                        width: 52,
                        height: 52,
                        fit: BoxFit.cover,
                        alignment: Alignment.center,
                        cacheWidth: avatarCachePx,
                        cacheHeight: avatarCachePx,
                        filterQuality: FilterQuality.low,
                        errorBuilder: (context, error, stackTrace) =>
                            const SizedBox(
                              width: 52,
                              height: 52,
                              child: Icon(
                                Icons.account_circle_outlined,
                                size: 26,
                                color: Colors.grey,
                              ),
                            ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          channel.channel.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: CupertinoTheme.of(context).textTheme.textStyle
                              .copyWith(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: CupertinoColors.label.resolveFrom(
                                  context,
                                ),
                              ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '$subscriberLabel • ${channel.channel.videoCount} videos',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: CupertinoTheme.of(context).textTheme.textStyle
                              .copyWith(
                                fontSize: 13,
                                color: CupertinoColors.secondaryLabel
                                    .resolveFrom(context),
                              ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: CupertinoColors.tertiaryLabel.resolveFrom(context),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _thumbnailUrl(SearchChannelWithSubscribers channelData) {
    if (channelData.thumbnailUrlOverride != null &&
        channelData.thumbnailUrlOverride!.isNotEmpty) {
      return channelData.thumbnailUrlOverride!;
    }
    if (channelData.channel.thumbnails.isNotEmpty) {
      return channelData.channel.thumbnails.first.url.toString();
    }
    return '';
  }
}

class SearchModeButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool isActive;
  final VoidCallback onPressed;

  const SearchModeButton({
    super.key,
    required this.label,
    required this.icon,
    required this.isActive,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(12);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final foregroundColor = isDark ? Colors.white : Colors.black;
    return CupertinoButton(
      padding: EdgeInsets.zero,
      minimumSize: Size.zero,
      onPressed: onPressed,
      child: Container(
        padding: const EdgeInsets.all(1.25),
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFFF004D), Color(0xFFFF7A00), Color(0xFF7A5CFF)],
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(
                0xFFFF4D00,
              ).withValues(alpha: isActive ? 0.3 : 0.16),
              blurRadius: isActive ? 16 : 10,
              spreadRadius: isActive ? 0.6 : 0.0,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: borderRadius,
          child: Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: (isActive
                  ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.2)
                  : CupertinoColors.systemGrey6
                        .resolveFrom(context)
                        .withValues(alpha: 0.52)),
              borderRadius: borderRadius,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: foregroundColor),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: CupertinoTheme.of(context).textTheme.textStyle
                      .copyWith(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: foregroundColor,
                      ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchAlbumCard extends StatelessWidget {
  final _SearchAlbumResult album;
  final VoidCallback onTap;

  const _SearchAlbumCard({required this.album, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark ? Colors.black : Colors.white;
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.black.withValues(alpha: 0.08);
    final coverCachePx = (62 * MediaQuery.devicePixelRatioOf(context))
        .round()
        .clamp(96, 768)
        .toInt();
    final fallbackThumbColor = CupertinoColors.tertiarySystemFill.resolveFrom(
      context,
    );
    final albumLabelColor = CupertinoColors.secondaryLabel.resolveFrom(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Material(
          color: cardColor,
          child: InkWell(
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cardColor,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: borderColor, width: 0.8),
              ),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: album.thumbnailUrl.isNotEmpty
                        ? Image.network(
                            album.thumbnailUrl,
                            width: 62,
                            height: 62,
                            fit: BoxFit.cover,
                            cacheWidth: coverCachePx,
                            cacheHeight: coverCachePx,
                            filterQuality: FilterQuality.low,
                            errorBuilder: (context, error, stackTrace) =>
                                Container(
                                  width: 62,
                                  height: 62,
                                  color: fallbackThumbColor,
                                  child: Icon(
                                    CupertinoIcons.music_albums_fill,
                                    size: 26,
                                    color: albumLabelColor,
                                  ),
                                ),
                          )
                        : Container(
                            width: 62,
                            height: 62,
                            color: fallbackThumbColor,
                            child: Icon(
                              CupertinoIcons.music_albums_fill,
                              size: 26,
                              color: albumLabelColor,
                            ),
                          ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Álbum',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.75,
                            color: albumLabelColor,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          album.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: CupertinoTheme.of(context).textTheme.textStyle
                              .copyWith(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          album.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: CupertinoTheme.of(context).textTheme.textStyle
                              .copyWith(
                                fontSize: 12,
                                color: CupertinoColors.secondaryLabel
                                    .resolveFrom(context),
                              ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    CupertinoIcons.chevron_forward,
                    size: 17,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class TopArtistCard extends StatelessWidget {
  final SearchChannelWithSubscribers channel;
  final String subscriberLabel;
  final VoidCallback onOpenChannel;

  const TopArtistCard({
    super.key,
    required this.channel,
    required this.subscriberLabel,
    required this.onOpenChannel,
  });

  @override
  Widget build(BuildContext context) {
    final thumb = _thumbnailUrl(channel);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark
        ? const Color(0xFF0B0B0B)
        : CupertinoColors.secondarySystemGroupedBackground.resolveFrom(context);
    final cardBorder = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : CupertinoColors.separator
              .resolveFrom(context)
              .withValues(alpha: 0.14);
    final avatarCachePx = (72 * MediaQuery.devicePixelRatioOf(context))
        .round()
        .clamp(96, 512)
        .toInt();
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Material(
        color: cardColor,
        surfaceTintColor: Colors.transparent,
        child: InkWell(
          onTap: onOpenChannel,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: cardBorder, width: 0.8),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  (isDark ? Colors.white : Colors.black).withValues(
                    alpha: 0.06,
                  ),
                  (isDark ? Colors.white : Colors.black).withValues(
                    alpha: 0.02,
                  ),
                ],
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: Transform.scale(
                        scale: 1.05,
                        child: Image.network(
                          thumb,
                          width: 72,
                          height: 72,
                          fit: BoxFit.cover,
                          alignment: Alignment.center,
                          cacheWidth: avatarCachePx,
                          cacheHeight: avatarCachePx,
                          filterQuality: FilterQuality.low,
                          errorBuilder: (context, error, stackTrace) =>
                              const SizedBox(
                                width: 72,
                                height: 72,
                                child: Icon(
                                  Icons.account_circle_outlined,
                                  size: 38,
                                  color: Colors.grey,
                                ),
                              ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            channel.channel.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: CupertinoTheme.of(context)
                                .textTheme
                                .textStyle
                                .copyWith(
                                  fontSize: 26,
                                  fontWeight: FontWeight.w700,
                                  color: CupertinoColors.label.resolveFrom(
                                    context,
                                  ),
                                ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            subscriberLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: CupertinoTheme.of(context)
                                .textTheme
                                .textStyle
                                .copyWith(
                                  fontSize: 14,
                                  color: CupertinoColors.secondaryLabel
                                      .resolveFrom(context),
                                ),
                          ),
                          Text(
                            '${channel.channel.videoCount} videos',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: CupertinoTheme.of(context)
                                .textTheme
                                .textStyle
                                .copyWith(
                                  fontSize: 13,
                                  color: CupertinoColors.secondaryLabel
                                      .resolveFrom(context),
                                ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _ArtistVideosActionButton(onPressed: onOpenChannel),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _thumbnailUrl(SearchChannelWithSubscribers channelData) {
    if (channelData.thumbnailUrlOverride != null &&
        channelData.thumbnailUrlOverride!.isNotEmpty) {
      return channelData.thumbnailUrlOverride!;
    }
    if (channelData.channel.thumbnails.isNotEmpty) {
      return channelData.channel.thumbnails.first.url.toString();
    }
    return '';
  }
}

class _TopArtistFromVideoCard extends StatelessWidget {
  final Video video;
  final String? channelThumbnailUrl;
  final VoidCallback onOpen;

  const _TopArtistFromVideoCard({
    required this.video,
    this.channelThumbnailUrl,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final thumb =
        (channelThumbnailUrl != null && channelThumbnailUrl!.isNotEmpty)
        ? channelThumbnailUrl!
        : bestThumbnailForVideo(video);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark
        ? const Color(0xFF0B0B0B)
        : CupertinoColors.secondarySystemGroupedBackground.resolveFrom(context);
    final cardBorder = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : CupertinoColors.separator
              .resolveFrom(context)
              .withValues(alpha: 0.14);
    final avatarCachePx = (72 * MediaQuery.devicePixelRatioOf(context))
        .round()
        .clamp(96, 512)
        .toInt();
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Material(
        color: cardColor,
        surfaceTintColor: Colors.transparent,
        child: InkWell(
          onTap: onOpen,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: cardBorder, width: 0.8),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  (isDark ? Colors.white : Colors.black).withValues(
                    alpha: 0.06,
                  ),
                  (isDark ? Colors.white : Colors.black).withValues(
                    alpha: 0.02,
                  ),
                ],
              ),
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: Transform.scale(
                    scale: 1.05,
                    child: Image.network(
                      thumb,
                      width: 72,
                      height: 72,
                      fit: BoxFit.cover,
                      alignment: Alignment.center,
                      cacheWidth: avatarCachePx,
                      cacheHeight: avatarCachePx,
                      filterQuality: FilterQuality.low,
                      errorBuilder: (context, error, stackTrace) =>
                          const SizedBox(
                            width: 72,
                            height: 72,
                            child: Icon(
                              Icons.account_circle_outlined,
                              size: 38,
                              color: Colors.grey,
                            ),
                          ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        cleanArtistName(video.author),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: CupertinoTheme.of(context).textTheme.textStyle
                            .copyWith(
                              fontSize: 24,
                              fontWeight: FontWeight.w700,
                              color: CupertinoColors.label.resolveFrom(context),
                            ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Del primer resultado',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: CupertinoTheme.of(context).textTheme.textStyle
                            .copyWith(
                              fontSize: 13,
                              color: CupertinoColors.secondaryLabel.resolveFrom(
                                context,
                              ),
                            ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.chevron_right_rounded,
                  color: CupertinoColors.tertiaryLabel.resolveFrom(context),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ArtistVideosActionButton extends StatefulWidget {
  final VoidCallback onPressed;

  const _ArtistVideosActionButton({required this.onPressed});

  @override
  State<_ArtistVideosActionButton> createState() =>
      _ArtistVideosActionButtonState();
}

class _ArtistVideosActionButtonState extends State<_ArtistVideosActionButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _borderController;

  @override
  void initState() {
    super.initState();
    _borderController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    )..repeat();
  }

  @override
  void dispose() {
    _borderController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(14);
    return AnimatedBuilder(
      animation: _borderController,
      builder: (context, _) {
        return CupertinoButton(
          padding: EdgeInsets.zero,
          minimumSize: Size.zero,
          onPressed: widget.onPressed,
          child: Container(
            padding: const EdgeInsets.all(1.2),
            decoration: BoxDecoration(
              borderRadius: borderRadius,
              gradient: SweepGradient(
                transform: GradientRotation(
                  _borderController.value * math.pi * 2,
                ),
                colors: [
                  const Color(0xFFE79A52).withValues(alpha: 0.82),
                  const Color(0xFFEDB567).withValues(alpha: 0.82),
                  const Color(0xFFF1CB86).withValues(alpha: 0.82),
                  const Color(0xFFE9A15A).withValues(alpha: 0.82),
                  const Color(0xFFE79A52).withValues(alpha: 0.82),
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFDA9A57).withValues(alpha: 0.14),
                  blurRadius: 10,
                  spreadRadius: 0,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: borderRadius,
              child: Container(
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      const Color(0xFFEABF81).withValues(alpha: 0.74),
                      const Color(0xFFE5AE6D).withValues(alpha: 0.78),
                      const Color(0xFFDF995A).withValues(alpha: 0.76),
                    ],
                  ),
                  borderRadius: borderRadius,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.14),
                    width: 0.45,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFDDA15F).withValues(alpha: 0.10),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Icon(
                      Icons.music_note_rounded,
                      size: 16,
                      color: Colors.white,
                    ),
                    SizedBox(width: 7),
                    Text(
                      'Ver videos musicales',
                      style: TextStyle(
                        fontFamily: '.SF Pro Text',
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _VideoCard extends StatelessWidget {
  final Video video;
  final VoidCallback onPlay;
  final VoidCallback? onQueueNext;
  final VoidCallback? onQueueEnd;
  final Future<void> Function(_SearchVideoContextAction action) onContextAction;

  const _VideoCard({
    required this.video,
    required this.onPlay,
    this.onQueueNext,
    this.onQueueEnd,
    required this.onContextAction,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveIsDownloaded =
        context.watch<DownloadService>().getDownloadStatus(video.id.value) ==
        DownloadStatus.downloaded;
    final borderRadius = BorderRadius.circular(14);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark
        ? Colors.black
        : CupertinoColors.secondarySystemGroupedBackground.resolveFrom(context);
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : CupertinoColors.separator
              .resolveFrom(context)
              .withValues(alpha: 0.14);
    final horizontalPadding = 8.0;
    final thumbSize = 56.0;
    final thumbGap = 8.0;
    final trailingSpace = effectiveIsDownloaded ? 300.0 : 0.0;
    final safeMaxTextWidth =
        MediaQuery.of(context).size.width -
        (horizontalPadding * 2) -
        thumbSize -
        thumbGap -
        trailingSpace -
        34.0;

    final card = LayoutBuilder(
      builder: (context, constraints) => ClipRRect(
        borderRadius: borderRadius,
        child: Material(
          color: cardColor,
          child: InkWell(
            onTap: onPlay,
            child: Container(
              width: constraints.hasBoundedWidth ? double.infinity : null,
              decoration: BoxDecoration(
                color: cardColor,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: borderColor, width: 0.6),
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: 8.0,
                vertical: 4.0,
              ),
              child: Row(
                children: [
                  SquareThumbnail.network(
                    imageUrl: _bestQualityThumbnail(video),
                    size: 56,
                    borderRadius: 10,
                    zoom: 1,
                    fallback: Container(
                      width: 56,
                      height: 56,
                      color: CupertinoColors.tertiarySystemFill.resolveFrom(
                        context,
                      ),
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.videocam_off_outlined,
                        size: 24,
                        color: CupertinoColors.secondaryLabel.resolveFrom(
                          context,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: safeMaxTextWidth.clamp(140.0, 520.0),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          video.title,
                          style: CupertinoTheme.of(context).textTheme.textStyle
                              .copyWith(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: CupertinoColors.label.resolveFrom(
                                  context,
                                ),
                                letterSpacing: -0.1,
                              ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          cleanArtistName(video.author),
                          style: CupertinoTheme.of(context).textTheme.textStyle
                              .copyWith(
                                fontSize: 11,
                                fontWeight: FontWeight.w400,
                                color: CupertinoColors.secondaryLabel
                                    .resolveFrom(context),
                              ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 150),
                  if (effectiveIsDownloaded) ...[
                    const Icon(
                      CupertinoIcons.arrow_down_circle_fill,
                      size: 14,
                      color: CupertinoColors.systemGreen,
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );

    final contextMenuWrapped = _SearchVideoContextMenu(
      onContextAction: onContextAction,
      child: card,
    );
    final swipeCard = (onQueueNext == null || onQueueEnd == null)
        ? contextMenuWrapped
        : Slidable(
            key: ObjectKey(video),
            startActionPane: ActionPane(
              motion: const StretchMotion(),
              extentRatio: 0.46,
              dismissible: DismissiblePane(
                onDismissed: () {},
                closeOnCancel: true,
                confirmDismiss: () async {
                  onQueueNext?.call();
                  return false;
                },
              ),
              children: [
                QueueSwipeActionButton(
                  onTap: () => onQueueNext?.call(),
                  baseColor: CupertinoColors.systemPink.resolveFrom(context),
                  icon: CupertinoIcons.text_insert,
                  label: 'Siguiente',
                ),
                QueueSwipeActionButton(
                  onTap: () => onQueueEnd?.call(),
                  baseColor: CupertinoColors.systemBlue.resolveFrom(context),
                  icon: CupertinoIcons.text_append,
                  label: 'Al final',
                ),
              ],
            ),
            child: contextMenuWrapped,
          );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.0),
      child: swipeCard,
    );
  }
}

class _YouTubeStyleVideoCard extends StatelessWidget {
  final Video video;
  final VoidCallback onPlay;
  final VoidCallback? onQueueNext;
  final VoidCallback? onQueueEnd;
  final Future<void> Function(_SearchVideoContextAction action) onContextAction;

  const _YouTubeStyleVideoCard({
    required this.video,
    required this.onPlay,
    this.onQueueNext,
    this.onQueueEnd,
    required this.onContextAction,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark
        ? Colors.black
        : CupertinoColors.secondarySystemGroupedBackground.resolveFrom(context);
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : CupertinoColors.separator
              .resolveFrom(context)
              .withValues(alpha: 0.14);
    final card = LayoutBuilder(
      builder: (context, constraints) => ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Material(
          color: cardColor,
          child: InkWell(
            onTap: onPlay,
            child: Container(
              width: constraints.hasBoundedWidth ? double.infinity : null,
              decoration: BoxDecoration(
                color: cardColor,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: borderColor, width: 0.6),
              ),
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox(
                      width: 168,
                      height: 94.5,
                      child: Image.network(
                        _bestQualityThumbnail(video),
                        fit: BoxFit.cover,
                        filterQuality: FilterQuality.low,
                        errorBuilder: (context, error, stackTrace) => Container(
                          color: CupertinoColors.tertiarySystemFill.resolveFrom(
                            context,
                          ),
                          alignment: Alignment.center,
                          child: Icon(
                            Icons.videocam_off_outlined,
                            size: 28,
                            color: CupertinoColors.secondaryLabel.resolveFrom(
                              context,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SizedBox(
                      height: 94.5,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            video.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: CupertinoTheme.of(context)
                                .textTheme
                                .textStyle
                                .copyWith(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: CupertinoColors.label.resolveFrom(
                                    context,
                                  ),
                                  letterSpacing: -0.1,
                                ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            cleanArtistName(video.author),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: CupertinoTheme.of(context)
                                .textTheme
                                .textStyle
                                .copyWith(
                                  fontSize: 12.5,
                                  color: CupertinoColors.secondaryLabel
                                      .resolveFrom(context),
                                ),
                          ),
                          const Spacer(),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    final contextMenuWrapped = _SearchVideoContextMenu(
      onContextAction: onContextAction,
      child: card,
    );
    final swipeCard = (onQueueNext == null || onQueueEnd == null)
        ? contextMenuWrapped
        : Slidable(
            key: ObjectKey(video),
            startActionPane: ActionPane(
              motion: const StretchMotion(),
              extentRatio: 0.46,
              dismissible: DismissiblePane(
                onDismissed: () {},
                closeOnCancel: true,
                confirmDismiss: () async {
                  onQueueNext?.call();
                  return false;
                },
              ),
              children: [
                QueueSwipeActionButton(
                  onTap: () => onQueueNext?.call(),
                  baseColor: CupertinoColors.systemPink.resolveFrom(context),
                  icon: CupertinoIcons.text_insert,
                  label: 'Siguiente',
                ),
                QueueSwipeActionButton(
                  onTap: () => onQueueEnd?.call(),
                  baseColor: CupertinoColors.systemBlue.resolveFrom(context),
                  icon: CupertinoIcons.text_append,
                  label: 'Al final',
                ),
              ],
            ),
            child: contextMenuWrapped,
          );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: swipeCard,
    );
  }
}

class _SearchVideoContextMenu extends StatelessWidget {
  final Future<void> Function(_SearchVideoContextAction action) onContextAction;
  final Widget child;

  const _SearchVideoContextMenu({
    required this.onContextAction,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final gray = CupertinoColors.systemGrey.resolveFrom(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? CupertinoColors.white : CupertinoColors.black;

    final actions = <Widget>[
      CupertinoContextMenuAction(
        onPressed: () {
          Navigator.of(context).pop();
          unawaited(onContextAction(_SearchVideoContextAction.addToFavorites));
        },
        child: _ContextMenuActionContent(
          label: 'Añadir a Favoritos',
          icon: CupertinoIcons.star_fill,
          textColor: textColor,
          iconColor: gray,
        ),
      ),
      CupertinoContextMenuAction(
        onPressed: () {
          Navigator.of(context).pop();
          unawaited(onContextAction(_SearchVideoContextAction.addToPlaylist));
        },
        child: _ContextMenuActionContent(
          label: 'Añadir a playlist',
          icon: CupertinoIcons.music_note_list,
          textColor: textColor,
          iconColor: gray,
        ),
      ),
      CupertinoContextMenuAction(
        onPressed: () {
          Navigator.of(context).pop();
          unawaited(onContextAction(_SearchVideoContextAction.addNext));
        },
        child: _ContextMenuActionContent(
          label: 'Añadir como siguiente',
          icon: CupertinoIcons.text_insert,
          textColor: textColor,
          iconColor: gray,
        ),
      ),
      CupertinoContextMenuAction(
        onPressed: () {
          Navigator.of(context).pop();
          unawaited(onContextAction(_SearchVideoContextAction.addToEnd));
        },
        child: _ContextMenuActionContent(
          label: 'Añadir al final',
          icon: CupertinoIcons.text_append,
          textColor: textColor,
          iconColor: gray,
        ),
      ),
      CupertinoContextMenuAction(
        onPressed: () {
          Navigator.of(context).pop();
          unawaited(onContextAction(_SearchVideoContextAction.share));
        },
        child: _ContextMenuActionContent(
          label: 'Compartir',
          icon: CupertinoIcons.square_arrow_up,
          textColor: textColor,
          iconColor: gray,
        ),
      ),
      CupertinoContextMenuAction(
        onPressed: () {
          Navigator.of(context).pop();
          unawaited(onContextAction(_SearchVideoContextAction.openArtist));
        },
        child: _ContextMenuActionContent(
          label: 'Ir al artista',
          icon: CupertinoIcons.person_crop_circle,
          textColor: textColor,
          iconColor: gray,
        ),
      ),
      CupertinoContextMenuAction(
        onPressed: () {
          Navigator.of(context).pop();
          unawaited(onContextAction(_SearchVideoContextAction.openAlbum));
        },
        child: _ContextMenuActionContent(
          label: 'Ir al álbum',
          icon: CupertinoIcons.rectangle_stack_fill,
          textColor: textColor,
          iconColor: gray,
        ),
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final hasBoundedWidth = constraints.maxWidth.isFinite;
        final hasBoundedHeight = constraints.maxHeight.isFinite;
        if (hasBoundedWidth && hasBoundedHeight) {
          final fixedSizeChild = SizedBox(
            width: constraints.maxWidth,
            height: constraints.maxHeight,
            child: child,
          );
          return CupertinoContextMenu.builder(
            actions: actions,
            enableHapticFeedback: true,
            builder: (context, animation) => fixedSizeChild,
          );
        }
        return CupertinoContextMenu(
          actions: actions,
          enableHapticFeedback: true,
          child: child,
        );
      },
    );
  }
}

class _ContextMenuActionContent extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color textColor;
  final Color iconColor;

  const _ContextMenuActionContent({
    required this.label,
    required this.icon,
    required this.textColor,
    required this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: textColor),
          ),
        ),
        Icon(icon, color: iconColor, size: 20),
      ],
    );
  }
}

class _GlassSheetActionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _GlassSheetActionRow({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: _AdaptiveBackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Material(
          color: Colors.white.withValues(alpha: 0.05),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: CupertinoColors.white.withValues(alpha: 0.18),
                  width: 0.6,
                ),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withValues(alpha: 0.08),
                    Colors.white.withValues(alpha: 0.02),
                  ],
                ),
              ),
              child: Row(
                children: [
                  Icon(icon, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      label,
                      style: const TextStyle(
                        fontFamily: '.SF Pro Text',
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                  ),
                  Icon(
                    CupertinoIcons.chevron_right,
                    size: 17,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

void _showIosTopToast(
  BuildContext context, {
  required String message,
  required IconData icon,
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final isDark = Theme.of(context).brightness == Brightness.dark;

  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (overlayContext) {
      final bottomInset = MediaQuery.of(overlayContext).padding.bottom;
      return IgnorePointer(
        ignoring: true,
        child: SizedBox.expand(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.only(bottom: bottomInset + 130),
              child: _IosTopToast(message: message, icon: icon, isDark: isDark),
            ),
          ),
        ),
      );
    },
  );
  overlay.insert(entry);
  Timer(const Duration(milliseconds: 1900), () {
    entry.remove();
  });
}

class _IosTopToast extends StatefulWidget {
  final String message;
  final IconData icon;
  final bool isDark;

  const _IosTopToast({
    required this.message,
    required this.icon,
    required this.isDark,
  });

  @override
  State<_IosTopToast> createState() => _IosTopToastState();
}

class _IosTopToastState extends State<_IosTopToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      reverseDuration: const Duration(milliseconds: 240),
    );
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    _slide = Tween<Offset>(
      begin: const Offset(0, -0.06),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _controller.forward();
    Timer(const Duration(milliseconds: 1400), () {
      if (mounted) {
        _controller.reverse();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: _slide,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: _AdaptiveBackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 330),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: widget.isDark
                    ? const Color(0xFF0D0F13).withValues(alpha: 0.84)
                    : Colors.white.withValues(alpha: 0.86),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: widget.isDark
                      ? Colors.white.withValues(alpha: 0.14)
                      : Colors.black.withValues(alpha: 0.08),
                  width: 0.6,
                ),
              ),
              child: Text(
                widget.message,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: '.SF Pro Text',
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: widget.isDark ? Colors.white : Colors.black,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ChannelVideosPage extends StatefulWidget {
  final String channelId;
  final String channelName;
  final String channelThumbnailUrl;
  final bool embedded;
  final VoidCallback? onBack;

  const ChannelVideosPage({
    super.key,
    required this.channelId,
    required this.channelName,
    required this.channelThumbnailUrl,
    this.embedded = false,
    this.onBack,
  });

  @override
  State<ChannelVideosPage> createState() => _ChannelVideosPageState();
}

class _ArtistProfileCacheEntry {
  final int schemaVersion;
  final List<Video> videos;
  final _SearchAlbumResult? suggestedAlbum;
  final List<_SearchAlbumResult> artistAlbums;
  final bool albumsResolved;

  const _ArtistProfileCacheEntry({
    required this.schemaVersion,
    required this.videos,
    required this.suggestedAlbum,
    required this.artistAlbums,
    required this.albumsResolved,
  });
}

class _ChannelVideosPageState extends State<ChannelVideosPage> {
  static const int _artistSessionCacheSchemaVersion = 3;
  static final Map<String, _ArtistProfileCacheEntry> _artistSessionCache = {};
  static const String _artistPersistentCacheBoxName = 'artist_page_cache';
  static const Duration _artistPersistentCacheTtl = Duration(days: 5);
  static const int _artistPersistentCacheMaxEntries = 120;
  final YoutubeExplode _yt = YoutubeExplode();
  final ScrollController _artistScrollController = ScrollController();
  static const Duration _channelFetchTimeout = Duration(seconds: 6);
  static const double _artistSectionHorizontalInset = 16;
  List<Video> _videos = [];
  List<Video> _artistProfileVideos = const [];
  bool _artistProfileVideosLoading = false;
  List<Video> _artistTopSongs = const [];
  bool _artistTopSongsLoading = false;
  String? _artistTopSongsShowAllPlaylistId;
  int _artistTopSongsLoadEpoch = 0;
  _SelectedAlbumView? _selectedAlbumView;
  bool _showAllTopSongs = false;
  _SearchAlbumResult? _suggestedAlbum;
  List<_SearchAlbumResult> _artistAlbums = const [];
  bool _suggestedAlbumLoading = false;
  final Map<String, bool> _albumPlaylistArtistMatchCache = {};
  int _albumLoadEpoch = 0;
  int _albumTransitionDirection = 1;
  bool _loading = true;
  bool _error = false;

  @override
  void setState(VoidCallback fn) {
    if (!mounted) return;
    super.setState(fn);
  }

  @override
  void initState() {
    super.initState();
    final cached = _artistSessionCache[_artistCacheKey];
    if (cached != null &&
        cached.schemaVersion == _artistSessionCacheSchemaVersion &&
        cached.videos.isNotEmpty) {
      _videos = cached.videos;
      _suggestedAlbum = cached.suggestedAlbum;
      _artistAlbums = cached.artistAlbums;
      _loading = false;
      _error = false;
      final shouldRefreshAlbums =
          !cached.albumsResolved || cached.artistAlbums.isEmpty;
      _suggestedAlbumLoading = shouldRefreshAlbums;
      if (shouldRefreshAlbums) {
        unawaited(_loadSuggestedAlbumForArtist());
      }
      unawaited(_loadArtistProfileVideosFromYouTubeMusic());
      unawaited(_loadArtistTopSongsFromYouTubeMusic());
      return;
    }
    unawaited(_restoreArtistPersistentCacheOrLoad());
  }

  String get _artistCacheKey {
    final channelId = widget.channelId.trim();
    if (channelId.isNotEmpty) return 'id:$channelId';
    return 'name:${widget.channelName.trim().toLowerCase()}';
  }

  void _storeArtistCache({required bool albumsResolved}) {
    if (_videos.isEmpty) return;
    final entry = _ArtistProfileCacheEntry(
      schemaVersion: _artistSessionCacheSchemaVersion,
      videos: List<Video>.from(_videos),
      suggestedAlbum: _suggestedAlbum,
      artistAlbums: List<_SearchAlbumResult>.from(_artistAlbums),
      albumsResolved: albumsResolved,
    );
    _artistSessionCache[_artistCacheKey] = entry;
    unawaited(_writeArtistPersistentCache(entry));
  }

  Future<void> _restoreArtistPersistentCacheOrLoad() async {
    final restored = await _readArtistPersistentCache();
    if (restored != null && mounted) {
      setState(() {
        _videos = restored.videos;
        _suggestedAlbum = restored.suggestedAlbum;
        _artistAlbums = restored.artistAlbums;
        _loading = false;
        _error = false;
        _suggestedAlbumLoading =
            !restored.albumsResolved || restored.artistAlbums.isEmpty;
      });
      _storeArtistCache(albumsResolved: restored.albumsResolved);
      if (!restored.albumsResolved) {
        unawaited(_loadSuggestedAlbumForArtist());
      }
      unawaited(_loadArtistProfileVideosFromYouTubeMusic());
      unawaited(_loadArtistTopSongsFromYouTubeMusic());
      return;
    }
    await _loadChannelVideos();
  }

  Future<_ArtistProfileCacheEntry?> _readArtistPersistentCache() async {
    try {
      final box = await Hive.openBox<String>(_artistPersistentCacheBoxName);
      final raw = box.get(_artistCacheKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final map = Map<String, dynamic>.from(decoded.cast<dynamic, dynamic>());
      final savedAtMs = (map['savedAtMs'] as num?)?.toInt() ?? 0;
      if (savedAtMs <= 0) return null;
      final savedAt = DateTime.fromMillisecondsSinceEpoch(savedAtMs);
      if (DateTime.now().difference(savedAt) > _artistPersistentCacheTtl) {
        return null;
      }

      final videosRaw = map['videos'];
      if (videosRaw is! List) return null;
      final restoredVideos = <Video>[];
      for (final item in videosRaw.whereType<Map>()) {
        final snapshot = _CachedVideoSnapshot.fromMap(
          Map<String, dynamic>.from(item.cast<dynamic, dynamic>()),
        );
        if (snapshot.videoId.isEmpty || snapshot.title.isEmpty) continue;
        restoredVideos.add(snapshot.toVideo());
      }
      if (restoredVideos.isEmpty) return null;

      _SearchAlbumResult? suggestedAlbum;
      final suggestedRaw = map['suggestedAlbum'];
      if (suggestedRaw is Map) {
        final m = Map<String, dynamic>.from(
          suggestedRaw.cast<dynamic, dynamic>(),
        );
        final playlistId = (m['playlistId'] ?? '').toString().trim();
        final title = (m['title'] ?? '').toString().trim();
        final artist = (m['artist'] ?? '').toString().trim();
        final thumbnailUrl = (m['thumbnailUrl'] ?? '').toString().trim();
        if (playlistId.isNotEmpty && title.isNotEmpty) {
          suggestedAlbum = _SearchAlbumResult(
            playlistId: playlistId,
            title: title,
            artist: artist.isEmpty ? 'Artista' : artist,
            thumbnailUrl: thumbnailUrl,
          );
        }
      }

      final albums = <_SearchAlbumResult>[];
      final albumsRaw = map['artistAlbums'];
      if (albumsRaw is List) {
        for (final rawAlbum in albumsRaw.whereType<Map>()) {
          final m = Map<String, dynamic>.from(
            rawAlbum.cast<dynamic, dynamic>(),
          );
          final playlistId = (m['playlistId'] ?? '').toString().trim();
          final title = (m['title'] ?? '').toString().trim();
          final artist = (m['artist'] ?? '').toString().trim();
          final thumbnailUrl = (m['thumbnailUrl'] ?? '').toString().trim();
          if (playlistId.isEmpty || title.isEmpty) continue;
          albums.add(
            _SearchAlbumResult(
              playlistId: playlistId,
              title: title,
              artist: artist.isEmpty ? 'Artista' : artist,
              thumbnailUrl: thumbnailUrl,
            ),
          );
        }
      }

      return _ArtistProfileCacheEntry(
        schemaVersion: _artistSessionCacheSchemaVersion,
        videos: restoredVideos,
        suggestedAlbum: suggestedAlbum,
        artistAlbums: albums,
        albumsResolved: map['albumsResolved'] == true,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeArtistPersistentCache(
    _ArtistProfileCacheEntry entry,
  ) async {
    try {
      final box = await Hive.openBox<String>(_artistPersistentCacheBoxName);
      await _pruneArtistPersistentCache(box);
      final payload = jsonEncode({
        'savedAtMs': DateTime.now().millisecondsSinceEpoch,
        'videos': entry.videos
            .take(80)
            .map((video) => _CachedVideoSnapshot.fromVideo(video).toMap())
            .toList(growable: false),
        'suggestedAlbum': entry.suggestedAlbum == null
            ? null
            : {
                'playlistId': entry.suggestedAlbum!.playlistId,
                'title': entry.suggestedAlbum!.title,
                'artist': entry.suggestedAlbum!.artist,
                'thumbnailUrl': entry.suggestedAlbum!.thumbnailUrl,
              },
        'artistAlbums': entry.artistAlbums
            .take(20)
            .map(
              (album) => {
                'playlistId': album.playlistId,
                'title': album.title,
                'artist': album.artist,
                'thumbnailUrl': album.thumbnailUrl,
              },
            )
            .toList(growable: false),
        'albumsResolved': entry.albumsResolved,
      });
      await box.put(_artistCacheKey, payload);
    } catch (_) {
      // Best effort.
    }
  }

  Future<void> _pruneArtistPersistentCache(Box<String> box) async {
    try {
      final entries = <({String key, int savedAtMs})>[];
      for (final key in box.keys.cast<dynamic>()) {
        final k = key.toString();
        final raw = box.get(k);
        if (raw == null || raw.isEmpty) continue;
        try {
          final decoded = jsonDecode(raw);
          if (decoded is! Map) continue;
          final map = Map<String, dynamic>.from(
            decoded.cast<dynamic, dynamic>(),
          );
          final savedAtMs = (map['savedAtMs'] as num?)?.toInt() ?? 0;
          if (savedAtMs > 0) {
            entries.add((key: k, savedAtMs: savedAtMs));
          }
        } catch (_) {}
      }
      entries.sort((a, b) => b.savedAtMs.compareTo(a.savedAtMs));
      final now = DateTime.now();
      for (final item in entries.skip(_artistPersistentCacheMaxEntries)) {
        await box.delete(item.key);
      }
      for (final item in entries) {
        final savedAt = DateTime.fromMillisecondsSinceEpoch(item.savedAtMs);
        if (now.difference(savedAt) > _artistPersistentCacheTtl) {
          await box.delete(item.key);
        }
      }
    } catch (_) {
      // Best effort.
    }
  }

  Future<void> _loadChannelVideos() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final allUploads = await _fetchChannelVideosWithFallback();
      final selected = _prioritizePopularVideos(allUploads);
      if (!mounted) return;
      setState(() {
        _videos = selected;
        _loading = false;
      });
      unawaited(_loadArtistProfileVideosFromYouTubeMusic());
      unawaited(_loadArtistTopSongsFromYouTubeMusic());
      _storeArtistCache(albumsResolved: false);
      unawaited(_loadSuggestedAlbumForArtist());
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = true;
        _loading = false;
      });
    }
  }

  Future<List<Video>> _fetchChannelVideosWithFallback() async {
    // Ejecutamos ambas fuentes en paralelo para obtener resultados más rápido.
    final fromPageFuture = _fetchUploadsFromPageFast();
    final fromPlaylistFuture = _fetchUploadsPlaylistFast();

    final first = await Future.any<(String, List<Video>)>([
      fromPageFuture.then((videos) => ('page', videos)),
      fromPlaylistFuture.then((videos) => ('playlist', videos)),
    ]);

    if (first.$2.isNotEmpty) return first.$2;

    final second = first.$1 == 'page'
        ? await fromPlaylistFuture
        : await fromPageFuture;
    if (second.isNotEmpty) return second;

    // 3) Fallback por busqueda del nombre del canal/topic
    final searchFallback = await _searchMusicByChannelName();
    return searchFallback;
  }

  Future<List<Video>> _fetchUploadsFromPageFast() async {
    try {
      final uploads = await _runYoutubeWithRetry(
        () => _yt.channels.getUploadsFromPage(
          widget.channelId,
          videoSorting: VideoSorting.newest,
          videoType: VideoType.normal,
        ),
        maxAttempts: 1,
      ).timeout(_channelFetchTimeout);
      return uploads.toList();
    } catch (_) {
      return const <Video>[];
    }
  }

  Future<List<Video>> _fetchUploadsPlaylistFast() async {
    try {
      final streamResult = await _runYoutubeWithRetry(
        () => _yt.channels.getUploads(widget.channelId).take(80).toList(),
        maxAttempts: 1,
      ).timeout(_channelFetchTimeout);
      return streamResult;
    } catch (_) {
      return const <Video>[];
    }
  }

  Future<List<Video>> _searchMusicByChannelName() async {
    final normalizedName = widget.channelName
        .replaceAll('- Topic', '')
        .replaceAll('Topic', '')
        .trim();
    final queries = <String>[
      '$normalizedName topic',
      '$normalizedName official audio',
      '$normalizedName music video',
    ];
    final collected = <Video>[];
    final seenIds = <String>{};
    for (final query in queries) {
      try {
        final result = await _runYoutubeWithRetry(
          () => _yt.search.search(query),
          maxAttempts: 1,
        ).timeout(_channelFetchTimeout);
        for (final item in result.take(20)) {
          if (!_looksLikeMusic(item)) continue;
          if (seenIds.add(item.id.value)) {
            collected.add(item);
          }
          if (collected.length >= 40) {
            return collected;
          }
        }
      } catch (_) {}
    }
    return collected;
  }

  Future<void> _loadArtistProfileVideosFromYouTubeMusic() async {
    final query = _artistDisplayName.trim().isNotEmpty
        ? _artistDisplayName.trim()
        : widget.channelName.trim();
    if (query.isEmpty) return;
    setState(() {
      _artistProfileVideosLoading = true;
    });
    final resolved = await _fetchArtistProfileVideosFromYouTubeMusic(query);
    if (!mounted) return;
    final filtered = (resolved.length > 5) ? resolved.sublist(5) : <Video>[];
    setState(() {
      _artistProfileVideos = filtered;
      _artistProfileVideosLoading = false;
    });
  }

  Future<void> _loadArtistTopSongsFromYouTubeMusic() async {
    final query = _artistDisplayName.trim().isNotEmpty
        ? _artistDisplayName.trim()
        : widget.channelName.trim();
    if (query.isEmpty) return;
    final loadEpoch = ++_artistTopSongsLoadEpoch;
    setState(() {
      _artistTopSongsLoading = true;
    });
    final resolved = await _fetchArtistTopSongsFromYouTubeMusic(query);
    if (!mounted || loadEpoch != _artistTopSongsLoadEpoch) return;

    // Fase 1: pintamos rápido el top corto de YT Music.
    setState(() {
      _artistTopSongs = resolved.songs;
      _artistTopSongsShowAllPlaylistId = resolved.showAllPlaylistId;
    });

    // Fase 2: expandimos con "Show all" en background para reemplazar por lista completa.
    final playlistId = (resolved.showAllPlaylistId ?? '').trim();
    if (playlistId.isNotEmpty) {
      try {
        final full = await _runYoutubeWithRetry(
          () => _yt.playlists.getVideos(PlaylistId(playlistId)).take(250).toList(),
          maxAttempts: 1,
        );
        if (!mounted || loadEpoch != _artistTopSongsLoadEpoch) return;
        if (full.isNotEmpty) {
          setState(() {
            _artistTopSongs = full;
          });
        }
      } catch (_) {
        // Best effort.
      }
    }

    if (!mounted || loadEpoch != _artistTopSongsLoadEpoch) return;
    setState(() {
      _artistTopSongsLoading = false;
    });
  }

  bool _isTopSongsShelfTitle(String shelfTitle) {
    final title = _normalizeAlbumSearchText(shelfTitle);
    if (title.isEmpty) return false;
    return title == 'top songs' ||
        title == 'top canciones' ||
        title.contains('top songs') ||
        title.contains('top canciones') ||
        title.contains('canciones populares') ||
        title.contains('popular songs');
  }

  bool _isVideosShelfTitle(String shelfTitle) {
    final title = _normalizeAlbumSearchText(shelfTitle);
    if (title.isEmpty) return false;
    return title == 'videos' ||
        title.contains('videos') ||
        title.contains('music videos') ||
        title.contains('videoclips');
  }

  Future<Map<String, dynamic>?> _fetchYoutubeMusicBrowsePayloadForArtistVideos(
    String browseId,
  ) async {
    final normalizedBrowseId = browseId.trim();
    if (normalizedBrowseId.isEmpty) return null;
    final client = HttpClient();
    try {
      final req = await client.postUrl(
        Uri.parse(_youtubeiMusicBrowseEndpointForArtistVideos),
      );
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      req.headers.set(
        HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
      );
      req.headers.set('Origin', 'https://music.youtube.com');
      req.headers.set(
        'Referer',
        'https://music.youtube.com/browse/$normalizedBrowseId',
      );
      req.headers.set('X-Youtube-Client-Name', '67');
      req.headers.set('X-Youtube-Client-Version', '1.20240226.01.00');
      req.add(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'browseId': normalizedBrowseId,
            'context': {
              'client': {
                'clientName': 'WEB_REMIX',
                'clientVersion': '1.20240226.01.00',
                'hl': 'es',
                'gl': 'US',
              },
              'request': {'useSsl': true},
            },
            'contentCheckOk': true,
            'racyCheckOk': true,
          }),
        ),
      );
      final res = await req.close();
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final body = await utf8.decoder.bind(res).join();
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded.cast<dynamic, dynamic>());
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  String? _extractFirstArtistBrowseId(dynamic node, {int depth = 0}) {
    if (depth > 20 || node == null) return null;
    final targetArtist = _normalizeAlbumSearchText(_artistDisplayName);
    if (node is Map) {
      final browseEndpoint = node['browseEndpoint'];
      if (browseEndpoint is Map) {
        final browseId = (browseEndpoint['browseId'] ?? '').toString().trim();
        final pageType = _extractPageTypeFromNode(node);
        if (browseId.isNotEmpty && pageType.contains('ARTIST')) {
          return browseId;
        }
      }
      final renderer = node['musicResponsiveListItemRenderer'];
      if (renderer is Map) {
        final title = _normalizeAlbumSearchText(
          _extractYouTubeText(
            (renderer['flexColumns'] is List &&
                    (renderer['flexColumns'] as List).isNotEmpty)
                ? ((renderer['flexColumns'] as List).first
                      as Map?)?['musicResponsiveListItemFlexColumnRenderer']?['text']
                : null,
          ),
        );
        final browseId =
            ((((renderer['navigationEndpoint'] as Map?)?['browseEndpoint']
                        as Map?)?['browseId']) ??
                    '')
                .toString()
                .trim();
        final pageType = _extractPageTypeFromNode(renderer);
        final hasArtistSignal =
            pageType.contains('ARTIST') ||
            title == targetArtist ||
            title.contains(targetArtist) ||
            (targetArtist.isNotEmpty && targetArtist.contains(title));
        if (browseId.isNotEmpty && hasArtistSignal) {
          return browseId;
        }
        // Fallback: si el renderer parece de artista pero no coincide exacto
        // (acentos/normalizacion rara), usamos su primer browseId.
        if (browseId.isNotEmpty && pageType.contains('ARTIST')) return browseId;
      }
      for (final value in node.values) {
        final nested = _extractFirstArtistBrowseId(value, depth: depth + 1);
        if (nested != null && nested.isNotEmpty) return nested;
      }
    } else if (node is List) {
      for (final value in node) {
        final nested = _extractFirstArtistBrowseId(value, depth: depth + 1);
        if (nested != null && nested.isNotEmpty) return nested;
      }
    }
    return null;
  }

  List<String> _artistQueryVariantsForBrowseId(String query) {
    final raw = query.replaceAll(RegExp(r'\s+'), ' ').trim();
    final normalized = _normalizeAlbumSearchText(raw);
    return <String>{raw, normalized}.where((q) => q.isNotEmpty).toList();
  }

  Future<String?> _resolveArtistBrowseIdForProfile(String query) async {
    final targetNormalized = _normalizeAlbumSearchText(_artistDisplayName);
    final variants = _artistQueryVariantsForBrowseId(query);

    // 1) Prioridad: filtro de Artistas en YT Music.
    for (final variant in variants) {
      for (final params in _youtubeMusicArtistsFilterParamsCandidates) {
        final payload = await _fetchYoutubeMusicSearchPayloadForAlbums(
          variant,
          paramsOverride: params,
        );
        final browseId = _extractFirstArtistBrowseId(payload);
        if (browseId != null && browseId.isNotEmpty) return browseId;
      }
    }

    // 2) Fallback: búsqueda general con variante exacta y normalizada.
    for (final variant in variants) {
      final initialPayload = await _fetchYoutubeMusicSearchInitialDataForAlbums(
        variant,
      );
      final searchPayload = await _fetchYoutubeMusicSearchPayloadForAlbums(
        variant,
      );
      final browseId =
          _extractFirstArtistBrowseId(initialPayload) ??
          _extractFirstArtistBrowseId(searchPayload);
      if (browseId != null && browseId.isNotEmpty) return browseId;
    }

    // 3) Último fallback: nombre del artista de la cabecera.
    if (targetNormalized.isNotEmpty) {
      for (final params in _youtubeMusicArtistsFilterParamsCandidates) {
        final payload = await _fetchYoutubeMusicSearchPayloadForAlbums(
          targetNormalized,
          paramsOverride: params,
        );
        final browseId = _extractFirstArtistBrowseId(payload);
        if (browseId != null && browseId.isNotEmpty) return browseId;
      }
    }

    return null;
  }

  List<Map<String, dynamic>> _extractMusicCarouselShelfRenderers(
    dynamic node, {
    int depth = 0,
  }) {
    if (depth > 20 || node == null) return const <Map<String, dynamic>>[];
    final out = <Map<String, dynamic>>[];
    if (node is Map) {
      final shelf = node['musicCarouselShelfRenderer'];
      if (shelf is Map) {
        out.add(Map<String, dynamic>.from(shelf.cast<dynamic, dynamic>()));
      }
      for (final value in node.values) {
        out.addAll(
          _extractMusicCarouselShelfRenderers(value, depth: depth + 1),
        );
      }
      return out;
    }
    if (node is List) {
      for (final value in node) {
        out.addAll(
          _extractMusicCarouselShelfRenderers(value, depth: depth + 1),
        );
      }
    }
    return out;
  }

  void _collectMusicResponsiveListItemRenderersForArtistVideos(
    dynamic node,
    List<Map<String, dynamic>> out, {
    int depth = 0,
  }) {
    if (depth > 20 || node == null) return;
    if (node is Map) {
      final responsive = node['musicResponsiveListItemRenderer'];
      if (responsive is Map) {
        out.add(Map<String, dynamic>.from(responsive.cast<dynamic, dynamic>()));
      }
      final twoRow = node['musicTwoRowItemRenderer'];
      if (twoRow is Map) {
        out.add(Map<String, dynamic>.from(twoRow.cast<dynamic, dynamic>()));
      }
      for (final value in node.values) {
        _collectMusicResponsiveListItemRenderersForArtistVideos(
          value,
          out,
          depth: depth + 1,
        );
      }
      return;
    }
    if (node is List) {
      for (final value in node) {
        _collectMusicResponsiveListItemRenderersForArtistVideos(
          value,
          out,
          depth: depth + 1,
        );
      }
    }
  }

  String? _extractArtistProfileVideoId(dynamic node, {int depth = 0}) {
    if (depth > 16 || node == null) return null;
    if (node is Map) {
      final direct = node['videoId'];
      if (direct is String && direct.trim().isNotEmpty) return direct.trim();
      final watchEndpoint = node['watchEndpoint'];
      if (watchEndpoint is Map) {
        final nested = watchEndpoint['videoId'];
        if (nested is String && nested.trim().isNotEmpty) return nested.trim();
      }
      for (final value in node.values) {
        final nested = _extractArtistProfileVideoId(value, depth: depth + 1);
        if (nested != null && nested.isNotEmpty) return nested;
      }
    } else if (node is List) {
      for (final value in node) {
        final nested = _extractArtistProfileVideoId(value, depth: depth + 1);
        if (nested != null && nested.isNotEmpty) return nested;
      }
    }
    return null;
  }

  Future<List<Video>> _fetchArtistProfileVideosFromYouTubeMusic(
    String query,
  ) async {
    try {
      final artistBrowseId = await _resolveArtistBrowseIdForProfile(query);
      if (artistBrowseId == null || artistBrowseId.isEmpty) {
        return const <Video>[];
      }
      final profilePayload =
          await _fetchYoutubeMusicBrowsePayloadForArtistVideos(artistBrowseId);
      if (profilePayload == null) return const <Video>[];
      final listShelves = _extractMusicShelfRenderers(profilePayload);
      final carouselShelves = _extractMusicCarouselShelfRenderers(
        profilePayload,
      );
      final videosShelves = [...listShelves, ...carouselShelves]
          .where((shelf) {
            final shelfTitle = _extractYouTubeText(shelf['title']);
            return _isVideosShelfTitle(shelfTitle);
          })
          .toList(growable: false);
      final results = <Video>[];
      final seenIds = <String>{};
      for (final shelf in videosShelves) {
        final renderers = <Map<String, dynamic>>[];
        _collectMusicResponsiveListItemRenderersForArtistVideos(
          shelf,
          renderers,
        );
        for (final renderer in renderers) {
          final videoId = _extractArtistProfileVideoId(renderer);
          if (videoId == null || videoId.isEmpty || !seenIds.add(videoId)) {
            continue;
          }
          final title = _extractAlbumTitleFromRendererNode(renderer);
          final artist = _extractAlbumArtistFromRendererNode(renderer).trim();
          results.add(
            _CachedVideoSnapshot(
              videoId: videoId,
              title: title.isEmpty ? 'Video' : title,
              author: artist.isEmpty ? _artistDisplayName : artist,
              channelId: widget.channelId,
              description: '',
              durationMs: null,
              viewCount: 0,
              uploadDateMs: null,
              publishDateMs: null,
              isLive: false,
            ).toVideo(),
          );
        }
      }
      if (results.isNotEmpty) return results;

      // Fallback robusto: algunas respuestas no etiquetan bien la shelf de
      // videos, así que tomamos todos los renderers del perfil y filtramos por
      // aquellos que sí contienen videoId/watchEndpoint.
      final fallbackRenderers = <Map<String, dynamic>>[];
      _collectMusicResponsiveListItemRenderersForArtistVideos(
        profilePayload,
        fallbackRenderers,
      );
      for (final renderer in fallbackRenderers) {
        final videoId = _extractArtistProfileVideoId(renderer);
        if (videoId == null || videoId.isEmpty || !seenIds.add(videoId)) {
          continue;
        }
        final title = _extractAlbumTitleFromRendererNode(renderer);
        final artist = _extractAlbumArtistFromRendererNode(renderer).trim();
        results.add(
          _CachedVideoSnapshot(
            videoId: videoId,
            title: title.isEmpty ? 'Video' : title,
            author: artist.isEmpty ? _artistDisplayName : artist,
            channelId: widget.channelId,
            description: '',
            durationMs: null,
            viewCount: 0,
            uploadDateMs: null,
            publishDateMs: null,
            isLive: false,
          ).toVideo(),
        );
      }
      return results;
    } catch (_) {
      return const <Video>[];
    }
  }

  Future<({List<Video> songs, String? showAllPlaylistId})>
  _fetchArtistTopSongsFromYouTubeMusic(String query) async {
    try {
      final artistBrowseId = await _resolveArtistBrowseIdForProfile(query);
      if (artistBrowseId == null || artistBrowseId.isEmpty) {
        return (songs: const <Video>[], showAllPlaylistId: null);
      }
      final profilePayload =
          await _fetchYoutubeMusicBrowsePayloadForArtistVideos(artistBrowseId);
      if (profilePayload == null) {
        return (songs: const <Video>[], showAllPlaylistId: null);
      }
      final listShelves = _extractMusicShelfRenderers(profilePayload);
      final carouselShelves = _extractMusicCarouselShelfRenderers(
        profilePayload,
      );
      final topSongsShelves = [...listShelves, ...carouselShelves]
          .where((shelf) => _isTopSongsShelfTitle(_extractYouTubeText(shelf['title'])))
          .toList(growable: false);
      String? showAllPlaylistId;
      for (final shelf in topSongsShelves) {
        final candidates = _extractPlaylistIdsFromNode(shelf);
        final picked = _pickBestPlayablePlaylistId(candidates);
        if (picked != null && picked.trim().isNotEmpty) {
          showAllPlaylistId = picked.trim();
          break;
        }
      }
      final results = <Video>[];
      final seenIds = <String>{};
      for (final shelf in topSongsShelves) {
        final renderers = <Map<String, dynamic>>[];
        _collectMusicResponsiveListItemRenderersForArtistVideos(
          shelf,
          renderers,
        );
        for (final renderer in renderers) {
          final videoId = _extractArtistProfileVideoId(renderer);
          if (videoId == null || videoId.isEmpty || !seenIds.add(videoId)) {
            continue;
          }
          final title = _extractAlbumTitleFromRendererNode(renderer);
          final artist = _extractAlbumArtistFromRendererNode(renderer).trim();
          results.add(
            _CachedVideoSnapshot(
              videoId: videoId,
              title: title.isEmpty ? 'Canción' : title,
              author: artist.isEmpty ? _artistDisplayName : artist,
              channelId: widget.channelId,
              description: '',
              durationMs: null,
              viewCount: 0,
              uploadDateMs: null,
              publishDateMs: null,
              isLive: false,
            ).toVideo(),
          );
        }
      }
      return (songs: results, showAllPlaylistId: showAllPlaylistId);
    } catch (_) {
      return (songs: const <Video>[], showAllPlaylistId: null);
    }
  }

  List<Video> _prioritizePopularVideos(List<Video> source) {
    final topic = <Video>[];
    final music = <Video>[];
    final others = <Video>[];
    final seenIds = <String>{};

    for (final video in source) {
      final id = video.id.value;
      if (!seenIds.add(id)) continue;
      if (_isTopicVideo(video)) {
        topic.add(video);
      } else if (_looksLikeMusic(video)) {
        music.add(video);
      } else {
        others.add(video);
      }
    }

    topic.sort(
      (a, b) => b.engagement.viewCount.compareTo(a.engagement.viewCount),
    );
    music.sort(
      (a, b) => b.engagement.viewCount.compareTo(a.engagement.viewCount),
    );
    others.sort(
      (a, b) => b.engagement.viewCount.compareTo(a.engagement.viewCount),
    );

    return [...topic, ...music, ...others];
  }

  bool _looksLikeMusic(Video video) {
    final title = '${video.title} ${video.author}'.toLowerCase();
    const keywords = [
      'official audio',
      'audio',
      'lyric',
      'lyrics',
      'music video',
      'vevo',
      'topic',
      'official video',
      'visualizer',
      'live',
      'session',
      'en vivo',
      'acoustic',
      'remix',
    ];
    return keywords.any(title.contains);
  }

  bool _isTopicVideo(Video video) {
    final author = video.author.toLowerCase().trim();
    return author.endsWith('- topic') || author.endsWith('topic');
  }

  String get _artistDisplayName {
    return widget.channelName
        .replaceAll(RegExp(r'\s*[-–—]\s*topic$', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s+topic$', caseSensitive: false), '')
        .trim();
  }

  List<String> _artistAlbumSearchQueries() {
    final profileDisplayName = _artistDisplayName.trim();
    final profileRawName = widget.channelName.trim();
    final normalized = cleanArtistName(widget.channelName);
    final withoutTopic = normalized
        .replaceAll(RegExp(r'\s*[-–—]\s*topic$', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s+topic$', caseSensitive: false), '')
        .trim();
    final display = profileDisplayName;
    final exactLiteral = profileDisplayName.isNotEmpty
        ? '"$profileDisplayName"'
        : '';
    final rawLiteral = profileRawName.isNotEmpty ? '"$profileRawName"' : '';
    final displayNoAccents = _foldBasicAccents(profileDisplayName).trim();
    final rawNoAccents = _foldBasicAccents(profileRawName).trim();
    final normalizedNoAccents = _foldBasicAccents(normalized).trim();
    final withoutTopicNoAccents = _foldBasicAccents(withoutTopic).trim();
    final displayNoAccentsLiteral = displayNoAccents.isNotEmpty
        ? '"$displayNoAccents"'
        : '';
    final rawNoAccentsLiteral = rawNoAccents.isNotEmpty
        ? '"$rawNoAccents"'
        : '';
    final values = <String>[
      profileDisplayName,
      exactLiteral,
      profileRawName,
      rawLiteral,
      displayNoAccents,
      displayNoAccentsLiteral,
      rawNoAccents,
      rawNoAccentsLiteral,
      display,
      withoutTopic,
      withoutTopicNoAccents,
      normalized.trim(),
      normalizedNoAccents,
      widget.channelName.trim(),
    ];
    final out = <String>[];
    final seen = <String>{};
    for (final value in values) {
      final q = value.trim();
      if (q.isEmpty) continue;
      final key = _foldBasicAccents(q).toLowerCase();
      if (seen.add(key)) out.add(q);
    }
    return out;
  }

  String _foldBasicAccents(String value) {
    const map = <String, String>{
      'á': 'a',
      'à': 'a',
      'ä': 'a',
      'â': 'a',
      'ã': 'a',
      'å': 'a',
      'é': 'e',
      'è': 'e',
      'ë': 'e',
      'ê': 'e',
      'í': 'i',
      'ì': 'i',
      'ï': 'i',
      'î': 'i',
      'ó': 'o',
      'ò': 'o',
      'ö': 'o',
      'ô': 'o',
      'õ': 'o',
      'ú': 'u',
      'ù': 'u',
      'ü': 'u',
      'û': 'u',
      'ñ': 'n',
      'ç': 'c',
    };
    final out = StringBuffer();
    for (final rune in value.runes) {
      final char = String.fromCharCode(rune);
      out.write(map[char] ?? char);
    }
    return out.toString();
  }

  String _strictArtistKey(String value) {
    final folded = _foldBasicAccents(cleanArtistName(value).toLowerCase());
    return folded
        .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _compactArtistKeyForStrictProfileMatch(String value) {
    return _strictArtistKey(value).replaceAll(' ', '');
  }

  bool _isStrictSameArtistName({
    required String canonicalArtistKey,
    required String candidateArtistKey,
  }) {
    final canonicalCompact = _compactArtistKeyForStrictProfileMatch(
      canonicalArtistKey,
    );
    final candidateCompact = _compactArtistKeyForStrictProfileMatch(
      candidateArtistKey,
    );
    if (canonicalCompact.isEmpty || candidateCompact.isEmpty) return false;
    if (canonicalCompact == candidateCompact) return true;
    // Permite colaboraciones pegadas tipo "<artista>y<otro>".
    if (candidateCompact.startsWith('${canonicalCompact}y')) return true;
    // Permite colaboraciones pegadas tipo "<otro>y<artista>".
    if (candidateCompact.endsWith('y$canonicalCompact')) return true;
    return false;
  }

  Future<bool> _albumPlaylistMatchesArtist(
    _SearchAlbumResult album,
    String canonicalArtistKey,
  ) async {
    final playlistId = album.playlistId.trim();
    if (playlistId.isEmpty || canonicalArtistKey.isEmpty) return false;
    final cached = _albumPlaylistArtistMatchCache[playlistId];
    if (cached != null) return cached;

    try {
      // Validación estricta: usamos el autor real del playlist/álbum.
      final playlist = await _runYoutubeWithRetry(
        () => _yt.playlists.get(PlaylistId(playlistId)),
        maxAttempts: 1,
      );
      final playlistAuthorKey = _strictArtistKey(playlist.author);
      final fallbackAlbumArtistKey = _strictArtistKey(album.artist);
      final matches = playlistAuthorKey.isNotEmpty
          ? _isStrictSameArtistName(
              canonicalArtistKey: canonicalArtistKey,
              candidateArtistKey: playlistAuthorKey,
            )
          : _isStrictSameArtistName(
              canonicalArtistKey: canonicalArtistKey,
              candidateArtistKey: fallbackAlbumArtistKey,
            );

      _albumPlaylistArtistMatchCache[playlistId] = matches;
      return matches;
    } catch (_) {
      // Si falla red/API, no bloqueamos completamente:
      // conservamos el match estricto del metadato del resultado.
      final fallback = _isStrictSameArtistName(
        canonicalArtistKey: canonicalArtistKey,
        candidateArtistKey: _strictArtistKey(album.artist),
      );
      _albumPlaylistArtistMatchCache[playlistId] = fallback;
      return fallback;
    }
  }

  String get _headerImageUrl {
    if (widget.channelThumbnailUrl.isNotEmpty) {
      return widget.channelThumbnailUrl;
    }
    if (_videos.isNotEmpty) return bestThumbnailForVideo(_videos.first);
    return '';
  }

  Future<void> _loadSuggestedAlbumForArtist() async {
    final requestEpoch = ++_albumLoadEpoch;
    final queries = _artistAlbumSearchQueries();
    if (queries.isEmpty) return;
    if (mounted) {
      setState(() {
        _suggestedAlbumLoading = true;
        _artistAlbums = const <_SearchAlbumResult>[];
      });
    } else {
      _suggestedAlbumLoading = true;
      _artistAlbums = const <_SearchAlbumResult>[];
    }

    List<_SearchAlbumResult> ordered = const <_SearchAlbumResult>[];
    try {
      final seenPlaylistIds = <String>{};
      final merged = <_SearchAlbumResult>[];
      Future<List<_SearchAlbumResult>> loadAlbumsForQuery(String query) async {
        final local = <_SearchAlbumResult>[];
        final localSeen = <String>{};

        void collectFromPayload(Map<String, dynamic>? payload) {
          if (payload == null) return;
          final extracted = _extractAlbumsInYoutubeMusicOrder(payload);
          for (final album in extracted) {
            final id = album.playlistId.trim();
            if (id.isEmpty || !localSeen.add(id)) continue;
            local.add(album);
          }
        }

        final initialFuture = _fetchYoutubeMusicSearchInitialDataForAlbums(
          query,
        );
        final defaultFuture = _runYoutubeWithRetry(
          () => _fetchYoutubeMusicSearchPayloadForAlbums(query),
          maxAttempts: 1,
        );

        final pair = await Future.wait([initialFuture, defaultFuture]);
        collectFromPayload(pair[0]);
        collectFromPayload(pair[1]);

        if (local.isEmpty) {
          final albumsOnlyPayload = await _runYoutubeWithRetry(
            () => _fetchYoutubeMusicSearchPayloadForAlbums(
              query,
              albumsOnly: true,
            ),
            maxAttempts: 1,
          );
          collectFromPayload(albumsOnlyPayload);
        }
        return local;
      }

      for (var i = 0; i < queries.length; i += 3) {
        final batch = queries.skip(i).take(3).toList(growable: false);
        if (batch.isEmpty) break;
        final batchResults = await Future.wait(batch.map(loadAlbumsForQuery));
        for (final local in batchResults) {
          for (final album in local) {
            final id = album.playlistId.trim();
            if (id.isEmpty || !seenPlaylistIds.add(id)) continue;
            merged.add(album);
          }
        }
        // Salida temprana para mostrar albums antes.
        if (merged.length >= 10) break;
      }
      if (merged.isNotEmpty) {
        ordered = merged;
      } else if (queries.isNotEmpty) {
        final plainQuery = queries.first;
        final fallback = await loadAlbumsForQuery(plainQuery);
        if (fallback.isNotEmpty) {
          ordered = fallback;
        }
      }
    } catch (_) {
      ordered = const <_SearchAlbumResult>[];
    }

    // Fallback duro: reutiliza el motor general de búsqueda de álbumes
    // para evitar perfiles vacíos cuando los endpoints anteriores no responden
    // consistentemente para cierto artista.
    if (ordered.isEmpty) {
      final display = _artistDisplayName.trim();
      final noAccents = _foldBasicAccents(display).trim();
      final byId = <String, _SearchAlbumResult>{};
      final appQueries = <String>[
        if (display.isNotEmpty) display,
        if (noAccents.isNotEmpty &&
            noAccents.toLowerCase() != display.toLowerCase())
          noAccents,
      ];
      if (appQueries.isNotEmpty) {
        final appResults = await Future.wait(
          appQueries.map(_searchAlbumsFromAppEngine),
        );
        for (final list in appResults) {
          for (final album in list) {
            final id = album.playlistId.trim();
            if (id.isNotEmpty) byId[id] = album;
          }
        }
      }
      if (byId.isNotEmpty) {
        ordered = byId.values.toList(growable: false);
      }
    }

    final profileArtistCompact = _compactArtistKeyForStrictProfileMatch(
      _artistDisplayName,
    );
    final profileArtistKey = _strictArtistKey(_artistDisplayName);
    final filtered = <_SearchAlbumResult>[];
    final seenPlaylistIds = <String>{};
    for (final album in ordered) {
      final playlistId = album.playlistId.trim();
      if (playlistId.isEmpty || !seenPlaylistIds.add(playlistId)) continue;
      final albumArtistKey = _strictArtistKey(album.artist);
      if (profileArtistCompact.isEmpty || albumArtistKey.isEmpty) continue;
      if (_isStrictSameArtistName(
        canonicalArtistKey: _artistDisplayName,
        candidateArtistKey: albumArtistKey,
      )) {
        filtered.add(album);
      }
    }

    // Mostramos solo resultados con coincidencia estricta de artista.
    final quickResults = filtered.take(12).toList(growable: false);
    if (quickResults.isEmpty) {
      if (!mounted || requestEpoch != _albumLoadEpoch) return;
      setState(() {
        _artistAlbums = const <_SearchAlbumResult>[];
        _suggestedAlbum = null;
        _suggestedAlbumLoading = false;
      });
      _storeArtistCache(albumsResolved: true);
      return;
    }

    // Mostramos resultados de inmediato y verificamos en background
    // para que el perfil cargue más rápido.
    if (!mounted || requestEpoch != _albumLoadEpoch) return;
    setState(() {
      _artistAlbums = quickResults;
      _suggestedAlbum = quickResults.isNotEmpty ? quickResults.first : null;
      _suggestedAlbumLoading = false;
    });
    _storeArtistCache(albumsResolved: false);

    unawaited(() async {
      final verification = await Future.wait(
        quickResults.take(8).map((album) async {
          final matches = await _albumPlaylistMatchesArtist(
            album,
            profileArtistKey,
          );
          return (album: album, matches: matches);
        }),
      );

      if (!mounted || requestEpoch != _albumLoadEpoch) return;
      final verified = <_SearchAlbumResult>[
        for (final item in verification)
          if (item.matches) item.album,
      ];
      final finalResults = verified.isNotEmpty ? verified : quickResults;
      setState(() {
        _artistAlbums = finalResults;
        _suggestedAlbum = finalResults.isNotEmpty ? finalResults.first : null;
      });
      _storeArtistCache(albumsResolved: true);
    }());
  }

  void _openSuggestedAlbum(_SearchAlbumResult album) {
    if (!mounted) return;
    setState(() {
      _albumTransitionDirection = 1;
      _selectedAlbumView = _SelectedAlbumView(
        playlistId: album.playlistId,
        albumTitle: album.title,
        artistName: album.artist,
        seedThumbnailUrl: album.thumbnailUrl,
      );
    });
  }

  Widget _buildSuggestedAlbumSection(BuildContext context) {
    final album = _suggestedAlbum;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: _artistSectionHorizontalInset,
            ),
            child: Text(
              'Álbum sugerido',
              style: const TextStyle(
                fontFamily: '.SF Pro Text',
                fontWeight: FontWeight.w800,
                fontSize: 24,
                letterSpacing: -0.2,
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (_suggestedAlbumLoading)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 6, 16, 10),
              child: SizedBox(
                height: 82,
                child: Center(child: CupertinoActivityIndicator(radius: 12)),
              ),
            )
          else if (album != null)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: _artistSectionHorizontalInset,
              ),
              child: _buildSuggestedAlbumArtistStyleCard(
                context,
                album,
                onTap: () => _openSuggestedAlbum(album),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: _artistSectionHorizontalInset,
              ),
              child: Text(
                'Sin álbum sugerido por ahora.',
                style: TextStyle(
                  fontFamily: '.SF Pro Text',
                  fontSize: 13,
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildArtistAlbumCard(
    BuildContext context,
    _SearchAlbumResult album, {
    required VoidCallback onTap,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark
        ? Colors.black
        : CupertinoColors.secondarySystemGroupedBackground.resolveFrom(context);
    final cardBorder = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : CupertinoColors.separator
              .resolveFrom(context)
              .withValues(alpha: 0.12);
    final fallback = Container(
      width: 142,
      height: 142,
      decoration: BoxDecoration(
        color: CupertinoColors.tertiarySystemFill.resolveFrom(context),
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: Icon(
        CupertinoIcons.music_albums_fill,
        size: 34,
        color: CupertinoColors.secondaryLabel.resolveFrom(context),
      ),
    );

    return SizedBox(
      width: 162,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Material(
          color: cardColor,
          surfaceTintColor: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            child: Container(
              decoration: BoxDecoration(
                color: cardColor,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: cardBorder, width: 0.6),
              ),
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  album.thumbnailUrl.isNotEmpty
                      ? SquareThumbnail.network(
                          imageUrl: album.thumbnailUrl,
                          size: 142,
                          borderRadius: 10,
                          fallback: fallback,
                        )
                      : fallback,
                  const SizedBox(height: 10),
                  Text(
                    album.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: '.SF Pro Text',
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    album.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: '.SF Pro Text',
                      fontSize: 12,
                      color: CupertinoColors.secondaryLabel.resolveFrom(
                        context,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSuggestedAlbumArtistStyleCard(
    BuildContext context,
    _SearchAlbumResult album, {
    required VoidCallback onTap,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark
        ? const Color(0xFF0B0B0B)
        : CupertinoColors.secondarySystemGroupedBackground.resolveFrom(context);
    final cardBorder = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : CupertinoColors.separator
              .resolveFrom(context)
              .withValues(alpha: 0.14);
    final coverCachePx = (72 * MediaQuery.devicePixelRatioOf(context))
        .round()
        .clamp(96, 640)
        .toInt();
    final fallback = Container(
      width: 72,
      height: 72,
      decoration: BoxDecoration(
        color: CupertinoColors.tertiarySystemFill.resolveFrom(context),
        borderRadius: BorderRadius.circular(12),
      ),
      alignment: Alignment.center,
      child: Icon(
        CupertinoIcons.music_albums_fill,
        size: 30,
        color: CupertinoColors.secondaryLabel.resolveFrom(context),
      ),
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Material(
        color: cardColor,
        surfaceTintColor: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: cardBorder, width: 0.8),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  (isDark ? Colors.white : Colors.black).withValues(
                    alpha: 0.06,
                  ),
                  (isDark ? Colors.white : Colors.black).withValues(
                    alpha: 0.02,
                  ),
                ],
              ),
            ),
            child: Row(
              children: [
                album.thumbnailUrl.isNotEmpty
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.network(
                          album.thumbnailUrl,
                          width: 72,
                          height: 72,
                          fit: BoxFit.cover,
                          alignment: Alignment.center,
                          cacheWidth: coverCachePx,
                          cacheHeight: coverCachePx,
                          filterQuality: FilterQuality.low,
                          errorBuilder: (context, error, stackTrace) =>
                              fallback,
                        ),
                      )
                    : fallback,
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        album.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: CupertinoTheme.of(context).textTheme.textStyle
                            .copyWith(
                              fontSize: 24,
                              fontWeight: FontWeight.w700,
                              color: CupertinoColors.label.resolveFrom(context),
                            ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        album.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: CupertinoTheme.of(context).textTheme.textStyle
                            .copyWith(
                              fontSize: 13,
                              color: CupertinoColors.secondaryLabel.resolveFrom(
                                context,
                              ),
                            ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Álbum sugerido',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: CupertinoTheme.of(context).textTheme.textStyle
                            .copyWith(
                              fontSize: 13,
                              color: CupertinoColors.secondaryLabel.resolveFrom(
                                context,
                              ),
                            ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.chevron_right_rounded,
                  color: CupertinoColors.tertiaryLabel.resolveFrom(context),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildArtistAlbumsSection(BuildContext context) {
    final suggestedPlaylistId = _suggestedAlbum?.playlistId.trim() ?? '';
    final albumsWithoutSuggested = suggestedPlaylistId.isEmpty
        ? _artistAlbums
        : _artistAlbums
              .where((album) => album.playlistId.trim() != suggestedPlaylistId)
              .toList(growable: false);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: _artistSectionHorizontalInset,
            ),
            child: Text(
              'Álbumes y EP´s',
              style: const TextStyle(
                fontFamily: '.SF Pro Text',
                fontWeight: FontWeight.w800,
                fontSize: 24,
                letterSpacing: -0.2,
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (_suggestedAlbumLoading && albumsWithoutSuggested.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 2, 16, 12),
              child: SizedBox(
                height: 118,
                child: Center(child: CupertinoActivityIndicator(radius: 12)),
              ),
            )
          else if (albumsWithoutSuggested.isNotEmpty)
            SizedBox(
              height: 222,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(
                  horizontal: _artistSectionHorizontalInset,
                ),
                scrollDirection: Axis.horizontal,
                itemCount: albumsWithoutSuggested.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, index) {
                  final album = albumsWithoutSuggested[index];
                  return _buildArtistAlbumCard(
                    context,
                    album,
                    onTap: () => _openSuggestedAlbum(album),
                  );
                },
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: _artistSectionHorizontalInset,
              ),
              child: Text(
                'Sin álbumes disponibles por ahora.',
                style: TextStyle(
                  fontFamily: '.SF Pro Text',
                  fontSize: 13,
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildArtistVideosSection(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark
        ? Colors.black
        : CupertinoColors.secondarySystemGroupedBackground.resolveFrom(context);
    final cardBorder = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : CupertinoColors.separator
              .resolveFrom(context)
              .withValues(alpha: 0.12);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: _artistSectionHorizontalInset,
            ),
            child: Text(
              'Videos',
              style: TextStyle(
                fontFamily: '.SF Pro Text',
                fontWeight: FontWeight.w800,
                fontSize: 24,
                letterSpacing: -0.2,
                color: isDark ? Colors.white : Colors.black,
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (_artistProfileVideosLoading)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 20),
              child: SizedBox(
                height: 120,
                child: Center(child: CupertinoActivityIndicator(radius: 12)),
              ),
            )
          else if (_artistProfileVideos.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: _artistSectionHorizontalInset,
              ),
              child: Text(
                'Sin videos disponibles por ahora.',
                style: TextStyle(
                  fontFamily: '.SF Pro Text',
                  fontSize: 13,
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
              ),
            )
          else
            SizedBox(
              height: 218,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(
                  horizontal: _artistSectionHorizontalInset,
                ),
                scrollDirection: Axis.horizontal,
                itemCount: _artistProfileVideos.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, index) {
                  final video = _artistProfileVideos[index];
                  final thumbUrl = _bestQualityThumbnail(video);
                  final thumbCacheWidth =
                      (280 * MediaQuery.devicePixelRatioOf(context))
                          .round()
                          .clamp(360, 1400)
                          .toInt();
                  final fallback = Container(
                    decoration: BoxDecoration(
                      color: CupertinoColors.tertiarySystemFill.resolveFrom(
                        context,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      CupertinoIcons.play_rectangle_fill,
                      size: 34,
                      color: CupertinoColors.secondaryLabel.resolveFrom(
                        context,
                      ),
                    ),
                  );

                  return SizedBox(
                    width: 280,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Material(
                        color: cardColor,
                        surfaceTintColor: Colors.transparent,
                        child: InkWell(
                          onTap: () => _playVideoPreferLocal(
                            video,
                            forceVideoPlayback: true,
                          ),
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: cardBorder, width: 0.6),
                            ),
                            padding: const EdgeInsets.all(10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                AspectRatio(
                                  aspectRatio: 16 / 9,
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: thumbUrl.isNotEmpty
                                        ? Image.network(
                                            thumbUrl,
                                            fit: BoxFit.cover,
                                            cacheWidth: thumbCacheWidth,
                                            filterQuality: FilterQuality.low,
                                            errorBuilder:
                                                (context, error, stackTrace) =>
                                                    fallback,
                                          )
                                        : fallback,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  video.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontFamily: '.SF Pro Text',
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: CupertinoColors.label.resolveFrom(
                                      context,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  cleanArtistName(video.author),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontFamily: '.SF Pro Text',
                                    fontSize: 12,
                                    color: CupertinoColors.secondaryLabel
                                        .resolveFrom(context),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  List<List<Video>> _buildTopSongColumns(List<Video> source) {
    if (source.isEmpty) return const [];
    final columns = <List<Video>>[];
    const itemsPerColumn = 4;
    for (var index = 0; index < source.length; index += itemsPerColumn) {
      final chunk = <Video>[source[index]];
      for (var offset = 1; offset < itemsPerColumn; offset++) {
        final nextIndex = index + offset;
        if (nextIndex >= source.length) break;
        chunk.add(source[nextIndex]);
      }
      columns.add(chunk);
    }
    return columns;
  }

  Widget _buildTopSongsSection(BuildContext context) {
    final columns = _buildTopSongColumns(_artistTopSongs);
    if (columns.isEmpty && !_artistTopSongsLoading) return const SizedBox.shrink();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: _artistSectionHorizontalInset,
            ),
            child: CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: const Size(1, 1),
              alignment: Alignment.centerLeft,
              onPressed: _openAllTopSongs,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Top canciones',
                    style: TextStyle(
                      fontFamily: '.SF Pro Text',
                      fontWeight: FontWeight.w800,
                      fontSize: 24,
                      letterSpacing: -0.2,
                      color: isDark ? Colors.white : Colors.black,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    CupertinoIcons.forward,
                    size: 22,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 320,
            child: _artistTopSongsLoading
                ? const Center(child: CupertinoActivityIndicator(radius: 12))
                : ListView.separated(
              padding: const EdgeInsets.symmetric(
                horizontal: _artistSectionHorizontalInset,
              ),
              scrollDirection: Axis.horizontal,
              itemCount: columns.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final chunk = columns[index];
                return SizedBox(
                  width: 332,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      const spacing = 8.0;
                      const rows = 4;
                      final rowHeight =
                          (constraints.maxHeight - (rows - 1) * spacing) / rows;
                      return Column(
                        children: List.generate(rows * 2 - 1, (slotIndex) {
                          if (slotIndex.isOdd) {
                            return const SizedBox(height: spacing);
                          }
                          final itemIndex = slotIndex ~/ 2;
                          if (itemIndex >= chunk.length) {
                            return SizedBox(height: rowHeight);
                          }
                          return SizedBox(
                            height: rowHeight,
                            child: _buildTopSongCompactCard(
                              context,
                              chunk[itemIndex],
                              expanded: false,
                            ),
                          );
                        }),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openAllTopSongs() async {
    if (_artistTopSongs.isEmpty) return;
    final playlistId = (_artistTopSongsShowAllPlaylistId ?? '').trim();
    if (playlistId.isNotEmpty) {
      try {
        final loaded = await _runYoutubeWithRetry(
          () => _yt.playlists.getVideos(PlaylistId(playlistId)).take(250).toList(),
          maxAttempts: 1,
        );
        if (loaded.isNotEmpty && mounted) {
          setState(() {
            _artistTopSongs = loaded;
          });
        }
      } catch (_) {
        // Best effort: mantenemos la lista corta si falla show all.
      }
    }
    if (!mounted) return;
    setState(() {
      _albumTransitionDirection = 1;
      _showAllTopSongs = true;
    });
  }

  void _closeAllTopSongs() {
    setState(() {
      _albumTransitionDirection = -1;
      _showAllTopSongs = false;
    });
  }

  Widget _buildAllTopSongsPage(
    BuildContext context, {
    required double bottomReserve,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(child: _buildArtistBlurBackground(context)),
        ),
        Column(
          children: [
            SizedBox(height: MediaQuery.of(context).padding.top + 8),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 16, 10),
              child: Row(
                children: [
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(34, 34),
                    onPressed: _closeAllTopSongs,
                    child: const Icon(CupertinoIcons.back),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Top canciones',
                      style: TextStyle(
                        fontFamily: '.SF Pro Display',
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        color: isDark ? Colors.white : Colors.black,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.separated(
                padding: EdgeInsets.fromLTRB(16, 0, 16, bottomReserve),
                itemCount: _artistTopSongs.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  return _buildTopSongCompactCard(
                    context,
                    _artistTopSongs[index],
                    expanded: false,
                  );
                },
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildTopSongCompactCard(
    BuildContext context,
    Video video, {
    bool expanded = true,
  }) {
    final isDownloaded =
        context.watch<DownloadService>().getDownloadStatus(video.id.value) ==
        DownloadStatus.downloaded;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark
        ? Colors.black
        : CupertinoColors.secondarySystemGroupedBackground.resolveFrom(context);
    final cardBorder = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : CupertinoColors.separator
              .resolveFrom(context)
              .withValues(alpha: 0.12);
    final card = ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Material(
        color: cardColor,
        surfaceTintColor: Colors.transparent,
        child: InkWell(
          onTap: () => _playVideoPreferLocal(video),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: cardBorder, width: 0.6),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                SquareThumbnail.network(
                  imageUrl: _bestQualityThumbnail(video),
                  size: 56,
                  borderRadius: 12,
                  fallback: Container(
                    width: 56,
                    height: 56,
                    color: CupertinoColors.tertiarySystemFill.resolveFrom(
                      context,
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      CupertinoIcons.music_note_2,
                      size: 21,
                      color: CupertinoColors.secondaryLabel.resolveFrom(
                        context,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        video.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: '.SF Pro Text',
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        cleanArtistName(video.author),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: '.SF Pro Text',
                          fontSize: 11,
                          color: CupertinoColors.secondaryLabel.resolveFrom(
                            context,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (isDownloaded) ...[
                  const SizedBox(width: 8),
                  const Icon(
                    CupertinoIcons.arrow_down_circle_fill,
                    size: 14,
                    color: CupertinoColors.systemGreen,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    final withContextMenu = _SearchVideoContextMenu(
      onContextAction: (action) async {
        if (action == _SearchVideoContextAction.addToFavorites) {
          await _addVideoToPlaylist(
            video,
            PlaylistService.favoritesPlaylistName,
          );
          return;
        }
        if (action == _SearchVideoContextAction.addToPlaylist) {
          await _showPlaylistPicker(video);
          return;
        }
        if (action == _SearchVideoContextAction.addNext) {
          _queueVideo(video, insertMode: ManualQueueInsertMode.next);
          return;
        }
        if (action == _SearchVideoContextAction.addToEnd) {
          _queueVideo(video, insertMode: ManualQueueInsertMode.end);
          return;
        }
        if (action == _SearchVideoContextAction.share) {
          await _shareVideoDeepLink(
            video,
            shareOrigin: _shareOriginFromContext(context),
          );
          return;
        }
        if (action == _SearchVideoContextAction.openAlbum) {
          await _openAlbumFromVideo(video);
        }
      },
      child: card,
    );

    if (expanded) return Expanded(child: withContextMenu);
    return withContextMenu;
  }

  Future<T> _runYoutubeWithRetry<T>(
    Future<T> Function() action, {
    int maxAttempts = 2,
  }) async {
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await action();
      } on RequestLimitExceededException {
        rethrow;
      } on SocketException catch (e) {
        lastError = e;
      } on HttpException catch (e) {
        lastError = e;
      } catch (e) {
        lastError = e;
      }
      if (attempt < maxAttempts) {
        await Future<void>.delayed(Duration(seconds: attempt));
      }
    }
    throw lastError ?? Exception('Error de red');
  }

  Future<void> _openVideoPlayer(
    String videoId, {
    String? thumbnailUrl,
    String? title,
    String? artist,
    bool forceVideoPlayback = false,
  }) async {
    try {
      final manager = Provider.of<VideoPlayerManager>(context, listen: false);
      manager.registerSearchThumbnail(videoId, thumbnailUrl);
      await manager.playFromUserSelection(
        context,
        videoId,
        preferredThumbnailUrl: thumbnailUrl,
        preferredTitle: title,
        preferredArtist: artist,
        preferVideoPlayback: forceVideoPlayback,
        forceBackendResolver: forceVideoPlayback,
      );
    } catch (_) {
      if (!mounted) return;
      showIosNotice(context, 'No se pudo iniciar la reproducción.');
    }
  }

  Future<void> _playVideoPreferLocal(
    Video video, {
    bool forceVideoPlayback = false,
  }) async {
    final downloadService = context.read<DownloadService>();
    final videoManager = context.read<VideoPlayerManager>();
    final local = await downloadService.getDownloadedVideoById(video.id.value);

    if (!mounted) return;
    if (local != null) {
      final thumb =
          (local.localThumbnailPath != null &&
              local.localThumbnailPath!.isNotEmpty)
          ? local.localThumbnailPath!
          : local.thumbnailUrl;
      await videoManager.playLocalFileFromUserSelection(
        context,
        id: local.videoId,
        filePath: local.filePath,
        title: local.title,
        thumbnailUrl: thumb,
        artist: local.channelTitle,
        localPlainLyrics: local.plainLyrics,
        localSyncedLyrics: local.syncedLyrics,
        queueStrategy: LocalPlaybackQueueStrategy.recommendations,
      );
      return;
    }

    await _openVideoPlayer(
      video.id.value,
      thumbnailUrl: _bestQualityThumbnail(video),
      title: video.title,
      artist: cleanArtistName(video.author),
      forceVideoPlayback: forceVideoPlayback,
    );
  }

  void _queueVideo(
    Video video, {
    ManualQueueInsertMode insertMode = ManualQueueInsertMode.end,
  }) {
    final manager = context.read<VideoPlayerManager>();
    final added = manager.addOnlineTrackToPlaybackQueue(
      videoId: video.id.value,
      title: video.title,
      thumbnailUrl: _bestQualityThumbnail(video),
      artist: cleanArtistName(video.author),
      insertMode: insertMode,
    );
    if (!mounted) return;
    _showIosTopToast(
      context,
      message: added
          ? (insertMode == ManualQueueInsertMode.next
                ? 'Se añadió como siguiente'
                : 'Se ha añadido a la cola')
          : 'Esta canción ya está en cola',
      icon: added
          ? CupertinoIcons.check_mark_circled_solid
          : CupertinoIcons.info_circle_fill,
    );
  }

  Future<_ResolvedAlbumRef?> _resolveAlbumFromVideo(Video video) async {
    // Regla solicitada: buscar "cancion + artista" en YouTube Music
    // y abrir el primer album devuelto.
    return _resolveAlbumFromAppSearchEngine(video);
  }

  Future<void> _openAlbumFromVideo(Video video) async {
    try {
      final album = await _resolveAlbumFromVideo(video);
      if (!mounted) return;
      if (album == null) {
        showIosNotice(
          context,
          'No se pudo identificar el álbum de esta canción.',
        );
        return;
      }
      setState(() {
        _selectedAlbumView = _SelectedAlbumView(
          playlistId: album.playlistId,
          albumTitle: album.title,
          artistName: album.artist,
          seedThumbnailUrl: album.thumbnailUrl.isNotEmpty
              ? album.thumbnailUrl
              : _bestQualityThumbnail(video),
        );
      });
    } catch (_) {
      if (!mounted) return;
      showIosNotice(context, 'No se pudo abrir el álbum.');
    }
  }

  Future<void> _showVideoOptionsMenu(Video video) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(26),
              child: _AdaptiveBackdropFilter(
                filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                child: Container(
                  decoration: BoxDecoration(
                    color: CupertinoColors.systemGrey6
                        .resolveFrom(sheetContext)
                        .withValues(alpha: 0.82),
                    borderRadius: BorderRadius.circular(26),
                    border: Border.all(
                      color: CupertinoColors.white.withValues(alpha: 0.24),
                      width: 0.7,
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(height: 8),
                      Container(
                        width: 42,
                        height: 4,
                        decoration: BoxDecoration(
                          color: CupertinoColors.systemGrey3
                              .resolveFrom(sheetContext)
                              .withValues(alpha: 0.75),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                video.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: CupertinoTheme.of(sheetContext)
                                    .textTheme
                                    .navTitleTextStyle
                                    .copyWith(fontWeight: FontWeight.w700),
                              ),
                            ),
                            const SizedBox(width: 8),
                            CupertinoButton(
                              padding: EdgeInsets.zero,
                              minimumSize: const Size(34, 34),
                              onPressed: () => Navigator.of(sheetContext).pop(),
                              child: Icon(
                                CupertinoIcons.xmark_circle_fill,
                                size: 24,
                                color: CupertinoColors.secondaryLabel
                                    .resolveFrom(sheetContext),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(10, 0, 10, 14),
                        child: Column(
                          children: [
                            _GlassSheetActionRow(
                              icon: CupertinoIcons.star_fill,
                              label: 'Añadir a Favoritos',
                              onTap: () =>
                                  Navigator.of(sheetContext).pop('favorites'),
                            ),
                            const SizedBox(height: 8),
                            _GlassSheetActionRow(
                              icon: CupertinoIcons.music_note_list,
                              label: 'Añadir a playlist',
                              onTap: () =>
                                  Navigator.of(sheetContext).pop('playlist'),
                            ),
                            const SizedBox(height: 8),
                            _GlassSheetActionRow(
                              icon: CupertinoIcons.text_insert,
                              label: 'Añadir como siguiente',
                              onTap: () =>
                                  Navigator.of(sheetContext).pop('queue_next'),
                            ),
                            const SizedBox(height: 8),
                            _GlassSheetActionRow(
                              icon: CupertinoIcons.text_append,
                              label: 'Añadir al final',
                              onTap: () =>
                                  Navigator.of(sheetContext).pop('queue_end'),
                            ),
                            const SizedBox(height: 8),
                            _GlassSheetActionRow(
                              icon: CupertinoIcons.square_arrow_up,
                              label: 'Compartir',
                              onTap: () =>
                                  Navigator.of(sheetContext).pop('share'),
                            ),
                            const SizedBox(height: 8),
                            _GlassSheetActionRow(
                              icon: CupertinoIcons.rectangle_stack_fill,
                              label: 'Ir al álbum',
                              onTap: () =>
                                  Navigator.of(sheetContext).pop('album'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );

    if (!mounted || action == null) return;
    if (action == 'favorites') {
      await _addVideoToPlaylist(video, PlaylistService.favoritesPlaylistName);
      return;
    }
    if (action == 'playlist') {
      await _showPlaylistPicker(video);
      return;
    }
    if (action == 'queue_next') {
      _queueVideo(video, insertMode: ManualQueueInsertMode.next);
      return;
    }
    if (action == 'queue_end') {
      _queueVideo(video, insertMode: ManualQueueInsertMode.end);
      return;
    }
    if (action == 'share') {
      await _shareVideoDeepLink(
        video,
        shareOrigin: _shareOriginFromContext(context),
      );
      return;
    }
    if (action == 'album') {
      await _openAlbumFromVideo(video);
    }
  }

  Future<void> _showPlaylistPicker(Video video) async {
    final playlistService = context.read<PlaylistService>();
    final playlists = await playlistService.getPlaylists();
    if (!mounted || playlists.isEmpty) return;

    final selectedName = await showGlassPlaylistPickerSheet(
      context: context,
      playlists: playlists,
      subtitle: video.title,
    );
    if (!mounted || selectedName == null || selectedName.isEmpty) return;
    await _addVideoToPlaylist(video, selectedName);
  }

  Future<void> _addVideoToPlaylist(Video video, String playlistName) async {
    final playlistService = context.read<PlaylistService>();
    final downloadService = context.read<DownloadService>();
    final videoManager = context.read<VideoPlayerManager>();
    final track = VideoHistory(
      videoId: video.id.value,
      title: video.title,
      thumbnailUrl: _bestQualityThumbnail(video),
      channelTitle: cleanArtistName(video.author),
      watchedAt: DateTime.now(),
    );
    await playlistService.addVideoToPlaylist(playlistName, track);
    await downloadService.autoDownloadIfEnabledUsingClone(
      playlistName,
      track,
      videoManager: videoManager,
    );
    if (!mounted) return;
    final label = PlaylistService.isFavoritesPlaylistName(playlistName)
        ? 'Añadida a Favoritos'
        : 'Añadida a $playlistName';
    _showIosTopToast(
      context,
      message: label,
      icon: PlaylistService.isFavoritesPlaylistName(playlistName)
          ? CupertinoIcons.star_fill
          : CupertinoIcons.check_mark_circled_solid,
    );
  }

  Future<void> _playRandomTrack() async {
    if (_videos.isEmpty) return;
    final randomIndex = math.Random().nextInt(_videos.length);
    await _playVideoPreferLocal(_videos[randomIndex]);
  }

  Widget _buildArtistBlurBackground(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ColoredBox(
      color: isDark ? const Color(0xFF000000) : const Color(0xFFFFFFFF),
      child: const SizedBox.expand(),
    );
  }

  Widget _buildArtistHeroSection(BuildContext context) {
    final imageUrl = _headerImageUrl.trim();
    final screenWidth = MediaQuery.of(context).size.width;
    final coverHeight = (screenWidth * 1.18).clamp(360.0, 680.0).toDouble();
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    final heroCacheWidth = (screenWidth * devicePixelRatio)
        .round()
        .clamp(720, 2048)
        .toInt();
    final heroCacheHeight = (coverHeight * devicePixelRatio)
        .round()
        .clamp(720, 2048)
        .toInt();
    final fallback = CupertinoColors.tertiarySystemFill.resolveFrom(context);
    final fallbackIcon = CupertinoColors.secondaryLabel.resolveFrom(context);
    final buttonBackground = Colors.white.withValues(alpha: 0.22);

    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          height: coverHeight,
          child: Stack(
            clipBehavior: Clip.none,
            fit: StackFit.expand,
            children: [
              imageUrl.isNotEmpty
                  ? Image.network(
                      imageUrl,
                      fit: BoxFit.cover,
                      cacheWidth: heroCacheWidth,
                      cacheHeight: heroCacheHeight,
                      filterQuality: FilterQuality.low,
                      errorBuilder: (context, error, stackTrace) => Container(
                        color: fallback,
                        alignment: Alignment.center,
                        child: Icon(
                          CupertinoIcons.person_alt_circle_fill,
                          size: 72,
                          color: fallbackIcon,
                        ),
                      ),
                    )
                  : Container(
                      color: fallback,
                      alignment: Alignment.center,
                      child: Icon(
                        CupertinoIcons.person_alt_circle_fill,
                        size: 72,
                        color: fallbackIcon,
                      ),
                    ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.16),
                      Colors.black.withValues(alpha: 0.54),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: -12,
                height: 36,
                child: IgnorePointer(
                  child: ClipRect(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _AdaptiveBackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                          child: const SizedBox.expand(),
                        ),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.white.withValues(alpha: 0.03),
                                Colors.black.withValues(alpha: 0.02),
                                Colors.transparent,
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 20,
                right: 20,
                bottom: 18,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Text(
                        _artistDisplayName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.left,
                        style: const TextStyle(
                          fontFamily: '.SF Pro Text',
                          color: CupertinoColors.white,
                          fontWeight: FontWeight.w900,
                          fontSize: 36,
                          letterSpacing: -0.5,
                          height: 1.0,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    CupertinoButton(
                      padding: const EdgeInsets.all(10),
                      minimumSize: const Size(38, 38),
                      borderRadius: BorderRadius.circular(12),
                      color: buttonBackground,
                      onPressed: _playRandomTrack,
                      child: Icon(
                        CupertinoIcons.play_fill,
                        size: 18,
                        color: CupertinoColors.white.withValues(alpha: 0.96),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  void _closeEmbeddedAlbumView() {
    if (_selectedAlbumView == null) return;
    setState(() {
      _albumTransitionDirection = -1;
      _selectedAlbumView = null;
    });
  }

  @override
  void dispose() {
    // Invalida callbacks async pendientes para evitar setState tardío.
    _albumLoadEpoch++;
    _artistScrollController.dispose();
    _yt.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selectedAlbum = _selectedAlbumView;
    final hasMiniPlayer = context.select<VideoPlayerManager, bool>(
      (playerManager) =>
          playerManager.currentVideoId != null && playerManager.isMinimized,
    );
    final bottomReserve = _rootBottomOverlayReserve(
      context,
      hasMiniPlayer: hasMiniPlayer,
    );
    final content = _loading
        ? const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CupertinoActivityIndicator(radius: 14)),
          )
        : _error
        ? const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: Text('No se pudieron cargar las canciones.')),
          )
        : _videos.isEmpty
        ? const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Text('No se encontraron canciones para este artista.'),
            ),
          )
        : SliverList(
            delegate: SliverChildListDelegate([
              _buildArtistHeroSection(context),
              _buildSuggestedAlbumSection(context),
              _buildTopSongsSection(context),
              _buildArtistAlbumsSection(context),
              _buildArtistVideosSection(context),
              SizedBox(height: bottomReserve),
            ]),
          );

    final pageBody = Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(child: _buildArtistBlurBackground(context)),
        ),
        ScrollConfiguration(
          behavior: const _NoGlowScrollBehavior(),
          child: CustomScrollView(
            controller: _artistScrollController,
            slivers: [content],
          ),
        ),
        if (widget.embedded)
          Positioned(
            top: MediaQuery.of(context).padding.top + 2,
            left: 6,
            child: CupertinoButton(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
              minimumSize: const Size(32, 32),
              onPressed: widget.onBack,
              child: const Icon(CupertinoIcons.back),
            ),
          ),
      ],
    );
    final appleTypographyBody = Theme(
      data: Theme.of(context).copyWith(
        textTheme: Theme.of(
          context,
        ).textTheme.apply(fontFamily: '.SF Pro Text'),
        primaryTextTheme: Theme.of(
          context,
        ).primaryTextTheme.apply(fontFamily: '.SF Pro Text'),
      ),
      child: DefaultTextStyle.merge(
        style: const TextStyle(fontFamily: '.SF Pro Text'),
        child: pageBody,
      ),
    );

    final artistContent = appleTypographyBody;

    return _IosEdgeSwipeBack(
      enabled: widget.embedded,
      onBack: () {
        if (selectedAlbum != null) {
          _closeEmbeddedAlbumView();
          return;
        }
        if (_showAllTopSongs) {
          _closeAllTopSongs();
          return;
        }
        widget.onBack?.call();
      },
      child: PopScope(
        canPop: selectedAlbum == null && !_showAllTopSongs,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop && selectedAlbum != null) {
            _closeEmbeddedAlbumView();
            return;
          }
          if (!didPop && _showAllTopSongs) {
            _closeAllTopSongs();
            return;
          }
          if (!didPop && selectedAlbum == null && widget.embedded) {
            widget.onBack?.call();
          }
        },
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 520),
          reverseDuration: const Duration(milliseconds: 420),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          layoutBuilder: (currentChild, previousChildren) {
            return Stack(
              fit: StackFit.expand,
              children: [
                ...previousChildren,
                if (currentChild != null) currentChild,
              ],
            );
          },
          transitionBuilder: (child, animation) {
            final beginX = _albumTransitionDirection > 0 ? 0.22 : -0.18;
            final curved = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );
            final slide = Tween<Offset>(
              begin: Offset(beginX, 0),
              end: Offset.zero,
            ).animate(curved);
            final scale = Tween<double>(begin: 0.94, end: 1.0).animate(curved);
            return FadeTransition(
              opacity: curved,
              child: ClipRect(
                child: SlideTransition(
                  position: slide,
                  child: ScaleTransition(scale: scale, child: child),
                ),
              ),
            );
          },
          child: selectedAlbum != null
              ? KeyedSubtree(
                  key: ValueKey('artist_album_${selectedAlbum.playlistId}'),
                  child: AlbumTracksPage(
                    playlistId: selectedAlbum.playlistId,
                    albumTitle: selectedAlbum.albumTitle,
                    artistName: selectedAlbum.artistName,
                    seedThumbnailUrl: selectedAlbum.seedThumbnailUrl,
                    libraryAlbumsService: Provider.of<LibraryAlbumsService?>(
                      context,
                      listen: false,
                    ),
                    embedded: true,
                    onBack: _closeEmbeddedAlbumView,
                  ),
                )
              : _showAllTopSongs
              ? KeyedSubtree(
                  key: ValueKey('artist_top_songs_${widget.channelId}'),
                  child: _buildAllTopSongsPage(
                    context,
                    bottomReserve: bottomReserve,
                  ),
                )
              : KeyedSubtree(
                  key: ValueKey('artist_home_${widget.channelId}'),
                  child: artistContent,
                ),
        ),
      ),
    );
  }
}

class AlbumTracksPage extends StatefulWidget {
  final String playlistId;
  final String albumTitle;
  final String artistName;
  final String seedThumbnailUrl;
  final LibraryAlbumsService? libraryAlbumsService;
  final bool embedded;
  final VoidCallback? onBack;

  const AlbumTracksPage({
    super.key,
    required this.playlistId,
    required this.albumTitle,
    required this.artistName,
    required this.seedThumbnailUrl,
    this.libraryAlbumsService,
    this.embedded = false,
    this.onBack,
  });

  @override
  State<AlbumTracksPage> createState() => _AlbumTracksPageState();
}

class _AlbumPageCacheEntry {
  final String resolvedTitle;
  final String resolvedArtist;
  final String coverUrl;
  final List<Video> tracks;
  final Color backgroundColor;

  const _AlbumPageCacheEntry({
    required this.resolvedTitle,
    required this.resolvedArtist,
    required this.coverUrl,
    required this.tracks,
    required this.backgroundColor,
  });
}

class _AlbumTracksPageState extends State<AlbumTracksPage>
    with SingleTickerProviderStateMixin {
  static final Map<String, _AlbumPageCacheEntry> _albumSessionCache = {};
  static const String _albumPersistentCacheBoxName = 'album_page_cache';
  static const Duration _albumPersistentCacheTtl = Duration(days: 7);
  static const int _albumPersistentCacheMaxEntries = 160;
  final YoutubeExplode _yt = YoutubeExplode();
  late final AnimationController _openHeaderController;
  late final CurvedAnimation _openHeaderCurve;
  bool _loading = true;
  bool _error = false;
  String _resolvedTitle = '';
  String _resolvedArtist = '';
  String _coverUrl = '';
  List<Video> _tracks = const [];
  Color _albumBackgroundColor = const Color(0xFF151821);
  bool _isQueueingAlbumDownload = false;
  final Map<String, CupertinoContextMenuPlusController>
  _albumTrackMenuControllers = {};

  CupertinoContextMenuPlusController _albumTrackMenuController(String videoId) {
    final key = videoId.trim();
    return _albumTrackMenuControllers.putIfAbsent(
      key,
      CupertinoContextMenuPlusController.new,
    );
  }

  ({bool allDownloaded, bool anyDownloading}) _albumDownloadState(
    DownloadService downloadService,
  ) {
    if (_tracks.isEmpty) {
      return (allDownloaded: false, anyDownloading: false);
    }
    var allDownloaded = true;
    var anyDownloading = false;
    for (final track in _tracks) {
      final status = downloadService.getDownloadStatus(track.id.value);
      if (status == DownloadStatus.downloading) {
        anyDownloading = true;
      }
      if (status != DownloadStatus.downloaded) {
        allDownloaded = false;
      }
    }
    return (allDownloaded: allDownloaded, anyDownloading: anyDownloading);
  }

  String get _albumCacheKey {
    final id = widget.playlistId.trim();
    if (id.isNotEmpty) return 'id:$id';
    return 'meta:${widget.albumTitle.trim().toLowerCase()}::${widget.artistName.trim().toLowerCase()}';
  }

  void _storeAlbumSessionCache() {
    if (_loading || _error) return;
    final entry = _AlbumPageCacheEntry(
      resolvedTitle: _resolvedTitle,
      resolvedArtist: _resolvedArtist,
      coverUrl: _coverUrl,
      tracks: List<Video>.from(_tracks),
      backgroundColor: _albumBackgroundColor,
    );
    _albumSessionCache[_albumCacheKey] = entry;
    unawaited(_writeAlbumPersistentCache(entry));
  }

  @override
  void initState() {
    super.initState();
    _openHeaderController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
    );
    _openHeaderCurve = CurvedAnimation(
      parent: _openHeaderController,
      curve: Curves.easeOutCubic,
    );
    _resolvedTitle = _cleanAlbumTitle(widget.albumTitle);
    _resolvedArtist = widget.artistName;
    _coverUrl = widget.seedThumbnailUrl;
    unawaited(_openHeaderController.forward());
    final cached = _albumSessionCache[_albumCacheKey];
    if (cached != null) {
      _resolvedTitle = cached.resolvedTitle;
      _resolvedArtist = cached.resolvedArtist;
      _coverUrl = cached.coverUrl;
      _tracks = cached.tracks;
      _albumBackgroundColor = cached.backgroundColor;
      _loading = false;
      _error = false;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_updateAlbumBackgroundFromCover());
    });
    unawaited(_restoreAlbumPersistentCacheOrLoad());
  }

  Future<void> _restoreAlbumPersistentCacheOrLoad() async {
    final cached = await _readAlbumPersistentCache();
    if (cached != null && mounted) {
      setState(() {
        _resolvedTitle = cached.resolvedTitle;
        _resolvedArtist = cached.resolvedArtist;
        _coverUrl = cached.coverUrl;
        _tracks = cached.tracks;
        _albumBackgroundColor = cached.backgroundColor;
        _loading = false;
        _error = false;
      });
      _storeAlbumSessionCache();
      return;
    }
    await _loadAlbumTracks();
  }

  Future<_AlbumPageCacheEntry?> _readAlbumPersistentCache() async {
    try {
      final box = await Hive.openBox<String>(_albumPersistentCacheBoxName);
      final raw = box.get(_albumCacheKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final map = Map<String, dynamic>.from(decoded.cast<dynamic, dynamic>());
      final savedAtMs = (map['savedAtMs'] as num?)?.toInt() ?? 0;
      if (savedAtMs <= 0) return null;
      final savedAt = DateTime.fromMillisecondsSinceEpoch(savedAtMs);
      if (DateTime.now().difference(savedAt) > _albumPersistentCacheTtl) {
        return null;
      }

      final tracksRaw = map['tracks'];
      if (tracksRaw is! List) return null;
      final tracks = <Video>[];
      for (final item in tracksRaw.whereType<Map>()) {
        final snapshot = _CachedVideoSnapshot.fromMap(
          Map<String, dynamic>.from(item.cast<dynamic, dynamic>()),
        );
        if (snapshot.videoId.isEmpty || snapshot.title.isEmpty) continue;
        tracks.add(snapshot.toVideo());
      }
      if (tracks.isEmpty) return null;

      final resolvedTitle = (map['resolvedTitle'] ?? '').toString().trim();
      final resolvedArtist = (map['resolvedArtist'] ?? '').toString().trim();
      final coverUrl = (map['coverUrl'] ?? '').toString().trim();
      final bgValue = (map['backgroundColorValue'] as num?)?.toInt();
      final bgColor = bgValue != null
          ? Color(bgValue)
          : const Color(0xFF151821);

      return _AlbumPageCacheEntry(
        resolvedTitle: resolvedTitle,
        resolvedArtist: resolvedArtist,
        coverUrl: coverUrl,
        tracks: tracks,
        backgroundColor: bgColor,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeAlbumPersistentCache(_AlbumPageCacheEntry entry) async {
    try {
      final box = await Hive.openBox<String>(_albumPersistentCacheBoxName);
      await _pruneAlbumPersistentCache(box);
      final payload = jsonEncode({
        'savedAtMs': DateTime.now().millisecondsSinceEpoch,
        'resolvedTitle': entry.resolvedTitle,
        'resolvedArtist': entry.resolvedArtist,
        'coverUrl': entry.coverUrl,
        'backgroundColorValue': entry.backgroundColor.toARGB32(),
        'tracks': entry.tracks
            .take(90)
            .map((video) => _CachedVideoSnapshot.fromVideo(video).toMap())
            .toList(growable: false),
      });
      await box.put(_albumCacheKey, payload);
    } catch (_) {
      // Best effort.
    }
  }

  Future<void> _pruneAlbumPersistentCache(Box<String> box) async {
    try {
      final entries = <({String key, int savedAtMs})>[];
      for (final key in box.keys.cast<dynamic>()) {
        final k = key.toString();
        final raw = box.get(k);
        if (raw == null || raw.isEmpty) continue;
        try {
          final decoded = jsonDecode(raw);
          if (decoded is! Map) continue;
          final map = Map<String, dynamic>.from(
            decoded.cast<dynamic, dynamic>(),
          );
          final savedAtMs = (map['savedAtMs'] as num?)?.toInt() ?? 0;
          if (savedAtMs > 0) {
            entries.add((key: k, savedAtMs: savedAtMs));
          }
        } catch (_) {}
      }
      entries.sort((a, b) => b.savedAtMs.compareTo(a.savedAtMs));
      final now = DateTime.now();
      for (final item in entries.skip(_albumPersistentCacheMaxEntries)) {
        await box.delete(item.key);
      }
      for (final item in entries) {
        final savedAt = DateTime.fromMillisecondsSinceEpoch(item.savedAtMs);
        if (now.difference(savedAt) > _albumPersistentCacheTtl) {
          await box.delete(item.key);
        }
      }
    } catch (_) {
      // Best effort.
    }
  }

  @override
  void dispose() {
    for (final controller in _albumTrackMenuControllers.values) {
      controller.dispose();
    }
    _openHeaderController.dispose();
    _yt.close();
    super.dispose();
  }

  String _cleanAlbumTitle(String rawTitle) {
    final normalized = rawTitle.trim();
    if (normalized.isEmpty) return '';
    return normalized
        .replaceFirst(
          RegExp(r'^(album|álbum)\s*[-:]\s*', caseSensitive: false),
          '',
        )
        .trim();
  }

  void _triggerBackFromAlbum() {
    final back = widget.onBack;
    if (back != null) {
      back();
      return;
    }
    Navigator.of(context, rootNavigator: false).maybePop();
  }

  Future<void> _addCurrentAlbumToLibrary() async {
    final library =
        widget.libraryAlbumsService ??
        Provider.of<LibraryAlbumsService?>(context, listen: false);
    if (library == null) {
      if (!mounted) return;
      _showIosTopToast(
        context,
        message:
            'No se pudo acceder a Biblioteca. Reinicia la app e inténtalo de nuevo.',
        icon: CupertinoIcons.exclamationmark_triangle_fill,
      );
      return;
    }
    final title = _resolvedTitle.isNotEmpty
        ? _resolvedTitle
        : widget.albumTitle;
    final artist = _resolvedArtist.isNotEmpty
        ? _resolvedArtist
        : widget.artistName.trim();
    final cover = _effectiveCoverUrl();
    final added = await library.addAlbum(
      playlistId: widget.playlistId,
      title: title,
      artist: artist,
      thumbnailUrl: cover,
    );
    if (!mounted) return;
    _showIosTopToast(
      context,
      message: added
          ? 'Álbum añadido a Biblioteca.'
          : 'Ese álbum ya está en Biblioteca.',
      icon: added
          ? CupertinoIcons.check_mark_circled_solid
          : CupertinoIcons.info_circle_fill,
    );
  }

  Future<void> _downloadAllAlbumTracks() async {
    if (_isQueueingAlbumDownload || _tracks.isEmpty) return;
    setState(() => _isQueueingAlbumDownload = true);
    try {
      final downloadService = context.read<DownloadService>();
      final videoManager = context.read<VideoPlayerManager>();
      final items = _tracks
          .map(
            (video) => VideoHistory(
              videoId: video.id.value,
              title: video.title,
              thumbnailUrl: _bestQualityThumbnail(video),
              channelTitle: cleanArtistName(video.author),
              watchedAt: DateTime.now(),
            ),
          )
          .toList(growable: false);
      final summary = await downloadService.downloadPlaylistVideosUsingClone(
        items,
        videoManager: videoManager,
      );
      if (summary.queued == 0 && summary.alreadyInProgress == 0) {
        if (mounted) setState(() => _isQueueingAlbumDownload = false);
      }
      if (!mounted) return;
      if (summary.queued > 0) {
        _showIosTopToast(
          context,
          message:
              'Descarga iniciada: ${summary.queued} canción${summary.queued == 1 ? '' : 'es'}.',
          icon: CupertinoIcons.check_mark_circled_solid,
        );
      } else {
        _showIosTopToast(
          context,
          message: 'Todas las canciones ya estaban descargadas o en proceso.',
          icon: CupertinoIcons.info_circle_fill,
        );
      }
    } catch (_) {
      if (mounted) setState(() => _isQueueingAlbumDownload = false);
      if (!mounted) return;
      _showIosTopToast(
        context,
        message: 'No se pudieron iniciar las descargas del álbum.',
        icon: CupertinoIcons.exclamationmark_triangle_fill,
      );
    }
  }

  Future<void> _confirmRemoveAlbumDownloads() async {
    if (_tracks.isEmpty) return;
    final shouldDelete = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: const Text('Eliminar descargas'),
        content: const Text(
          '¿Quieres eliminar todas las canciones descargadas de este álbum?',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (shouldDelete != true || !mounted) return;

    final downloadService = context.read<DownloadService>();
    var deletedCount = 0;
    for (final track in _tracks) {
      if (downloadService.getDownloadStatus(track.id.value) ==
          DownloadStatus.downloaded) {
        await downloadService.deleteVideo(track.id.value);
        deletedCount++;
      }
    }
    if (!mounted) return;
    _showIosTopToast(
      context,
      message: deletedCount > 0
          ? 'Se eliminaron $deletedCount descarga${deletedCount == 1 ? '' : 's'} del álbum.'
          : 'No había descargas para eliminar en este álbum.',
      icon: deletedCount > 0
          ? CupertinoIcons.check_mark_circled_solid
          : CupertinoIcons.info_circle_fill,
    );
  }

  Future<T> _runYoutubeWithRetry<T>(
    Future<T> Function() action, {
    int maxAttempts = 2,
  }) async {
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await action();
      } on RequestLimitExceededException {
        rethrow;
      } on SocketException catch (e) {
        lastError = e;
      } on HttpException catch (e) {
        lastError = e;
      } catch (e) {
        lastError = e;
      }
      if (attempt < maxAttempts) {
        await Future<void>.delayed(Duration(seconds: attempt));
      }
    }
    throw lastError ?? Exception('Error de red');
  }

  List<String> _albumPrimaryPlaylistCandidates() {
    final candidates = <String>{};
    final rawId = widget.playlistId.trim();
    if (rawId.isNotEmpty) {
      candidates.add(rawId);
      if (rawId.startsWith('VL')) {
        final stripped = rawId.substring(2).trim();
        if (stripped.isNotEmpty) candidates.add(stripped);
      } else {
        candidates.add('VL$rawId');
      }
    }
    return candidates.toList(growable: false);
  }

  Future<List<String>> _albumSearchFallbackCandidates() async {
    final candidates = <String>{};
    final searchTitle = _resolvedTitle.isNotEmpty
        ? _resolvedTitle
        : _cleanAlbumTitle(widget.albumTitle);
    final searchArtist = _resolvedArtist.isNotEmpty
        ? _resolvedArtist
        : widget.artistName.trim();
    final query = '$searchTitle $searchArtist'
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (query.isNotEmpty) {
      final found = await _searchAlbumsFromAppEngine(query);
      for (final album in found) {
        final id = album.playlistId.trim();
        if (id.isNotEmpty) candidates.add(id);
      }
    }
    return candidates.toList(growable: false);
  }

  Future<(dynamic playlist, List<Video>)?> _tryLoadAlbumCandidate(
    String candidateId,
  ) async {
    final normalized = candidateId.trim();
    if (normalized.isEmpty) return null;
    final playlistId = PlaylistId(normalized);
    final loadedPlaylist = await _runYoutubeWithRetry(
      () => _yt.playlists.get(playlistId),
      maxAttempts: 1,
    );
    final loadedVideos = await _runYoutubeWithRetry(
      () => _yt.playlists.getVideos(playlistId).take(80).toList(),
      maxAttempts: 1,
    );
    if (loadedVideos.isEmpty) return null;
    return (loadedPlaylist, loadedVideos);
  }

  Future<void> _loadAlbumTracks() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      dynamic playlist;
      List<Video> videos = const [];
      Object? lastError;

      // Fase 1: intento directo por playlistId (rápido).
      final primaryCandidates = _albumPrimaryPlaylistCandidates();
      for (final candidate in primaryCandidates) {
        try {
          final loaded = await _tryLoadAlbumCandidate(candidate);
          if (loaded == null) continue;
          playlist = loaded.$1;
          videos = loaded.$2;
          break;
        } catch (e) {
          lastError = e;
        }
      }

      // Fase 2: fallback por búsqueda solo si la carga directa falló.
      if (playlist == null) {
        final fallbackCandidates = await _albumSearchFallbackCandidates();
        for (final candidate in fallbackCandidates) {
          if (primaryCandidates.contains(candidate)) continue;
          try {
            final loaded = await _tryLoadAlbumCandidate(candidate);
            if (loaded == null) continue;
            playlist = loaded.$1;
            videos = loaded.$2;
            break;
          } catch (e) {
            lastError = e;
          }
        }
      }

      if (playlist == null) {
        throw lastError ?? Exception('No se pudo resolver el álbum');
      }
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = false;
        _tracks = videos;
        if (_coverUrl.trim().isEmpty && videos.isNotEmpty) {
          _coverUrl = _bestQualityThumbnail(videos.first);
        }
        final cleanedPlaylistTitle = _cleanAlbumTitle(playlist.title);
        _resolvedTitle = cleanedPlaylistTitle.isNotEmpty
            ? cleanedPlaylistTitle
            : _resolvedTitle;
        _resolvedArtist = playlist.author.trim().isNotEmpty
            ? playlist.author.trim()
            : _resolvedArtist;
      });
      _storeAlbumSessionCache();
      unawaited(_updateAlbumBackgroundFromCover());
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = true;
      });
    }
  }

  Future<void> _updateAlbumBackgroundFromCover() async {
    final cover = _effectiveCoverUrl();
    if (cover.isEmpty) return;
    try {
      final scheme = await ColorScheme.fromImageProvider(
        provider: NetworkImage(cover),
        brightness: Brightness.dark,
      );
      if (!mounted) return;
      final hsl = HSLColor.fromColor(scheme.primary);
      final saturation = (hsl.saturation * 0.58).clamp(0.18, 0.70).toDouble();
      final lightness = hsl.lightness.clamp(0.14, 0.34).toDouble();
      final softened = hsl
          .withSaturation(saturation)
          .withLightness(lightness)
          .toColor();
      setState(() {
        _albumBackgroundColor = softened;
      });
      _storeAlbumSessionCache();
    } catch (_) {
      // Si falla lectura de color, mantenemos el fallback.
    }
  }

  Future<void> _playVideoPreferLocal(Video video) async {
    final downloadService = context.read<DownloadService>();
    final manager = context.read<VideoPlayerManager>();
    final local = await downloadService.getDownloadedVideoById(video.id.value);
    if (!mounted) return;
    if (local != null) {
      final thumb =
          (local.localThumbnailPath != null &&
              local.localThumbnailPath!.isNotEmpty)
          ? local.localThumbnailPath!
          : local.thumbnailUrl;
      await manager.playLocalFileFromUserSelection(
        context,
        id: local.videoId,
        filePath: local.filePath,
        title: local.title,
        thumbnailUrl: thumb,
        artist: local.channelTitle,
        localPlainLyrics: local.plainLyrics,
        localSyncedLyrics: local.syncedLyrics,
        queueStrategy: LocalPlaybackQueueStrategy.recommendations,
      );
      return;
    }
    manager.registerSearchThumbnail(
      video.id.value,
      _bestQualityThumbnail(video),
    );
    await manager.playFromUserSelection(
      context,
      video.id.value,
      preferredThumbnailUrl: _bestQualityThumbnail(video),
      preferredTitle: video.title,
      preferredArtist: cleanArtistName(video.author),
      preferVideoPlayback: false,
      forceBackendResolver: false,
    );
  }

  void _queueAlbumTrack(
    Video video, {
    ManualQueueInsertMode insertMode = ManualQueueInsertMode.end,
  }) {
    final manager = context.read<VideoPlayerManager>();
    final added = manager.addOnlineTrackToPlaybackQueue(
      videoId: video.id.value,
      title: video.title,
      thumbnailUrl: _bestQualityThumbnail(video),
      artist: cleanArtistName(video.author),
      insertMode: insertMode,
    );
    if (!mounted) return;
    _showIosTopToast(
      context,
      message: added
          ? (insertMode == ManualQueueInsertMode.next
                ? 'Se añadió como siguiente'
                : 'Se ha añadido a la cola')
          : 'Esta canción ya está en cola',
      icon: added
          ? CupertinoIcons.check_mark_circled_solid
          : CupertinoIcons.info_circle_fill,
    );
  }

  Future<void> _handleAlbumTrackContextAction(
    Video video,
    _SearchVideoContextAction action,
  ) async {
    if (action == _SearchVideoContextAction.addToFavorites) {
      await _addVideoToPlaylist(video, PlaylistService.favoritesPlaylistName);
      return;
    }
    if (action == _SearchVideoContextAction.addToPlaylist) {
      await _showPlaylistPicker(video);
      return;
    }
    if (action == _SearchVideoContextAction.addNext) {
      _queueAlbumTrack(video, insertMode: ManualQueueInsertMode.next);
      return;
    }
    if (action == _SearchVideoContextAction.addToEnd) {
      _queueAlbumTrack(video, insertMode: ManualQueueInsertMode.end);
      return;
    }
    if (action == _SearchVideoContextAction.share) {
      await _shareVideoDeepLink(
        video,
        shareOrigin: _shareOriginFromContext(context),
      );
      return;
    }
  }

  Future<void> _showTrackOptionsMenu(Video video) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(26),
              child: _AdaptiveBackdropFilter(
                filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                child: Container(
                  decoration: BoxDecoration(
                    color: CupertinoColors.systemGrey6
                        .resolveFrom(sheetContext)
                        .withValues(alpha: 0.82),
                    borderRadius: BorderRadius.circular(26),
                    border: Border.all(
                      color: CupertinoColors.white.withValues(alpha: 0.24),
                      width: 0.7,
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(height: 8),
                      Container(
                        width: 42,
                        height: 4,
                        decoration: BoxDecoration(
                          color: CupertinoColors.systemGrey3
                              .resolveFrom(sheetContext)
                              .withValues(alpha: 0.75),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                video.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: CupertinoTheme.of(sheetContext)
                                    .textTheme
                                    .navTitleTextStyle
                                    .copyWith(fontWeight: FontWeight.w700),
                              ),
                            ),
                            const SizedBox(width: 8),
                            CupertinoButton(
                              padding: EdgeInsets.zero,
                              minimumSize: const Size(34, 34),
                              onPressed: () => Navigator.of(sheetContext).pop(),
                              child: Icon(
                                CupertinoIcons.xmark_circle_fill,
                                size: 24,
                                color: CupertinoColors.secondaryLabel
                                    .resolveFrom(sheetContext),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(10, 0, 10, 14),
                        child: Column(
                          children: [
                            _GlassSheetActionRow(
                              icon: CupertinoIcons.star_fill,
                              label: 'Añadir a Favoritos',
                              onTap: () =>
                                  Navigator.of(sheetContext).pop('favorites'),
                            ),
                            const SizedBox(height: 8),
                            _GlassSheetActionRow(
                              icon: CupertinoIcons.music_note_list,
                              label: 'Añadir a playlist',
                              onTap: () =>
                                  Navigator.of(sheetContext).pop('playlist'),
                            ),
                            const SizedBox(height: 8),
                            _GlassSheetActionRow(
                              icon: CupertinoIcons.text_insert,
                              label: 'Añadir como siguiente',
                              onTap: () =>
                                  Navigator.of(sheetContext).pop('queue_next'),
                            ),
                            const SizedBox(height: 8),
                            _GlassSheetActionRow(
                              icon: CupertinoIcons.text_append,
                              label: 'Añadir al final',
                              onTap: () =>
                                  Navigator.of(sheetContext).pop('queue_end'),
                            ),
                            const SizedBox(height: 8),
                            _GlassSheetActionRow(
                              icon: CupertinoIcons.square_arrow_up,
                              label: 'Compartir',
                              onTap: () =>
                                  Navigator.of(sheetContext).pop('share'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );

    if (!mounted || action == null) return;
    if (action == 'favorites') {
      await _addVideoToPlaylist(video, PlaylistService.favoritesPlaylistName);
      return;
    }
    if (action == 'playlist') {
      await _showPlaylistPicker(video);
      return;
    }
    if (action == 'queue_next') {
      _queueAlbumTrack(video, insertMode: ManualQueueInsertMode.next);
      return;
    }
    if (action == 'queue_end') {
      _queueAlbumTrack(video, insertMode: ManualQueueInsertMode.end);
      return;
    }
    if (action == 'share') {
      await _shareVideoDeepLink(
        video,
        shareOrigin: _shareOriginFromContext(context),
      );
      return;
    }
  }

  Future<void> _showPlaylistPicker(Video video) async {
    final playlistService = context.read<PlaylistService>();
    final playlists = await playlistService.getPlaylists();
    if (!mounted || playlists.isEmpty) return;

    final selectedName = await showGlassPlaylistPickerSheet(
      context: context,
      playlists: playlists,
      subtitle: video.title,
    );
    if (!mounted || selectedName == null || selectedName.isEmpty) return;
    await _addVideoToPlaylist(video, selectedName);
  }

  Future<void> _addVideoToPlaylist(Video video, String playlistName) async {
    final playlistService = context.read<PlaylistService>();
    final downloadService = context.read<DownloadService>();
    final videoManager = context.read<VideoPlayerManager>();
    final track = VideoHistory(
      videoId: video.id.value,
      title: video.title,
      thumbnailUrl: _bestQualityThumbnail(video),
      channelTitle: cleanArtistName(video.author),
      watchedAt: DateTime.now(),
    );
    await playlistService.addVideoToPlaylist(playlistName, track);
    await downloadService.autoDownloadIfEnabledUsingClone(
      playlistName,
      track,
      videoManager: videoManager,
    );
    if (!mounted) return;
    final label = PlaylistService.isFavoritesPlaylistName(playlistName)
        ? 'Añadida a Favoritos'
        : 'Añadida a $playlistName';
    _showIosTopToast(
      context,
      message: label,
      icon: PlaylistService.isFavoritesPlaylistName(playlistName)
          ? CupertinoIcons.star_fill
          : CupertinoIcons.check_mark_circled_solid,
    );
  }

  Future<void> _playTopTrack() async {
    if (_tracks.isEmpty) return;
    await _playVideoPreferLocal(_tracks.first);
  }

  Future<void> _playRandomTrack() async {
    if (_tracks.isEmpty) return;
    final randomIndex = math.Random().nextInt(_tracks.length);
    await _playVideoPreferLocal(_tracks[randomIndex]);
  }

  String _effectiveCoverUrl() {
    final seed = widget.seedThumbnailUrl.trim();
    if (seed.isNotEmpty) return seed;
    return _coverUrl.trim();
  }

  Widget _buildAlbumBlurBackground(BuildContext context) {
    final cover = _effectiveCoverUrl();
    final tint = _albumBackgroundColor;
    final topTone = Color.lerp(tint, Colors.black, 0.55)!;
    final bottomTone = Color.lerp(tint, Colors.black, 0.82)!;
    final blurCoverCachePx =
        (MediaQuery.of(context).size.width *
                MediaQuery.devicePixelRatioOf(context) *
                0.95)
            .round()
            .clamp(560, 1400)
            .toInt();

    Widget? artworkLayer;
    if (cover.isNotEmpty) {
      artworkLayer = Transform.scale(
        scale: 1.30,
        child: cover.startsWith('/')
            ? Image.file(
                File(cover),
                fit: BoxFit.cover,
                cacheWidth: blurCoverCachePx,
                cacheHeight: blurCoverCachePx,
                filterQuality: FilterQuality.low,
              )
            : Image.network(
                cover,
                fit: BoxFit.cover,
                cacheWidth: blurCoverCachePx,
                cacheHeight: blurCoverCachePx,
                filterQuality: FilterQuality.low,
              ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [topTone, tint, bottomTone],
            ),
          ),
        ),
        if (artworkLayer != null)
          Opacity(
            opacity: 0.56,
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 48, sigmaY: 48),
              child: artworkLayer,
            ),
          ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(-0.25, -0.80),
              radius: 1.20,
              colors: [
                tint.withValues(alpha: 0.42),
                tint.withValues(alpha: 0.15),
                Colors.black.withValues(alpha: 0.62),
              ],
              stops: const [0.0, 0.50, 1.0],
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.10),
                Colors.transparent,
                Colors.black.withValues(alpha: 0.52),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPlaylistStyleAlbumHeader(
    BuildContext context, {
    required bool animatedCutoutEnabled,
    required bool isInLibrary,
  }) {
    final cover = _effectiveCoverUrl();
    final screenWidth = MediaQuery.of(context).size.width;
    final coverHeight = (screenWidth * 1.30).clamp(420.0, 740.0).toDouble();
    final fallback = CupertinoColors.tertiarySystemFill.resolveFrom(context);
    final fallbackIcon = CupertinoColors.secondaryLabel.resolveFrom(context);
    final albumName = _resolvedTitle.isNotEmpty ? _resolvedTitle : 'Álbum';
    final firstTrackArtist = _tracks.isNotEmpty
        ? cleanArtistName(_tracks.first.author).trim()
        : '';
    final bottomArtistLabel = firstTrackArtist.isNotEmpty
        ? firstTrackArtist
        : (_resolvedArtist.isNotEmpty
              ? _resolvedArtist
              : widget.artistName.trim());
    return AnimatedBuilder(
      animation: _openHeaderCurve,
      builder: (context, child) {
        final t = _openHeaderCurve.value;
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * 34),
            child: Transform.scale(
              scale: 0.965 + (0.035 * t),
              alignment: Alignment.topCenter,
              child: child,
            ),
          ),
        );
      },
      child: Column(
        children: [
          SizedBox(
            width: double.infinity,
            height: coverHeight,
            child: Stack(
              clipBehavior: Clip.none,
              fit: StackFit.expand,
              children: [
                cover.isNotEmpty
                    ? _AlbumAnimatedCover(
                        key: ValueKey('album-cover-$cover'),
                        imageUrl: cover,
                        size: coverHeight,
                        zoom: 1.08,
                        cutoutEnabled: animatedCutoutEnabled,
                        fallback: Container(
                          color: fallback,
                          alignment: Alignment.center,
                          child: Icon(
                            CupertinoIcons.music_albums_fill,
                            size: 64,
                            color: fallbackIcon,
                          ),
                        ),
                      )
                    : Container(
                        color: fallback,
                        alignment: Alignment.center,
                        child: Icon(
                          CupertinoIcons.music_albums_fill,
                          size: 64,
                          color: fallbackIcon,
                        ),
                      ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.18),
                        Colors.black.withValues(alpha: 0.52),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: -12,
                  height: 36,
                  child: IgnorePointer(
                    child: ClipRect(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                            child: const SizedBox.expand(),
                          ),
                          DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.white.withValues(alpha: 0.03),
                                  Colors.black.withValues(alpha: 0.02),
                                  Colors.transparent,
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 20,
                  right: 20,
                  bottom: 18,
                  child: Column(
                    children: [
                      Text(
                        albumName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: CupertinoTheme.of(context)
                            .textTheme
                            .navTitleTextStyle
                            .copyWith(
                              color: CupertinoColors.white,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      const SizedBox(height: 4),
                      if (bottomArtistLabel.isNotEmpty)
                        Text(
                          bottomArtistLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: CupertinoTheme.of(context).textTheme.textStyle
                              .copyWith(
                                color: CupertinoColors.white.withValues(
                                  alpha: 0.95,
                                ),
                                fontSize: 14,
                              ),
                        ),
                      const SizedBox(height: 4),
                      Text(
                        '${_tracks.length} canciones',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: CupertinoTheme.of(context).textTheme.textStyle
                            .copyWith(
                              color: CupertinoColors.white.withValues(
                                alpha: 0.92,
                              ),
                              fontSize: 13,
                            ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _AlbumHeaderActionButton(
                              icon: CupertinoIcons.play_fill,
                              label: 'Reproducir',
                              isPrimary: true,
                              onPressed: _playTopTrack,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _AlbumHeaderActionButton(
                              icon: CupertinoIcons.shuffle,
                              label: 'Aleatorio',
                              onPressed: _playRandomTrack,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _AlbumHeaderActionButton(
                              icon: isInLibrary
                                  ? CupertinoIcons.check_mark
                                  : CupertinoIcons.add,
                              label: isInLibrary ? 'Añadido' : 'Biblioteca',
                              onPressed: _addCurrentAlbumToLibrary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _buildPlaylistStyleAlbumTrackTile(BuildContext context, Video video) {
    final downloadService = context.watch<DownloadService>();
    final isDownloaded =
        downloadService.getDownloadStatus(video.id.value) ==
        DownloadStatus.downloaded;
    final contextMenuController = _albumTrackMenuController(video.id.value);
    final card = LayoutBuilder(
      builder: (context, constraints) {
        final previewWidth = (MediaQuery.of(context).size.width - 32)
            .clamp(240.0, 420.0)
            .toDouble();
        final cardWidth = constraints.hasBoundedWidth
            ? double.infinity
            : previewWidth;
        return ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: _AdaptiveBackdropFilter(
            filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: Colors.white.withValues(alpha: 0.11),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.18),
                  width: 0.55,
                ),
              ),
              child: CupertinoButton(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                onPressed: () => _playVideoPreferLocal(video),
                child: SizedBox(
                  width: cardWidth,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 220),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              video.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: CupertinoTheme.of(context)
                                  .textTheme
                                  .textStyle
                                  .copyWith(
                                    fontSize: 16,
                                    color: CupertinoColors.white,
                                  ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              cleanArtistName(video.author),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: CupertinoTheme.of(context)
                                  .textTheme
                                  .textStyle
                                  .copyWith(
                                    fontSize: 13,
                                    color: CupertinoColors.systemGrey2,
                                  ),
                            ),
                          ],
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isDownloaded) ...[
                            const Icon(
                              CupertinoIcons.arrow_down_circle_fill,
                              size: 16,
                              color: CupertinoColors.systemGreen,
                            ),
                            const SizedBox(width: 8),
                          ],
                          CupertinoButton(
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(30, 30),
                            onPressed: contextMenuController.open,
                            child: Icon(
                              CupertinoIcons.ellipsis_circle,
                              size: 22,
                              color: CupertinoColors.systemGrey2,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );

    final contextMenuWrapped = CupertinoContextMenuPlus(
      controller: contextMenuController,
      enableHapticFeedback: true,
      actions: [
        CupertinoContextMenuAction(
          onPressed: () {
            Navigator.of(context).pop();
            unawaited(
              _handleAlbumTrackContextAction(
                video,
                _SearchVideoContextAction.addNext,
              ),
            );
          },
          child: const Row(
            children: [
              Expanded(child: Text('Añadir como siguiente')),
              SizedBox(width: 16),
              Icon(CupertinoIcons.text_insert, size: 20),
            ],
          ),
        ),
        CupertinoContextMenuAction(
          trailingIcon: CupertinoIcons.text_append,
          onPressed: () {
            Navigator.of(context).pop();
            unawaited(
              _handleAlbumTrackContextAction(
                video,
                _SearchVideoContextAction.addToEnd,
              ),
            );
          },
          child: const Text('Añadir al final'),
        ),
        CupertinoContextMenuAction(
          trailingIcon: CupertinoIcons.star_fill,
          onPressed: () {
            Navigator.of(context).pop();
            unawaited(
              _handleAlbumTrackContextAction(
                video,
                _SearchVideoContextAction.addToFavorites,
              ),
            );
          },
          child: const Text('Añadir a Favoritos'),
        ),
        CupertinoContextMenuAction(
          trailingIcon: CupertinoIcons.music_note_list,
          onPressed: () {
            Navigator.of(context).pop();
            unawaited(
              _handleAlbumTrackContextAction(
                video,
                _SearchVideoContextAction.addToPlaylist,
              ),
            );
          },
          child: const Text('Añadir a playlist'),
        ),
        CupertinoContextMenuAction(
          trailingIcon: CupertinoIcons.square_arrow_up,
          onPressed: () {
            Navigator.of(context).pop();
            unawaited(
              _handleAlbumTrackContextAction(
                video,
                _SearchVideoContextAction.share,
              ),
            );
          },
          child: const Text('Compartir'),
        ),
      ],
      child: card,
    );

    final swipeCard = Slidable(
      key: ValueKey('album_track_${video.id.value}'),
      startActionPane: ActionPane(
        motion: const StretchMotion(),
        extentRatio: 0.46,
        dismissible: DismissiblePane(
          onDismissed: () {},
          closeOnCancel: true,
          confirmDismiss: () async {
            _queueAlbumTrack(video, insertMode: ManualQueueInsertMode.next);
            return false;
          },
        ),
        children: [
          QueueSwipeActionButton(
            onTap: () =>
                _queueAlbumTrack(video, insertMode: ManualQueueInsertMode.next),
            baseColor: CupertinoColors.systemPink.resolveFrom(context),
            icon: CupertinoIcons.text_insert,
            label: 'Siguiente',
          ),
          QueueSwipeActionButton(
            onTap: () =>
                _queueAlbumTrack(video, insertMode: ManualQueueInsertMode.end),
            baseColor: CupertinoColors.systemBlue.resolveFrom(context),
            icon: CupertinoIcons.text_append,
            label: 'Al final',
          ),
        ],
      ),
      child: contextMenuWrapped,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: swipeCard,
    );
  }

  @override
  Widget build(BuildContext context) {
    final downloadService = context.watch<DownloadService>();
    final animatedCutoutEnabled =
        context.watch<AppSettingsService?>()?.animatedCutoutCovers ?? true;
    final hasMiniPlayer = context.select<VideoPlayerManager, bool>(
      (playerManager) =>
          playerManager.currentVideoId != null && playerManager.isMinimized,
    );
    final bottomReserve = _rootBottomOverlayReserve(
      context,
      hasMiniPlayer: hasMiniPlayer,
    );
    final libraryAlbums =
        context.watch<LibraryAlbumsService?>()?.albums ??
        const <LibraryAlbum>[];
    final currentPlaylistId = widget.playlistId.trim();
    final isCurrentAlbumInLibrary =
        currentPlaylistId.isNotEmpty &&
        libraryAlbums.any(
          (album) => album.playlistId.trim() == currentPlaylistId,
        );
    final albumDownloadState = _albumDownloadState(downloadService);
    final allAlbumTracksDownloaded = albumDownloadState.allDownloaded;
    final isAlbumDownloadInProgress =
        albumDownloadState.anyDownloading ||
        (_isQueueingAlbumDownload && !allAlbumTracksDownloaded);
    final content = _loading
        ? SliverList(
            delegate: SliverChildListDelegate([
              _buildPlaylistStyleAlbumHeader(
                context,
                animatedCutoutEnabled: animatedCutoutEnabled,
                isInLibrary: isCurrentAlbumInLibrary,
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Center(child: CupertinoActivityIndicator(radius: 14)),
              ),
              SizedBox(height: bottomReserve),
            ]),
          )
        : _error
        ? SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 22),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('No se pudo cargar este álbum.'),
                    const SizedBox(height: 10),
                    CupertinoButton.filled(
                      onPressed: _loadAlbumTracks,
                      child: const Text('Reintentar'),
                    ),
                  ],
                ),
              ),
            ),
          )
        : _tracks.isEmpty
        ? SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  'Este álbum no tiene canciones disponibles.',
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: CupertinoTheme.of(context).textTheme.textStyle
                      .copyWith(
                        color: CupertinoColors.white,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
            ),
          )
        : SliverList(
            delegate: SliverChildBuilderDelegate((context, index) {
              if (index == 0) {
                return _buildPlaylistStyleAlbumHeader(
                  context,
                  animatedCutoutEnabled: animatedCutoutEnabled,
                  isInLibrary: isCurrentAlbumInLibrary,
                );
              }
              if (index == _tracks.length + 1) {
                return SizedBox(height: bottomReserve);
              }
              final video = _tracks[index - 1];
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _buildPlaylistStyleAlbumTrackTile(context, video),
              );
            }, childCount: _tracks.length + 2),
          );

    final page = CupertinoPageScaffold(
      backgroundColor: _albumBackgroundColor,
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(child: _buildAlbumBlurBackground(context)),
          ),
          ScrollConfiguration(
            behavior: const _NoGlowScrollBehavior(),
            child: CustomScrollView(slivers: [content]),
          ),
          if (widget.embedded)
            Positioned(
              top: MediaQuery.of(context).padding.top + 2,
              left: 6,
              child: CupertinoButton(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
                minimumSize: const Size(32, 32),
                onPressed: _triggerBackFromAlbum,
                child: const Icon(CupertinoIcons.back),
              ),
            ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 2,
            right: 6,
            child: CupertinoButton(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
              minimumSize: const Size(32, 32),
              onPressed: _tracks.isEmpty || isAlbumDownloadInProgress
                  ? null
                  : (allAlbumTracksDownloaded
                        ? _confirmRemoveAlbumDownloads
                        : _downloadAllAlbumTracks),
              child: isAlbumDownloadInProgress
                  ? const CupertinoActivityIndicator(radius: 10)
                  : Icon(
                      allAlbumTracksDownloaded
                          ? CupertinoIcons.check_mark_circled_solid
                          : CupertinoIcons.arrow_down_circle,
                      color: allAlbumTracksDownloaded
                          ? CupertinoColors.systemGreen
                          : CupertinoColors.white,
                    ),
            ),
          ),
        ],
      ),
    );

    return page;
  }
}

class _NoGlowScrollBehavior extends ScrollBehavior {
  const _NoGlowScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}

class _IosEdgeSwipeBack extends StatefulWidget {
  final Widget child;
  final VoidCallback onBack;
  final bool enabled;

  const _IosEdgeSwipeBack({
    required this.child,
    required this.onBack,
    this.enabled = true,
  });

  @override
  State<_IosEdgeSwipeBack> createState() => _IosEdgeSwipeBackState();
}

class _IosEdgeSwipeBackState extends State<_IosEdgeSwipeBack> {
  static const double _edgeWidth = 24;
  static const double _distanceThreshold = 72;
  static const double _velocityThreshold = 700;
  double _dragDistance = 0;
  bool _fired = false;

  void _resetGesture() {
    _dragDistance = 0;
    _fired = false;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: _edgeWidth,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: (_) {
              _dragDistance = 0;
              _fired = false;
            },
            onHorizontalDragUpdate: (details) {
              if (_fired) return;
              final delta = details.primaryDelta ?? 0;
              if (delta > 0) {
                _dragDistance += delta;
              } else if (_dragDistance > 0) {
                _dragDistance = (_dragDistance + delta).clamp(
                  0,
                  double.infinity,
                );
              }
            },
            onHorizontalDragEnd: (details) {
              if (_fired) return;
              final velocity = details.primaryVelocity ?? 0;
              final shouldBack =
                  _dragDistance >= _distanceThreshold ||
                  velocity >= _velocityThreshold;
              if (shouldBack) {
                _fired = true;
                widget.onBack();
              }
              _resetGesture();
            },
            onHorizontalDragCancel: _resetGesture,
          ),
        ),
      ],
    );
  }
}

class _AlbumHeaderActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isPrimary;
  final VoidCallback onPressed;

  const _AlbumHeaderActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.isPrimary = false,
  });

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(14);
    final primaryColor = const Color(0xFFE83C64);
    return CupertinoButton(
      padding: EdgeInsets.zero,
      minimumSize: Size.zero,
      onPressed: onPressed,
      child: ClipRRect(
        borderRadius: borderRadius,
        child: _AdaptiveBackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            height: 34,
            decoration: BoxDecoration(
              borderRadius: borderRadius,
              color: isPrimary
                  ? primaryColor.withValues(alpha: 0.88)
                  : Colors.white.withValues(alpha: 0.11),
              border: Border.all(
                color: isPrimary
                    ? Colors.white.withValues(alpha: 0.26)
                    : Colors.white.withValues(alpha: 0.18),
                width: 0.55,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 14, color: Colors.white),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: const TextStyle(
                    fontFamily: '.SF Pro Text',
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AlbumAnimatedCover extends StatefulWidget {
  final String imageUrl;
  final double size;
  final double zoom;
  final bool cutoutEnabled;
  final Widget fallback;

  const _AlbumAnimatedCover({
    super.key,
    required this.imageUrl,
    required this.size,
    required this.zoom,
    required this.cutoutEnabled,
    required this.fallback,
  });

  @override
  State<_AlbumAnimatedCover> createState() => _AlbumAnimatedCoverState();
}

class _AlbumAnimatedCoverState extends State<_AlbumAnimatedCover>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motionController;
  Uint8List? _cutoutBytes;
  String? _lastCutoutUrl;

  @override
  void initState() {
    super.initState();
    _motionController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 5800),
    )..repeat(reverse: true);
    if (widget.cutoutEnabled) {
      unawaited(_resolveCutout());
    }
  }

  @override
  void didUpdateWidget(covariant _AlbumAnimatedCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl ||
        oldWidget.cutoutEnabled != widget.cutoutEnabled) {
      if (!widget.cutoutEnabled) {
        _lastCutoutUrl = null;
        if (_cutoutBytes != null) {
          setState(() {
            _cutoutBytes = null;
          });
        } else {
          _cutoutBytes = null;
        }
      } else {
        unawaited(_resolveCutout());
      }
    }
  }

  @override
  void dispose() {
    _motionController.dispose();
    super.dispose();
  }

  Future<void> _resolveCutout() async {
    final source = widget.imageUrl.trim();
    if (!widget.cutoutEnabled || source.isEmpty || source == _lastCutoutUrl) {
      return;
    }
    _lastCutoutUrl = source;
    try {
      final sourceBytes = await _loadCoverBytes(source);
      if (sourceBytes == null || sourceBytes.isEmpty) return;
      final cutout = await ArtworkSubjectCutoutService.buildCutout(
        sourceBytes: sourceBytes,
        cacheKey: 'album_header_${source.hashCode}',
        viewportZoom: widget.zoom,
      );
      if (!mounted || _lastCutoutUrl != source) return;
      setState(() {
        _cutoutBytes = cutout;
      });
    } catch (_) {
      // Si falla el recorte, mantenemos la portada normal.
    }
  }

  Future<Uint8List?> _loadCoverBytes(String raw) async {
    if (raw.startsWith('/')) {
      final file = File(raw);
      if (await file.exists()) {
        return file.readAsBytes();
      }
      return null;
    }

    final uri = Uri.tryParse(raw);
    if (uri == null) return null;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.getUrl(uri).timeout(const Duration(seconds: 8));
      req.headers.set(
        HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)',
      );
      req.headers.set(HttpHeaders.acceptHeader, 'image/*,*/*;q=0.8');
      final res = await req.close().timeout(const Duration(seconds: 12));
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final bytes = await consolidateHttpClientResponseBytes(
        res,
        autoUncompress: true,
      ).timeout(const Duration(seconds: 12));
      return bytes;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.imageUrl.trim();
    final hasLocal = url.startsWith('/');
    final coverCachePx =
        (widget.size * MediaQuery.devicePixelRatioOf(context) * widget.zoom)
            .round()
            .clamp(96, 2048)
            .toInt();
    final baseImage = hasLocal
        ? Image.file(
            File(url),
            fit: BoxFit.cover,
            cacheWidth: coverCachePx,
            cacheHeight: coverCachePx,
            filterQuality: FilterQuality.low,
            errorBuilder: (context, error, stackTrace) => widget.fallback,
          )
        : Image.network(
            url,
            fit: BoxFit.cover,
            cacheWidth: coverCachePx,
            cacheHeight: coverCachePx,
            filterQuality: FilterQuality.low,
            gaplessPlayback: true,
            errorBuilder: (context, error, stackTrace) => widget.fallback,
          );

    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Transform.scale(scale: widget.zoom, child: baseImage),
          if (widget.cutoutEnabled && _cutoutBytes != null)
            IgnorePointer(
              child: AnimatedBuilder(
                animation: _motionController,
                builder: (context, _) {
                  final turn = _motionController.value * math.pi * 2;
                  final dx =
                      math.sin(turn * 1.1 + 0.7) * (widget.size * 0.0095);
                  final dy =
                      math.cos(turn * 0.87 + 1.3) * (widget.size * 0.0078);
                  final scale = 1.50 + (math.sin(turn * 0.92) * 0.012);
                  return Transform.translate(
                    offset: Offset(dx, dy),
                    child: Transform.scale(
                      scale: scale,
                      child: Image.memory(
                        _cutoutBytes!,
                        fit: BoxFit.contain,
                        cacheWidth: coverCachePx,
                        cacheHeight: coverCachePx,
                        filterQuality: FilterQuality.low,
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
