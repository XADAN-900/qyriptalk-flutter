import 'dart:convert';
import 'package:http/http.dart' as http;

/// Basit, anahtar gerektirmeyen metin çeviri servisi.
/// Google'ın herkese açık çeviri ucunu kullanır; sonuçlar bellekte önbeğe alınır.
class Translate {
  static final Map<String, String> _cache = {};

  /// Desteklenen diller (uygulama dilleriyle aynı).
  static const List<String> supported = ['tr', 'en', 'fr', 'es', 'pt', 'ru', 'ar'];

  /// [text]'i [target] diline çevirir. [source] 'auto' ise kaynağı kendisi bulur.
  /// Dönen kayıt: {'text': çeviri, 'src': algılanan kaynak dil}. Hata olursa null.
  static Future<Map<String, String>?> translate(
    String text, {
    required String target,
    String source = 'auto',
  }) async {
    final t = text.trim();
    if (t.isEmpty) return {'text': text, 'src': source};
    final key = '$source|$target|$t';
    final cached = _cache[key];
    if (cached != null) {
      final sep = cached.indexOf('\u0001');
      return {'text': cached.substring(sep + 1), 'src': cached.substring(0, sep)};
    }
    try {
      final uri = Uri.parse(
        'https://translate.googleapis.com/translate_a/single'
        '?client=gtx&sl=$source&tl=$target&dt=t&q=${Uri.encodeComponent(t)}',
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(utf8.decode(res.bodyBytes)) as List;
      final sb = StringBuffer();
      for (final seg in (data[0] as List)) {
        if (seg is List && seg.isNotEmpty && seg[0] != null) sb.write(seg[0]);
      }
      final out = sb.toString();
      final src = (data.length > 2 && data[2] is String) ? data[2] as String : source;
      _cache[key] = '$src\u0001$out';
      return {'text': out, 'src': src};
    } catch (_) {
      return null;
    }
  }
}
