import 'package:flutter/material.dart';
import 'package:qyriptalk/core/i18n.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../core/utils.dart';
import '../models/models.dart';
import '../services/app_state.dart';
import '../services/call_service.dart';
import '../widgets/avatar.dart';

class CallsTab extends StatelessWidget {
  const CallsTab({super.key});

  Future<void> _callBack(BuildContext context, CallLogEntry c) async {
    final id = c.targetChatId;
    if (id == null) return;
    final err = await context.read<CallService>().startCall(
          isDm: c.targetIsDm,
          chatId: id,
          chatTitle: c.title,
        );
    if (err != null && context.mounted) showSnack(context, err, error: true);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final log = app.callLog;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const T('Aramalar'),
        actions: [
          if (log.isNotEmpty)
            IconButton(
              tooltip: 'Geçmişi temizle',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: () async {
                final ok = await confirmDialog(context,
                    title: 'Arama geçmişi',
                    message: 'Tüm arama geçmişi bu cihazdan silinsin mi?',
                    confirmText: 'Temizle',
                    destructive: true);
                if (ok) app.clearCallLog();
              },
            ),
        ],
      ),
      body: log.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.call_rounded, size: 72, color: theme.colorScheme.primary.withValues(alpha: 0.5)),
                    const SizedBox(height: 14),
                    const T('Henüz arama yok',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    T(
                      'Bir sohbetin üstündeki telefon simgesine dokunarak sesli arama başlat.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: theme.hintColor),
                    ),
                  ],
                ),
              ),
            )
          : ListView.builder(
              itemCount: log.length,
              itemBuilder: (_, i) {
                final c = log[i];
                final color = c.missed ? QColors.danger : theme.hintColor;
                final icon = c.outgoing
                    ? Icons.call_made_rounded
                    : (c.missed ? Icons.call_missed_rounded : Icons.call_received_rounded);
                final userPhoto = c.targetIsDm && c.targetChatId != null && app.uid != null
                    ? app.users[otherUidFromDm(c.targetChatId!, app.uid!)]?.photo
                    : app.rooms[c.targetChatId]?.logo;
                return ListTile(
                  leading: Avatar(name: c.title, photo: userPhoto, size: 48, isGroup: c.isGroup),
                  title: Text(c.title,
                      style: TextStyle(
                          fontWeight: FontWeight.w600, color: c.missed ? QColors.danger : null)),
                  subtitle: Row(
                    children: [
                      Icon(icon, size: 16, color: color),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          '${formatChatListTime(c.ts)} ${formatClock(c.ts)}'
                          '${c.durationSec > 0 ? ' · ${formatDuration(c.durationSec)}' : ''}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  trailing: IconButton(
                    icon: Icon(Icons.call_rounded, color: theme.colorScheme.primary),
                    onPressed: () => _callBack(context, c),
                  ),
                );
              },
            ),
    );
  }
}
