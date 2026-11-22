import 'package:flutter/material.dart';
import 'package:qyriptalk/core/i18n.dart';
import 'package:flutter/services.dart';

class QColors {
  static const Color primary = Color(0xFF6A5CFF);
  static const Color blue = Color(0xFF0A84FF);
  static const Color violet = Color(0xFF8E3BFF);
  static const Color pink = Color(0xFFFF4F8B);
  static const Color online = Color(0xFF31C46C);
  static const Color darkBg = Color(0xFF07041A);
  static const Color darkSurface = Color(0xFF120D2B);
  static const Color darkCard = Color(0xFF1B1538);
  static const Color lightBg = Color(0xFFF6F5FB);
  static const Color danger = Color(0xFFFF4757);

  /// Messenger tarzı gönderilen mesaj gradyanı.
  static const LinearGradient brand = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [blue, violet, pink],
  );

  static const LinearGradient bubble = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF2F7BFF), Color(0xFF7B4DFF)],
  );
}

class AppTheme {
  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: QColors.primary,
      brightness: Brightness.light,
    ).copyWith(primary: QColors.primary, surface: Colors.white);
    return _base(scheme).copyWith(
      scaffoldBackgroundColor: QColors.lightBg,
    );
  }

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: QColors.primary,
      brightness: Brightness.dark,
    ).copyWith(
      primary: const Color(0xFF8B80FF),
      surface: QColors.darkSurface,
    );
    return _base(scheme).copyWith(
      scaffoldBackgroundColor: QColors.darkBg,
    );
  }

  static ThemeData _base(ColorScheme scheme) {
    final isDark = scheme.brightness == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: scheme.brightness,
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
        backgroundColor: isDark ? QColors.darkBg : QColors.lightBg,
        foregroundColor: isDark ? Colors.white : const Color(0xFF14112B),
        titleTextStyle: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.4,
          color: isDark ? Colors.white : const Color(0xFF14112B),
        ),
        systemOverlayStyle:
            isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? QColors.darkCard : const Color(0xFFEDEBF7),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: scheme.primary, width: 1.4),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 50),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: isDark ? QColors.darkSurface : Colors.white,
        indicatorColor: scheme.primary.withValues(alpha: 0.18),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        height: 68,
      ),
      dividerTheme: DividerThemeData(
        color: isDark ? Colors.white10 : Colors.black12,
        thickness: 0.6,
        space: 0.6,
      ),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: CupertinoPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      }),
    );
  }
}

void showSnack(BuildContext context, String message, {bool error = false}) {
  final m = ScaffoldMessenger.maybeOf(context);
  if (m == null) return;
  m.hideCurrentSnackBar();
  m.showSnackBar(SnackBar(
    content: Text(message),
    backgroundColor: error ? QColors.danger : null,
    duration: const Duration(seconds: 3),
  ));
}

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmText = 'Tamam',
  bool destructive = false,
}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const T('Vazgeç'),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: QColors.danger,
                  minimumSize: const Size(64, 40))
              : FilledButton.styleFrom(minimumSize: const Size(64, 40)),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmText),
        ),
      ],
    ),
  );
  return r == true;
}

Future<String?> promptText(
  BuildContext context, {
  required String title,
  String? hint,
  String initial = '',
  bool obscure = false,
  String confirmText = 'Kaydet',
  int maxLines = 1,
}) async {
  final c = TextEditingController(text: initial);
  final r = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        obscureText: obscure,
        maxLines: obscure ? 1 : maxLines,
        decoration: InputDecoration(hintText: hint),
        onSubmitted: maxLines == 1 ? (v) => Navigator.pop(ctx, v) : null,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const T('Vazgeç'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(64, 40)),
          onPressed: () => Navigator.pop(ctx, c.text),
          child: Text(confirmText),
        ),
      ],
    ),
  );
  return r;
}
