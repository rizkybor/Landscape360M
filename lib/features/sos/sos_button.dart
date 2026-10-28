import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import 'sos_screen.dart';

// The red S.O.S button on the map (SosButton.tsx) for accounts the admin allowed: hold it
// for 3 s, so a touch in a pocket does nothing. Admins open S.O.S from their account page.

const sosHold = Duration(seconds: 3);

class SosButton extends ConsumerStatefulWidget {
  const SosButton({super.key});

  @override
  ConsumerState<SosButton> createState() => _SosButtonState();
}

class _SosButtonState extends ConsumerState<SosButton> with SingleTickerProviderStateMixin {
  late final _hold = AnimationController(vsync: this, duration: sosHold)..addStatusListener(_done);
  Timer? _ticks;

  @override
  void dispose() {
    _ticks?.cancel();
    _hold.dispose();
    super.dispose();
  }

  void _start() {
    HapticFeedback.mediumImpact();
    _hold.forward(from: 0);
    // A light tap each second so the hold can be felt in a glove
    _ticks = Timer.periodic(const Duration(seconds: 1), (_) => HapticFeedback.selectionClick());
  }

  void _stop() {
    _ticks?.cancel();
    _ticks = null;
    if (_hold.status != AnimationStatus.completed) _hold.reverse();
  }

  void _done(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    _ticks?.cancel();
    _ticks = null;
    HapticFeedback.heavyImpact();
    _hold.value = 0;
    unawaited(openSosScreen(context, ref));
  }

  @override
  Widget build(BuildContext context) {
    final p = ref.watch(profileProvider).value;
    if (p == null || !p.canUseSos || p.isAdmin) return const SizedBox.shrink();
    return Semantics(
      button: true,
      label: 'S.O.S: hold for 3 seconds',
      child: GestureDetector(
        key: const Key('sos-button'),
        onTapDown: (_) => _start(),
        onTapUp: (_) => _stop(),
        onTapCancel: _stop,
        child: AnimatedBuilder(
          animation: _hold,
          builder: (context, _) => Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              Container(
                width: L360.touch + 4,
                height: L360.touch + 4,
                decoration: BoxDecoration(
                  color: const Color(0xFF962620),
                  shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: const Color(0xFF962620).withValues(alpha: 0.35), blurRadius: 10)],
                ),
                child: CustomPaint(
                  painter: _Ring(_hold.value),
                  child: const Center(
                    child: Text(
                      'SOS',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        fontSize: 13,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                ),
              ),
              if (_hold.value > 0)
                Positioned(
                  right: L360.touch + 14,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: L360Colors.ink.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'Keep holding… ${((1 - _hold.value) * sosHold.inSeconds).ceil()}',
                      style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Ring extends CustomPainter {
  const _Ring(this.progress);
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final r = rect.deflate(3);
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = Colors.white.withValues(alpha: 0.25);
    canvas.drawArc(r, 0, math.pi * 2, false, base);
    if (progress > 0) {
      canvas.drawArc(
        r,
        -math.pi / 2,
        math.pi * 2 * progress,
        false,
        base
          ..color = Colors.white
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_Ring old) => old.progress != progress;
}
