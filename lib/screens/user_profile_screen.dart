import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../core/utils.dart';
import '../services/app_state.dart';
import '../services/call_service.dart';
import '../widgets/avatar.dart';
import 'chat_screen.dart';
import 'media_viewer.dart';

class UserProfileScreen extends StatelessWidget {
  final String uid;
  final bool fromChat;
  const UserProfileScreen({super.key, required this.uid, this.fromChat = false});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final u = app.users[uid];
    final theme = Theme.of(context);
    if (u == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('Kullanıcı bulunamadı')));
    }
    final me = app.uid;
    final dmId = me == null ? null : dmIdFor(me, uid);
    final dmKey = dmId == null ? '' : 'dm:$dmId';

    return Scaffold(
      appBar: AppBar(),
      body: ListView(
        children: [
          const SizedBox(height: 8),
          Center(
            child: GestureDetector(
              onTap: u.photo == null
                  ? null
                  : () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ImageViewerScreen(dataUrl: u.photo!, title: u.username),
                        ),
                      ),
              child: Hero(
                tag: 'avatar_$uid',
                child: Avatar(name: u.username, photo: u.photo, size: 120, online: app.onlineVisible(u)),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Center(
            child: Text(u.username, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text(
              app.presenceText(u),
              style: TextStyle(color: app.onlineVisible(u) ? QColors.online : theme.hintColor),
            ),
          ),
          const SizedBox(height: 20),
          if (uid != me)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _Action(
                  icon: Icons.chat_bubble_rounded,
                  label: 'Mesaj',
                  onTap: () {
                    if (dmId == null) return;
                    if (fromChat) {
                      Navigator.pop(context);
                    } else {
                      Navigator.push(context,
                          MaterialPageRoute(builder: (_) => ChatScreen(isDm: true, chatId: dmId)));
                    }
                  },
                ),
                const SizedBox(width: 14),
                _Action(
                  icon: Icons.call_rounded,
                  label: 'Ara',
                  onTap: () async {
                    if (dmId == null) return;
                    final err = await context
                        .read<CallService>()
                        .startCall(isDm: true, chatId: dmId, chatTitle: u.username);
                    if (err != null && context.mounted) showSnack(context, err, error: true);
                  },
                ),
                const SizedBox(width: 14),
                _Action(
                  icon: app.isMuted(dmKey)
                      ? Icons.notifications_active_rounded
                      : Icons.notifications_off_rounded,
                  label: app.isMuted(dmKey) ? 'Sesi aç' : 'Sessiz',
                  onTap: () => app.toggleMute(dmKey),
                ),
              ],
            ),
          const SizedBox(height: 20),
          if (u.bio.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.info_outline_rounded),
              title: const Text('Hakkında'),
              subtitle: Text(u.bio),
            ),
          if (u.createdAt > 0)
            ListTile(
              leading: const Icon(Icons.calendar_month_outlined),
              title: const Text('Katılma tarihi'),
              subtitle: Text(DateFormat('d MMMM y', 'tr_TR')
                  .format(DateTime.fromMillisecondsSinceEpoch(u.createdAt))),
            ),
          if (u.role != 'user')
            ListTile(
              leading: const Icon(Icons.verified_user_outlined),
              title: const Text('Rol'),
              subtitle: Text(u.role == 'admin' ? 'Yönetici' : 'Moderatör'),
            ),
        ],
      ),
    );
  }
}

class _Action extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _Action({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        width: 92,
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          children: [
            Icon(icon, color: theme.colorScheme.primary),
            const SizedBox(height: 6),
            Text(label, style: TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
