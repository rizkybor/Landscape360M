import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/domain/geo/spherical.dart';
import 'package:landscape360/domain/map/offline_regions.dart';
import 'package:landscape360/domain/marked/marked_areas.dart';
import 'package:landscape360/domain/share/share_location.dart';
import 'package:landscape360/domain/survey/survey_utils.dart';
import 'package:landscape360/domain/tracks/track_recorder_geo.dart';

// Compares the Dart ports with values computed by the web app's own TypeScript
// (test/fixtures/web_reference.json, made by tool/web_reference/generate.sh). Numbers must
// agree to 6 decimals, text exactly.

const _tolerance = 1e-6;

void main() {
  final ref = jsonDecode(File('test/fixtures/web_reference.json').readAsStringSync()) as Map<String, dynamic>;
  List<Map<String, dynamic>> rows(String key) => (ref[key] as List).cast<Map<String, dynamic>>();
  double d(Object? v) => (v! as num).toDouble();
  List<double> ds(Object? v) => (v! as List).map(d).toList();
  LngLat ll(Object? v) => (d((v! as List)[0]), d((v as List)[1]));
  Matcher near(Object? v) => closeTo(d(v), _tolerance);

  void expectLine(List<LngLat> actual, Object? expected) {
    final exp = (expected! as List).map(ll).toList();
    expect(actual, hasLength(exp.length));
    for (var i = 0; i < exp.length; i++) {
      expect(actual[i].$1, closeTo(exp[i].$1, 1e-9), reason: 'point $i lng');
      expect(actual[i].$2, closeTo(exp[i].$2, 1e-9), reason: 'point $i lat');
    }
  }

  test('geodesicInverse (Vincenty WGS84)', () {
    for (final r in rows('geodesic')) {
      final i = ds(r['input']);
      final g = geodesicInverse(i[0], i[1], i[2], i[3]);
      expect(g.distance, near(r['distance']), reason: '$i distance');
      expect(g.initialBearing, near(r['initialBearing']), reason: '$i initial');
      expect(g.finalBearing, near(r['finalBearing']), reason: '$i final');
    }
  });

  test('getAzimuthData', () {
    for (final r in rows('az')) {
      final i = ds(r['input']);
      final a = getAzimuthData((lat: i[0], lng: i[1], elevation: i[2]), (lat: i[3], lng: i[4], elevation: i[5]));
      expect(a.forwardAzimuth, near(r['forwardAzimuth']));
      expect(a.backAzimuth, near(r['backAzimuth']));
      expect(a.horizontalDistance, near(r['horizontalDistance']));
      expect(a.slope, near(r['slope']));
      expect(a.slopeDegrees, near(r['slopeDegrees']));
      expect(a.elevationDiff, near(r['elevationDiff']));
    }
  });

  test('snapToAngle', () {
    for (final r in rows('snap')) {
      final out = snapToAngle(r['prev'] == null ? null : ll(r['prev']), ll(r['last']), ll(r['target']), d(r['step']));
      expectLine([out], [r['result']]);
    }
  });

  test('buildSurveyLine and segmentMidpoints (Bezier)', () {
    LinePoint point(Map<String, dynamic> p) {
      final h = p['handle'] as Map<String, dynamic>?;
      return LinePoint(
        lng: d(p['lng']),
        lat: d(p['lat']),
        corner: p['corner'] == 'sharp' ? PointCorner.sharp : null,
        handle: h == null ? null : SurveyHandle(east: d(h['east']), north: d(h['north'])),
      );
    }

    for (final r in rows('lines')) {
      final pts = (r['points'] as List).cast<Map<String, dynamic>>().map(point).toList();
      expectLine(buildSurveyLine(pts), r['line']);
      expectLine(segmentMidpoints(pts), r['mids']);
    }
  });

  test('handleFromDrag and handleEnds', () {
    final h = (ref['handles'] as Map<String, dynamic>);
    final handle = handleFromDrag((lng: 106.75, lat: -6.235), (106.7503, -6.2347));
    expect(handle.east, near((h['handle'] as Map)['east']));
    expect(handle.north, near((h['handle'] as Map)['north']));
    final ends = handleEnds((lng: 106.75, lat: -6.235), const SurveyHandle(east: 12.5, north: -7.25));
    expectLine([ends.out, ends.inEnd], [(h['ends'] as Map)['out'], (h['ends'] as Map)['in']]);
  });

  test('toDMS and toUTM text', () {
    for (final r in rows('dms')) {
      expect(toDMS(d(r['deg']), isLat: r['isLat'] as bool), r['out'], reason: '${r['deg']}');
    }
    for (final r in rows('utm')) {
      expect(toUTM(d(r['lat']), d(r['lng'])), r['out'], reason: '${r['lat']},${r['lng']}');
    }
  });

  test('distance, degree, area and length formatting', () {
    for (final r in rows('fmt')) {
      final m = d(r['m']);
      expect(formatDistance(m), r['dist']);
      expect(formatDegrees(d(r['degIn'])), r['deg']);
      expect(formatTrackDistance(m), r['trackDist']);
      expect(formatArea(d(r['areaIn'])), r['area']);
      expect(formatLength(m), r['len']);
    }
  });

  test('marked area: area, perimeter and focus mask', () {
    for (final r in rows('areas')) {
      final ring = (r['ring'] as List).map(ll).toList();
      expect(ringArea(ring), near(r['area']));
      expect(ringPerimeter(ring), near(r['perimeter']));
      final mask = focusMaskRings(ring);
      final expected = r['mask'] as List;
      for (var k = 0; k < 2; k++) {
        expectLine(mask[k], expected[k]);
      }
    }
  });

  test('haversine (track recorder)', () {
    for (final r in rows('hav')) {
      final i = ds(r['input']);
      expect(haversineDistance((lat: i[0], lng: i[1]), (lat: i[2], lng: i[3])), near(r['d']));
    }
  });

  test('share location link', () {
    final s = ref['share'] as Map<String, dynamic>;
    expect(sharedLocationUrl(-6.789912, 106.983201), s['url']);
    expect(sharedLocationUrl(-0.000004, -0.000006), s['urlNeg']);
  });

  test('offline map tile counts match the web', () {
    for (final t in rows('tiles')) {
      final b = OfflineBounds.fromJson(t['bounds'] as Map<String, dynamic>);
      expect(tileCount(b, t['min'] as int, t['max'] as int), t['count'], reason: '${t['bounds']}');
    }
  });
}
