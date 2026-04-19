import 'package:flutter/foundation.dart';

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
  Future<List<LiveLyricWordTiming>> transcribeLocalFile({
    required String filePath,
  }) async {
    if (filePath.trim().isEmpty) return const [];
    debugPrint('[live_lyrics] iOS alignment desactivado');
    return const [];
  }
}
