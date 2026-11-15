import 'dart:async';
import 'dart:convert';

import 'package:firebase_database/firebase_database.dart';
import 'package:http/http.dart' as http;

import '../core/utils.dart';
import '../models/models.dart';

/// Tek bir sohbetin (oda ya da özel mesaj) veritabanı işlemleri.
class ChatRef {
  final FirebaseDatabase db;
  final bool isDm;
  final String id;
  final String myUid;
  final String myName;

  ChatRef({
    required this.db,
    required this.isDm,
    required this.id,
    required this.myUid,
    required this.myName,
  });

  String get key => isDm ? 'dm:$id' : 'room:$id';
  String get basePath => isDm ? 'privateMessages/$id' : 'rooms/$id';
  DatabaseReference get base => db.ref(basePath);
  DatabaseReference get messages => db.ref('$basePath/messages');

  static const int maxMediaBytes = 7 * 1024 * 1024;

  Map<String, Object?> _envelope({ReplyRef? reply}) => {
        'sender': myName,
        'senderUid': myUid,
        'timestamp': ServerValue.timestamp,
        if (reply != null) 'replyTo': reply.toMap(),
      };

  Future<void> sendText(String text, {ReplyRef? reply}) async {
    final ref = messages.push();
    await ref.set({..._envelope(reply: reply), 'text': text});
    await setTyping(false);
  }

  Future<void> sendMedia({
    required String type, // image | video | voice | file
    required String dataUrl,
    required String fileName,
    required int fileSize,
    required String fileType,
    String caption = '',
    int duration = 0,
    ReplyRef? reply,
  }) async {
    final ref = messages.push();
    await ref.set({
      ..._envelope(reply: reply),
      'type': type,
      'fileName': fileName,
      'fileSize': fileSize,
      'fileType': fileType,
      'fileData': dataUrl,
      if (type == 'image') 'imageData': dataUrl,
      if (caption.isNotEmpty) 'caption': caption,
      if (type == 'voice') 'duration': duration,
    });
  }

  Future<void> edit(String msgId, String text) => messages.child(msgId).update({
        'text': text,
        'edited': true,
        'editedAt': ServerValue.timestamp,
      });

  Future<void> delete(String msgId) => messages.child(msgId).remove();

  Future<void> react(String msgId, String? emoji) {
    final r = messages.child('$msgId/reactions/$myUid');
    return emoji == null ? r.remove() : r.set(emoji);
  }

  Future<void> markRead(String msgId) =>
      messages.child('$msgId/readBy/$myUid').set(true);

  Future<void> pin(ChatMessage m) => base.child('pinnedMessage').set({
        'id': m.id,
        'sender': m.sender,
        'previewText': m.previewText,
        'pinnedBy': myName,
        'pinnedAt': ServerValue.timestamp,
      });

  Future<void> unpin() => base.child('pinnedMessage').remove();

  Timer? _typingOff;
  bool _typing = false;

  Future<void> setTyping(bool on) async {
    final r = base.child('typing/$myUid');
    _typingOff?.cancel();
    if (on) {
      _typingOff = Timer(const Duration(seconds: 4), () => setTyping(false));
      if (_typing) return;
      _typing = true;
      await r.set({'username': myName, 'ts': ServerValue.timestamp});
      r.onDisconnect().remove();
    } else {
      if (!_typing) return;
      _typing = false;
      await r.remove();
    }
  }

  static Future<void> forward({
    required FirebaseDatabase db,
    required ChatMessage msg,
    required bool toDm,
    required String toId,
    required String myUid,
    required String myName,
  }) async {
    final path = toDm ? 'privateMessages/$toId/messages' : 'rooms/$toId/messages';
    await db.ref(path).push().set({
      ...msg.contentFields(),
      'sender': myName,
      'senderUid': myUid,
      'timestamp': ServerValue.timestamp,
      'forwarded': true,
    });
  }
}

/// MyMemory ücretsiz çeviri servisi (web sürümüyle aynı).
class Translator {
  static final Map<String, String> _cache = {};

  static bool looksTurkish(String s) =>
      RegExp(r'[çğıöşüÇĞİÖŞÜ]').hasMatch(s) ||
      RegExp(r'\b(ve|bir|bu|ne|için|değil|evet|hayır|nasılsın|merhaba)\b',
              caseSensitive: false)
          .hasMatch(s);

  static Future<String?> translate(String text, {String? target}) async {
    final t = text.trim();
    if (t.isEmpty) return null;
    final to = target ?? (looksTurkish(t) ? 'en' : 'tr');
    final from = to == 'tr' ? 'en' : 'tr';
    final k = '$from|$to|$t';
    final hit = _cache[k];
    if (hit != null) return hit;
    try {
      final uri = Uri.parse('https://api.mymemory.translated.net/get').replace(
        queryParameters: {'q': t, 'langpair': '$from|$to'},
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return null;
      final j = asMap(jsonDecode(res.body));
      final out = asStr(asMap(j['responseData'])['translatedText']);
      if (out.isEmpty) return null;
      _cache[k] = out;
      return out;
    } catch (_) {
      return null;
    }
  }
}
