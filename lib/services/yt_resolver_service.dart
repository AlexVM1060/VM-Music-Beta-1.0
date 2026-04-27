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
    defaultValue: 'http://136.119.37.116:10000',
  );
  static const String _apiKey = String.fromEnvironment(
    'YT_RESOLVER_API_KEY',
    defaultValue: '',
  );
  static const Duration _sendTimeout = Duration(seconds: 10);
  static const Duration _receiveTimeout = Duration(seconds: 40);

  bool get isConfigured => _baseUrl.trim().isNotEmpty;

  Future<YtResolverResult?> resolveVideo(String videoId) async {
    if (!isConfigured) return null;
    final cleanVideoId = videoId.trim();
    if (cleanVideoId.isEmpty) return null;

    final endpoint = '${_baseUrl.trim()}/resolve';
    log(
      '[yt-resolver-service] request videoId=$cleanVideoId endpoint=$endpoint',
    );
    final headers = <String, String>{};
    if (_apiKey.trim().isNotEmpty) {
      headers['x-api-key'] = _apiKey.trim();
    }

    final response = await _dio.get<dynamic>(
      endpoint,
      queryParameters: <String, dynamic>{'videoId': cleanVideoId},
      options: Options(
        headers: headers,
        validateStatus: (_) => true,
        sendTimeout: _sendTimeout,
        receiveTimeout: _receiveTimeout,
      ),
    );
    log(
      '[yt-resolver-service] response videoId=$cleanVideoId status=${response.statusCode}',
    );

    final data = response.data;
    if (response.statusCode != 200 || data is! Map) {
      log(
        '[yt-resolver-service] non-success videoId=$cleanVideoId status=${response.statusCode} body=${response.data}',
      );
      return null;
    }
    if (data['ok'] != true) return null;

    final sourceUrlRaw = (data['sourceUrl'] ?? '').toString().trim();
    final sourceProxyUrl = (data['sourceProxyUrl'] ?? '').toString().trim();
    final sourceUrl = sourceProxyUrl.isNotEmpty ? sourceProxyUrl : sourceUrlRaw;
    final isVideoSource = data['isVideoSource'] == true;

    String? audioUrl;
    final audio = data['audio'];
    if (audio is Map) {
      final raw = (audio['url'] ?? '').toString().trim();
      if (raw.isNotEmpty) audioUrl = raw;
    }
    final audioProxyUrl = (data['audioProxyUrl'] ?? '').toString().trim();
    if (audioProxyUrl.isNotEmpty) {
      audioUrl = audioProxyUrl;
    }

    String? muxedUrl;
    final muxed = data['muxed'];
    if (muxed is Map) {
      final raw = (muxed['url'] ?? '').toString().trim();
      if (raw.isNotEmpty) muxedUrl = raw;
    }
    final muxedProxyUrl = (data['muxedProxyUrl'] ?? '').toString().trim();
    if (muxedProxyUrl.isNotEmpty) {
      muxedUrl = muxedProxyUrl;
    }

    if (sourceUrl.isEmpty && audioUrl == null && muxedUrl == null) {
      return null;
    }

    return YtResolverResult(
      sourceUrl: sourceUrl,
      isVideoSource: isVideoSource,
      audioUrl: audioUrl,
      muxedUrl: muxedUrl,
    );
  }
}
