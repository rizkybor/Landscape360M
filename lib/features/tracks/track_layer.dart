import 'dart:convert';

import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';

import '../../domain/tracks/track_recorder_geo.dart';
import '../map/style_guard.dart';
import 'track_recorder_state.dart';

// The Track Recorder on the map (TrackRecorderLayer.tsx): the recording in progress in
// orange, a saved track in cyan, both on a dark casing, and the saved track's start (green)
// and finish (red). Pauses break the line. The position itself is the map's location puck.

const _active = 'track-recorder-active';
const _viewing = 'track-recorder-viewing';
const _ends = 'track-recorder-ends';
const _empty = <String, Object>{'type': 'FeatureCollection', 'features': <Object>[]};

Map<String, Object> trackLinesGeoJson(List<TrackPoint> points) => {
  'type': 'FeatureCollection',
  'features': [
    for (final segment in splitSegments(points))
      if (segment.length >= 2)
        {
          'type': 'Feature',
          'properties': <String, Object>{},
          'geometry': {
            'type': 'LineString',
            'coordinates': [
              for (final p in segment) [p.lng, p.lat],
            ],
          },
        },
  ],
};

Map<String, Object> trackEndsGeoJson(List<TrackPoint> points) => {
  'type': 'FeatureCollection',
  'features': [
    for (final (kind, p) in [
      if (points.isNotEmpty) ('start', points.first),
      if (points.length > 1) ('finish', points.last),
    ])
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

class TrackLayer {
  TrackLayer(this.map);

  final MapboxMap map;
  bool _installed = false;

  Future<void> install() async {
    _installed = false;
    for (final id in [_viewing, _active, _ends]) {
      if (!await map.styleSourceExists(id)) {
        await map.addStyleSource(id, jsonEncode({'type': 'geojson', 'data': _empty}));
      }
    }
    for (final (source, color, casing) in [(_viewing, '#22d3ee', '#0f172a'), (_active, '#f97316', '#7c2d12')]) {
      await _add({
        'id': '$source-casing',
        'type': 'line',
        'source': source,
        'layout': {'line-join': 'round', 'line-cap': 'round'},
        'paint': {'line-color': casing, 'line-width': 7, 'line-opacity': 0.6},
      });
      await _add({
        'id': '$source-line',
        'type': 'line',
        'source': source,
        'layout': {'line-join': 'round', 'line-cap': 'round'},
        'paint': {'line-color': color, 'line-width': 4},
      });
    }
    await _add({
      'id': '$_ends-points',
      'type': 'circle',
      'source': _ends,
      'paint': {
        'circle-radius': 7,
        'circle-color': [
          'match',
          ['get', 'kind'],
          'start',
          '#284A1B',
          '#B4302A',
        ],
        'circle-stroke-color': '#ffffff',
        'circle-stroke-width': 2.5,
      },
    });
    _installed = true;
  }

  Future<void> _add(Map<String, Object> layer) async {
    final id = layer['id']! as String;
    if (await map.styleLayerExists(id)) await map.removeStyleLayer(id);
    await map.addStyleLayer(jsonEncode(layer), null);
  }

  Future<void> show(TrackRecorderState s) => onStyle(() => _show(s));

  Future<void> _show(TrackRecorderState s) async {
    if (!_installed) return;
    final viewing = s.viewing?.points ?? const <TrackPoint>[];
    await map.setStyleSourceProperty(_viewing, 'data', trackLinesGeoJson(viewing));
    await map.setStyleSourceProperty(_ends, 'data', trackEndsGeoJson(viewing));
    await map.setStyleSourceProperty(_active, 'data', trackLinesGeoJson(s.activePoints));
  }
}
