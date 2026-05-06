import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:myapp/services/social_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class PushNotificationService {
  PushNotificationService({required SocialService socialService})
    : _socialService = socialService;

  final SocialService _socialService;
  bool _started = false;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    if (kIsWeb) return;
    if (defaultTargetPlatform != TargetPlatform.iOS &&
        defaultTargetPlatform != TargetPlatform.android) {
      return;
    }

    try {
      await Firebase.initializeApp();
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      await _socialService.ensureReady();
      await _syncCurrentToken(messaging);
      messaging.onTokenRefresh.listen((token) async {
        await _upsertToken(token);
      });
    } catch (e, s) {
      debugPrint('[push] init skipped: $e');
      debugPrintStack(stackTrace: s, label: '[push] init stack');
    }
  }

  Future<void> _syncCurrentToken(FirebaseMessaging messaging) async {
    final token = await messaging.getToken();
    if (token == null || token.trim().isEmpty) return;
    await _upsertToken(token);
  }

  Future<void> _upsertToken(String token) async {
    final cleanToken = token.trim();
    if (cleanToken.isEmpty) return;
    final userId = (_socialService.myUserId ?? '').trim();
    if (userId.isEmpty) return;
    final platform = Platform.isIOS
        ? 'ios'
        : (Platform.isAndroid ? 'android' : 'other');
    await Supabase.instance.client.from('user_push_tokens').upsert({
      'user_id': userId,
      'token': cleanToken,
      'platform': platform,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'token');
  }
}
