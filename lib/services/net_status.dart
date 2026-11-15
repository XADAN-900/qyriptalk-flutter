import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

/// Gerçek internet algılama: birkaç saniyede bir genel sunuculara kısa bir bağlantı dener.
/// Sonuç sadece iki durum: internet VAR ya da YOK.
class NetStatus with WidgetsBindingObserver {
  NetStatus._();

  static final NetStatus instance = NetStatus._();

  /// true: internet var, false: internet yok.
  final ValueNotifier<bool> online = ValueNotifier<bool>(true);

  /// İnternet geri geldiğinde çağrılır (ör. veritabanını yeniden bağlamak için).
  final List<VoidCallback> onBack = [];

  Timer? _timer;
  bool _checking = false;
  int _fails = 0;
  bool _started = false;

  static const _targets = [
    ('8.8.8.8', 53),
    ('1.1.1.1', 443),
    ('208.67.222.222', 443),
  ];

  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    check();
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    // İnternet yokken daha sık bak ki geri gelince hemen anlaşılsın.
    _timer = Timer.periodic(Duration(seconds: online.value ? 5 : 2), (_) => check());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      check();
      _schedule();
    } else if (state == AppLifecycleState.paused) {
      _timer?.cancel();
    }
  }

  Future<bool> _probe() async {
    final attempts = _targets.map((t) async {
      try {
        final s = await Socket.connect(t.$1, t.$2, timeout: const Duration(seconds: 3));
        s.destroy();
        return true;
      } catch (_) {
        return false;
      }
    }).toList();
    // Herhangi biri başarılıysa internet var.
    final c = Completer<bool>();
    var done = 0;
    for (final f in attempts) {
      f.then((ok) {
        done++;
        if (ok && !c.isCompleted) c.complete(true);
        if (done == attempts.length && !c.isCompleted) c.complete(false);
      });
    }
    return c.future;
  }

  Future<void> check() async {
    if (_checking) return;
    _checking = true;
    try {
      final ok = await _probe();
      if (ok) {
        _fails = 0;
        if (!online.value) {
          online.value = true;
          _schedule();
          for (final f in List.of(onBack)) {
            try {
              f();
            } catch (_) {}
          }
        }
      } else {
        _fails++;
        // Tek bir başarısız deneme yanlış alarm olabilir: art arda 2 kez olursa "yok".
        if (_fails >= 2 && online.value) {
          online.value = false;
          _schedule();
        }
      }
    } finally {
      _checking = false;
    }
  }
}
