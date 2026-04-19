import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

class AppUpdateInfo {
  final String currentVersion;
  final String latestVersion;
  final bool force;
  final String title;
  final String message;
  final String storeUrl;

  const AppUpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.force,
    required this.title,
    required this.message,
    required this.storeUrl,
  });
}

class AppUpdateService {
  static const String _configUrl =
      'https://raw.githubusercontent.com/AlexVM1060/VM-Music-Beta-1.0/refs/heads/master/versionupdate.json';
  static bool _checkedThisSession = false;

  Future<AppUpdateInfo?> checkForUpdate() async {
    if (_checkedThisSession) return null;
    _checkedThisSession = true;
    if (kIsWeb) return null;
    if (!Platform.isIOS && !Platform.isAndroid) return null;

    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version.trim();
      if (currentVersion.isEmpty) return null;

      final payload = await _fetchRemotePayload();
      if (payload == null) return null;

      final latestVersion = (payload['latestVersion'] ?? '').toString().trim();
      final minimumSupportedVersion = (payload['minimumSupportedVersion'] ?? '')
          .toString()
          .trim();
      final forceFromPayload = payload['force'] == true;
      final title = ((payload['title'] ?? '').toString().trim()).isNotEmpty
          ? (payload['title'] as String).trim()
          : 'Nueva actualización disponible';
      final message = ((payload['message'] ?? '').toString().trim()).isNotEmpty
          ? (payload['message'] as String).trim()
          : 'Hay una nueva versión de la app.';

      final storeUrl = Platform.isIOS
          ? (payload['storeUrlIos'] ?? '').toString().trim()
          : (payload['storeUrlAndroid'] ?? '').toString().trim();
      if (storeUrl.isEmpty) return null;
      if (latestVersion.isEmpty) return null;

      final hasUpdate = _compareVersions(currentVersion, latestVersion) < 0;
      final belowMinimum =
          minimumSupportedVersion.isNotEmpty &&
          _compareVersions(currentVersion, minimumSupportedVersion) < 0;
      final forceUpdate = forceFromPayload || belowMinimum;

      if (!hasUpdate && !forceUpdate) return null;

      return AppUpdateInfo(
        currentVersion: currentVersion,
        latestVersion: latestVersion,
        force: forceUpdate,
        title: title,
        message: message,
        storeUrl: storeUrl,
      );
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _fetchRemotePayload() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client
          .getUrl(Uri.parse(_configUrl))
          .timeout(const Duration(seconds: 8));
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final res = await req.close().timeout(const Duration(seconds: 10));
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

  int _compareVersions(String a, String b) {
    final aParts = _toNumericParts(a);
    final bParts = _toNumericParts(b);
    final maxLen = aParts.length > bParts.length
        ? aParts.length
        : bParts.length;
    for (var i = 0; i < maxLen; i++) {
      final left = i < aParts.length ? aParts[i] : 0;
      final right = i < bParts.length ? bParts[i] : 0;
      if (left != right) return left.compareTo(right);
    }
    return 0;
  }

  List<int> _toNumericParts(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) return const <int>[0];
    final segments = normalized.split('.');
    final out = <int>[];
    for (final segment in segments) {
      final match = RegExp(r'^\d+').firstMatch(segment.trim());
      if (match == null) {
        out.add(0);
      } else {
        out.add(int.tryParse(match.group(0) ?? '') ?? 0);
      }
    }
    return out;
  }
}
