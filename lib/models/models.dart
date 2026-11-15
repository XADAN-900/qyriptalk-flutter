import '../core/utils.dart';

class AppUser {
  final String uid;
  final String username;
  final String? photo;
  final String bio;
  final bool isOnline;
  final int lastSeen;
  final String role;
  final int createdAt;

  const AppUser({
    required this.uid,
    required this.username,
    this.photo,
    this.bio = '',
    this.isOnline = false,
    this.lastSeen = 0,
    this.role = 'user',
    this.createdAt = 0,
  });

  factory AppUser.fromMap(String uid, Map<String, dynamic> m) => AppUser(
        uid: uid,
        username: asStr(m['username'], 'Kullanıcı'),
        photo: asStrOrNull(m['profilePhoto']),
        bio: asStr(m['bio']),
        isOnline: asBool(m['isOnline']),
        lastSeen: asInt(m['lastSeen']),
        role: asStr(m['role'], 'user'),
        createdAt: asInt(m['createdAt']),
      );

  String get statusText => isOnline ? 'çevrimiçi' : formatLastSeen(lastSeen);
  bool get isAdmin => role == 'admin';
  bool get isModerator => role == 'moderator' || role == 'admin';
}

class Room {
  final String id;
  final String name;
  final String? logo;
  final bool isPrivate;
  final String? password;
  final String createdBy;
  final int createdAt;
  final String description;

  const Room({
    required this.id,
    required this.name,
    this.logo,
    this.isPrivate = false,
    this.password,
    this.createdBy = '',
    this.createdAt = 0,
    this.description = '',
  });

  bool get hasPassword => password != null && password!.isNotEmpty;

  factory Room.fromMap(String id, Map<String, dynamic> m) => Room(
        id: id,
        name: asStr(m['name'], 'Oda'),
        logo: asStrOrNull(m['logo']),
        isPrivate: asBool(m['isPrivate']),
        password: asStrOrNull(m['password']),
        createdBy: asStr(m['createdBy']),
        createdAt: asInt(m['createdAt']),
        description: asStr(m['description']),
      );

  String get inviteLink =>
      'Qyriptalk/${name.replaceAll(RegExp(r'\s+'), '')}/$id';
}

class ReplyRef {
  final String id;
  final String sender;
  final String previewText;
  const ReplyRef(this.id, this.sender, this.previewText);

  Map<String, dynamic> toMap() =>
      {'id': id, 'sender': sender, 'previewText': previewText};

  static ReplyRef? fromAny(Object? v) {
    final m = asMap(v);
    if (m.isEmpty || m['id'] == null) return null;
    return ReplyRef(asStr(m['id']), asStr(m['sender']), asStr(m['previewText']));
  }
}

class ChatMessage {
  final String id;
  final String sender;
  final String senderUid;
  final String text;
  final String type; // text | image | video | voice | file | system
  final String? fileName;
  final int fileSize;
  final String? fileType;
  final String? fileData;
  final String caption;
  final int duration;
  final int timestamp;
  final Set<String> readBy;
  final ReplyRef? replyTo;
  final bool edited;
  final bool forwarded;
  final Map<String, String> reactions;
  final Map<String, dynamic> raw;

  const ChatMessage({
    required this.id,
    required this.sender,
    required this.senderUid,
    required this.text,
    required this.type,
    this.fileName,
    this.fileSize = 0,
    this.fileType,
    this.fileData,
    this.caption = '',
    this.duration = 0,
    this.timestamp = 0,
    this.readBy = const {},
    this.replyTo,
    this.edited = false,
    this.forwarded = false,
    this.reactions = const {},
    this.raw = const {},
  });

  factory ChatMessage.fromMap(String id, Map<String, dynamic> m) {
    final rb = asMap(m['readBy']);
    final re = asMap(m['reactions']);
    final type = asStr(m['type'], 'text');
    return ChatMessage(
      id: id,
      sender: asStr(m['sender'], 'Kullanıcı'),
      senderUid: asStr(m['senderUid']),
      text: asStr(m['text']),
      type: type.isEmpty ? 'text' : type,
      fileName: asStrOrNull(m['fileName']),
      fileSize: asInt(m['fileSize']),
      fileType: asStrOrNull(m['fileType']),
      fileData: asStrOrNull(m['fileData']) ?? asStrOrNull(m['imageData']),
      caption: asStr(m['caption']),
      duration: asInt(m['duration']),
      timestamp: asInt(m['timestamp']),
      readBy: rb.entries
          .where((e) => asBool(e.value))
          .map((e) => e.key)
          .toSet(),
      replyTo: ReplyRef.fromAny(m['replyTo']),
      edited: asBool(m['edited']),
      forwarded: asBool(m['forwarded']),
      reactions: re.map((k, v) => MapEntry(k, asStr(v))),
      raw: m,
    );
  }

  bool get isMedia => type != 'text';

  String get previewText {
    switch (type) {
      case 'image':
        return caption.isNotEmpty ? '📷 $caption' : '📷 Fotoğraf';
      case 'video':
        return caption.isNotEmpty ? '🎬 $caption' : '🎬 Video';
      case 'voice':
        return '🎤 Sesli mesaj (${formatDuration(duration)})';
      case 'file':
        return '📎 ${fileName ?? 'Dosya'}';
      default:
        return text.isEmpty ? 'Mesaj' : text;
    }
  }

  /// İletme için kopyalanabilir içerik alanları.
  Map<String, dynamic> contentFields() {
    final out = <String, dynamic>{};
    for (final k in const [
      'type',
      'text',
      'fileName',
      'fileSize',
      'fileType',
      'fileData',
      'imageData',
      'caption',
      'duration',
    ]) {
      if (raw[k] != null) out[k] = raw[k];
    }
    return out;
  }
}

/// Sohbet listesindeki tek satır (oda ya da özel sohbet).
class ChatSummary {
  final String id; // roomId ya da dmId
  final bool isDm;
  final String title;
  final String? photo;
  final String? otherUid;
  final ChatMessage? last;
  final int unread;
  final bool online;
  final bool muted;
  final bool pinned;

  const ChatSummary({
    required this.id,
    required this.isDm,
    required this.title,
    this.photo,
    this.otherUid,
    this.last,
    this.unread = 0,
    this.online = false,
    this.muted = false,
    this.pinned = false,
  });

  String get key => isDm ? 'dm:$id' : 'room:$id';
  int get sortTs => last?.timestamp ?? 0;
}

class CallLogEntry {
  final String id;
  final String title;
  final bool outgoing;
  final bool missed;
  final bool isGroup;
  final int ts;
  final int durationSec;
  final String? targetChatId;
  final bool targetIsDm;

  const CallLogEntry({
    required this.id,
    required this.title,
    required this.outgoing,
    required this.missed,
    required this.isGroup,
    required this.ts,
    this.durationSec = 0,
    this.targetChatId,
    this.targetIsDm = true,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'outgoing': outgoing,
        'missed': missed,
        'isGroup': isGroup,
        'ts': ts,
        'durationSec': durationSec,
        'targetChatId': targetChatId,
        'targetIsDm': targetIsDm,
      };

  factory CallLogEntry.fromJson(Map<String, dynamic> m) => CallLogEntry(
        id: asStr(m['id']),
        title: asStr(m['title']),
        outgoing: asBool(m['outgoing']),
        missed: asBool(m['missed']),
        isGroup: asBool(m['isGroup']),
        ts: asInt(m['ts']),
        durationSec: asInt(m['durationSec']),
        targetChatId: asStrOrNull(m['targetChatId']),
        targetIsDm: m['targetIsDm'] != false,
      );
}
