import 'dart:async';
import 'dart:math' as math;

import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// Coordinador global para suavizar ráfagas de llamadas a YouTube.
///
/// Centraliza:
/// - Throttling entre requests
/// - Slow mode temporal tras rate limit
/// - Backoff con jitter para reintentos
class YoutubeRequestGuard {
  YoutubeRequestGuard._();

  static final YoutubeRequestGuard shared = YoutubeRequestGuard._();

  static const Duration _minRequestGap = Duration(milliseconds: 520);
  static const Duration _slowRequestGap = Duration(milliseconds: 1700);
  static const Duration _defaultSlowModeDuration = Duration(seconds: 45);

  final math.Random _random = math.Random();
  Future<void> _serializedGate = Future<void>.value();
  DateTime? _lastRequestAt;
  DateTime? _slowModeUntil;

  bool get isSlowModeActive {
    final until = _slowModeUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  void activateSlowMode([Duration duration = _defaultSlowModeDuration]) {
    final next = DateTime.now().add(duration);
    final current = _slowModeUntil;
    if (current == null || next.isAfter(current)) {
      _slowModeUntil = next;
    }
  }

  Future<void> waitForSlot() {
    final completer = Completer<void>();
    _serializedGate = _serializedGate.then((_) async {
      final now = DateTime.now();
      final effectiveGap = isSlowModeActive ? _slowRequestGap : _minRequestGap;
      final last = _lastRequestAt;
      if (last != null) {
        final elapsed = now.difference(last);
        if (elapsed < effectiveGap) {
          await Future<void>.delayed(effectiveGap - elapsed);
        }
      }
      if (isSlowModeActive) {
        final jitterMs = 140 + _random.nextInt(420);
        await Future<void>.delayed(Duration(milliseconds: jitterMs));
      }
      _lastRequestAt = DateTime.now();
      completer.complete();
    }).catchError((_) {
      if (!completer.isCompleted) {
        completer.complete();
      }
    });
    return completer.future;
  }

  bool isRateLimitError(Object error) {
    if (error is RequestLimitExceededException) return true;
    final raw = error.toString().toLowerCase();
    return raw.contains('429') ||
        raw.contains('too many requests') ||
        raw.contains('rate limit') ||
        raw.contains('quota');
  }

  Duration retryDelay({
    required int attempt,
    required Object? lastError,
  }) {
    final isRateLimit = lastError != null && isRateLimitError(lastError);
    final seconds = isRateLimit ? (5 + (attempt * 4)) : (attempt * 3);
    final jitterMs = 120 + _random.nextInt(360);
    return Duration(seconds: seconds, milliseconds: jitterMs);
  }
}
