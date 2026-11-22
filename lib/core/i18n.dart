import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/translate.dart';

/// Tüm arayüz metinlerini çalışırken otomatik çeviren hafif katman.
///
/// Kaynak metinler Türkçe'dir. Seçili dil 'tr' ise metin olduğu gibi döner.
/// Başka bir dilde: önce kalıcı önbelleğe bakılır; yoksa Türkçe gösterilip
/// arka planda çeviri çekilir, önbelleğe yazılır ve arayüz tazelenir.
class I18n extends ChangeNotifier {
  I18n._();
  static final I18n I = I18n._();

  SharedPreferences? _prefs;
  String lang = 'tr';

  final Map<String, Map<String, String>> _cache = {}; // kaynak -> {dil: çeviri}
  final Set<String> _pending = {};
  bool _scheduled = false;

  Future<void> init(SharedPreferences prefs, String language) async {
    _prefs = prefs;
    lang = language;
    final raw = prefs.getString('i18nCache');
    if (raw != null) {
      try {
        final m = jsonDecode(raw) as Map;
        m.forEach((k, v) => _cache[k as String] = Map<String, String>.from(v as Map));
      } catch (_) {}
    }
  }

  void setLang(String l) {
    if (l == lang) return;
    lang = l;
    notifyListeners();
  }

  /// Kaynağı (Türkçe) seçili dile çevirir. Çeviri hazır değilse Türkçe döner
  /// ve çeviri arka planda çekilir.
  String tr(String src) {
    if (lang == 'tr' || src.trim().isEmpty) return src;
    final hit = _cache[src]?[lang];
    if (hit != null) return hit;
    _queue(src);
    return src;
  }

  void _queue(String src) {
    final key = '$lang\u0001$src';
    if (_pending.contains(key)) return;
    _pending.add(key);
    _schedule();
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    Future.delayed(const Duration(milliseconds: 220), _flush);
  }

  Future<void> _flush() async {
    _scheduled = false;
    if (_pending.isEmpty) return;
    final targetLang = lang;
    // Bu dildeki bekleyenleri al (en çok 25'er işleyelim).
    final items = _pending
        .where((k) => k.startsWith('$targetLang\u0001'))
        .take(25)
        .toList();
    var changed = false;
    for (final k in items) {
      _pending.remove(k);
      final src = k.substring(k.indexOf('\u0001') + 1);
      if (_cache[src]?[targetLang] != null) continue;
      final r = await Translate.translate(src, target: targetLang, source: 'tr');
      final out = r?['text'];
      if (out != null && out.isNotEmpty) {
        (_cache[src] ??= {})[targetLang] = out;
        changed = true;
      }
    }
    if (changed) {
      _persist();
      notifyListeners();
    }
    if (_pending.any((k) => k.startsWith('$targetLang\u0001'))) {
      _schedule();
    }
  }

  void _persist() {
    try {
      _prefs?.setString('i18nCache', jsonEncode(_cache));
    } catch (_) {}
  }
}

/// Kısa yardımcı: metni seçili dile çevir.
String tr(String src) => I18n.I.tr(src);

/// Çeviri hazır oldukça otomatik tazelenen metin widget'ı.
/// `Text(...)` yerine birebir kullanılır (aynı parametreler).
class T extends StatelessWidget {
  final String data;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;
  final bool? softWrap;
  final TextDirection? textDirection;
  final String? semanticsLabel;
  final StrutStyle? strutStyle;

  const T(
    this.data, {
    super.key,
    this.style,
    this.textAlign,
    this.maxLines,
    this.overflow,
    this.softWrap,
    this.textDirection,
    this.semanticsLabel,
    this.strutStyle,
  });

  @override
  Widget build(BuildContext context) {
    return Text(
      I18n.I.tr(data),
      style: style,
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: overflow,
      softWrap: softWrap,
      textDirection: textDirection,
      semanticsLabel: semanticsLabel,
      strutStyle: strutStyle,
    );
  }
}
