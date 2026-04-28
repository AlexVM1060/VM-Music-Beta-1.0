import 'dart:async';
import 'dart:developer';

import 'package:dio/dio.dart';

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
  static const String _apiKey = String.fromEnvironment(
    'YT_RESOLVER_API_KEY',
    defaultValue: '',
  );
  static const Duration _sendTimeout = Duration(seconds: 10);
  static const Duration _receiveTimeout = Duration(seconds: 120);
  static const Duration _overallResolveTimeout = Duration(seconds: 25);

  bool get isConfigured => _baseUrl.trim().isNotEmpty;

  Future<YtResolverResult?> resolveVideo(String videoId) async {
    if (!isConfigured) return null;
    final cleanVideoId = videoId.trim();
    if (cleanVideoId.isEmpty) return null;

    final base = _baseUrl.trim();
    final directMuxed = _buildMuxedProxyUrl(base, cleanVideoId);
    final endpoint = _buildResolveEndpoint(base);
    final headers = <String, String>{};
    if (_apiKey.trim().isNotEmpty) {
      headers['x-api-key'] = _apiKey.trim();
    }
    log(
      '[yt-resolver-service] request videoId=$cleanVideoId endpoint=$endpoint',
    );

    if (endpoint != null) {
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
        log(
          '[yt-resolver-service] response videoId=$cleanVideoId status=${response.statusCode}',
        );
        if (response.statusCode == 200 && data is Map && data['ok'] == true) {
          final parsed = _parseResolveResponse(data);
          if (parsed != null) {
            return parsed;
          }
        }
      } on TimeoutException {
        log(
          '[yt-resolver-service] timeout videoId=$cleanVideoId after ${_overallResolveTimeout.inSeconds}s; fallback to direct stream',
        );
      } catch (e) {
        log(
          '[yt-resolver-service] resolve failed videoId=$cleanVideoId; fallback to direct stream',
          error: e,
        );
      }
    }

    if (directMuxed == null || directMuxed.isEmpty) {
      log('[yt-resolver-service] invalid base url: $base');
      return null;
    }
    log(
      '[yt-resolver-service] direct muxed fallback videoId=$cleanVideoId url=$directMuxed',
    );
    return YtResolverResult(
      sourceUrl: directMuxed,
      isVideoSource: true,
      audioUrl: null,
      muxedUrl: directMuxed,
    );
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
}
