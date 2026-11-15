import 'dart:async';
import 'dart:typed_data';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/firebase_config.dart';

/// Uygulama kapalıyken gelen FCM verisini bildirime çevirir (ayrı isolate).
@pragma('vm:entry-point')
Future<void> firebaseBackgroundHandler(RemoteMessage message) async {
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(options: FirebaseConfig.options);
    }
  } catch (_) {}
  await NotificationService.init(background: true);
  await NotificationService.handleRemoteData(message.data, background: true);
}

class NotificationService {
  NotificationService._();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _ready = false;
  static FlutterTts? _tts;

  /// Bildirime dokunulunca çağrılır: payload ('dm:..', 'room:..', 'call:..') ve eylem kimliği.
  static void Function(String payload, String? actionId)? onTap;

  static const _chMessages = 'qt_messages';
  static const _chSilent = 'qt_messages_silent';
  static const _chCalls = 'qt_calls';

  static Future<void> init({bool background = false}) async {
    if (_ready) return;
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('ic_notification'),
    );
    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: (r) {
        final p = r.payload;
        if (p != null && onTap != null) onTap!(p, r.actionId);
      },
    );
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      await android.createNotificationChannel(const AndroidNotificationChannel(
        _chMessages,
        'Mesajlar',
        description: 'Yeni mesaj bildirimleri',
        importance: Importance.high,
        sound: RawResourceAndroidNotificationSound('qyrip_message'),
        playSound: true,
        enableVibration: true,
      ));
      await android.createNotificationChannel(const AndroidNotificationChannel(
        _chSilent,
        'Mesajlar (sessiz)',
        description: 'Sesi kapalı mesaj bildirimleri',
        importance: Importance.defaultImportance,
        playSound: false,
        enableVibration: false,
      ));
      await android.createNotificationChannel(const AndroidNotificationChannel(
        _chCalls,
        'Gelen aramalar',
        description: 'Sesli arama bildirimi',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
      ));
    }
    _ready = true;
  }

  static Future<void> requestPermission() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    try {
      await android?.requestNotificationsPermission();
    } catch (_) {}
  }

  /// Uygulama bir bildirime dokunularak açıldıysa o bildirimin verisi.
  static Future<NotificationResponse?> launchResponse() async {
    try {
      final d = await _plugin.getNotificationAppLaunchDetails();
      if (d != null && d.didNotificationLaunchApp) return d.notificationResponse;
    } catch (_) {}
    return null;
  }

  static int idFor(String key) {
    // FNV-1a: isolate'ler arasında da aynı kimlik (aynı bildirim üst üste yazılır).
    var h = 0x811c9dc5;
    for (final c in key.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0x7fffffff;
    }
    return h;
  }

  static Future<void> showMessage({
    required String key,
    required String title,
    required String body,
    bool showContent = true,
    bool silent = false,
  }) async {
    await init();
    final details = AndroidNotificationDetails(
      silent ? _chSilent : _chMessages,
      silent ? 'Mesajlar (sessiz)' : 'Mesajlar',
      importance: silent ? Importance.defaultImportance : Importance.high,
      priority: silent ? Priority.defaultPriority : Priority.high,
      category: AndroidNotificationCategory.message,
      styleInformation: BigTextStyleInformation(showContent ? body : 'Yeni mesaj'),
      visibility: showContent
          ? NotificationVisibility.public
          : NotificationVisibility.private,
      groupKey: 'qyriptalk.messages',
      color: const Color(0xFF6A5CFF),
      ticker: title,
    );
    await _plugin.show(
      idFor(key),
      title,
      showContent ? body : 'Yeni mesaj',
      NotificationDetails(android: details),
      payload: key,
    );
  }

  static Future<void> showIncomingCall({
    required String callId,
    required String title,
    required String text,
  }) async {
    await init();
    final details = AndroidNotificationDetails(
      _chCalls,
      'Gelen aramalar',
      importance: Importance.max,
      priority: Priority.max,
      category: AndroidNotificationCategory.call,
      fullScreenIntent: true,
      ongoing: true,
      autoCancel: false,
      timeoutAfter: 45000,
      visibility: NotificationVisibility.public,
      color: const Color(0xFF31C46C),
      vibrationPattern: Int64List.fromList([0, 800, 600, 800, 600, 800]),
      actions: <AndroidNotificationAction>[
        AndroidNotificationAction('decline', 'Reddet',
            showsUserInterface: true, cancelNotification: true),
        AndroidNotificationAction('answer', 'Cevapla',
            showsUserInterface: true, cancelNotification: true),
      ],
    );
    await _plugin.show(
      idFor('call:$callId'),
      title,
      text,
      NotificationDetails(android: details),
      payload: 'call:$callId',
    );
  }

  static Future<void> cancelCall(String callId) =>
      _plugin.cancel(idFor('call:$callId'));

  static Future<void> cancelForKey(String key) => _plugin.cancel(idFor(key));

  static Future<void> cancelAll() => _plugin.cancelAll();

  static Future<void> handleRemoteData(Map<String, dynamic> data,
      {bool background = false}) async {
    final type = '${data['type'] ?? ''}';
    if (type == 'message') {
      final key = '${data['convKey'] ?? ''}';
      if (key.isEmpty) return;
      final prefs = await SharedPreferences.getInstance();
      final muted = prefs.getStringList('mutedChats') ?? const [];
      if (muted.contains(key)) return;
      if (prefs.getString('uid') == null) return;
      final isRoom = '${data['room'] ?? '0'}' == '1';
      final sender = '${data['sender'] ?? ''}';
      final text = '${data['text'] ?? ''}';
      await showMessage(
        key: key,
        title: '${data['title'] ?? 'Qyriptalk'}',
        body: isRoom ? '$sender: $text' : text,
        showContent: prefs.getBool('lockscreenPreview') ?? true,
        silent: !(prefs.getBool('soundNotifications') ?? true),
      );
    } else if (type == 'call') {
      await showIncomingCall(
        callId: '${data['callId'] ?? ''}',
        title: '${data['title'] ?? 'Qyriptalk'}',
        text: '${data['text'] ?? 'Sesli arıyor...'}',
      );
    } else if (type == 'call_end') {
      await cancelCall('${data['callId'] ?? ''}');
    }
  }

  // ------------------------------------------------------------------
  // FCM jetonu
  // ------------------------------------------------------------------
  static StreamSubscription<String>? _tokenSub;
  static String? _token;

  static Future<void> registerToken(FirebaseDatabase db, String uid) async {
    await init();
    await requestPermission();
    if (!FirebaseConfig.hasAndroidAppId) return;
    try {
      final fm = FirebaseMessaging.instance;
      await fm.requestPermission();
      final token = await fm.getToken();
      if (token != null) {
        _token = token;
        await db.ref('fcmTokens/$uid/$token').set(ServerValue.timestamp);
      }
      await _tokenSub?.cancel();
      _tokenSub = fm.onTokenRefresh.listen((t) {
        _token = t;
        db.ref('fcmTokens/$uid/$t').set(ServerValue.timestamp);
      });
    } catch (e) {
      debugPrint('FCM kullanılamıyor: $e');
    }
  }

  static Future<void> unregisterToken(FirebaseDatabase db, String uid) async {
    final t = _token;
    await _tokenSub?.cancel();
    _tokenSub = null;
    if (t != null) {
      try {
        await db.ref('fcmTokens/$uid/$t').remove();
      } catch (_) {}
    }
  }

  // ------------------------------------------------------------------
  // Sesli okuma
  // ------------------------------------------------------------------
  static Future<void> speak(String text) async {
    try {
      _tts ??= FlutterTts();
      await _tts!.setLanguage('tr-TR');
      await _tts!.setSpeechRate(0.5);
      await _tts!.speak(text);
    } catch (_) {}
  }
}
