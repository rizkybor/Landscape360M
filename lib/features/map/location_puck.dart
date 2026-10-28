import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../../core/theme/app_theme.dart';

// The user's position drawn like the web's UserLocationMarker: an ember dot with a white
// border, a soft ring, and where the phone points a 70° beam with a needle tip. The map
// turns the beam itself (natively, with the compass), so it costs no Flutter frames.

/// Logical size of the beam image (the web's SVG is 88 × 88)
const _beamSize = 88.0;

Future<Uint8List> _render(double size, double scale, void Function(Canvas canvas, double s) paint) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(scale);
  paint(canvas, size);
  final image = await recorder.endRecording().toImage((size * scale).ceil(), (size * scale).ceil());
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}

/// Core dot: 16 pt ember with a 3 pt white border and a soft shadow
Future<Uint8List> puckDot(double scale) => _render(22, scale, (c, s) {
  final center = Offset(s / 2, s / 2);
  c
    ..drawCircle(
      center.translate(0, 1),
      8,
      Paint()
        ..color = const Color(0x66682E16)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
    )
    ..drawCircle(center, 8, Paint()..color = const Color(0xFFFFFFFF))
    ..drawCircle(center, 5, Paint()..color = L360Colors.ember500);
});

/// Static ring around the dot: 24 pt ember at 25%
Future<Uint8List> puckRing(double scale) =>
    _render(24, scale, (c, s) => c.drawCircle(Offset(s / 2, s / 2), 12, Paint()..color = const Color(0x40E46C24)));

/// Heading beam pointing up (north before the map turns it): 70° wide, fading out, with the
/// needle tip at the dot. Same geometry as the web's SVG (viewBox -44 -44 88 88).
Future<Uint8List> puckBeam(double scale) => _render(_beamSize, scale, (c, s) {
  c.translate(s / 2, s / 2);
  final beam = Path()
    ..moveTo(0, 0)
    ..lineTo(-25.2, -36)
    ..arcTo(
      Rect.fromCircle(center: Offset.zero, radius: 44),
      -math.pi / 2 - 35 * math.pi / 180,
      70 * math.pi / 180,
      false,
    )
    ..close();
  c.drawPath(
    beam,
    Paint()
      ..shader = ui.Gradient.radial(
        Offset.zero,
        44,
        const [Color(0x8CE46C24), Color(0x8CE46C24), Color(0x00E46C24)],
        const [0, 0.15, 1],
      ),
  );
  final needle = Path()
    ..moveTo(0, -21)
    ..lineTo(5, -10)
    ..lineTo(0, -12.5)
    ..lineTo(-5, -10)
    ..close();
  c
    ..drawPath(
      needle,
      Paint()
        ..color = const Color(0xFFFFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeJoin = StrokeJoin.round,
    )
    ..drawPath(needle, Paint()..color = L360Colors.ember500);
});
