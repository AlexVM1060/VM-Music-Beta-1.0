import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

class ArtworkSubjectCutoutService {
  static final Map<String, Future<Uint8List?>> _cutoutCache = {};
  static const MethodChannel _nativeChannel = MethodChannel('com.vm.music.beta/artwork_cutout');

  static Future<Uint8List?> buildCutout({
    required String cacheKey,
    required Uint8List sourceBytes,
    double viewportZoom = 1.0,
  }) {
    return _cutoutCache.putIfAbsent(
      cacheKey,
      () async {
        final payload = <String, Object>{
          'bytes': sourceBytes,
          'viewportZoom': viewportZoom,
        };

        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
          try {
            final native = await _nativeChannel.invokeMethod<Uint8List>(
              'extractSubjectCutout',
              payload,
            );
            if (native != null && native.isNotEmpty) {
              return native;
            }
          } catch (_) {
            // Fallback to Dart implementation when native Vision is unavailable.
          }
        }

        return compute(_buildCutoutWorker, payload);
      },
    );
  }

  static void evict(String cacheKey) {
    _cutoutCache.remove(cacheKey);
  }

  static void clear() {
    _cutoutCache.clear();
  }
}

Uint8List? _buildCutoutWorker(Map<String, Object> payload) {
  final sourceBytes = payload['bytes'] as Uint8List;
  // Mantener lectura para compatibilidad de payload/cache aunque no se use.
  final _ = (payload['viewportZoom'] as num?)?.toDouble() ?? 1.0;

  final decoded = img.decodeImage(sourceBytes);
  if (decoded == null) return null;

  // Usar imagen cruda completa para el recorte de sujeto.
  final src = decoded;

  final maxSide = math.max(src.width, src.height);
  final targetSide = maxSide > 196 ? 196 : maxSide;
  if (targetSide < 40) return null;

  final work = img.copyResize(
    src,
    width: (src.width * targetSide / maxSide).round(),
    height: (src.height * targetSide / maxSide).round(),
    interpolation: img.Interpolation.average,
  );

  final w = work.width;
  final h = work.height;
  final size = w * h;

  final luminance = Float32List(size);
  final saturation = Float32List(size);

  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = work.getPixel(x, y);
      final r = p.r.toDouble();
      final g = p.g.toDouble();
      final b = p.b.toDouble();
      final maxRgb = math.max(r, math.max(g, b));
      final minRgb = math.min(r, math.min(g, b));
      final idx = y * w + x;
      luminance[idx] = (0.2126 * r + 0.7152 * g + 0.0722 * b).toDouble();
      saturation[idx] = maxRgb <= 0 ? 0 : ((maxRgb - minRgb) / maxRgb).toDouble();
    }
  }

  final edge = Float32List(size);
  var maxEdge = 0.0;
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final i00 = (y - 1) * w + (x - 1);
      final i01 = (y - 1) * w + x;
      final i02 = (y - 1) * w + (x + 1);
      final i10 = y * w + (x - 1);
      final i12 = y * w + (x + 1);
      final i20 = (y + 1) * w + (x - 1);
      final i21 = (y + 1) * w + x;
      final i22 = (y + 1) * w + (x + 1);

      final gx =
          -luminance[i00] + luminance[i02] - 2 * luminance[i10] + 2 * luminance[i12] - luminance[i20] + luminance[i22];
      final gy =
          luminance[i00] + 2 * luminance[i01] + luminance[i02] - luminance[i20] - 2 * luminance[i21] - luminance[i22];
      final mag = math.sqrt((gx * gx) + (gy * gy));
      final idx = y * w + x;
      edge[idx] = mag.toDouble();
      if (mag > maxEdge) maxEdge = mag;
    }
  }

  if (maxEdge <= 0) {
    return _fallbackEllipseCutout(src);
  }

  final saliency = Float32List(size);
  var sum = 0.0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final idx = y * w + x;
      final nx = (x + 0.5) / w - 0.5;
      final ny = (y + 0.5) / h - 0.5;
      final centerPrior = math.exp(-((nx * nx) / 0.13 + (ny * ny) / 0.20));
      // Person prior: usually centered, with face/torso slightly above the midline.
      final personPrior = math.exp(-((nx * nx) / 0.10 + ((ny + 0.09) * (ny + 0.09)) / 0.15));
      final edgeNorm = (edge[idx] / maxEdge).clamp(0, 1).toDouble();
      final s = 0.50 * edgeNorm + 0.18 * saturation[idx] + 0.16 * centerPrior + 0.16 * personPrior;
      saliency[idx] = s.toDouble();
      sum += s;
    }
  }

  final mean = sum / size;
  var sq = 0.0;
  for (var i = 0; i < size; i++) {
    final d = saliency[i] - mean;
    sq += d * d;
  }
  final std = math.sqrt(sq / size);
  final threshold = (mean + std * 0.20).clamp(0.24, 0.82).toDouble();

  final binary = Uint8List(size);
  for (var i = 0; i < size; i++) {
    binary[i] = saliency[i] >= threshold ? 1 : 0;
  }

  final components = _extractComponents(binary, saliency, w, h);
  if (components.isEmpty) {
    return _fallbackEllipseCutout(src);
  }

  final selectedMask = _composeSubjectMask(components, w, h);
  final selectedCount = selectedMask.where((v) => v == 1).length;
  if (selectedCount < (size * 0.030)) {
    return _fallbackEllipseCutout(src);
  }

  final refined = _refineMask(selectedMask, w, h);

  final mask = img.Image(width: w, height: h, numChannels: 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final a = refined[y * w + x] == 1 ? 255 : 0;
      mask.setPixelRgba(x, y, 0, 0, 0, a);
    }
  }
  img.gaussianBlur(mask, radius: 1);

  final upMask = img.copyResize(
    mask,
    width: src.width,
    height: src.height,
    interpolation: img.Interpolation.cubic,
  );

  final out = img.Image(width: src.width, height: src.height, numChannels: 4);
  for (var y = 0; y < src.height; y++) {
    for (var x = 0; x < src.width; x++) {
      final sp = src.getPixel(x, y);
      final mp = upMask.getPixel(x, y);
      final soft = math.pow((mp.a / 255.0).clamp(0.0, 1.0), 1.55).toDouble();
      final alpha = (soft * sp.a).round().clamp(0, 255);
      final cleanedAlpha = alpha < 44 ? 0 : alpha;
      if (cleanedAlpha == 0) {
        out.setPixelRgba(x, y, 0, 0, 0, 0);
      } else {
        out.setPixelRgba(
          x,
          y,
          sp.r,
          sp.g,
          sp.b,
          cleanedAlpha,
        );
      }
    }
  }

  return Uint8List.fromList(img.encodePng(out, level: 6));
}

List<_ComponentStats> _extractComponents(Uint8List binary, Float32List saliency, int w, int h) {
  final visited = Uint8List(binary.length);
  final queue = List<int>.filled(binary.length, 0, growable: false);
  final components = <_ComponentStats>[];

  for (var i = 0; i < binary.length; i++) {
    if (binary[i] == 0 || visited[i] == 1) continue;

    var head = 0;
    var tail = 0;
    queue[tail++] = i;
    visited[i] = 1;

    final pixels = <int>[];
    var sumX = 0.0;
    var sumY = 0.0;
    var saliencySum = 0.0;
    var minX = w;
    var minY = h;
    var maxX = 0;
    var maxY = 0;

    while (head < tail) {
      final idx = queue[head++];
      pixels.add(idx);
      final x = idx % w;
      final y = idx ~/ w;
      sumX += x;
      sumY += y;
      saliencySum += saliency[idx];
      if (x < minX) minX = x;
      if (y < minY) minY = y;
      if (x > maxX) maxX = x;
      if (y > maxY) maxY = y;

      void push(int nx, int ny) {
        if (nx < 0 || ny < 0 || nx >= w || ny >= h) return;
        final n = ny * w + nx;
        if (binary[n] == 0 || visited[n] == 1) return;
        visited[n] = 1;
        queue[tail++] = n;
      }

      push(x - 1, y);
      push(x + 1, y);
      push(x, y - 1);
      push(x, y + 1);
    }

    if (pixels.isEmpty) continue;
    final area = pixels.length;
    components.add(
      _ComponentStats(
        pixels: pixels,
        area: area,
        cx: sumX / area,
        cy: sumY / area,
        meanSaliency: saliencySum / area,
        minX: minX,
        minY: minY,
        maxX: maxX,
        maxY: maxY,
      ),
    );
  }

  return components;
}

Uint8List _composeSubjectMask(List<_ComponentStats> components, int w, int h) {
  if (components.isEmpty) return Uint8List(w * h);
  final size = w * h;
  final cx = (w - 1) * 0.5;
  final cy = (h - 1) * 0.5;
  final minArea = (size * 0.0045).round();

  final filtered = components.where((c) => c.area >= minArea).toList();
  if (filtered.isEmpty) return Uint8List(w * h);

  double scoreOf(_ComponentStats c) {
    final nx = ((c.cx - cx).abs() / (w * 0.5)).clamp(0.0, 1.0);
    final ny = ((c.cy - cy).abs() / (h * 0.5)).clamp(0.0, 1.0);
    final centerScore = 1.0 - ((nx * nx) * 0.58 + (ny * ny) * 0.42).clamp(0.0, 1.0);
    final upperCenterCy = h * 0.45;
    final personCenter = 1.0 - ((c.cy - upperCenterCy).abs() / (h * 0.5)).clamp(0.0, 1.0);
    final areaScore = (c.area / (size * 0.18)).clamp(0.0, 1.0);
    final compW = (c.maxX - c.minX + 1).toDouble();
    final compH = (c.maxY - c.minY + 1).toDouble();
    final aspect = (compH / compW).clamp(0.2, 3.2);
    final portraitShape = (1.0 - ((aspect - 1.45).abs() / 1.45)).clamp(0.0, 1.0);
    return c.meanSaliency * 0.40 +
        centerScore * 0.22 +
        areaScore * 0.14 +
        personCenter * 0.16 +
        portraitShape * 0.08;
  }

  filtered.sort((a, b) => scoreOf(b).compareTo(scoreOf(a)));
  final primary = filtered.first;
  final primaryDiag = math.sqrt(
    ((primary.maxX - primary.minX + 1) * (primary.maxX - primary.minX + 1)).toDouble() +
        ((primary.maxY - primary.minY + 1) * (primary.maxY - primary.minY + 1)).toDouble(),
  );
  final primaryScore = scoreOf(primary);

  final selected = <_ComponentStats>[primary];
  for (var i = 1; i < filtered.length; i++) {
    final c = filtered[i];
    final s = scoreOf(c);
    final dx = c.cx - primary.cx;
    final dy = c.cy - primary.cy;
    final dist = math.sqrt(dx * dx + dy * dy);

    final scoreNear = s >= primaryScore * 0.74;
    final closeEnough = dist <= math.max(primaryDiag * 0.98, math.min(w, h) * 0.26);
    final meaningfulPiece = c.area >= primary.area * 0.06;
    final verticalBridge = (c.cy - primary.cy).abs() <= h * 0.30;
    if ((scoreNear && closeEnough) ||
        (closeEnough && meaningfulPiece && c.meanSaliency > 0.33) ||
        (verticalBridge && meaningfulPiece && c.meanSaliency > 0.42)) {
      selected.add(c);
    }
  }

  final out = Uint8List(size);
  for (final c in selected) {
    for (final p in c.pixels) {
      out[p] = 1;
    }
  }
  return out;
}

Uint8List _refineMask(Uint8List source, int w, int h) {
  Uint8List current = source;

  // Fill holes first, then remove isolated bits, then reconnect thin parts.
  current = _majorityPass(current, w, h, minNeighbors: 4);
  current = _majorityPass(current, w, h, minNeighbors: 3);
  current = _majorityPass(current, w, h, minNeighbors: 5);
  current = _majorityPass(current, w, h, minNeighbors: 4);
  current = _removeSmallForegroundIslands(
    current,
    w,
    h,
    minArea: math.max(18, (w * h * 0.0016).round()),
  );
  current = _fillSmallBackgroundHoles(
    current,
    w,
    h,
    maxHoleArea: math.max(20, (w * h * 0.0022).round()),
  );
  current = _majorityPass(current, w, h, minNeighbors: 4);

  return current;
}

Uint8List _majorityPass(Uint8List source, int w, int h, {required int minNeighbors}) {
  final out = Uint8List(source.length);

  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var count = 0;
      for (var ny = y - 1; ny <= y + 1; ny++) {
        for (var nx = x - 1; nx <= x + 1; nx++) {
          if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
          if (source[ny * w + nx] == 1) count++;
        }
      }
      out[y * w + x] = count >= minNeighbors ? 1 : 0;
    }
  }

  return out;
}

Uint8List _removeSmallForegroundIslands(Uint8List mask, int w, int h, {required int minArea}) {
  final out = Uint8List.fromList(mask);
  final visited = Uint8List(mask.length);
  final queue = List<int>.filled(mask.length, 0, growable: false);

  for (var i = 0; i < mask.length; i++) {
    if (out[i] == 0 || visited[i] == 1) continue;
    var head = 0;
    var tail = 0;
    queue[tail++] = i;
    visited[i] = 1;
    final pixels = <int>[];

    while (head < tail) {
      final idx = queue[head++];
      pixels.add(idx);
      final x = idx % w;
      final y = idx ~/ w;

      void push(int nx, int ny) {
        if (nx < 0 || ny < 0 || nx >= w || ny >= h) return;
        final n = ny * w + nx;
        if (visited[n] == 1 || out[n] == 0) return;
        visited[n] = 1;
        queue[tail++] = n;
      }

      push(x - 1, y);
      push(x + 1, y);
      push(x, y - 1);
      push(x, y + 1);
    }

    if (pixels.length < minArea) {
      for (final p in pixels) {
        out[p] = 0;
      }
    }
  }
  return out;
}

Uint8List _fillSmallBackgroundHoles(Uint8List mask, int w, int h, {required int maxHoleArea}) {
  final out = Uint8List.fromList(mask);
  final visited = Uint8List(mask.length);
  final queue = List<int>.filled(mask.length, 0, growable: false);

  for (var i = 0; i < mask.length; i++) {
    if (out[i] == 1 || visited[i] == 1) continue;
    var head = 0;
    var tail = 0;
    queue[tail++] = i;
    visited[i] = 1;
    final pixels = <int>[];
    var touchesBorder = false;

    while (head < tail) {
      final idx = queue[head++];
      pixels.add(idx);
      final x = idx % w;
      final y = idx ~/ w;
      if (x == 0 || y == 0 || x == w - 1 || y == h - 1) {
        touchesBorder = true;
      }

      void push(int nx, int ny) {
        if (nx < 0 || ny < 0 || nx >= w || ny >= h) return;
        final n = ny * w + nx;
        if (visited[n] == 1 || out[n] == 1) return;
        visited[n] = 1;
        queue[tail++] = n;
      }

      push(x - 1, y);
      push(x + 1, y);
      push(x, y - 1);
      push(x, y + 1);
    }

    if (!touchesBorder && pixels.length <= maxHoleArea) {
      for (final p in pixels) {
        out[p] = 1;
      }
    }
  }
  return out;
}

Uint8List? _fallbackEllipseCutout(img.Image src) {
  final w = src.width;
  final h = src.height;
  final out = img.Image(width: w, height: h, numChannels: 4);

  final cx = w * 0.5;
  final cy = h * 0.53;
  final rx = w * 0.34;
  final ry = h * 0.42;

  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = src.getPixel(x, y);
      final dx = (x - cx) / rx;
      final dy = (y - cy) / ry;
      final d = dx * dx + dy * dy;
      final m = (1.0 - d).clamp(0.0, 1.0);
      final feather = (m * m * (3 - 2 * m));
      final a = (feather * p.a).round().clamp(0, 255);
      if (a == 0) {
        out.setPixelRgba(x, y, 0, 0, 0, 0);
      } else {
        out.setPixelRgba(
          x,
          y,
          p.r,
          p.g,
          p.b,
          a,
        );
      }
    }
  }
  return Uint8List.fromList(img.encodePng(out, level: 6));
}

class _ComponentStats {
  final List<int> pixels;
  final int area;
  final double cx;
  final double cy;
  final double meanSaliency;
  final int minX;
  final int minY;
  final int maxX;
  final int maxY;

  _ComponentStats({
    required this.pixels,
    required this.area,
    required this.cx,
    required this.cy,
    required this.meanSaliency,
    required this.minX,
    required this.minY,
    required this.maxX,
    required this.maxY,
  });
}
