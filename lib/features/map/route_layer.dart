import 'dart:convert';

import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';

import '../../domain/route/route_planner.dart';
import 'map_tools_state.dart';

// The planned route on the map, with the web's paint: a white casing under a coloured line
// (by travel mode), plus the start and destination points

const _source = 'route-planner-source';
const _empty = <String, Object>{'type': 'FeatureCollection', 'features': <Object>[]};

String _hex(int argb) => '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

Map<String, Object> routeGeoJson(RoutePlannerState s) => {
  'type': 'FeatureCollection',
  'features': [
    if (s.result != null)
      {
        'type': 'Feature',
        'properties': {'kind': 'route'},
        'geometry': {
          'type': 'LineString',
          'coordinates': [
            for (final p in s.result!.coordinates) [p.lng, p.lat],
          ],
        },
      },
    for (final (kind, p) in [('start', s.draft.start), ('end', s.draft.end)])
      if (p != null)
        {
          'type': 'Feature',
          'properties': {'kind': kind},
          'geometry': {
            'type': 'Point',
            'coordinates': [p.lng, p.lat],
          },
        },
  ],
};

class RouteLayer {
  RouteLayer(this.map);

  final MapboxMap map;

  Future<void> install() async {
    if (!await map.styleSourceExists(_source)) {
      await map.addStyleSource(_source, jsonEncode({'type': 'geojson', 'data': _empty}));
    }
    final line = [
      '==',
      ['get', 'kind'],
      'route',
    ];
    await _add({
      'id': 'route-planner-casing',
      'type': 'line',
      'source': _source,
      'filter': line,
      'layout': {'line-join': 'round', 'line-cap': 'round'},
      'paint': {'line-color': '#ffffff', 'line-width': 8, 'line-opacity': 0.9},
    });
    await _add({
      'id': 'route-planner-line',
      'type': 'line',
      'source': _source,
      'filter': line,
      'layout': {'line-join': 'round', 'line-cap': 'round'},
      'paint': {'line-color': _hex(RouteMode.drivingToll.color), 'line-width': 4.5},
    });
    await _add({
      'id': 'route-planner-points',
      'type': 'circle',
      'source': _source,
      'filter': [
        '!=',
        ['get', 'kind'],
        'route',
      ],
      'paint': {
        'circle-radius': 8,
        'circle-color': [
          'match',
          ['get', 'kind'],
          'start',
          '#365b25',
          '#e46c24',
        ],
        'circle-stroke-color': '#ffffff',
        'circle-stroke-width': 3,
      },
    });
  }

  Future<void> _add(Map<String, Object> layer) async {
    final id = layer['id']! as String;
    if (await map.styleLayerExists(id)) await map.removeStyleLayer(id);
    await map.addStyleLayer(jsonEncode(layer), null);
  }

  Future<void> show(RoutePlannerState s) async {
    await map.setStyleSourceProperty(_source, 'data', s.enabled ? routeGeoJson(s) : _empty);
    await map.setStyleLayerProperty('route-planner-line', 'line-color', _hex(s.mode.color));
  }
}
