import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../core/utils.dart';
import '../services/app_state.dart';
import '../services/call_service.dart';
import '../widgets/avatar.dart';

class CallScreen extends StatefulWidget {
  const CallScreen({super.key});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();
  bool _closing = false;

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  void _maybeClose(CallService calls) {
    if (calls.phase == CallPhase.idle && !_closing) {
      _closing = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Future.delayed(const Duration(milliseconds: 700), () {
          if (mounted) Navigator.of(context).maybePop();
        });
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final calls = context.watch<CallService>();
    final app = context.read<AppState>();
    _maybeClose(calls);

    String? photo;
    final tid = calls.targetId;
    if (calls.callType == 'dm' && tid != null && app.uid != null) {
      photo = app.users[otherUidFromDm(tid, app.uid!)]?.photo;
    } else if (tid != null) {
      photo = app.rooms[tid]?.logo;
    }

    final phase = calls.phase;
    String status;
    switch (phase) {
      case CallPhase.incoming:
        status = calls.statusText.isEmpty ? 'Gelen sesli arama' : calls.statusText;
        break;
      case CallPhase.outgoing:
        status = calls.statusText.isEmpty ? 'Aranıyor…' : calls.statusText;
        break;
      case CallPhase.active:
        status = calls.connectedAt == null
            ? (calls.statusText.isEmpty ? 'Bağlanıyor…' : calls.statusText)
            : (calls.statusText.isNotEmpty ? calls.statusText : formatDuration(calls.elapsed.inSeconds));
        break;
      case CallPhase.idle:
        status = 'Arama sona erdi';
        break;
    }

    final others = calls.participants.values
        .where((p) => p.uid != app.uid && p.status == 'joined')
        .toList();

    return PopScope(
      canPop: phase == CallPhase.idle,
      child: Scaffold(
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF2B1B7A), Color(0xFF120A3A), Color(0xFF07041A)],
            ),
          ),
          child: SafeArea(
            child: Column(
              children: [
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.lock_rounded, size: 14, color: Colors.white54),
                    const SizedBox(width: 6),
                    Text(
                      calls.callType == 'room' ? 'Qyriptalk grup araması' : 'Qyriptalk sesli arama',
                      style: const TextStyle(color: Colors.white54, fontSize: 13),
                    ),
                  ],
                ),
                const Spacer(flex: 2),
                // Sabit boyutlu alan: büyüyen halkalar alttaki yazıları itmesin.
                AnimatedBuilder(
                  animation: _pulse,
                  builder: (_, child) {
                    final ringing = phase == CallPhase.incoming || phase == CallPhase.outgoing;
                    final v = _pulse.value;
                    return SizedBox(
                      width: 270,
                      height: 270,
                      child: Stack(
                      alignment: Alignment.center,
                      clipBehavior: Clip.none,
                      children: [
                        if (ringing)
                          for (final d in [0.0, 0.5])
                            Opacity(
                              opacity: (1 - ((v + d) % 1)).clamp(0.0, 1.0).toDouble() * 0.5,
                              child: Container(
                                width: 140 + 120 * ((v + d) % 1),
                                height: 140 + 120 * ((v + d) % 1),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.white38, width: 2),
                                ),
                              ),
                            ),
                        child!,
                      ],
                    ),
                    );
                  },
                  child: Avatar(
                    name: calls.title,
                    photo: photo,
                    size: 140,
                    isGroup: calls.callType == 'room',
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    calls.title,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w800),
                  ),
                ),
                const SizedBox(height: 8),
                Text(status, style: const TextStyle(color: Colors.white70, fontSize: 16)),
                if (calls.callType == 'room' && others.isNotEmpty) ...[
                  const SizedBox(height: 22),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 14,
                    runSpacing: 10,
                    children: [
                      for (final p in others)
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Stack(
                              children: [
                                Avatar(name: p.username, photo: app.users[p.uid]?.photo, size: 48),
                                if (p.muted)
                                  const Positioned(
                                    right: 0,
                                    bottom: 0,
                                    child: CircleAvatar(
                                      radius: 9,
                                      backgroundColor: QColors.danger,
                                      child: Icon(Icons.mic_off_rounded, size: 12, color: Colors.white),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(p.username, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                          ],
                        ),
                    ],
                  ),
                ],
                const Spacer(flex: 3),
                if (phase == CallPhase.incoming)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(40, 0, 40, 40),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _RoundButton(
                          icon: Icons.call_end_rounded,
                          label: 'Reddet',
                          color: QColors.danger,
                          onTap: () => calls.decline(),
                        ),
                        _RoundButton(
                          icon: Icons.call_rounded,
                          label: 'Cevapla',
                          color: QColors.online,
                          onTap: () async {
                            final err = await calls.accept();
                            if (err != null && context.mounted) showSnack(context, err, error: true);
                          },
                        ),
                      ],
                    ),
                  )
                else if (phase != CallPhase.idle)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(28, 0, 28, 40),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _RoundButton(
                          icon: calls.speaker ? Icons.volume_up_rounded : Icons.volume_down_rounded,
                          label: 'Hoparlör',
                          color: calls.speaker ? Colors.white : Colors.white24,
                          iconColor: calls.speaker ? Colors.black : Colors.white,
                          onTap: calls.toggleSpeaker,
                        ),
                        _RoundButton(
                          icon: calls.muted ? Icons.mic_off_rounded : Icons.mic_rounded,
                          label: calls.muted ? 'Sessiz' : 'Mikrofon',
                          color: calls.muted ? Colors.white : Colors.white24,
                          iconColor: calls.muted ? Colors.black : Colors.white,
                          onTap: calls.toggleMute,
                        ),
                        _RoundButton(
                          icon: Icons.call_end_rounded,
                          label: 'Bitir',
                          color: QColors.danger,
                          onTap: () => calls.leave(),
                        ),
                      ],
                    ),
                  )
                else
                  const SizedBox(height: 120),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final Color iconColor;
  final VoidCallback onTap;

  const _RoundButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.iconColor = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: color,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(width: 72, height: 72, child: Icon(icon, color: iconColor, size: 32)),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13)),
      ],
    );
  }
}
