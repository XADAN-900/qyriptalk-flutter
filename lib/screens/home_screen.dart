import 'dart:async';
import 'package:qyriptalk/core/i18n.dart';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../core/utils.dart';
import '../models/models.dart';
import '../services/app_state.dart';
import '../services/native_bridge.dart';
import '../widgets/avatar.dart';
import 'calls_tab.dart';
import 'chat_screen.dart';
import 'new_chat_screen.dart';
import 'rooms_tab.dart';
import 'settings_tab.dart';

void openChat(BuildContext context, {required bool isDm, required String chatId}) {
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => ChatScreen(isDm: isDm, chatId: chatId),
  ));
}

void openDmWith(BuildContext context, String otherUid) {
  final me = context.read<AppState>().uid;
  if (me == null || otherUid == me) return;
  openChat(context, isDm: true, chatId: dmIdFor(me, otherUid));
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;
  StreamSubscription<String>? _openSub;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    _askBackgroundOnce();
    _openSub = app.openChatRequests.stream.listen((key) {
      if (!mounted) return;
      if (key.startsWith('dm:')) {
        openChat(context, isDm: true, chatId: key.substring(3));
      } else if (key.startsWith('room:')) {
        openChat(context, isDm: false, chatId: key.substring(5));
      }
    });
  }

  /// İlk girişte bir kez: tam ekran arama izni ve pil kısıtlaması (WhatsApp gibi çalışsın diye).
  Future<void> _askBackgroundOnce() async {
    final app = context.read<AppState>();
    if (app.prefs.getBool('askedBackground') == true) return;
    await Future.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    final fullOk = await NativeBridge.canUseFullScreen();
    final battOk = await NativeBridge.isIgnoringBattery();
    await app.prefs.setBool('askedBackground', true);
    if ((fullOk && battOk) || !mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.notifications_active_rounded, size: 40),
        title: const T('Aramaları kaçırma'),
        content: const T(
          'Uygulama kapalıyken ve ekran kilitliyken de mesaj bildirimleri ve zil sesli, tam ekran '
          'aramalar gelsin diye iki izin gerekiyor. Açılan ekranlarda Qyriptalk\'a izin ver.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const T('Sonra')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(64, 40)),
            onPressed: () async {
              Navigator.pop(ctx);
              if (!battOk) await NativeBridge.requestIgnoreBattery();
              if (!fullOk) await NativeBridge.openFullScreenSettings();
            },
            child: const T('İzin ver'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _openSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final unread = app.totalUnread;
    final missed = app.callLog.where((c) => c.missed && c.ts > (app.prefs.getInt('callsSeenAt') ?? 0)).length;
    return Scaffold(
      body: Column(
        children: [
          if (!app.connected)
            Material(
              color: QColors.danger,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: const [
                      Icon(Icons.wifi_off_rounded, color: Colors.white, size: 16),
                      SizedBox(width: 8),
                      T('İnternet yok',
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ),
            ),
          Expanded(
            child: IndexedStack(
              index: _tab,
              children: const [ChatsTab(), RoomsTab(), CallsTab(), SettingsTab()],
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) {
          if (i == 2) app.prefs.setInt('callsSeenAt', DateTime.now().millisecondsSinceEpoch);
          setState(() => _tab = i);
        },
        destinations: [
          NavigationDestination(
            icon: Badge(
              isLabelVisible: unread > 0,
              label: Text(unread > 99 ? '99+' : '$unread'),
              child: const Icon(Icons.chat_bubble_outline_rounded),
            ),
            selectedIcon: Badge(
              isLabelVisible: unread > 0,
              label: Text(unread > 99 ? '99+' : '$unread'),
              child: const Icon(Icons.chat_bubble_rounded),
            ),
            label: 'Sohbetler',
          ),
          const NavigationDestination(
            icon: Icon(Icons.groups_outlined),
            selectedIcon: Icon(Icons.groups_rounded),
            label: 'Odalar',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: missed > 0 && _tab != 2,
              label: Text('$missed'),
              child: const Icon(Icons.call_outlined),
            ),
            selectedIcon: const Icon(Icons.call_rounded),
            label: 'Aramalar',
          ),
          NavigationDestination(
            icon: Avatar(name: app.username, photo: app.me?.photo, size: 26),
            label: 'Profil',
          ),
        ],
      ),
    );
  }
}

// ==========================================================================
// SOHBETLER
// ==========================================================================

class ChatsTab extends StatefulWidget {
  const ChatsTab({super.key});

  @override
  State<ChatsTab> createState() => _ChatsTabState();
}

class _ChatsTabState extends State<ChatsTab> {
  final _search = TextEditingController();
  String _q = '';
  int _filter = 0; // 0 tümü, 1 okunmamış, 2 kişiler, 3 odalar

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    var chats = app.chatSummaries();
    if (_q.isNotEmpty) {
      final q = _q.toLowerCase();
      chats = chats
          .where((c) =>
              c.title.toLowerCase().contains(q) ||
              (c.last?.previewText.toLowerCase().contains(q) ?? false))
          .toList();
    }
    if (_filter == 1) chats = chats.where((c) => c.unread > 0).toList();
    if (_filter == 2) chats = chats.where((c) => c.isDm).toList();
    if (_filter == 3) chats = chats.where((c) => !c.isDm).toList();

    final onlineUsers = app.users.values
        .where((u) => app.onlineVisible(u))
        .toList()
      ..sort((a, b) => a.username.toLowerCase().compareTo(b.username.toLowerCase()));
    final archivedCount = app.archivedCount;

    return Scaffold(
      floatingActionButton: FloatingActionButton(
        heroTag: 'newChat',
        onPressed: () => Navigator.push(
            context, MaterialPageRoute(builder: (_) => const NewChatScreen())),
        child: const Icon(Icons.edit_square),
      ),
      body: NestedScrollView(
        headerSliverBuilder: (context, _) => [
          SliverAppBar(
            floating: true,
            snap: true,
            title: const GradientText('Qyriptalk',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, letterSpacing: -0.8)),
            actions: [
              IconButton(
                tooltip: 'Yeni sohbet',
                icon: const Icon(Icons.person_add_alt_1_rounded),
                onPressed: () => Navigator.push(
                    context, MaterialPageRoute(builder: (_) => const NewChatScreen())),
              ),
            ],
          ),
        ],
        body: ListView(
          padding: const EdgeInsets.only(bottom: 96),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: TextField(
                controller: _search,
                onChanged: (v) => setState(() => _q = v.trim()),
                decoration: InputDecoration(
                  hintText: tr('Sohbetlerde ara'),
                  prefixIcon: const Icon(Icons.search_rounded),
                  isDense: true,
                  suffixIcon: _q.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () {
                            _search.clear();
                            setState(() => _q = '');
                          },
                        ),
                ),
              ),
            ),
            if (onlineUsers.isNotEmpty && _q.isEmpty)
              SizedBox(
                height: 98,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  itemCount: onlineUsers.length,
                  itemBuilder: (_, i) {
                    final u = onlineUsers[i];
                    return InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () => openDmWith(context, u.uid),
                      child: SizedBox(
                        width: 72,
                        child: Column(
                          children: [
                            const SizedBox(height: 6),
                            Avatar(name: u.username, photo: u.photo, size: 56, online: true),
                            const SizedBox(height: 6),
                            Text(
                              u.username,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            // Filtreler ekrana tam sığar (kaydırma gerekmez; büyük yazıda yazı küçülür).
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  for (final (i, label) in const [
                    (0, 'Tümü'),
                    (1, 'Okunmamış'),
                    (2, 'Kişiler'),
                    (3, 'Odalar'),
                  ])
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: _FilterChip(
                          label: label,
                          selected: _filter == i,
                          onTap: () => setState(() => _filter = i),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (archivedCount > 0 && _q.isEmpty && _filter == 0)
              ListTile(
                leading: const SizedBox(
                  width: 52,
                  child: Icon(Icons.archive_outlined),
                ),
                title: const T('Arşivlenmiş', style: TextStyle(fontWeight: FontWeight.w600)),
                trailing: Text('$archivedCount'),
                onTap: () => Navigator.push(
                    context, MaterialPageRoute(builder: (_) => const ArchivedChatsScreen())),
              ),
            if (chats.isEmpty && !app.chatsReady)
              const Padding(
                padding: EdgeInsets.only(top: 80),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (chats.isEmpty)
              _EmptyChats(searching: _q.isNotEmpty || _filter != 0)
            else
              for (final c in chats) ChatTile(chat: c),
          ],
        ),
      ),
    );
  }
}

class _EmptyChats extends StatelessWidget {
  final bool searching;
  const _EmptyChats({required this.searching});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 60, 32, 0),
      child: Column(
        children: [
          Icon(searching ? Icons.search_off_rounded : Icons.forum_outlined,
              size: 72, color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5)),
          const SizedBox(height: 16),
          Text(
            searching ? 'Sonuç yok' : 'Henüz sohbet yok',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            searching
                ? 'Farklı bir şey aramayı dene.'
                : 'Sağ alttaki düğmeyle birine yaz ya da Odalar sekmesinden bir odaya katıl.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).hintColor),
          ),
        ],
      ),
    );
  }
}

class ChatTile extends StatelessWidget {
  final ChatSummary chat;
  const ChatTile({super.key, required this.chat});

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final theme = Theme.of(context);
    final last = chat.last;
    final mine = last != null && last.senderUid == app.uid;
    String preview = last?.previewText ?? (chat.isDm ? '' : 'Odaya hoş geldin 👋');
    if (last != null && !chat.isDm && !mine) preview = '${last.sender}: $preview';
    final bold = chat.unread > 0;
    final read = last != null && mine && last.readBy.any((u) => u != app.uid);

    return InkWell(
      onTap: () => openChat(context, isDm: chat.isDm, chatId: chat.id),
      onLongPress: () => _options(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        child: Row(
          children: [
            Avatar(
              name: chat.title,
              photo: chat.photo,
              size: 56,
              online: chat.online,
              isGroup: !chat.isDm,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (chat.pinned)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: Icon(Icons.push_pin_rounded, size: 14, color: theme.hintColor),
                        ),
                      Expanded(
                        child: Text(
                          chat.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
                          ),
                        ),
                      ),
                      if (chat.muted)
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: Icon(Icons.notifications_off_outlined, size: 15, color: theme.hintColor),
                        ),
                      const SizedBox(width: 6),
                      Text(
                        formatChatListTime(chat.sortTs),
                        style: TextStyle(
                          fontSize: 12,
                          color: bold ? theme.colorScheme.primary : theme.hintColor,
                          fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      if (mine)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: Icon(
                            read ? Icons.done_all_rounded : Icons.done_rounded,
                            size: 16,
                            color: read ? QColors.blue : theme.hintColor,
                          ),
                        ),
                      Expanded(
                        child: Text(
                          preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: bold ? theme.textTheme.bodyLarge?.color : theme.hintColor,
                            fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
                          ),
                        ),
                      ),
                      if (chat.unread > 0)
                        Container(
                          margin: const EdgeInsets.only(left: 8),
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          constraints: const BoxConstraints(minWidth: 22),
                          decoration: BoxDecoration(
                            gradient: chat.muted ? null : QColors.bubble,
                            color: chat.muted ? theme.hintColor : null,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            chat.unread > 99 ? '99+' : '${chat.unread}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _options(BuildContext context) {
    final app = context.read<AppState>();
    final key = chat.key;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(app.isPinned(key) ? Icons.push_pin_outlined : Icons.push_pin_rounded),
              title: Text(app.isPinned(key) ? 'Sabitlemeyi kaldır' : 'Sohbeti sabitle'),
              onTap: () {
                app.togglePin(key);
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading: Icon(app.isMuted(key)
                  ? Icons.notifications_active_outlined
                  : Icons.notifications_off_outlined),
              title: Text(app.isMuted(key) ? 'Sesi aç' : 'Sessize al'),
              onTap: () {
                app.toggleMute(key);
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading: Icon(app.isArchived(key) ? Icons.unarchive_outlined : Icons.archive_outlined),
              title: Text(app.isArchived(key) ? 'Arşivden çıkar' : 'Arşivle'),
              onTap: () {
                app.toggleArchive(key);
                Navigator.pop(ctx);
              },
            ),
            if (!chat.isDm)
              ListTile(
                leading: const Icon(Icons.logout_rounded, color: QColors.danger),
                title: const T('Odadan ayrıl', style: TextStyle(color: QColors.danger)),
                onTap: () async {
                  Navigator.pop(ctx);
                  final ok = await confirmDialog(context,
                      title: 'Odadan ayrıl',
                      message: '"${chat.title}" odasından ayrılmak istiyor musun?',
                      confirmText: 'Ayrıl',
                      destructive: true);
                  if (ok) await app.leaveRoom(chat.id);
                },
              ),
          ],
        ),
      ),
    );
  }
}

class ArchivedChatsScreen extends StatelessWidget {
  const ArchivedChatsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final chats = context.watch<AppState>().chatSummaries(archived: true);
    return Scaffold(
      appBar: AppBar(title: const T('Arşivlenmiş')),
      body: chats.isEmpty
          ? const Center(child: T('Arşivde sohbet yok'))
          : ListView(children: [for (final c in chats) ChatTile(chat: c)]),
    );
  }
}


/// Sohbet filtresi düğmesi: dört tanesi ekrana eşit genişlikte sığar.
class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _FilterChip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: selected ? cs.secondaryContainer : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: selected ? Colors.transparent : cs.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 38,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: selected ? cs.onSecondaryContainer : cs.onSurface,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
