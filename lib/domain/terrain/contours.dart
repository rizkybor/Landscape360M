import 'dart:math' as math;

import '../geo/spherical.dart';

// Contour lines from terrain elevation, the same way as the web
// (src/utils/TurfContourProvider.ts + src/components/ContourLayer.tsx): sample a point grid
// over the view, then trace isolines (marching squares) at every interval.

/// Contour intervals offered as shortcuts (meters), like the web
const contourIntervalPresets = [12.5, 25.0, 50.0, 125.0];
const minContourInterval = 10.0;
const maxContourInterval = 500.0;
const contourIntervalStep = 2.5;

/// Contours are only traced from this zoom (the web's performance limit)
const contourMinZoom = 11.0;

/// Grid density across the view on phones (the web's mobile value)
const contourGridDensity = 40;

/// Every index (thicker, labelled) contour: 4× the interval, the cartographic 1:4 ratio
double contourIndexInterval(double interval) => switch (interval) {
  12.5 => 50,
  25 => 100,
  50 => 200,
  125 => 500,
  _ => interval * 4,
};

class GeoBounds {
  const GeoBounds({required this.west, required this.south, required this.east, required this.north});

  final double west;
  final double south;
  final double east;
  final double north;

  double get width => east - west;
  double get height => north - south;
}

/// Regular grid of sample points, like turf.pointGrid(bbox, cellSide, {units: 'degrees'}):
/// columns run west to east, each a list of rows south to north.
List<List<LngLat>> contourSampleGrid(GeoBounds b, {int density = contourGridDensity}) {
  final cellSide = math.max(b.width, b.height) / density; // degrees of arc
  const metersPerDegree = turfEarthRadius * math.pi / 180;
  final xFraction = cellSide / (turfDistance((b.west, b.south), (b.east, b.south)) / metersPerDegree);
  final yFraction = cellSide / (turfDistance((b.west, b.south), (b.west, b.north)) / metersPerDegree);
  final cellWidth = xFraction * b.width;
  final cellHeight = yFraction * b.height;
  if (!cellWidth.isFinite || !cellHeight.isFinite || cellWidth <= 0 || cellHeight <= 0) return const [];
  final columns = (b.width / cellWidth).floor();
  final rows = (b.height / cellHeight).floor();
  final deltaX = (b.width - columns * cellWidth) / 2;
  final deltaY = (b.height - rows * cellHeight) / 2;

  final grid = <List<LngLat>>[];
  for (var x = b.west + deltaX; x <= b.east; x += cellWidth) {
    final column = <LngLat>[];
    for (var y = b.south + deltaY; y <= b.north; y += cellHeight) {
      column.add((x, y));
    }
    grid.add(column);
  }
  return grid;
}

/// Contour levels covering [minElev]..[maxElev]: multiples of [interval] from just below the
/// lowest point to one interval above the highest (same as the web)
List<double> contourBreaks(double minElev, double maxElev, double interval) {
  if (!minElev.isFinite || !maxElev.isFinite || interval <= 0) return const [];
  final start = (minElev / interval).floorToDouble() * interval;
  return [for (var i = start; i <= maxElev + interval; i += interval) i];
}

/// One contour level as polylines of [lng, lat]
class ContourLine {
  const ContourLine(this.elevation, this.lines);

  final double elevation;
  final List<List<LngLat>> lines;
}

/// Traces isolines through a sampled grid ([points] and [elevations] indexed [column][row])
/// with marching squares and linear interpolation along cell edges.
List<ContourLine> traceContours(List<List<LngLat>> points, List<List<double>> elevations, List<double> breaks) {
  final cols = points.length;
  if (cols < 2) return const [];
  final rows = points.first.length;
  if (rows < 2 || points.any((c) => c.length != rows)) return const [];

  final result = <ContourLine>[];
  for (final level in breaks) {
    final segments = <(LngLat, LngLat)>[];
    for (var i = 0; i < cols - 1; i++) {
      for (var j = 0; j < rows - 1; j++) {
        _cellSegments(points, elevations, i, j, level, segments);
      }
    }
    if (segments.isNotEmpty) result.add(ContourLine(level, _join(segments)));
  }
  return result;
}

LngLat _lerp(LngLat a, LngLat b, double za, double zb, double level) {
  final t = za == zb ? 0.5 : (level - za) / (zb - za);
  return (a.$1 + (b.$1 - a.$1) * t, a.$2 + (b.$2 - a.$2) * t);
}

void _cellSegments(List<List<LngLat>> p, List<List<double>> z, int i, int j, double level, List<(LngLat, LngLat)> out) {
  // Corners: bl, br, tr, tl (x east, y north)
  final bl = p[i][j], br = p[i + 1][j], tr = p[i + 1][j + 1], tl = p[i][j + 1];
  final zbl = z[i][j], zbr = z[i + 1][j], ztr = z[i + 1][j + 1], ztl = z[i][j + 1];
  final code = (ztl >= level ? 8 : 0) | (ztr >= level ? 4 : 0) | (zbr >= level ? 2 : 0) | (zbl >= level ? 1 : 0);
  if (code == 0 || code == 15) return;

  LngLat bottom() => _lerp(bl, br, zbl, zbr, level);
  LngLat right() => _lerp(br, tr, zbr, ztr, level);
  LngLat top() => _lerp(tl, tr, ztl, ztr, level);
  LngLat left() => _lerp(bl, tl, zbl, ztl, level);

  switch (code) {
    case 1 || 14:
      out.add((left(), bottom()));
    case 2 || 13:
      out.add((bottom(), right()));
    case 3 || 12:
      out.add((left(), right()));
    case 4 || 11:
      out.add((top(), right()));
    case 6 || 9:
      out.add((bottom(), top()));
    case 7 || 8:
      out.add((left(), top()));
    case 5 || 10:
      // Saddle: the cell centre decides which corners connect
      final centerHigh = (zbl + zbr + ztr + ztl) / 4 >= level;
      final bottomLeftHigh = code == 5;
      if (centerHigh == bottomLeftHigh) {
        out
          ..add((left(), top()))
          ..add((bottom(), right()));
      } else {
        out
          ..add((left(), bottom()))
          ..add((top(), right()));
      }
  }
}

/// Joins touching segments into longer polylines (needed for labels along the line)
List<List<LngLat>> _join(List<(LngLat, LngLat)> segments) {
  String key(LngLat p) => '${(p.$1 * 1e9).round()},${(p.$2 * 1e9).round()}';
  final byEnd = <String, List<int>>{};
  for (var s = 0; s < segments.length; s++) {
    byEnd.putIfAbsent(key(segments[s].$1), () => []).add(s);
    byEnd.putIfAbsent(key(segments[s].$2), () => []).add(s);
  }
  final used = List<bool>.filled(segments.length, false);

  int? next(LngLat at) {
    for (final s in byEnd[key(at)] ?? const <int>[]) {
      if (!used[s]) return s;
    }
    return null;
  }

  final lines = <List<LngLat>>[];
  for (var s = 0; s < segments.length; s++) {
    if (used[s]) continue;
    used[s] = true;
    final line = [segments[s].$1, segments[s].$2];
    // Grow forward from the end, then backward from the start
    for (var forward = 0; forward < 2; forward++) {
      while (true) {
        final end = forward == 0 ? line.last : line.first;
        final n = next(end);
        if (n == null) break;
        used[n] = true;
        final (a, b) = segments[n];
        final other = key(a) == key(end) ? b : a;
        if (forward == 0) {
          line.add(other);
        } else {
          line.insert(0, other);
        }
      }
    }
    lines.add(line);
  }
  return lines;
}

/// GeoJSON FeatureCollection of the contours, one MultiLineString per level with its
/// `elevation` (what the web's contour layers filter and label on)
Map<String, dynamic> contoursGeoJson(List<ContourLine> contours) => {
  'type': 'FeatureCollection',
  'features': [
    for (final c in contours)
      {
        'type': 'Feature',
        'properties': {'elevation': c.elevation},
        'geometry': {
          'type': 'MultiLineString',
          'coordinates': [
            for (final line in c.lines)
              [
                for (final p in line) [p.$1, p.$2],
              ],
          ],
        },
      },
  ],
};
