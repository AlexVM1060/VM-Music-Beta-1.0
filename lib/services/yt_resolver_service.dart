import 'dart:async';
import 'dart:developer';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

class YtResolverResult {
  final String sourceUrl;
  final bool isVideoSource;
  final String? audioUrl;
  final String? muxedUrl;

  const YtResolverResult({
    required this.sourceUrl,
    required this.isVideoSource,
    required this.audioUrl,
    required this.muxedUrl,
  });
}

class YtResolverService {
  YtResolverService({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  static const String _baseUrl = String.fromEnvironment(
    'YT_RESOLVER_BASE_URL',
    defaultValue: 'http://136.114.174.34:10000',
  );
  static const List<String> _fallbackBaseUrls = <String>[
    'http://34.28.151.222:10000',
    'http://35.202.25.111:10000',
  ];
  static const String _apiKey = String.fromEnvironment(
    'YT_RESOLVER_API_KEY',
    defaultValue: '',
  );
  static const Duration _sendTimeout = Duration(seconds: 10);
  static const Duration _receiveTimeout = Duration(seconds: 120);
  static const Duration _overallResolveTimeout = Duration(seconds: 25);
  static const Duration _failedBackendPenalty = Duration(seconds: 75);
  static final math.Random _random = math.Random();
  static String? _lastHealthyBaseUrl;
  static final Map<String, DateTime> _backendBlockedUntil = <String, DateTime>{};

  void _trace(String message) {
    log(message);
    // Asegura visibilidad en Debug Console de Flutter.
    debugPrint(message);
  }

  bool get isConfigured => _baseUrl.trim().isNotEmpty;

  Future<YtResolverResult?> resolveVideo(String videoId) async {
    if (!isConfigured) return null;
    final cleanVideoId = videoId.trim();
    if (cleanVideoId.isEmpty) return null;

    final candidateBases = _orderedCandidateBases();
    final headers = <String, String>{};
    if (_apiKey.trim().isNotEmpty) {
      headers['x-api-key'] = _apiKey.trim();
    }
    final resolveStartedAt = DateTime.now();
    final failedBasesInThisResolve = <String>{};
    for (final base in candidateBases) {
      final endpoint = _buildResolveEndpoint(base);
      final requestStartedAt = DateTime.now();
      _trace(
        '[yt-resolver-service] request videoId=$cleanVideoId endpoint=$endpoint',
      );
      if (endpoint == null) {
        continue;
      }
      try {
        final response = await _dio
            .get<dynamic>(
              endpoint,
              queryParameters: <String, dynamic>{'videoId': cleanVideoId},
              options: Options(
                headers: headers,
                validateStatus: (_) => true,
                sendTimeout: _sendTimeout,
                receiveTimeout: _receiveTimeout,
              ),
            )
            .timeout(_overallResolveTimeout);

        final data = response.data;
        _trace(
          '[yt-resolver-service] response videoId=$cleanVideoId status=${response.statusCode}',
        );
        if (response.statusCode == 200 && data is Map && data['ok'] == true) {
          final parsed = _parseResolveResponse(data);
          if (parsed != null) {
            final requestElapsedMs = DateTime.now()
                .difference(requestStartedAt)
                .inMilliseconds;
            final totalElapsedMs = DateTime.now()
                .difference(resolveStartedAt)
                .inMilliseconds;
            final requestElapsedSeconds =
                (requestElapsedMs / 1000).toStringAsFixed(2);
            final totalElapsedSeconds =
                (totalElapsedMs / 1000).toStringAsFixed(2);
            _trace(
              '[yt-resolver-service] resolved videoId=$cleanVideoId base=$base requestSec=$requestElapsedSeconds totalSec=$totalElapsedSeconds',
            );
            _markBackendHealthy(base);
            return parsed;
          }
        }
        _markBackendFailed(base);
        failedBasesInThisResolve.add(base);
      } on TimeoutException {
        _trace(
          '[yt-resolver-service] timeout videoId=$cleanVideoId after ${_overallResolveTimeout.inSeconds}s for endpoint=$endpoint',
        );
        _markBackendFailed(base);
        failedBasesInThisResolve.add(base);
      } catch (e) {
        _trace(
          '[yt-resolver-service] resolve failed videoId=$cleanVideoId endpoint=$endpoint',
        );
        log(
          '[yt-resolver-service] resolve failed videoId=$cleanVideoId endpoint=$endpoint',
          error: e,
        );
        _markBackendFailed(base);
        failedBasesInThisResolve.add(base);
      }
    }

    for (final base in candidateBases) {
      if (failedBasesInThisResolve.contains(base)) continue;
      final directMuxed = _buildMuxedProxyUrl(base, cleanVideoId);
      if (directMuxed == null || directMuxed.isEmpty) continue;
      final totalElapsedMs = DateTime.now()
          .difference(resolveStartedAt)
          .inMilliseconds;
      final totalElapsedSeconds = (totalElapsedMs / 1000).toStringAsFixed(2);
      _trace(
        '[yt-resolver-service] direct muxed fallback videoId=$cleanVideoId base=$base totalSec=$totalElapsedSeconds url=$directMuxed',
      );
      _markBackendHealthy(base);
      return YtResolverResult(
        sourceUrl: directMuxed,
        isVideoSource: true,
        audioUrl: null,
        muxedUrl: directMuxed,
      );
    }
    return null;
  }

  YtResolverResult? _parseResolveResponse(Map data) {
    String? readNestedUrl(Object? node) {
      if (node is! Map) return null;
      final raw = (node['url'] ?? '').toString().trim();
      return raw.isEmpty ? null : raw;
    }

    final sourceProxyUrl = (data['sourceProxyUrl'] ?? '').toString().trim();
    final sourceRaw = (data['sourceUrl'] ?? '').toString().trim();
    final sourceUrl = sourceProxyUrl.isNotEmpty ? sourceProxyUrl : sourceRaw;

    final muxedProxyUrl = (data['muxedProxyUrl'] ?? '').toString().trim();
    final muxedNested = readNestedUrl(data['muxed']);
    final muxedUrl = muxedProxyUrl.isNotEmpty ? muxedProxyUrl : muxedNested;

    final audioProxyUrl = (data['audioProxyUrl'] ?? '').toString().trim();
    final audioNested = readNestedUrl(data['audio']);
    final audioUrl = audioProxyUrl.isNotEmpty ? audioProxyUrl : audioNested;

    final preferred = (muxedUrl ?? '').trim().isNotEmpty
        ? muxedUrl!.trim()
        : sourceUrl.isNotEmpty
        ? sourceUrl
        : (audioUrl ?? '').trim();
    if (preferred.isEmpty) return null;

    final resolvedIsVideo = preferred == (muxedUrl ?? '').trim()
        ? true
        : preferred == sourceUrl
        ? data['isVideoSource'] == true
        : false;

    return YtResolverResult(
      sourceUrl: preferred,
      isVideoSource: resolvedIsVideo,
      audioUrl: (audioUrl ?? '').trim().isEmpty ? null : audioUrl!.trim(),
      muxedUrl: (muxedUrl ?? '').trim().isEmpty ? null : muxedUrl!.trim(),
    );
  }

  String? _buildResolveEndpoint(String baseUrl) {
    try {
      final normalizedBase = _normalizeBaseUrl(baseUrl);
      if (normalizedBase == null) return null;
      final baseUri = Uri.parse(normalizedBase);
      final segments = <String>[
        ...baseUri.pathSegments.where((segment) => segment.isNotEmpty),
        'resolve',
      ];
      return baseUri.replace(pathSegments: segments).toString();
    } catch (_) {
      return null;
    }
  }

  String? _buildMuxedProxyUrl(String baseUrl, String videoId) {
    try {
      final normalizedBase = _normalizeBaseUrl(baseUrl);
      if (normalizedBase == null) return null;
      final baseUri = Uri.parse(normalizedBase);
      final segments = <String>[
        ...baseUri.pathSegments.where((segment) => segment.isNotEmpty),
        'stream',
      ];
      return baseUri
          .replace(
            pathSegments: segments,
            queryParameters: <String, String>{
              'videoId': videoId,
              'kind': 'muxed',
            },
          )
          .toString();
    } catch (_) {
      return null;
    }
  }

  String? _normalizeBaseUrl(String rawBaseUrl) {
    var value = rawBaseUrl.trim();
    if (value.isEmpty) return null;
    value = value.replaceFirst(RegExp(r'^https?://https?://'), 'http://');
    value = value.replaceFirst(RegExp(r'/:([0-9]+)'), r':$1');
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      value = 'http://$value';
    }
    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty) return null;
    return uri.toString();
  }

  List<String> _orderedCandidateBases() {
    final unique = <String>[];
    final seen = <String>{};
    for (final raw in <String>[_baseUrl.trim(), ..._fallbackBaseUrls]) {
      final normalized = _normalizeBaseUrl(raw);
      if (normalized == null) continue;
      if (!seen.add(normalized)) continue;
      unique.add(normalized);
    }
    if (unique.isEmpty) return const <String>[];

    final now = DateTime.now();
    _backendBlockedUntil.removeWhere((key, until) => !until.isAfter(now));

    final available = unique
        .where((base) => !_backendBlockedUntil.containsKey(base))
        .toList(growable: false);
    final pool = available.isNotEmpty ? available : unique;

    final ordered = List<String>.from(pool);
    ordered.shuffle(_random);

    final preferred = _lastHealthyBaseUrl;
    if (preferred != null) {
      final idx = ordered.indexOf(preferred);
      if (idx > 0) {
        final base = ordered.removeAt(idx);
        ordered.insert(0, base);
      } else if (idx < 0 && pool.contains(preferred)) {
        ordered.insert(0, preferred);
      }
    }
    return ordered;
  }

  void _markBackendHealthy(String base) {
    _lastHealthyBaseUrl = base;
    _backendBlockedUntil.remove(base);
    _trace('[yt-resolver-service] backend healthy base=$base');
  }

  void _markBackendFailed(String base) {
    _backendBlockedUntil[base] = DateTime.now().add(_failedBackendPenalty);
    if (_lastHealthyBaseUrl == base) {
      _lastHealthyBaseUrl = null;
    }
    _trace(
      '[yt-resolver-service] backend penalized base=$base for ${_failedBackendPenalty.inSeconds}s',
    );
  }
}
