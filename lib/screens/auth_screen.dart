import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../services/app_state.dart';
import '../widgets/avatar.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _pass2 = TextEditingController();
  bool _register = false;
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (_register && _pass.text != _pass2.text) {
      setState(() => _error = 'Şifreler eşleşmiyor.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final app = context.read<AppState>();
    final err = _register
        ? await app.register(_user.text, _pass.text)
        : await app.login(_user.text, _pass.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
    });
  }

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
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 104,
                        height: 104,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(30),
                          boxShadow: [
                            BoxShadow(
                              color: QColors.primary.withValues(alpha: 0.35),
                              blurRadius: 30,
                              offset: const Offset(0, 12),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(30),
                          child: Image.asset('assets/logo.png', fit: BoxFit.cover),
                        ),
                      ),
                    ),
                    const SizedBox(height: 22),
                    const Center(
                      child: GradientText(
                        'Qyriptalk',
                        style: TextStyle(fontSize: 38, fontWeight: FontWeight.w900, letterSpacing: -1),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _register
                          ? 'Hesap oluştur, sohbete hemen başla.'
                          : 'Arkadaşlarınla anında, güvenle konuş.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Theme.of(context).hintColor, fontSize: 15),
                    ),
                    const SizedBox(height: 32),
                    TextField(
                      controller: _user,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.username],
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.alternate_email_rounded),
                        hintText: 'Kullanıcı adı',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _pass,
                      obscureText: _obscure,
                      textInputAction: _register ? TextInputAction.next : TextInputAction.done,
                      onSubmitted: (_) => _register ? null : _submit(),
                      autofillHints: const [AutofillHints.password],
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.lock_outline_rounded),
                        hintText: 'Şifre',
                        suffixIcon: IconButton(
                          icon: Icon(_obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                          onPressed: () => setState(() => _obscure = !_obscure),
                        ),
                      ),
                    ),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 250),
                      child: _register
                          ? Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: TextField(
                                controller: _pass2,
                                obscureText: _obscure,
                                onSubmitted: (_) => _submit(),
                                decoration: const InputDecoration(
                                  prefixIcon: Icon(Icons.lock_reset_rounded),
                                  hintText: 'Şifre (tekrar)',
                                ),
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: QColors.danger.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.error_outline, color: QColors.danger, size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(_error!, style: const TextStyle(color: QColors.danger)),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 22),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: QColors.brand,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.transparent,
                          shadowColor: Colors.transparent,
                        ),
                        onPressed: _busy ? null : _submit,
                        child: _busy
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white),
                              )
                            : Text(_register ? 'Kayıt ol' : 'Giriş yap',
                                style: const TextStyle(color: Colors.white)),
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                                _register = !_register;
                                _error = null;
                              }),
                      child: Text(_register
                          ? 'Zaten hesabın var mı? Giriş yap'
                          : 'Hesabın yok mu? Kayıt ol'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
