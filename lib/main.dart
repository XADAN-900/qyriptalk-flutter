import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/firebase_config.dart';
import 'core/nav.dart';
import 'core/theme.dart';
import 'screens/auth_screen.dart';
import 'screens/call_screen.dart';
import 'screens/home_screen.dart';
import 'services/app_state.dart';
import 'services/call_service.dart';
import 'services/app_guard.dart';
import 'services/native_bridge.dart';
import 'services/net_status.dart';
import 'services/notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('tr_TR');
  try {
    await Firebase.initializeApp(options: FirebaseConfig.options);
  } catch (_) {
    // Arka plan servisi uygulamayı önceden başlatmış olabilir: var olanı kullan.
    if (Firebase.apps.isEmpty) rethrow;
  }
  try {
    final db = FirebaseDatabase.instanceFor(
      app: Firebase.app(),
      databaseURL: FirebaseConfig.databaseUrl,
    );
    db.setPersistenceEnabled(true);
    db.setPersistenceCacheSizeBytes(100 * 1024 * 1024);
  } catch (_) {}
  if (FirebaseConfig.hasAndroidAppId) {
    FirebaseMessaging.onBackgroundMessage(firebaseBackgroundHandler);
  }
  await NotificationService.init();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
  ));
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  NativeBridge.init();
  NetStatus.instance.start();
  final prefs = await SharedPreferences.getInstance();
  final app = AppState(prefs);
  final calls = CallService(app);
  runApp(QyriptalkApp(app: app, calls: calls));
  await app.restoreSession();
  calls.syncListening();
  Future.delayed(const Duration(seconds: 8), () => _uploadLastCrash(app));
  // Uygulama bir bildirimden (Cevapla, tam ekran arama, mesaj) açıldıysa ona git.
  final launch = await NativeBridge.takeLaunchAction();
  if (launch != null) {
    Future.delayed(const Duration(milliseconds: 600), () => NativeBridge.actions.add(launch));
  }
}

class QyriptalkApp extends StatefulWidget {
  final AppState app;
  final CallService calls;
  const QyriptalkApp({super.key, required this.app, required this.calls});

  @override
  State<QyriptalkApp> createState() => _QyriptalkAppState();
}

class _QyriptalkAppState extends State<QyriptalkApp> {
  bool _callScreenOpen = false;

  @override
  void initState() {
    super.initState();
    widget.calls.onPresent = _presentCallScreen;
    widget.app.addListener(_onAppChanged);
    NotificationService.onTap = _onNotificationTap;
    NativeBridge.actions.stream.listen((a) {
      if (a['action'] == 'open_conv') {
        final key = a['convKey'];
        if (key != null && key.isNotEmpty) widget.app.openChatRequests.add(key);
      }
    });
    NotificationService.launchResponse().then((r) {
      final p = r?.payload;
      if (p != null) {
        Future.delayed(const Duration(milliseconds: 900), () => _onNotificationTap(p, r?.actionId));
      }
    });
  }

  void _onAppChanged() => widget.calls.syncListening();

  void _onNotificationTap(String payload, String? actionId) {
    if (payload.startsWith('call:')) {
      widget.calls.handleNotificationAction(payload.substring(5), actionId);
      return;
    }
    widget.app.openChatRequests.add(payload);
  }

  void _presentCallScreen() {
    if (_callScreenOpen) return;
    final nav = navigatorKey.currentState;
    if (nav == null) return;
    _callScreenOpen = true;
    nav
        .push(MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => const CallScreen(),
        ))
        .then((_) => _callScreenOpen = false);
  }

  @override
  void dispose() {
    widget.app.removeListener(_onAppChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: widget.app),
        ChangeNotifierProvider<CallService>.value(value: widget.calls),
      ],
      child: Consumer<AppState>(
        builder: (context, app, _) => MaterialApp(
          title: 'Qyriptalk',
          debugShowCheckedModeBanner: false,
          navigatorKey: navigatorKey,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: app.themeMode,
          locale: const Locale('tr', 'TR'),
          supportedLocales: const [Locale('tr', 'TR'), Locale('en', 'US')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: const _Gate(),
        ),
      ),
    );
  }
}

/// Uygulama bir önceki açılışta çöktüyse raporu kullanıcıya hiçbir şey göstermeden
/// yönetici paneline (crashReports) gönderir.
Future<void> _uploadLastCrash(AppState app) async {
  const ch = MethodChannel('qyriptalk/crash');
  String? report;
  try {
    report = await ch.invokeMethod<String>('get');
  } catch (_) {}
  if (report == null || report.trim().isEmpty || app.uid == null) return;
  try {
    await app.db.ref('crashReports').push().set({
      'report': report.length > 8000 ? report.substring(0, 8000) : report,
      'uid': app.uid ?? '',
      'username': app.username,
      'app': 'Qyriptalk ${AppGuard.build}',
      'ts': ServerValue.timestamp,
    }).timeout(const Duration(seconds: 20));
    await ch.invokeMethod('clear');
  } catch (_) {}
}

class _Gate extends StatelessWidget {
  const _Gate();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    if (app.restoring) {
      return Scaffold(
        body: Center(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(28),
            child: Image.asset('assets/logo.png', width: 110, height: 110),
          ),
        ),
      );
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 350),
      child: app.isLoggedIn
          ? AppGuard(
              key: ValueKey('guard_${app.uid}'),
              db: app.db,
              uid: app.uid!,
              repo: 'XADAN-900/qyriptalk-flutter',
              apkName: 'Qyriptalk.apk',
              appName: 'Qyriptalk',
              accent: const Color(0xFF7B61FF),
              onLogout: app.logout,
              child: HomeScreen(key: ValueKey(app.uid)),
            )
          : const AuthScreen(key: ValueKey('auth')),
    );
  }
}
