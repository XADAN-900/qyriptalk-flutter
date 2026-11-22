import 'package:flutter/material.dart';
import 'package:qyriptalk/core/i18n.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/theme.dart';

/// Kamera ile QR kod okur ve okunan metni geri döndürür (Navigator.pop(context, değer)).
class QrScanScreen extends StatefulWidget {
  final String title;
  final String hint;
  const QrScanScreen({
    super.key,
    this.title = 'QR kod tara',
    this.hint = 'Oda davet kodunu ya da bir arkadaşının profil kodunu çerçeveye getir',
  });

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final MobileScannerController _c = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
  );
  bool _done = false;
  bool _torch = false;

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final v = b.rawValue;
      if (v != null && v.trim().isNotEmpty) {
        _done = true;
        HapticFeedback.mediumImpact();
        Navigator.of(context).pop(v.trim());
        return;
      }
    }
  }

  Future<void> _fromGallery() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (x == null) return;
    try {
      final r = await _c.analyzeImage(x.path);
      final v = r?.barcodes.isNotEmpty == true ? r!.barcodes.first.rawValue : null;
      if (!mounted) return;
      if (v == null || v.trim().isEmpty) {
        showSnack(context, tr('Bu görselde QR kod bulunamadı.'), error: true);
        return;
      }
      _done = true;
      Navigator.of(context).pop(v.trim());
    } catch (_) {
      if (mounted) showSnack(context, tr('Görsel okunamadı.'), error: true);
    }
  }

  Future<void> _paste() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    final v = d?.text?.trim();
    if (!mounted) return;
    if (v == null || v.isEmpty) {
      showSnack(context, tr('Panoda bağlantı yok.'), error: true);
      return;
    }
    _done = true;
    Navigator.of(context).pop(v);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final box = size.width * 0.7;
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: Text(widget.title, style: const TextStyle(color: Colors.white, fontSize: 18)),
        actions: [
          IconButton(
            tooltip: 'Fener',
            icon: Icon(_torch ? Icons.flash_on_rounded : Icons.flash_off_rounded),
            onPressed: () async {
              await _c.toggleTorch();
              setState(() => _torch = !_torch);
            },
          ),
          IconButton(
            tooltip: 'Kamerayı değiştir',
            icon: const Icon(Icons.cameraswitch_rounded),
            onPressed: () => _c.switchCamera(),
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(child: MobileScanner(controller: _c, onDetect: _onDetect)),
          // Karartma + tarama çerçevesi
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _FramePainter(box)),
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            top: size.height / 2 + box / 2 + 24,
            child: Text(
              widget.hint,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white54),
                          minimumSize: const Size(0, 48),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        onPressed: _fromGallery,
                        icon: const Icon(Icons.photo_library_outlined),
                        label: const T('Galeriden'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white54),
                          minimumSize: const Size(0, 48),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        onPressed: _paste,
                        icon: const Icon(Icons.content_paste_rounded),
                        label: const T('Yapıştır'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FramePainter extends CustomPainter {
  final double box;
  _FramePainter(this.box);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromCenter(center: Offset(size.width / 2, size.height / 2), width: box, height: box);
    final rr = RRect.fromRectAndRadius(rect, const Radius.circular(24));
    final overlay = Path()
      ..addRect(Offset.zero & size)
      ..addRRect(rr)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(overlay, Paint()..color = Colors.black.withValues(alpha: 0.55));

    final p = Paint()
      ..shader = QColors.brand.createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    const l = 34.0;
    final r = rect;
    // Köşe çizgileri
    canvas.drawLine(r.topLeft + const Offset(0, l), r.topLeft + const Offset(0, 12), p);
    canvas.drawLine(r.topLeft + const Offset(12, 0), r.topLeft + const Offset(l, 0), p);
    canvas.drawLine(r.topRight + const Offset(-l, 0), r.topRight + const Offset(-12, 0), p);
    canvas.drawLine(r.topRight + const Offset(0, 12), r.topRight + const Offset(0, l), p);
    canvas.drawLine(r.bottomLeft + const Offset(0, -l), r.bottomLeft + const Offset(0, -12), p);
    canvas.drawLine(r.bottomLeft + const Offset(12, 0), r.bottomLeft + const Offset(l, 0), p);
    canvas.drawLine(r.bottomRight + const Offset(-l, 0), r.bottomRight + const Offset(-12, 0), p);
    canvas.drawLine(r.bottomRight + const Offset(0, -12), r.bottomRight + const Offset(0, -l), p);
  }

  @override
  bool shouldRepaint(covariant _FramePainter old) => old.box != box;
}
