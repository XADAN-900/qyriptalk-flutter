import 'dart:async';

import 'package:flutter/services.dart';

/// Android yerel katmanı (arka plan servisi, tam ekran arama bildirimi) ile köprü.
class NativeBridge {
  NativeBridge._();

  static const MethodChannel _ch = MethodChannel('qyriptalk/native');

  /// Bildirimden / yerel taraftan gelen olaylar: answer, show_call, declined, hangup, open_conv.
  static final StreamController<Map<String, String?>> actions =
      StreamController<Map<String, String?>>.broadcast();

  static bool _init = false;

  static void init() {
    if (_init) return;
    _init = true;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'onAction') {
        actions.add(_toMap(call.arguments));
      }
      return null;
    });
  }

  static Map<String, String?> _toMap(Object? v) {
    final out = <String, String?>{};
    if (v is Map) {
      v.forEach((k, val) => out['$k'] = val?.toString());
    }
    return out;
  }

  static Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _ch.invokeMethod<T>(method, args);
    } catch (_) {
      return null;
    }
  }

  /// Giriş yapan kullanıcıyı yerel servise bildirir ve arka plan dinlemesini başlatır.
  static Future<void> setSession({
    required String uid,
    required String username,
    required bool enabled,
    required bool sound,
    required bool preview,
    required bool speak,
  }) =>
      _call('setSession', {
        'uid': uid,
        'username': username,
        'enabled': enabled,
        'sound': sound,
        'preview': preview,
        'speak': speak,
      });

  static Future<void> clearSession() => _call('clearSession');

  static Future<void> setInCall(bool inCall) => _call('setInCall', {'inCall': inCall});

  static Future<void> cancelCallNotification() => _call('cancelCallNotification');

  static Future<void> dismissConversation(String key) => _call('dismissConversation', {'key': key});

  /// Uygulama bir bildirimden açıldıysa o olayı (bir kez) döndürür.
  static Future<Map<String, String?>?> takeLaunchAction() async {
    final v = await _call<Object>('takeLaunchAction');
    if (v == null) return null;
    return _toMap(v);
  }

  static Future<bool> canUseFullScreen() async => (await _call<bool>('canUseFullScreen')) ?? true;

  static Future<void> openFullScreenSettings() => _call('openFullScreenSettings');

  static Future<bool> isIgnoringBattery() async => (await _call<bool>('isIgnoringBattery')) ?? true;

  static Future<void> requestIgnoreBattery() => _call('requestIgnoreBattery');

  static Future<void> openNotificationSettings() => _call('openNotificationSettings');
}
