import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/strings.dart';
import '../services/app_state.dart';

/// Kayıt/giriş sonrası bir kez gösterilen dil seçim ekranı.
class LanguageSetupScreen extends StatelessWidget {
  const LanguageSetupScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final s = S.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 8),
                Image.asset('assets/logo_splash.png', width: 84, height: 84),
                const SizedBox(height: 18),
                Text(s.chooseLanguage,
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text('Dilini seç · Choose your language',
                    style: TextStyle(color: Theme.of(context).hintColor)),
                const SizedBox(height: 14),
                Flexible(
                  child: SingleChildScrollView(
                    child: LanguagePicker(
                      selected: app.languageCode,
                      onSelected: (code) => app.setLanguage(code),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
