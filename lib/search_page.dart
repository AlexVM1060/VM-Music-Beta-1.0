import 'dart:developer' as developer;
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter, Rect;
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:image/image.dart' as img;
import 'package:myapp/models/video_history.dart';
import 'package:myapp/search_view_state.dart';
import 'package:myapp/services/download_service.dart';
import 'package:myapp/services/history_service.dart';
import 'package:myapp/services/playlist_service.dart';
import 'package:myapp/services/app_settings_service.dart';
import 'package:myapp/utils/artist_name_utils.dart';
import 'package:myapp/utils/artwork_subject_cutout_service.dart';
import 'package:myapp/utils/thumbnail_quality.dart';
import 'package:myapp/video_player_manager.dart';
import 'package:myapp/widgets/playlist_picker_sheet.dart';
import 'package:myapp/widgets/queue_swipe_action_button.dart';
import 'package:myapp/widgets/square_thumbnail.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

enum SearchState { initial, loading, success, error, noResults }

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

const String _youtubeiMusicSearchEndpointForAlbums =
    'https://music.youtube.com/youtubei/v1/search?key=AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8';

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
          if (albumsOnly) 'params': 'EgWKAQIYAWoKEAoQAxAEEAkQBQ==',
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
  final query = '$compactTitle $compactArtist'
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (query.isEmpty) return null;

  final results = await _searchAlbumsFromAppEngine(query);
  if (results.isEmpty) return null;
  final best = results.first;
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

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage>
    with SingleTickerProviderStateMixin {
  static const int _minimumSubscribers = 100000;
  static const int _maxChannelsToShow = 2;
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
  bool _showArtists = true;
  bool _showAlbums = true;
  _SelectedArtistView? _selectedArtistView;
  _SelectedAlbumView? _selectedAlbumView;
  int _artistTransitionDirection = 1;
  List<Video> _initialRecommendations = const [];
  bool _initialRecommendationsLoading = false;
  String? _initialRecommendationQuery;
  bool _initialRecommendationsFromQueue = false;
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
      final glow = _ensureSearchBarGlowController();
      if (_searchFocusNode.hasFocus) {
        glow.repeat();
      } else {
        glow.stop();
      }
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_loadInitialRecommendations());
    });
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
    final cached = _searchCache[query];
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

    setState(() {
      _searchState = SearchState.loading;
      _videos = [];
      _channels = [];
      _albums = [];
    });

    try {
      final videosFuture = _searchWithCache(query);
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
        _channels = _channels.isNotEmpty
            ? _channels
            : (cachedChannels ?? const []);
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
      final albumResult = await _searchAlbumsWithCache(
        primaryArtistQuery.isNotEmpty ? primaryArtistQuery : query,
      );
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

  Future<void> _loadInitialRecommendations() async {
    if (!mounted) return;
    setState(() {
      _initialRecommendationsLoading = true;
    });

    try {
      final queueVideos = await _loadQueueStyleRecommendationVideos();
      if (!mounted) return;
      if (queueVideos.isNotEmpty) {
        setState(() {
          _initialRecommendationQuery = null;
          _initialRecommendations = queueVideos.take(12).toList();
          _initialRecommendationsFromQueue = true;
          _initialRecommendationsLoading = false;
        });
        return;
      }

      const fallbackQueries = [
        'Regional mexicano',
        'musica en ingles',
        'rels b',
      ];
      final query =
          fallbackQueries[math.Random().nextInt(fallbackQueries.length)];
      final videos = await _searchWithCache(query);
      if (!mounted) return;
      setState(() {
        _initialRecommendationQuery = query;
        _initialRecommendations = _prioritizedVideos(videos).take(12).toList();
        _initialRecommendationsFromQueue = false;
        _initialRecommendationsLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _initialRecommendationQuery = null;
        _initialRecommendations = const [];
        _initialRecommendationsFromQueue = false;
        _initialRecommendationsLoading = false;
      });
    }
  }

  Future<List<Video>> _loadQueueStyleRecommendationVideos() async {
    final manager = context.read<VideoPlayerManager>();
    final historyService = context.read<HistoryService>();
    var queueItems = await manager.fetchQueueStyleRecommendations(limit: 24);
    if (queueItems.isEmpty) {
      final history = await historyService.getHistory();
      final seed = history
          .map((item) => item.videoId.trim())
          .firstWhere((id) => id.isNotEmpty, orElse: () => '');
      if (seed.isNotEmpty) {
        queueItems = await manager.fetchQueueStyleRecommendations(
          limit: 24,
          seedVideoId: seed,
        );
      }
    }
    if (queueItems.isEmpty) return const <Video>[];

    final orderedIds = <String>[];
    final seenIds = <String>{};
    for (final item in queueItems) {
      if (item.isLocal) continue;
      final id = item.videoId.trim();
      if (id.isEmpty) continue;
      if (seenIds.add(id)) orderedIds.add(id);
    }
    if (orderedIds.isEmpty) return const <Video>[];

    final resolved = await Future.wait(
      orderedIds.take(16).map(_resolveVideoById),
    );
    return resolved.whereType<Video>().toList(growable: false);
  }

  Future<Video?> _resolveVideoById(String videoId) async {
    try {
      return await _runYoutubeWithRetry(
        () => _youtubeExplode.videos.get(videoId),
        maxAttempts: 1,
      );
    } catch (_) {
      return null;
    }
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
    if (_initialRecommendations.isEmpty && !_initialRecommendationsLoading) {
      unawaited(_loadInitialRecommendations());
    }
  }

  Future<void> _applySuggestionAndSearch(String suggestion) async {
    await _searchVideos(forcedQuery: suggestion);
  }

  Future<void> _openChannel(SearchChannelWithSubscribers channelData) async {
    final channel = channelData.channel;
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
      );
    } catch (e, s) {
      developer.log('Error al abrir reproductor', error: e, stackTrace: s);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo iniciar la reproducción.')),
      );
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
      return;
    }

    await _openVideoPlayer(
      video.id.value,
      thumbnailUrl: _bestQualityThumbnail(video),
      title: video.title,
      artist: cleanArtistName(video.author),
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

  Future<void> _openArtistFromVideo(Video video) async {
    final videoId = video.id.value.trim();
    if (videoId.isEmpty) return;
    final cached = _artistProfileByVideoIdCache[videoId];
    if (cached != null) {
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
      await _openArtistEmbedded(
        channelId: resolved.channelId,
        channelName: resolved.channelName,
        channelThumbnailUrl: resolved.channelThumbnailUrl,
      );
    } catch (_) {
      _artistProfileByVideoIdInFlight.remove(videoId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No se pudo abrir el perfil del artista.'),
        ),
      );
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No se pudo identificar el álbum de esta canción.'),
          ),
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo abrir el álbum.')),
      );
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
              child: BackdropFilter(
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

  Future<List<Video>> _searchWithCache(String query) async {
    final cached = _searchCache[query];
    if (cached != null) return cached;
    final inFlight = _searchInFlight[query];
    if (inFlight != null) return inFlight;

    final future = _runYoutubeWithRetry(
      () => _searchAutoGeneratedTopicVideos(query),
    );
    _searchInFlight[query] = future;
    try {
      final result = await future;
      _searchCache[query] = result;
      return result;
    } finally {
      _searchInFlight.remove(query);
    }
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
      final list = await _youtubeExplode.search.searchContent(
        query,
        filter: TypeFilters.channel,
      );
      final channels = list.whereType<SearchChannel>().take(8).toList();
      if (channels.isEmpty) return const <SearchChannelWithSubscribers>[];

      // Ruta rápida: evita llamadas extras para que el artista aparezca antes.
      final resolvedByChannelSearch = await _resolveChannelsWithSubscribers(
        channels,
      );
      final filtered = _filterChannelsBySubscribers(resolvedByChannelSearch);
      if (filtered.isNotEmpty) {
        return _hydrateTopicChannelPhotos(
          filtered,
          resolvedByChannelSearch,
          forcedTopicThumbnail: _topThumbnailFromResolved(
            resolvedByChannelSearch,
          ),
        );
      }

      // Fallback solo si no hubo suficientes candidatos por canal.
      final videos = await _searchWithCache(query);
      final resolvedByVideoSearch = await _resolveChannelsFromTopVideos(
        videos.take(2).toList(),
      );
      final merged = _mergeChannelCandidates(
        resolvedByChannelSearch,
        resolvedByVideoSearch,
      );
      final mergedFiltered = _filterChannelsBySubscribers(merged);
      return _hydrateTopicChannelPhotos(
        mergedFiltered,
        merged,
        forcedTopicThumbnail: _topThumbnailFromResolved(merged),
      );
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
      return _hydrateTopicChannelPhotos(
        _filterChannelsBySubscribers(rawResult),
        rawResult,
        forcedTopicThumbnail: _topThumbnailFromResolved(rawResult),
      );
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
                    embedded: true,
                    onBack: _closeAlbumView,
                  ),
                ),
              )
            : selectedArtist == null
            ? KeyedSubtree(
                key: const ValueKey('search_home'),
                child: Scaffold(
                  backgroundColor:
                      Theme.of(context).brightness == Brightness.dark
                      ? Colors.black
                      : CupertinoColors.systemGroupedBackground.resolveFrom(
                          context,
                        ),
                  body: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0),
                    child: Column(
                      children: [
                        const SizedBox(height: 16),
                        _buildSearchBar(),
                        const SizedBox(height: 10),
                        _buildSearchFilters(),
                        const SizedBox(height: 24),
                        Expanded(child: _buildBody()),
                      ],
                    ),
                  ),
                ),
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
    return Row(
      children: [
        SearchModeButton(
          label: 'Canciones',
          icon: CupertinoIcons.music_note_2,
          isActive: true,
          onPressed: () {},
        ),
        const SizedBox(width: 10),
        SearchModeButton(
          label: 'Artistas',
          icon: CupertinoIcons.person_2,
          isActive: _showArtists,
          onPressed: () {
            setState(() {
              _showArtists = !_showArtists;
            });
          },
        ),
        const SizedBox(width: 10),
        SearchModeButton(
          label: 'Álbumes',
          icon: CupertinoIcons.music_albums,
          isActive: _showAlbums,
          onPressed: () {
            setState(() {
              _showAlbums = !_showAlbums;
            });
          },
        ),
      ],
    );
  }

  Widget _buildSearchBar() {
    final borderRadius = BorderRadius.circular(18);
    final focused = _searchFocusNode.hasFocus;
    final glow = _ensureSearchBarGlowController();

    return AnimatedBuilder(
      animation: glow,
      builder: (context, _) {
        final rotation = glow.value * math.pi * 2;
        return Container(
          height: 42,
          padding: const EdgeInsets.all(1.25),
          decoration: BoxDecoration(
            borderRadius: borderRadius,
            gradient: SweepGradient(
              transform: GradientRotation(rotation),
              colors: [
                const Color(0xFFFF004D),
                const Color(0xFFFF7A00),
                const Color(0xFF7A5CFF),
                const Color(0xFFFF004D),
              ],
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(
                  0xFF581A95,
                ).withValues(alpha: focused ? 0.34 : 0.14),
                blurRadius: focused ? 20 : 10,
                spreadRadius: focused ? 0.9 : 0,
                offset: const Offset(0, 2),
              ),
              BoxShadow(
                color: const Color(
                  0xFFFF2A6D,
                ).withValues(alpha: focused ? 0.24 : 0.08),
                blurRadius: focused ? 26 : 12,
                spreadRadius: focused ? 1.2 : 0,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: borderRadius,
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: Container(
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
                              unawaited(
                                _clearSearchAndShowInitialRecommendations(),
                              );
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
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBody() {
    final hasMiniPlayer = context.select<VideoPlayerManager, bool>(
      (playerManager) =>
          playerManager.currentVideoId != null && playerManager.isMinimized,
    );
    final bottomReserve = _rootBottomOverlayReserve(
      context,
      hasMiniPlayer: hasMiniPlayer,
    );
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
        final downloadService = context.watch<DownloadService>();
        if (_initialRecommendationsLoading && _initialRecommendations.isEmpty) {
          return const Center(child: CupertinoActivityIndicator(radius: 14));
        }
        if (_initialRecommendations.isEmpty) {
          return Center(
            child: Text(
              'Comienza haciendo',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          );
        }
        return ListView(
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _initialRecommendationsFromQueue
                    ? 'Recomendado para ti'
                    : (_initialRecommendationQuery == null
                          ? 'Recomendado para ti'
                          : 'Recomendado para ti • $_initialRecommendationQuery'),
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            ..._initialRecommendations.map(
              (video) => VideoCard(
                video: video,
                isDownloaded:
                    downloadService.getDownloadStatus(video.id.value) ==
                    DownloadStatus.downloaded,
                onPlay: () => _playVideoPreferLocal(video),
                onQueueNext: () =>
                    _queueVideo(video, insertMode: ManualQueueInsertMode.next),
                onQueueEnd: () =>
                    _queueVideo(video, insertMode: ManualQueueInsertMode.end),
                onMenuTap: () => _showVideoOptionsMenu(video),
              ),
            ),
            SizedBox(height: bottomReserve),
          ],
        );
      case SearchState.success:
        final downloadService = context.watch<DownloadService>();
        final prioritizedVideos = _prioritizedVideos(_videos);
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
            if (_showArtists &&
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
            if (_showAlbums && albumResults.isNotEmpty) ...[
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
                  'Canciones',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
            ...prioritizedVideos
                .take(20)
                .map(
                  (video) => VideoCard(
                    video: video,
                    isDownloaded:
                        downloadService.getDownloadStatus(video.id.value) ==
                        DownloadStatus.downloaded,
                    onPlay: () => _playVideoPreferLocal(video),
                    onQueueNext: () => _queueVideo(
                      video,
                      insertMode: ManualQueueInsertMode.next,
                    ),
                    onQueueEnd: () => _queueVideo(
                      video,
                      insertMode: ManualQueueInsertMode.end,
                    ),
                    onMenuTap: () => _showVideoOptionsMenu(video),
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
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
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
                          filterQuality: FilterQuality.medium,
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
                            style: CupertinoTheme.of(context)
                                .textTheme
                                .textStyle
                                .copyWith(
                                  fontSize: 16,
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
    final borderRadius = BorderRadius.circular(14);
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
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Container(
              height: 30,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: (isActive
                    ? Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.2)
                    : CupertinoColors.systemGrey6
                          .resolveFrom(context)
                          .withValues(alpha: 0.52)),
                borderRadius: borderRadius,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 14,
                    color: isActive
                        ? Theme.of(context).colorScheme.primary
                        : CupertinoColors.label.resolveFrom(context),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: CupertinoTheme.of(context).textTheme.textStyle
                        .copyWith(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: isActive
                              ? Theme.of(context).colorScheme.primary
                              : null,
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
                            filterQuality: FilterQuality.medium,
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
                          filterQuality: FilterQuality.medium,
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
                          const SizedBox(height: 4),
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
                      filterQuality: FilterQuality.medium,
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

class VideoCard extends StatelessWidget {
  final Video video;
  final VoidCallback onPlay;
  final VoidCallback? onQueueNext;
  final VoidCallback? onQueueEnd;
  final VoidCallback onMenuTap;
  final bool isDownloaded;
  final bool highlightTop;

  const VideoCard({
    super.key,
    required this.video,
    required this.onPlay,
    this.onQueueNext,
    this.onQueueEnd,
    required this.onMenuTap,
    this.isDownloaded = false,
    this.highlightTop = false,
  });

  @override
  Widget build(BuildContext context) {
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
    final card = ClipRRect(
      borderRadius: borderRadius,
      child: Material(
        color: cardColor,
        child: InkWell(
          onTap: onPlay,
          child: Container(
            decoration: BoxDecoration(
              color: cardColor,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: borderColor, width: 0.6),
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: 12.0,
              vertical: 6.0,
            ),
            child: Row(
              children: [
                SquareThumbnail.network(
                  imageUrl: _bestQualityThumbnail(video),
                  size: 64,
                  borderRadius: 10,
                  zoom: 1,
                  fallback: Container(
                    width: 64,
                    height: 64,
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
                const SizedBox(width: 14),
                Expanded(
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
                              color: CupertinoColors.label.resolveFrom(context),
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
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: CupertinoColors.secondaryLabel.resolveFrom(
                                context,
                              ),
                            ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (isDownloaded) ...[
                  Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      color: CupertinoColors.tertiarySystemFill.resolveFrom(
                        context,
                      ),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: CupertinoColors.separator
                            .resolveFrom(context)
                            .withValues(alpha: 0.32),
                        width: 0.5,
                      ),
                    ),
                    child: const Icon(
                      CupertinoIcons.arrow_down_circle_fill,
                      size: 14,
                      color: CupertinoColors.systemGreen,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(32, 32),
                  onPressed: onMenuTap,
                  child: Icon(
                    CupertinoIcons.ellipsis_circle,
                    size: 24,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final swipeCard = (onQueueNext == null || onQueueEnd == null)
        ? card
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
            child: card,
          );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.0),
      child: highlightTop
          ? Container(
              padding: const EdgeInsets.all(1),
              decoration: BoxDecoration(
                borderRadius: borderRadius,
                color: CupertinoColors.systemPink
                    .resolveFrom(context)
                    .withValues(alpha: 0.34),
                boxShadow: [
                  BoxShadow(
                    color: CupertinoColors.systemPink
                        .resolveFrom(context)
                        .withValues(alpha: 0.16),
                    blurRadius: 10,
                    spreadRadius: 0,
                  ),
                ],
              ),
              child: swipeCard,
            )
          : swipeCard,
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
      child: BackdropFilter(
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
          child: BackdropFilter(
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
  final YoutubeExplode _yt = YoutubeExplode();
  final ScrollController _artistScrollController = ScrollController();
  static const Duration _channelFetchTimeout = Duration(seconds: 6);
  static const double _artistSectionHorizontalInset = 16;
  List<Video> _videos = [];
  _SelectedAlbumView? _selectedAlbumView;
  _SearchAlbumResult? _suggestedAlbum;
  List<_SearchAlbumResult> _artistAlbums = const [];
  bool _suggestedAlbumLoading = false;
  final Map<String, bool> _albumPlaylistArtistMatchCache = {};
  int _albumLoadEpoch = 0;
  int _albumTransitionDirection = 1;
  bool _loading = true;
  bool _error = false;

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
      return;
    }
    _loadChannelVideos();
  }

  String get _artistCacheKey {
    final channelId = widget.channelId.trim();
    if (channelId.isNotEmpty) return 'id:$channelId';
    return 'name:${widget.channelName.trim().toLowerCase()}';
  }

  void _storeArtistCache({required bool albumsResolved}) {
    if (_videos.isEmpty) return;
    _artistSessionCache[_artistCacheKey] = _ArtistProfileCacheEntry(
      schemaVersion: _artistSessionCacheSchemaVersion,
      videos: List<Video>.from(_videos),
      suggestedAlbum: _suggestedAlbum,
      artistAlbums: List<_SearchAlbumResult>.from(_artistAlbums),
      albumsResolved: albumsResolved,
    );
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

        final pair = await Future.wait([
          initialFuture,
          defaultFuture,
        ]);
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
        final batchResults = await Future.wait(
          batch.map(loadAlbumsForQuery),
        );
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
        if (noAccents.isNotEmpty && noAccents.toLowerCase() != display.toLowerCase())
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
                          filterQuality: FilterQuality.medium,
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

  List<List<Video>> _buildTopSongColumns(List<Video> source) {
    if (source.isEmpty) return const [];
    final columns = <List<Video>>[];
    for (var index = 0; index < source.length; index += 2) {
      final pair = <Video>[source[index]];
      if (index + 1 < source.length) {
        pair.add(source[index + 1]);
      }
      columns.add(pair);
    }
    return columns;
  }

  Widget _buildTopSongsSection(
    BuildContext context,
    DownloadService downloadService,
  ) {
    final columns = _buildTopSongColumns(_videos);
    if (columns.isEmpty) return const SizedBox.shrink();
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
              'Top canciones',
              style: const TextStyle(
                fontFamily: '.SF Pro Text',
                fontWeight: FontWeight.w800,
                fontSize: 24,
                letterSpacing: -0.2,
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 170,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(
                horizontal: _artistSectionHorizontalInset,
              ),
              scrollDirection: Axis.horizontal,
              itemCount: columns.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final pair = columns[index];
                return SizedBox(
                  width: 286,
                  child: Column(
                    children: [
                      _buildTopSongCompactCard(
                        context,
                        pair.first,
                        downloadService,
                      ),
                      const SizedBox(height: 6),
                      if (pair.length > 1)
                        _buildTopSongCompactCard(
                          context,
                          pair[1],
                          downloadService,
                        )
                      else
                        const Spacer(),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopSongCompactCard(
    BuildContext context,
    Video video,
    DownloadService downloadService,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark
        ? Colors.black
        : CupertinoColors.secondarySystemGroupedBackground.resolveFrom(context);
    final cardBorder = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : CupertinoColors.separator
              .resolveFrom(context)
              .withValues(alpha: 0.12);
    final actionBg = CupertinoColors.tertiarySystemFill.resolveFrom(context);
    final actionAccent = CupertinoColors.systemPink.resolveFrom(context);
    final isDownloaded =
        downloadService.getDownloadStatus(video.id.value) ==
        DownloadStatus.downloaded;

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
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
            child: Row(
              children: [
                SquareThumbnail.network(
                  imageUrl: _bestQualityThumbnail(video),
                  size: 44,
                  borderRadius: 10,
                  fallback: Container(
                    width: 44,
                    height: 44,
                    color: CupertinoColors.tertiarySystemFill.resolveFrom(
                      context,
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      CupertinoIcons.music_note,
                      size: 22,
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
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
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
                          color: CupertinoColors.secondaryLabel.resolveFrom(
                            context,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (isDownloaded) ...[
                  const Icon(
                    CupertinoIcons.arrow_down_circle_fill,
                    size: 16,
                    color: CupertinoColors.systemGreen,
                  ),
                  const SizedBox(width: 8),
                ],
                CupertinoButton(
                  padding: const EdgeInsets.all(4),
                  minimumSize: const Size(28, 28),
                  borderRadius: BorderRadius.circular(9),
                  color: actionBg,
                  onPressed: () => _showVideoOptionsMenu(video),
                  child: Icon(
                    CupertinoIcons.add,
                    size: 14,
                    color: actionAccent,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    return Expanded(child: card);
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
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo iniciar la reproducción.')),
      );
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
      return;
    }

    await _openVideoPlayer(
      video.id.value,
      thumbnailUrl: _bestQualityThumbnail(video),
      title: video.title,
      artist: cleanArtistName(video.author),
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No se pudo identificar el álbum de esta canción.'),
          ),
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo abrir el álbum.')),
      );
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
              child: BackdropFilter(
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
                      filterQuality: FilterQuality.medium,
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
    final downloadService = context.watch<DownloadService>();
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
              _buildTopSongsSection(context, downloadService),
              _buildArtistAlbumsSection(context),
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

    final artistContent = widget.embedded
        ? appleTypographyBody
        : Scaffold(
            backgroundColor: Theme.of(context).brightness == Brightness.dark
                ? Colors.black
                : Colors.white,
            extendBodyBehindAppBar: true,
            body: appleTypographyBody,
          );

    return _IosEdgeSwipeBack(
      enabled: widget.embedded,
      onBack: () {
        if (selectedAlbum != null) {
          _closeEmbeddedAlbumView();
          return;
        }
        widget.onBack?.call();
      },
      child: PopScope(
        canPop: selectedAlbum == null,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop && selectedAlbum != null) {
            _closeEmbeddedAlbumView();
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
                    embedded: true,
                    onBack: _closeEmbeddedAlbumView,
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
  final bool embedded;
  final VoidCallback? onBack;

  const AlbumTracksPage({
    super.key,
    required this.playlistId,
    required this.albumTitle,
    required this.artistName,
    required this.seedThumbnailUrl,
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

  String get _albumCacheKey {
    final id = widget.playlistId.trim();
    if (id.isNotEmpty) return 'id:$id';
    return 'meta:${widget.albumTitle.trim().toLowerCase()}::${widget.artistName.trim().toLowerCase()}';
  }

  void _storeAlbumSessionCache() {
    if (_loading || _error) return;
    _albumSessionCache[_albumCacheKey] = _AlbumPageCacheEntry(
      resolvedTitle: _resolvedTitle,
      resolvedArtist: _resolvedArtist,
      coverUrl: _coverUrl,
      tracks: List<Video>.from(_tracks),
      backgroundColor: _albumBackgroundColor,
    );
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
    unawaited(_loadAlbumTracks());
  }

  @override
  void dispose() {
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
              child: BackdropFilter(
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

  Widget _buildPlaylistStyleAlbumHeader(BuildContext context) {
    final cover = _effectiveCoverUrl();
    final animatedCutoutEnabled =
        context.watch<AppSettingsService?>()?.animatedCutoutCovers ?? true;
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

  Widget _buildPlaylistStyleAlbumTrackTile(
    BuildContext context,
    Video video,
    bool isDownloaded,
  ) {
    final card = DecoratedBox(
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
          context,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: CupertinoButton(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        onPressed: () => _playVideoPreferLocal(video),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    video.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: CupertinoTheme.of(context).textTheme.textStyle
                        .copyWith(
                          fontSize: 16,
                          color: CupertinoColors.label.resolveFrom(context),
                        ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    cleanArtistName(video.author),
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
            if (isDownloaded) ...[
              const SizedBox(width: 8),
              const Icon(
                CupertinoIcons.arrow_down_circle_fill,
                size: 16,
                color: CupertinoColors.systemGreen,
              ),
            ],
            CupertinoButton(
              padding: EdgeInsets.zero,
              minimumSize: const Size(30, 30),
              onPressed: () => _showTrackOptionsMenu(video),
              child: Icon(
                CupertinoIcons.ellipsis_circle,
                size: 22,
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            ),
          ],
        ),
      ),
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
      child: card,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: swipeCard,
    );
  }

  @override
  Widget build(BuildContext context) {
    final downloadService = context.watch<DownloadService>();
    final hasMiniPlayer = context.select<VideoPlayerManager, bool>(
      (playerManager) =>
          playerManager.currentVideoId != null && playerManager.isMinimized,
    );
    final bottomReserve = _rootBottomOverlayReserve(
      context,
      hasMiniPlayer: hasMiniPlayer,
    );
    final content = _loading
        ? SliverList(
            delegate: SliverChildListDelegate([
              _buildPlaylistStyleAlbumHeader(context),
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
              if (index == 0) return _buildPlaylistStyleAlbumHeader(context);
              if (index == _tracks.length + 1) {
                return SizedBox(height: bottomReserve);
              }
              final video = _tracks[index - 1];
              final isDownloaded =
                  downloadService.getDownloadStatus(video.id.value) ==
                  DownloadStatus.downloaded;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _buildPlaylistStyleAlbumTrackTile(
                  context,
                  video,
                  isDownloaded,
                ),
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
        child: BackdropFilter(
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
            filterQuality: FilterQuality.medium,
            errorBuilder: (context, error, stackTrace) => widget.fallback,
          )
        : Image.network(
            url,
            fit: BoxFit.cover,
            cacheWidth: coverCachePx,
            cacheHeight: coverCachePx,
            filterQuality: FilterQuality.medium,
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
                        filterQuality: FilterQuality.medium,
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
