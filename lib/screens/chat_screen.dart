import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';

import '../core/theme.dart';
import '../core/utils.dart';
import '../models/models.dart';
import '../services/app_state.dart';
import '../services/call_service.dart';
import '../services/chat_repo.dart';
import '../widgets/avatar.dart';
import '../widgets/emoji_panel.dart';
import '../widgets/message_bubble.dart';
import 'room_info_screen.dart';
import 'user_profile_screen.dart';

class ChatScreen extends StatefulWidget {
  final bool isDm;
  final String chatId;
  const ChatScreen({super.key, required this.isDm, required this.chatId});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _Entry {
  final ChatMessage? msg;
  final String? day;
  final bool groupedWithNext;
  final bool firstOfGroup;
  const _Entry({this.msg, this.day, this.groupedWithNext = false, this.firstOfGroup = true});
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  static const int _page = 60;

  late final AppState app;
  late final ChatRef ref;
  final List<ChatMessage> _msgs = [];
  final List<StreamSubscription> _subs = [];
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final Map<String, GlobalKey> _keys = {};
  final Map<String, String> _translations = {};
  final Set<String> _selected = {};

  bool _loaded = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  bool _showEmoji = false;
  bool _searching = false;
  String _query = '';
  bool _showJump = false;
  int _newWhileUp = 0;
  String? _highlightId;

  ChatMessage? _replyTo;
  ChatMessage? _editing;
  Map<String, dynamic>? _pinned;
  List<String> _typing = const [];
  Map<String, dynamic> _members = {};
  bool _kicked = false;

  // Ses kaydı
  AudioRecorder? _recorder;
  bool _recording = false;
  int _recSec = 0;
  Timer? _recTimer;
  String? _recPath;

  bool get _isDm => widget.isDm;
  String get _myUid => app.uid ?? '';

  @override
  void initState() {
    super.initState();
    app = context.read<AppState>();
    ref = ChatRef(
      db: app.db,
      isDm: _isDm,
      id: widget.chatId,
      myUid: _myUid,
      myName: app.username,
    );
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => app.markChatOpened(ref.key));
    _scroll.addListener(_onScroll);
    _input.addListener(_onTextChanged);
    if (!_isDm && !app.rooms.containsKey(widget.chatId)) app.refreshRoom(widget.chatId);
    _subscribe();
  }

  void _subscribe() {
    final q = ref.messages.orderByKey().limitToLast(_page);
    q.get().then((s) {
      if (!mounted) return;
      setState(() {
        _loaded = true;
        if (s.children.length < _page) _hasMore = false;
      });
    }).catchError((_) {
      if (mounted) setState(() => _loaded = true);
    });
    _subs.add(q.onChildAdded.listen(_onAdded, onError: (_) {}));
    _subs.add(q.onChildChanged.listen(_onChanged, onError: (_) {}));
    _subs.add(q.onChildRemoved.listen(_onRemoved, onError: (_) {}));
    _subs.add(ref.base.child('pinnedMessage').onValue.listen((e) {
      final v = asMap(e.snapshot.value);
      if (mounted) setState(() => _pinned = v.isEmpty ? null : v);
    }, onError: (_) {}));
    _subs.add(ref.base.child('typing').onValue.listen((e) {
      final m = asMap(e.snapshot.value);
      final now = DateTime.now().millisecondsSinceEpoch;
      final names = <String>[];
      m.forEach((uid, v) {
        if (uid == _myUid) return;
        final t = asMap(v);
        final ts = asInt(t['ts']);
        if (ts != 0 && now - ts > 15000) return;
        final n = asStr(t['username']);
        if (n.isNotEmpty) names.add(n);
      });
      if (mounted) setState(() => _typing = names);
    }, onError: (_) {}));
    if (!_isDm) {
      var first = true;
      _subs.add(app.db.ref('rooms/${widget.chatId}/users').onValue.listen((e) {
        final m = asMap(e.snapshot.value);
        if (!mounted) return;
        final wasMember = _members.containsKey(_myUid);
        setState(() => _members = m);
        final room = app.rooms[widget.chatId];
        if (!first && wasMember && !m.containsKey(_myUid) && room?.createdBy != _myUid) {
          _removedFromRoom('Odadan çıkarıldın.');
        }
        first = false;
      }, onError: (_) {}));
      _subs.add(app.db.ref('rooms/${widget.chatId}/bannedUsers/$_myUid').onValue.listen((e) {
        if (e.snapshot.exists) _removedFromRoom('Bu odaya erişimin kısıtlandı.');
      }, onError: (_) {}));
    }
  }

  void _removedFromRoom(String reason) {
    if (_kicked || !mounted) return;
    _kicked = true;
    app.leaveRoom(widget.chatId);
    showSnack(context, reason, error: true);
    Navigator.of(context).maybePop();
  }

  int _indexFor(String id) {
    // Push anahtarları zamana göre sıralıdır: ikili arama ile yerleştir.
    var lo = 0, hi = _msgs.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_msgs[mid].id.compareTo(id) < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  void _onAdded(DatabaseEvent e) {
    final k = e.snapshot.key;
    if (k == null) return;
    final m = ChatMessage.fromMap(k, asMap(e.snapshot.value));
    final i = _indexFor(k);
    if (i < _msgs.length && _msgs[i].id == k) {
      _msgs[i] = m;
    } else {
      _msgs.insert(i, m);
      final isNewest = i == _msgs.length - 1;
      if (_loaded && isNewest && m.senderUid != _myUid && _scroll.hasClients && _scroll.offset > 300) {
        _newWhileUp++;
      }
    }
    _afterIncoming(m);
    if (mounted) setState(() {});
  }

  void _onChanged(DatabaseEvent e) {
    final k = e.snapshot.key;
    if (k == null) return;
    final i = _indexFor(k);
    if (i < _msgs.length && _msgs[i].id == k) {
      final m = ChatMessage.fromMap(k, asMap(e.snapshot.value));
      _msgs[i] = m;
      if (m.edited) _translations.remove(k);
      if (mounted) setState(() {});
    }
  }

  Future<void> _onRemoved(DatabaseEvent e) async {
    final k = e.snapshot.key;
    if (k == null) return;
    // limitToLast penceresinden düşen mesaj silinmiş sayılmaz: gerçekten var mı bak.
    try {
      final s = await ref.messages.child(k).get();
      if (s.exists) return;
    } catch (_) {}
    final i = _indexFor(k);
    if (i < _msgs.length && _msgs[i].id == k) {
      _msgs.removeAt(i);
      _selected.remove(k);
      if (mounted) setState(() {});
    }
  }

  void _afterIncoming(ChatMessage m) {
    if (m.senderUid == _myUid) return;
    final resumed = WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    if (resumed && app.showReadReceipts && !m.readBy.contains(_myUid)) {
      ref.markRead(m.id).catchError((_) {});
    }
    if (app.autoTranslate && m.type == 'text' && m.text.trim().isNotEmpty && !_translations.containsKey(m.id)) {
      _translate(m, silent: true);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      app.markChatOpened(ref.key);
      if (app.showReadReceipts) {
        for (final m in _msgs.reversed.take(40)) {
          if (m.senderUid != _myUid && !m.readBy.contains(_myUid)) {
            ref.markRead(m.id).catchError((_) {});
          }
        }
      }
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final show = _scroll.offset > 400;
    if (show != _showJump) {
      setState(() {
        _showJump = show;
        if (!show) _newWhileUp = 0;
      });
    }
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 400) _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _msgs.isEmpty || !_loaded) return;
    setState(() => _loadingMore = true);
    try {
      final firstId = _msgs.first.id;
      final s = await ref.messages.orderByKey().endAt(firstId).limitToLast(_page + 1).get();
      final older = <ChatMessage>[];
      for (final c in s.children) {
        if (c.key == null || c.key == firstId) continue;
        older.add(ChatMessage.fromMap(c.key!, asMap(c.value)));
      }
      for (final m in older) {
        final i = _indexFor(m.id);
        if (i < _msgs.length && _msgs[i].id == m.id) continue;
        _msgs.insert(i, m);
      }
      if (older.length < _page) _hasMore = false;
    } catch (_) {}
    if (mounted) setState(() => _loadingMore = false);
  }

  void _onTextChanged() {
    final has = _input.text.trim().isNotEmpty;
    if (has) ref.setTyping(true);
    setState(() {});
  }

  // ------------------------------------------------------------------
  // Gönderme
  // ------------------------------------------------------------------
  ReplyRef? _replyRef() {
    final r = _replyTo;
    if (r == null) return null;
    return ReplyRef(r.id, r.senderUid == _myUid ? 'Sen' : r.sender, r.previewText);
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    if (!_isDm && !app.joinedRoomIds.contains(widget.chatId)) {
      showSnack(context, 'Mesaj göndermek için önce odaya katıl.', error: true);
      return;
    }
    HapticFeedback.selectionClick();
    final editing = _editing;
    final reply = _replyRef();
    _input.clear();
    setState(() {
      _replyTo = null;
      _editing = null;
    });
    try {
      if (editing != null) {
        await ref.edit(editing.id, text);
      } else {
        await ref.sendText(text, reply: reply);
      }
      if (_scroll.hasClients) {
        _scroll.animateTo(0, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    } catch (e) {
      _input.text = text;
      if (mounted) showSnack(context, 'Mesaj gönderilemedi.', error: true);
    }
  }

  Future<void> _sendMedia({
    required String type,
    required Uint8List bytes,
    required String fileName,
    required String mime,
    String caption = '',
    int duration = 0,
  }) async {
    if (bytes.length > ChatRef.maxMediaBytes) {
      showSnack(context, 'Dosya çok büyük (en fazla 7 MB).', error: true);
      return;
    }
    final reply = _replyRef();
    setState(() => _replyTo = null);
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(
      content: Row(children: [
        SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        SizedBox(width: 12),
        Text('Gönderiliyor…'),
      ]),
      duration: Duration(seconds: 30),
    ));
    try {
      await ref.sendMedia(
        type: type,
        dataUrl: toDataUrl(bytes, mime),
        fileName: fileName,
        fileSize: bytes.length,
        fileType: mime,
        caption: caption,
        duration: duration,
        reply: reply,
      );
      messenger.hideCurrentSnackBar();
    } catch (e) {
      messenger.hideCurrentSnackBar();
      if (mounted) showSnack(context, 'Gönderilemedi: $e', error: true);
    }
  }

  Future<String?> _askCaption(Widget preview) async {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(borderRadius: BorderRadius.circular(14), child: preview),
              const SizedBox(height: 12),
              TextField(
                controller: c,
                maxLines: 3,
                minLines: 1,
                decoration: const InputDecoration(hintText: 'Açıklama ekle…'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Vazgeç')),
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(64, 40)),
            onPressed: () => Navigator.pop(ctx, c.text.trim()),
            icon: const Icon(Icons.send_rounded, size: 18),
            label: const Text('Gönder'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickImage(ImageSource source) async {
    final x = await ImagePicker().pickImage(source: source, maxWidth: 1600, maxHeight: 1600, imageQuality: 78);
    if (x == null || !mounted) return;
    final b = await x.readAsBytes();
    final caption = await _askCaption(
        Image.memory(b, height: 260, fit: BoxFit.cover, width: double.infinity));
    if (caption == null) return;
    await _sendMedia(type: 'image', bytes: b, fileName: x.name, mime: 'image/jpeg', caption: caption);
  }

  Future<void> _pickVideo() async {
    final x = await ImagePicker().pickVideo(source: ImageSource.gallery, maxDuration: const Duration(minutes: 3));
    if (x == null || !mounted) return;
    final len = await x.length();
    if (len > ChatRef.maxMediaBytes) {
      if (mounted) showSnack(context, 'Video çok büyük (en fazla 7 MB).', error: true);
      return;
    }
    final b = await x.readAsBytes();
    final caption = await _askCaption(Container(
      height: 160,
      color: Colors.black,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.videocam_rounded, color: Colors.white, size: 48),
          const SizedBox(height: 8),
          Text('${x.name}\n${formatFileSize(len)}',
              textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
        ],
      ),
    ));
    if (caption == null) return;
    await _sendMedia(type: 'video', bytes: b, fileName: x.name, mime: mimeFromName(x.name), caption: caption);
  }

  Future<void> _pickFile() async {
    final r = await FilePicker.platform.pickFiles(withData: true);
    if (r == null || r.files.isEmpty || !mounted) return;
    final f = r.files.first;
    var bytes = f.bytes;
    if (bytes == null && f.path != null) bytes = await File(f.path!).readAsBytes();
    if (bytes == null) return;
    final mime = mimeFromName(f.name);
    final type = mime.startsWith('image/')
        ? 'image'
        : mime.startsWith('video/')
            ? 'video'
            : 'file';
    await _sendMedia(type: type, bytes: bytes, fileName: f.name, mime: mime);
  }

  void _attachSheet() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _AttachButton(
                icon: Icons.photo_rounded,
                label: 'Galeri',
                color: const Color(0xFF8E3BFF),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickImage(ImageSource.gallery);
                },
              ),
              _AttachButton(
                icon: Icons.photo_camera_rounded,
                label: 'Kamera',
                color: const Color(0xFFFF4F8B),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickImage(ImageSource.camera);
                },
              ),
              _AttachButton(
                icon: Icons.videocam_rounded,
                label: 'Video',
                color: const Color(0xFFFF9F43),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickVideo();
                },
              ),
              _AttachButton(
                icon: Icons.insert_drive_file_rounded,
                label: 'Dosya',
                color: const Color(0xFF0A84FF),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickFile();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------
  // Sesli mesaj
  // ------------------------------------------------------------------
  Future<void> _startRecording() async {
    final rec = AudioRecorder();
    if (!await rec.hasPermission()) {
      rec.dispose();
      if (mounted) showSnack(context, 'Mikrofon izni gerekli.', error: true);
      return;
    }
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await rec.start(
      const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000, sampleRate: 44100, numChannels: 1),
      path: path,
    );
    HapticFeedback.mediumImpact();
    _recorder = rec;
    _recPath = path;
    setState(() {
      _recording = true;
      _recSec = 0;
    });
    _recTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _recSec++);
      if (_recSec >= 300) _stopRecording(send: true);
    });
  }

  Future<void> _stopRecording({required bool send}) async {
    final rec = _recorder;
    _recTimer?.cancel();
    _recorder = null;
    if (rec == null) return;
    final path = await rec.stop() ?? _recPath;
    rec.dispose();
    final secs = _recSec;
    setState(() => _recording = false);
    if (!send || path == null) return;
    if (secs < 1) {
      if (mounted) showSnack(context, 'Kayıt çok kısa.');
      return;
    }
    final f = File(path);
    if (!await f.exists()) return;
    final b = await f.readAsBytes();
    await _sendMedia(
      type: 'voice',
      bytes: b,
      fileName: 'sesli_mesaj_${DateTime.now().millisecondsSinceEpoch}.m4a',
      mime: 'audio/mp4',
      duration: secs,
    );
  }

  // ------------------------------------------------------------------
  // Mesaj işlemleri
  // ------------------------------------------------------------------
  bool get _canModerate {
    if (_isDm) return false;
    final room = app.rooms[widget.chatId];
    return room?.createdBy == _myUid || (app.me?.isModerator ?? false);
  }

  Future<void> _translate(ChatMessage m, {bool silent = false}) async {
    final out = await Translator.translate(m.type == 'text' ? m.text : m.caption);
    if (!mounted) return;
    if (out == null) {
      if (!silent) showSnack(context, 'Çeviri yapılamadı.', error: true);
      return;
    }
    setState(() => _translations[m.id] = out);
  }

  void _messageActions(ChatMessage m) {
    HapticFeedback.mediumImpact();
    final mine = m.senderUid == _myUid;
    final isPinned = _pinned != null && _pinned!['id'] == m.id;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (final e in kQuickReactions)
                      InkWell(
                        borderRadius: BorderRadius.circular(24),
                        onTap: () {
                          Navigator.pop(ctx);
                          final current = m.reactions[_myUid];
                          ref.react(m.id, current == e ? null : e);
                        },
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: m.reactions[_myUid] == e
                                ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.2)
                                : null,
                          ),
                          child: Text(e, style: const TextStyle(fontSize: 28)),
                        ),
                      ),
                  ],
                ),
              ),
              const Divider(height: 20),
              _action(ctx, Icons.reply_rounded, 'Yanıtla', () {
                setState(() {
                  _replyTo = m;
                  _editing = null;
                });
                _focus.requestFocus();
              }),
              if (m.type == 'text' || m.caption.isNotEmpty)
                _action(ctx, Icons.copy_rounded, 'Kopyala', () {
                  Clipboard.setData(ClipboardData(text: m.type == 'text' ? m.text : m.caption));
                  showSnack(context, 'Kopyalandı');
                }),
              if (m.type == 'text' || m.caption.isNotEmpty)
                _action(ctx, Icons.translate_rounded,
                    _translations.containsKey(m.id) ? 'Çeviriyi gizle' : 'Çevir', () {
                  if (_translations.containsKey(m.id)) {
                    setState(() => _translations.remove(m.id));
                  } else {
                    _translate(m);
                  }
                }),
              _action(ctx, Icons.shortcut_rounded, 'İlet', () => _forward([m])),
              _action(ctx, isPinned ? Icons.push_pin_outlined : Icons.push_pin_rounded,
                  isPinned ? 'Sabitlemeyi kaldır' : 'Sabitle', () {
                isPinned ? ref.unpin() : ref.pin(m);
              }),
              if (mine && m.type == 'text')
                _action(ctx, Icons.edit_rounded, 'Düzenle', () {
                  setState(() {
                    _editing = m;
                    _replyTo = null;
                    _input.text = m.text;
                    _input.selection = TextSelection.collapsed(offset: m.text.length);
                  });
                  _focus.requestFocus();
                }),
              if (mine)
                _action(ctx, Icons.info_outline_rounded, 'Bilgi', () => _showInfo(m)),
              _action(ctx, Icons.check_circle_outline_rounded, 'Seç', () {
                setState(() => _selected.add(m.id));
              }),
              if (mine || _canModerate)
                _action(ctx, Icons.delete_outline_rounded, 'Herkesten sil', () async {
                  final ok = await confirmDialog(context,
                      title: 'Mesajı sil',
                      message: 'Bu mesaj herkesten silinecek.',
                      confirmText: 'Sil',
                      destructive: true);
                  if (ok) {
                    await ref.delete(m.id);
                    if (isPinned) await ref.unpin();
                  }
                }, danger: true),
            ],
          ),
        ),
      ),
    );
  }

  Widget _action(BuildContext ctx, IconData icon, String label, VoidCallback onTap, {bool danger = false}) {
    return ListTile(
      leading: Icon(icon, color: danger ? QColors.danger : null),
      title: Text(label, style: TextStyle(color: danger ? QColors.danger : null)),
      onTap: () {
        Navigator.pop(ctx);
        onTap();
      },
    );
  }

  void _showInfo(ChatMessage m) {
    final readers = m.readBy.where((u) => u != _myUid).toList();
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              leading: const Icon(Icons.schedule_rounded),
              title: const Text('Gönderildi'),
              subtitle: Text('${formatDayHeader(m.timestamp)} ${formatClock(m.timestamp)}'),
            ),
            ListTile(
              leading: const Icon(Icons.done_all_rounded, color: QColors.blue),
              title: Text(readers.isEmpty ? 'Henüz okunmadı' : 'Okuyanlar (${readers.length})'),
            ),
            for (final u in readers)
              ListTile(
                dense: true,
                leading: Avatar(name: app.users[u]?.username ?? '?', photo: app.users[u]?.photo, size: 34),
                title: Text(app.users[u]?.username ?? 'Kullanıcı'),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Future<void> _forward(List<ChatMessage> msgs) async {
    final targets = app.chatSummaries();
    final picked = await showModalBottomSheet<ChatSummary>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (_, sc) => ListView(
          controller: sc,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('İlet…', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            ),
            for (final t in targets)
              ListTile(
                leading: Avatar(name: t.title, photo: t.photo, size: 42, isGroup: !t.isDm),
                title: Text(t.title),
                onTap: () => Navigator.pop(ctx, t),
              ),
            for (final u in app.users.values.where((u) =>
                u.uid != _myUid && !targets.any((t) => t.isDm && t.otherUid == u.uid)))
              ListTile(
                leading: Avatar(name: u.username, photo: u.photo, size: 42),
                title: Text(u.username),
                onTap: () => Navigator.pop(
                    ctx,
                    ChatSummary(
                        id: dmIdFor(_myUid, u.uid), isDm: true, title: u.username, otherUid: u.uid)),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    for (final m in msgs) {
      await ChatRef.forward(
        db: app.db,
        msg: m,
        toDm: picked.isDm,
        toId: picked.id,
        myUid: _myUid,
        myName: app.username,
      );
    }
    if (!mounted) return;
    setState(() => _selected.clear());
    showSnack(context, '${msgs.length} mesaj "${picked.title}" sohbetine iletildi.');
  }

  Future<void> _deleteSelected() async {
    final list = _msgs.where((m) => _selected.contains(m.id)).toList();
    final allowed = list.where((m) => m.senderUid == _myUid || _canModerate).toList();
    if (allowed.isEmpty) {
      showSnack(context, 'Sadece kendi mesajlarını silebilirsin.', error: true);
      return;
    }
    final ok = await confirmDialog(context,
        title: '${allowed.length} mesaj silinsin mi?',
        message: allowed.length < list.length
            ? 'Başkalarına ait ${list.length - allowed.length} mesaj silinmeyecek.'
            : 'Seçilen mesajlar herkesten silinecek.',
        confirmText: 'Sil',
        destructive: true);
    if (!ok) return;
    for (final m in allowed) {
      await ref.delete(m.id);
    }
    if (mounted) setState(() => _selected.clear());
  }

  void _jumpTo(String id) {
    final k = _keys[id];
    final ctx = k?.currentContext;
    if (ctx == null) {
      showSnack(context, 'Mesaj daha eski; yukarı kaydırarak yükle.');
      return;
    }
    Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 350), alignment: 0.4);
    setState(() => _highlightId = id);
    Timer(const Duration(milliseconds: 1600), () {
      if (mounted && _highlightId == id) setState(() => _highlightId = null);
    });
  }

  Future<void> _startCall() async {
    final title = _title();
    final err = await context
        .read<CallService>()
        .startCall(isDm: _isDm, chatId: widget.chatId, chatTitle: title);
    if (err != null && mounted) showSnack(context, err, error: true);
  }

  String _title() {
    if (_isDm) {
      final other = otherUidFromDm(widget.chatId, _myUid);
      return app.users[other]?.username ?? 'Sohbet';
    }
    return app.rooms[widget.chatId]?.name ?? 'Oda';
  }

  void _openInfo() {
    if (_isDm) {
      final other = otherUidFromDm(widget.chatId, _myUid);
      Navigator.push(context,
          MaterialPageRoute(builder: (_) => UserProfileScreen(uid: other, fromChat: true)));
    } else {
      Navigator.push(context, MaterialPageRoute(builder: (_) => RoomInfoScreen(roomId: widget.chatId)));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    app.markChatClosed(ref.key);
    ref.setTyping(false);
    for (final s in _subs) {
      s.cancel();
    }
    _recTimer?.cancel();
    _recorder?.dispose();
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------
  // Arayüz
  // ------------------------------------------------------------------
  List<_Entry> _entries() {
    var list = _msgs;
    if (_searching && _query.isNotEmpty) {
      final q = _query.toLowerCase();
      list = list
          .where((m) =>
              m.text.toLowerCase().contains(q) ||
              m.caption.toLowerCase().contains(q) ||
              (m.fileName ?? '').toLowerCase().contains(q))
          .toList();
    }
    final out = <_Entry>[];
    DateTime? lastDay;
    for (var i = 0; i < list.length; i++) {
      final m = list[i];
      final ts = m.timestamp == 0 ? DateTime.now().millisecondsSinceEpoch : m.timestamp;
      final d = DateTime.fromMillisecondsSinceEpoch(ts);
      if (lastDay == null || !isSameDay(lastDay, d)) {
        out.add(_Entry(day: formatDayHeader(ts)));
        lastDay = d;
      }
      final prev = i > 0 ? list[i - 1] : null;
      final next = i < list.length - 1 ? list[i + 1] : null;
      bool close(ChatMessage? a, ChatMessage b) =>
          a != null &&
          a.senderUid == b.senderUid &&
          (a.timestamp - b.timestamp).abs() < 3 * 60 * 1000 &&
          isSameDay(DateTime.fromMillisecondsSinceEpoch(a.timestamp == 0 ? ts : a.timestamp), d);
      out.add(_Entry(
        msg: m,
        groupedWithNext: close(next, m),
        firstOfGroup: !close(prev, m),
      ));
    }
    return out.reversed.toList();
  }

  @override
  Widget build(BuildContext context) {
    final appW = context.watch<AppState>();
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final entries = _entries();
    final other = _isDm ? appW.users[otherUidFromDm(widget.chatId, _myUid)] : null;
    final room = _isDm ? null : appW.rooms[widget.chatId];
    final joined = _isDm || appW.joinedRoomIds.contains(widget.chatId);
    final selecting = _selected.isNotEmpty;

    String subtitle;
    if (_typing.isNotEmpty) {
      subtitle = _isDm ? 'yazıyor…' : '${_typing.join(', ')} yazıyor…';
    } else if (_isDm) {
      subtitle = other?.statusText ?? '';
    } else {
      final online = _members.values.where((v) => asBool(asMap(v)['online'])).length;
      subtitle = '${_members.length} üye${online > 0 ? ' · $online çevrimiçi' : ''}';
    }

    return PopScope(
      canPop: !_showEmoji && !selecting && !_searching,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        setState(() {
          _showEmoji = false;
          _selected.clear();
          _searching = false;
          _query = '';
        });
      },
      child: Scaffold(
        appBar: selecting
            ? AppBar(
                leading: IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => setState(() => _selected.clear()),
                ),
                title: Text('${_selected.length} seçildi'),
                actions: [
                  IconButton(
                    icon: const Icon(Icons.copy_rounded),
                    onPressed: () {
                      final txt = _msgs
                          .where((m) => _selected.contains(m.id) && m.type == 'text')
                          .map((m) => '${m.sender}: ${m.text}')
                          .join('\n');
                      Clipboard.setData(ClipboardData(text: txt));
                      setState(() => _selected.clear());
                      showSnack(context, 'Kopyalandı');
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.shortcut_rounded),
                    onPressed: () => _forward(_msgs.where((m) => _selected.contains(m.id)).toList()),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: _deleteSelected,
                  ),
                ],
              )
            : _searching
                ? AppBar(
                    leading: IconButton(
                      icon: const Icon(Icons.arrow_back_rounded),
                      onPressed: () => setState(() {
                        _searching = false;
                        _query = '';
                      }),
                    ),
                    title: TextField(
                      autofocus: true,
                      onChanged: (v) => setState(() => _query = v.trim()),
                      decoration: const InputDecoration(
                        hintText: 'Bu sohbette ara…',
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                      ),
                    ),
                  )
                : AppBar(
                    titleSpacing: 0,
                    title: InkWell(
                      onTap: _openInfo,
                      child: Row(
                        children: [
                          Hero(
                            tag: _isDm ? 'avatar_${other?.uid}' : 'room_${widget.chatId}',
                            child: Avatar(
                              name: _title(),
                              photo: _isDm ? other?.photo : room?.logo,
                              size: 40,
                              online: other?.isOnline ?? false,
                              isGroup: !_isDm,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(_title(),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                                Text(
                                  subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w400,
                                    color: _typing.isNotEmpty || (other?.isOnline ?? false)
                                        ? QColors.online
                                        : theme.hintColor,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    actions: [
                      IconButton(
                        tooltip: 'Sesli arama',
                        icon: const Icon(Icons.call_rounded),
                        onPressed: joined ? _startCall : null,
                      ),
                      PopupMenuButton<String>(
                        onSelected: (v) {
                          switch (v) {
                            case 'search':
                              setState(() => _searching = true);
                              break;
                            case 'info':
                              _openInfo();
                              break;
                            case 'mute':
                              app.toggleMute(ref.key);
                              break;
                          }
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(value: 'search', child: Text('Sohbette ara')),
                          PopupMenuItem(
                              value: 'info', child: Text(_isDm ? 'Profili görüntüle' : 'Oda bilgisi')),
                          PopupMenuItem(
                              value: 'mute',
                              child: Text(app.isMuted(ref.key) ? 'Bildirimleri aç' : 'Sessize al')),
                        ],
                      ),
                    ],
                  ),
        body: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: isDark
                  ? const [Color(0xFF0B0724), Color(0xFF07041A)]
                  : const [Color(0xFFF4F2FF), Color(0xFFF9F8FD)],
            ),
          ),
          child: Column(
            children: [
              if (_pinned != null && !_searching)
                Material(
                  color: theme.colorScheme.surface,
                  child: InkWell(
                    onTap: () => _jumpTo(asStr(_pinned!['id'])),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
                      child: Row(
                        children: [
                          Icon(Icons.push_pin_rounded, size: 18, color: theme.colorScheme.primary),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Sabitlenmiş · ${asStr(_pinned!['sender'])}',
                                    style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        color: theme.colorScheme.primary)),
                                Text(asStr(_pinned!['previewText']),
                                    maxLines: 1, overflow: TextOverflow.ellipsis),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close_rounded, size: 18),
                            onPressed: () => ref.unpin(),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              Expanded(
                child: Stack(
                  children: [
                    if (!_loaded)
                      const Center(child: CircularProgressIndicator())
                    else if (_msgs.isEmpty)
                      _EmptyChat(title: _title(), isDm: _isDm)
                    else
                      ListView.builder(
                        controller: _scroll,
                        reverse: true,
                        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                        padding: const EdgeInsets.only(top: 8, bottom: 8),
                        itemCount: entries.length + 1,
                        itemBuilder: (_, i) {
                          if (i == entries.length) {
                            return _loadingMore
                                ? const Padding(
                                    padding: EdgeInsets.all(12),
                                    child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                                  )
                                : (!_hasMore
                                    ? Padding(
                                        padding: const EdgeInsets.all(16),
                                        child: Center(
                                          child: Text('🔒 Sohbetin başlangıcı',
                                              style: TextStyle(color: theme.hintColor, fontSize: 12)),
                                        ),
                                      )
                                    : const SizedBox(height: 40));
                          }
                          final e = entries[i];
                          if (e.day != null) return DayChip(e.day!);
                          final m = e.msg!;
                          final mine = m.senderUid == _myUid;
                          final key = _keys.putIfAbsent(m.id, () => GlobalKey());
                          final bubble = MessageBubble(
                            key: key,
                            m: m,
                            mine: mine,
                            myUid: _myUid,
                            showSender: !_isDm && e.firstOfGroup,
                            showAvatar: !_isDm,
                            groupedWithNext: e.groupedWithNext,
                            senderPhoto: appW.users[m.senderUid]?.photo,
                            readByOthers: m.readBy.any((u) => u != _myUid),
                            selected: _selected.contains(m.id),
                            highlighted: _highlightId == m.id,
                            compact: appW.compactMode,
                            translation: _translations[m.id],
                            onTapReply: m.replyTo == null ? null : () => _jumpTo(m.replyTo!.id),
                            onLongPress: selecting
                                ? () => setState(() => _selected.contains(m.id)
                                    ? _selected.remove(m.id)
                                    : _selected.add(m.id))
                                : () => _messageActions(m),
                            onTap: selecting
                                ? () => setState(() => _selected.contains(m.id)
                                    ? _selected.remove(m.id)
                                    : _selected.add(m.id))
                                : null,
                            onDoubleTap: selecting
                                ? null
                                : () {
                                    HapticFeedback.lightImpact();
                                    final cur = m.reactions[_myUid];
                                    ref.react(m.id, cur == '❤️' ? null : '❤️');
                                  },
                            onTapSender: mine
                                ? null
                                : () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (_) => UserProfileScreen(uid: m.senderUid))),
                            onTapReactions: () => _showReactions(m),
                          );
                          if (selecting) return bubble;
                          return Dismissible(
                            key: ValueKey('swipe_${m.id}'),
                            direction: DismissDirection.startToEnd,
                            dismissThresholds: const {DismissDirection.startToEnd: 0.25},
                            confirmDismiss: (_) async {
                              HapticFeedback.selectionClick();
                              setState(() {
                                _replyTo = m;
                                _editing = null;
                              });
                              _focus.requestFocus();
                              return false;
                            },
                            background: Padding(
                              padding: const EdgeInsets.only(left: 20),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Icon(Icons.reply_rounded, color: theme.colorScheme.primary),
                              ),
                            ),
                            child: bubble,
                          );
                        },
                      ),
                    if (_showJump)
                      Positioned(
                        right: 14,
                        bottom: 12,
                        child: Badge(
                          isLabelVisible: _newWhileUp > 0,
                          label: Text('$_newWhileUp'),
                          child: FloatingActionButton.small(
                            heroTag: 'jump',
                            onPressed: () => _scroll.animateTo(0,
                                duration: const Duration(milliseconds: 300), curve: Curves.easeOut),
                            child: const Icon(Icons.keyboard_double_arrow_down_rounded),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (_typing.isNotEmpty && !_searching)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                    child: _TypingBubble(label: _isDm ? '' : _typing.join(', ')),
                  ),
                ),
              if (!joined)
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: () => app.joinRoom(widget.chatId),
                        icon: const Icon(Icons.login_rounded),
                        label: const Text('Odaya katıl'),
                      ),
                    ),
                  ),
                )
              else if (!_searching && !selecting)
                _composer(theme),
              if (_showEmoji && joined)
                EmojiPanel(
                  onPick: (e) {
                    final sel = _input.selection;
                    final text = _input.text;
                    final start = sel.isValid ? sel.start : text.length;
                    final end = sel.isValid ? sel.end : text.length;
                    _input.value = TextEditingValue(
                      text: text.replaceRange(start, end, e),
                      selection: TextSelection.collapsed(offset: start + e.length),
                    );
                  },
                  onBackspace: () {
                    final t = _input.text;
                    if (t.isEmpty) return;
                    final chars = t.characters;
                    _input.text = chars.skipLast(1).toString();
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showReactions(ChatMessage m) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final e in m.reactions.entries)
              ListTile(
                leading: Avatar(
                    name: app.users[e.key]?.username ?? '?', photo: app.users[e.key]?.photo, size: 38),
                title: Text(e.key == _myUid ? 'Sen' : (app.users[e.key]?.username ?? 'Kullanıcı')),
                subtitle: e.key == _myUid ? const Text('Kaldırmak için dokun') : null,
                trailing: Text(e.value, style: const TextStyle(fontSize: 24)),
                onTap: e.key == _myUid
                    ? () {
                        Navigator.pop(ctx);
                        ref.react(m.id, null);
                      }
                    : null,
              ),
          ],
        ),
      ),
    );
  }

  Widget _composer(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    final hasText = _input.text.trim().isNotEmpty;
    return Material(
      color: theme.colorScheme.surface,
      child: SafeArea(
        top: false,
        bottom: !_showEmoji,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_replyTo != null || _editing != null)
              Container(
                padding: const EdgeInsets.fromLTRB(14, 8, 4, 0),
                child: Row(
                  children: [
                    Icon(_editing != null ? Icons.edit_rounded : Icons.reply_rounded,
                        color: theme.colorScheme.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _editing != null
                                ? 'Mesajı düzenle'
                                : '${_replyTo!.senderUid == _myUid ? 'Kendine' : _replyTo!.sender} yanıt',
                            style: TextStyle(
                                fontWeight: FontWeight.w700, color: theme.colorScheme.primary, fontSize: 13),
                          ),
                          Text(
                            (_editing ?? _replyTo)!.previewText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: theme.hintColor, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => setState(() {
                        if (_editing != null) _input.clear();
                        _replyTo = null;
                        _editing = null;
                      }),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
              child: _recording
                  ? Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.delete_outline_rounded, color: QColors.danger),
                          onPressed: () => _stopRecording(send: false),
                        ),
                        const _RecDot(),
                        const SizedBox(width: 8),
                        Text(formatDuration(_recSec),
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text('Kaydediliyor…', style: TextStyle(color: theme.hintColor)),
                        ),
                        _SendButton(icon: Icons.send_rounded, onTap: () => _stopRecording(send: true)),
                      ],
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        IconButton(
                          icon: Icon(_showEmoji ? Icons.keyboard_rounded : Icons.emoji_emotions_outlined),
                          color: theme.colorScheme.primary,
                          onPressed: () {
                            if (_showEmoji) {
                              _focus.requestFocus();
                            } else {
                              FocusScope.of(context).unfocus();
                            }
                            setState(() => _showEmoji = !_showEmoji);
                          },
                        ),
                        Expanded(
                          child: Container(
                            decoration: BoxDecoration(
                              color: isDark ? QColors.darkCard : const Color(0xFFEFEDF8),
                              borderRadius: BorderRadius.circular(24),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: _input,
                                    focusNode: _focus,
                                    minLines: 1,
                                    maxLines: 6,
                                    textCapitalization: TextCapitalization.sentences,
                                    keyboardType: TextInputType.multiline,
                                    textInputAction:
                                        app.enterToSend ? TextInputAction.send : TextInputAction.newline,
                                    onSubmitted: app.enterToSend ? (_) => _send() : null,
                                    onTap: () {
                                      if (_showEmoji) setState(() => _showEmoji = false);
                                    },
                                    decoration: const InputDecoration(
                                      hintText: 'Mesaj yaz…',
                                      filled: false,
                                      isDense: true,
                                      contentPadding: EdgeInsets.fromLTRB(16, 12, 4, 12),
                                      border: InputBorder.none,
                                      enabledBorder: InputBorder.none,
                                      focusedBorder: InputBorder.none,
                                    ),
                                  ),
                                ),
                                if (!hasText && _editing == null)
                                  IconButton(
                                    icon: const Icon(Icons.attach_file_rounded),
                                    color: theme.hintColor,
                                    onPressed: _attachSheet,
                                  ),
                                if (!hasText && _editing == null)
                                  IconButton(
                                    icon: const Icon(Icons.photo_camera_rounded),
                                    color: theme.hintColor,
                                    onPressed: () => _pickImage(ImageSource.camera),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        hasText || _editing != null
                            ? _SendButton(
                                icon: _editing != null ? Icons.check_rounded : Icons.send_rounded,
                                onTap: _send,
                              )
                            : _SendButton(icon: Icons.mic_rounded, onTap: _startRecording),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _SendButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 46,
        height: 46,
        decoration: const BoxDecoration(shape: BoxShape.circle, gradient: QColors.bubble),
        child: Icon(icon, color: Colors.white, size: 22),
      ),
    );
  }
}

class _AttachButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _AttachButton({required this.icon, required this.label, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            CircleAvatar(radius: 28, backgroundColor: color, child: Icon(icon, color: Colors.white, size: 26)),
            const SizedBox(height: 6),
            Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

class _RecDot extends StatefulWidget {
  const _RecDot();

  @override
  State<_RecDot> createState() => _RecDotState();
}

class _RecDotState extends State<_RecDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 700))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _c,
      child: const CircleAvatar(radius: 6, backgroundColor: QColors.danger),
    );
  }
}

class _TypingBubble extends StatefulWidget {
  final String label;
  const _TypingBubble({required this.label});

  @override
  State<_TypingBubble> createState() => _TypingBubbleState();
}

class _TypingBubbleState extends State<_TypingBubble> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF241C47) : Colors.white,
            borderRadius: BorderRadius.circular(18),
          ),
          child: AnimatedBuilder(
            animation: _c,
            builder: (_, __) => Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(3, (i) {
                final t = ((_c.value * 3) - i).clamp(0.0, 1.0).toDouble();
                final y = t < 0.5 ? t * 2 : (1 - t) * 2;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Transform.translate(
                    offset: Offset(0, -4 * y),
                    child: CircleAvatar(
                      radius: 3.5,
                      backgroundColor: Theme.of(context).hintColor,
                    ),
                  ),
                );
              }),
            ),
          ),
        ),
        if (widget.label.isNotEmpty) ...[
          const SizedBox(width: 8),
          Flexible(
            child: Text(widget.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
          ),
        ],
      ],
    );
  }
}

class _EmptyChat extends StatelessWidget {
  final String title;
  final bool isDm;
  const _EmptyChat({required this.title, required this.isDm});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('👋', style: TextStyle(fontSize: 56)),
            const SizedBox(height: 12),
            Text(
              isDm ? '$title ile sohbete başla' : '$title odasına hoş geldin',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text('İlk mesajı sen gönder!', style: TextStyle(color: Theme.of(context).hintColor)),
          ],
        ),
      ),
    );
  }
}
