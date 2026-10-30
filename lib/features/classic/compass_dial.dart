import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';
import '../../domain/classic/classic_nav.dart';

// A digital compass for Classic (CompassDial.tsx): the needle swings to the typed bearing the
// short way round, settling with a little overshoot like a real needle, and dragging the dial
// sets the bearing. [ghost] shows a second, faint bearing (the azimuth behind a back azimuth).

const _red = Color(0xFFE5533D);
const _gold = Color(0xFFD49B22);
const _cream = Color(0xFFE9DCB8);

class CompassDial extends StatefulWidget {
  const CompassDial({
    super.key,
    required this.value,
    this.ghost,
    this.onChanged,
    required this.label,
    this.enabled = true,
    this.size = 96,
  });

  final double? value;
  final double? ghost;
  final ValueChanged<int>? onChanged;
  final String label;
  final bool enabled;
  final double size;

  @override
  State<CompassDial> createState() => _CompassDialState();
}

class _CompassDialState extends State<CompassDial> {
  // Unwrapped angles: from 350° to 10° the needle turns 20°, not 340° backwards
  late double _angle = widget.value ?? 0;
  late double _ghost = widget.ghost ?? 0;
  bool _dragging = false;

  static double _unwrap(double current, double target) {
    final delta = ((target - current) % 360 + 540) % 360 - 180;
    return current + delta;
  }

  @override
  void didUpdateWidget(CompassDial old) {
    super.didUpdateWidget(old);
    final v = widget.value;
    if (v != null) _angle = _unwrap(_angle, v);
    final g = widget.ghost;
    if (g != null) _ghost = _unwrap(_ghost, g);
  }

  void _drag(Offset local) {
    final c = widget.size / 2;
    final dx = local.dx - c, dy = local.dy - c;
    final deg = ((math.atan2(dx, -dy) * 180 / math.pi + 360) % 360).round() % 360;
    if (deg != widget.value?.round()) HapticFeedback.selectionClick();
    widget.onChanged!(deg);
  }

  @override
  Widget build(BuildContext context) {
    final interactive = widget.onChanged != null && widget.enabled;
    final v = widget.value;
    // A free swing while typing, a firm follow while dragging
    final duration = _dragging ? Duration.zero : const Duration(milliseconds: 900);
    const curve = Cubic(0.34, 1.56, 0.64, 1);
    return Opacity(
      opacity: widget.enabled ? 1 : 0.4,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            label: widget.label,
            value: v == null ? 'not set' : '${formatCompass(v)} ${compassPoint(v)}',
            slider: interactive,
            child: GestureDetector(
              onPanStart: interactive
                  ? (d) {
                      setState(() => _dragging = true);
                      _drag(d.localPosition);
                    }
                  : null,
              onPanUpdate: interactive ? (d) => _drag(d.localPosition) : null,
              onPanEnd: interactive ? (_) => setState(() => _dragging = false) : null,
              onTapUp: interactive ? (d) => _drag(d.localPosition) : null,
              child: SizedBox.square(
                dimension: widget.size,
                child: Stack(
                  children: [
                    Positioned.fill(child: CustomPaint(painter: _FacePainter())),
                    if (widget.ghost != null)
                      TweenAnimationBuilder<double>(
                        tween: Tween(end: _ghost),
                        duration: duration,
                        curve: curve,
                        builder: (_, a, _) => Positioned.fill(child: CustomPaint(painter: _GhostPainter(a))),
                      ),
                    if (v != null)
                      TweenAnimationBuilder<double>(
                        tween: Tween(end: _angle),
                        duration: duration,
                        curve: curve,
                        builder: (_, a, _) => Positioned.fill(child: CustomPaint(painter: _NeedlePainter(a))),
                      ),
                    Positioned.fill(child: CustomPaint(painter: _HubPainter())),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          // Digital readout
          Container(
            constraints: const BoxConstraints(minWidth: 76),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(color: L360Colors.ink, borderRadius: BorderRadius.circular(6)),
            child: Text.rich(
              v == null
                  ? const TextSpan(
                      text: '---°',
                      style: TextStyle(color: L360Colors.sand400),
                    )
                  : TextSpan(
                      children: [
                        TextSpan(text: '${formatCompass(v)} '),
                        TextSpan(
                          text: compassPoint(v),
                          style: const TextStyle(fontSize: 9, color: L360Colors.sand300),
                        ),
                      ],
                    ),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: L360Colors.gold400,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// The dial is drawn on a 100 × 100 box centred on 0, like the web's SVG viewBox
void _scaled(Canvas canvas, Size size, void Function() draw) {
  canvas
    ..save()
    ..translate(size.width / 2, size.height / 2)
    ..scale(size.width / 100);
  draw();
  canvas.restore();
}

class _FacePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) => _scaled(canvas, size, () {
    canvas
      ..drawCircle(
        Offset.zero,
        48,
        Paint()
          ..shader = const RadialGradient(
            radius: 0.6,
            colors: [Color(0xFF24301B), Color(0xFF10160B)],
          ).createShader(Rect.fromCircle(center: Offset.zero, radius: 48)),
      )
      ..drawCircle(
        Offset.zero,
        48,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = _gold,
      );
    for (var t = 0; t < 360; t += 5) {
      final inner = t % 90 == 0
          ? 37.0
          : t % 30 == 0
          ? 39.5
          : t % 10 == 0
          ? 41.5
          : 43.0;
      final a = t * math.pi / 180;
      final dir = Offset(math.sin(a), -math.cos(a));
      canvas.drawLine(
        dir * 45,
        dir * inner,
        Paint()
          ..color = (t == 0 ? _red : _cream).withValues(alpha: t % 10 == 0 ? 0.95 : 0.45)
          ..strokeWidth = t % 30 == 0 ? 1.4 : 0.7,
      );
    }
    void label(String text, double deg, double r, double fontSize, Color color, FontWeight weight) {
      final a = deg * math.pi / 180;
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(fontSize: fontSize, fontWeight: weight, color: color),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      canvas
        ..save()
        ..rotate(a)
        ..translate(0, -r);
      tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
      canvas.restore();
    }

    for (final (i, c) in ['N', 'E', 'S', 'W'].indexed) {
      label(c, i * 90, 27, 9, c == 'N' ? _red : const Color(0xFFF3EAD2), FontWeight.w800);
    }
    for (final d in [30, 60, 120, 150, 210, 240, 300, 330]) {
      label('$d', d.toDouble(), 29, 5, const Color(0xFFB8AD8A), FontWeight.w400);
    }
  });

  @override
  bool shouldRepaint(_FacePainter old) => false;
}

class _GhostPainter extends CustomPainter {
  _GhostPainter(this.angle);
  final double angle;

  @override
  void paint(Canvas canvas, Size size) => _scaled(canvas, size, () {
    canvas.rotate(angle * math.pi / 180);
    final paint = Paint()
      ..color = _gold
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    for (var y = 0.0; y > -34; y -= 5) {
      canvas.drawLine(Offset(0, y), Offset(0, math.max(y - 3, -34)), paint);
    }
    canvas.drawCircle(const Offset(0, -34), 2.2, Paint()..color = _gold);
  });

  @override
  bool shouldRepaint(_GhostPainter old) => old.angle != angle;
}

class _NeedlePainter extends CustomPainter {
  _NeedlePainter(this.angle);
  final double angle;

  @override
  void paint(Canvas canvas, Size size) => _scaled(canvas, size, () {
    canvas
      ..rotate(angle * math.pi / 180)
      ..drawPath(
        Path()
          ..moveTo(0, -36)
          ..lineTo(4.5, 0)
          ..lineTo(-4.5, 0)
          ..close(),
        Paint()..color = _red,
      )
      ..drawPath(
        Path()
          ..moveTo(0, 22)
          ..lineTo(4.5, 0)
          ..lineTo(-4.5, 0)
          ..close(),
        Paint()..color = _cream,
      );
  });

  @override
  bool shouldRepaint(_NeedlePainter old) => old.angle != angle;
}

class _HubPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) => _scaled(canvas, size, () {
    canvas
      ..drawCircle(Offset.zero, 3.4, Paint()..color = _gold)
      ..drawCircle(
        Offset.zero,
        3.4,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = const Color(0xFF10160B),
      );
  });

  @override
  bool shouldRepaint(_HubPainter old) => false;
}
