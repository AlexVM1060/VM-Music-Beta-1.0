import 'package:dio/dio.dart';

class AiStemsService {
  AiStemsService({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  static const String _baseUrl = String.fromEnvironment(
    'STEMS_API_BASE_URL',
    defaultValue: '',
  );
  static const String _apiKey = String.fromEnvironment(
    'STEMS_API_KEY',
    defaultValue: '',
  );

  bool get isConfigured => _baseUrl.trim().isNotEmpty;

  Future<String?> requestInstrumentalUrl({
    required String trackId,
    required String sourceUrl,
  }) async {
    if (!isConfigured) return null;
    final base = _baseUrl.trim();
    final endpoint = '$base/stems/separate';

    final headers = <String, String>{};
    if (_apiKey.trim().isNotEmpty) {
      headers['x-api-key'] = _apiKey.trim();
    }

    final response = await _dio.post<dynamic>(
      endpoint,
      data: <String, dynamic>{
        'trackId': trackId.trim(),
        'sourceUrl': sourceUrl.trim(),
      },
      options: Options(
        headers: headers,
        sendTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(minutes: 8),
      ),
    );

    final data = response.data;
    if (response.statusCode != 200 || data is! Map) return null;
    final ok = data['ok'] == true;
    if (!ok) return null;
    final raw = (data['instrumentalUrl'] ?? '').toString().trim();
    if (raw.isEmpty) return null;
    return raw;
  }
}
