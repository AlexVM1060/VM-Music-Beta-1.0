import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class LiveLyricWordTiming {
  final String word;
  final Duration start;
  final Duration end;
  final double confidence;

  const LiveLyricWordTiming({
    required this.word,
    required this.start,
    required this.end,
    required this.confidence,
  });
}

class IosLiveLyricsAlignmentService {
  static const MethodChannel _channel = MethodChannel(
    'com.vm.music.beta/ios_live_lyrics_alignment',
  );

  Future<List<LiveLyricWordTiming>> transcribeLocalFile({
    required String filePath,
  }) async {
    if (filePath.trim().isEmpty) return const [];

    try {
      final dynamic raw = await _channel.invokeMethod('transcribeLocalFile', {
        'filePath': filePath,
      });
      if (raw is! List) return const [];
      final output = <LiveLyricWordTiming>[];
      for (final item in raw) {
        if (item is! Map) continue;
        final word = (item['word'] ?? '').toString().trim();
        if (word.isEmpty) continue;
        final startMs = (item['startMs'] as num?)?.toInt() ?? 0;
        final endMs = (item['endMs'] as num?)?.toInt() ?? startMs;
        final confidence = (item['confidence'] as num?)?.toDouble() ?? 0.0;
        output.add(
          LiveLyricWordTiming(
            word: word,
            start: Duration(milliseconds: startMs.clamp(0, 1 << 30)),
            end: Duration(milliseconds: endMs.clamp(startMs, 1 << 30)),
            confidence: confidence.clamp(0.0, 1.0),
          ),
        );
      }
      output.sort((a, b) => a.start.compareTo(b.start));
      return output;
    } on PlatformException catch (e) {
      debugPrint('[live_lyrics] iOS alignment error: ${e.code} ${e.message}');
      return const [];
    } catch (e) {
      debugPrint('[live_lyrics] iOS alignment error: $e');
      return const [];
    }
  }
}
