import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../core/utils.dart';
import '../models/models.dart';
import 'app_state.dart';
import 'native_bridge.dart';
import 'notification_service.dart';

enum CallPhase { idle, outgoing, incoming, active }

class CallParticipant {
  final String uid;
  final String username;
  final String status; // joined | left | declined
  final bool muted;
  const CallParticipant(this.uid, this.username, this.status, this.muted);
}

/// Web sürümüyle birebir uyumlu WebRTC sesli arama (mesh, Firebase sinyalleşmesi).
class CallService extends ChangeNotifier with WidgetsBindingObserver {
  CallService(this.app) {
    WidgetsBinding.instance.addObserver(this);
    _nativeSub = NativeBridge.actions.stream.listen(_onNativeAction);
  }

  StreamSubscription? _nativeSub;

  /// Yerel bildirimden gelen olaylar (Cevapla, tam ekran arama, Reddet, Aramayı bitir).
  Future<void> _onNativeAction(Map<String, String?> a) async {
    final action = a['action'];
    final id = a['callId'] ?? callId;
    switch (action) {
      case 'answer':
        if (id != null) await handleNotificationAction(id, 'answer');
        break;
      case 'show_call':
        if (id != null) await handleNotificationAction(id, null);
        break;
      case 'declined':
        // Yerel taraf veritabanına "reddedildi" yazdı; burada sadece ekranı kapat.
        if (phase == CallPhase.incoming && (id == null || id == callId)) {
          _answered = true;
          _logCall(missed: true, declined: true);
          _reset();
        }
        break;
      case 'hangup':
        if (phase != CallPhase.idle) await leave();
        break;
    }
  }

  final AppState app;
  FirebaseDatabase get db => app.db;

  /// Arama ekranını göstermek için (main.dart bağlar).
  VoidCallback? onPresent;

  CallPhase phase = CallPhase.idle;
  String? callId;
  String callType = 'dm';
  String? targetId;
  String title = '';
  bool isCaller = false;
  int _myJoinedAt = 0;
  DateTime? connectedAt;
  bool muted = false;
  bool speaker = false;
  Map<String, CallParticipant> participants = {};
  String statusText = '';

  MediaStream? _local;
  final Map<String, RTCPeerConnection> _pcs = {};
  final Map<String, List<StreamSubscription>> _peerSubs = {};
  final Map<String, RTCPeerConnectionState> peerStates = {};
  StreamSubscription? _inviteSub;
  StreamSubscription? _partSub;
  StreamSubscription? _statusSub;
  StreamSubscription? _myInviteSub;
  Timer? _ringTimeout;
  Timer? _ticker;
  final AudioPlayer _tone = AudioPlayer();
  String? _listeningUid;
  bool _foreground = true;
  bool _answered = false;

  static const Map<String, dynamic> _ice = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {'urls': 'stun:stun2.l.google.com:19302'},
      {
        'urls': 'turn:openrelay.metered.ca:80',
        'username': 'openrelayproject',
        'credential': 'openrelayproject',
      },
      {
        'urls': 'turn:openrelay.metered.ca:443',
        'username': 'openrelayproject',
        'credential': 'openrelayproject',
      },
      {
        'urls': 'turn:openrelay.metered.ca:443?transport=tcp',
        'username': 'openrelayproject',
        'credential': 'openrelayproject',
      },
    ],
    'sdpSemantics': 'unified-plan',
  };

  String? get _me => app.uid;

  Duration get elapsed =>
      connectedAt == null ? Duration.zero : DateTime.now().difference(connectedAt!);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground && phase == CallPhase.incoming) {
      // Uygulamaya dönüldü: yerel zil bildirimini kapat, uygulama içi arama ekranı + zil.
      NativeBridge.cancelCallNotification();
      _playLoop('ringtone.wav');
      onPresent?.call();
    }
  }

  // ------------------------------------------------------------------
  // Gelen arama dinleme
  // ------------------------------------------------------------------
  void syncListening() {
    final uid = _me;
    if (uid == _listeningUid) return;
    _inviteSub?.cancel();
    _inviteSub = null;
    _listeningUid = uid;
    if (uid == null) return;
    _inviteSub = db.ref('callInvites/$uid').onChildAdded.listen(_onInvite, onError: (_) {});
  }

  Future<void> _onInvite(DatabaseEvent e) =>
      _handleInvite(e.snapshot.key, asMap(e.snapshot.value));

  Future<void> _handleInvite(String? id, Map<String, dynamic> inv) async {
    final uid = _me;
    if (uid == null || id == null || inv.isEmpty) return;
    if (id == callId) return;
    final st = await db.ref('calls/$id/status').get();
    final status = asStr(st.value);
    if (status != 'ringing' && status != 'active') {
      await db.ref('callInvites/$uid/$id').remove();
      return;
    }
    if (phase != CallPhase.idle) return; // meşgul: davet kalır, karşı taraf zaman aşımına düşer

    callId = id;
    callType = asStr(inv['type'], 'dm');
    targetId = asStrOrNull(inv['targetId']);
    title = callType == 'room'
        ? asStr(inv['title'], 'Oda')
        : asStr(inv['callerName'], 'Qyriptalk');
    isCaller = false;
    _answered = false;
    phase = CallPhase.incoming;
    statusText = callType == 'room'
        ? '${asStr(inv['callerName'])} grup araması başlattı'
        : 'Sesli arama';
    notifyListeners();

    _myInviteSub = db.ref('callInvites/$uid/$id').onValue.listen((ev) {
      if (ev.snapshot.value == null && phase == CallPhase.incoming && !_answered) {
        _logCall(missed: true);
        _reset();
      }
    });

    if (_foreground) {
      _playLoop('ringtone.wav');
    }
    // Arka planda / ekran kapalıyken zil sesli tam ekran arama bildirimini yerel servis gösterir.
    onPresent?.call();
  }

  // ------------------------------------------------------------------
  // Arama başlat
  // ------------------------------------------------------------------
  Future<String?> startCall({
    required bool isDm,
    required String chatId,
    required String chatTitle,
  }) async {
    final uid = _me;
    if (uid == null) return 'Oturum yok.';
    if (phase != CallPhase.idle) return 'Zaten devam eden bir arama var.';

    List<String> targets;
    if (isDm) {
      final other = otherUidFromDm(chatId, uid);
      if (other.isEmpty) return 'Kullanıcı bulunamadı.';
      targets = [other];
    } else {
      final s = await db.ref('rooms/$chatId/users').get();
      targets = asMap(s.value).keys.where((k) => k != uid).toList();
      if (targets.isEmpty) return 'Odada aranacak başka kimse yok.';
    }

    try {
      await _getLocal();
    } catch (_) {
      return 'Mikrofona erişilemedi. Lütfen izin ver.';
    }

    final ref = db.ref('calls').push();
    callId = ref.key;
    callType = isDm ? 'dm' : 'room';
    targetId = chatId;
    title = chatTitle;
    isCaller = true;
    _myJoinedAt = DateTime.now().millisecondsSinceEpoch;

    try {
      await ref.set({
        'type': callType,
        'targetId': chatId,
        'callerId': uid,
        'callerName': app.username,
        'title': chatTitle,
        'status': 'ringing',
        'createdAt': ServerValue.timestamp,
      });
      await ref.child('participants/$uid').set({
        'username': app.username,
        'joinedAt': _myJoinedAt,
        'status': 'joined',
      });
      await Future.wait(targets.map((t) => db.ref('callInvites/$t/${ref.key}').set({
            'type': callType,
            'targetId': chatId,
            'callerId': uid,
            'callerName': app.username,
            'title': chatTitle,
            'createdAt': ServerValue.timestamp,
          })));
    } catch (e) {
      await _disposeMedia();
      _reset();
      return 'Arama başlatılamadı: $e';
    }

    phase = CallPhase.outgoing;
    statusText = targets.length > 1 ? '${targets.length} kişi aranıyor…' : 'Çalıyor…';
    notifyListeners();
    _watchCall(ref.key!);
    _playLoop('dialtone.wav');
    _ringTimeout = Timer(Duration(seconds: isDm ? 45 : 60), () async {
      final joined = participants.values.where((p) => p.status == 'joined').length;
      if (joined <= 1) {
        statusText = 'Yanıt yok';
        notifyListeners();
        await leave();
      }
    });
    onPresent?.call();
    return null;
  }

  // ------------------------------------------------------------------
  // Cevapla / reddet
  // ------------------------------------------------------------------
  Future<String?> accept() async {
    final uid = _me;
    final id = callId;
    if (uid == null || id == null || phase != CallPhase.incoming) return null;
    _answered = true;
    await _stopTone();
    await NotificationService.cancelCall(id);
    await NativeBridge.cancelCallNotification();
    try {
      await _getLocal();
    } catch (_) {
      await db.ref('callInvites/$uid/$id').remove();
      _reset();
      return 'Mikrofona erişilemedi.';
    }
    _myJoinedAt = DateTime.now().millisecondsSinceEpoch;
    try {
      await db.ref('calls/$id/participants/$uid').set({
        'username': app.username,
        'joinedAt': _myJoinedAt,
        'status': 'joined',
      });
      await db.ref('calls/$id/status').set('active');
    } catch (e) {
      await _disposeMedia();
      _reset();
      return 'Görüşmeye katılınamadı.';
    }
    await _myInviteSub?.cancel();
    _myInviteSub = null;
    await db.ref('callInvites/$uid/$id').remove();
    phase = CallPhase.active;
    statusText = 'Bağlanıyor…';
    notifyListeners();
    _watchCall(id);
    return null;
  }

  Future<void> decline() async {
    final uid = _me;
    final id = callId;
    if (uid == null || id == null) return;
    _answered = true;
    await NotificationService.cancelCall(id);
    await NativeBridge.cancelCallNotification();
    await db.ref('callInvites/$uid/$id').remove();
    await db.ref('calls/$id/participants/$uid').set({
      'username': app.username,
      'status': 'declined',
    });
    _logCall(missed: true, declined: true);
    _reset();
  }

  /// Bildirimdeki Cevapla/Reddet düğmesinden gelir.
  Future<void> handleNotificationAction(String callIdFromPayload, String? action) async {
    if (callId != callIdFromPayload) {
      // Uygulama yeni açıldıysa daveti henüz işlememiş olabiliriz.
      final uid = _me;
      if (uid == null) return;
      final s = await db.ref('callInvites/$uid/$callIdFromPayload').get();
      if (!s.exists) return;
      await _handleInvite(s.key, asMap(s.value));
    }
    if (action == 'answer') {
      await accept();
    } else if (action == 'decline') {
      await decline();
    } else {
      onPresent?.call();
    }
  }

  // ------------------------------------------------------------------
  // Görüşme izleme + mesh bağlantıları
  // ------------------------------------------------------------------
  void _watchCall(String id) {
    _partSub?.cancel();
    _statusSub?.cancel();
    _partSub = db.ref('calls/$id/participants').onValue.listen((e) {
      final m = asMap(e.snapshot.value);
      participants = m.map((k, v) {
        final p = asMap(v);
        return MapEntry(
            k,
            CallParticipant(k, asStr(p['username'], 'Kullanıcı'),
                asStr(p['status']), asBool(p['muted'])));
      });
      final joined =
          participants.values.where((p) => p.status == 'joined').map((p) => p.uid).toList();

      if (joined.length > 1) {
        if (phase != CallPhase.active || connectedAt == null) {
          phase = CallPhase.active;
          connectedAt ??= DateTime.now();
          _ringTimeout?.cancel();
          _stopTone();
          _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());
          NativeBridge.setInCall(true);
        }
        statusText = '';
      }

      // DM: karşı taraf reddettiyse aramayı bitir
      if (isCaller && callType == 'dm' && joined.length <= 1) {
        final others = participants.values.where((p) => p.uid != _me);
        if (others.isNotEmpty && others.every((p) => p.status == 'declined')) {
          statusText = 'Arama reddedildi';
          notifyListeners();
          leave();
          return;
        }
      }
      // Görüşme sürerken herkes ayrıldıysa bitir
      if (phase == CallPhase.active && connectedAt != null && joined.length <= 1) {
        leave();
        return;
      }

      final me = _me;
      for (final uid in joined) {
        if (uid == me || _pcs.containsKey(uid)) continue;
        final raw = asMap(m[uid]);
        final otherJoinedAt = asInt(raw['joinedAt']);
        final iAmOfferer = otherJoinedAt < _myJoinedAt;
        _createPeer(uid, iAmOfferer, id);
      }
      for (final uid in _pcs.keys.toList()) {
        if (!joined.contains(uid)) _cleanupPeer(uid);
      }
      notifyListeners();
    });

    _statusSub = db.ref('calls/$id/status').onValue.listen((e) {
      final s = e.snapshot.value;
      if (s == 'ended' || (s == null && phase != CallPhase.idle && connectedAt != null)) {
        _finish(remote: true);
      }
    });
  }

  Future<void> _createPeer(String remoteUid, bool isOfferer, String id) async {
    final me = _me;
    final local = _local;
    if (me == null || local == null) return;
    final pc = await createPeerConnection(_ice);
    _pcs[remoteUid] = pc;
    final subs = <StreamSubscription>[];
    _peerSubs[remoteUid] = subs;

    for (final t in local.getAudioTracks()) {
      await pc.addTrack(t, local);
    }

    final pairKey = isOfferer ? '${me}_$remoteUid' : '${remoteUid}_$me';
    final pairRef = db.ref('calls/$id/peers/$pairKey');
    final pending = <RTCIceCandidate>[];
    var remoteSet = false;
    var handlingRemote = false;

    Future<void> flush() async {
      while (pending.isNotEmpty) {
        final c = pending.removeAt(0);
        try {
          await pc.addCandidate(c);
        } catch (_) {}
      }
    }

    pc.onIceCandidate = (RTCIceCandidate c) {
      if (c.candidate == null) return;
      pairRef.child('candidates/$me').push().set(c.toMap());
    };

    pc.onConnectionState = (RTCPeerConnectionState s) {
      peerStates[remoteUid] = s;
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        statusText = '';
      } else if (s == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        statusText = 'Bağlantı zayıf, yeniden bağlanılıyor…';
      } else if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        statusText = 'Bağlantı koptu';
        Timer(const Duration(seconds: 8), () {
          if (peerStates[remoteUid] == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
            _cleanupPeer(remoteUid);
          }
        });
      }
      notifyListeners();
    };

    subs.add(pairRef.child('candidates/$remoteUid').onChildAdded.listen((e) async {
      final m = asMap(e.snapshot.value);
      if (m.isEmpty) return;
      final c = RTCIceCandidate(
        asStrOrNull(m['candidate']),
        asStrOrNull(m['sdpMid']),
        m['sdpMLineIndex'] == null ? null : asInt(m['sdpMLineIndex']),
      );
      if (remoteSet) {
        try {
          await pc.addCandidate(c);
        } catch (_) {}
      } else {
        pending.add(c);
      }
    }));

    if (isOfferer) {
      final offer = await pc.createOffer({'offerToReceiveAudio': true});
      await pc.setLocalDescription(offer);
      await pairRef.child('offer').set({'sdp': offer.sdp, 'type': offer.type});
      subs.add(pairRef.child('answer').onValue.listen((e) async {
        final a = asMap(e.snapshot.value);
        if (a.isEmpty || remoteSet || handlingRemote) return;
        handlingRemote = true;
        try {
          await pc.setRemoteDescription(
              RTCSessionDescription(asStr(a['sdp']), asStr(a['type'], 'answer')));
          remoteSet = true;
          await flush();
        } catch (_) {
          handlingRemote = false;
        }
      }));
    } else {
      subs.add(pairRef.child('offer').onValue.listen((e) async {
        final o = asMap(e.snapshot.value);
        if (o.isEmpty || remoteSet || handlingRemote) return;
        handlingRemote = true;
        try {
          await pc.setRemoteDescription(
              RTCSessionDescription(asStr(o['sdp']), asStr(o['type'], 'offer')));
          remoteSet = true;
          await flush();
          final answer = await pc.createAnswer({});
          await pc.setLocalDescription(answer);
          await pairRef.child('answer').set({'sdp': answer.sdp, 'type': answer.type});
        } catch (_) {
          handlingRemote = false;
        }
      }));
    }
    await Helper.setSpeakerphoneOn(speaker);
  }

  void _cleanupPeer(String uid) {
    for (final s in _peerSubs.remove(uid) ?? const <StreamSubscription>[]) {
      s.cancel();
    }
    final pc = _pcs.remove(uid);
    peerStates.remove(uid);
    if (pc != null) {
      pc.close();
      pc.dispose();
    }
  }

  // ------------------------------------------------------------------
  // Kontroller
  // ------------------------------------------------------------------
  Future<void> toggleMute() async {
    muted = !muted;
    for (final t in _local?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = !muted;
    }
    final id = callId;
    final uid = _me;
    if (id != null && uid != null) {
      db.ref('calls/$id/participants/$uid/muted').set(muted).catchError((_) {});
    }
    notifyListeners();
  }

  Future<void> toggleSpeaker() async {
    speaker = !speaker;
    try {
      await Helper.setSpeakerphoneOn(speaker);
    } catch (_) {}
    notifyListeners();
  }

  /// Görüşmeden ayrıl (arayan vazgeçerse daveti de geri çeker).
  Future<void> leave() async {
    final id = callId;
    final uid = _me;
    if (id == null || uid == null) {
      _reset();
      return;
    }
    try {
      final s = await db.ref('calls/$id/participants').get();
      final m = asMap(s.value);
      final stillJoined = m.entries
          .where((e) => e.key != uid && asStr(asMap(e.value)['status']) == 'joined')
          .length;
      await db.ref('calls/$id/participants/$uid').set({
        'username': app.username,
        'status': 'left',
      });
      if (stillJoined == 0) {
        await db.ref('calls/$id/status').set('ended');
        // Bekleyen davetleri temizle
        final callSnap = await db.ref('calls/$id').get();
        final call = asMap(callSnap.value);
        final targetsSnap = call['type'] == 'room'
            ? await db.ref('rooms/${asStr(call['targetId'])}/users').get()
            : null;
        final targets = <String>{};
        if (targetsSnap != null) targets.addAll(asMap(targetsSnap.value).keys);
        if (call['type'] == 'dm') {
          final o = otherUidFromDm(asStr(call['targetId']), uid);
          if (o.isNotEmpty) targets.add(o);
        }
        for (final t in targets) {
          db.ref('callInvites/$t/$id').remove();
        }
        Timer(const Duration(seconds: 3), () => db.ref('calls/$id').remove());
      }
    } catch (_) {}
    await _finish(remote: false);
  }

  Future<void> _finish({required bool remote}) async {
    if (phase == CallPhase.idle && callId == null) return;
    final wasConnected = connectedAt != null;
    if (phase == CallPhase.incoming && !_answered) {
      _logCall(missed: true);
    } else {
      _logCall(missed: !wasConnected && !isCaller);
    }
    await _stopTone();
    if (wasConnected || isCaller) _playOnce('callend.wav');
    final id = callId;
    if (id != null) NotificationService.cancelCall(id);
    await _disposeMedia();
    _reset();
    db.goOnline();
  }

  void _logCall({required bool missed, bool declined = false}) {
    final id = callId;
    if (id == null) return;
    app.addCallLog(CallLogEntry(
      id: id,
      title: title,
      outgoing: isCaller,
      missed: missed && !isCaller,
      isGroup: callType == 'room',
      ts: DateTime.now().millisecondsSinceEpoch,
      durationSec: elapsed.inSeconds,
      targetChatId: targetId,
      targetIsDm: callType == 'dm',
    ));
  }

  Future<void> _getLocal() async {
    if (_local != null) return;
    _local = await navigator.mediaDevices.getUserMedia({
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      },
      'video': false,
    });
  }

  Future<void> _disposeMedia() async {
    for (final uid in _pcs.keys.toList()) {
      _cleanupPeer(uid);
    }
    final l = _local;
    _local = null;
    if (l != null) {
      for (final t in l.getTracks()) {
        try {
          await t.stop();
        } catch (_) {}
      }
      try {
        await l.dispose();
      } catch (_) {}
    }
  }

  void _reset() {
    if (connectedAt != null) NativeBridge.setInCall(false);
    if (phase == CallPhase.incoming) NativeBridge.cancelCallNotification();
    _ringTimeout?.cancel();
    _ringTimeout = null;
    _ticker?.cancel();
    _ticker = null;
    _partSub?.cancel();
    _partSub = null;
    _statusSub?.cancel();
    _statusSub = null;
    _myInviteSub?.cancel();
    _myInviteSub = null;
    _stopTone();
    phase = CallPhase.idle;
    callId = null;
    targetId = null;
    isCaller = false;
    connectedAt = null;
    muted = false;
    speaker = false;
    participants = {};
    peerStates.clear();
    _answered = false;
    notifyListeners();
  }

  Future<void> _playLoop(String asset) async {
    try {
      await _tone.stop();
      await _tone.setReleaseMode(ReleaseMode.loop);
      await _tone.play(AssetSource(asset), volume: 0.8);
    } catch (_) {}
  }

  Future<void> _playOnce(String asset) async {
    try {
      final p = AudioPlayer();
      await p.play(AssetSource(asset), volume: 0.7);
      p.onPlayerComplete.first.then((_) => p.dispose());
    } catch (_) {}
  }

  Future<void> _stopTone() async {
    try {
      await _tone.stop();
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _nativeSub?.cancel();
    _inviteSub?.cancel();
    _reset();
    _tone.dispose();
    super.dispose();
  }
}
