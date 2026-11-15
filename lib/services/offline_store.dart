import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// İnternetsizken de gösterilebilsin diye son sohbetleri / gönderileri cihazda saklar.
/// Basit JSON dosyaları (uygulamanın özel klasöründe).
class OfflineStore {
  OfflineStore._();

  static Directory? _dir;
  static final Map<String, Future<void>> _writing = {};

  static Future<Directory> _base() async {
    if (_dir != null) return _dir!;
    final root = await getApplicationSupportDirectory();
    final d = Directory('${root.path}/offline');
    if (!await d.exists()) await d.create(recursive: true);
    _dir = d;
    return d;
  }

  static String _safe(String name) => name.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');

  static Future<Object?> read(String name) async {
    try {
      final f = File('${(await _base()).path}/${_safe(name)}.json');
      if (!await f.exists()) return null;
      final s = await f.readAsString();
      if (s.isEmpty) return null;
      return s.length > 200000 ? await compute(jsonDecode, s) : jsonDecode(s);
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(String name, Object data) {
    final prev = _writing[name] ?? Future.value();
    final next = prev.then((_) async {
      try {
        final d = await _base();
        final s = jsonEncode(data);
        final tmp = File('${d.path}/${_safe(name)}.tmp');
        await tmp.writeAsString(s, flush: true);
        await tmp.rename('${d.path}/${_safe(name)}.json');
      } catch (_) {}
    });
    _writing[name] = next;
    return next;
  }

  /// Ön eki [prefix] olan dosyalardan en yeni [keep] tanesi dışındakileri siler.
  static Future<void> prune(String prefix, int keep) async {
    try {
      final d = await _base();
      final files = <File>[];
      await for (final e in d.list()) {
        if (e is File && e.path.split('/').last.startsWith(_safe(prefix)) && e.path.endsWith('.json')) {
          files.add(e);
        }
      }
      if (files.length <= keep) return;
      final stats = <File, DateTime>{};
      for (final f in files) {
        stats[f] = (await f.stat()).modified;
      }
      files.sort((a, b) => stats[b]!.compareTo(stats[a]!));
      for (final f in files.skip(keep)) {
        await f.delete().catchError((_) => f);
      }
    } catch (_) {}
  }

  static Future<void> clearAll() async {
    try {
      final d = await _base();
      if (await d.exists()) await d.delete(recursive: true);
      _dir = null;
    } catch (_) {}
  }

  /// JSON'a güvenle yazılabilir hale getirir (Firebase değerleri Map<Object?,Object?> olabilir).
  static Object? plain(Object? v) {
    if (v is Map) return v.map((k, val) => MapEntry('$k', plain(val)));
    if (v is List) return v.map(plain).toList();
    if (v is num || v is String || v is bool || v == null) return v;
    return v.toString();
  }
}
