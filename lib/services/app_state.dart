import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/firebase_config.dart';
import '../core/utils.dart';
import '../models/models.dart';
import 'native_bridge.dart';
import 'net_status.dart';
import 'offline_store.dart';
import 'notification_service.dart';

/// Uygulamanın tek gerçek kaynağı: oturum, kullanıcılar, odalar, sohbet özetleri.
class AppState extends ChangeNotifier with WidgetsBindingObserver {
  AppState(this.prefs) {
    db = FirebaseDatabase.instanceFor(
      app: Firebase.app(),
      databaseURL: FirebaseConfig.databaseUrl,
    );
    WidgetsBinding.instance.addObserver(this);
    NetStatus.instance.online.addListener(_onNetChanged);
    NetStatus.instance.onBack.add(() => db.goOnline());
    final ti = prefs.getInt('themeMode') ?? 0;
    _themeMode = (ti >= 0 && ti < ThemeMode.values.length)
        ? ThemeMode.values[ti]
        : ThemeMode.system;
    _lang = prefs.getString('lang');
    _muted.addAll(prefs.getStringList('mutedChats') ?? const []);
    _pinned.addAll(prefs.getStringList('pinnedChats') ?? const []);
    _archived.addAll(prefs.getStringList('archivedChats') ?? const []);
  }

  final SharedPreferences prefs;
  late final FirebaseDatabase db;

  // ---------------- Oturum ----------------
  String? _uid;
  String? _username;
  bool _restoring = true;
  String? get uid => _uid;
  String get username => _username ?? '';
  bool get isLoggedIn => _uid != null;
  bool get restoring => _restoring;

  // ---------------- Durum ----------------
  final Map<String, AppUser> users = {};
  final Map<String, Room> rooms = {};
  final Set<String> joinedRoomIds = {};
  final Map<String, ChatMessage> _last = {};
  final Map<String, int> _unread = {};
  final Set<String> _muted = {};
  final Set<String> _pinned = {};
  final Set<String> _archived = {};
  Map<String, dynamic> settings = {};
  /// Gerçek internet durumu (var / yok).
  bool get connected => NetStatus.instance.online.value;

  void _onNetChanged() => notifyListeners();
  bool foreground = true;
  bool _usersLoaded = false;
  bool _joinedLoaded = false;
  final Set<String> _roomMetaPending = {};

  /// Sohbet listesi ilk kez tamamen yüklendi mi? (Yüklenirken boş ekran / yanıp sönme olmasın.)
  bool get chatsReady => _usersLoaded && _joinedLoaded && _roomMetaPending.isEmpty;
  String? activeChatKey;

  ThemeMode _themeMode = ThemeMode.system;
  ThemeMode get themeMode => _themeMode;

  // ---- Dil / çeviri ----
  static const List<String> kLanguages = ['tr', 'en', 'fr', 'es', 'pt', 'ru', 'ar'];
  String? _lang;

  /// Seçili dil kodu. Henüz seçilmemişse cihaz dilini (desteklenenlerden) kullanır.
  String get languageCode {
    final l = _lang;
    if (l != null && kLanguages.contains(l)) return l;
    final dev = WidgetsBinding.instance.platformDispatcher.locale.languageCode;
    return kLanguages.contains(dev) ? dev : 'tr';
  }

  /// Kullanıcı dili daha önce açıkça seçti mi (kayıt akışında sormak için).
  bool get hasChosenLanguage => _lang != null;

  Locale get locale => Locale(languageCode);

  void setLanguage(String code) {
    if (!kLanguages.contains(code)) return;
    _lang = code;
    prefs.setString('lang', code);
    final uid = _uid;
    if (uid != null) {
      db.ref('users/$uid/settings/lang').set(code).catchError((_) {});
    }
    notifyListeners();
  }

  final _subs = <StreamSubscription>[];
  final Map<String, StreamSubscription> _lastSubs = {};
  final Set<String> _lastInitialized = {};

  /// Bildirime dokunulunca açılacak sohbet (ana ekran dinler).
  final StreamController<String> openChatRequests =
      StreamController<String>.broadcast();

  AppUser? get me => _uid == null ? null : users[_uid];

  // ======================================================================
  // GİRİŞ / KAYIT
  // ======================================================================

  Future<void> restoreSession() async {
    final savedUid = prefs.getString('uid');
    final savedName = prefs.getString('username');
    if (savedUid != null && savedName != null) {
      _uid = savedUid;
      _username = savedName;
      _restoring = false;
      notifyListeners();
      // Hesap silinmiş mi diye arka planda kontrol et.
      unawaited(db.ref('users/$savedUid/username').get().then((s) {
        if (!s.exists && _uid == savedUid && connected) logout();
      }).catchError((_) {}));
      // Eski sürümden kalan oturum: şifre sormadan güvenli girişe taşı.
      if (connected) await _ensureSecureSession(savedUid).timeout(const Duration(seconds: 20), onTimeout: () {});
      if (_uid == null) return;
      await _startSession();
    } else {
      _restoring = false;
      notifyListeners();
    }
  }

  /// Tüm kullanıcıları (uid -> veri) getirir. Realtime Database'de "username" için
  /// indeks tanımlı olmadığından sorgu yerine istemci tarafında filtreleriz
  /// (web sürümü de aynısını yapıyor).
  Future<Map<String, Map<String, dynamic>>> _fetchUsers() async {
    final snap = await db.ref('users').get().timeout(const Duration(seconds: 20));
    final out = <String, Map<String, dynamic>>{};
    asMap(snap.value).forEach((k, v) {
      final m = asMap(v);
      if (m.isNotEmpty) out[k] = m;
    });
    return out;
  }

  static String _norm(String s) => s.trim().toLowerCase();

  /// Kullanıcı adı alınmış mı? (büyük/küçük harf duyarsız)
  Future<bool> isUsernameTaken(String name) async {
    final n = _norm(name);
    if (n.isEmpty) return false;
    final uids = await _uidsForUsername(name);
    return uids.any((u) => u != _uid);
  }

  static String? validateUsername(String username) {
    final u = username.trim();
    if (u.length < 3) return 'Kullanıcı adı en az 3 karakter olmalı.';
    if (u.length > 24) return 'Kullanıcı adı en fazla 24 karakter olabilir.';
    if (!RegExp(r'^[\wçğıöşüÇĞİÖŞÜ.\- ]+$').hasMatch(u)) {
      return 'Sadece harf, rakam, boşluk, nokta, - ve _ kullanılabilir.';
    }
    return null;
  }

  // ----------------------------------------------------------------------
  // GÜVENLİ GİRİŞ (Firebase Authentication)
  // Şifreler artık veritabanında DURMAZ; Firebase Auth'ta güvenle (hash'li) saklanır.
  // Her hesap için gizli bir e-posta: <uid>@users.qyriptalk.app
  // authMap/{authUid} = uid  -> veritabanı kuralları kimin hangi hesap olduğunu bilir.
  // usernames/{ad}/{uid} = true -> giriş için kullanıcı adı -> hesap eşlemesi.
  // Eski hesaplar ilk girişte otomatik taşınır (açık şifre silinir).
  // ----------------------------------------------------------------------
  FirebaseAuth get auth => FirebaseAuth.instanceFor(app: Firebase.app());

  /// Veritabanı kuralları da aynı adresi hesaplayabilsin diye: küçük harfli uid.
  /// [ver]: yönetici şifreyi sıfırladıysa hesabın yeni sürümü (ör. "r1"); yoksa boş.
  static String authEmail(String uid, [String ver = '']) =>
      '${uid.toLowerCase()}${ver.isEmpty ? '' : '.$ver'}@users.qyriptalk.app';

  /// Herkese açık "authV/{uid}": yönetici panelden şifre değiştirdiyse giriş adresi sürümü.
  Future<String> _authVer(String uid) async {
    try {
      return asStr((await db.ref('authV/$uid').get().timeout(const Duration(seconds: 10))).value);
    } catch (_) {
      return '';
    }
  }

  /// authMap kaydı: kuralların beklediği biçimde (sürümle birlikte) uid yazılır.
  Future<void> _writeAuthMap(String authUid, String uid, {FirebaseDatabase? using}) =>
      (using ?? db).ref('authMap/$authUid').set(uid);

  /// Firebase en az 6 karakter ister; eski kısa şifreler için sabit bir dönüşüm.
  static String authPassword(String pw) => pw.length >= 6 ? pw : 'qt#$pw#qyrip';

  static String nameKey(String username) =>
      _norm(username).replaceAll('.', ',').replaceAll(RegExp(r'[#$\[\]/]'), '_');

  static bool _authUnavailable(FirebaseAuthException e) =>
      e.code == 'operation-not-allowed' ||
      e.code == 'configuration-not-found' ||
      (e.message ?? '').contains('CONFIGURATION_NOT_FOUND');

  /// Kullanıcı adına ait hesap kimlikleri (önce herkese açık indeks, yoksa eski yöntem).
  Future<List<String>> _uidsForUsername(String username) async {
    try {
      final s = await db.ref('usernames/${nameKey(username)}').get().timeout(const Duration(seconds: 15));
      final ids = asMap(s.value).keys.toList();
      if (ids.isNotEmpty) return ids;
    } catch (_) {}
    try {
      final all = await _fetchUsers();
      var matches = all.entries.where((e) => asStr(e.value['username']) == username).toList();
      if (matches.isEmpty) {
        matches = all.entries.where((e) => _norm(asStr(e.value['username'])) == _norm(username)).toList();
      }
      return matches.map((e) => e.key).toList();
    } catch (_) {
      return const [];
    }
  }

  /// Hesabı güvenli girişe bağlar: eşleme + indeks yazar, açık metin şifreyi siler.
  Future<void> _linkAccount(String uid, String authUid, String username, {FirebaseDatabase? using}) async {
    final d = using ?? db;
    await d.ref('authMap/$authUid').set(uid);
    await d.ref('users/$uid/authUid').set(authUid);
    await d.ref('usernames/${nameKey(username)}/$uid').set(true);
    await d.ref('users/$uid/password').remove();
  }

  Future<String?> login(String username, String password) async {
    username = username.trim();
    if (username.isEmpty || password.isEmpty) {
      return 'Kullanıcı adı ve şifre gerekli.';
    }
    try {
      final uids = await _uidsForUsername(username);
      if (uids.isEmpty) return 'Bu kullanıcı adıyla bir hesap bulunamadı.';
      for (final uid in uids) {
        final ver = await _authVer(uid);
        final email = authEmail(uid, ver);
        try {
          final cred = await auth.signInWithEmailAndPassword(email: email, password: authPassword(password));
          final s = await db.ref('users/$uid/username').get();
          final name = asStr(s.value, username);
          // Eski sürümden kalan açık şifre ve eksik indeksleri temizle.
          await _linkAccount(uid, cred.user!.uid, name);
          await _setSession(uid, name);
          return null;
        } on FirebaseAuthException catch (e) {
          if (_authUnavailable(e)) return _legacyLogin(uid, username, password);
          if (e.code == 'too-many-requests') {
            return 'Çok fazla deneme yapıldı. Biraz bekleyip tekrar dene.';
          }
          if (e.code == 'network-request-failed') {
            return 'Sunucuya ulaşılamadı. İnternet bağlantını kontrol et.';
          }
          // Hesap henüz taşınmamış olabilir: eski şifreyle doğrula ve taşı.
          if (ver.isNotEmpty) continue;
          final migrated = await _migrateWithPassword(uid, password);
          if (migrated != null) {
            await _setSession(uid, migrated);
            return null;
          }
        }
      }
      return 'Şifre hatalı.';
    } on TimeoutException {
      return 'Sunucuya ulaşılamadı. İnternet bağlantını kontrol et.';
    } catch (e) {
      return 'Giriş yapılamadı. Lütfen tekrar dene.\n($e)';
    }
  }

  /// Eski (taşınmamış) hesap: veritabanındaki şifre doğruysa Firebase Auth hesabı açar.
  /// Başarılıysa kullanıcı adını döndürür.
  Future<String?> _migrateWithPassword(String uid, String password) async {
    try {
      final s = await db.ref('users/$uid').get();
      final m = asMap(s.value);
      final stored = asStr(m['password']);
      if (stored.isEmpty || stored != password) return null;
      final name = asStr(m['username'], 'Kullanıcı');
      final cred = await auth.createUserWithEmailAndPassword(
          email: authEmail(uid), password: authPassword(password));
      await _linkAccount(uid, cred.user!.uid, name);
      return name;
    } catch (_) {
      return null;
    }
  }

  /// Firebase'de e-posta/şifre girişi henüz açılmamışsa eski yöntemle giriş (geçici).
  Future<String?> _legacyLogin(String uid, String username, String password) async {
    try {
      final s = await db.ref('users/$uid').get();
      final m = asMap(s.value);
      if (asStr(m['password']) == password) {
        await _setSession(uid, asStr(m['username'], username));
        return null;
      }
    } catch (_) {}
    return 'Şifre hatalı.';
  }

  /// Oturumu açık eski kullanıcıyı (şifresini sormadan) güvenli girişe taşır.
  Future<void> _ensureSecureSession(String uid) async {
    if (auth.currentUser != null) return;
    try {
      final s = await db.ref('users/$uid').get();
      final m = asMap(s.value);
      final pw = asStr(m['password']);
      final name = asStr(m['username'], username);
      if (pw.isEmpty) {
        // Hesap taşınmış ama bu cihazda Firebase oturumu yok: tekrar giriş gerekli.
        if (asStr(m['authUid']).isNotEmpty) await logout();
        return;
      }
      UserCredential cred;
      try {
        cred = await auth.signInWithEmailAndPassword(email: authEmail(uid), password: authPassword(pw));
      } on FirebaseAuthException catch (e) {
        if (_authUnavailable(e)) return;
        cred = await auth.createUserWithEmailAndPassword(email: authEmail(uid), password: authPassword(pw));
      }
      await _linkAccount(uid, cred.user!.uid, name);
    } catch (_) {}
  }

  Future<String?> register(
    String username,
    String password, {
    String? photoDataUrl,
    String bio = '',
  }) async {
    username = username.trim();
    final v = validateUsername(username);
    if (v != null) return v;
    if (password.length < 6) return 'Şifre en az 6 karakter olmalı.';
    try {
      if (await isUsernameTaken(username)) return 'Bu kullanıcı adı zaten alınmış.';
      final ref = db.ref('users').push();
      final uid = ref.key!;
      String? authUid;
      try {
        final cred = await auth.createUserWithEmailAndPassword(
            email: authEmail(uid), password: authPassword(password));
        authUid = cred.user!.uid;
        await db.ref('authMap/$authUid').set(uid);
      } on FirebaseAuthException catch (e) {
        if (!_authUnavailable(e)) {
          return e.code == 'network-request-failed'
              ? 'Sunucuya ulaşılamadı. İnternet bağlantını kontrol et.'
              : 'Kayıt başarısız (${e.code}).';
        }
      }
      await ref.set({
        'username': username,
        // Güvenli giriş açık değilse (geçici) eski yöntem; açıksa şifre ASLA veritabanına yazılmaz.
        if (authUid == null) 'password': password,
        if (authUid != null) 'authUid': authUid,
        'isOnline': true,
        'createdAt': ServerValue.timestamp,
        'lastSeen': DateTime.now().millisecondsSinceEpoch,
        'role': 'user',
        if (photoDataUrl != null) 'profilePhoto': photoDataUrl,
        if (bio.trim().isNotEmpty) 'bio': bio.trim(),
        'settings': {
          'messageNotifications': true,
          'soundNotifications': true,
          'showReadReceipts': true,
          'lockscreenPreview': true,
        },
      });
      await db.ref('usernames/${nameKey(username)}/$uid').set(true).catchError((_) {});
      await _setSession(uid, username);
      return null;
    } on TimeoutException {
      return 'Sunucuya ulaşılamadı. İnternet bağlantını kontrol et.';
    } catch (e) {
      return 'Kayıt başarısız. Lütfen tekrar dene.\n($e)';
    }
  }

  /// Yönetici: henüz taşınmamış TÜM hesapları güvenli girişe taşır ve açık şifreleri siler.
  /// Ayrı bir Firebase örneğiyle çalışır (senin oturumun kapanmaz).
  Future<String> migrateAllAccounts(void Function(int done, int total) onProgress) async {
    final all = await _fetchUsers();
    final todo = all.entries
        .where((e) => asStr(e.value['password']).isNotEmpty || asStr(e.value['authUid']).isNotEmpty)
        .toList();
    FirebaseApp app2;
    try {
      app2 = Firebase.app('migrator');
    } catch (_) {
      app2 = await Firebase.initializeApp(name: 'migrator', options: FirebaseConfig.options);
    }
    final auth2 = FirebaseAuth.instanceFor(app: app2);
    final db2 = FirebaseDatabase.instanceFor(app: app2, databaseURL: FirebaseConfig.databaseUrl);
    var ok = 0, skipped = 0, done = 0;
    for (final e in todo) {
      final uid = e.key;
      final m = e.value;
      final pw = asStr(m['password']);
      final name = asStr(m['username'], 'Kullanıcı');
      try {
        if (pw.isEmpty) {
          // Zaten taşınmış: sadece indeks eksikse tamamla.
          await db.ref('usernames/${nameKey(name)}/$uid').set(true).catchError((_) {});
          ok++;
        } else {
          UserCredential cred;
          try {
            cred = await auth2.createUserWithEmailAndPassword(email: authEmail(uid), password: authPassword(pw));
          } on FirebaseAuthException catch (x) {
            if (x.code == 'email-already-in-use') {
              cred = await auth2.signInWithEmailAndPassword(email: authEmail(uid), password: authPassword(pw));
            } else {
              rethrow;
            }
          }
          await _linkAccount(uid, cred.user!.uid, name, using: db2);
          await auth2.signOut();
          ok++;
        }
      } on FirebaseAuthException catch (x) {
        if (_authUnavailable(x)) {
          return 'Firebase Console\'da Authentication → Sign-in method → Email/Password açık değil.';
        }
        if (x.code == 'too-many-requests') {
          return '$ok hesap taşındı. Firebase sınırına takıldı; bir saat sonra tekrar bas, kaldığı yerden devam eder.';
        }
        skipped++;
      } catch (_) {
        skipped++;
      }
      done++;
      onProgress(done, todo.length);
    }
    return skipped == 0
        ? 'Tamamlandı: $ok hesap güvenli girişe taşındı, açık şifreler silindi ✅'
        : '$ok hesap taşındı, $skipped hesap taşınamadı (tekrar deneyebilirsin).';
  }

  Future<void> _setSession(String uid, String name) async {
    _uid = uid;
    _username = name;
    await prefs.setString('uid', uid);
    await prefs.setString('username', name);
    notifyListeners();
    await _startSession();
  }

  /// Kullanıcı bir içeriği / kişiyi yöneticiye şikayet eder (yönetim panelinde görünür).
  Future<void> report({
    required String type,
    required String targetUid,
    String path = '',
    String preview = '',
    required String reason,
  }) async {
    final uid = _uid;
    if (uid == null) return;
    await db.ref('reports').push().set({
      'app': 'Qyriptalk',
      'type': type,
      'targetUid': targetUid,
      'targetName': users[targetUid]?.username ?? '',
      'path': path,
      'preview': preview.length > 400 ? preview.substring(0, 400) : preview,
      'reason': reason,
      'from': uid,
      'fromName': username,
      'ts': ServerValue.timestamp,
    });
  }

  /// Hesabı kalıcı olarak siler (profil, kullanıcı adı, oda üyelikleri, giriş hesabı).
  Future<String?> deleteMyAccount(String password) async {
    final uid = _uid;
    if (uid == null) return 'Oturum yok.';
    final u = auth.currentUser;
    try {
      if (u != null) {
        await u.reauthenticateWithCredential(
            EmailAuthProvider.credential(email: u.email ?? authEmail(uid), password: authPassword(password)));
      } else {
        final s = await db.ref('users/$uid/password').get();
        if (asStr(s.value) != password) return 'Şifre hatalı.';
      }
    } on FirebaseAuthException catch (e) {
      return e.code == 'network-request-failed' ? 'İnternet bağlantını kontrol et.' : 'Şifre hatalı.';
    } catch (_) {
      return 'Şifre doğrulanamadı.';
    }
    try {
      await db.ref('users/$uid').onDisconnect().cancel();
      await db.ref('users/$uid/isOnline').onDisconnect().cancel();
      await db.ref('users/$uid/lastSeen').onDisconnect().cancel();
      final up = <String, Object?>{
        'users/$uid': null,
        'usernames/${nameKey(username)}/$uid': null,
        'fcmTokens/$uid': null,
      };
      for (final r in joinedRoomIds) {
        up['rooms/$r/users/$uid'] = null;
      }
      await db.ref().update(up);
      if (u != null) {
        await db.ref('authMap/${u.uid}').remove().catchError((_) {});
        await u.delete().catchError((_) {});
      }
    } catch (e) {
      return 'Hesap silinemedi: $e';
    }
    await logout(deleted: true);
    return null;
  }

  Future<void> logout({bool deleted = false}) async {
    final uid = _uid;
    await NativeBridge.clearSession();
    await OfflineStore.clearAll();
    if (uid != null && !deleted) {
      try {
        await NotificationService.unregisterToken(db, uid);
        await db.ref('users/$uid/isOnline').set(false);
        await db.ref('users/$uid/lastSeen').set(ServerValue.timestamp);
      } catch (_) {}
    }
    await _stopSession();
    try {
      await auth.signOut();
    } catch (_) {}
    _uid = null;
    _username = null;
    await prefs.remove('uid');
    await prefs.remove('username');
    users.clear();
    rooms.clear();
    joinedRoomIds.clear();
    _last.clear();
    _unread.clear();
    settings = {};
    await NotificationService.cancelAll();
    notifyListeners();
  }

  // ======================================================================
  // OTURUM DİNLEYİCİLERİ
  // ======================================================================

  Future<void> _startSession() async {
    final uid = _uid;
    if (uid == null) return;
    await _stopSession();

    _setPresence(true);

    // İnternetsizken de son sohbetler görünsün: cihazdaki kopyayı hemen yükle.
    await _loadHomeCache();

    _subs.add(db.ref('.info/connected').onValue.listen((e) {
      if (e.snapshot.value == true) _setPresence(true);
    }));

    _subs.add(db.ref('users').onValue.listen((e) {
      final all = asMap(e.snapshot.value);
      users.clear();
      all.forEach((k, v) {
        final m = asMap(v);
        if (m.isEmpty) return;
        users[k] = AppUser.fromMap(k, m);
      });
      final mine = users[uid];
      if (mine != null && mine.username != _username) {
        _username = mine.username;
        prefs.setString('username', mine.username);
      }
      _usersLoaded = true;
      _syncDmListeners();
      notifyListeners();
      _saveHomeCacheSoon();
    }, onError: (_) {
      _usersLoaded = true;
      notifyListeners();
    }));

    _subs.add(db.ref('users/$uid/blocked').onValue.listen((e) {
      blocked
        ..clear()
        ..addAll(asMap(e.snapshot.value).keys);
      notifyListeners();
    }, onError: (_) {}));

    _subs.add(db.ref('users/$uid/clearedChats').onValue.listen((e) {
      _cleared
        ..clear()
        ..addAll(asMap(e.snapshot.value).map((k, v) => MapEntry(k, asStr(v))));
      notifyListeners();
    }, onError: (_) {}));

    _subs.add(db.ref('users/$uid/settings').onValue.listen((e) {
      settings = asMap(e.snapshot.value);
      _mirrorSettings();
      notifyListeners();
    }, onError: (_) {}));

    _subs.add(db.ref('users/$uid/joinedRooms').onValue.listen((e) {
      final ids = asMap(e.snapshot.value).keys.toSet();
      joinedRoomIds
        ..clear()
        ..addAll(ids);
      for (final id in ids) {
        if (!rooms.containsKey(id) && _roomMetaPending.add(id)) {
          unawaited(refreshRoom(id).whenComplete(() {
            _roomMetaPending.remove(id);
            notifyListeners();
          }));
        }
      }
      _joinedLoaded = true;
      _syncRoomListeners();
      notifyListeners();
      _saveHomeCacheSoon();
    }, onError: (_) {
      _joinedLoaded = true;
      notifyListeners();
    }));

    unawaited(NotificationService.registerToken(db, uid));
    _syncNative();
  }

  Future<void> _stopSession() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    for (final s in _lastSubs.values) {
      await s.cancel();
    }
    _lastSubs.clear();
    _lastInitialized.clear();
    for (final s in _memberSubs.values) {
      await s.cancel();
    }
    _memberSubs.clear();
    _roomMembers.clear();
    _usersLoaded = false;
    _joinedLoaded = false;
    _roomMetaPending.clear();
  }

  void _setPresence(bool online) {
    final uid = _uid;
    if (uid == null) return;
    final r = db.ref('users/$uid');
    r.child('isOnline').set(online).catchError((_) {});
    if (online) {
      r.child('isOnline').onDisconnect().set(false).catchError((_) {});
      r.child('lastSeen').onDisconnect().set(ServerValue.timestamp).catchError((_) {});
    } else {
      r.child('lastSeen').set(ServerValue.timestamp).catchError((_) {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!isLoggedIn) return;
    foreground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) {
      if (activeChatKey != null) _unread[activeChatKey!] = 0;
      _setPresence(true);
      db.goOnline();
    } else if (state == AppLifecycleState.paused) {
      _setPresence(false);
    }
  }

  // ======================================================================
  // SON MESAJ DİNLEYİCİLERİ (sohbet listesi + bildirimler)
  // ======================================================================

  void _syncRoomListeners() {
    for (final id in joinedRoomIds) {
      _listenLast('room:$id', 'rooms/$id/messages', id, false);
      _memberSubs[id] ??= db.ref('rooms/$id/users').onValue.listen((e) {
        _roomMembers[id] = asMap(e.snapshot.value).keys.toSet();
        notifyListeners();
      }, onError: (_) {});
    }
    for (final id in _memberSubs.keys.where((k) => !joinedRoomIds.contains(k)).toList()) {
      _memberSubs.remove(id)?.cancel();
      _roomMembers.remove(id);
    }
    final stale = _lastSubs.keys
        .where((k) => k.startsWith('room:') && !joinedRoomIds.contains(k.substring(5)))
        .toList();
    for (final k in stale) {
      _lastSubs.remove(k)?.cancel();
      _last.remove(k);
      _unread.remove(k);
    }
  }

  // ---------- Gizlilik: çevrimiçi / son görülme sadece tanıdıklara ----------
  final Map<String, StreamSubscription> _memberSubs = {};
  final Map<String, Set<String>> _roomMembers = {};

  /// Mesajlaştığın ya da aynı odada olduğun kişi mi?
  bool isContact(String uid) {
    final me = _uid;
    if (me == null || uid == me) return false;
    if (_last.containsKey('dm:${dmIdFor(me, uid)}')) return true;
    for (final s in _roomMembers.values) {
      if (s.contains(uid)) return true;
    }
    return false;
  }

  /// Çevrimiçi göstergesi (tanımadığın kişilerde hiç gösterilmez).
  bool onlineVisible(AppUser? u) => u != null && u.isOnline && isContact(u.uid);

  /// "çevrimiçi" / "son görülme ..." yazısı (tanımadığın kişilerde boş).
  String presenceText(AppUser? u) => (u == null || !isContact(u.uid)) ? '' : u.statusText;

  // ---------- Engelleme ----------
  /// Engellediğim kişiler: mesaj atamaz, arayamaz, bildirimleri gelmez.
  final Set<String> blocked = {};

  bool isBlocked(String other) => blocked.contains(other);

  Future<void> setBlocked(String other, bool block) async {
    final uid = _uid;
    if (uid == null || other == uid) return;
    block ? blocked.add(other) : blocked.remove(other);
    notifyListeners();
    final r = db.ref('users/$uid/blocked/$other');
    await (block ? r.set(true) : r.remove()).catchError((_) {});
  }

  /// Karşı taraf beni engellemiş mi?
  Future<bool> hasBlockedMe(String other) async {
    final uid = _uid;
    if (uid == null) return false;
    try {
      return (await db.ref('users/$other/blocked/$uid').get()).exists;
    } catch (_) {
      return false;
    }
  }

  // ---------- Sohbeti temizle (sadece kendin için) ----------
  /// sohbet anahtarı -> temizlendiği andaki son mesajın kimliği (o ve öncesi gizlenir)
  final Map<String, String> _cleared = {};

  bool isClearedMsg(String key, String msgId) {
    final c = _cleared[key];
    return c != null && msgId.compareTo(c) <= 0;
  }

  Future<void> clearChat(String key, String? lastMsgId) async {
    final uid = _uid;
    if (uid == null || lastMsgId == null) return;
    _cleared[key] = lastMsgId;
    _unread[key] = 0;
    notifyListeners();
    await OfflineStore.write('chat_$key', const <Object?>[]);
    await db.ref('users/$uid/clearedChats/${_safeKey(key)}').set(lastMsgId).catchError((_) {});
  }

  static String _safeKey(String key) => key.replaceAll(RegExp(r'[.#$\[\]/]'), '_');

  void _syncDmListeners() {
    final uid = _uid;
    if (uid == null) return;
    for (final other in users.keys) {
      if (other == uid) continue;
      final dmId = dmIdFor(uid, other);
      _listenLast('dm:$dmId', 'privateMessages/$dmId/messages', dmId, true);
    }
  }

  void _listenLast(String key, String path, String chatId, bool isDm) {
    if (_lastSubs.containsKey(key)) return;
    _lastSubs[key] = db.ref(path).limitToLast(1).onValue.listen((e) {
      ChatMessage? msg;
      for (final c in e.snapshot.children) {
        msg = ChatMessage.fromMap(c.key!, asMap(c.value));
      }
      final prev = _last[key];
      final firstLoad = !_lastInitialized.contains(key);
      _lastInitialized.add(key);
      if (msg == null) {
        if (_last.remove(key) != null) notifyListeners();
        return;
      }
      _last[key] = msg;
      final mine = msg.senderUid == _uid;
      if (!mine) {
        if (firstLoad) {
          if (!msg.readBy.contains(_uid) && !isClearedMsg(key, msg.id) && (activeChatKey != key || !foreground)) {
            _unread[key] = (_unread[key] ?? 0) < 1 ? 1 : _unread[key]!;
          }
        } else if (prev?.id != msg.id) {
          if (activeChatKey != key || !foreground) {
            _unread[key] = (_unread[key] ?? 0) + 1;
            // Uygulama ekrandayken bildirimi biz gösteririz; arka planda / kapalıyken
            // yerel servis (sesli, sohbet başına tek bildirim, Yanıtla/Okundu) gösterir.
            if (foreground) _notifyIncoming(key, chatId, isDm, msg);
          }
        }
      }
      notifyListeners();
      _saveHomeCacheSoon();
    }, onError: (_) {});
  }

  void _notifyIncoming(String key, String chatId, bool isDm, ChatMessage msg) {
    if (!notificationsEnabled || _muted.contains(key) || isBlocked(msg.senderUid)) return;
    final title = isDm ? msg.sender : (rooms[chatId]?.name ?? 'Oda');
    final body = isDm ? msg.previewText : '${msg.sender}: ${msg.previewText}';
    NotificationService.showMessage(
      key: key,
      title: title,
      body: body,
      showContent: lockscreenPreview,
      silent: !soundEnabled,
    );
    if (speakMessages) {
      NotificationService.speak('${msg.sender} diyor ki: ${msg.previewText}');
    }
  }

  // ======================================================================
  // ÇEVRİMDIŞI KOPYA (internet yokken son sohbetler)
  // ======================================================================

  final Map<String, Map<String, dynamic>> _roomRaw = {};
  Timer? _saveTimer;

  static const int _maxInlineImage = 150 * 1024;

  void _saveHomeCacheSoon() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 3), _saveHomeCache);
  }

  Future<void> _saveHomeCache() async {
    final uid = _uid;
    if (uid == null || !_usersLoaded) return;
    String? small(String? s) => (s != null && s.length <= _maxInlineImage) ? s : null;
    final u = <String, Object?>{};
    users.forEach((k, v) {
      u[k] = {
        'username': v.username,
        'profilePhoto': small(v.photo),
        'bio': v.bio,
        'lastSeen': v.lastSeen,
        'role': v.role,
      };
    });
    final r = <String, Object?>{};
    for (final id in joinedRoomIds) {
      final m = _roomRaw[id];
      if (m == null) continue;
      r[id] = {...m, 'logo': small(asStrOrNull(m['logo']))};
    }
    final last = <String, Object?>{};
    _last.forEach((k, m) {
      final raw = Map<String, dynamic>.from(m.raw)
        ..remove('fileData')
        ..remove('imageData');
      last[k] = {'id': m.id, 'raw': raw};
    });
    await OfflineStore.write('home_$uid', OfflineStore.plain({
      'users': u,
      'rooms': r,
      'joined': joinedRoomIds.toList(),
      'last': last,
    })!);
  }

  Future<void> _loadHomeCache() async {
    final uid = _uid;
    if (uid == null) return;
    final data = asMap(await OfflineStore.read('home_$uid'));
    if (data.isEmpty) return;
    if (users.isEmpty) {
      asMap(data['users']).forEach((k, v) {
        final m = asMap(v);
        if (m.isNotEmpty) users[k] = AppUser.fromMap(k, m);
      });
    }
    asMap(data['rooms']).forEach((k, v) {
      final m = asMap(v);
      if (m.isEmpty || rooms.containsKey(k)) return;
      rooms[k] = Room.fromMap(k, m);
      _roomRaw[k] = m;
    });
    final joined = data['joined'];
    if (joined is List && joinedRoomIds.isEmpty) {
      joinedRoomIds.addAll(joined.map((e) => '$e'));
    }
    asMap(data['last']).forEach((k, v) {
      final m = asMap(v);
      final id = asStr(m['id']);
      if (id.isEmpty || _last.containsKey(k)) return;
      _last[k] = ChatMessage.fromMap(id, asMap(m['raw']));
    });
    if (users.isNotEmpty) _usersLoaded = true;
    _joinedLoaded = true;
    notifyListeners();
  }

  // ======================================================================
  // SOHBET LİSTESİ
  // ======================================================================

  List<ChatSummary> chatSummaries({bool archived = false}) {
    final uid = _uid;
    if (uid == null) return const [];
    final out = <ChatSummary>[];
    for (final id in joinedRoomIds) {
      final key = 'room:$id';
      if (_archived.contains(key) != archived) continue;
      final r = rooms[id];
      // Bilgisi henüz gelmemiş (ya da silinmiş) odaları gösterme: yanıp sönmesin.
      if (r == null) continue;
      out.add(ChatSummary(
        id: id,
        isDm: false,
        title: r.name,
        photo: r.logo,
        last: (_last[key] != null && isClearedMsg(key, _last[key]!.id)) ? null : _last[key],
        unread: _unread[key] ?? 0,
        muted: _muted.contains(key),
        pinned: _pinned.contains(key),
      ));
    }
    _last.forEach((key, msg) {
      if (!key.startsWith('dm:')) return;
      if (_archived.contains(key) != archived) return;
      final dmId = key.substring(3);
      final other = otherUidFromDm(dmId, uid);
      final u = users[other];
      if (u == null) return;
      out.add(ChatSummary(
        id: dmId,
        isDm: true,
        title: u.username,
        photo: u.photo,
        otherUid: other,
        last: isClearedMsg(key, msg.id) ? null : msg,
        unread: _unread[key] ?? 0,
        online: u.isOnline,
        muted: _muted.contains(key),
        pinned: _pinned.contains(key),
      ));
    });
    out.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.sortTs.compareTo(a.sortTs);
    });
    return out;
  }

  int get totalUnread {
    var t = 0;
    _unread.forEach((k, v) {
      if (!_muted.contains(k) && !_archived.contains(k)) t += v;
    });
    return t;
  }

  int get archivedCount => chatSummaries(archived: true).length;

  void markChatOpened(String key) {
    activeChatKey = key;
    if ((_unread[key] ?? 0) != 0) {
      _unread[key] = 0;
      notifyListeners();
    }
    NotificationService.cancelForKey(key);
    NativeBridge.dismissConversation(key);
  }

  void markChatClosed(String key) {
    if (activeChatKey == key) activeChatKey = null;
  }

  bool isMuted(String key) => _muted.contains(key);
  bool isPinned(String key) => _pinned.contains(key);
  bool isArchived(String key) => _archived.contains(key);

  void toggleMute(String key) {
    _muted.contains(key) ? _muted.remove(key) : _muted.add(key);
    prefs.setStringList('mutedChats', _muted.toList());
    notifyListeners();
  }

  void togglePin(String key) {
    _pinned.contains(key) ? _pinned.remove(key) : _pinned.add(key);
    prefs.setStringList('pinnedChats', _pinned.toList());
    notifyListeners();
  }

  void toggleArchive(String key) {
    _archived.contains(key) ? _archived.remove(key) : _archived.add(key);
    prefs.setStringList('archivedChats', _archived.toList());
    notifyListeners();
  }

  // ======================================================================
  // ODALAR
  // ======================================================================

  Future<Room?> refreshRoom(String id) async {
    try {
      final base = db.ref('rooms/$id');
      final keys = ['name', 'logo', 'isPrivate', 'password', 'passwordHash', 'createdBy', 'createdAt', 'description'];
      final snaps = await Future.wait(keys.map((k) => base.child(k).get()));
      final m = <String, dynamic>{};
      for (var i = 0; i < keys.length; i++) {
        if (snaps[i].exists) m[keys[i]] = snaps[i].value;
      }
      if (m['name'] == null) {
        // İnternet yokken boş gelen yanıt "oda silindi" demek değildir.
        if (!connected) return rooms[id];
        // Oda silinmiş.
        rooms.remove(id);
        if (joinedRoomIds.contains(id) && _uid != null) {
          await db.ref('users/$_uid/joinedRooms/$id').remove();
        }
        notifyListeners();
        return null;
      }
      // Eski odalarda açık metin şifre: oda sahibi açınca özet (hash) haline çevrilir.
      final plain = asStr(m['password']);
      if (plain.isNotEmpty && asStr(m['createdBy']) == _uid) {
        final h = roomPasswordHash(id, plain);
        await base.update({'passwordHash': h, 'password': null}).catchError((_) {});
        m['passwordHash'] = h;
        m.remove('password');
      }
      final r = Room.fromMap(id, m);
      rooms[id] = r;
      _roomRaw[id] = m;
      notifyListeners();
      _saveHomeCacheSoon();
      return r;
    } catch (_) {
      return rooms[id];
    }
  }

  /// Herkese açık odaları listeler (mesajları indirmeden: önce anahtarlar).
  Future<List<Room>> discoverRooms() async {
    final ids = await _shallowKeys('rooms');
    final list = await Future.wait(ids.map((id) async {
      final cached = rooms[id];
      if (cached != null) return cached;
      return refreshRoom(id);
    }));
    final out = list.whereType<Room>().where((r) => !r.isPrivate).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }

  Future<List<String>> _shallowKeys(String path) async {
    // Realtime Database REST API: ?shallow=true sadece anahtarları döndürür.
    try {
      String? token;
      try {
        token = await auth.currentUser?.getIdToken();
      } catch (_) {}
      final res = await http
          .get(Uri.parse(
              '${FirebaseConfig.databaseUrl}/$path.json?shallow=true${token != null ? '&auth=$token' : ''}'))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return [];
      final json = jsonDecode(res.body);
      if (json is Map) return json.keys.map((e) => e.toString()).toList();
    } catch (_) {}
    return [];
  }

  /// Oda oluşturur ve oda kimliğini döndürür. Hata durumunda [Exception] fırlatır.
  Future<String> createRoom({
    required String name,
    String? password,
    bool isPrivate = false,
    String? logoDataUrl,
    String description = '',
  }) async {
    final uid = _uid;
    if (uid == null) throw Exception('Oturum yok.');
    name = name.trim();
    if (name.length < 2) throw Exception('Oda adı en az 2 karakter olmalı.');
    final ref = db.ref('rooms').push();
      final data = <String, Object?>{
        'name': name,
        'passwordHash': (password == null || password.trim().isEmpty)
            ? null
            : roomPasswordHash(ref.key!, password.trim()),
        'isPrivate': isPrivate,
        'createdBy': uid,
        'createdAt': ServerValue.timestamp,
        if (logoDataUrl != null) 'logo': logoDataUrl,
        if (description.isNotEmpty) 'description': description,
      };
    await ref.set(data);
    await joinRoom(ref.key!);
    await refreshRoom(ref.key!);
    return ref.key!;
  }

  Future<void> joinRoom(String roomId) async {
    final uid = _uid;
    if (uid == null) return;
    await db.ref('rooms/$roomId/users/$uid').set({'username': username, 'online': true});
    await db.ref('users/$uid/joinedRooms/$roomId').set(true);
    joinedRoomIds.add(roomId);
    _syncRoomListeners();
    notifyListeners();
  }

  Future<void> leaveRoom(String roomId) async {
    final uid = _uid;
    if (uid == null) return;
    await db.ref('rooms/$roomId/users/$uid').remove();
    await db.ref('users/$uid/joinedRooms/$roomId').remove();
    joinedRoomIds.remove(roomId);
    _syncRoomListeners();
    notifyListeners();
  }

  Future<void> deleteRoom(String roomId) async {
    final uid = _uid;
    await db.ref('rooms/$roomId').remove();
    if (uid != null) await db.ref('users/$uid/joinedRooms/$roomId').remove();
    joinedRoomIds.remove(roomId);
    rooms.remove(roomId);
    _syncRoomListeners();
    notifyListeners();
  }

  static ({String id, String name})? parseInvite(String input) {
    final s = input.trim();
    final i = s.indexOf('Qyriptalk/');
    if (i >= 0) {
      final after = s.substring(i + 'Qyriptalk/'.length);
      final slash = after.lastIndexOf('/');
      if (slash > 0) {
        final id = after.substring(slash + 1).trim();
        if (id.length >= 15) return (id: id, name: after.substring(0, slash));
      }
    }
    // Yalnızca oda kimliği yapıştırıldıysa
    if (RegExp(r'^-[\w-]{15,}$').hasMatch(s)) return (id: s, name: '');
    return null;
  }

  // ======================================================================
  // AYARLAR / PROFİL
  // ======================================================================

  bool _setting(String k, bool def) {
    final v = settings[k];
    if (v == null) return def;
    return asBool(v);
  }

  bool get enterToSend => _setting('enterToSend', false);
  bool get showReadReceipts => _setting('showReadReceipts', true);
  bool get autoTranslate => _setting('autoTranslate', false);
  bool get notificationsEnabled => _setting('messageNotifications', true);
  bool get soundEnabled => _setting('soundNotifications', true);
  bool get lockscreenPreview => _setting('lockscreenPreview', true);
  bool get speakMessages => _setting('speakMessages', false);
  bool get compactMode => _setting('compactMode', false);

  /// Arka plan bildirim işleyicisi (ayrı isolate) ayarları buradan okur.
  void _mirrorSettings() {
    prefs.setBool('lockscreenPreview', lockscreenPreview);
    prefs.setBool('soundNotifications', soundEnabled);
    _syncNative();
  }

  /// Arka plan servisine (uygulama kapalıyken bildirimler) oturum ve tercihleri iletir.
  void _syncNative() {
    final uid = _uid;
    if (uid == null) return;
    NativeBridge.setSession(
      uid: uid,
      username: username,
      enabled: notificationsEnabled,
      sound: soundEnabled,
      preview: lockscreenPreview,
      speak: speakMessages,
    );
  }

  Future<void> setSetting(String key, Object value) async {
    settings = {...settings, key: value};
    _mirrorSettings();
    notifyListeners();
    final uid = _uid;
    if (uid != null) {
      await db.ref('users/$uid/settings/$key').set(value).catchError((_) {});
    }
  }

  void setThemeMode(ThemeMode m) {
    _themeMode = m;
    prefs.setInt('themeMode', m.index);
    notifyListeners();
  }

  Future<void> updateProfile({String? bio, String? photoDataUrl, bool removePhoto = false}) async {
    final uid = _uid;
    if (uid == null) return;
    final up = <String, Object?>{};
    if (bio != null) up['bio'] = bio;
    if (photoDataUrl != null) up['profilePhoto'] = photoDataUrl;
    if (removePhoto) up['profilePhoto'] = null;
    if (up.isNotEmpty) await db.ref('users/$uid').update(up);
  }

  Future<String?> changePassword(String current, String next) async {
    final uid = _uid;
    if (uid == null) return 'Oturum yok.';
    if (next.length < 6) return 'Yeni şifre en az 6 karakter olmalı.';
    final u = auth.currentUser;
    if (u != null) {
      try {
        await u.reauthenticateWithCredential(
            EmailAuthProvider.credential(email: u.email ?? authEmail(uid), password: authPassword(current)));
        await u.updatePassword(authPassword(next));
        return null;
      } on FirebaseAuthException catch (e) {
        if (e.code == 'network-request-failed') return 'İnternet bağlantını kontrol et.';
        return 'Mevcut şifre hatalı.';
      }
    }
    final s = await db.ref('users/$uid/password').get();
    if (asStr(s.value) != current) return 'Mevcut şifre hatalı.';
    await db.ref('users/$uid/password').set(next);
    return null;
  }

  Future<String?> changeUsername(String next) async {
    final uid = _uid;
    if (uid == null) return 'Oturum yok.';
    next = next.trim();
    final v = validateUsername(next);
    if (v != null) return v;
    if (await isUsernameTaken(next)) return 'Bu kullanıcı adı alınmış.';
    final old = _username ?? '';
    await db.ref('users/$uid/username').set(next);
    if (old.isNotEmpty && nameKey(old) != nameKey(next)) {
      await db.ref('usernames/${nameKey(old)}/$uid').remove().catchError((_) {});
    }
    await db.ref('usernames/${nameKey(next)}/$uid').set(true).catchError((_) {});
    _username = next;
    await prefs.setString('username', next);
    notifyListeners();
    return null;
  }

  // ======================================================================
  // ARAMA GEÇMİŞİ (cihazda)
  // ======================================================================

  List<CallLogEntry> get callLog {
    final raw = prefs.getStringList('callLog_${_uid ?? ''}') ?? const [];
    return raw
        .map((s) {
          try {
            return CallLogEntry.fromJson(asMap(jsonDecode(s)));
          } catch (_) {
            return null;
          }
        })
        .whereType<CallLogEntry>()
        .toList()
      ..sort((a, b) => b.ts.compareTo(a.ts));
  }

  Future<void> addCallLog(CallLogEntry e) async {
    final k = 'callLog_${_uid ?? ''}';
    final list = prefs.getStringList(k) ?? <String>[];
    list.removeWhere((s) => s.contains('"id":"${e.id}"'));
    list.add(jsonEncode(e.toJson()));
    while (list.length > 100) {
      list.removeAt(0);
    }
    await prefs.setStringList(k, list);
    notifyListeners();
  }

  Future<void> clearCallLog() async {
    await prefs.remove('callLog_${_uid ?? ''}');
    notifyListeners();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopSession();
    openChatRequests.close();
    super.dispose();
  }
}
