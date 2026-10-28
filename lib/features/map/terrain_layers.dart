import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';

import '../../domain/map/grid_dms.dart';
import '../../domain/map/map_settings.dart';
import '../../domain/terrain/contours.dart';

// Contour and DMS grid layers on the map, with the same sources, layers, filters and paint
// as the web (ContourLayer.tsx, GridDMSLayer.tsx).

const _contourSource = 'contours';
const _gridSource = 'dms-grid-source';
const _empty = <String, Object>{'type': 'FeatureCollection', 'features': <Object>[]};

const _contourLayers = ['contour-intermediate', 'contour-index', 'contour-labels'];
const _gridLayers = ['dms-grid-lines', 'dms-grid-labels-lat', 'dms-grid-labels-lng'];

class TerrainLayers {
  TerrainLayers(this.map);

  final MapboxMap map;

  // Last view the data was made for: new data makes the map redraw and go idle again, so
  // the same view must not be computed twice (that loop kept the web map redrawing)
  String? _contourKey;
  String? _gridKey;
  int _contourRun = 0;
  Timer? _debounce;

  void dispose() => _debounce?.cancel();

  /// Adds the sources and layers to a freshly loaded style
  Future<void> install(MapSettings s) async {
    _contourKey = null;
    _gridKey = null;
    if (!await map.styleSourceExists(_contourSource)) {
      await map.addStyleSource(_contourSource, jsonEncode({'type': 'geojson', 'data': _empty}));
    }
    if (!await map.styleSourceExists(_gridSource)) {
      await map.addStyleSource(_gridSource, jsonEncode({'type': 'geojson', 'data': _empty}));
    }
    final index = contourIndexInterval(s.contourInterval);
    final isIndex = [
      '==',
      [
        '%',
        ['get', 'elevation'],
        index,
      ],
      0,
    ];
    await _addLayer({
      'id': 'contour-intermediate',
      'type': 'line',
      'source': _contourSource,
      'minzoom': 13,
      'filter': ['!', isIndex],
      'paint': {'line-color': '#FFBF00', 'line-width': 0.8, 'line-opacity': s.contourOpacity * 0.5},
    });
    await _addLayer({
      'id': 'contour-index',
      'type': 'line',
      'source': _contourSource,
      'minzoom': 11,
      'filter': isIndex,
      'paint': {'line-color': '#FFBF00', 'line-width': 1.5, 'line-opacity': s.contourOpacity},
    });
    await _addLayer({
      'id': 'contour-labels',
      'type': 'symbol',
      'source': _contourSource,
      'minzoom': 14,
      'filter': isIndex,
      'layout': {
        'symbol-placement': 'line',
        'text-field': [
          'concat',
          [
            'to-string',
            ['get', 'elevation'],
          ],
          'm',
        ],
        'text-size': 10,
        'text-font': ['Open Sans Bold', 'Arial Unicode MS Bold'],
        'text-allow-overlap': false,
        'text-ignore-placement': false,
        'text-max-angle': 30,
      },
      'paint': {
        'text-color': '#FFFFFF',
        'text-halo-color': '#000000',
        'text-halo-width': 1,
        'text-opacity': s.contourOpacity,
      },
    });
    await _addLayer({
      'id': 'dms-grid-lines',
      'type': 'line',
      'source': _gridSource,
      'paint': {
        'line-color': 'rgba(59, 130, 246, 1)',
        'line-opacity': s.gridOpacity,
        'line-width': 1,
        'line-dasharray': [2, 2],
      },
    });
    for (final axis in ['lat', 'lng']) {
      await _addLayer({
        'id': 'dms-grid-labels-$axis',
        'type': 'symbol',
        'source': _gridSource,
        'filter': [
          'all',
          ['==', 'type', 'grid-label'],
          ['==', 'axis', axis],
        ],
        'layout': {
          'text-field': ['get', 'text'],
          'text-font': ['DIN Offc Pro Medium', 'Arial Unicode MS Bold'],
          'text-size': 13,
          'text-justify': 'center',
          'text-anchor': 'center',
          'symbol-placement': 'point',
          'text-rotate': axis == 'lng' ? -90 : 0,
          'text-allow-overlap': true,
          'text-ignore-placement': true,
        },
        'paint': {
          'text-color': '#3b82f6',
          'text-halo-color': '#ffffff',
          'text-halo-width': 1,
          'text-halo-blur': 0.5,
          'text-opacity': s.gridOpacity,
        },
      });
    }
    await apply(s);
  }

  Future<void> _addLayer(Map<String, dynamic> layer) async {
    if (await map.styleLayerExists(layer['id'] as String)) await map.removeStyleLayer(layer['id'] as String);
    await map.addStyleLayer(jsonEncode(layer), null);
  }

  /// Visibility, opacity and the index filter after a settings change
  Future<void> apply(MapSettings s) async {
    for (final id in _contourLayers) {
      await map.setStyleLayerProperty(id, 'visibility', s.showContours ? 'visible' : 'none');
    }
    for (final id in _gridLayers) {
      await map.setStyleLayerProperty(id, 'visibility', s.showGrid ? 'visible' : 'none');
    }
    await map.setStyleLayerProperty('contour-intermediate', 'line-opacity', s.contourOpacity * 0.5);
    await map.setStyleLayerProperty('contour-index', 'line-opacity', s.contourOpacity);
    await map.setStyleLayerProperty('contour-labels', 'text-opacity', s.contourOpacity);
    await map.setStyleLayerProperty('dms-grid-lines', 'line-opacity', s.gridOpacity);
    await map.setStyleLayerProperty('dms-grid-labels-lat', 'text-opacity', s.gridOpacity);
    await map.setStyleLayerProperty('dms-grid-labels-lng', 'text-opacity', s.gridOpacity);
    final index = contourIndexInterval(s.contourInterval);
    final isIndex = [
      '==',
      [
        '%',
        ['get', 'elevation'],
        index,
      ],
      0,
    ];
    await map.setStyleLayerProperty('contour-intermediate', 'filter', ['!', isIndex]);
    await map.setStyleLayerProperty('contour-index', 'filter', isIndex);
    await map.setStyleLayerProperty('contour-labels', 'filter', isIndex);
  }

  Future<(GeoBounds, CameraState)> _view() async {
    final camera = await map.getCameraState();
    final bounds = await map.coordinateBoundsForCamera(
      CameraOptions(center: camera.center, zoom: camera.zoom, pitch: camera.pitch, bearing: camera.bearing),
    );
    return (
      GeoBounds(
        west: bounds.southwest.coordinates.lng.toDouble(),
        south: bounds.southwest.coordinates.lat.toDouble(),
        east: bounds.northeast.coordinates.lng.toDouble(),
        north: bounds.northeast.coordinates.lat.toDouble(),
      ),
      camera,
    );
  }

  static String _key(GeoBounds b, double zoom, String extra) =>
      '${zoom.toStringAsFixed(2)}|${b.west.toStringAsFixed(5)}|${b.south.toStringAsFixed(5)}|'
      '${b.east.toStringAsFixed(5)}|${b.north.toStringAsFixed(5)}|$extra';

  /// Called when the map settles: grid now, contours after a short pause (300 ms, like the web)
  void onMapIdle(MapSettings s) {
    unawaited(_updateGrid(s).catchError(_log));
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => unawaited(_updateContours(s).catchError(_log)));
  }

  static void _log(Object e) {
    if (kDebugMode) debugPrint('TerrainLayers: $e');
  }

  Future<void> _updateGrid(MapSettings s) async {
    if (!s.showGrid) return;
    final (b, camera) = await _view();
    final key = _key(b, camera.zoom, '${s.gridStep}');
    if (key == _gridKey) return;
    _gridKey = key;
    // As an object: a string would be read as a URL
    await map.setStyleSourceProperty(_gridSource, 'data', gridGeoJson(b, camera.zoom, step: s.gridStep));
  }

  Future<void> _updateContours(MapSettings s) async {
    if (!s.showContours) return;
    final run = ++_contourRun;
    final (b, camera) = await _view();
    if (camera.zoom < contourMinZoom) {
      if (_contourKey != 'cleared') {
        _contourKey = 'cleared';
        await map.setStyleSourceProperty(_contourSource, 'data', _empty);
      }
      return;
    }
    final key = _key(b, camera.zoom, '${s.contourInterval}|${s.appliedExaggeration}');
    if (key == _contourKey) return;

    final grid = contourSampleGrid(b);
    if (grid.isEmpty) return;
    final ex = s.appliedExaggeration;
    // Sample the terrain in batches (each sample is one call into the map)
    final elevations = <List<double>>[];
    var minElev = double.infinity, maxElev = double.negativeInfinity;
    for (final column in grid) {
      final values = await Future.wait([
        for (final p in column)
          map.getElevation(Point(coordinates: Position(p.$1, p.$2))).then((v) => realElevation(v ?? 0, ex)),
      ]);
      if (run != _contourRun) return; // a newer view replaced this one
      for (final v in values) {
        if (v < minElev) minElev = v;
        if (v > maxElev) maxElev = v;
      }
      elevations.add(values);
    }
    final contours = traceContours(grid, elevations, contourBreaks(minElev, maxElev, s.contourInterval));
    if (run != _contourRun) return;
    _contourKey = key;
    await map.setStyleSourceProperty(_contourSource, 'data', contoursGeoJson(contours));
  }

  /// Settings changed: recompute what depends on them
  void refresh(MapSettings s) {
    _contourKey = null;
    _gridKey = null;
    onMapIdle(s);
  }
}
