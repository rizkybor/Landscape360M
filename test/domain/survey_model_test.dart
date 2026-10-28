import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/domain/account/profile.dart';
import 'package:landscape360/domain/survey/survey_model.dart';
import 'package:landscape360/domain/survey/survey_utils.dart';

// Same rules as src/store/useSurveyStore.ts (web) and the same JSON in surveys.data

// A survey as the web saves it: old points without corner, a sharp corner, a dragged handle
const webJson = '''
[{"id":"g1","name":"Jalur Cibodas","color":"#FFD700","points":[
  {"id":"p1","lng":106.98,"lat":-6.79,"elevation":1450.5},
  {"id":"p2","lng":106.981,"lat":-6.789,"elevation":1480,"name":"Pos 1","corner":"sharp"},
  {"id":"p3","lng":106.982,"lat":-6.7885,"elevation":1510.25,"corner":"smooth","handle":{"east":12.5,"north":-3}}
]},{"id":"g2","name":"Survey 2","color":"#00FF7F","points":[]}]
''';

void main() {
  group('JSON (surveys.data)', () {
    test('reads what the web saves and writes it back the same', () {
      final groups = surveyFromJson(jsonDecode(webJson));
      expect(groups.map((g) => g.name), ['Jalur Cibodas', 'Survey 2']);
      final p = groups.first.points;
      expect((p[0].corner, p[0].handle, p[0].name), (null, null, null));
      expect((p[1].corner, p[1].name), (PointCorner.sharp, 'Pos 1'));
      expect(p[2].handle, const SurveyHandle(east: 12.5, north: -3));
      // Same data (key order does not matter in JSON); whole numbers stay whole
      expect(jsonDecode(jsonEncode(surveyToJson(groups))), jsonDecode(webJson));
      expect(jsonEncode(surveyToJson(groups)), contains('"elevation":1480,'));
    });

    test('never writes "corner": null or "handle": null', () {
      final text = jsonEncode(surveyToJson(surveyFromJson(jsonDecode(webJson))));
      expect(text, isNot(contains('null')));
    });

    test('tolerates numbers as text and odd entries', () {
      final g = surveyFromJson([
        {
          'id': 'g',
          'name': 'X',
          'color': '#00BFFF',
          'points': [
            {'id': 'a', 'lng': '106.5', 'lat': '-6.5', 'elevation': '12'},
            'garbage',
          ],
        },
        42,
      ]);
      expect((g.single.points.single.lng, g.single.points.single.elevation), (106.5, 12.0));
      expect(surveyFromJson(null), isEmpty);
    });
  });

  group('editing (useSurveyStore actions)', () {
    test('the first point creates "Survey 1" in gold', () {
      final d = const SurveyDoc().addPoint(lng: 1, lat: 2, elevation: 3);
      expect(
        (d.groups.single.name, d.groups.single.color, d.activeGroupId),
        ('Survey 1', '#FFD700', d.groups.single.id),
      );
    });

    test('new sheets get the next name and colour and become active', () {
      var d = const SurveyDoc();
      for (var i = 0; i < 6; i++) {
        d = d.createGroup();
      }
      expect(d.groups.map((g) => g.color), [...surveyColors, surveyColors.first]);
      expect(d.groups[2].name, 'Survey 3');
      expect(d.activeGroupId, d.groups.last.id);
      final removed = d.deleteGroup(d.groups.last.id);
      expect(removed.activeGroupId, removed.groups.last.id);
    });

    test('straight mode sharpens the previous point and drops its handle', () {
      var d = const SurveyDoc().addPoint(lng: 0, lat: 0, elevation: 0);
      final g = d.groups.single;
      d = d.setHandle(g.id, g.points.single.id, const SurveyHandle(east: 5, north: 5));
      d = d.addPoint(lng: 0.001, lat: 0, elevation: 0, sharpenLast: true);
      final first = d.groups.single.points.first;
      expect((first.corner, first.handle), (PointCorner.sharp, null));
    });

    test('a corner removes the handle; a handle makes the point smooth', () {
      var d = const SurveyDoc().addPoint(lng: 0, lat: 0, elevation: 0, id: 'p');
      final gid = d.groups.single.id;
      d = d.setHandle(gid, 'p', const SurveyHandle(east: 1, north: 2));
      expect(d.groups.single.points.single.corner, PointCorner.smooth);
      d = d.setCorner(gid, 'p', PointCorner.sharp);
      expect((d.groups.single.points.single.corner, d.groups.single.points.single.handle), (PointCorner.sharp, null));
      d = d.setHandle(gid, 'p', const SurveyHandle(east: 1, north: 2)).setGroupCorners(gid, PointCorner.smooth);
      expect((d.groups.single.points.single.corner, d.groups.single.points.single.handle), (PointCorner.smooth, null));
    });

    test('move, rename, remove and clear points', () {
      var d = const SurveyDoc()
          .addPoint(lng: 0, lat: 0, elevation: 10, id: 'a')
          .addPoint(lng: 0.001, lat: 0, elevation: 20, id: 'b');
      final gid = d.groups.single.id;
      d = d.movePoint(gid, 'a', lat: 1, lng: 2);
      expect((d.groups.single.points.first.lat, d.groups.single.points.first.elevation), (1.0, 10.0));
      d = d.renamePoint(gid, 'a', '  Pos 1 ').renamePoint(gid, 'b', '   ');
      expect(d.groups.single.points.map((p) => p.name), ['Pos 1', null]);
      d = d.removePoint(gid, 'a');
      expect(d.groups.single.points.map((p) => p.id), ['b']);
      expect(d.clearPoints(gid).groups.single.points, isEmpty);
    });

    test('total distance is the sum of the WGS84 segments', () {
      final d = const SurveyDoc()
          .addPoint(lng: 106.8, lat: -6.2, elevation: 0)
          .addPoint(lng: 106.801, lat: -6.2, elevation: 0)
          .addPoint(lng: 106.802, lat: -6.2, elevation: 0);
      expect(d.groups.single.totalDistance, closeTo(2 * 110.6, 1));
    });
  });

  group('placing a new point', () {
    final g = const SurveyDoc()
        .addPoint(lng: 106.75, lat: -6.235, elevation: 0)
        .addPoint(lng: 106.75, lat: -6.234, elevation: 0)
        .groups
        .single;

    test('curve mode keeps the tapped spot', () {
      final r = placeNewPoint(g, (106.751, -6.2338), straightMode: false, angleStep: 90);
      expect((r.coords, r.straight), ((106.751, -6.2338), false));
    });

    test('straight mode snaps to the angle step, free angle keeps the spot', () {
      final snapped = placeNewPoint(g, (106.751, -6.2338), straightMode: true, angleStep: 90);
      expect(snapped.straight, isTrue);
      expect(snapped.coords.$2, closeTo(-6.234, 1e-6)); // a right turn: same latitude
      expect(placeNewPoint(g, (106.751, -6.2338), straightMode: true, angleStep: 0).coords, (106.751, -6.2338));
    });
  });

  test('cloud limits like the web: Free 2, Pro 4, Enterprise 10', () {
    expect([surveyLimit(Plan.free), surveyLimit(Plan.pro), surveyLimit(Plan.enterprise)], [2, 4, 10]);
  });

  test('save name: given, else the first sheet, else "Untitled Survey"', () {
    final groups = surveyFromJson(jsonDecode(webJson));
    expect(surveySaveName(groups, 'Mine'), 'Mine');
    expect(surveySaveName(groups, ''), 'Jalur Cibodas');
    expect(surveySaveName(const []), 'Untitled Survey');
  });

  test('UUIDs are v4 and distinct', () {
    final a = newUuid(), b = newUuid();
    expect(a, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
    expect(a, isNot(b));
  });

  test('handles under half a meter are dropped', () {
    expect(isHandleTooShort(const SurveyHandle(east: 0.3, north: 0.3)), isTrue);
    expect(isHandleTooShort(const SurveyHandle(east: 0.4, north: 0.4)), isFalse);
  });
}
