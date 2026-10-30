import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mbx;

import '../../domain/classic/classic_drawing.dart';
import '../../domain/classic/classic_nav.dart';
import '../../domain/classic/classic_solve.dart';
import '../../domain/classic/field_work.dart';
import '../../domain/geo/spherical.dart' show LngLat;
import '../map/style_guard.dart';

// Classic on the map (ClassicLayer.tsx): a compass rose on every point (north follows the
// map), the lines drawn as bearings are typed, the points and X where the azimuth lines cross.
// The likely circle around X and the draggable line ends are Flutter (ClassicOverlay).

const _lines = 'classic-lines';
const _points = 'classic-points';
const _cross = 'classic-cross';
const _rose = 'classic-rose';
const _empty = <String, Object>{'type': 'FeatureCollection', 'features': <Object>[]};

Map<String, Object> _point(LngLat p, Map<String, Object> props) => {
  'type': 'Feature',
  'properties': props,
  'geometry': {
    'type': 'Point',
    'coordinates': [p.$1, p.$2],
  },
};

Map<String, Object> linesGeoJson(ClassicDrawing d) => {
  'type': 'FeatureCollection',
  'features': [
    for (final l in d.lines)
      {
        'type': 'Feature',
        'properties': {'kind': l.back ? 'back' : 'main', 'text': l.text},
        'geometry': {
          'type': 'LineString',
          'coordinates': [
            [l.from.$1, l.from.$2],
            [l.end.$1, l.end.$2],
          ],
        },
      },
  ],
};

/// Resection: your one position. Intersection: each position you sight from.
Map<String, Object> pointsGeoJson(ClassicSolution sol, ClassicMode mode) => {
  'type': 'FeatureCollection',
  'features': mode == ClassicMode.resection
      ? [
          if (sol.origin != null) _point(sol.origin!, {'label': 'You'}),
        ]
      : [
          for (final (i, s) in sol.sightings.indexed)
            if (s.point != null) _point(s.point!, {'label': 'Pos ${String.fromCharCode(65 + i)}'}),
        ],
};

Map<String, Object> crossGeoJson(ClassicDrawing d) => {
  'type': 'FeatureCollection',
  'features': [
    if (d.crossing case final fix?)
      _point(fix.point, {'label': 'X · ±${metresText(fixRadius(fix))}', 'checked': d.checked}),
  ],
};

/// The compass card drawn around a point: N in red, ticks every 30°
Future<Uint8List> rosePng(double scale) async {
  const size = 76.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)
    ..scale(scale)
    ..translate(size / 2, size / 2);
  const ink = Color(0xFF1A2214);
  canvas
    ..drawCircle(Offset.zero, 30, Paint()..color = const Color(0x59FFFFFF))
    ..drawCircle(
      Offset.zero,
      30,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = ink.withValues(alpha: 0.7),
    );
  for (var i = 0; i < 12; i++) {
    final a = i * 30 * math.pi / 180;
    final dir = Offset(math.sin(a), -math.cos(a));
    canvas.drawLine(
      dir * 30,
      dir * (i % 3 == 0 ? 23 : 26.5),
      Paint()
        ..color = ink
        ..strokeWidth = i % 3 == 0 ? 1.6 : 1,
    );
  }
  for (final (i, c) in ['N', 'E', 'S', 'W'].indexed) {
    final tp = TextPainter(
      text: TextSpan(
        text: c,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: c == 'N' ? const Color(0xFFB4302A) : ink,
          shadows: const [Shadow(color: Color(0xFFFFFFFF), blurRadius: 2)],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final at = [const Offset(0, -34), const Offset(34, 0), const Offset(0, 34), const Offset(-34, 0)][i];
    tp.paint(canvas, at - Offset(tp.width / 2, tp.height / 2));
  }
  final image = await recorder.endRecording().toImage((size * scale).ceil(), (size * scale).ceil());
  return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

class ClassicLayer {
  ClassicLayer(this.map, this.scale);

  final mbx.MapboxMap map;
  final double scale;
  bool _installed = false;

  Future<void> install() async {
    _installed = false;
    if (!await map.hasStyleImage(_rose)) {
      await map.addImage(_rose, scale, mbx.StyleImage.bytes(await rosePng(scale)));
    }
    for (final id in [_lines, _points, _cross]) {
      if (!await map.styleSourceExists(id)) {
        await map.addStyleSource(id, jsonEncode({'type': 'geojson', 'data': _empty}));
      }
    }
    for (final layer in [
      // A compass rose on every point: north follows the map, the lines leave from its centre
      {
        'id': '$_points-rose',
        'type': 'symbol',
        'source': _points,
        'layout': {
          'icon-image': _rose,
          'icon-rotation-alignment': 'map',
          'icon-pitch-alignment': 'map',
          'icon-allow-overlap': true,
          'icon-ignore-placement': true,
        },
      },
      {
        'id': '$_lines-main',
        'type': 'line',
        'source': _lines,
        'filter': [
          '==',
          ['get', 'kind'],
          'main',
        ],
        'paint': {'line-color': '#b4302a', 'line-width': 2.5},
      },
      {
        'id': '$_lines-back',
        'type': 'line',
        'source': _lines,
        'filter': [
          '==',
          ['get', 'kind'],
          'back',
        ],
        'paint': {
          'line-color': '#d49b22',
          'line-width': 2,
          'line-dasharray': [2, 1.5],
        },
      },
      {
        'id': '$_lines-label',
        'type': 'symbol',
        'source': _lines,
        'layout': {
          'symbol-placement': 'line-center',
          'text-field': ['get', 'text'],
          'text-size': 11,
          'text-offset': [0, -0.8],
          'text-allow-overlap': true,
        },
        'paint': {
          'text-color': [
            'case',
            [
              '==',
              ['get', 'kind'],
              'back',
            ],
            '#7a4e0e',
            '#7a201c',
          ],
          'text-halo-color': '#ffffff',
          'text-halo-width': 1.5,
        },
      },
      {
        'id': '$_points-dot',
        'type': 'circle',
        'source': _points,
        'paint': {
          'circle-radius': 6,
          'circle-color': '#365b25',
          'circle-stroke-color': '#ffffff',
          'circle-stroke-width': 2,
        },
      },
      {
        'id': '$_points-label',
        'type': 'symbol',
        'source': _points,
        'layout': {
          'text-field': ['get', 'label'],
          'text-size': 12,
          // Above the compass rose
          'text-offset': [0, -3.6],
          'text-allow-overlap': true,
        },
        'paint': {'text-color': '#1a2214', 'text-halo-color': '#ffffff', 'text-halo-width': 1.5},
      },
      {
        'id': '$_cross-dot',
        'type': 'circle',
        'source': _cross,
        'paint': {
          'circle-radius': [
            'case',
            ['get', 'checked'],
            8,
            6,
          ],
          'circle-color': [
            'case',
            ['get', 'checked'],
            '#d49b22',
            '#ffffff',
          ],
          'circle-stroke-color': [
            'case',
            ['get', 'checked'],
            '#1a2214',
            '#b4302a',
          ],
          'circle-stroke-width': 2.5,
        },
      },
      {
        'id': '$_cross-label',
        'type': 'symbol',
        'source': _cross,
        'layout': {
          'text-field': ['get', 'label'],
          'text-size': 12,
          'text-offset': [0, 1.5],
          'text-allow-overlap': true,
        },
        'paint': {'text-color': '#7a4e0e', 'text-halo-color': '#ffffff', 'text-halo-width': 1.5},
      },
    ]) {
      final id = layer['id']! as String;
      if (await map.styleLayerExists(id)) await map.removeStyleLayer(id);
      await map.addStyleLayer(jsonEncode(layer), null);
    }
    _installed = true;
  }

  /// [sol] null: Classic is closed, nothing drawn
  Future<void> show(ClassicSolution? sol, ClassicMode mode, ClassicDrawing? drawing) =>
      onStyle(() => _show(sol, mode, drawing));

  Future<void> _show(ClassicSolution? sol, ClassicMode mode, ClassicDrawing? drawing) async {
    if (!_installed) return;
    await map.setStyleSourceProperty(_lines, 'data', drawing == null ? _empty : linesGeoJson(drawing));
    await map.setStyleSourceProperty(_points, 'data', sol == null ? _empty : pointsGeoJson(sol, mode));
    await map.setStyleSourceProperty(_cross, 'data', drawing == null ? _empty : crossGeoJson(drawing));
  }
}
