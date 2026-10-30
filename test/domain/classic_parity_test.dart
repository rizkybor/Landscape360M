import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/domain/classic/classic_nav.dart';
import 'package:landscape360/domain/classic/classic_solve.dart';
import 'package:landscape360/domain/classic/field_work.dart';
import 'package:landscape360/domain/geo/spherical.dart';

// Classic against the web's own TypeScript (classicNav.ts, classicSolve.ts), through
// test/fixtures/web_reference.json (tool/web_reference/generate.sh): every message exactly,
// every number to a millionth (points to 1e-9 degrees).

void main() {
  final ref = (jsonDecode(File('test/fixtures/web_reference.json').readAsStringSync()) as Map)['classic'] as Map;
  List<Map<String, dynamic>> rows(String key) => (ref[key] as List).cast<Map<String, dynamic>>();
  double d(Object? v) => (v! as num).toDouble();
  LngLat ll(Object? v) => (d((v! as List)[0]), d((v as List)[1]));
  DmsInput dms(Object? v) => DmsInput.fromJson((v! as Map).cast<String, dynamic>());

  void expectParsed(Parsed actual, Object? expected, String reason) {
    final e = expected! as Map;
    expect(actual.error, e['error'], reason: '$reason error');
    if (e['value'] == null) {
      expect(actual.value, isNull, reason: reason);
    } else {
      expect(actual.value, closeTo(d(e['value']), 1e-9), reason: reason);
    }
  }

  void expectPoint(LngLat? actual, Object? expected, String reason) {
    if (expected == null) return expect(actual, isNull, reason: reason);
    final e = ll(expected);
    expect(actual!.$1, closeTo(e.$1, 1e-9), reason: '$reason lng');
    expect(actual.$2, closeTo(e.$2, 1e-9), reason: '$reason lat');
  }

  void expectCheck(Check? actual, Object? expected, String reason) {
    if (expected == null) return expect(actual, isNull, reason: reason);
    final e = expected as Map;
    expect((actual!.verdict.name, actual.message), (e['verdict'], e['message']), reason: reason);
  }

  void expectFix(Fix? actual, Object? expected, String reason) {
    if (expected == null) return expect(actual, isNull, reason: reason);
    final e = expected as Map;
    expectPoint(actual!.point, e['point'], '$reason point');
    expect(actual.cutAngle, closeTo(d(e['cutAngle']), 1e-6), reason: '$reason cut');
    for (final (i, v) in (e['along'] as List).indexed) {
      expect(actual.along[i], closeTo(d(v), 1e-4), reason: '$reason along $i');
    }
    for (final (i, v) in (e['misses'] as List).indexed) {
      expect(actual.misses[i], closeTo(d(v), 1e-4), reason: '$reason miss $i');
    }
  }

  test('degrees, minutes, seconds: values and every message', () {
    for (final r in rows('dms')) {
      expectParsed(
        parseDms(dms(r['input']), (r['max'] as num).toInt(), 'latitude'),
        r['out'],
        '${r['input']} /${r['max']}',
      );
    }
    for (final r in rows('toDms')) {
      expect(toDmsInput(d(r['v'])).toJson(), (r['out'] as Map).cast<String, String>(), reason: '${r['v']}');
    }
  });

  test('compass readings, formatting, compass points and their Indonesian names', () {
    for (final r in rows('compass')) {
      expectParsed(parseCompass(r['t'] as String, 'azimuth'), r['out'], '"${r['t']}"');
    }
    for (final r in rows('format')) {
      final v = d(r['v']);
      expect((formatCompass(v), compassPoint(v)), (r['fmt'], r['point']), reason: '$v');
      expect(backAzimuthOf(v), closeTo(d(r['back']), 1e-9));
      expect(angleDiff(v, 350), closeTo(d(r['diff']), 1e-9));
    }
    for (final r in rows('hints')) {
      expect(compassPointHint(r['p'] as String), r['hint']);
    }
    expect(
      [for (final p in compassPoints) (p.abbr, p.deg, p.id)],
      [for (final p in rows('points')) (p['abbr'], d(p['deg']), p['id'])],
    );
  });

  test('back azimuth checks', () {
    for (final r in rows('backChecks')) {
      expectCheck(checkBackAzimuth(d(r['back']), d(r['az'])), r['out'], '${r['back']} for ${r['az']}');
    }
  });

  test('where lines cross, the likely circle, the hints on the cut and the triangle of error', () {
    for (final (i, r) in rows('fix').indexed) {
      final lines = [
        for (final l in (r['lines'] as List).cast<Map<String, dynamic>>())
          Line(from: ll(l['from']), bearing: d(l['bearing'])),
      ];
      final fix = fixFromLines(lines);
      expectFix(fix, r['fix'], 'set $i');
      if (fix == null) continue;
      expect(fixRadius(fix), closeTo(d(r['radius']), 1e-4), reason: 'set $i radius');
      final review = reviewFix(fix, lines, 'intersection', [
        for (var k = 0; k < lines.length; k++) 'position ${String.fromCharCode(65 + k)}',
      ]);
      final expected = (r['review'] as List).cast<Map<String, dynamic>>();
      expect(review, hasLength(expected.length), reason: 'set $i review');
      for (final (k, e) in expected.indexed) {
        expectCheck(review[k], e, 'set $i review $k');
      }
    }
    for (final r in rows('along')) {
      expect(lengthAlong(ll(r['from']), d(r['bearing']), ll(r['to'])), closeTo(d(r['out']), 1e-6));
    }
  });

  test('solveClassic: steps opening in order, lines, the fix and every problem', () {
    for (final (n, r) in rows('solve').indexed) {
      final input = r['input'] as Map<String, dynamic>;
      final data = FieldWorkData.fromJson({'sightings': input['sightings'], 'origin': input['origin']});
      final sol = solveClassic(
        mode: ClassicMode.parse(input['mode']),
        sightings: data.sightings,
        origin: data.origin,
        declination: input['declination'] as String,
      );
      final out = r['out'] as Map<String, dynamic>;
      final why = 'case $n';
      expect(sol.pointsReady, out['pointsReady'], reason: why);
      expectPoint(sol.origin, out['origin'], '$why origin');
      expect(sol.originError, out['originError'], reason: why);
      expectParsed(sol.declination, out['declination'], '$why declination');
      expect(sol.problem, out['problem'], reason: '$why problem');
      expectFix(sol.fix, out['fix'], '$why fix');
      final lines = (out['lines'] as List).cast<Map<String, dynamic>>();
      expect(sol.lines, hasLength(lines.length), reason: '$why lines');
      for (final (i, l) in lines.indexed) {
        expect(sol.lines[i].index, l['index']);
        expect(sol.lines[i].bearing, closeTo(d(l['bearing']), 1e-9));
        expectPoint(sol.lines[i].from, l['from'], '$why line $i');
      }
      final review = (out['review'] as List).cast<Map<String, dynamic>>();
      expect(sol.review, hasLength(review.length), reason: '$why review');
      for (final (i, e) in review.indexed) {
        expectCheck(sol.review[i], e, '$why review $i');
      }
      for (final (i, e) in (out['sightings'] as List).cast<Map<String, dynamic>>().indexed) {
        final s = sol.sightings[i];
        final r2 = '$why sighting $i';
        expect(
          (s.label, s.pointError, s.azOpen, s.backOpen, s.complete, s.open),
          (e['label'], e['pointError'], e['azOpen'], e['backOpen'], e['complete'], e['open']),
          reason: r2,
        );
        expectPoint(s.point, e['point'], '$r2 point');
        expectParsed(s.azimuth, e['azimuth'], '$r2 azimuth');
        expectParsed(s.back, e['back'], '$r2 back');
        expectCheck(s.backCheck, e['backCheck'], '$r2 check');
        expect(s.backAnswer, e['backAnswer'] == null ? isNull : closeTo(d(e['backAnswer']), 1e-9), reason: r2);
      }
    }
  });
}
