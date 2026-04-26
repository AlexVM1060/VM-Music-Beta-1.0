import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class AiCoverAnimationService {
  AiCoverAnimationService({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  static const String _baseUrl = String.fromEnvironment(
    'COVER_ANIMATION_API_BASE_URL',
    defaultValue: 'https://vmmusic-backend.onrender.com',
  );
  static const String _apiKey = String.fromEnvironment(
    'COVER_ANIMATION_API_KEY',
    defaultValue: '',
  );
  static const bool _usePublicFallback = bool.fromEnvironment(
    'COVER_ANIMATION_USE_PUBLIC_FALLBACK',
    defaultValue: true,
  );
  static const String _publicSpaceBaseUrl = String.fromEnvironment(
    'PUBLIC_COVER_ANIMATION_SPACE_URL',
    defaultValue: 'https://multimodalart-stable-video-diffusion.hf.space',
  );
  static const String _publicSpaceApiName = String.fromEnvironment(
    'PUBLIC_COVER_ANIMATION_SPACE_API_NAME',
    defaultValue: 'video',
  );
  static const String _publicSpaceToken = String.fromEnvironment(
    'PUBLIC_COVER_ANIMATION_SPACE_TOKEN',
    defaultValue: '',
  );
  static const int _publicMotionBucketId = int.fromEnvironment(
    'PUBLIC_COVER_ANIMATION_MOTION_BUCKET_ID',
    defaultValue: 200,
  );
  static const int _publicFpsId = int.fromEnvironment(
    'PUBLIC_COVER_ANIMATION_FPS_ID',
    defaultValue: 6,
  );

  final Map<String, String?> _cache = <String, String?>{};
  final Map<String, Future<String?>> _requests = <String, Future<String?>>{};
  final Map<String, Future<String?>> _persistRequests =
      <String, Future<String?>>{};
  static const String _cacheDirName = 'ai_cover_animation_cache';
  static const String _cacheVersion = 'v2';
  static const int _maxCachedFiles = 80;

  bool get isConfigured =>
      _baseUrl.trim().isNotEmpty ||
      (_usePublicFallback && _publicSpaceBaseUrl.trim().isNotEmpty);

  Future<String?> requestAnimatedCoverUrl({
    required String trackId,
    required String sourceUrl,
    Uint8List? sourceBytes,
    String? sourceFilename,
  }) async {
    final cleanTrackId = trackId.trim();
    final cleanSource = sourceUrl.trim();
    if (!isConfigured || cleanTrackId.isEmpty || cleanSource.isEmpty) {
      return null;
    }

    final cacheKey =
        '$cleanTrackId|$cleanSource|${_bytesSignature(sourceBytes)}';
    if (_cache.containsKey(cacheKey)) {
      return _cache[cacheKey];
    }
    final persisted = await _readPersistedAnimatedCover(cacheKey);
    if (persisted != null && persisted.isNotEmpty) {
      _cache[cacheKey] = persisted;
      return persisted;
    }
    final inFlight = _requests[cacheKey];
    if (inFlight != null) return inFlight;

    final request = _requestAnimatedCoverUrl(
      trackId: cleanTrackId,
      sourceUrl: cleanSource,
      sourceBytes: sourceBytes,
      sourceFilename: sourceFilename,
    );
    _requests[cacheKey] = request;
    try {
      final resolved = await request;
      final persistedResult = await _persistAnimatedCoverIfNeeded(
        cacheKey,
        resolved,
      );
      _cache[cacheKey] = persistedResult;
      return persistedResult;
    } finally {
      if (identical(_requests[cacheKey], request)) {
        _requests.remove(cacheKey);
      }
    }
  }

  Future<String?> _requestAnimatedCoverUrl({
    required String trackId,
    required String sourceUrl,
    Uint8List? sourceBytes,
    String? sourceFilename,
  }) async {
    final customBase = _baseUrl.trim();
    if (customBase.isNotEmpty && _looksLikeHttpUrl(sourceUrl)) {
      try {
        final fromCustom = await _requestFromCustomBackend(
          baseUrl: customBase,
          trackId: trackId,
          sourceUrl: sourceUrl,
        );
        if ((fromCustom ?? '').trim().isNotEmpty) {
          return fromCustom;
        }
      } catch (_) {
        // Si el backend custom falla, intentamos fallback público.
      }
    }
    if (_usePublicFallback && _publicSpaceBaseUrl.trim().isNotEmpty) {
      return _requestFromPublicGradioSpace(
        sourceUrl: sourceUrl,
        sourceBytes: sourceBytes,
        sourceFilename: sourceFilename,
      );
    }
    return null;
  }

  Future<String?> _requestFromCustomBackend({
    required String baseUrl,
    required String trackId,
    required String sourceUrl,
  }) async {
    final endpoint = '$baseUrl/cover/animate';
    final headers = <String, String>{};
    if (_apiKey.trim().isNotEmpty) {
      headers['x-api-key'] = _apiKey.trim();
    }

    final response = await _dio.post<dynamic>(
      endpoint,
      data: <String, dynamic>{
        'trackId': trackId,
        'sourceUrl': sourceUrl,
        'loopMode': 'boomerang',
      },
      options: Options(
        headers: headers,
        sendTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 45),
      ),
    );

    final data = response.data;
    if (response.statusCode != 200 || data is! Map) return null;
    if (data['ok'] != true) return null;
    final animatedUrl = (data['animatedCoverUrl'] ?? '').toString().trim();
    if (animatedUrl.isEmpty) return null;
    return animatedUrl;
  }

  Future<String?> _requestFromPublicGradioSpace({
    required String sourceUrl,
    Uint8List? sourceBytes,
    String? sourceFilename,
  }) async {
    final base = _publicSpaceBaseUrl.trim().replaceFirst(RegExp(r'/$'), '');
    final apiNames = _candidateApiNames();
    if (base.isEmpty || apiNames.isEmpty) return null;

    final headers = <String, String>{};
    final token = _publicSpaceToken.trim();
    if (token.isNotEmpty) {
      headers['authorization'] = 'Bearer $token';
    }

    final queueDataCandidates = <dynamic>[];
    final uploadedPath = await _uploadSourceToGradio(
      base: base,
      headers: headers,
      sourceBytes: sourceBytes,
      sourceFilename: sourceFilename,
    );
    if (uploadedPath != null && uploadedPath.isNotEmpty) {
      queueDataCandidates.add(<String, dynamic>{
        'path': uploadedPath,
        'url': _normalizePotentialUrl(uploadedPath, base: base),
        'meta': <String, dynamic>{'_type': 'gradio.FileData'},
      });
      queueDataCandidates.add(uploadedPath);
    }
    if (_looksLikeHttpUrl(sourceUrl)) {
      queueDataCandidates.add(<String, dynamic>{
        'path': sourceUrl,
        'url': sourceUrl,
        'meta': <String, dynamic>{'_type': 'gradio.FileData'},
      });
      queueDataCandidates.add(sourceUrl);
    }
    if (queueDataCandidates.isEmpty) return null;
    final motionBucketId = _publicMotionBucketId.clamp(1, 255);
    final fpsId = _publicFpsId.clamp(5, 30);

    for (final apiName in apiNames) {
      final callEndpoint = '$base/gradio_api/call/$apiName';
      for (final imageInput in queueDataCandidates) {
        try {
          final queueResponse = await _dio.post<dynamic>(
            callEndpoint,
            data: <String, dynamic>{
              'data': <dynamic>[
                imageInput,
                42, // seed
                true, // randomize_seed
                motionBucketId, // motion_bucket_id
                fpsId, // fps_id
              ],
            },
            options: Options(
              headers: headers,
              sendTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 25),
            ),
          );
          final queueBody = queueResponse.data;
          if (queueResponse.statusCode != 200 || queueBody is! Map) {
            continue;
          }
          final eventId = (queueBody['event_id'] ?? '').toString().trim();
          if (eventId.isEmpty) continue;

          final eventUrl = '$callEndpoint/$eventId';
          final streamResponse = await _dio.get<ResponseBody>(
            eventUrl,
            options: Options(
              headers: headers,
              responseType: ResponseType.stream,
              receiveTimeout: const Duration(minutes: 3),
            ),
          );
          final stream = streamResponse.data?.stream;
          if (stream == null) continue;
          final byteStream = stream.map(
            (chunk) => chunk.toList(growable: false),
          );

          String? lastData;
          String? bestUrl;
          await for (final line
              in byteStream
                  .transform(utf8.decoder)
                  .transform(const LineSplitter())) {
            final trimmed = line.trim();
            if (trimmed.startsWith('data:')) {
              final payload = trimmed.substring(5).trim();
              if (payload.isNotEmpty && payload != '[DONE]') {
                lastData = payload;
                final fromChunk = _extractVideoUrlFromPayload(
                  payload,
                  base: base,
                  sourceUrl: sourceUrl,
                );
                if (fromChunk != null) {
                  bestUrl = fromChunk;
                }
              }
              continue;
            }
            if (trimmed == 'event: complete' || trimmed == 'event: completed') {
              if (bestUrl != null) return bestUrl;
              if (lastData != null && lastData.isNotEmpty) {
                final fromLast = _extractVideoUrlFromPayload(
                  lastData,
                  base: base,
                  sourceUrl: sourceUrl,
                );
                if (fromLast != null) return fromLast;
              }
              break;
            }
            if (trimmed == 'event: error' || trimmed == 'event: failed') {
              break;
            }
          }
        } catch (_) {
          // Intentamos el siguiente formato de payload/API name.
        }
      }
    }
    return null;
  }

  List<String> _candidateApiNames() {
    final raw = _publicSpaceApiName.trim().replaceFirst(RegExp(r'^/+'), '');
    final out = <String>[];
    void add(String value) {
      final clean = value.trim().replaceFirst(RegExp(r'^/+'), '');
      if (clean.isEmpty) return;
      if (!out.contains(clean)) out.add(clean);
    }

    add(raw);
    add('video');
    add('predict');
    return out;
  }

  Future<String?> _uploadSourceToGradio({
    required String base,
    required Map<String, String> headers,
    Uint8List? sourceBytes,
    String? sourceFilename,
  }) async {
    final bytes = sourceBytes;
    if (bytes == null || bytes.isEmpty) return null;

    final filename = _sanitizeFilename(sourceFilename);
    final endpoints = <String>['$base/gradio_api/upload', '$base/upload'];
    for (final endpoint in endpoints) {
      final payloads = <FormData>[
        FormData.fromMap({
          'files': [
            MultipartFile.fromBytes(
              bytes,
              filename: filename,
              contentType: _guessImageMediaType(filename),
            ),
          ],
        }),
        FormData.fromMap({
          'files': MultipartFile.fromBytes(
            bytes,
            filename: filename,
            contentType: _guessImageMediaType(filename),
          ),
        }),
      ];
      for (final body in payloads) {
        try {
          final response = await _dio.post<dynamic>(
            endpoint,
            data: body,
            options: Options(
              headers: headers,
              sendTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 25),
            ),
          );
          if (response.statusCode != 200) continue;
          final path = _extractUploadedPath(response.data);
          if (path != null && path.trim().isNotEmpty) {
            return path.trim();
          }
        } catch (_) {
          // Intentamos siguiente forma/end-point.
        }
      }
    }
    return null;
  }

  String? _extractUploadedPath(dynamic node) {
    if (node == null) return null;
    if (node is String) {
      final clean = node.trim();
      return clean.isEmpty ? null : clean;
    }
    if (node is List) {
      for (final item in node) {
        final found = _extractUploadedPath(item);
        if (found != null) return found;
      }
      return null;
    }
    if (node is Map) {
      const keys = <String>['path', 'name', 'url', 'file', 'files', 'data'];
      for (final key in keys) {
        if (!node.containsKey(key)) continue;
        final found = _extractUploadedPath(node[key]);
        if (found != null) return found;
      }
      for (final value in node.values) {
        final found = _extractUploadedPath(value);
        if (found != null) return found;
      }
    }
    return null;
  }

  String? _extractVideoUrlFromGradioResult(
    dynamic node, {
    required String base,
    required String sourceUrl,
  }) {
    final candidates = <String>{};
    _collectPotentialUrls(node, base: base, out: candidates);
    if (candidates.isEmpty) return null;

    final ordered = candidates.toList(growable: false)
      ..sort(
        (a, b) =>
            _scoreCandidateUrl(b, sourceUrl) - _scoreCandidateUrl(a, sourceUrl),
      );
    final best = ordered.first;
    if (_scoreCandidateUrl(best, sourceUrl) < 0) return null;
    return best;
  }

  String? _extractVideoUrlFromPayload(
    String payload, {
    required String base,
    required String sourceUrl,
  }) {
    try {
      final parsed = jsonDecode(payload);
      return _extractVideoUrlFromGradioResult(
        parsed,
        base: base,
        sourceUrl: sourceUrl,
      );
    } catch (_) {
      return _normalizePotentialUrl(payload, base: base);
    }
  }

  void _collectPotentialUrls(
    dynamic node, {
    required String base,
    required Set<String> out,
  }) {
    if (node == null) return;
    if (node is String) {
      final normalized = _normalizePotentialUrl(node, base: base);
      if (normalized != null) out.add(normalized);
      return;
    }
    if (node is List) {
      for (final item in node) {
        _collectPotentialUrls(item, base: base, out: out);
      }
      return;
    }
    if (node is Map) {
      for (final value in node.values) {
        _collectPotentialUrls(value, base: base, out: out);
      }
    }
  }

  int _scoreCandidateUrl(String candidate, String sourceUrl) {
    final value = candidate.trim().toLowerCase();
    if (value.isEmpty) return -1000;
    final source = sourceUrl.trim().toLowerCase();
    if (source.isNotEmpty && value == source) return -800;

    var score = 0;
    if (RegExp(r'\.(mp4|mov|m4v|m3u8|webm)(\?|#|$)').hasMatch(value)) {
      score += 120;
    }
    if (value.contains('/video/') ||
        value.contains('/videos/') ||
        value.contains('video=')) {
      score += 80;
    }
    if (value.contains('/gradio_api/file=')) {
      score += 70;
    }
    if (value.contains('/tmp/gradio/') || value.contains('/tmp/')) {
      score += 34;
    }
    if (value.contains('.hf.space')) {
      score += 10;
    }
    if (RegExp(r'\.(jpg|jpeg|png|webp|bmp|avif)(\?|#|$)').hasMatch(value)) {
      score -= 90;
    }
    return score;
  }

  String? _normalizePotentialUrl(String raw, {required String base}) {
    final value = raw.trim();
    if (value.isEmpty) return null;
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return value;
    }
    if (value.startsWith('/gradio_api/file=') || value.startsWith('/file=')) {
      return '$base$value';
    }
    if (value.startsWith('gradio_api/file=')) {
      return '$base/$value';
    }
    if (value.startsWith('/tmp/')) {
      return '$base/gradio_api/file=$value';
    }
    if (value.startsWith('/')) {
      return '$base$value';
    }
    return null;
  }

  bool _looksLikeHttpUrl(String raw) {
    final value = raw.trim().toLowerCase();
    return value.startsWith('http://') || value.startsWith('https://');
  }

  String _bytesSignature(Uint8List? bytes) {
    if (bytes == null || bytes.isEmpty) return 'none';
    final len = bytes.length;
    final first = bytes.first;
    final mid = bytes[len ~/ 2];
    final last = bytes.last;
    return '$len:$first:$mid:$last';
  }

  String _sanitizeFilename(String? raw) {
    final source = (raw ?? '').trim();
    if (source.isEmpty) return 'cover.jpg';
    final safe = source.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    if (safe.isEmpty) return 'cover.jpg';
    return safe;
  }

  DioMediaType _guessImageMediaType(String filename) {
    final value = filename.toLowerCase();
    if (value.endsWith('.png')) return DioMediaType.parse('image/png');
    if (value.endsWith('.webp')) return DioMediaType.parse('image/webp');
    if (value.endsWith('.gif')) return DioMediaType.parse('image/gif');
    if (value.endsWith('.bmp')) return DioMediaType.parse('image/bmp');
    if (value.endsWith('.avif')) return DioMediaType.parse('image/avif');
    return DioMediaType.parse('image/jpeg');
  }

  Future<String?> _readPersistedAnimatedCover(String cacheKey) async {
    try {
      final file = await _persistedFileFor(cacheKey);
      if (!await file.exists()) return null;
      final length = await file.length();
      if (length <= 0) {
        try {
          await file.delete();
        } catch (_) {}
        return null;
      }
      return file.path;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _persistAnimatedCoverIfNeeded(
    String cacheKey,
    String? resolved,
  ) async {
    final normalized = (resolved ?? '').trim();
    if (normalized.isEmpty) return null;
    if (normalized.startsWith('/')) return normalized;
    if (!_looksLikeHttpUrl(normalized)) return normalized;

    final inFlight = _persistRequests[cacheKey];
    if (inFlight != null) return inFlight;

    final request = _downloadAndPersistAnimatedCover(cacheKey, normalized);
    _persistRequests[cacheKey] = request;
    try {
      return await request;
    } finally {
      if (identical(_persistRequests[cacheKey], request)) {
        _persistRequests.remove(cacheKey);
      }
    }
  }

  Future<String?> _downloadAndPersistAnimatedCover(
    String cacheKey,
    String remoteUrl,
  ) async {
    try {
      final file = await _persistedFileFor(cacheKey);
      if (await file.exists() && await file.length() > 0) {
        return file.path;
      }
      final uri = Uri.tryParse(remoteUrl);
      if (uri == null) return remoteUrl;

      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 18);
      try {
        final req = await client
            .getUrl(uri)
            .timeout(const Duration(seconds: 18));
        req.headers.set(
          HttpHeaders.userAgentHeader,
          'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)',
        );
        final res = await req.close().timeout(const Duration(seconds: 45));
        if (res.statusCode < 200 || res.statusCode >= 300) return remoteUrl;
        final bytes = await consolidateHttpClientResponseBytes(res);
        if (bytes.isEmpty) return remoteUrl;
        await file.writeAsBytes(bytes, flush: true);
      } finally {
        client.close(force: true);
      }
      unawaited(_trimCache());
      return file.path;
    } catch (_) {
      return remoteUrl;
    }
  }

  Future<File> _persistedFileFor(String cacheKey) async {
    final dir = await _cacheDir();
    final key = _hashKey('$cacheKey|$_cacheVersion');
    return File('${dir.path}/$key.mp4');
  }

  Future<Directory> _cacheDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/$_cacheDirName');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  String _hashKey(String payload) {
    var hash = 0xcbf29ce484222325;
    const prime = 0x100000001b3;
    for (final unit in payload.codeUnits) {
      hash ^= unit;
      hash = (hash * prime) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16);
  }

  Future<void> _trimCache() async {
    try {
      final dir = await _cacheDir();
      final files = await dir
          .list()
          .where((entity) => entity is File)
          .cast<File>()
          .toList();
      if (files.length <= _maxCachedFiles) return;
      files.sort(
        (a, b) => a.statSync().modified.compareTo(b.statSync().modified),
      );
      final deleteCount = files.length - _maxCachedFiles;
      for (var i = 0; i < deleteCount; i++) {
        try {
          await files[i].delete();
        } catch (_) {}
      }
    } catch (_) {
      // Best effort.
    }
  }
}
