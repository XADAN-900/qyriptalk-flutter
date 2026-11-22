import 'dart:io';
import 'package:qyriptalk/core/i18n.dart';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../core/theme.dart';
import '../core/utils.dart';

/// Dosyayı paylaş / başka uygulamayla aç (galeriye kaydetme dahil).
Future<void> shareDataUrl(BuildContext context, String dataUrl,
    {String? fileName, String? mime}) async {
  final path = await MediaCache.file(dataUrl, fileName: fileName, mime: mime);
  if (path == null) {
    if (context.mounted) showSnack(context, tr('Dosya açılamadı.'), error: true);
    return;
  }
  await Share.shareXFiles([XFile(path, mimeType: mime ?? mimeOfDataUrl(dataUrl))]);
}

class ImageViewerScreen extends StatelessWidget {
  final String dataUrl;
  final String? title;
  final String? caption;
  const ImageViewerScreen({super.key, required this.dataUrl, this.title, this.caption});

  @override
  Widget build(BuildContext context) {
    final bytes = MediaCache.bytes(dataUrl);
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.black54,
        foregroundColor: Colors.white,
        title: Text(title ?? '', style: const TextStyle(color: Colors.white, fontSize: 17)),
        actions: [
          IconButton(
            icon: const Icon(Icons.share_rounded),
            onPressed: () => shareDataUrl(context, dataUrl, fileName: 'qyriptalk.jpg'),
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: bytes == null
                ? const Center(child: Icon(Icons.broken_image, color: Colors.white54, size: 64))
                : InteractiveViewer(
                    minScale: 1,
                    maxScale: 5,
                    child: Center(child: Image.memory(bytes, fit: BoxFit.contain)),
                  ),
          ),
          if (caption != null && caption!.isNotEmpty)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                color: Colors.black54,
                padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + MediaQuery.of(context).padding.bottom),
                child: Text(caption!, style: const TextStyle(color: Colors.white, fontSize: 15)),
              ),
            ),
        ],
      ),
    );
  }
}

class VideoPlayerScreen extends StatefulWidget {
  final String dataUrl;
  final String? fileName;
  final String? caption;
  const VideoPlayerScreen({super.key, required this.dataUrl, this.fileName, this.caption});

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  VideoPlayerController? _c;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final path = await MediaCache.file(widget.dataUrl, fileName: widget.fileName);
    if (path == null) {
      setState(() => _error = 'Video açılamadı.');
      return;
    }
    final c = VideoPlayerController.file(File(path));
    try {
      await c.initialize();
      await c.play();
      c.addListener(() {
        if (mounted) setState(() {});
      });
      if (!mounted) {
        c.dispose();
        return;
      }
      setState(() => _c = c);
    } catch (e) {
      c.dispose();
      if (mounted) setState(() => _error = 'Bu video oynatılamıyor.');
    }
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.share_rounded),
            onPressed: () => shareDataUrl(context, widget.dataUrl, fileName: widget.fileName),
          ),
        ],
      ),
      body: Center(
        child: _error != null
            ? Text(_error!, style: const TextStyle(color: Colors.white70))
            : c == null
                ? const CircularProgressIndicator()
                : GestureDetector(
                    onTap: () => c.value.isPlaying ? c.pause() : c.play(),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Flexible(
                          child: AspectRatio(
                            aspectRatio: c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                VideoPlayer(c),
                                if (!c.value.isPlaying)
                                  const CircleAvatar(
                                    radius: 32,
                                    backgroundColor: Colors.black45,
                                    child: Icon(Icons.play_arrow_rounded, size: 44, color: Colors.white),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        VideoProgressIndicator(c, allowScrubbing: true,
                            padding: const EdgeInsets.all(14)),
                        if (widget.caption != null && widget.caption!.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                            child: Text(widget.caption!, style: const TextStyle(color: Colors.white)),
                          ),
                      ],
                    ),
                  ),
      ),
    );
  }
}
