import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../core/utils.dart';

/// Sesli mesaj oynatıcı: dalga formu, ilerleme, hız (1x / 1.5x / 2x).
class VoicePlayer extends StatefulWidget {
  final String dataUrl;
  final int durationSec;
  final String? fileType;
  final bool mine;
  final String seed;

  const VoicePlayer({
    super.key,
    required this.dataUrl,
    required this.durationSec,
    required this.mine,
    required this.seed,
    this.fileType,
  });

  @override
  State<VoicePlayer> createState() => _VoicePlayerState();
}

class _VoicePlayerState extends State<VoicePlayer> {
  static _VoicePlayerState? _active;

  AudioPlayer? _player;
  final List<StreamSubscription> _subs = [];
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  bool _playing = false;
  bool _loading = false;
  double _rate = 1.0;
  late final List<double> _bars;

  @override
  void initState() {
    super.initState();
    var h = widget.seed.hashCode;
    _bars = List.generate(28, (i) {
      h = (h * 1103515245 + 12345) & 0x7fffffff;
      return 0.25 + (h % 1000) / 1000 * 0.75;
    });
    _dur = Duration(seconds: widget.durationSec);
  }

  Future<void> _toggle() async {
    if (_loading) return;
    if (_player == null) {
      setState(() => _loading = true);
      final path = await MediaCache.file(widget.dataUrl, mime: widget.fileType);
      if (!mounted) return;
      if (path == null) {
        setState(() => _loading = false);
        return;
      }
      final p = AudioPlayer();
      _player = p;
      _subs.add(p.onPositionChanged.listen((d) {
        if (mounted) setState(() => _pos = d);
      }));
      _subs.add(p.onDurationChanged.listen((d) {
        if (mounted && d.inMilliseconds > 0) setState(() => _dur = d);
      }));
      _subs.add(p.onPlayerComplete.listen((_) {
        if (mounted) {
          setState(() {
            _playing = false;
            _pos = Duration.zero;
          });
        }
      }));
      _active?._pauseExternally();
      _active = this;
      try {
        await p.setPlaybackRate(_rate);
        await p.play(DeviceFileSource(path));
        setState(() {
          _playing = true;
          _loading = false;
        });
      } catch (_) {
        setState(() => _loading = false);
      }
      return;
    }
    if (_playing) {
      await _player!.pause();
      setState(() => _playing = false);
    } else {
      _active?._pauseExternally();
      _active = this;
      await _player!.resume();
      setState(() => _playing = true);
    }
  }

  void _pauseExternally() {
    if (_active == this) _active = null;
    if (_playing) {
      _player?.pause();
      if (mounted) setState(() => _playing = false);
    }
  }

  Future<void> _cycleRate() async {
    final next = _rate == 1.0 ? 1.5 : (_rate == 1.5 ? 2.0 : 1.0);
    setState(() => _rate = next);
    try {
      await _player?.setPlaybackRate(next);
    } catch (_) {}
  }

  void _seek(double fraction) {
    final p = _player;
    if (p == null || _dur.inMilliseconds == 0) return;
    p.seek(Duration(milliseconds: (fraction * _dur.inMilliseconds).round()));
  }

  @override
  void dispose() {
    if (_active == this) _active = null;
    for (final s in _subs) {
      s.cancel();
    }
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fg = widget.mine ? Colors.white : Theme.of(context).colorScheme.primary;
    final dim = widget.mine ? Colors.white38 : Theme.of(context).hintColor.withValues(alpha: 0.35);
    final progress =
        _dur.inMilliseconds == 0 ? 0.0 : (_pos.inMilliseconds / _dur.inMilliseconds).clamp(0.0, 1.0).toDouble();
    final shown = _playing || _pos > Duration.zero ? _pos : _dur;
    return SizedBox(
      width: 236,
      child: Row(
        children: [
          GestureDetector(
            onTap: _toggle,
            child: CircleAvatar(
              radius: 20,
              backgroundColor: widget.mine ? Colors.white24 : fg.withValues(alpha: 0.12),
              child: _loading
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: fg),
                    )
                  : Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: fg, size: 26),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LayoutBuilder(
                  builder: (context, c) => GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (d) => _seek(d.localPosition.dx / c.maxWidth),
                    onHorizontalDragUpdate: (d) => _seek((d.localPosition.dx / c.maxWidth).clamp(0.0, 1.0).toDouble()),
                    child: SizedBox(
                      height: 28,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          for (var i = 0; i < _bars.length; i++)
                            Expanded(
                              child: Container(
                                margin: const EdgeInsets.symmetric(horizontal: 1),
                                height: 26 * _bars[i],
                                decoration: BoxDecoration(
                                  color: (i / _bars.length) <= progress ? fg : dim,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  formatDuration(shown.inSeconds),
                  style: TextStyle(fontSize: 11, color: widget.mine ? Colors.white70 : Theme.of(context).hintColor),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: _cycleRate,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: widget.mine ? Colors.white24 : fg.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${_rate == 1.0 ? '1' : _rate.toString()}x',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: fg),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
