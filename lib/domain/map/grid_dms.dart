import '../terrain/contours.dart';
import '../util/js_compat.dart';

// Latitude / longitude grid with DMS labels, port of src/components/GridDMSLayer.tsx (web)

/// Grid intervals the user can pick (degrees); null = automatic by zoom
const gridStepOptions = <(double?, String, String)>[
  (null, 'Auto (Dynamic)', 'Follows the zoom'),
  (15 / 3600, '15" (~450m)', 'Skala 1:10.000'),
  (30 / 3600, '30" (~900m)', 'Skala 1:25.000'),
  (1 / 60, "1' (~1.8km)", 'Skala 1:50.000'),
  (5 / 60, "5' (~9km)", 'Skala 1:250.000'),
];

/// No grid below this zoom (too cluttered)
const gridMinZoom = 4.0;

/// Grid interval in degrees for a zoom level, matching map scales
double autoGridStep(double zoom) {
  if (zoom >= 15) return 15 / 3600; // 15" (~450 m, 1:10.000)
  if (zoom >= 14) return 30 / 3600; // 30" (~900 m, 1:25.000)
  if (zoom >= 12) return 1 / 60; // 1' (~1.8 km, 1:50.000)
  if (zoom >= 10) return 5 / 60; // 5' (~9 km, 1:250.000)
  if (zoom >= 8) return 10 / 60; // 10'
  if (zoom >= 6) return 0.5; // 30'
  return 1;
}

/// Grid label: whole seconds, never 60" (carried into the minute), e.g. 6° 47' 05" S
String formatGridDMS(double value, {required bool isLat}) {
  final abs = value.abs();
  var d = abs.floor();
  var m = ((abs - d) * 60).floor();
  var s = jsRound((abs - d - m / 60) * 3600).toInt();
  if (s == 60) {
    s = 0;
    m += 1;
  }
  if (m == 60) {
    m = 0;
    d += 1;
  }
  final dir = isLat ? (value >= 0 ? 'N' : 'S') : (value >= 0 ? 'E' : 'W');
  return '$d° $m\' ${s.toString().padLeft(2, '0')}" $dir';
}

/// GeoJSON of the grid for the view: dashed lines plus a label for each, placed in the
/// middle of the view (latitude labels horizontal, longitude labels vertical)
Map<String, dynamic> gridGeoJson(GeoBounds b, double zoom, {double? step}) {
  if (zoom < gridMinZoom) return const {'type': 'FeatureCollection', 'features': <Object>[]};
  final s = step ?? autoGridStep(zoom);
  double clean(double v) => jsRound(v * 360000) / 360000; // fix floating point drift
  final features = <Map<String, dynamic>>[];

  for (var lat = (b.south / s).floorToDouble() * s; lat <= b.north + s; lat += s) {
    final v = clean(lat);
    if (v < -90 || v > 90) continue;
    features
      ..add({
        'type': 'Feature',
        'geometry': {
          'type': 'LineString',
          'coordinates': [
            [b.west - 1, v],
            [b.east + 1, v],
          ],
        },
        'properties': {'type': 'grid-line', 'value': v, 'axis': 'lat'},
      })
      ..add({
        'type': 'Feature',
        'geometry': {
          'type': 'Point',
          'coordinates': [(b.west + b.east) / 2, v],
        },
        'properties': {'type': 'grid-label', 'text': formatGridDMS(v, isLat: true), 'axis': 'lat'},
      });
  }

  for (var lng = (b.west / s).floorToDouble() * s; lng <= b.east + s; lng += s) {
    final v = clean(lng);
    features
      ..add({
        'type': 'Feature',
        'geometry': {
          'type': 'LineString',
          'coordinates': [
            [v, b.south - 1],
            [v, b.north + 1],
          ],
        },
        'properties': {'type': 'grid-line', 'value': v, 'axis': 'lng'},
      })
      ..add({
        'type': 'Feature',
        'geometry': {
          'type': 'Point',
          'coordinates': [v, (b.south + b.north) / 2],
        },
        'properties': {'type': 'grid-label', 'text': formatGridDMS(v, isLat: false), 'axis': 'lng'},
      });
  }
  return {'type': 'FeatureCollection', 'features': features};
}
