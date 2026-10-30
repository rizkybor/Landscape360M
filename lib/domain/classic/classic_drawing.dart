import 'dart:math' as math;

import '../geo/spherical.dart';
import 'classic_nav.dart';
import 'classic_solve.dart';
import 'field_work.dart';

// What Classic draws on the map (ClassicLayer.tsx), worked out from the solution: a compass
// line for every bearing as soon as it is typed, where the azimuth lines cross (X), and how
// long each line is.

class CompassLine {
  const CompassLine({
    required this.index,
    required this.from,
    required this.bearing,
    required this.back,
    required this.text,
    required this.length,
    required this.end,
  });

  final int index; // the sighting
  final LngLat from;
  final double bearing; // true bearing
  final bool back; // the back azimuth (gold), else the azimuth (red)
  final String text;
  final double length; // metres
  final LngLat end;

  /// `sighting:main` or `sighting:back`, the key of a hand-set length
  String get key => '$index:${back ? 'back' : 'main'}';
}

/// Every bearing typed so far, as a line from its point: resection, from your position (the
/// azimuth toward each point in red, its back azimuth the opposite way in gold); intersection,
/// from each position (the azimuth toward the object, crossing at X, and its back azimuth)
class ClassicDrawing {
  ClassicDrawing._(this.lines, this.crossing, this.checked);

  factory ClassicDrawing.of(ClassicSolution sol, ClassicMode mode, Map<String, double> lineLengths) {
    final resection = mode == ClassicMode.resection;
    final d = sol.declination.value ?? 0;
    final raw = <({int index, LngLat from, double bearing, bool back, String text})>[];
    for (final (index, s) in sol.sightings.indexed) {
      final point = s.point;
      if (point == null || !s.open) continue;
      final letter = String.fromCharCode(65 + index);
      final az = s.azimuth.value;
      if (az != null) {
        raw.add((
          index: index,
          from: point,
          bearing: normalize360(az + d),
          back: false,
          text: resection ? '$letter · Az ${formatCompass(az)}' : 'Az ${formatCompass(az)}',
        ));
      }
      final back = s.back.value;
      if (s.backOpen && back != null) {
        raw.add((
          index: index,
          from: point,
          bearing: normalize360(back + d),
          back: true,
          text: resection ? '$letter · Back ${formatCompass(back)}' : 'Back ${formatCompass(back)}',
        ));
      }
    }

    // Where the azimuth lines cross, as typed (the back azimuths point away from the object);
    // resection lines all start at your position, so there is nothing to cross
    Fix? live;
    final toObject = [
      for (final l in raw)
        if (!l.back) Line(from: l.from, bearing: l.bearing),
    ];
    if (!resection && toObject.length >= 2) {
      final f = fixFromLines(toObject);
      if (f != null && f.along.every((a) => a > 0)) live = f;
    }

    // Each line's length: set by hand (dragging its end), or one that fits the exercise. Not
    // from the real point: how far the lines reach must not hint where the answer is.
    final known = [
      for (final s in sol.sightings)
        if (s.point != null) s.point!,
    ];
    var spread = 1000.0;
    for (final a in known) {
      for (final b in known) {
        spread = math.max(spread, bearingTo(a, b).distance);
      }
    }
    final crossing = sol.fix?.point ?? live?.point;
    final lines = [
      for (final l in raw)
        () {
          // Intersection lines run well past the crossing (about twice as far), so the cut reads
          // clearly; resection lines and lines before any crossing reach about the spread
          final toCrossing = crossing == null ? 0.0 : bearingTo(l.from, crossing).distance * (resection ? 1.3 : 2.2);
          final auto =
              math.max(resection ? 300.0 : 800.0, toCrossing != 0 ? toCrossing : spread * (resection ? 1.5 : 2.5)) *
              (l.back ? 0.6 : 1);
          final key = '${l.index}:${l.back ? 'back' : 'main'}';
          final length = lineLengths[key] ?? auto;
          return CompassLine(
            index: l.index,
            from: l.from,
            bearing: l.bearing,
            back: l.back,
            text: l.text,
            length: length,
            end: turfDestination(l.from, length, l.bearing > 180 ? l.bearing - 360 : l.bearing),
          );
        }(),
    ];
    return ClassicDrawing._(lines, sol.fix ?? live, sol.fix != null);
  }

  final List<CompassLine> lines;

  /// The checked answer, or the crossing as typed
  final Fix? crossing;

  /// Every step is checked: [crossing] is the answer
  final bool checked;
}

/// A line's new length when its end is dragged: kept on the line, so the direction and the
/// start never change (50 m to 200 km)
double draggedLength(CompassLine l, LngLat to) => lengthAlong(l.from, l.bearing, to).clamp(50, 200000).toDouble();

/// A circle of [radiusM] metres around [center], as a polygon ring (the likely area of X)
List<LngLat> circleRing(LngLat center, double radiusM, {int steps = 72}) => [
  for (var i = 0; i <= steps; i++) turfDestination(center, radiusM, -180 + 360 * i / steps),
];
