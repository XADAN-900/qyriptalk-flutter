import 'dart:async';
import 'package:qyriptalk/core/i18n.dart';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Yönetim paneliyle bağlantılı kontroller (uygulama açıkken çalışır):
///  - Hesap askıya alındıysa (bans/{uid}) uygulamayı kilitler.
///  - Panelden gönderilen duyuruyu (announcements) bir kez gösterir.
///  - GitHub'da yeni sürüm varsa "Güncelle" ekranı gösterir; APK'yı indirip kurulumu başlatır.
class AppGuard extends StatefulWidget {
  final FirebaseDatabase db;
  final String uid;
  final String repo; // ör. XADAN-900/flinq-flutter
  final String apkName; // ör. FlinQ.apk
  final String appName;
  final Color accent;
  final Future<void> Function() onLogout;
  final Widget child;

  const AppGuard({
    super.key,
    required this.db,
    required this.uid,
    required this.repo,
    required this.apkName,
    required this.appName,
    required this.accent,
    required this.onLogout,
    required this.child,
  });

  /// CI derleme numarası (GitHub Actions run_number). Yerel derlemede 0: güncelleme kontrolü yapılmaz.
  static const int build = int.fromEnvironment('APP_BUILD', defaultValue: 0);

  @override
  State<AppGuard> createState() => _AppGuardState();
}

class _AppGuardState extends State<AppGuard> with WidgetsBindingObserver {
  static const _ch = MethodChannel('app/installer');
  final List<StreamSubscription> _subs = [];
  Map<String, dynamic>? _ban;
  bool _updateShown = false;
  DateTime? _lastUpdateCheck;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _subs.add(widget.db.ref('bans/${widget.uid}').onValue.listen((e) {
      final v = e.snapshot.value;
      if (!mounted) return;
      setState(() => _ban = v == null ? null : (v is Map ? v.map((k, x) => MapEntry('$k', x)) : {'reason': '$v'}));
    }, onError: (_) {}));
    _subs.add(widget.db.ref('announcements').orderByKey().limitToLast(1).onChildAdded.listen(
          _onAnnouncement,
          onError: (_) {},
        ));
    Future.delayed(const Duration(seconds: 3), _checkUpdate);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _resumed = true;
      final last = _lastUpdateCheck;
      if (last == null || DateTime.now().difference(last) > const Duration(hours: 6)) _checkUpdate();
      _showPendingAnnouncement();
    } else {
      _resumed = false;
    }
  }

  // ---------------- Duyuru ----------------
  bool _resumed = true;
  bool _showingAnn = false;
  String? _pendingAnnId;
  Map<String, dynamic>? _pendingAnn;

  Future<void> _onAnnouncement(DatabaseEvent e) async {
    final id = e.snapshot.key;
    final v = e.snapshot.value;
    if (id == null || v is! Map) return;
    final m = v.map((k, x) => MapEntry('$k', x));
    final ts = m['ts'] is num ? (m['ts'] as num).toInt() : 0;
    if (ts > 0 && DateTime.now().millisecondsSinceEpoch - ts > 7 * 24 * 3600 * 1000) return;
    final prefs = await SharedPreferences.getInstance();
    final seen = prefs.getString('announcementSeen') ?? '';
    if (seen.compareTo(id) >= 0) return;
    // "Görüldü" işareti pencere gerçekten gösterilince konur.
    _pendingAnnId = id;
    _pendingAnn = m;
    _showPendingAnnouncement();
  }

  Future<void> _showPendingAnnouncement() async {
    final id = _pendingAnnId;
    final m = _pendingAnn;
    if (id == null || m == null || _showingAnn) return;
    if (!_resumed || !mounted) return; // arka plandaysa öne gelince gösterilir
    _showingAnn = true;
    _pendingAnnId = null;
    _pendingAnn = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('announcementSeen', id);
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: Icon(Icons.campaign_rounded, size: 40, color: widget.accent),
          title: Text('${m['title'] ?? 'Duyuru'}'),
          content: SingleChildScrollView(child: Text('${m['body'] ?? ''}')),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const T('Tamam'))],
        ),
      );
    } finally {
      _showingAnn = false;
    }
  }

  // ---------------- Güncelleme ----------------
  static int _buildOf(String tag) {
    final m = RegExp(r'-(\d+)$').firstMatch(tag);
    return m == null ? 0 : int.parse(m.group(1)!);
  }

  Future<void> _checkUpdate() async {
    _lastUpdateCheck = DateTime.now();
    if (AppGuard.build == 0 || _updateShown || !Platform.isAndroid) return;
    try {
      final res = await http
          .get(Uri.parse('https://api.github.com/repos/${widget.repo}/releases/latest'),
              headers: {'Accept': 'application/vnd.github+json'})
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return;
      final j = jsonDecode(res.body);
      if (j is! Map) return;
      final tag = '${j['tag_name'] ?? ''}';
      final latest = _buildOf(tag);
      if (latest <= AppGuard.build) return;
      String? url;
      final assets = j['assets'];
      if (assets is List) {
        for (final a in assets) {
          if (a is Map && '${a['name']}'.toLowerCase().endsWith('.apk')) {
            url = '${a['browser_download_url']}';
            break;
          }
        }
      }
      url ??= 'https://github.com/${widget.repo}/releases/latest/download/${widget.apkName}';
      if (!mounted) return;
      _updateShown = true;
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => _UpdateDialog(
          appName: widget.appName,
          version: tag,
          notes: '${j['body'] ?? ''}',
          url: url!,
          accent: widget.accent,
          channel: _ch,
        ),
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final ban = _ban;
    if (ban == null) return widget.child;
    final reason = '${ban['reason'] ?? ''}'.trim();
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.gpp_bad_rounded, size: 72, color: Colors.redAccent),
              const SizedBox(height: 16),
              const T('Hesabın askıya alındı',
                  textAlign: TextAlign.center, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
              const SizedBox(height: 10),
              Text(
                reason.isEmpty ? 'Bu hesap yönetici tarafından askıya alındı.' : 'Sebep: $reason',
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).hintColor),
              ),
              const SizedBox(height: 24),
              FilledButton(onPressed: widget.onLogout, child: const T('Çıkış yap')),
            ],
          ),
        ),
      ),
    );
  }
}

class _UpdateDialog extends StatefulWidget {
  final String appName;
  final String version;
  final String notes;
  final String url;
  final Color accent;
  final MethodChannel channel;

  const _UpdateDialog({
    required this.appName,
    required this.version,
    required this.notes,
    required this.url,
    required this.accent,
    required this.channel,
  });

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  double? _progress; // null: başlamadı
  String? _error;
  bool _done = false;
  String? _path;
  http.Client? _client;

  @override
  void dispose() {
    _client?.close();
    super.dispose();
  }

  Future<void> _download() async {
    setState(() {
      _progress = 0;
      _error = null;
    });
    final client = http.Client();
    _client = client;
    try {
      final req = http.Request('GET', Uri.parse(widget.url));
      final res = await client.send(req);
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final total = res.contentLength ?? 0;
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/update.apk');
      final sink = f.openWrite();
      var got = 0;
      await for (final chunk in res.stream) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0 && mounted) setState(() => _progress = got / total);
      }
      await sink.close();
      _path = f.path;
      if (!mounted) return;
      setState(() => _done = true);
      await _install();
    } catch (e) {
      if (mounted) {
        setState(() {
          _progress = null;
          _error = 'İndirilemedi. İnternet bağlantını kontrol edip tekrar dene.';
        });
      }
    } finally {
      client.close();
      _client = null;
    }
  }

  Future<void> _install() async {
    final p = _path;
    if (p == null) return;
    try {
      final r = await widget.channel.invokeMethod<String>('installApk', {'path': p});
      if (r == 'permission' && mounted) {
        setState(() => _error = 'Açılan ekranda "Bu kaynaktan izin ver"i aç, sonra geri dönüp "Kur"a bas.');
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Kurulum başlatılamadı.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final downloading = _progress != null && !_done;
    return PopScope(
      canPop: !downloading,
      child: AlertDialog(
        icon: Icon(Icons.system_update_rounded, size: 44, color: widget.accent),
        title: const T('Yeni sürüm var'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${widget.appName} için yeni bir sürüm hazır (${widget.version}). '
                'Güncellemek için "Güncelle"ye bas; indirip kurulumu otomatik başlatırız.'),
            if (downloading) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: _progress == 0 ? null : _progress, color: widget.accent),
              const SizedBox(height: 6),
              Text('İndiriliyor… %${((_progress ?? 0) * 100).round()}',
                  style: TextStyle(color: Theme.of(context).hintColor)),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.redAccent)),
            ],
          ],
        ),
        actions: [
          if (!downloading)
            TextButton(onPressed: () => Navigator.pop(context), child: const T('Sonra')),
          if (_done)
            FilledButton(onPressed: _install, child: const T('Kur'))
          else if (!downloading)
            FilledButton(onPressed: _download, child: const T('Güncelle')),
        ],
      ),
    );
  }
}
