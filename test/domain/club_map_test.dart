import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/domain/community/club_map.dart';

// The club map's shapes, measurements and elevation profile maths, the same as the web
// (src/lib/community.ts: annotationGeometry, annotationPoints, lineLengthM, densifyLine,
// profileStats)

Map<String, dynamic> annotationRow({
  String id = 'a1',
  String kind = 'line',
  Map<String, dynamic>? geometry,
  bool mine = true,
  int comments = 0,
}) => {
  'id': id,
  'kind': kind,
  'label': 'Water source',
  'note': 'Flows in the rainy season',
  'color': '#1f6feb',
  'geometry':
      geometry ??
      {
        'type': 'LineString',
        'coordinates': [
          [106.9, -6.7],
          [106.91, -6.7],
        ],
      },
  'author_name': 'Rina A.',
  'is_mine': mine,
  'comment_count': comments,
  'created_at': '2026-11-02T00:00:00Z',
  'updated_at': '2026-11-02T01:00:00Z',
};

void main() {
  group('geometry from the points tapped', () {
    test('a pin or note is the last point, rounded to 6 decimals', () {
      expect(annotationGeometry(AnnotationKind.pin, []), isNull);
      expect(annotationGeometry(AnnotationKind.note, [(106.1234567, -6.7654321), (106.2, -6.8)]), {
        'type': 'Point',
        'coordinates': [106.2, -6.8],
      });
      expect(annotationGeometry(AnnotationKind.pin, [(106.1234567, -6.7654321)])!['coordinates'], [
        106.123457,
        -6.765432,
      ]);
    });

    test('a line needs 2 points, an area 3 and is closed', () {
      expect(annotationGeometry(AnnotationKind.line, [(1, 1)]), isNull);
      expect(annotationGeometry(AnnotationKind.line, [(1, 1), (2, 2)])!['type'], 'LineString');
      expect(annotationGeometry(AnnotationKind.area, [(1, 1), (2, 2)]), isNull);
      final area = annotationGeometry(AnnotationKind.area, [(1, 1), (2, 1), (2, 2)])!;
      expect(area['coordinates'], [
        [
          [1.0, 1.0],
          [2.0, 1.0],
          [2.0, 2.0],
          [1.0, 1.0],
        ],
      ]);
      // And back: an area's points without the closing one, to edit it again
      expect(annotationPoints(area), [(1.0, 1.0), (2.0, 1.0), (2.0, 2.0)]);
    });

    test('points needed per kind', () {
      expect([for (final k in AnnotationKind.values) k.needed], [1, 2, 3, 1]);
    });
  });

  group('measurements', () {
    test('line length on the sphere', () {
      // 0.01° of longitude at 6.7° S ≈ 1,104.6 m
      expect(lineLengthM([(106.9, -6.7), (106.91, -6.7)]), closeTo(1104.6, 1));
      expect(lineLengthM([(106.9, -6.7)]), 0);
    });

    test('a profile: about every 10 m, at most 200 points, distances from the start', () {
      final pts = densifyLine([(106.9, -6.7), (106.91, -6.7)]);
      expect(pts.length, 112, reason: '1,104.6 m / 10 m + 1');
      expect(pts.first.distM, 0);
      expect(pts.last.distM, closeTo(1104.6, 1));
      expect(pts.last.at.$1, closeTo(106.91, 1e-9));
      expect(densifyLine([(106.9, -6.7), (107.9, -6.7)]).length, 200);
      expect(densifyLine([(106.9, -6.7)]), hasLength(1));
    });

    test('lowest, highest, climb and descent skip gaps', () {
      final s = profileStats([1000, 1010, double.nan, 1005, 1020])!;
      expect((s.min, s.max, s.gain, s.loss, s.start, s.end), (1000.0, 1020.0, 25.0, 5.0, 1000.0, 1020.0));
      expect(profileStats([double.nan]), isNull);
    });
  });

  group('rows', () {
    test('a drawing, with its measure', () {
      final a = Annotation.fromRow(annotationRow(comments: 2));
      expect(a.kind, AnnotationKind.line);
      expect(a.color, '#1f6feb');
      expect(a.commentCount, 2);
      expect(a.points, [(106.9, -6.7), (106.91, -6.7)]);
      expect(a.measure, '1.10 km');
      final pin = Annotation.fromRow(
        annotationRow(
          kind: 'pin',
          geometry: {
            'type': 'Point',
            'coordinates': [106.9, -6.7],
          },
        )..['note'] = '  ',
      );
      expect(pin.measure, isNull);
      expect(pin.note, isNull, reason: 'blank note');
    });

    test('a saved view', () {
      final v = SavedView.fromRow({
        'id': 'v1',
        'name': 'Summit',
        'lng': 106.98,
        'lat': '-6.78',
        'zoom': 14.5,
        'pitch': 60,
        'bearing': -20,
        'terrain': true,
        'is_mine': true,
      });
      expect((v.lng, v.lat, v.zoom, v.pitch, v.bearing, v.terrain), (106.98, -6.78, 14.5, 60.0, -20.0, true));
    });
  });
}
