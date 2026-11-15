import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/theme.dart';
import '../core/utils.dart';
import '../models/models.dart';
import '../screens/media_viewer.dart';
import 'avatar.dart';
import 'voice_player.dart';

class MessageBubble extends StatelessWidget {
  final ChatMessage m;
  final bool mine;
  final bool showSender;
  final bool showAvatar;
  final bool groupedWithNext;
  final String? senderPhoto;
  final bool readByOthers;
  final bool selected;
  final bool highlighted;
  final bool compact;
  final String? translation;
  final String myUid;
  final VoidCallback? onTapReply;
  final VoidCallback? onLongPress;
  final VoidCallback? onDoubleTap;
  final VoidCallback? onTap;
  final VoidCallback? onTapSender;
  final VoidCallback? onTapReactions;

  const MessageBubble({
    super.key,
    required this.m,
    required this.mine,
    required this.myUid,
    this.showSender = false,
    this.showAvatar = false,
    this.groupedWithNext = false,
    this.senderPhoto,
    this.readByOthers = false,
    this.selected = false,
    this.highlighted = false,
    this.compact = false,
    this.translation,
    this.onTapReply,
    this.onLongPress,
    this.onDoubleTap,
    this.onTap,
    this.onTapSender,
    this.onTapReactions,
  });

  static const double _r = 20;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final otherColor = isDark ? const Color(0xFF241C47) : Colors.white;
    final textColor = mine ? Colors.white : (isDark ? Colors.white : const Color(0xFF16132B));
    final maxW = MediaQuery.of(context).size.width * 0.76;

    final radius = BorderRadius.only(
      topLeft: const Radius.circular(_r),
      topRight: const Radius.circular(_r),
      bottomLeft: Radius.circular(!mine && groupedWithNext ? 6 : _r),
      bottomRight: Radius.circular(mine && groupedWithNext ? 6 : _r),
    );

    final mediaOnly = (m.type == 'image' || m.type == 'video') && m.caption.isEmpty && m.replyTo == null;

    final content = <Widget>[];
    if (m.forwarded) {
      content.add(Padding(
        padding: const EdgeInsets.only(bottom: 3),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.shortcut_rounded, size: 14, color: textColor.withValues(alpha: 0.7)),
          const SizedBox(width: 3),
          Text('İletildi',
              style: TextStyle(
                  fontSize: 12, fontStyle: FontStyle.italic, color: textColor.withValues(alpha: 0.7))),
        ]),
      ));
    }
    if (showSender && !mine) {
      content.add(GestureDetector(
        onTap: onTapSender,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Text(
            m.sender,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: _nameColor(m.sender),
            ),
          ),
        ),
      ));
    }
    if (m.replyTo != null) {
      content.add(_ReplyQuote(reply: m.replyTo!, mine: mine, onTap: onTapReply));
    }
    content.add(_body(context, textColor, maxW));
    if (translation != null && translation!.isNotEmpty) {
      content.add(Container(
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.only(top: 6),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: textColor.withValues(alpha: 0.2))),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.translate_rounded, size: 14, color: textColor.withValues(alpha: 0.7)),
            const SizedBox(width: 6),
            Flexible(
              child: Text(translation!,
                  style: TextStyle(color: textColor.withValues(alpha: 0.9), fontStyle: FontStyle.italic)),
            ),
          ],
        ),
      ));
    }
    content.add(_meta(textColor));

    Widget bubble = Container(
      constraints: BoxConstraints(maxWidth: maxW),
      padding: mediaOnly
          ? const EdgeInsets.all(3)
          : EdgeInsets.fromLTRB(12, compact ? 6 : 8, 12, compact ? 5 : 7),
      decoration: BoxDecoration(
        gradient: mine ? QColors.bubble : null,
        color: mine ? null : otherColor,
        borderRadius: radius,
        boxShadow: mine || isDark
            ? null
            : [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 6, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: content,
      ),
    );

    if (m.reactions.isNotEmpty) {
      final counts = <String, int>{};
      for (final e in m.reactions.values) {
        counts[e] = (counts[e] ?? 0) + 1;
      }
      final mineReacted = m.reactions.containsKey(myUid);
      bubble = Column(
        crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          bubble,
          Transform.translate(
            offset: const Offset(0, -6),
            child: GestureDetector(
              onTap: onTapReactions,
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 8),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF2E2557) : Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: mineReacted ? theme.colorScheme.primary : Colors.transparent,
                  ),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 4),
                  ],
                ),
                child: Text(
                  counts.entries
                          .map((e) => e.value > 1 ? '${e.key}${e.value}' : e.key)
                          .join(' '),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ),
          ),
        ],
      );
    }

    final row = Row(
      mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (!mine && showAvatar)
          Padding(
            padding: const EdgeInsets.only(right: 6, bottom: 2),
            child: groupedWithNext
                ? const SizedBox(width: 30)
                : GestureDetector(
                    onTap: onTapSender,
                    child: Avatar(name: m.sender, photo: senderPhoto, size: 30),
                  ),
          ),
        Flexible(child: bubble),
      ],
    );

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onLongPress: onLongPress,
      onDoubleTap: onDoubleTap,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        color: selected
            ? theme.colorScheme.primary.withValues(alpha: 0.18)
            : highlighted
                ? theme.colorScheme.primary.withValues(alpha: 0.10)
                : Colors.transparent,
        padding: EdgeInsets.fromLTRB(10, groupedWithNext ? 1 : 2, 10, groupedWithNext ? 1 : (compact ? 3 : 6)),
        child: row,
      ),
    );
  }

  Widget _body(BuildContext context, Color textColor, double maxW) {
    switch (m.type) {
      case 'image':
        return _image(context, maxW, textColor);
      case 'video':
        return _video(context, textColor);
      case 'voice':
        return VoicePlayer(
          dataUrl: m.fileData ?? '',
          durationSec: m.duration,
          fileType: m.fileType,
          mine: mine,
          seed: m.id,
        );
      case 'file':
        return _file(context, textColor);
      default:
        return _text(context, m.text, textColor);
    }
  }

  Widget _text(BuildContext context, String text, Color color) {
    final emojiOnly = text.runes.length <= 3 &&
        text.isNotEmpty &&
        !RegExp(r'[A-Za-z0-9çğıöşüÇĞİÖŞÜ]').hasMatch(text);
    final style = TextStyle(
      color: color,
      fontSize: emojiOnly ? 40 : (compact ? 15 : 16),
      height: 1.3,
    );
    final spans = <InlineSpan>[];
    var last = 0;
    for (final match in urlRegex.allMatches(text)) {
      if (match.start > last) spans.add(TextSpan(text: text.substring(last, match.start)));
      final url = match.group(0)!;
      spans.add(TextSpan(
        text: url,
        style: TextStyle(
          decoration: TextDecoration.underline,
          color: mine ? Colors.white : QColors.blue,
          fontWeight: FontWeight.w500,
        ),
        recognizer: TapGestureRecognizer()
          ..onTap = () {
            final u = url.startsWith('http') ? url : 'https://$url';
            launchUrl(Uri.parse(u), mode: LaunchMode.externalApplication);
          },
      ));
      last = match.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return Text.rich(TextSpan(style: style, children: spans));
  }

  Widget _image(BuildContext context, double maxW, Color textColor) {
    final bytes = MediaCache.bytes(m.fileData);
    final img = ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: bytes == null
          ? Container(
              width: 220,
              height: 160,
              color: Colors.black12,
              child: const Icon(Icons.broken_image_outlined, size: 40),
            )
          : ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxW - 6, maxHeight: 340, minWidth: 120),
              child: Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true, cacheWidth: 900),
            ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTap ??
              (m.fileData == null
                  ? null
                  : () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ImageViewerScreen(
                              dataUrl: m.fileData!, title: m.sender, caption: m.caption),
                        ),
                      )),
          child: Hero(tag: 'img_${m.id}', child: img),
        ),
        if (m.caption.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 2, right: 2),
            child: _text(context, m.caption, textColor),
          ),
      ],
    );
  }

  Widget _video(BuildContext context, Color textColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTap ??
              (m.fileData == null
                  ? null
                  : () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => VideoPlayerScreen(
                              dataUrl: m.fileData!, fileName: m.fileName, caption: m.caption),
                        ),
                      )),
          child: Container(
            width: 230,
            height: 150,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: const LinearGradient(
                colors: [Color(0xFF1B1538), Color(0xFF3A2C7A)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Stack(
              children: [
                const Center(
                  child: CircleAvatar(
                    radius: 28,
                    backgroundColor: Colors.white24,
                    child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: 38),
                  ),
                ),
                Positioned(
                  left: 10,
                  bottom: 8,
                  child: Row(
                    children: [
                      const Icon(Icons.videocam_rounded, color: Colors.white70, size: 16),
                      const SizedBox(width: 4),
                      Text(formatFileSize(m.fileSize),
                          style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (m.caption.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 2, right: 2),
            child: _text(context, m.caption, textColor),
          ),
      ],
    );
  }

  Widget _file(BuildContext context, Color textColor) {
    final ext = (m.fileName ?? '').contains('.')
        ? (m.fileName!.split('.').last.toUpperCase())
        : 'DOSYA';
    return GestureDetector(
      onTap: onTap ??
          (m.fileData == null
              ? null
              : () => shareDataUrl(context, m.fileData!, fileName: m.fileName, mime: m.fileType)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: mine ? Colors.white.withValues(alpha: 0.15) : textColor.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 42,
                  height: 42,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: mine ? Colors.white24 : QColors.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    ext.length > 4 ? ext.substring(0, 4) : ext,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: mine ? Colors.white : QColors.primary,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        m.fileName ?? 'Dosya',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: textColor, fontWeight: FontWeight.w600),
                      ),
                      Text(formatFileSize(m.fileSize),
                          style: TextStyle(color: textColor.withValues(alpha: 0.7), fontSize: 12)),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Icon(Icons.download_rounded, color: textColor.withValues(alpha: 0.8)),
              ],
            ),
          ),
          if (m.caption.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: _text(context, m.caption, textColor),
            ),
        ],
      ),
    );
  }

  Widget _meta(Color textColor) {
    final c = mine ? Colors.white70 : textColor.withValues(alpha: 0.55);
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (m.edited)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Text('düzenlendi', style: TextStyle(fontSize: 11, color: c, fontStyle: FontStyle.italic)),
            ),
          Text(formatClock(m.timestamp), style: TextStyle(fontSize: 11, color: c)),
          if (mine) ...[
            const SizedBox(width: 3),
            Icon(
              m.timestamp == 0
                  ? Icons.schedule_rounded
                  : (readByOthers ? Icons.done_all_rounded : Icons.done_rounded),
              size: 15,
              color: readByOthers ? const Color(0xFF7FE3FF) : c,
            ),
          ],
        ],
      ),
    );
  }

  static Color _nameColor(String name) {
    const colors = [
      Color(0xFF0A84FF),
      Color(0xFFFF4F8B),
      Color(0xFF00B894),
      Color(0xFFFF9F43),
      Color(0xFF8E44AD),
      Color(0xFFE17055),
      Color(0xFF6A5CFF),
    ];
    return colors[name.hashCode.abs() % colors.length];
  }
}

class _ReplyQuote extends StatelessWidget {
  final ReplyRef reply;
  final bool mine;
  final VoidCallback? onTap;
  const _ReplyQuote({required this.reply, required this.mine, this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = mine ? Colors.white : Theme.of(context).colorScheme.primary;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.fromLTRB(8, 5, 8, 5),
        decoration: BoxDecoration(
          color: mine
              ? Colors.white.withValues(alpha: 0.16)
              : (isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.05)),
          borderRadius: BorderRadius.circular(10),
          border: Border(left: BorderSide(color: accent, width: 3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(reply.sender,
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5, color: accent)),
            Text(
              reply.previewText,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                color: mine ? Colors.white70 : Theme.of(context).hintColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class DayChip extends StatelessWidget {
  final String text;
  const DayChip(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 10),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(text, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
      ),
    );
  }
}
