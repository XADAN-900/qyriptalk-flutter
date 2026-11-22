import 'package:flutter/material.dart';
import '../services/app_state.dart';
import 'package:provider/provider.dart';

/// Çok dilli metinler. `S.of(context).get('key')` veya kısayol getter'larla kullanılır.
/// Bir anahtar seçili dilde yoksa Türkçe'ye, o da yoksa anahtarın kendisine düşer.
class S {
  final String lang;
  const S(this.lang);

  static S of(BuildContext context) =>
      S(context.watch<AppState>().languageCode);

  static String langName(String code) => _langNames[code] ?? code;

  static const Map<String, String> _langNames = {
    'tr': 'Türkçe',
    'en': 'English',
    'fr': 'Français',
    'es': 'Español',
    'pt': 'Português',
    'ru': 'Русский',
    'ar': 'العربية',
  };

  String get(String key) {
    final row = _t[key];
    if (row == null) return key;
    return row[lang] ?? row['tr'] ?? key;
  }

  // Kısayollar (sık kullanılanlar)
  String get settings => get('settings');
  String get language => get('language');
  String get chooseLanguage => get('chooseLanguage');
  String get translate => get('translate');
  String get showOriginal => get('showOriginal');
  String get translating => get('translating');
  String get translateFailed => get('translateFailed');
  String get save => get('save');
  String get cancel => get('cancel');
  String get continueLbl => get('continue');

  static const Map<String, Map<String, String>> _t = {
    'settings': {'tr': 'Ayarlar', 'en': 'Settings', 'fr': 'Paramètres', 'es': 'Ajustes', 'pt': 'Definições', 'ru': 'Настройки', 'ar': 'الإعدادات'},
    'language': {'tr': 'Dil', 'en': 'Language', 'fr': 'Langue', 'es': 'Idioma', 'pt': 'Idioma', 'ru': 'Язык', 'ar': 'اللغة'},
    'chooseLanguage': {'tr': 'Dilini seç', 'en': 'Choose your language', 'fr': 'Choisissez votre langue', 'es': 'Elige tu idioma', 'pt': 'Escolhe o teu idioma', 'ru': 'Выберите язык', 'ar': 'اختر لغتك'},
    'translate': {'tr': 'Çevir', 'en': 'Translate', 'fr': 'Traduire', 'es': 'Traducir', 'pt': 'Traduzir', 'ru': 'Перевести', 'ar': 'ترجمة'},
    'showOriginal': {'tr': 'Orijinali göster', 'en': 'Show original', 'fr': "Afficher l'original", 'es': 'Ver original', 'pt': 'Ver original', 'ru': 'Показать оригинал', 'ar': 'إظهار الأصل'},
    'translating': {'tr': 'Çevriliyor…', 'en': 'Translating…', 'fr': 'Traduction…', 'es': 'Traduciendo…', 'pt': 'A traduzir…', 'ru': 'Перевод…', 'ar': 'جارٍ الترجمة…'},
    'translateFailed': {'tr': 'Çeviri başarısız', 'en': 'Translation failed', 'fr': 'Échec de la traduction', 'es': 'Error de traducción', 'pt': 'Falha na tradução', 'ru': 'Не удалось перевести', 'ar': 'فشلت الترجمة'},
    'save': {'tr': 'Kaydet', 'en': 'Save', 'fr': 'Enregistrer', 'es': 'Guardar', 'pt': 'Guardar', 'ru': 'Сохранить', 'ar': 'حفظ'},
    'cancel': {'tr': 'İptal', 'en': 'Cancel', 'fr': 'Annuler', 'es': 'Cancelar', 'pt': 'Cancelar', 'ru': 'Отмена', 'ar': 'إلغاء'},
    'alreadyYourLanguage': {'tr': 'Zaten senin dilinde', 'en': 'Already in your language', 'fr': 'Déjà dans votre langue', 'es': 'Ya está en tu idioma', 'pt': 'Já está no teu idioma', 'ru': 'Уже на вашем языке', 'ar': 'بلغتك بالفعل'},
    'continue': {'tr': 'Devam', 'en': 'Continue', 'fr': 'Continuer', 'es': 'Continuar', 'pt': 'Continuar', 'ru': 'Продолжить', 'ar': 'متابعة'},
  };
}

/// Dil seçimi için ortak liste widget'ı (kayıt ve ayarlarda kullanılır).
class LanguagePicker extends StatelessWidget {
  final String selected;
  final ValueChanged<String> onSelected;
  const LanguagePicker({super.key, required this.selected, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final code in AppState.kLanguages)
          ListTile(
            onTap: () => onSelected(code),
            title: Text(S.langName(code)),
            trailing: selected == code
                ? const Icon(Icons.check_rounded, color: Color(0xFF6C4CF1))
                : null,
          ),
      ],
    );
  }
}
