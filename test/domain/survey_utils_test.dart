import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/domain/geo/spherical.dart';
import 'package:landscape360/domain/survey/survey_utils.dart';

// Same cases as src/utils/surveyUtils.test.ts (web)

double _bearing(LngLat a, LngLat b) => turfBearing(a, b);
double _turnBetween(LngLat prev, LngLat last, LngLat next) {
  final t = _bearing(last, next) - _bearing(prev, last);
  return (t.remainder(360) + 540).remainder(360) - 180;
}

double _dms(double d, double m, double s) => d.sign * (d.abs() + m / 60 + s / 3600);

void main() {
  group('snapToAngle', () {
    const prev = (106.75, -6.235);
    const last = (106.75, -6.234); // heading north

    test('turns a near-right turn into exactly 90°', () {
      final snapped = snapToAngle(prev, last, (106.751, -6.2338), 90);
      expect(_turnBetween(prev, last, snapped), closeTo(90, 5e-4));
    });

    test('turns a near-left turn into exactly -90° on a diagonal line', () {
      const diagPrev = (106.75, -6.235);
      const diagLast = (106.751, -6.234);
      final snapped = snapToAngle(diagPrev, diagLast, (106.7505, -6.2334), 90);
      expect(_turnBetween(diagPrev, diagLast, snapped), closeTo(-90, 5e-4));
    });

    test('keeps going straight when the cursor is almost in line', () {
      final snapped = snapToAngle(prev, last, (106.7501, -6.233), 90);
      expect(_turnBetween(prev, last, snapped), closeTo(0, 5e-4));
    });

    test('snaps to 45° steps', () {
      final snapped = snapToAngle(prev, last, (106.7508, -6.2333), 45);
      expect(_turnBetween(prev, last, snapped), closeTo(45, 5e-4));
    });

    test('snaps the azimuth from north for the first segment', () {
      final snapped = snapToAngle(null, last, (106.7512, -6.2338), 90);
      expect((_bearing(last, snapped) + 360).remainder(360), closeTo(90, 5e-4));
    });

    test('uses the distance along the snapped direction', () {
      const target = (106.751, -6.234);
      final snapped = snapToAngle(prev, last, target, 90);
      expect(turfDistance(last, snapped), closeTo(turfDistance(last, target), 0.5));
    });
  });

  group('geodesicInverse (WGS84)', () {
    test('matches the classic Flinders Peak -> Buninyong reference line', () {
      final r = geodesicInverse(
        _dms(-37, 57, 3.7203),
        _dms(144, 25, 29.5244),
        _dms(-37, 39, 10.1561),
        _dms(143, 55, 35.3839),
      );
      expect(r.distance, closeTo(54972.271, 5e-3));
      expect(r.initialBearing, closeTo(_dms(306, 52, 5.37), 5e-5));
      expect(r.finalBearing, closeTo(_dms(127, 10, 25.07) + 180, 5e-5));
    });

    test('measures 1" of latitude near Jakarta as ~30.7 m, unlike the sphere', () {
      expect(geodesicInverse(-6.2, 106.8, -6.2 + 1 / 3600, 106.8).distance, closeTo(30.72, 0.05));
    });

    test('returns zero for the same point', () {
      expect(geodesicInverse(-6.2, 106.8, -6.2, 106.8).distance, 0);
    });
  });

  group('getAzimuthData', () {
    ({double lat, double lng, double elevation}) pt(double lat, double lng, [double elevation = 0]) =>
        (lat: lat, lng: lng, elevation: elevation);

    test('gives due east as 090° with the reverse direction as back azimuth', () {
      final d = getAzimuthData(pt(-6.2, 106.8), pt(-6.2, 106.801));
      expect(d.forwardAzimuth, closeTo(90, 0.05));
      expect(d.backAzimuth, closeTo(270, 0.05));
      expect(d.horizontalDistance, closeTo(110.6, 0.5));
    });

    test('computes slope from the elevation difference', () {
      final d = getAzimuthData(pt(-6.2, 106.8, 10), pt(-6.2, 106.801, 21.06));
      expect(d.slope, closeTo((11.06 / d.horizontalDistance) * 100, 5e-7));
    });
  });

  group('buildSurveyLine', () {
    const square = [
      LinePoint(lng: 106.75, lat: -6.235),
      LinePoint(lng: 106.75, lat: -6.234),
      LinePoint(lng: 106.751, lat: -6.234),
      LinePoint(lng: 106.751, lat: -6.235),
    ];
    LinePoint sharp(LinePoint p) => LinePoint(lng: p.lng, lat: p.lat, corner: PointCorner.sharp);
    bool has(List<LngLat> line, LinePoint p) => line.any((q) => q.$1 == p.lng && q.$2 == p.lat);

    test('curves through smooth points (default)', () {
      final line = buildSurveyLine(square);
      expect(line.length, greaterThan(square.length));
      expect(line.first, (square[0].lng, square[0].lat));
      expect(line.last, (square[3].lng, square[3].lat));
    });

    test('draws straight segments when every point is sharp', () {
      expect(buildSurveyLine(square.map(sharp).toList()), [for (final p in square) (p.lng, p.lat)]);
    });

    test('keeps a sharp corner exactly on its point while curving elsewhere', () {
      final pts = [...square, const LinePoint(lng: 106.752, lat: -6.2355)];
      final line = buildSurveyLine([for (var i = 0; i < pts.length; i++) i == 2 ? sharp(pts[i]) : pts[i]]);
      expect(has(line, pts[2]), isTrue);
      expect(line.length, greaterThan(pts.length));
    });

    test('bends a segment with a dragged Bezier handle and keeps the points on the line', () {
      const a = (lng: 106.75, lat: -6.235);
      const b = LinePoint(lng: 106.751, lat: -6.235);
      final handle = handleFromDrag(a, (106.7503, -6.2347)); // pulled north-east
      final pts = [LinePoint(lng: a.lng, lat: a.lat, handle: handle), b];
      final line = buildSurveyLine(pts);
      expect(line.length, greaterThan(2));
      expect(line.first, (a.lng, a.lat));
      expect(line.last, (b.lng, b.lat));
      // The curve bulges north of the straight east-west chord
      expect(segmentMidpoints(pts)[0].$2, greaterThan(a.lat));
    });

    test('turns a drag into a handle whose ends are opposite each other', () {
      const p = (lng: 106.75, lat: -6.235);
      final handle = handleFromDrag(p, (106.7501, -6.2349));
      expect(handle.east, greaterThan(0));
      expect(handle.north, greaterThan(0));
      final ends = handleEnds(p, handle);
      expect(ends.out.$1, closeTo(106.7501, 5e-10));
      expect(ends.out.$2, closeTo(-6.2349, 5e-10));
      expect(ends.inEnd.$1 + ends.out.$1, closeTo(2 * p.lng, 5e-10));
    });

    test('leaves two points as a straight line', () {
      expect(buildSurveyLine(square.sublist(0, 2)), hasLength(2));
    });
  });

  group('toDMS', () {
    test('formats degrees, minutes and seconds with the hemisphere', () {
      expect(toDMS(-6.23642, isLat: true), '6°14\'11.11" S');
      expect(toDMS(106.743808, isLat: false), '106°44\'37.71" E');
    });

    test('carries 59.999" into the next minute instead of printing 60.00"', () {
      expect(toDMS(6 + 13 / 60 + 59.999 / 3600, isLat: true), '6°14\'0.00" N');
      expect(toDMS(-(7 + 59 / 60 + 59.9999 / 3600), isLat: true), '8°0\'0.00" S');
    });
  });
}
