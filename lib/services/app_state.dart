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
import 'notification_service.dart';

/// Giriş akışının aşaması.
/// - signedOut: giriş / kayıt ekranı
/// - verifyEmail: e-posta doğrulama bekleniyor
/// - upgradeLegacy: eski (doğrulamasız) hesap, e-posta ile güvenceye alınmalı
enum AuthStage { signedOut, verifyEmail, upgradeLegacy }

/// Uygulamanın tek gerçek kaynağı: oturum, kullanıcılar, odalar, sohbet özetleri.
class AppState extends ChangeNotifier with WidgetsBindingObserver {
  AppState(this.prefs) {
    db = FirebaseDatabase.instanceFor(
      app: Firebase.app(),
      databaseURL: FirebaseConfig.databaseUrl,
    );
    auth = FirebaseAuth.instanceFor(app: Firebase.app());
    // Doğrulama ve şifre sıfırlama e-postaları Türkçe gelsin.
    auth.setLanguageCode('tr').catchError((_) {});
    WidgetsBinding.instance.addObserver(this);
    final ti = prefs.getInt('themeMode') ?? 0;
    _themeMode = (ti >= 0 && ti < ThemeMode.values.length)
        ? ThemeMode.values[ti]
        : ThemeMode.system;
    _muted.addAll(prefs.getStringList('mutedChats') ?? const []);
    _pinned.addAll(prefs.getStringList('pinnedChats') ?? const []);
    _archived.addAll(prefs.getStringList('archivedChats') ?? const []);
  }

  final SharedPreferences prefs;
  late final FirebaseDatabase db;
  late final FirebaseAuth auth;

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
  bool connected = true;
  bool foreground = true;
  bool _usersLoaded = false;
  bool _joinedLoaded = false;
  final Set<String> _roomMetaPending = {};

  /// Sohbet listesi ilk kez tamamen yüklendi mi? (Yüklenirken boş ekran / yanıp sönme olmasın.)
  bool get chatsReady => _usersLoaded && _joinedLoaded && _roomMetaPending.isEmpty;
  String? activeChatKey;

  ThemeMode _themeMode = ThemeMode.system;
  ThemeMode get themeMode => _themeMode;

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

  // ---------------- Doğrulama akışı ----------------
  AuthStage authStage = AuthStage.signedOut;
  String? _legacyUid;
  String? _legacyName;
  String? get legacyName => _legacyName;
  String get pendingEmail => auth.currentUser?.email ?? '';

  /// Eski sürümden kalan doğrulamasız oturum kapatıldıysa bir kez bilgi göster.
  bool securityNotice = false;

  Future<void> restoreSession() async {
    try {
      final fb = auth.currentUser;
      if (fb != null) {
        try {
          await fb.reload();
        } catch (_) {}
        final u = auth.currentUser;
        if (u != null && u.emailVerified) {
          _restoring = false;
          await _finishAuth(u);
          return;
        } else if (u != null) {
          authStage = AuthStage.verifyEmail;
        }
      } else if (prefs.getString('uid') != null) {
        // Doğrulamasız eski oturum: güvenlik için yeniden giriş + doğrulama istenir.
        await prefs.remove('uid');
        await prefs.remove('username');
        securityNotice = true;
      }
    } catch (_) {}
    _restoring = false;
    notifyListeners();
  }

  /// Tüm kullanıcıları (uid -> veri) getirir. Realtime Database'de "username" için
  /// indeks tanımlı olmadığından sorgu yerine istemci tarafında filtreleriz.
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

  /// Firebase anahtarlarında kullanılamayan karakterleri temizler (. # $ [ ] /).
  static String _key(String s) => _norm(s).replaceAll(RegExp(r'[.#$\[\]/]'), '_');

  /// Kullanıcı adı alınmış mı? (büyük/küçük harf duyarsız)
  Future<bool> isUsernameTaken(String name) async {
    final n = _norm(name);
    if (n.isEmpty) return false;
    try {
      final idx = await db.ref('usernames/${_key(name)}').get();
      final owner = asStr(asMap(idx.value)['uid']);
      if (owner.isNotEmpty && owner != _uid) return true;
    } catch (_) {}
    try {
      final all = await _fetchUsers();
      return all.entries.any((e) => _norm(asStr(e.value['username'])) == n && e.key != _uid);
    } catch (_) {
      // Sıkı veritabanı kurallarında giriş yapmadan kullanıcı listesi okunamaz; indeks yeterli.
      return false;
    }
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

  static String? validateEmail(String email) {
    final e = email.trim();
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$').hasMatch(e)) return 'Geçerli bir e-posta adresi gir.';
    return null;
  }

  /// Güçlü şifre kuralı: en az 8 karakter, harf ve rakam.
  static String? validatePassword(String p) {
    if (p.length < 8) return 'Şifre en az 8 karakter olmalı.';
    if (!RegExp(r'[0-9]').hasMatch(p) || !RegExp(r'[A-Za-zçğıöşüÇĞİÖŞÜ]').hasMatch(p)) {
      return 'Şifre hem harf hem rakam içermeli.';
    }
    return null;
  }

  // ---- Kaba kuvvet (brute-force) koruması: art arda hatalı girişte bekletme ----
  int get lockSecondsLeft {
    final until = prefs.getInt('authLockUntil') ?? 0;
    final left = ((until - DateTime.now().millisecondsSinceEpoch) / 1000).ceil();
    return left > 0 ? left : 0;
  }

  String _fail(String msg) {
    final n = (prefs.getInt('authFails') ?? 0) + 1;
    prefs.setInt('authFails', n);
    if (n >= 5) {
      final secs = (30 * (1 << (n - 5))).clamp(30, 900).toInt();
      prefs.setInt('authLockUntil', DateTime.now().millisecondsSinceEpoch + secs * 1000);
      return '$msg\nÇok fazla hatalı deneme: $secs saniye beklemen gerekiyor.';
    }
    final left = 5 - n;
    return left <= 2 ? '$msg ($left deneme hakkın kaldı)' : msg;
  }

  void _resetFails() {
    prefs.remove('authFails');
    prefs.remove('authLockUntil');
  }

  String _authError(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-email':
        return 'E-posta adresi geçersiz.';
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
      case 'INVALID_LOGIN_CREDENTIALS':
        return 'E-posta/kullanıcı adı ya da şifre hatalı.';
      case 'email-already-in-use':
        return 'Bu e-posta ile zaten bir hesap var. Giriş yapmayı dene.';
      case 'weak-password':
        return 'Şifre çok zayıf.';
      case 'too-many-requests':
        return 'Çok fazla deneme yapıldı. Güvenlik için biraz bekle ve tekrar dene.';
      case 'network-request-failed':
        return 'İnternet bağlantısı yok.';
      case 'user-disabled':
        return 'Bu hesap devre dışı bırakılmış.';
      case 'configuration-not-found':
      case 'internal-error':
        if (e.code == 'configuration-not-found' || (e.message ?? '').contains('CONFIGURATION_NOT_FOUND')) {
          return 'Firebase Authentication bu projede henüz açılmamış. Firebase konsolu → Authentication → '
              '"Get started", ardından Sign-in method → Email/Password → Enable.';
        }
        return e.message ?? 'Sunucu hatası, biraz sonra tekrar dene.';
      case 'operation-not-allowed':
        return 'E-posta ile giriş Firebase konsolunda kapalı. (Authentication → Sign-in method → Email/Password açılmalı.)';
      case 'requires-recent-login':
        return 'Güvenlik için çıkış yapıp tekrar giriş yapmalısın.';
      default:
        return e.message ?? 'Bir hata oluştu (${e.code}).';
    }
  }

  Future<void> _writeUsernameIndex(String username, String dataUid, String email) async {
    try {
      await db.ref('usernames/${_key(username)}').set({'uid': dataUid, 'username': username, 'email': email});
    } catch (_) {}
  }

  /// E-posta (ya da kullanıcı adı) + şifre ile giriş.
  /// Eski hesaplar için doğru şifre girilirse "hesabı güvenceye al" adımına geçer.
  Future<String?> login(String id, String password) async {
    id = id.trim();
    if (id.isEmpty || password.isEmpty) return 'E-posta/kullanıcı adı ve şifre gerekli.';
    final lock = lockSecondsLeft;
    if (lock > 0) return 'Çok fazla hatalı deneme. $lock saniye sonra tekrar dene.';
    try {
      String? email;
      if (id.contains('@')) {
        email = id;
      } else {
        final idx = asMap((await db.ref('usernames/${_key(id)}').get()).value);
        if (asStr(idx['email']).isNotEmpty) email = asStr(idx['email']);
        if (email == null) {
          final all = await _fetchUsers();
          var matches = all.entries.where((e) => asStr(e.value['username']) == id).toList();
          if (matches.isEmpty) {
            matches = all.entries.where((e) => _norm(asStr(e.value['username'])) == _norm(id)).toList();
          }
          if (matches.isEmpty) return _fail('Bu kullanıcı adıyla bir hesap bulunamadı.');
          for (final e in matches) {
            if (asStr(e.value['email']).isNotEmpty && asStr(e.value['authUid']).isNotEmpty) {
              email = asStr(e.value['email']);
              break;
            }
          }
          if (email == null) {
            // Eski (doğrulamasız) hesap
            for (final e in matches) {
              final pw = asStr(e.value['password']);
              if (pw.isNotEmpty && pw == password) {
                _resetFails();
                _legacyUid = e.key;
                _legacyName = asStr(e.value['username'], id);
                authStage = AuthStage.upgradeLegacy;
                notifyListeners();
                return null;
              }
            }
            return _fail('Şifre hatalı.');
          }
        }
      }
      final cred = await auth
          .signInWithEmailAndPassword(email: email, password: password)
          .timeout(const Duration(seconds: 25));
      _resetFails();
      final u = cred.user!;
      if (!u.emailVerified) {
        authStage = AuthStage.verifyEmail;
        notifyListeners();
        return null;
      }
      await _finishAuth(u);
      return null;
    } on FirebaseAuthException catch (e) {
      final msg = _authError(e);
      if (e.code == 'wrong-password' || e.code == 'invalid-credential' || e.code == 'user-not-found' ||
          e.code == 'INVALID_LOGIN_CREDENTIALS') {
        return _fail(msg);
      }
      return msg;
    } on TimeoutException {
      return 'Sunucuya ulaşılamadı. İnternet bağlantını kontrol et.';
    } catch (e) {
      return 'Giriş yapılamadı. Lütfen tekrar dene.\n($e)';
    }
  }

  /// Yeni hesap: Firebase Authentication + e-posta doğrulaması.
  Future<String?> register(
    String username,
    String email,
    String password, {
    String? photoDataUrl,
    String bio = '',
  }) async {
    username = username.trim();
    email = email.trim();
    final v = validateUsername(username) ?? validateEmail(email) ?? validatePassword(password);
    if (v != null) return v;
    try {
      if (await isUsernameTaken(username)) return 'Bu kullanıcı adı zaten alınmış.';
      final cred = await auth.createUserWithEmailAndPassword(email: email, password: password);
      final u = cred.user!;
      await u.updateDisplayName(username);
      await db.ref('users/${u.uid}').set({
        'username': username,
        'email': email,
        'authUid': u.uid,
        'emailVerified': false,
        'isOnline': false,
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
      await _writeUsernameIndex(username, u.uid, email);
      await u.sendEmailVerification();
      authStage = AuthStage.verifyEmail;
      notifyListeners();
      return null;
    } on FirebaseAuthException catch (e) {
      return _authError(e);
    } catch (e) {
      return 'Kayıt başarısız. Lütfen tekrar dene.\n($e)';
    }
  }

  /// Eski hesabı e-posta + yeni güçlü şifreyle güvenceye alır; açık şifre veritabanından silinir.
  Future<String?> upgradeLegacy(String email, String newPassword) async {
    final legacyUid = _legacyUid;
    final name = _legacyName;
    if (legacyUid == null || name == null) return 'Oturum süresi doldu, tekrar giriş yap.';
    email = email.trim();
    final v = validateEmail(email) ?? validatePassword(newPassword);
    if (v != null) return v;
    try {
      final cred = await auth.createUserWithEmailAndPassword(email: email, password: newPassword);
      final u = cred.user!;
      await u.updateDisplayName(name);
      await db.ref('authLinks/${u.uid}').set(legacyUid);
      await db.ref('users/$legacyUid').update({
        'email': email,
        'authUid': u.uid,
        'emailVerified': false,
        'password': null, // açık metin şifre artık tutulmuyor
      });
      await _writeUsernameIndex(name, legacyUid, email);
      await u.sendEmailVerification();
      _legacyUid = null;
      _legacyName = null;
      authStage = AuthStage.verifyEmail;
      notifyListeners();
      return null;
    } on FirebaseAuthException catch (e) {
      return _authError(e);
    } catch (e) {
      return 'Hesap güvenceye alınamadı.\n($e)';
    }
  }

  /// Doğrulama bağlantısına tıklandı mı? Tıklandıysa oturumu açar.
  Future<bool> checkVerified() async {
    final u = auth.currentUser;
    if (u == null) {
      authStage = AuthStage.signedOut;
      notifyListeners();
      return false;
    }
    try {
      await u.reload();
    } catch (_) {}
    final r = auth.currentUser;
    if (r != null && r.emailVerified) {
      await _finishAuth(r);
      return true;
    }
    return false;
  }

  Future<String?> resendVerification() async {
    try {
      await auth.currentUser?.sendEmailVerification();
      return null;
    } on FirebaseAuthException catch (e) {
      return _authError(e);
    }
  }

  Future<String?> resetPassword(String id) async {
    var email = id.trim();
    try {
      if (!email.contains('@')) {
        final idx = asMap((await db.ref('usernames/${_key(email)}').get()).value);
        email = asStr(idx['email']);
        if (email.isEmpty) {
          return 'Bu kullanıcı adına bağlı e-posta yok. Eski hesaplar önce giriş yapıp hesabı güvenceye almalı.';
        }
      }
      await auth.sendPasswordResetEmail(email: email);
      return null;
    } on FirebaseAuthException catch (e) {
      return _authError(e);
    } catch (e) {
      return 'Gönderilemedi: $e';
    }
  }

  /// Doğrulama / güvenceye alma adımından vazgeç, giriş ekranına dön.
  Future<void> cancelAuthFlow() async {
    _legacyUid = null;
    _legacyName = null;
    try {
      await auth.signOut();
    } catch (_) {}
    authStage = AuthStage.signedOut;
    notifyListeners();
  }

  /// Doğrulanmış Firebase kullanıcısıyla uygulama oturumunu açar.
  Future<void> _finishAuth(User u) async {
    var dataUid = prefs.getString('dataUid_${u.uid}') ?? u.uid;
    try {
      final link = await db.ref('authLinks/${u.uid}').get();
      final linked = asStr(link.value);
      if (linked.isNotEmpty) {
        // Bağlantıyı yalnızca profil de aynı hesabı gösteriyorsa kabul et (sahte bağlantıya karşı).
        final owner = await db.ref('users/$linked/authUid').get();
        if (asStr(owner.value) == u.uid) dataUid = linked;
      }
    } catch (_) {}
    var name = u.displayName ?? (u.email?.split('@').first ?? 'kullanici');
    try {
      final s = await db.ref('users/$dataUid').get();
      final m = asMap(s.value);
      if (m.isEmpty) {
        await db.ref('users/$dataUid').set({
          'username': name,
          'email': u.email,
          'authUid': u.uid,
          'createdAt': ServerValue.timestamp,
          'role': 'user',
        });
      } else {
        name = asStr(m['username'], name);
      }
      await db.ref('users/$dataUid').update({'emailVerified': true, 'authUid': u.uid, 'email': u.email});
      await _writeUsernameIndex(name, dataUid, u.email ?? '');
    } catch (_) {}
    authStage = AuthStage.signedOut;
    _resetFails();
    await prefs.setString('dataUid_${u.uid}', dataUid);
    await _setSession(dataUid, name);
  }

  Future<void> _setSession(String uid, String name) async {
    _uid = uid;
    _username = name;
    await prefs.setString('uid', uid);
    await prefs.setString('username', name);
    notifyListeners();
    await _startSession();
  }

  Future<void> logout() async {
    final uid = _uid;
    if (uid != null) {
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
    authStage = AuthStage.signedOut;
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

    _subs.add(db.ref('.info/connected').onValue.listen((e) {
      final c = e.snapshot.value == true;
      if (c != connected) {
        connected = c;
        notifyListeners();
      }
      if (c) _setPresence(true);
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
    }, onError: (_) {
      _usersLoaded = true;
      notifyListeners();
    }));

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
    }, onError: (_) {
      _joinedLoaded = true;
      notifyListeners();
    }));

    unawaited(NotificationService.registerToken(db, uid));
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
          if (!msg.readBy.contains(_uid) && (activeChatKey != key || !foreground)) {
            _unread[key] = (_unread[key] ?? 0) < 1 ? 1 : _unread[key]!;
          }
        } else if (prev?.id != msg.id) {
          if (activeChatKey != key || !foreground) {
            _unread[key] = (_unread[key] ?? 0) + 1;
            _notifyIncoming(key, chatId, isDm, msg);
          }
        }
      }
      notifyListeners();
    }, onError: (_) {});
  }

  void _notifyIncoming(String key, String chatId, bool isDm, ChatMessage msg) {
    if (!notificationsEnabled || _muted.contains(key)) return;
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
        last: _last[key],
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
        last: msg,
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
      final keys = ['name', 'logo', 'isPrivate', 'password', 'createdBy', 'createdAt', 'description'];
      final snaps = await Future.wait(keys.map((k) => base.child(k).get()));
      final m = <String, dynamic>{};
      for (var i = 0; i < keys.length; i++) {
        if (snaps[i].exists) m[keys[i]] = snaps[i].value;
      }
      if (m['name'] == null) {
        // Oda silinmiş.
        rooms.remove(id);
        if (joinedRoomIds.contains(id) && _uid != null) {
          await db.ref('users/$_uid/joinedRooms/$id').remove();
        }
        notifyListeners();
        return null;
      }
      final r = Room.fromMap(id, m);
      rooms[id] = r;
      notifyListeners();
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
      String tokenPart = '';
      try {
        final token = await auth.currentUser?.getIdToken();
        if (token != null) tokenPart = '&auth=$token';
      } catch (_) {}
      final res = await http
          .get(Uri.parse('${FirebaseConfig.databaseUrl}/$path.json?shallow=true$tokenPart'))
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
        'password': (password == null || password.isEmpty) ? null : password,
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
    final u = auth.currentUser;
    final email = u?.email;
    if (u == null || email == null) return 'Oturum yok, tekrar giriş yap.';
    final v = validatePassword(next);
    if (v != null) return v;
    try {
      await u.reauthenticateWithCredential(EmailAuthProvider.credential(email: email, password: current));
      await u.updatePassword(next);
      return null;
    } on FirebaseAuthException catch (e) {
      if (e.code == 'wrong-password' || e.code == 'invalid-credential') return 'Mevcut şifre hatalı.';
      return _authError(e);
    }
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
    if (old.isNotEmpty && _key(old) != _key(next)) {
      try {
        await db.ref('usernames/${_key(old)}').remove();
      } catch (_) {}
    }
    await _writeUsernameIndex(next, uid, auth.currentUser?.email ?? '');
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
