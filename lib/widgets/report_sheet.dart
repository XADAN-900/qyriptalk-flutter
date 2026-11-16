import 'package:flutter/material.dart';

/// Şikayet sebebi seçtirir (yöneticiye iletilir). Vazgeçilirse null döner.
Future<String?> pickReportReason(BuildContext context, {String title = 'Şikayet et'}) async {
  const reasons = [
    'Spam ya da reklam',
    'Uygunsuz / müstehcen içerik',
    'Taciz ya da zorbalık',
    'Nefret söylemi',
    'Sahte hesap / dolandırıcılık',
    'Şiddet ya da tehlikeli içerik',
  ];
  final r = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 6, 20, 8),
            child: Text('Şikayetin sadece yöneticiye gider. Kimin şikayet ettiği karşı tarafa gösterilmez.',
                textAlign: TextAlign.center),
          ),
          for (final x in reasons)
            ListTile(
              leading: const Icon(Icons.flag_outlined),
              title: Text(x),
              onTap: () => Navigator.pop(ctx, x),
            ),
          ListTile(
            leading: const Icon(Icons.edit_note_rounded),
            title: const Text('Diğer'),
            onTap: () async {
              final c = TextEditingController();
              final v = await showDialog<String>(
                context: ctx,
                builder: (d) => AlertDialog(
                  title: const Text('Şikayet sebebi'),
                  content: TextField(controller: c, autofocus: true, maxLines: 3, maxLength: 300),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(d), child: const Text('Vazgeç')),
                    TextButton(onPressed: () => Navigator.pop(d, c.text.trim()), child: const Text('Gönder')),
                  ],
                ),
              );
              if (v != null && v.isNotEmpty && ctx.mounted) Navigator.pop(ctx, v);
            },
          ),
        ]),
      ),
    ),
  );
  return r;
}
