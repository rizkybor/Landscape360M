import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/domain/geo/spherical.dart';
import 'package:landscape360/domain/map/grid_dms.dart';
import 'package:landscape360/domain/map/map_settings.dart';
import 'package:landscape360/domain/terrain/contours.dart';

// Contours and the DMS grid behave like the web's ContourLayer / TurfContourProvider and
// GridDMSLayer

const view = GeoBounds(west: 106.9, south: -6.85, east: 107.0, north: -6.75);

/// A cone-shaped hill: 1000 m at the center, falling 100 m per 0.005° of distance
double cone(LngLat p) {
  final d = math.sqrt(math.pow(p.$1 - 106.95, 2) + math.pow(p.$2 + 6.8, 2));
  return 1000 - d / 0.005 * 100;
}

void main() {
  group('contour sample grid (turf.pointGrid in degrees)', () {
    test('covers the view with about 40 cells across, evenly spaced', () {
      final grid = contourSampleGrid(view);
      expect(grid.length, inInclusiveRange(38, 42));
      expect(grid.first.length, inInclusiveRange(38, 42));
      expect(grid.every((c) => c.length == grid.first.length), isTrue);
      final first = grid.first.first, last = grid.last.last;
      expect(first.$1, greaterThanOrEqualTo(view.west));
      expect(first.$2, greaterThanOrEqualTo(view.south));
      expect(last.$1, lessThanOrEqualTo(view.east));
      expect(last.$2, lessThanOrEqualTo(view.north));
      final dx = grid[1].first.$1 - grid[0].first.$1;
      expect(grid[21].first.$1 - grid[20].first.$1, closeTo(dx, 1e-12));
    });

    test('is empty for an empty view', () {
      expect(contourSampleGrid(const GeoBounds(west: 1, south: 1, east: 1, north: 1)), isEmpty);
    });
  });

  test('breaks: multiples of the interval from below the lowest to above the highest', () {
    expect(contourBreaks(812, 1190, 50), [800, 850, 900, 950, 1000, 1050, 1100, 1150, 1200]); // up to 1190 + 50
    expect(contourBreaks(10, 40, 12.5), [0, 12.5, 25, 37.5, 50]);
    expect(contourBreaks(double.nan, 5, 50), isEmpty);
  });

  test('index contours every 4 intervals, with the web\'s fixed pairs', () {
    expect([for (final i in contourIntervalPresets) contourIndexInterval(i)], [50, 100, 200, 500]);
    expect(contourIndexInterval(30), 120);
  });

  group('traceContours (marching squares)', () {
    late List<List<LngLat>> grid;
    late List<List<double>> z;

    setUp(() {
      grid = contourSampleGrid(view);
      z = [
        for (final column in grid) [for (final p in column) cone(p)],
      ];
    });

    test('a cone gives closed rings at the right distance from the summit', () {
      final contours = traceContours(grid, z, [800, 900]);
      expect(contours.map((c) => c.elevation), [800, 900]);
      for (final c in contours) {
        expect(c.lines, hasLength(1), reason: 'one joined ring per level');
        final ring = c.lines.single;
        expect(ring.first.$1, closeTo(ring.last.$1, 1e-9), reason: 'closed');
        final radius = (1000 - c.elevation) / 100 * 0.005;
        for (final p in ring) {
          final d = math.sqrt(math.pow(p.$1 - 106.95, 2) + math.pow(p.$2 + 6.8, 2));
          expect(d, closeTo(radius, 0.0005), reason: '${c.elevation} m ring');
        }
      }
    });

    test('levels outside the terrain give nothing; a flat view gives nothing', () {
      expect(traceContours(grid, z, [1500, -5000]), isEmpty);
      final flat = [
        for (final column in grid) [for (final _ in column) 100.0],
      ];
      expect(traceContours(grid, flat, contourBreaks(100, 100, 50)), isEmpty);
    });

    test('GeoJSON has one MultiLineString per level with its elevation', () {
      final geo = contoursGeoJson(traceContours(grid, z, [800]));
      final feature = (geo['features'] as List).single as Map<String, dynamic>;
      expect(feature['properties'], {'elevation': 800.0});
      expect((feature['geometry'] as Map)['type'], 'MultiLineString');
    });
  });

  group('DMS grid', () {
    test('automatic interval follows the map scale', () {
      expect(autoGridStep(16), 15 / 3600);
      expect(autoGridStep(14), 30 / 3600);
      expect(autoGridStep(12.5), 1 / 60);
      expect(autoGridStep(10), 5 / 60);
      expect(autoGridStep(8), 10 / 60);
      expect(autoGridStep(6), 0.5);
      expect(autoGridStep(5), 1);
    });

    test('labels use whole seconds and never show 60"', () {
      expect(formatGridDMS(-6.785, isLat: true), '6° 47\' 06" S');
      expect(formatGridDMS(106.95, isLat: false), '106° 57\' 00" E');
      expect(formatGridDMS(6 + 59 / 60 + 59.8 / 3600, isLat: true), '7° 0\' 00" N');
      expect(formatGridDMS(-0.5, isLat: false), '0° 30\' 00" W');
    });

    test('lines and labels for each grid value across the view', () {
      final geo = gridGeoJson(view, 12, step: 1 / 60);
      final features = (geo['features'] as List).cast<Map<String, dynamic>>();
      final latLines = features.where(
        (f) => (f['properties'] as Map)['axis'] == 'lat' && (f['properties'] as Map)['type'] == 'grid-line',
      );
      final lngLabels = features.where(
        (f) => (f['properties'] as Map)['axis'] == 'lng' && (f['properties'] as Map)['type'] == 'grid-label',
      );
      // 0.1° view at 1' spacing: about 6 lines each way plus the edge ones
      expect(latLines.length, inInclusiveRange(6, 9));
      expect(lngLabels.length, inInclusiveRange(6, 9));
      for (final l in latLines) {
        final v = (l['properties'] as Map)['value'] as double;
        expect((v * 60 - (v * 60).round()).abs(), lessThan(1e-9), reason: 'on a whole minute');
      }
    });

    test('nothing below zoom 4', () {
      expect(gridGeoJson(view, 3.9)['features'], isEmpty);
    });
  });

  test('settings: contour and grid defaults match the web and survive saving', () {
    const s = MapSettings();
    expect((s.showContours, s.contourInterval, s.contourOpacity), (true, 50.0, 0.8));
    expect((s.showGrid, s.gridOpacity, s.gridStep), (false, 0.5, null));
    final changed = s.copyWith(showGrid: true, gridStep: () => 30 / 3600, contourInterval: 12.5);
    final back = MapSettings.fromJson(changed.toJson());
    expect((back.showGrid, back.gridStep, back.contourInterval), (true, 30 / 3600, 12.5));
    expect(back.copyWith(gridStep: () => null).gridStep, isNull);
    expect(MapSettings.fromJson({'contourOpacity': 7, 'contourInterval': 1}).contourOpacity, 1.0);
  });
}
