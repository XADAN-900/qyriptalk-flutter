import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../core/utils.dart';
import '../models/models.dart';
import '../services/app_state.dart';
import '../widgets/avatar.dart';
import 'chat_screen.dart';
import 'home_screen.dart';
import 'qr_scan_screen.dart';
import 'user_profile_screen.dart';

/// Odaya katılma akışı: yasak kontrolü, şifre sorma, katıl ve aç.
Future<void> joinRoomFlow(BuildContext context, Room room) async {
  final app = context.read<AppState>();
  final uid = app.uid;
  if (uid == null) return;
  if (app.joinedRoomIds.contains(room.id)) {
    openChat(context, isDm: false, chatId: room.id);
    return;
  }
  final banned = await app.db.ref('rooms/${room.id}/bannedUsers/$uid').get();
  if (!context.mounted) return;
  if (banned.exists) {
    showSnack(context, 'Bu odaya erişimin kısıtlanmış.', error: true);
    return;
  }
  if (room.hasPassword && room.createdBy != uid) {
    final pw = await promptText(context,
        title: '"${room.name}" şifreli', hint: 'Oda şifresi', obscure: true, confirmText: 'Katıl');
    if (pw == null || !context.mounted) return;
    if (pw.trim() != room.password) {
      showSnack(context, 'Yanlış şifre.', error: true);
      return;
    }
  }
  await app.joinRoom(room.id);
  if (!context.mounted) return;
  showSnack(context, '${room.name} odasına katıldın 🎉');
  openChat(context, isDm: false, chatId: room.id);
}

/// Kişi profil QR kodunun öneki (oda davetlerinden ayırmak için).
const String kUserQrPrefix = 'Qyriptalk/kisi/';

/// QR'dan ya da yapıştırılan bağlantıdan gelen kodu işler: oda daveti ya da kişi profili.
Future<void> handleScannedCode(BuildContext context, String code) async {
  final app = context.read<AppState>();
  final c = code.trim();
  final ui = c.indexOf(kUserQrPrefix);
  if (ui >= 0) {
    final uid = c.substring(ui + kUserQrPrefix.length).split(RegExp(r'[/?#\s]')).first;
    if (uid == app.uid) {
      showSnack(context, 'Bu senin kendi QR kodun 🙂');
      return;
    }
    if (uid.isEmpty || !app.users.containsKey(uid)) {
      showSnack(context, 'Bu QR koduna ait kullanıcı bulunamadı.', error: true);
      return;
    }
    Navigator.push(context, MaterialPageRoute(builder: (_) => UserProfileScreen(uid: uid)));
    return;
  }
  final parsed = AppState.parseInvite(c);
  if (parsed == null) {
    showSnack(context, 'Bu bir Qyriptalk davet kodu değil.', error: true);
    return;
  }
  final room = await app.refreshRoom(parsed.id);
  if (!context.mounted) return;
  if (room == null) {
    showSnack(context, 'Oda bulunamadı ya da silinmiş.', error: true);
    return;
  }
  await joinRoomFlow(context, room);
}

Future<void> scanQrFlow(BuildContext context) async {
  final code = await Navigator.push<String>(
    context,
    MaterialPageRoute(fullscreenDialog: true, builder: (_) => const QrScanScreen()),
  );
  if (code == null || !context.mounted) return;
  await handleScannedCode(context, code);
}

/// Davetle katıl: QR tara ya da bağlantıyı yapıştır.
Future<void> joinByInviteDialog(BuildContext context) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text('Odaya davetle katıl', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
        ),
        ListTile(
          leading: const Icon(Icons.qr_code_scanner_rounded),
          title: const Text('QR kod tara'),
          subtitle: const Text('Kamerayla ya da galerideki bir görselden'),
          onTap: () => Navigator.pop(ctx, 'qr'),
        ),
        ListTile(
          leading: const Icon(Icons.link_rounded),
          title: const Text('Davet bağlantısı gir'),
          subtitle: const Text('Qyriptalk/OdaAdı/OdaID'),
          onTap: () => Navigator.pop(ctx, 'link'),
        ),
      ]),
    ),
  );
  if (choice == null || !context.mounted) return;
  if (choice == 'qr') {
    await scanQrFlow(context);
    return;
  }
  final clip = await Clipboard.getData(Clipboard.kTextPlain);
  final initial = (clip?.text ?? '').contains('Qyriptalk/') ? clip!.text!.trim() : '';
  if (!context.mounted) return;
  final link = await promptText(context,
      title: 'Davet bağlantısı', hint: 'Qyriptalk/OdaAdı/OdaID', initial: initial, confirmText: 'Katıl');
  if (link == null || link.trim().isEmpty || !context.mounted) return;
  await handleScannedCode(context, link);
}

Future<void> showCreateRoomSheet(BuildContext context) async {
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _CreateRoomSheet(),
  );
}

class RoomsTab extends StatefulWidget {
  const RoomsTab({super.key});

  @override
  State<RoomsTab> createState() => _RoomsTabState();
}

class _RoomsTabState extends State<RoomsTab> {
  List<Room>? _rooms;
  bool _loading = false;
  String _q = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() => _loading = true);
    final list = await context.read<AppState>().discoverRooms();
    if (!mounted) return;
    setState(() {
      _rooms = list;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final mine = app.joinedRoomIds.map((id) => app.rooms[id]).whereType<Room>().toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final q = _q.toLowerCase();
    final discover = (_rooms ?? const <Room>[])
        .where((r) => !app.joinedRoomIds.contains(r.id))
        .where((r) => q.isEmpty || r.name.toLowerCase().contains(q))
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Odalar'),
        actions: [
          IconButton(
            tooltip: 'QR kod tara',
            icon: const Icon(Icons.qr_code_scanner_rounded),
            onPressed: () => scanQrFlow(context),
          ),
          IconButton(
            tooltip: 'Davet ile katıl',
            icon: const Icon(Icons.link_rounded),
            onPressed: () => joinByInviteDialog(context),
          ),
          IconButton(
            tooltip: 'Yenile',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _load,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'newRoom',
        onPressed: () => showCreateRoomSheet(context),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Oda oluştur'),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 100),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: TextField(
                onChanged: (v) => setState(() => _q = v.trim()),
                decoration: const InputDecoration(
                  hintText: 'Oda ara',
                  prefixIcon: Icon(Icons.search_rounded),
                  isDense: true,
                ),
              ),
            ),
            if (mine.isNotEmpty) ...[
              const _Section('Odalarım'),
              SizedBox(
                height: 116,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  itemCount: mine.length,
                  itemBuilder: (_, i) {
                    final r = mine[i];
                    return InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () => openChat(context, isDm: false, chatId: r.id),
                      child: SizedBox(
                        width: 84,
                        child: Column(
                          children: [
                            const SizedBox(height: 6),
                            Avatar(name: r.name, photo: r.logo, size: 64, isGroup: true, ring: true),
                            const SizedBox(height: 6),
                            Text(r.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
            const _Section('Keşfet'),
            if (_rooms == null || !app.chatsReady || (_loading && discover.isEmpty))
              const Padding(
                padding: EdgeInsets.all(40),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (discover.isEmpty)
              Padding(
                padding: const EdgeInsets.all(40),
                child: Column(
                  children: [
                    Icon(Icons.travel_explore_rounded,
                        size: 64, color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5)),
                    const SizedBox(height: 12),
                    const Text('Katılabileceğin yeni oda yok',
                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                    const SizedBox(height: 4),
                    Text('İlk odayı sen oluştur!', style: TextStyle(color: Theme.of(context).hintColor)),
                  ],
                ),
              )
            else
              for (final r in discover) _RoomCard(room: r, creator: app.users[r.createdBy]?.username),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String text;
  const _Section(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
        child: Text(text,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 13,
              letterSpacing: 0.6,
              color: Theme.of(context).colorScheme.primary,
            )),
      );
}

class _RoomCard extends StatelessWidget {
  final Room room;
  final String? creator;
  const _RoomCard({required this.room, this.creator});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      elevation: 0,
      color: theme.brightness == Brightness.dark ? QColors.darkCard : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        leading: Avatar(name: room.name, photo: room.logo, size: 50, isGroup: true),
        title: Row(
          children: [
            Flexible(
              child: Text(room.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
            if (room.hasPassword)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Icon(Icons.lock_rounded, size: 15, color: theme.hintColor),
              ),
          ],
        ),
        subtitle: Text(
          room.description.isNotEmpty
              ? room.description
              : (creator != null ? 'Kurucu: $creator' : 'Herkese açık oda'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: FilledButton.tonal(
          style: FilledButton.styleFrom(minimumSize: const Size(64, 36)),
          onPressed: () => joinRoomFlow(context, room),
          child: const Text('Katıl'),
        ),
      ),
    );
  }
}

class _CreateRoomSheet extends StatefulWidget {
  const _CreateRoomSheet();

  @override
  State<_CreateRoomSheet> createState() => _CreateRoomSheetState();
}

class _CreateRoomSheetState extends State<_CreateRoomSheet> {
  final _name = TextEditingController();
  final _desc = TextEditingController();
  final _pass = TextEditingController();
  bool _private = false;
  bool _busy = false;
  String? _logo;

  Future<void> _pickLogo() async {
    final x = await ImagePicker()
        .pickImage(source: ImageSource.gallery, maxWidth: 512, maxHeight: 512, imageQuality: 80);
    if (x == null) return;
    final b = await x.readAsBytes();
    setState(() => _logo = toDataUrl(b, 'image/jpeg'));
  }

  Future<void> _create() async {
    setState(() => _busy = true);
    final app = context.read<AppState>();
    try {
      final id = await app.createRoom(
        name: _name.text,
        password: _pass.text.trim(),
        isPrivate: _private,
        logoDataUrl: _logo,
        description: _desc.text.trim(),
      );
      if (!mounted) return;
      final nav = Navigator.of(context);
      nav.pop();
      nav.push(MaterialPageRoute(builder: (_) => ChatScreen(isDm: false, chatId: id)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showSnack(context, e.toString().replaceFirst('Exception: ', ''), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.of(context).viewInsets.bottom + 20),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Yeni oda', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
            const SizedBox(height: 16),
            Center(
              child: GestureDetector(
                onTap: _pickLogo,
                child: Stack(
                  children: [
                    Avatar(
                      name: _name.text.isEmpty ? 'Oda' : _name.text,
                      photo: _logo,
                      size: 88,
                      isGroup: _logo == null,
                    ),
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: CircleAvatar(
                        radius: 15,
                        backgroundColor: Theme.of(context).colorScheme.primary,
                        child: const Icon(Icons.camera_alt_rounded, size: 16, color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              maxLength: 40,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(hintText: 'Oda adı', prefixIcon: Icon(Icons.tag_rounded)),
            ),
            TextField(
              controller: _desc,
              maxLength: 120,
              decoration: const InputDecoration(
                  hintText: 'Açıklama (isteğe bağlı)', prefixIcon: Icon(Icons.notes_rounded)),
            ),
            TextField(
              controller: _pass,
              decoration: const InputDecoration(
                  hintText: 'Şifre (isteğe bağlı)', prefixIcon: Icon(Icons.lock_outline_rounded)),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _private,
              onChanged: (v) => setState(() => _private = v),
              title: const Text('Gizli oda'),
              subtitle: const Text('Keşfet listesinde görünmez, sadece davet bağlantısıyla katılınır.'),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _create,
              icon: _busy
                  ? const SizedBox(
                      width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.check_rounded),
              label: const Text('Oluştur'),
            ),
          ],
        ),
      ),
    );
  }
}
