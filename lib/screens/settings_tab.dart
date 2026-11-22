import 'package:flutter/material.dart';
import '../core/strings.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../core/theme.dart';
import '../core/utils.dart';
import '../services/app_state.dart';
import '../services/app_guard.dart';
import '../services/native_bridge.dart';
import '../widgets/avatar.dart';
import 'rooms_tab.dart';

class SettingsTab extends StatelessWidget {
  const SettingsTab({super.key});

  Future<void> _changePhoto(BuildContext context) async {
    final app = context.read<AppState>();
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Galeriden seç'),
              onTap: () => Navigator.pop(ctx, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Fotoğraf çek'),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
            if (app.me?.photo != null)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: QColors.danger),
                title: const Text('Fotoğrafı kaldır', style: TextStyle(color: QColors.danger)),
                onTap: () => Navigator.pop(ctx, 'remove'),
              ),
          ],
        ),
      ),
    );
    if (action == null) return;
    if (action == 'remove') {
      await app.updateProfile(removePhoto: true);
      return;
    }
    final x = await ImagePicker().pickImage(
      source: action == 'camera' ? ImageSource.camera : ImageSource.gallery,
      maxWidth: 512,
      maxHeight: 512,
      imageQuality: 82,
    );
    if (x == null) return;
    final b = await x.readAsBytes();
    await app.updateProfile(photoDataUrl: toDataUrl(b, 'image/jpeg'));
    if (context.mounted) showSnack(context, 'Profil fotoğrafı güncellendi.');
  }

  void _showMyQr(BuildContext context) {
    final app = context.read<AppState>();
    final code = '$kUserQrPrefix${app.uid}';
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        contentPadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Avatar(name: app.username, photo: app.me?.photo, size: 64, ring: true),
            const SizedBox(height: 10),
            Text(app.username, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)),
              child: QrImageView(data: code, size: 210, backgroundColor: Colors.white),
            ),
            const SizedBox(height: 10),
            Text('Qyriptalk\'ta "QR kod tara" ile okutulabilir',
                textAlign: TextAlign.center, style: TextStyle(color: Theme.of(ctx).hintColor, fontSize: 13)),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () => Share.share('Qyriptalk\'ta beni ekle: ${app.username}\n$code'),
            icon: const Icon(Icons.share_rounded),
            label: const Text('Paylaş'),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Kapat')),
        ],
      ),
    );
  }

  Future<void> _editBio(BuildContext context) async {
    final app = context.read<AppState>();
    final v = await promptText(context,
        title: 'Hakkımda', initial: app.me?.bio ?? '', hint: 'Kendinden bahset', maxLines: 3);
    if (v == null) return;
    await app.updateProfile(bio: v.trim());
  }

  Future<void> _changeUsername(BuildContext context) async {
    final app = context.read<AppState>();
    final v = await promptText(context, title: 'Kullanıcı adı', initial: app.username);
    if (v == null || v.trim() == app.username) return;
    final err = await app.changeUsername(v);
    if (context.mounted) showSnack(context, err ?? 'Kullanıcı adı güncellendi.', error: err != null);
  }

  Future<void> _migrateAll(BuildContext context) async {
    final app = context.read<AppState>();
    final ok = await confirmDialog(context,
        title: 'Hesapları taşı',
        message: 'Henüz taşınmamış tüm hesaplar Firebase güvenli girişine geçirilecek ve veritabanındaki '
            'açık şifreler silinecek. Kullanıcılar aynı kullanıcı adı ve şifreyle girmeye devam eder.',
        confirmText: 'Başlat');
    if (!ok || !context.mounted) return;
    final progress = ValueNotifier<String>('Hazırlanıyor…');
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(children: [
          const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.4)),
          const SizedBox(width: 16),
          Expanded(child: ValueListenableBuilder<String>(valueListenable: progress, builder: (_, v, __) => Text(v))),
        ]),
      ),
    );
    String msg;
    try {
      msg = await app.migrateAllAccounts((d, n) => progress.value = '$d / $n hesap');
    } catch (e) {
      msg = 'Taşıma başarısız: $e';
    }
    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Hesap taşıma'),
        content: Text(msg),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Tamam'))],
      ),
    );
  }

  Future<void> _changePassword(BuildContext context) async {
    final app = context.read<AppState>();
    final cur = await promptText(context, title: 'Mevcut şifre', obscure: true, confirmText: 'Devam');
    if (cur == null || !context.mounted) return;
    final next = await promptText(context, title: 'Yeni şifre', hint: 'En az 6 karakter', obscure: true);
    if (next == null) return;
    final err = await app.changePassword(cur, next);
    if (context.mounted) showSnack(context, err ?? 'Şifre değiştirildi.', error: err != null);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final me = app.me;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Profil')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          const SizedBox(height: 8),
          Center(
            child: GestureDetector(
              onTap: () => _changePhoto(context),
              child: Stack(
                children: [
                  Avatar(name: app.username, photo: me?.photo, size: 108, ring: true),
                  Positioned(
                    right: 4,
                    bottom: 4,
                    child: CircleAvatar(
                      radius: 17,
                      backgroundColor: theme.colorScheme.primary,
                      child: const Icon(Icons.camera_alt_rounded, size: 18, color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(app.username,
                    style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
                if (me != null && me.role != 'user')
                  Container(
                    margin: const EdgeInsets.only(left: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      gradient: QColors.brand,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      me.role == 'admin' ? 'Yönetici' : 'Moderatör',
                      style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Center(
            child: InkWell(
              onTap: () => _editBio(context),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
                child: Text(
                  (me?.bio.isNotEmpty ?? false) ? me!.bio : 'Hakkımda ekle…',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: theme.hintColor),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          _Group(title: 'Hesap', children: [
            ListTile(
              leading: const Icon(Icons.qr_code_2_rounded),
              title: const Text('QR kodum'),
              subtitle: const Text('Arkadaşın okutsun, seni hemen bulsun'),
              onTap: () => _showMyQr(context),
            ),
            ListTile(
              leading: const Icon(Icons.qr_code_scanner_rounded),
              title: const Text('QR kod tara'),
              subtitle: const Text('Oda daveti ya da profil kodu'),
              onTap: () => scanQrFlow(context),
            ),
            ListTile(
              leading: const Icon(Icons.alternate_email_rounded),
              title: const Text('Kullanıcı adı'),
              subtitle: Text(app.username),
              onTap: () => _changeUsername(context),
            ),
            ListTile(
              leading: const Icon(Icons.edit_note_rounded),
              title: const Text('Hakkımda'),
              onTap: () => _editBio(context),
            ),
            ListTile(
              leading: const Icon(Icons.key_rounded),
              title: const Text('Şifreyi değiştir'),
              onTap: () => _changePassword(context),
            ),
            if (me?.role == 'admin' || app.username.toLowerCase() == 'xadan')
              ListTile(
                leading: const Icon(Icons.admin_panel_settings_outlined),
                title: const Text('Tüm hesapları güvenli girişe taşı'),
                subtitle: const Text('Yönetici: açık şifreleri siler, herkesi Firebase güvenli girişine geçirir'),
                onTap: () => _migrateAll(context),
              ),
          ]),
          _Group(title: 'Görünüm', children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(value: ThemeMode.system, label: Text('Sistem'), icon: Icon(Icons.brightness_auto)),
                  ButtonSegment(value: ThemeMode.light, label: Text('Açık'), icon: Icon(Icons.light_mode)),
                  ButtonSegment(value: ThemeMode.dark, label: Text('Koyu'), icon: Icon(Icons.dark_mode)),
                ],
                selected: {app.themeMode},
                onSelectionChanged: (s) => app.setThemeMode(s.first),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.translate_rounded),
              title: Text(S.of(context).language),
              subtitle: Text(S.langName(app.languageCode)),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => showModalBottomSheet(
                context: context,
                showDragHandle: true,
                builder: (_) => SafeArea(
                  child: LanguagePicker(
                    selected: app.languageCode,
                    onSelected: (code) {
                      app.setLanguage(code);
                      Navigator.pop(context);
                    },
                  ),
                ),
              ),
            ),
          ]),
          _Group(title: 'Bildirimler', children: [
            SwitchListTile(
              secondary: const Icon(Icons.notifications_active_outlined),
              title: const Text('Mesaj bildirimleri'),
              value: app.notificationsEnabled,
              onChanged: (v) => app.setSetting('messageNotifications', v),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.volume_up_outlined),
              title: const Text('Bildirim sesi'),
              value: app.soundEnabled,
              onChanged: (v) => app.setSetting('soundNotifications', v),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.lock_outline_rounded),
              title: const Text('Kilit ekranında içerik'),
              subtitle: const Text('Kapalıysa sadece "Yeni mesaj" yazar'),
              value: app.lockscreenPreview,
              onChanged: (v) => app.setSetting('lockscreenPreview', v),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.record_voice_over_outlined),
              title: const Text('Gelen mesajları sesli oku'),
              value: app.speakMessages,
              onChanged: (v) => app.setSetting('speakMessages', v),
            ),
            ListTile(
              leading: const Icon(Icons.phone_in_talk_outlined),
              title: const Text('Tam ekran arama izni'),
              subtitle: const Text('Ekran kapalıyken gelen arama WhatsApp gibi tam ekran çalsın'),
              onTap: () async {
                final ok = await NativeBridge.canUseFullScreen();
                if (ok) {
                  if (context.mounted) showSnack(context, 'Tam ekran arama izni zaten açık ✅');
                } else {
                  await NativeBridge.openFullScreenSettings();
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.battery_saver_outlined),
              title: const Text('Arka planda çalışma'),
              subtitle: const Text('Pil kısıtlamasını kaldır; uygulama kapalıyken de mesaj ve arama gelsin'),
              onTap: () async {
                final ok = await NativeBridge.isIgnoringBattery();
                if (ok) {
                  if (context.mounted) showSnack(context, 'Pil kısıtlaması zaten kapalı ✅');
                } else {
                  await NativeBridge.requestIgnoreBattery();
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.tune_rounded),
              title: const Text('Telefon bildirim ayarları'),
              onTap: () => NativeBridge.openNotificationSettings(),
            ),
          ]),
          _Group(title: 'Sohbet', children: [
            SwitchListTile(
              secondary: const Icon(Icons.keyboard_return_rounded),
              title: const Text('Enter ile gönder'),
              value: app.enterToSend,
              onChanged: (v) => app.setSetting('enterToSend', v),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.done_all_rounded),
              title: const Text('Okundu bilgisi'),
              subtitle: const Text('Kapalıysa okuduğunu karşı taraf görmez'),
              value: app.showReadReceipts,
              onChanged: (v) => app.setSetting('showReadReceipts', v),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.translate_rounded),
              title: const Text('Gelen mesajları otomatik çevir'),
              value: app.autoTranslate,
              onChanged: (v) => app.setSetting('autoTranslate', v),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.density_small_rounded),
              title: const Text('Sıkı görünüm'),
              value: app.compactMode,
              onChanged: (v) => app.setSetting('compactMode', v),
            ),
          ]),
          _Group(title: 'Hakkında', children: [
            const ListTile(
              leading: Icon(Icons.info_outline_rounded),
              title: Text('Qyriptalk'),
              subtitle: Text('Sürüm 2.1 · derleme ${AppGuard.build}'),
            ),
            ListTile(
              leading: const Icon(Icons.logout_rounded, color: QColors.danger),
              title: const Text('Çıkış yap', style: TextStyle(color: QColors.danger)),
              onTap: () async {
                final ok = await confirmDialog(context,
                    title: 'Çıkış yap',
                    message: 'Hesabından çıkmak istediğine emin misin?',
                    confirmText: 'Çıkış yap',
                    destructive: true);
                if (ok) await app.logout();
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_forever_rounded, color: QColors.danger),
              title: const Text('Hesabımı sil', style: TextStyle(color: QColors.danger)),
              subtitle: const Text('Profilin, kullanıcı adın ve oda üyeliklerin kalıcı olarak silinir'),
              onTap: () async {
                final ok = await confirmDialog(context,
                    title: 'Hesabını sil',
                    message: 'Hesabın kalıcı olarak silinecek. Bu işlem geri alınamaz.',
                    confirmText: 'Devam',
                    destructive: true);
                if (!ok || !context.mounted) return;
                final pw = await promptText(context,
                    title: 'Şifreni yaz', hint: 'Onaylamak için şifren', obscure: true, confirmText: 'Hesabımı sil');
                if (pw == null || pw.isEmpty || !context.mounted) return;
                final err = await app.deleteMyAccount(pw);
                if (err != null && context.mounted) showSnack(context, err, error: true);
              },
            ),
          ]),
        ],
      ),
    );
  }
}

class _Group extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _Group({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 6, bottom: 6),
            child: Text(title.toUpperCase(),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                  color: theme.colorScheme.primary,
                )),
          ),
          Material(
            color: theme.brightness == Brightness.dark ? QColors.darkCard : Colors.white,
            borderRadius: BorderRadius.circular(18),
            clipBehavior: Clip.antiAlias,
            child: Column(children: children),
          ),
        ],
      ),
    );
  }
}
