import 'dart:math' as math;

import '../geo/spherical.dart' show LngLat;
import '../survey/survey_utils.dart' show geodesicInverse;
import '../util/js_compat.dart';

// Classic (classicNav.ts on the web): learn resection and intersection the map-and-compass
// way, with every coordinate typed in degrees, minutes and seconds and every bearing in
// compass degrees. The maths and the hints live here; the screen is ClassicPanel and the map
// drawing ClassicLayer.

class DmsInput {
  const DmsInput({this.d = '', this.m = '', this.s = ''});

  factory DmsInput.fromJson(Map<String, dynamic>? j) =>
      DmsInput(d: '${j?['d'] ?? ''}', m: '${j?['m'] ?? ''}', s: '${j?['s'] ?? ''}');

  final String d;
  final String m;
  final String s;

  DmsInput copyWith({String? d, String? m, String? s}) => DmsInput(d: d ?? this.d, m: m ?? this.m, s: s ?? this.s);

  Map<String, String> toJson() => {'d': d, 'm': m, 's': s};

  @override
  bool operator ==(Object other) => other is DmsInput && other.d == d && other.m == m && other.s == s;

  @override
  int get hashCode => Object.hash(d, m, s);
}

/// A typed value: a number, or why not (null error with a null value: nothing typed yet)
class Parsed {
  const Parsed.value(double this.value) : error = null;
  const Parsed.error(this.error) : value = null;
  const Parsed.empty() : value = null, error = null;

  final double? value;
  final String? error;
}

bool _blank(String v) => v.trim().isEmpty;
double _num(String v) => jsNumber(v.trim().replaceFirst(',', '.'));
bool _isInteger(double v) => v.isFinite && v == v.truncateToDouble();

/// Degrees, minutes, seconds to decimal degrees. [maxDeg] is 90 for latitude, 180 for
/// longitude, 360 for a bearing (which must stay under 360°).
Parsed parseDms(DmsInput input, int maxDeg, String what) {
  if (_blank(input.d) && _blank(input.m) && _blank(input.s)) return const Parsed.empty();
  if (_blank(input.d)) return Parsed.error('Enter the degrees of the $what.');
  final d = _num(input.d);
  final m = _blank(input.m) ? 0.0 : _num(input.m);
  final s = _blank(input.s) ? 0.0 : _num(input.s);
  if ([d, m, s].any((v) => !v.isFinite)) return Parsed.error('Use numbers only in the $what.');
  if (d < 0 || m < 0 || s < 0) return const Parsed.error('No minus signs: the direction comes from N/S or E/W.');
  if (!_isInteger(d) || !_isInteger(m)) {
    return const Parsed.error('Degrees and minutes are whole numbers; put the fraction in the seconds.');
  }
  if (m >= 60) return const Parsed.error("Minutes go from 0 to 59 (60' is 1°).");
  if (s >= 60) return const Parsed.error('Seconds go from 0 to 59.99 (60" is 1\').');
  final value = d + m / 60 + s / 3600;
  if (maxDeg == 360 ? value >= 360 : value > maxDeg) {
    return Parsed.error(
      maxDeg == 360
          ? 'A bearing goes from 0° to 359° 59\' 59". 360° is north again, so write 0°.'
          : 'The $what cannot be more than $maxDeg°.',
    );
  }
  return Parsed.value(value);
}

/// Decimal degrees to DMS fields (seconds to 2 decimals, carried so 60" never shows)
DmsInput toDmsInput(double deg) {
  final hundredths = jsRound(deg.abs() * 360000).toInt();
  final d = hundredths ~/ 360000;
  final m = (hundredths % 360000) ~/ 6000;
  final s = (hundredths % 6000) / 100;
  return DmsInput(d: '$d', m: '$m', s: jsNum(double.parse(s.toStringAsFixed(2))));
}

/// A compass reading in degrees, 0–360 (360 is north again, the same as 0); decimals allowed
Parsed parseCompass(String text, String what) {
  var t = text.trim().replaceFirst(',', '.');
  if (t.endsWith('°')) t = t.substring(0, t.length - 1);
  if (t.isEmpty) return const Parsed.empty();
  if (!RegExp(r'^-?\d+(\.\d+)?$').hasMatch(t)) {
    return Parsed.error('Type the $what as compass degrees, e.g. 114 or 114.5.');
  }
  final v = double.parse(t);
  if (v < 0) return const Parsed.error('A compass has no negative degrees: go clockwise from north, 0 to 360.');
  if (v > 360) return Parsed.error('A compass goes from 0° to 360°. Subtract 360° from ${jsNum(v)}°.');
  return Parsed.value(v == 360 ? 0 : v);
}

double normalize360(double deg) => jsMod(jsMod(deg, 360) + 360, 360);

/// A compass reading as 114° or 114.5° (to a tenth)
String formatCompass(double deg) {
  final v = jsRound(normalize360(deg) * 10) / 10;
  return '${jsNum(v == 360 ? 0 : v)}°';
}

const _points = ['N', 'NNE', 'NE', 'ENE', 'E', 'ESE', 'SE', 'SSE', 'S', 'SSW', 'SW', 'WSW', 'W', 'WNW', 'NW', 'NNW'];

/// The compass point of a bearing (16 points: N, NNE, NE ...)
String compassPoint(double deg) => _points[jsRound(normalize360(deg) / 22.5).toInt() % 16];

// The 16 compass points in Indonesian, for the hints (the labels stay in English, as on compasses)
const _namesId = {
  'N': 'Utara',
  'NNE': 'Utara-Timur Laut',
  'NE': 'Timur Laut',
  'ENE': 'Timur-Timur Laut',
  'E': 'Timur',
  'ESE': 'Timur-Tenggara',
  'SE': 'Tenggara',
  'SSE': 'Selatan-Tenggara',
  'S': 'Selatan',
  'SSW': 'Selatan-Barat Daya',
  'SW': 'Barat Daya',
  'WSW': 'Barat-Barat Daya',
  'W': 'Barat',
  'WNW': 'Barat-Barat Laut',
  'NW': 'Barat Laut',
  'NNW': 'Utara-Barat Laut',
};
const _namesEn = {
  'N': 'North',
  'NNE': 'North-NorthEast',
  'NE': 'NorthEast',
  'ENE': 'East-NorthEast',
  'E': 'East',
  'ESE': 'East-SouthEast',
  'SE': 'SouthEast',
  'SSE': 'South-SouthEast',
  'S': 'South',
  'SSW': 'South-SouthWest',
  'SW': 'SouthWest',
  'WSW': 'West-SouthWest',
  'W': 'West',
  'WNW': 'West-NorthWest',
  'NW': 'NorthWest',
  'NNW': 'North-NorthWest',
};

/// "ENE = Timur-Timur Laut (East-NorthEast), sekitar 56°–79°"
String compassPointHint(String abbr) {
  final i = _points.indexOf(abbr);
  final from = normalize360(i * 22.5 - 11.25);
  final to = i * 22.5 + 11.25;
  return '$abbr = ${_namesId[abbr]} (${_namesEn[abbr]}), sekitar ${from.ceil()}°–${to.floor()}°';
}

/// All 16 points with their centre bearing and Indonesian name, for the hint table
final compassPoints = [for (final (i, abbr) in _points.indexed) (abbr: abbr, deg: i * 22.5, id: _namesId[abbr]!)];

/// a − b, between −180° and 180° (positive: a is clockwise of b)
double angleDiff(double a, double b) {
  final d = normalize360(a - b);
  return d > 180 ? d - 360 : d;
}

double backAzimuthOf(double az) => normalize360(az + 180);

// --- Where two lines cross ---------------------------------------------------------------

const _a = 6378137.0;
const _e2 = 0.00669437999014; // WGS84 first eccentricity squared
double _rad(double d) => d * math.pi / 180;

// Metres east / north of an origin, on the plane touching the ellipsoid there
({List<double> Function(LngLat) to, LngLat Function(double x, double y) from}) _plane(LngLat origin) {
  final phi = _rad(origin.$2);
  final w = math.sqrt(1 - _e2 * math.pow(math.sin(phi), 2));
  final n = _a / w; // prime vertical radius
  final m = _a * (1 - _e2) / math.pow(w, 3); // meridian radius
  final kx = _rad(1) * n * math.cos(phi);
  final ky = _rad(1) * m;
  return (
    to: (p) => [(p.$1 - origin.$1) * kx, (p.$2 - origin.$2) * ky],
    from: (x, y) => (origin.$1 + x / kx, origin.$2 + y / ky),
  );
}

class Fix {
  const Fix({required this.point, required this.along, required this.misses, required this.cutAngle});

  final LngLat point;

  /// Metres from each line's start along its bearing; negative = behind the start
  final List<double> along;

  /// Metres from the fix to each line (0 for every line when there are two)
  final List<double> misses;

  /// The widest angle between any two lines, 0–90° (90° is the strongest cut)
  final double cutAngle;
}

class Line {
  const Line({required this.from, required this.bearing});
  final LngLat from;
  final double bearing;
}

/// The point closest to every line (least squares; with two lines, where they cross), or null
/// when the lines are all parallel. Solved on a plane touching the ellipsoid, re-centred on
/// the answer.
Fix? fixFromLines(List<Line> lines) {
  var cutAngle = 0.0;
  for (var i = 0; i < lines.length; i++) {
    for (var j = 0; j < i; j++) {
      final diff = angleDiff(lines[i].bearing, lines[j].bearing).abs();
      cutAngle = math.max(cutAngle, diff > 90 ? 180 - diff : diff);
    }
  }
  if (lines.length < 2 || cutAngle < 0.05) return null;

  LngLat origin = (
    lines.fold(0.0, (n, l) => n + l.from.$1) / lines.length,
    lines.fold(0.0, (n, l) => n + l.from.$2) / lines.length,
  );
  Fix? fix;
  for (var iter = 0; iter < 3; iter++) {
    final plane = _plane(origin);
    final geo = [
      for (final l in lines)
        () {
          final xy = plane.to(l.from);
          final d = [math.sin(_rad(l.bearing)), math.cos(_rad(l.bearing))];
          return (x: xy[0], y: xy[1], d: d, n: [d[1], -d[0]]);
        }(),
    ];
    // Sum of n·nᵀ times the point = sum of n·nᵀ times each start
    var a = 0.0, b = 0.0, c = 0.0, r1 = 0.0, r2 = 0.0;
    for (final g in geo) {
      a += g.n[0] * g.n[0];
      b += g.n[0] * g.n[1];
      c += g.n[1] * g.n[1];
      final k = g.n[0] * g.x + g.n[1] * g.y;
      r1 += g.n[0] * k;
      r2 += g.n[1] * k;
    }
    final det = a * c - b * b;
    final px = (c * r1 - b * r2) / det;
    final py = (a * r2 - b * r1) / det;
    fix = Fix(
      point: plane.from(px, py),
      along: [for (final g in geo) (px - g.x) * g.d[0] + (py - g.y) * g.d[1]],
      misses: [for (final g in geo) ((px - g.x) * g.n[0] + (py - g.y) * g.n[1]).abs()],
      cutAngle: cutAngle,
    );
    origin = fix.point;
  }
  return fix;
}

/// True bearing and distance from a to b
({double bearing, double distance}) bearingTo(LngLat a, LngLat b) {
  final g = geodesicInverse(a.$2, a.$1, b.$2, b.$1);
  return (bearing: g.initialBearing, distance: g.distance);
}

/// How far along a line (from [from], on [bearing]) the point [to] lies, in metres: the
/// point is projected onto the line, so dragging sideways does not change the line
double lengthAlong(LngLat from, double bearing, LngLat to) {
  final g = bearingTo(from, to);
  return g.distance * math.cos(_rad(g.bearing - bearing));
}

/// How far off a hand compass usually is (degrees)
const compassErrorDeg = 2.0;

/// Radius (metres) of the area the object most likely lies in (fixRadius in classicNav.ts)
double fixRadius(Fix fix, [double errorDeg = compassErrorDeg]) {
  final far = fix.along.map((a) => a.abs()).reduce(math.max);
  final cut = math.max(fix.cutAngle, 5.0);
  var r = far * math.tan(_rad(errorDeg)) / math.sin(_rad(cut));
  if (fix.misses.length >= 3) r = math.max(r, fix.misses.reduce(math.max) * 1.5);
  return math.min(5000, math.max(15, r));
}

// --- Hints -----------------------------------------------------------------------------------

enum Verdict { ok, close, off }

class Check {
  const Check(this.verdict, this.message);
  final Verdict verdict;
  final String message;
}

/// A back azimuth against the azimuth it belongs to (to a tenth of a degree)
Check checkBackAzimuth(double back, double azimuth) {
  final expected = backAzimuthOf(azimuth);
  if (angleDiff(back, expected).abs() < 0.05) return const Check(Verdict.ok, 'Correct.');
  if (angleDiff(back, azimuth).abs() < 0.05) {
    return const Check(Verdict.off, 'That is the azimuth itself. The back azimuth points the opposite way.');
  }
  final rule = azimuth < 180
      ? '${formatCompass(azimuth)} is less than 180°, so add 180°.'
      : '${formatCompass(azimuth)} is 180° or more, so subtract 180°.';
  // Whole degrees right, the decimals changed
  final wholeRight = back.floor() == expected.floor();
  return Check(
    Verdict.off,
    wholeRight ? 'The whole degrees are right. Keep the decimals exactly as in the azimuth.' : rule,
  );
}

String metresText(double m) => m >= 1000 ? '${(m / 1000).toStringAsFixed(1)} km' : '${jsRoundStr(m)} m';

/// Hints on the fix: a weak cut and the triangle of error (three or more lines). [labels]
/// names each line.
List<Check> reviewFix(Fix fix, List<Line> lines, String mode, List<String> labels) {
  final out = <Check>[];
  final resection = mode == 'resection';
  final span = math.max(1.0, fix.along.fold(0.0, (n, a) => n + a.abs()) / fix.along.length);
  if (fix.cutAngle < 30) {
    out.add(
      Check(
        Verdict.close,
        'The lines cross at a shallow ${jsRoundStr(fix.cutAngle)}°, so a small reading error moves the answer a lot. '
        'Choose ${resection ? 'reference points' : 'positions'} so the lines meet at 30–150° '
        '(seen from ${resection ? 'you' : 'the object'}).',
      ),
    );
  }
  if (lines.length >= 3) {
    // The triangle (or polygon) of error: how far apart the lines cross, pair by pair
    final crossings = <LngLat>[];
    for (var i = 0; i < lines.length; i++) {
      for (var j = 0; j < i; j++) {
        final pair = fixFromLines([lines[i], lines[j]]);
        if (pair != null) crossings.add(pair.point);
      }
    }
    var size = 0.0;
    for (final p in crossings) {
      for (final q in crossings) {
        size = math.max(size, bearingTo(p, q).distance);
      }
    }
    if (size <= math.max(50, span * 0.06)) {
      out.add(
        Check(Verdict.ok, 'All ${lines.length} lines meet within ${metresText(size)}: a tight triangle of error.'),
      );
    } else {
      // With four or more lines: the slip is the line whose removal lets all the others meet
      int? culprit;
      if (lines.length >= 4) {
        final spreads = [
          for (var i = 0; i < lines.length; i++)
            () {
              final rest = fixFromLines([
                for (var k = 0; k < lines.length; k++)
                  if (k != i) lines[k],
              ]);
              return rest == null ? double.infinity : rest.misses.reduce(math.max);
            }(),
        ];
        final sorted = [...spreads]..sort();
        if (sorted[0] * 3 < sorted[1]) culprit = spreads.indexOf(sorted[0]);
      }
      out.add(
        Check(
          Verdict.off,
          culprit != null
              ? 'The line from ${labels[culprit]} misses the others. Its azimuth or back azimuth is the most likely slip.'
              : 'The lines cross ${metresText(size)} apart (the triangle of error). One reading is off: take them '
                    'again, starting with the one you are least sure of.',
        ),
      );
    }
  }
  return out;
}
