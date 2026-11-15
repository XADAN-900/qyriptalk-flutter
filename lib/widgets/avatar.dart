import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../core/utils.dart';

/// Profil/oda görseli; görsel yoksa baş harfli renkli daire.
class Avatar extends StatelessWidget {
  final String? photo;
  final String name;
  final double size;
  final bool online;
  final bool isGroup;
  final bool ring;

  const Avatar({
    super.key,
    required this.name,
    this.photo,
    this.size = 48,
    this.online = false,
    this.isGroup = false,
    this.ring = false,
  });

  static const _palette = [
    [Color(0xFF6A5CFF), Color(0xFF9D6BFF)],
    [Color(0xFF0A84FF), Color(0xFF39C3FF)],
    [Color(0xFFFF4F8B), Color(0xFFFF8A65)],
    [Color(0xFF00B894), Color(0xFF55EFC4)],
    [Color(0xFFFF9F43), Color(0xFFFECA57)],
    [Color(0xFF8E44AD), Color(0xFFE056FD)],
    [Color(0xFF1E90FF), Color(0xFF6A5CFF)],
  ];

  @override
  Widget build(BuildContext context) {
    final bytes = MediaCache.bytes(photo);
    final colors = _palette[name.hashCode.abs() % _palette.length];
    Widget inner;
    if (bytes != null) {
      inner = ClipOval(
        child: Image.memory(
          bytes,
          width: size,
          height: size,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          cacheWidth: (size * 3).round(),
          errorBuilder: (_, __, ___) => _fallback(colors),
        ),
      );
    } else {
      inner = _fallback(colors);
    }
    if (ring) {
      inner = Container(
        padding: const EdgeInsets.all(2.5),
        decoration: const BoxDecoration(shape: BoxShape.circle, gradient: QColors.brand),
        child: Container(
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Theme.of(context).scaffoldBackgroundColor,
          ),
          child: inner,
        ),
      );
    }
    if (!online) return inner;
    final dot = size * 0.28;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        inner,
        Positioned(
          right: 0,
          bottom: 0,
          child: Container(
            width: dot,
            height: dot,
            decoration: BoxDecoration(
              color: QColors.online,
              shape: BoxShape.circle,
              border: Border.all(
                color: Theme.of(context).scaffoldBackgroundColor,
                width: size * 0.05 + 1,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _fallback(List<Color> colors) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            colors: colors,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: isGroup
            ? Icon(Icons.groups_rounded, color: Colors.white, size: size * 0.52)
            : Text(
                initialsOf(name),
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: size * 0.38,
                ),
              ),
      );
}

/// Marka gradyanlı başlık metni.
class GradientText extends StatelessWidget {
  final String text;
  final TextStyle style;
  const GradientText(this.text, {super.key, required this.style});

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback: (r) => QColors.brand.createShader(r),
      blendMode: BlendMode.srcIn,
      child: Text(text, style: style),
    );
  }
}
