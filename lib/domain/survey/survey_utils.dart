import 'dart:math' as math;

import '../geo/spherical.dart';

// Port of src/utils/surveyUtils.ts (web). Keep the operations in the same order: the
// parity tests compare results with the web to 6+ decimals.

/// How the survey line bends at a point: a curve through it (default) or a sharp corner
enum PointCorner { smooth, sharp }

/// Bezier handle dragged out from a point, in meters east/north
class SurveyHandle {
  const SurveyHandle({required this.east, required this.north});

  final double east;
  final double north;

  @override
  bool operator ==(Object other) => other is SurveyHandle && other.east == east && other.north == north;

  @override
  int get hashCode => Object.hash(east, north);

  @override
  String toString() => 'SurveyHandle($east, $north)';
}

/// The parts of a survey point the line drawing needs
class LinePoint {
  const LinePoint({required this.lng, required this.lat, this.corner, this.handle});

  final double lng;
  final double lat;
  final PointCorner? corner;
  final SurveyHandle? handle;
}

class AzimuthData {
  const AzimuthData({
    required this.forwardAzimuth,
    required this.backAzimuth,
    required this.horizontalDistance,
    required this.slope,
    required this.slopeDegrees,
    required this.elevationDiff,
  });

  final double forwardAzimuth; // degrees
  final double backAzimuth; // degrees
  final double horizontalDistance; // meters
  final double slope; // percent
  final double slopeDegrees; // degrees
  final double elevationDiff; // meters
}

class GeodesicResult {
  const GeodesicResult({required this.distance, required this.initialBearing, required this.finalBearing});

  final double distance; // meters
  final double initialBearing; // degrees 0..360
  final double finalBearing; // degrees 0..360, direction of travel on arrival
}

// WGS84 ellipsoid (the datum of GPS and the map)
const double _wgs84A = 6378137;
const double _wgs84F = 1 / 298.257223563;
const double _wgs84B = _wgs84A * (1 - _wgs84F);
double _toRad(double deg) => (deg * math.pi) / 180;
double _toDeg(double rad) => (rad * 180) / math.pi;
double _hypot(double a, double b) => math.sqrt(a * a + b * b);

/// Distance and bearings between two points on the WGS84 ellipsoid (Vincenty's inverse
/// formula). Falls back to a spherical result for nearly antipodal points, where the
/// iteration does not converge.
GeodesicResult geodesicInverse(double lat1, double lng1, double lat2, double lng2) {
  const zero = GeodesicResult(distance: 0, initialBearing: 0, finalBearing: 0);
  if (lat1 == lat2 && lng1 == lng2) return zero;

  final l = _toRad(lng2 - lng1);
  final u1 = math.atan((1 - _wgs84F) * math.tan(_toRad(lat1)));
  final u2 = math.atan((1 - _wgs84F) * math.tan(_toRad(lat2)));
  final sinU1 = math.sin(u1), cosU1 = math.cos(u1);
  final sinU2 = math.sin(u2), cosU2 = math.cos(u2);

  var lambda = l;
  var sinSigma = 0.0, cosSigma = 0.0, sigma = 0.0, cos2Alpha = 0.0, cos2SigmaM = 0.0;
  var sinLambda = 0.0, cosLambda = 0.0;
  var converged = false;

  for (var i = 0; i < 200; i++) {
    sinLambda = math.sin(lambda);
    cosLambda = math.cos(lambda);
    sinSigma = _hypot(cosU2 * sinLambda, cosU1 * sinU2 - sinU1 * cosU2 * cosLambda);
    if (sinSigma == 0) return zero;
    cosSigma = sinU1 * sinU2 + cosU1 * cosU2 * cosLambda;
    sigma = math.atan2(sinSigma, cosSigma);
    final sinAlpha = (cosU1 * cosU2 * sinLambda) / sinSigma;
    cos2Alpha = 1 - sinAlpha * sinAlpha;
    cos2SigmaM = cos2Alpha != 0 ? cosSigma - (2 * sinU1 * sinU2) / cos2Alpha : 0; // 0 on the equator
    final c = (_wgs84F / 16) * cos2Alpha * (4 + _wgs84F * (4 - 3 * cos2Alpha));
    final prev = lambda;
    lambda =
        l +
        (1 - c) *
            _wgs84F *
            sinAlpha *
            (sigma + c * sinSigma * (cos2SigmaM + c * cosSigma * (-1 + 2 * cos2SigmaM * cos2SigmaM)));
    if ((lambda - prev).abs() < 1e-12) {
      converged = true;
      break;
    }
  }

  if (!converged) {
    final from = (lng1, lat1);
    final to = (lng2, lat2);
    return GeodesicResult(
      distance: turfDistance(from, to),
      initialBearing: (turfBearing(from, to) + 360).remainder(360),
      finalBearing: (turfFinalBearing(from, to) + 360).remainder(360),
    );
  }

  final uSq = (cos2Alpha * (_wgs84A * _wgs84A - _wgs84B * _wgs84B)) / (_wgs84B * _wgs84B);
  final a = 1 + (uSq / 16384) * (4096 + uSq * (-768 + uSq * (320 - 175 * uSq)));
  final b = (uSq / 1024) * (256 + uSq * (-128 + uSq * (74 - 47 * uSq)));
  final deltaSigma =
      b *
      sinSigma *
      (cos2SigmaM +
          (b / 4) *
              (cosSigma * (-1 + 2 * cos2SigmaM * cos2SigmaM) -
                  (b / 6) * cos2SigmaM * (-3 + 4 * sinSigma * sinSigma) * (-3 + 4 * cos2SigmaM * cos2SigmaM)));

  final alpha1 = math.atan2(cosU2 * sinLambda, cosU1 * sinU2 - sinU1 * cosU2 * cosLambda);
  final alpha2 = math.atan2(cosU1 * sinLambda, -sinU1 * cosU2 + cosU1 * sinU2 * cosLambda);

  return GeodesicResult(
    distance: _wgs84B * a * (sigma - deltaSigma),
    initialBearing: (_toDeg(alpha1) + 360).remainder(360),
    finalBearing: (_toDeg(alpha2) + 360).remainder(360),
  );
}

/// Survey data between two points (lat, lng, elevation in meters)
AzimuthData getAzimuthData(
  ({double lat, double lng, double elevation}) p1,
  ({double lat, double lng, double elevation}) p2,
) {
  final geo = geodesicInverse(p1.lat, p1.lng, p2.lat, p2.lng);
  final rise = p2.elevation - p1.elevation;
  final run = geo.distance;
  return AzimuthData(
    forwardAzimuth: geo.initialBearing,
    // On an ellipsoid the way back is the arrival bearing + 180°
    backAzimuth: (geo.finalBearing + 180).remainder(360),
    horizontalDistance: run,
    slope: run > 0 ? (rise / run) * 100 : 0,
    slopeDegrees: run > 0 ? math.atan(rise / run) * (180 / math.pi) : 0,
    elevationDiff: rise,
  );
}

/// "DDD.D°"
String formatDegrees(double deg) => '${deg.toStringAsFixed(1).padLeft(5, '0')}°';

String formatDistance(double meters) =>
    meters >= 1000 ? '${(meters / 1000).toStringAsFixed(2)} km' : '${meters.toStringAsFixed(1)} m';

/// Decimal degrees to DMS, e.g. 6°14'11.11" S
String toDMS(double deg, {required bool isLat}) {
  // Round once in hundredths of a second, so 59.999" becomes the next minute, not 60.00"
  final totalHundredths = _jsRoundInt(deg.abs() * 360000);
  final degrees = totalHundredths ~/ 360000;
  final minutes = (totalHundredths % 360000) ~/ 6000;
  final seconds = ((totalHundredths % 6000) / 100).toStringAsFixed(2);
  final hemisphere = isLat ? (deg >= 0 ? 'N' : 'S') : (deg >= 0 ? 'E' : 'W');
  return '$degrees°$minutes\'$seconds" $hemisphere';
}

int _jsRoundInt(double x) {
  final floor = x.floorToDouble();
  return (x - floor >= 0.5 ? floor + 1 : floor).toInt();
}

/// WGS84 latitude/longitude to a UTM string, e.g. "48S 701234 mE 9312345 mN"
String toUTM(double lat, double lon) {
  const a = 6378137.0;
  const f = 1 / 298.257223563;
  const k0 = 0.9996;

  final e = math.sqrt(f * (2 - f));
  final eSq = e * e;
  final ePrimeSq = eSq / (1 - eSq);

  final latRad = (lat * math.pi) / 180;
  final lonRad = (lon * math.pi) / 180;

  final zoneNumber = ((lon + 180) / 6).floor() + 1;
  final lonOrigin = (zoneNumber - 1) * 6 - 180 + 3;
  final lonOriginRad = (lonOrigin * math.pi) / 180;

  double sq(double v) => v * v;
  double pw(double v, int n) => math.pow(v, n).toDouble();

  final n = a / math.sqrt(1 - eSq * sq(math.sin(latRad)));
  final t = sq(math.tan(latRad));
  final c = ePrimeSq * sq(math.cos(latRad));
  final aa = math.cos(latRad) * (lonRad - lonOriginRad);

  final m =
      a *
      ((1 - eSq / 4 - (3 * pw(eSq, 2)) / 64 - (5 * pw(eSq, 3)) / 256) * latRad -
          ((3 * eSq) / 8 + (3 * pw(eSq, 2)) / 32 + (45 * pw(eSq, 3)) / 1024) * math.sin(2 * latRad) +
          ((15 * pw(eSq, 2)) / 256 + (45 * pw(eSq, 3)) / 1024) * math.sin(4 * latRad) -
          ((35 * pw(eSq, 3)) / 3072) * math.sin(6 * latRad));

  final easting =
      k0 *
          n *
          (aa + ((1 - t + c) * pw(aa, 3)) / 6 + ((5 - 18 * t + pw(t, 2) + 72 * c - 58 * ePrimeSq) * pw(aa, 5)) / 120) +
      500000.0;

  var northing =
      k0 *
      (m +
          n *
              math.tan(latRad) *
              (pw(aa, 2) / 2 +
                  ((5 - t + 9 * c + 4 * pw(c, 2)) * pw(aa, 4)) / 24 +
                  ((61 - 58 * t + pw(t, 2) + 600 * c - 330 * ePrimeSq) * pw(aa, 6)) / 720));

  final hemisphere = lat >= 0 ? 'N' : 'S';
  if (lat < 0) northing += 10000000.0;

  return '$zoneNumber$hemisphere ${_jsRoundInt(easting)} mE ${_jsRoundInt(northing)} mN';
}

/// Snaps the direction of the segment last -> target to a multiple of [step] degrees: the
/// turn from the previous segment prev -> last when there is one, otherwise the azimuth
/// from north. The distance follows the cursor along the snapped direction.
LngLat snapToAngle(LngLat? prev, LngLat last, LngLat target, double step) {
  final base = prev != null ? turfBearing(prev, last) : 0.0;
  final bearing = turfBearing(last, target);
  final distance = turfDistance(last, target);

  final turn = ((bearing - base).remainder(360) + 540).remainder(360) - 180; // -180..180
  final snappedTurn = _jsRoundInt(turn / step) * step;
  final along = distance * math.cos(((turn - snappedTurn) * math.pi) / 180);

  return turfDestination(last, along, base + snappedTurn);
}

// Local flat coordinates in meters (x = east, y = north) around an origin, accurate enough
// for drawing curves between nearby survey points
const double _metersPerDegree = (math.pi / 180) * 6378137;

LngLat _toLocal(LngLat origin, LngLat p) =>
    ((p.$1 - origin.$1) * _metersPerDegree * math.cos(_toRad(origin.$2)), (p.$2 - origin.$2) * _metersPerDegree);

LngLat _fromLocal(LngLat origin, LngLat xy) =>
    (origin.$1 + xy.$1 / (_metersPerDegree * math.cos(_toRad(origin.$2))), origin.$2 + xy.$2 / _metersPerDegree);

/// Bezier handle (meters east/north) pointing from the point towards the dragged target
SurveyHandle handleFromDrag(({double lng, double lat}) point, LngLat target) {
  final local = _toLocal((point.lng, point.lat), target);
  return SurveyHandle(east: local.$1, north: local.$2);
}

/// Ends of a point's two handles: `out` towards the next point, `in` towards the previous
({LngLat out, LngLat inEnd}) handleEnds(({double lng, double lat}) point, SurveyHandle handle) {
  final origin = (point.lng, point.lat);
  return (
    out: _fromLocal(origin, (handle.east, handle.north)),
    inEnd: _fromLocal(origin, (-handle.east, -handle.north)),
  );
}

class _Segment {
  _Segment(this.p0, this.c1, this.c2, this.p3, {required this.straight});
  final LngLat p0, c1, c2, p3;
  final bool straight;
}

/// Cubic Bezier control points of every segment, in local meters around the first point.
/// A point with a handle uses it on both sides; a smooth point without one gets an
/// automatic tangent (Catmull-Rom); a sharp point and the two ends of the line get none.
(LngLat, List<_Segment>) _segmentControls(List<LinePoint> points) {
  final origin = (points[0].lng, points[0].lat);
  final xy = [for (final p in points) _toLocal(origin, (p.lng, p.lat))];
  final last = points.length - 1;

  LngLat tangent(int i) {
    final h = points[i].handle;
    if (h != null) return (h.east, h.north);
    if (points[i].corner == PointCorner.sharp || i == 0 || i == last) return (0, 0);
    return ((xy[i + 1].$1 - xy[i - 1].$1) / 6, (xy[i + 1].$2 - xy[i - 1].$2) / 6);
  }

  final tangents = [for (var i = 0; i < points.length; i++) tangent(i)];
  final segments = <_Segment>[];
  for (var i = 0; i < last; i++) {
    final p0 = xy[i], p3 = xy[i + 1];
    final c1 = (p0.$1 + tangents[i].$1, p0.$2 + tangents[i].$2);
    final c2 = (p3.$1 - tangents[i + 1].$1, p3.$2 - tangents[i + 1].$2);
    final straight = c1.$1 == p0.$1 && c1.$2 == p0.$2 && c2.$1 == p3.$1 && c2.$2 == p3.$2;
    segments.add(_Segment(p0, c1, c2, p3, straight: straight));
  }
  return (origin, segments);
}

LngLat _bezierAt(_Segment s, double t) {
  final u = 1 - t;
  final a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t;
  return (a * s.p0.$1 + b * s.c1.$1 + c * s.c2.$1 + d * s.p3.$1, a * s.p0.$2 + b * s.c1.$2 + c * s.c2.$2 + d * s.p3.$2);
}

const int _curveSamples = 32;

/// Coordinates of a survey line: straight segments, sharp corners and Bezier curves as set
/// per point. The survey points themselves are always on the line.
List<LngLat> buildSurveyLine(List<LinePoint> points) {
  if (points.length < 2) return [for (final p in points) (p.lng, p.lat)];
  final (origin, segments) = _segmentControls(points);

  final line = <LngLat>[(points[0].lng, points[0].lat)];
  for (var i = 0; i < segments.length; i++) {
    final s = segments[i];
    if (!s.straight) {
      for (var k = 1; k < _curveSamples; k++) {
        line.add(_fromLocal(origin, _bezierAt(s, k / _curveSamples)));
      }
    }
    line.add((points[i + 1].lng, points[i + 1].lat));
  }
  return line;
}

/// Middle of each drawn segment (on the curve when it bends), for its distance label
List<LngLat> segmentMidpoints(List<LinePoint> points) {
  if (points.length < 2) return const [];
  final (origin, segments) = _segmentControls(points);
  return [for (final s in segments) _fromLocal(origin, _bezierAt(s, 0.5))];
}
