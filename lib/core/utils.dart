import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

/// Firebase'den gelen dinamik değeri güvenle `Map<String, dynamic>`e çevirir.
Map<String, dynamic> asMap(Object? v) {
  if (v is Map) {
    return v.map((k, val) => MapEntry(k.toString(), val));
  }
  if (v is List) {
    final m = <String, dynamic>{};
    for (var i = 0; i < v.length; i++) {
      if (v[i] != null) m['$i'] = v[i];
    }
    return m;
  }
  return <String, dynamic>{};
}

String asStr(Object? v, [String fallback = '']) {
  if (v == null) return fallback;
  return v.toString();
}

String? asStrOrNull(Object? v) {
  if (v == null) return null;
  final s = v.toString();
  return s.isEmpty ? null : s;
}

int asInt(Object? v, [int fallback = 0]) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}

bool asBool(Object? v) => v == true || v == 'true' || v == 1;

/// İki kullanıcı arasındaki özel sohbet kimliği (web sürümü ile aynı).
String dmIdFor(String a, String b) {
  final l = [a, b]..sort();
  return l.join('_');
}

String otherUidFromDm(String dmId, String myUid) {
  if (dmId.startsWith('${myUid}_')) return dmId.substring(myUid.length + 1);
  if (dmId.endsWith('_$myUid')) {
    return dmId.substring(0, dmId.length - myUid.length - 1);
  }
  return '';
}

String formatClock(int ts) {
  if (ts <= 0) return '';
  return DateFormat('HH:mm').format(DateTime.fromMillisecondsSinceEpoch(ts));
}

bool isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

String formatChatListTime(int ts) {
  if (ts <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(ts);
  final now = DateTime.now();
  if (isSameDay(d, now)) return DateFormat('HH:mm').format(d);
  if (isSameDay(d, now.subtract(const Duration(days: 1)))) return 'Dün';
  if (now.difference(d).inDays < 7) return DateFormat('EEEE', 'tr_TR').format(d);
  return DateFormat('dd.MM.yy').format(d);
}

String formatDayHeader(int ts) {
  final d = DateTime.fromMillisecondsSinceEpoch(ts);
  final now = DateTime.now();
  if (isSameDay(d, now)) return 'Bugün';
  if (isSameDay(d, now.subtract(const Duration(days: 1)))) return 'Dün';
  if (d.year == now.year) return DateFormat('d MMMM EEEE', 'tr_TR').format(d);
  return DateFormat('d MMMM y', 'tr_TR').format(d);
}

String formatLastSeen(int ts) {
  if (ts <= 0) return 'çevrimdışı';
  final d = DateTime.fromMillisecondsSinceEpoch(ts);
  final now = DateTime.now();
  final diff = now.difference(d);
  if (diff.inMinutes < 1) return 'az önce görüldü';
  if (diff.inMinutes < 60) return '${diff.inMinutes} dk önce görüldü';
  if (isSameDay(d, now)) return 'bugün ${DateFormat('HH:mm').format(d)} görüldü';
  if (isSameDay(d, now.subtract(const Duration(days: 1)))) {
    return 'dün ${DateFormat('HH:mm').format(d)} görüldü';
  }
  return '${DateFormat('dd.MM.yyyy HH:mm').format(d)} görüldü';
}

String formatDuration(int seconds) {
  final m = seconds ~/ 60;
  final s = seconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

String formatFileSize(int bytes) {
  if (bytes <= 0) return '0 B';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

const Map<String, String> _mimeByExt = {
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'heic': 'image/heic',
  'mp4': 'video/mp4',
  'mov': 'video/quicktime',
  'webm': 'video/webm',
  '3gp': 'video/3gpp',
  'mkv': 'video/x-matroska',
  'm4a': 'audio/mp4',
  'aac': 'audio/aac',
  'mp3': 'audio/mpeg',
  'ogg': 'audio/ogg',
  'opus': 'audio/ogg',
  'wav': 'audio/wav',
  'pdf': 'application/pdf',
  'txt': 'text/plain',
  'zip': 'application/zip',
  'rar': 'application/vnd.rar',
  'doc': 'application/msword',
  'docx':
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'xls': 'application/vnd.ms-excel',
  'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'ppt': 'application/vnd.ms-powerpoint',
  'pptx':
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'apk': 'application/vnd.android.package-archive',
};

String mimeFromName(String name) {
  final i = name.lastIndexOf('.');
  if (i < 0) return 'application/octet-stream';
  return _mimeByExt[name.substring(i + 1).toLowerCase()] ??
      'application/octet-stream';
}

String extFromMime(String mime) {
  for (final e in _mimeByExt.entries) {
    if (e.value == mime) return e.key;
  }
  if (mime.contains('webm')) return 'webm';
  if (mime.contains('ogg')) return 'ogg';
  if (mime.startsWith('image/')) return 'jpg';
  if (mime.startsWith('video/')) return 'mp4';
  if (mime.startsWith('audio/')) return 'm4a';
  return 'bin';
}

String toDataUrl(Uint8List bytes, String mime) =>
    'data:$mime;base64,${base64Encode(bytes)}';

/// data:...;base64,.... -> bayt. Bozuk/eksik girdilerde null döner.
Uint8List? decodeDataUrl(String? data) {
  if (data == null || data.isEmpty) return null;
  try {
    var s = data;
    final comma = s.indexOf(',');
    if (s.startsWith('data:') && comma > 0) s = s.substring(comma + 1);
    s = s.replaceAll(RegExp(r'\s'), '');
    final pad = s.length % 4;
    if (pad != 0) s = s.padRight(s.length + (4 - pad), '=');
    return base64Decode(s);
  } catch (_) {
    return null;
  }
}

String mimeOfDataUrl(String? data, [String fallback = 'application/octet-stream']) {
  if (data == null || !data.startsWith('data:')) return fallback;
  final semi = data.indexOf(';');
  if (semi < 6) return fallback;
  return data.substring(5, semi);
}

/// Çözülmüş medyayı bellekte tutar; aynı görsel/ses defalarca çözülmesin.
class MediaCache {
  MediaCache._();
  static final Map<int, Uint8List> _bytes = {};
  static final Map<int, String> _files = {};
  static final List<int> _order = [];
  static const int _max = 120;

  static int _key(String data) => Object.hash(data.length, data.hashCode);

  static Uint8List? bytes(String? data) {
    if (data == null || data.isEmpty) return null;
    final k = _key(data);
    final hit = _bytes[k];
    if (hit != null) return hit;
    final b = decodeDataUrl(data);
    if (b == null) return null;
    _bytes[k] = b;
    _order.add(k);
    if (_order.length > _max) {
      final old = _order.removeAt(0);
      _bytes.remove(old);
    }
    return b;
  }

  /// Medyayı geçici bir dosyaya yazar (video/ses oynatıcılar dosya ister).
  static Future<String?> file(String? data, {String? fileName, String? mime}) async {
    if (data == null || data.isEmpty) return null;
    final k = _key(data);
    final existing = _files[k];
    if (existing != null && File(existing).existsSync()) return existing;
    final b = bytes(data);
    if (b == null) return null;
    final dir = await getTemporaryDirectory();
    final m = mime ?? mimeOfDataUrl(data);
    var name = fileName ?? 'media_$k.${extFromMime(m)}';
    name = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final f = File('${dir.path}/qt_$k-$name');
    await f.writeAsBytes(b, flush: true);
    _files[k] = f.path;
    return f.path;
  }
}

String initialsOf(String name) {
  final t = name.trim();
  if (t.isEmpty) return '?';
  final parts = t.split(RegExp(r'\s+'));
  if (parts.length > 1 && parts[1].isNotEmpty) {
    return (parts[0].substring(0, 1) + parts[1].substring(0, 1)).toUpperCase();
  }
  return t.substring(0, 1).toUpperCase();
}

final RegExp urlRegex = RegExp(
  r'((https?:\/\/)|(www\.))[^\s<]+',
  caseSensitive: false,
);
