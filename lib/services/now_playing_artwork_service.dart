import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class NowPlayingArtworkService {
  static const double _zoom = 1.10;
  static const int _outputSize = 1024;
  static const int _maxCachedFiles = 120;
  static const String _cacheDirName = 'now_playing_artwork';
  static const String _cacheVersion = 'v1';

  final Map<String, Future<Uri?>> _inFlight = {};

  Future<Uri?> resolveNowPlayingArtUri({
    required String videoId,
    required String? thumbnailSource,
  }) async {
    final source = thumbnailSource?.trim() ?? '';
    if (source.isEmpty || videoId.trim().isEmpty) return null;

    final key = _buildCacheKey(videoId: videoId.trim(), source: source);
    final existing = _inFlight[key];
    if (existing != null) return existing;

    final future = _resolveInternal(
      videoId: videoId.trim(),
      source: source,
      cacheKey: key,
    );
    _inFlight[key] = future;
    try {
      return await future;
    } finally {
      _inFlight.remove(key);
    }
  }

  Future<Uri?> _resolveInternal({
    required String videoId,
    required String source,
    required String cacheKey,
  }) async {
    try {
      final cacheDir = await _cacheDir();
      final target = File('${cacheDir.path}/${videoId}_$cacheKey.png');
      if (await target.exists() && await target.length() > 0) {
        return Uri.file(target.path);
      }

      final bytes = await _readSourceBytes(source);
      if (bytes == null || bytes.isEmpty) return null;

      final processedBytes = await _cropSquarePng(bytes, zoom: _zoom, outputSize: _outputSize);
      if (processedBytes == null || processedBytes.isEmpty) return null;

      await target.writeAsBytes(processedBytes, flush: true);
      unawaited(_trimCache(cacheDir));
      return Uri.file(target.path);
    } catch (_) {
      return null;
    }
  }

  Future<Directory> _cacheDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/$_cacheDirName');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<Uint8List?> _readSourceBytes(String source) async {
    if (source.startsWith('/')) {
      final file = File(source);
      if (!await file.exists()) return null;
      return file.readAsBytes();
    }

    final uri = Uri.tryParse(source);
    if (uri == null) return null;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(uri).timeout(const Duration(seconds: 15));
      final res = await req.close().timeout(const Duration(seconds: 20));
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final data = await consolidateHttpClientResponseBytes(res);
      return data;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<Uint8List?> _cropSquarePng(
    Uint8List input, {
    required double zoom,
    required int outputSize,
  }) async {
    ui.Codec? codec;
    ui.Image? decoded;
    ui.Image? rendered;
    try {
      codec = await ui.instantiateImageCodec(input);
      final frame = await codec.getNextFrame();
      decoded = frame.image;
      final width = decoded.width.toDouble();
      final height = decoded.height.toDouble();
      if (width <= 0 || height <= 0) return null;

      final minSide = width < height ? width : height;
      final safeZoom = zoom <= 0 ? 1.0 : zoom;
      final srcSide = (minSide / safeZoom).clamp(1.0, minSide);
      final src = ui.Rect.fromLTWH(
        (width - srcSide) / 2,
        (height - srcSide) / 2,
        srcSide,
        srcSide,
      );
      final dst = ui.Rect.fromLTWH(0, 0, outputSize.toDouble(), outputSize.toDouble());

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      final paint = ui.Paint()..filterQuality = ui.FilterQuality.high;
      canvas.drawImageRect(decoded, src, dst, paint);
      final picture = recorder.endRecording();
      rendered = await picture.toImage(outputSize, outputSize);
      final byteData = await rendered.toByteData(format: ui.ImageByteFormat.png);
      return byteData?.buffer.asUint8List();
    } catch (_) {
      return null;
    } finally {
      decoded?.dispose();
      rendered?.dispose();
      codec?.dispose();
    }
  }

  String _buildCacheKey({
    required String videoId,
    required String source,
  }) {
    final payload = '$videoId|$source|$_zoom|$_outputSize|$_cacheVersion';
    return _fnv1a64(payload).toRadixString(16);
  }

  int _fnv1a64(String input) {
    const int fnvOffsetBasis = 0xcbf29ce484222325;
    const int fnvPrime = 0x100000001b3;
    var hash = fnvOffsetBasis;
    final bytes = input.codeUnits;
    for (final b in bytes) {
      hash ^= b;
      hash = (hash * fnvPrime) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash;
  }

  Future<void> _trimCache(Directory cacheDir) async {
    try {
      final files = await cacheDir.list().where((e) => e is File).cast<File>().toList();
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
      // Ignoramos errores de limpieza de caché.
    }
  }
}
