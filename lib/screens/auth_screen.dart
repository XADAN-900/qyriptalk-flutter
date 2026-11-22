import 'dart:async';
import 'package:qyriptalk/core/i18n.dart';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../core/utils.dart';
import '../services/app_state.dart';
import '../widgets/avatar.dart';

/// Giriş ekranı + 3 adımlı kayıt (hesap → profil → hazırsın).
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool _register = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isDark
                ? const [Color(0xFF1A0F4D), QColors.darkBg]
                : const [Color(0xFFE6E1FF), QColors.lightBg],
          ),
        ),
        child: SafeArea(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: _register
                ? _RegisterFlow(
                    key: const ValueKey('reg'),
                    onBackToLogin: () => setState(() => _register = false),
                  )
                : _LoginView(
                    key: const ValueKey('login'),
                    onRegister: () => setState(() => _register = true),
                  ),
          ),
        ),
      ),
    );
  }
}

// ==========================================================================
// GİRİŞ
// ==========================================================================

class _LoginView extends StatefulWidget {
  final VoidCallback onRegister;
  const _LoginView({super.key, required this.onRegister});

  @override
  State<_LoginView> createState() => _LoginViewState();
}

class _LoginViewState extends State<_LoginView> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await context.read<AppState>().login(_user.text, _pass.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _Logo(),
              const SizedBox(height: 22),
              const Center(
                child: GradientText('Qyriptalk',
                    style: TextStyle(fontSize: 38, fontWeight: FontWeight.w900, letterSpacing: -1)),
              ),
              const SizedBox(height: 6),
              T(
                'Tekrar hoş geldin! Hesabına giriş yap.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).hintColor, fontSize: 15),
              ),
              const SizedBox(height: 32),
              TextField(
                controller: _user,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.username],
                decoration: InputDecoration(
                  prefixIcon: Icon(Icons.alternate_email_rounded),
                  hintText: tr('Kullanıcı adı'),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _pass,
                obscureText: _obscure,
                onSubmitted: (_) => _submit(),
                autofillHints: const [AutofillHints.password],
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.lock_outline_rounded),
                  hintText: tr('Şifre'),
                  suffixIcon: IconButton(
                    icon: Icon(_obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 14),
                _ErrorBox(_error!),
              ],
              const SizedBox(height: 22),
              _GradientButton(label: 'Giriş yap', busy: _busy, onTap: _submit),
              const SizedBox(height: 26),
              Row(children: [
                const Expanded(child: Divider()),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: T('Qyriptalk\'ta yeni misin?', style: TextStyle(color: Theme.of(context).hintColor)),
                ),
                const Expanded(child: Divider()),
              ]),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(64, 50),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
                onPressed: _busy ? null : widget.onRegister,
                icon: const Icon(Icons.person_add_alt_1_rounded),
                label: const T('Yeni hesap oluştur', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==========================================================================
// KAYIT (3 adım)
// ==========================================================================

class _RegisterFlow extends StatefulWidget {
  final VoidCallback onBackToLogin;
  const _RegisterFlow({super.key, required this.onBackToLogin});

  @override
  State<_RegisterFlow> createState() => _RegisterFlowState();
}

class _RegisterFlowState extends State<_RegisterFlow> {
  final _page = PageController();
  int _step = 0;

  // 1. adım
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _pass2 = TextEditingController();
  bool _obscure = true;
  Timer? _debounce;
  bool _checking = false;
  bool? _available;
  String? _userError;

  // 2. adım
  Uint8List? _photo;
  final _bio = TextEditingController();

  bool _busy = false;
  String? _error;

  static const _bioIdeas = [
    'Merhaba! Qyriptalk kullanıyorum 👋',
    'Müsaitim 💬',
    'Sadece acil durumlar 📵',
    'Kahve ve sohbet ☕',
    'Oyun zamanı 🎮',
  ];

  @override
  void initState() {
    super.initState();
    _user.addListener(_onUserChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _page.dispose();
    super.dispose();
  }

  void _onUserChanged() {
    final name = _user.text.trim();
    _debounce?.cancel();
    final err = name.isEmpty ? null : AppState.validateUsername(name);
    setState(() {
      _userError = err;
      _available = null;
      _checking = name.isNotEmpty && err == null;
    });
    if (name.isEmpty || err != null) return;
    _debounce = Timer(const Duration(milliseconds: 600), () async {
      bool taken;
      try {
        taken = await context.read<AppState>().isUsernameTaken(name);
      } catch (_) {
        if (mounted) setState(() => _checking = false);
        return;
      }
      if (!mounted || _user.text.trim() != name) return;
      setState(() {
        _checking = false;
        _available = !taken;
      });
    });
  }

  int get _strength {
    final p = _pass.text;
    var s = 0;
    if (p.length >= 6) s++;
    if (p.length >= 10) s++;
    if (RegExp(r'[0-9]').hasMatch(p) && RegExp(r'[A-Za-zçğıöşüÇĞİÖŞÜ]').hasMatch(p)) s++;
    if (RegExp(r'[^A-Za-z0-9çğıöşüÇĞİÖŞÜ]').hasMatch(p) || RegExp(r'[A-ZÇĞİÖŞÜ]').hasMatch(p)) s++;
    return s;
  }

  String? _step1Error() {
    final name = _user.text.trim();
    final v = AppState.validateUsername(name);
    if (v != null) return v;
    if (_available == false) return 'Bu kullanıcı adı zaten alınmış.';
    if (_pass.text.length < 6) return 'Şifre en az 6 karakter olmalı.';
    if (_pass.text != _pass2.text) return 'Şifreler eşleşmiyor.';
    return null;
  }

  void _go(int step) {
    FocusScope.of(context).unfocus();
    setState(() {
      _step = step;
      _error = null;
    });
    _page.animateToPage(step, duration: const Duration(milliseconds: 350), curve: Curves.easeOutCubic);
  }

  Future<void> _next() async {
    if (_step == 0) {
      final e = _step1Error();
      if (e != null) {
        setState(() => _error = e);
        return;
      }
      if (_available == null) {
        // Kontrol henüz bitmediyse şimdi kontrol et.
        setState(() => _busy = true);
        final taken = await context.read<AppState>().isUsernameTaken(_user.text);
        if (!mounted) return;
        setState(() {
          _busy = false;
          _available = !taken;
        });
        if (taken) {
          setState(() => _error = 'Bu kullanıcı adı zaten alınmış.');
          return;
        }
      }
      _go(1);
    } else if (_step == 1) {
      _go(2);
    } else {
      await _create();
    }
  }

  Future<void> _pickPhoto(ImageSource src) async {
    final x = await ImagePicker().pickImage(source: src, maxWidth: 512, maxHeight: 512, imageQuality: 82);
    if (x == null) return;
    final b = await x.readAsBytes();
    setState(() => _photo = b);
  }

  void _photoSheet() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const T('Galeriden seç'),
            onTap: () {
              Navigator.pop(ctx);
              _pickPhoto(ImageSource.gallery);
            },
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const T('Fotoğraf çek'),
            onTap: () {
              Navigator.pop(ctx);
              _pickPhoto(ImageSource.camera);
            },
          ),
          if (_photo != null)
            ListTile(
              leading: const Icon(Icons.delete_outline, color: QColors.danger),
              title: const T('Fotoğrafı kaldır', style: TextStyle(color: QColors.danger)),
              onTap: () {
                Navigator.pop(ctx);
                setState(() => _photo = null);
              },
            ),
        ]),
      ),
    );
  }

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await context.read<AppState>().register(
          _user.text,
          _pass.text,
          photoDataUrl: _photo == null ? null : toDataUrl(_photo!, 'image/jpeg'),
          bio: _bio.text,
        );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const titles = ['Hesabını oluştur', 'Profilini kişiselleştir', 'Her şey hazır!'];
    const subtitles = [
      'Arkadaşlarının seni bulacağı bir kullanıcı adı seç.',
      'Bir fotoğraf ve kısa bir açıklama ekle. İstersen sonra da değiştirebilirsin.',
      'Profilini kontrol et ve görünümü seç.',
    ];
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: _busy ? null : () => _step == 0 ? widget.onBackToLogin() : _go(_step - 1),
              ),
              Expanded(
                child: Row(
                  children: [
                    for (var i = 0; i < 3; i++)
                      Expanded(
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          height: 5,
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(3),
                            gradient: i <= _step ? QColors.brand : null,
                            color: i <= _step ? null : theme.dividerColor,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text('${_step + 1}/3', style: TextStyle(color: theme.hintColor, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(titles[_step], style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: -0.6)),
              const SizedBox(height: 6),
              Text(subtitles[_step], style: TextStyle(color: theme.hintColor, fontSize: 15)),
            ],
          ),
        ),
        Expanded(
          child: PageView(
            controller: _page,
            physics: const NeverScrollableScrollPhysics(),
            children: [_accountStep(theme), _profileStep(theme), _doneStep(theme)],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null) ...[_ErrorBox(_error!), const SizedBox(height: 12)],
              _GradientButton(
                label: _step == 2 ? 'Hesabı oluştur 🚀' : (_step == 1 && _photo == null && _bio.text.trim().isEmpty ? 'Şimdilik geç' : 'Devam'),
                busy: _busy,
                onTap: _next,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _accountStep(ThemeData theme) {
    final name = _user.text.trim();
    Widget? suffix;
    if (_checking) {
      suffix = const Padding(
        padding: EdgeInsets.all(14),
        child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    } else if (_available == true) {
      suffix = const Icon(Icons.check_circle_rounded, color: QColors.online);
    } else if (_available == false || (_userError != null && name.isNotEmpty)) {
      suffix = const Icon(Icons.error_rounded, color: QColors.danger);
    }
    String? helper;
    Color? helperColor;
    if (_userError != null && name.isNotEmpty) {
      helper = _userError;
      helperColor = QColors.danger;
    } else if (_available == true) {
      helper = '@$name kullanılabilir';
      helperColor = QColors.online;
    } else if (_available == false) {
      helper = 'Bu kullanıcı adı alınmış';
      helperColor = QColors.danger;
    }
    final strength = _strength;
    const labels = ['Çok zayıf', 'Zayıf', 'Orta', 'İyi', 'Güçlü'];
    const colors = [QColors.danger, QColors.danger, Color(0xFFFF9F43), Color(0xFF7BC67B), QColors.online];
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
      children: [
        TextField(
          controller: _user,
          textInputAction: TextInputAction.next,
          maxLength: 24,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.alternate_email_rounded),
            hintText: tr('Kullanıcı adı'),
            suffixIcon: suffix,
            counterText: '',
            helperText: helper,
            helperStyle: TextStyle(color: helperColor, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _pass,
          obscureText: _obscure,
          textInputAction: TextInputAction.next,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.lock_outline_rounded),
            hintText: tr('Şifre (en az 6 karakter)'),
            suffixIcon: IconButton(
              icon: Icon(_obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
        ),
        if (_pass.text.isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              for (var i = 0; i < 4; i++)
                Expanded(
                  child: Container(
                    height: 4,
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    decoration: BoxDecoration(
                      color: i < strength ? colors[strength] : theme.dividerColor,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              const SizedBox(width: 10),
              Text(labels[strength], style: TextStyle(color: colors[strength], fontSize: 12, fontWeight: FontWeight.w700)),
            ],
          ),
        ],
        const SizedBox(height: 14),
        TextField(
          controller: _pass2,
          obscureText: _obscure,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _next(),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.lock_reset_rounded),
            hintText: tr('Şifre (tekrar)'),
            suffixIcon: _pass2.text.isEmpty
                ? null
                : Icon(
                    _pass2.text == _pass.text ? Icons.check_circle_rounded : Icons.error_rounded,
                    color: _pass2.text == _pass.text ? QColors.online : QColors.danger,
                  ),
          ),
        ),
        const SizedBox(height: 18),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline_rounded, size: 18, color: theme.hintColor),
            const SizedBox(width: 8),
            Expanded(
              child: T(
                'Şifreni kimseyle paylaşma. Başka sitelerde kullandığın bir şifreyi burada kullanmamanı öneririz.',
                style: TextStyle(color: theme.hintColor, fontSize: 13),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _profileStep(ThemeData theme) {
    final name = _user.text.trim().isEmpty ? '?' : _user.text.trim();
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 12),
      children: [
        Center(
          child: GestureDetector(
            onTap: _photoSheet,
            child: Stack(
              children: [
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: const BoxDecoration(shape: BoxShape.circle, gradient: QColors.brand),
                  child: _photo == null
                      ? Avatar(name: name, size: 128)
                      : ClipOval(child: Image.memory(_photo!, width: 128, height: 128, fit: BoxFit.cover)),
                ),
                Positioned(
                  right: 4,
                  bottom: 4,
                  child: CircleAvatar(
                    radius: 20,
                    backgroundColor: theme.colorScheme.primary,
                    child: Icon(_photo == null ? Icons.add_a_photo_rounded : Icons.edit_rounded,
                        color: Colors.white, size: 20),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: TextButton(
            onPressed: _photoSheet,
            child: Text(_photo == null ? 'Profil fotoğrafı ekle' : 'Fotoğrafı değiştir'),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _bio,
          maxLength: 140,
          maxLines: 3,
          minLines: 2,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            prefixIcon: Icon(Icons.edit_note_rounded),
            hintText: tr('Hakkımda — kendinden kısaca bahset'),
          ),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final idea in _bioIdeas)
              ActionChip(
                label: Text(idea),
                onPressed: () => setState(() {
                  _bio.text = idea;
                  _bio.selection = TextSelection.collapsed(offset: idea.length);
                }),
              ),
          ],
        ),
      ],
    );
  }

  Widget _doneStep(ThemeData theme) {
    final app = context.watch<AppState>();
    final isDark = theme.brightness == Brightness.dark;
    final name = _user.text.trim();
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: isDark ? QColors.darkCard : Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [BoxShadow(color: QColors.primary.withValues(alpha: 0.15), blurRadius: 30, offset: const Offset(0, 10))],
          ),
          child: Column(
            children: [
              _photo == null
                  ? Avatar(name: name.isEmpty ? '?' : name, size: 96, ring: true)
                  : Container(
                      padding: const EdgeInsets.all(3),
                      decoration: const BoxDecoration(shape: BoxShape.circle, gradient: QColors.brand),
                      child: ClipOval(child: Image.memory(_photo!, width: 96, height: 96, fit: BoxFit.cover)),
                    ),
              const SizedBox(height: 12),
              Text(name, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text(
                _bio.text.trim().isEmpty ? 'Hakkımda eklenmedi' : _bio.text.trim(),
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.hintColor),
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  Icon(Icons.circle, size: 10, color: QColors.online),
                  SizedBox(width: 6),
                  T('çevrimiçi', style: TextStyle(color: QColors.online, fontWeight: FontWeight.w600)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        const T('Görünüm', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
        const SizedBox(height: 10),
        SegmentedButton<ThemeMode>(
          segments: const [
            ButtonSegment(value: ThemeMode.system, label: T('Sistem'), icon: Icon(Icons.brightness_auto)),
            ButtonSegment(value: ThemeMode.light, label: T('Açık'), icon: Icon(Icons.light_mode)),
            ButtonSegment(value: ThemeMode.dark, label: T('Koyu'), icon: Icon(Icons.dark_mode)),
          ],
          selected: {app.themeMode},
          onSelectionChanged: (s) => app.setThemeMode(s.first),
        ),
        const SizedBox(height: 20),
        _Feature(icon: Icons.chat_bubble_rounded, text: 'Arkadaşlarınla özel mesajlaş, odalara katıl'),
        _Feature(icon: Icons.call_rounded, text: 'Ücretsiz sesli ve grup araması yap'),
        _Feature(icon: Icons.mic_rounded, text: 'Sesli mesaj, fotoğraf, video ve dosya gönder'),
        _Feature(icon: Icons.notifications_active_rounded, text: 'Bildirim izni sorulursa "İzin ver"e dokun'),
      ],
    );
  }
}

// ==========================================================================
// Ortak parçalar
// ==========================================================================

class _Feature extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Feature({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: QColors.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: QColors.primary, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(text)),
          ],
        ),
      );
}

class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          width: 104,
          height: 104,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(30),
            boxShadow: [
              BoxShadow(color: QColors.primary.withValues(alpha: 0.35), blurRadius: 30, offset: const Offset(0, 12)),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(30),
            child: Image.asset('assets/logo.png', fit: BoxFit.cover),
          ),
        ),
      );
}

class _ErrorBox extends StatelessWidget {
  final String text;
  const _ErrorBox(this.text);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: QColors.danger.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            const Icon(Icons.error_outline, color: QColors.danger, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: const TextStyle(color: QColors.danger))),
          ],
        ),
      );
}

class _GradientButton extends StatelessWidget {
  final String label;
  final bool busy;
  final VoidCallback onTap;
  const _GradientButton({required this.label, required this.busy, required this.onTap});

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(gradient: QColors.brand, borderRadius: BorderRadius.circular(16)),
        child: FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.transparent, shadowColor: Colors.transparent),
          onPressed: busy ? null : onTap,
          child: busy
              ? const SizedBox(
                  width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
              : Text(label, style: const TextStyle(color: Colors.white)),
        ),
      );
}
