import 'dart:convert';

import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';

import '../../domain/survey/survey_model.dart';
import '../../domain/survey/survey_utils.dart';
import '../map/style_guard.dart';

// Survey lines on the map, like the web's PlottingLayer: each sheet in its colour (curves,
// sharp corners and Bezier handles drawn by buildSurveyLine), the active sheet opaque, and
// the dashed handle line of the selected point.

const _lines = 'survey-lines';
const _handles = 'survey-handles';
const _empty = <String, Object>{'type': 'FeatureCollection', 'features': <Object>[]};

Map<String, Object> surveyLinesGeoJson(SurveyDoc doc) => {
  'type': 'FeatureCollection',
  'features': [
    for (final g in doc.groups)
      if (g.points.length >= 2)
        {
          'type': 'Feature',
          'properties': {'color': g.color, 'isActive': g.id == doc.activeGroup?.id},
          'geometry': {
            'type': 'LineString',
            'coordinates': [
              for (final c in buildSurveyLine([for (final p in g.points) p.line])) [c.$1, c.$2],
            ],
          },
        },
  ],
};

Map<String, Object> handleGeoJson(SurveyDoc doc, String? selectedPointId) {
  for (final g in doc.groups) {
    if (g.id != doc.activeGroup?.id) continue;
    for (final p in g.points) {
      if (p.id != selectedPointId || p.handle == null) continue;
      final ends = handleEnds((lng: p.lng, lat: p.lat), p.handle!);
      return {
        'type': 'FeatureCollection',
        'features': [
          {
            'type': 'Feature',
            'properties': {'color': g.color},
            'geometry': {
              'type': 'LineString',
              'coordinates': [
                [ends.inEnd.$1, ends.inEnd.$2],
                [p.lng, p.lat],
                [ends.out.$1, ends.out.$2],
              ],
            },
          },
        ],
      };
    }
  }
  return _empty;
}

class NavigatorLayer {
  NavigatorLayer(this.map);

  final MapboxMap map;
  bool _installed = false;

  Future<void> install() async {
    _installed = false;
    for (final id in [_lines, _handles]) {
      if (!await map.styleSourceExists(id)) {
        await map.addStyleSource(id, jsonEncode({'type': 'geojson', 'data': _empty}));
      }
    }
    await _add({
      'id': 'survey-lines-path',
      'type': 'line',
      'source': _lines,
      'layout': {'line-join': 'miter', 'line-cap': 'round'},
      'paint': {
        'line-color': ['get', 'color'],
        'line-width': 2, // thin on phones, so the line does not hide the map (web)
        'line-opacity': [
          'case',
          ['get', 'isActive'],
          1,
          0.6,
        ],
      },
    });
    await _add({
      'id': 'survey-handles-path',
      'type': 'line',
      'source': _handles,
      'paint': {
        'line-color': ['get', 'color'],
        'line-width': 1.5,
        'line-dasharray': [2, 1.5],
      },
    });
    _installed = true;
  }

  Future<void> _add(Map<String, Object> layer) async {
    final id = layer['id']! as String;
    if (await map.styleLayerExists(id)) await map.removeStyleLayer(id);
    await map.addStyleLayer(jsonEncode(layer), null);
  }

  Future<void> show(SurveyDoc doc, String? selectedPointId) => onStyle(() => _show(doc, selectedPointId));

  Future<void> _show(SurveyDoc doc, String? selectedPointId) async {
    if (!_installed) return;
    await map.setStyleSourceProperty(_lines, 'data', surveyLinesGeoJson(doc));
    await map.setStyleSourceProperty(_handles, 'data', handleGeoJson(doc, selectedPointId));
  }
}
