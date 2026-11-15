import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../core/theme.dart';
import '../core/utils.dart';
import '../models/models.dart';
import '../services/app_state.dart';
import '../widgets/avatar.dart';
import 'user_profile_screen.dart';

class RoomInfoScreen extends StatefulWidget {
  final String roomId;
  const RoomInfoScreen({super.key, required this.roomId});

  @override
  State<RoomInfoScreen> createState() => _RoomInfoScreenState();
}

class _RoomInfoScreenState extends State<RoomInfoScreen> {
  Map<String, dynamic> _members = {};
  Map<String, dynamic> _banned = {};
  final List<StreamSubscription> _subs = [];

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    app.refreshRoom(widget.roomId);
    _subs.add(app.db.ref('rooms/${widget.roomId}/users').onValue.listen((e) {
      if (mounted) setState(() => _members = asMap(e.snapshot.value));
    }, onError: (_) {}));
    _subs.add(app.db.ref('rooms/${widget.roomId}/bannedUsers').onValue.listen((e) {
      if (mounted) setState(() => _banned = asMap(e.snapshot.value));
    }, onError: (_) {}));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  Future<void> _edit(AppState app, Room room) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.image_outlined),
            title: const Text('Oda logosunu değiştir'),
            onTap: () => Navigator.pop(ctx, 'logo'),
          ),
          ListTile(
            leading: const Icon(Icons.drive_file_rename_outline),
            title: const Text('Oda adını değiştir'),
            onTap: () => Navigator.pop(ctx, 'name'),
          ),
          ListTile(
            leading: const Icon(Icons.notes_rounded),
            title: const Text('Açıklamayı düzenle'),
            onTap: () => Navigator.pop(ctx, 'desc'),
          ),
          ListTile(
            leading: const Icon(Icons.lock_outline_rounded),
            title: Text(room.hasPassword ? 'Şifreyi değiştir / kaldır' : 'Şifre koy'),
            onTap: () => Navigator.pop(ctx, 'password'),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.visibility_off_outlined),
            title: const Text('Gizli oda'),
            value: room.isPrivate,
            onChanged: (v) => Navigator.pop(ctx, v ? 'private_on' : 'private_off'),
          ),
        ]),
      ),
    );
    if (action == null) return;
    final r = app.db.ref('rooms/${room.id}');
    switch (action) {
      case 'logo':
        final x = await ImagePicker()
            .pickImage(source: ImageSource.gallery, maxWidth: 512, maxHeight: 512, imageQuality: 80);
        if (x == null) return;
        final b = await x.readAsBytes();
        await r.child('logo').set(toDataUrl(b, 'image/jpeg'));
        break;
      case 'name':
        if (!mounted) return;
        final v = await promptText(context, title: 'Oda adı', initial: room.name);
        if (v == null || v.trim().length < 2) return;
        await r.child('name').set(v.trim());
        break;
      case 'desc':
        if (!mounted) return;
        final v = await promptText(context, title: 'Açıklama', initial: room.description, maxLines: 3);
        if (v == null) return;
        await r.child('description').set(v.trim().isEmpty ? null : v.trim());
        break;
      case 'password':
        if (!mounted) return;
        final v = await promptText(context,
            title: 'Oda şifresi', hint: 'Boş bırakırsan şifre kaldırılır', initial: room.password ?? '');
        if (v == null) return;
        await r.child('password').set(v.trim().isEmpty ? null : v.trim());
        break;
      case 'private_on':
        await r.child('isPrivate').set(true);
        break;
      case 'private_off':
        await r.child('isPrivate').set(false);
        break;
    }
    await app.refreshRoom(room.id);
  }

  Future<void> _memberActions(AppState app, String uid, String name) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: const Text('Profili görüntüle'),
            onTap: () => Navigator.pop(ctx, 'profile'),
          ),
          ListTile(
            leading: const Icon(Icons.person_remove_outlined, color: QColors.danger),
            title: const Text('Odadan çıkar', style: TextStyle(color: QColors.danger)),
            onTap: () => Navigator.pop(ctx, 'kick'),
          ),
          ListTile(
            leading: const Icon(Icons.block_rounded, color: QColors.danger),
            title: const Text('Yasakla', style: TextStyle(color: QColors.danger)),
            onTap: () => Navigator.pop(ctx, 'ban'),
          ),
        ]),
      ),
    );
    if (action == null || !mounted) return;
    if (action == 'profile') {
      Navigator.push(context, MaterialPageRoute(builder: (_) => UserProfileScreen(uid: uid)));
    } else if (action == 'kick') {
      await app.db.ref('rooms/${widget.roomId}/users/$uid').remove();
      if (mounted) showSnack(context, '$name odadan çıkarıldı.');
    } else if (action == 'ban') {
      final ok = await confirmDialog(context,
          title: 'Yasakla', message: '$name bu odaya bir daha katılamayacak.', confirmText: 'Yasakla', destructive: true);
      if (!ok) return;
      await app.db.ref('rooms/${widget.roomId}/bannedUsers/$uid').set(name);
      await app.db.ref('rooms/${widget.roomId}/users/$uid').remove();
      if (mounted) showSnack(context, '$name yasaklandı.');
    }
  }

  void _showQr(Room room) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(room.name, textAlign: TextAlign.center),
        content: SizedBox(
          width: 240,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                child: QrImageView(data: room.inviteLink, size: 210, backgroundColor: Colors.white),
              ),
              const SizedBox(height: 12),
              SelectableText(room.inviteLink, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Kapat'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final room = app.rooms[widget.roomId];
    final theme = Theme.of(context);
    if (room == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
    }
    final isOwner = room.createdBy == app.uid;
    final canManage = isOwner || (app.me?.isModerator ?? false);
    final key = 'room:${room.id}';
    final memberIds = _members.keys.toList()
      ..sort((a, b) {
        final ao = asBool(asMap(_members[a])['online']) || (app.users[a]?.isOnline ?? false);
        final bo = asBool(asMap(_members[b])['online']) || (app.users[b]?.isOnline ?? false);
        if (ao != bo) return ao ? -1 : 1;
        return (app.users[a]?.username ?? '').compareTo(app.users[b]?.username ?? '');
      });

    return Scaffold(
      appBar: AppBar(
        actions: [
          if (canManage)
            IconButton(icon: const Icon(Icons.edit_rounded), onPressed: () => _edit(app, room)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          Center(
            child: Hero(
              tag: 'room_${room.id}',
              child: Avatar(name: room.name, photo: room.logo, size: 110, isGroup: true, ring: true),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(room.name,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
                ),
                if (room.hasPassword) const Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.lock_rounded, size: 18)),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text(
              '${room.isPrivate ? 'Gizli oda' : 'Herkese açık oda'} · ${_members.length} üye',
              style: TextStyle(color: theme.hintColor),
            ),
          ),
          if (room.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
              child: Text(room.description, textAlign: TextAlign.center),
            ),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _Btn(
                icon: Icons.chat_bubble_rounded,
                label: 'Sohbet',
                onTap: () => Navigator.pop(context),
              ),
              const SizedBox(width: 12),
              _Btn(
                icon: app.isMuted(key) ? Icons.notifications_active_rounded : Icons.notifications_off_rounded,
                label: app.isMuted(key) ? 'Sesi aç' : 'Sessiz',
                onTap: () => app.toggleMute(key),
              ),
              const SizedBox(width: 12),
              _Btn(icon: Icons.qr_code_rounded, label: 'QR', onTap: () => _showQr(room)),
            ],
          ),
          const SizedBox(height: 12),
          ListTile(
            leading: const Icon(Icons.link_rounded),
            title: const Text('Davet bağlantısı'),
            subtitle: Text(room.inviteLink, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.copy_rounded),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: room.inviteLink));
                    showSnack(context, 'Davet bağlantısı kopyalandı.');
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.share_rounded),
                  onPressed: () => Share.share(
                      'Qyriptalk\'ta "${room.name}" odasına katıl!\n${room.inviteLink}'),
                ),
              ],
            ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Text('${_members.length} ÜYE',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12, color: theme.colorScheme.primary)),
          ),
          for (final uid in memberIds)
            Builder(builder: (_) {
              final u = app.users[uid];
              final name = u?.username ?? asStr(asMap(_members[uid])['username'], 'Kullanıcı');
              final online = u?.isOnline ?? asBool(asMap(_members[uid])['online']);
              return ListTile(
                leading: Avatar(name: name, photo: u?.photo, size: 44, online: online),
                title: Text(uid == app.uid ? '$name (sen)' : name,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(u?.bio.isNotEmpty == true ? u!.bio : (online ? 'çevrimiçi' : (u?.statusText ?? '')),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: uid == room.createdBy
                    ? Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(gradient: QColors.brand, borderRadius: BorderRadius.circular(10)),
                        child: const Text('Kurucu',
                            style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                      )
                    : null,
                onTap: uid == app.uid
                    ? null
                    : () => canManage && uid != room.createdBy
                        ? _memberActions(app, uid, name)
                        : Navigator.push(
                            context, MaterialPageRoute(builder: (_) => UserProfileScreen(uid: uid))),
              );
            }),
          if (canManage && _banned.isNotEmpty) ...[
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              child: Text('YASAKLILAR',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12, color: theme.colorScheme.error)),
            ),
            for (final e in _banned.entries)
              ListTile(
                leading: const Icon(Icons.block_rounded),
                title: Text(app.users[e.key]?.username ?? asStr(e.value, 'Kullanıcı')),
                trailing: TextButton(
                  onPressed: () => app.db.ref('rooms/${room.id}/bannedUsers/${e.key}').remove(),
                  child: const Text('Yasağı kaldır'),
                ),
              ),
          ],
          const Divider(),
          if (app.joinedRoomIds.contains(room.id) && !isOwner)
            ListTile(
              leading: const Icon(Icons.logout_rounded, color: QColors.danger),
              title: const Text('Odadan ayrıl', style: TextStyle(color: QColors.danger)),
              onTap: () async {
                final ok = await confirmDialog(context,
                    title: 'Odadan ayrıl', message: '"${room.name}" odasından ayrılınsın mı?', confirmText: 'Ayrıl', destructive: true);
                if (!ok) return;
                await app.leaveRoom(room.id);
                if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
              },
            ),
          if (isOwner)
            ListTile(
              leading: const Icon(Icons.delete_forever_rounded, color: QColors.danger),
              title: const Text('Odayı sil', style: TextStyle(color: QColors.danger)),
              subtitle: const Text('Tüm mesajlar kalıcı olarak silinir'),
              onTap: () async {
                final ok = await confirmDialog(context,
                    title: 'Odayı sil',
                    message: '"${room.name}" ve tüm mesajları kalıcı olarak silinecek. Emin misin?',
                    confirmText: 'Sil',
                    destructive: true);
                if (!ok) return;
                await app.deleteRoom(room.id);
                if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
              },
            ),
        ],
      ),
    );
  }
}

class _Btn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _Btn({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: 88,
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(children: [
          Icon(icon, color: c),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(color: c, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}
