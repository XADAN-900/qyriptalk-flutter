import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/utils.dart';
import '../services/app_state.dart';
import '../widgets/avatar.dart';
import 'chat_screen.dart';
import 'rooms_tab.dart';
import 'user_profile_screen.dart';

class NewChatScreen extends StatefulWidget {
  const NewChatScreen({super.key});

  @override
  State<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends State<NewChatScreen> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final users = app.users.values.where((u) => u.uid != app.uid).where((u) {
      if (_q.isEmpty) return true;
      return u.username.toLowerCase().contains(_q.toLowerCase());
    }).toList()
      ..sort((a, b) {
        if (a.isOnline != b.isOnline) return a.isOnline ? -1 : 1;
        return a.username.toLowerCase().compareTo(b.username.toLowerCase());
      });

    return Scaffold(
      appBar: AppBar(title: const Text('Yeni sohbet')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              autofocus: false,
              onChanged: (v) => setState(() => _q = v.trim()),
              decoration: const InputDecoration(
                hintText: 'Kişi ara',
                prefixIcon: Icon(Icons.search_rounded),
                isDense: true,
              ),
            ),
          ),
          ListTile(
            leading: const CircleAvatar(child: Icon(Icons.group_add_rounded)),
            title: const Text('Yeni oda oluştur', style: TextStyle(fontWeight: FontWeight.w600)),
            onTap: () => showCreateRoomSheet(context),
          ),
          ListTile(
            leading: const CircleAvatar(child: Icon(Icons.qr_code_scanner_rounded)),
            title: const Text('QR kod tara', style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: const Text('Oda daveti ya da arkadaşının profil kodu'),
            onTap: () => scanQrFlow(context),
          ),
          ListTile(
            leading: const CircleAvatar(child: Icon(Icons.link_rounded)),
            title: const Text('Davet bağlantısıyla katıl', style: TextStyle(fontWeight: FontWeight.w600)),
            onTap: () => joinByInviteDialog(context),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('${users.length} kişi',
                  style: TextStyle(color: Theme.of(context).hintColor, fontWeight: FontWeight.w600)),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: users.length,
              itemBuilder: (_, i) {
                final u = users[i];
                return ListTile(
                  leading: Avatar(name: u.username, photo: u.photo, size: 46, online: u.isOnline),
                  title: Text(u.username, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(u.bio.isNotEmpty ? u.bio : u.statusText,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: IconButton(
                    icon: const Icon(Icons.info_outline_rounded),
                    onPressed: () => Navigator.push(context,
                        MaterialPageRoute(builder: (_) => UserProfileScreen(uid: u.uid))),
                  ),
                  onTap: () {
                    final me = app.uid;
                    if (me == null) return;
                    Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ChatScreen(isDm: true, chatId: dmIdFor(me, u.uid)),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
