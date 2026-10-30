import 'dart:convert';

import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mbx;

import '../../domain/geo/spherical.dart';
import '../../domain/marked/area_contours.dart';
import '../../domain/marked/marked_areas.dart';
import '../map/style_guard.dart';
import 'area_state.dart';

// Marked Areas on the map (MarkedAreaLayer.tsx, SharedAreaLayer.tsx): every saved area with
// a light fill, a coloured outline and its name; the shape being drawn; and the focus view,
// a dark mask over everything outside one area (also used for an area opened from a link).

const areaFillLayer = 'marked-areas-fill';
const _areas = 'marked-areas';
const _labels = 'marked-areas-labels';
const _draft = 'marked-area-draft';
const _mask = 'marked-area-mask';
const _contours = 'marked-area-contours';
const _empty = <String, Object>{'type': 'FeatureCollection', 'features': <Object>[]};

Map<String, Object> areasGeoJson(AreasState s) => {
  'type': 'FeatureCollection',
  'features': [
    for (final a in s.areas) areaFeature(a.ring, {'id': a.id, 'color': a.color, 'focused': a.id == s.focusId}),
  ],
};

Map<String, Object> _labelsGeoJson(AreasState s) => {
  'type': 'FeatureCollection',
  'features': [
    for (final a in s.areas)
      {
        'type': 'Feature',
        'properties': {'name': a.name},
        'geometry': {
          'type': 'Point',
          'coordinates': [ringCenter(a.ring).$1, ringCenter(a.ring).$2],
        },
      },
  ],
};

/// The shape being drawn: a dashed line (closed once it is a shape) and its corners
Map<String, Object> draftGeoJson(List<LngLat> draft) => {
  'type': 'FeatureCollection',
  'features': [
    if (draft.length >= 2)
      {
        'type': 'Feature',
        'properties': <String, Object>{},
        'geometry': {
          'type': 'LineString',
          'coordinates': [
            for (final p in draft.length >= 3 ? [...draft, draft.first] : draft) [p.$1, p.$2],
          ],
        },
      },
    for (final (i, p) in draft.indexed)
      {
        'type': 'Feature',
        'properties': {'first': i == 0},
        'geometry': {
          'type': 'Point',
          'coordinates': [p.$1, p.$2],
        },
      },
  ],
};

/// What the focus view shows: an area of mine, or one opened from a link
typedef FocusShape = ({List<LngLat> ring, String color});

class AreaLayer {
  AreaLayer(this.map);

  final mbx.MapboxMap map;
  bool _installed = false;

  Future<void> install() async {
    _installed = false;
    for (final id in [_mask, _contours, _areas, _labels, _draft]) {
      if (!await map.styleSourceExists(id)) {
        await map.addStyleSource(id, jsonEncode({'type': 'geojson', 'data': _empty}));
      }
    }
    for (final layer in [
      {
        'id': '$_mask-fill',
        'type': 'fill',
        'source': _mask,
        'filter': [
          '!',
          ['has', 'color'],
        ],
        'paint': {'fill-color': '#0b0f08', 'fill-opacity': 0.72},
      },
      {
        'id': '$_mask-outline',
        'type': 'line',
        'source': _mask,
        'filter': ['has', 'color'],
        'paint': {
          'line-color': ['get', 'color'],
          'line-width': 3.5,
        },
      },
      // Contours uploaded on the website (AreaContourLines.tsx): topographic brown, so they
      // read apart from the map's own gold contours; index lines thicker and labelled
      {
        'id': '$_contours-line',
        'type': 'line',
        'source': _contours,
        'paint': {
          'line-color': '#8a5a2b',
          'line-width': [
            'case',
            ['get', 'index'],
            1.8,
            0.9,
          ],
          'line-opacity': 0.9,
        },
      },
      {
        'id': '$_contours-label',
        'type': 'symbol',
        'source': _contours,
        'minzoom': 12,
        'filter': [
          'all',
          ['get', 'index'],
          [
            '!=',
            ['get', 'elevation'],
            null,
          ],
        ],
        'layout': {
          'symbol-placement': 'line',
          'text-field': [
            'concat',
            [
              'to-string',
              [
                'round',
                ['get', 'elevation'],
              ],
            ],
            ' m',
          ],
          'text-size': 10,
          'symbol-spacing': 300,
        },
        'paint': {'text-color': '#6b4220', 'text-halo-color': '#ffffff', 'text-halo-width': 1.4},
      },
      {
        'id': areaFillLayer,
        'type': 'fill',
        'source': _areas,
        'paint': {
          'fill-color': ['get', 'color'],
          'fill-opacity': [
            'case',
            ['get', 'focused'],
            0,
            0.15,
          ],
        },
      },
      {
        'id': '$_areas-outline',
        'type': 'line',
        'source': _areas,
        'paint': {
          'line-color': ['get', 'color'],
          'line-width': [
            'case',
            ['get', 'focused'],
            3.5,
            2.5,
          ],
        },
      },
      {
        'id': '$_labels-text',
        'type': 'symbol',
        'source': _labels,
        'minzoom': 10,
        'layout': {
          'text-field': ['get', 'name'],
          'text-size': 12,
          'text-max-width': 12,
        },
        'paint': {'text-color': '#1a2214', 'text-halo-color': '#ffffff', 'text-halo-width': 1.5},
      },
      {
        'id': '$_draft-line',
        'type': 'line',
        'source': _draft,
        'filter': [
          '==',
          ['geometry-type'],
          'LineString',
        ],
        'paint': {
          'line-color': '#d49b22',
          'line-width': 2.5,
          'line-dasharray': [2, 1.5],
        },
      },
      {
        'id': '$_draft-points',
        'type': 'circle',
        'source': _draft,
        'filter': [
          '==',
          ['geometry-type'],
          'Point',
        ],
        'paint': {
          'circle-radius': [
            'case',
            ['get', 'first'],
            7,
            5,
          ],
          'circle-color': [
            'case',
            ['get', 'first'],
            '#365b25',
            '#ffffff',
          ],
          'circle-stroke-color': '#d49b22',
          'circle-stroke-width': 2.5,
        },
      },
    ]) {
      final id = layer['id']! as String;
      if (await map.styleLayerExists(id)) await map.removeStyleLayer(id);
      await map.addStyleLayer(jsonEncode(layer), null);
    }
    _installed = true;
  }

  /// [linked]: an area opened from a share link, shown in focus over everything else
  /// [linkedContours]: the contours uploaded to that area, when it has any
  Future<void> show(AreasState s, {FocusShape? linked, ContourSet? linkedContours}) =>
      onStyle(() => _show(s, linked: linked, linkedContours: linkedContours));

  Future<void> _show(AreasState s, {FocusShape? linked, ContourSet? linkedContours}) async {
    if (!_installed) return;
    await map.setStyleSourceProperty(_contours, 'data', contourLinesGeoJson([...s.contourSets, ?linkedContours]));
    await map.setStyleSourceProperty(_areas, 'data', areasGeoJson(s));
    await map.setStyleSourceProperty(_labels, 'data', _labelsGeoJson(s));
    await map.setStyleSourceProperty(_draft, 'data', s.drawing ? draftGeoJson(s.draft) : _empty);
    final focused = s.focused;
    final FocusShape? shape = linked ?? (focused == null ? null : (ring: focused.ring, color: focused.color));
    await map.setStyleSourceProperty(_mask, 'data', {
      'type': 'FeatureCollection',
      'features': [
        if (shape != null) focusMask(shape.ring),
        // The linked area's outline (my own areas draw theirs above)
        if (linked != null) areaFeature(linked.ring, {'color': linked.color}),
      ],
    });
  }
}
