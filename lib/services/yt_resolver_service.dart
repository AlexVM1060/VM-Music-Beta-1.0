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
    defaultValue: 'https://vmmusic-backend.onrender.com',
  );
  static const String _apiKey = String.fromEnvironment(
    'YT_RESOLVER_API_KEY',
    defaultValue: '',
  );

  bool get isConfigured => _baseUrl.trim().isNotEmpty;

  Future<YtResolverResult?> resolveVideo(String videoId) async {
    if (!isConfigured) return null;
    final cleanVideoId = videoId.trim();
    if (cleanVideoId.isEmpty) return null;

    final endpoint = '${_baseUrl.trim()}/resolve';
    log('[yt-resolver-service] request videoId=$cleanVideoId endpoint=$endpoint');
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
        sendTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 12),
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

    final sourceUrl = (data['sourceUrl'] ?? '').toString().trim();
    final isVideoSource = data['isVideoSource'] == true;

    String? audioUrl;
    final audio = data['audio'];
    if (audio is Map) {
      final raw = (audio['url'] ?? '').toString().trim();
      if (raw.isNotEmpty) audioUrl = raw;
    }

    String? muxedUrl;
    final muxed = data['muxed'];
    if (muxed is Map) {
      final raw = (muxed['url'] ?? '').toString().trim();
      if (raw.isNotEmpty) muxedUrl = raw;
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
