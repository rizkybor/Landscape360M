import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mbx;

import '../../core/theme/app_theme.dart';
import '../../domain/community/club_map.dart';
import '../../domain/marked/marked_areas.dart' show formatArea, formatLength, ringArea;
import '../map/style_guard.dart';
import 'club_map_state.dart';

// The club map on the map: everyone's drawings in their colour (areas filled, lines, pins as dots,
// notes as rings, each with its label; the selected one thicker), the drawing being made, the bar
// while points are tapped (Undo / Cancel / Done), and the card of the club map (open the selected
// drawing, fit all, close). Fills and lines lie on the 3D terrain by themselves.

const clubMapFillLayer = 'club-map-fill';
const clubMapLineLayer = 'club-map-line';
const clubMapPointLayer = 'club-map-point';
const _source = 'club-map';
const _draft = 'club-map-draft';
const _empty = <String, Object>{'type': 'FeatureCollection', 'features': <Object>[]};

List<double> _c((double, double) p) => [p.$1, p.$2];

/// The club's drawings, with their colour, label, kind and whether selected
Map<String, Object> clubMapGeoJson(List<Annotation> annotations, String? selectedId) => {
  'type': 'FeatureCollection',
  'features': [
    for (final a in annotations)
      if (a.points.isNotEmpty)
        {
          'type': 'Feature',
          'properties': {
            'id': a.id,
            'color': a.color,
            'label': a.label,
            'kind': a.kind.name,
            'selected': a.id == selectedId,
          },
          'geometry': a.geometry,
        },
  ],
};

/// The drawing being made: its shape so far and its points
Map<String, Object> clubDraftGeoJson(ClubDraw? d) {
  if (d == null || d.points.isEmpty) return _empty;
  final pts = [for (final p in d.points) _c(p)];
  return {
    'type': 'FeatureCollection',
    'features': [
      if (d.kind == AnnotationKind.area && pts.length >= 3)
        {
          'type': 'Feature',
          'properties': {'color': d.color},
          'geometry': {
            'type': 'Polygon',
            'coordinates': [
              [...pts, pts.first],
            ],
          },
        },
      if (!d.kind.isPoint && pts.length >= 2)
        {
          'type': 'Feature',
          'properties': {'color': d.color},
          'geometry': {
            'type': 'LineString',
            'coordinates': d.kind == AnnotationKind.area && pts.length >= 3 ? [...pts, pts.first] : pts,
          },
        },
      for (final p in pts)
        {
          'type': 'Feature',
          'properties': {'color': d.color},
          'geometry': {'type': 'Point', 'coordinates': p},
        },
    ],
  };
}

class ClubMapLayer {
  ClubMapLayer(this.map);

  final mbx.MapboxMap map;
  bool _installed = false;

  Future<void> install() async {
    _installed = false;
    for (final id in [_source, _draft]) {
      if (!await map.styleSourceExists(id)) {
        await map.addStyleSource(id, jsonEncode({'type': 'geojson', 'data': _empty}));
      }
    }
    Object geom(String type) => [
      '==',
      ['geometry-type'],
      type,
    ];
    final selected = ['get', 'selected'];
    for (final layer in [
      {
        'id': clubMapFillLayer,
        'type': 'fill',
        'source': _source,
        'filter': geom('Polygon'),
        'paint': {
          'fill-color': ['get', 'color'],
          'fill-opacity': ['case', selected, 0.32, 0.18],
        },
      },
      {
        'id': clubMapLineLayer,
        'type': 'line',
        'source': _source,
        'filter': [
          '!=',
          ['geometry-type'],
          'Point',
        ],
        'layout': {'line-join': 'round', 'line-cap': 'round'},
        'paint': {
          'line-color': ['get', 'color'],
          'line-width': ['case', selected, 5, 3],
        },
      },
      {
        'id': clubMapPointLayer,
        'type': 'circle',
        'source': _source,
        'filter': geom('Point'),
        'paint': {
          'circle-radius': ['case', selected, 10, 7],
          // A pin is a dot in its colour, a note a white dot ringed in its colour
          'circle-color': [
            'case',
            [
              '==',
              ['get', 'kind'],
              'note',
            ],
            '#ffffff',
            ['get', 'color'],
          ],
          'circle-stroke-color': [
            'case',
            [
              '==',
              ['get', 'kind'],
              'note',
            ],
            ['get', 'color'],
            '#ffffff',
          ],
          'circle-stroke-width': 3,
        },
      },
      {
        'id': '$_source-labels',
        'type': 'symbol',
        'source': _source,
        'layout': {
          'text-field': ['get', 'label'],
          'text-size': 12,
          'text-anchor': 'top',
          'text-offset': [0, 0.9],
          'text-max-width': 12,
          'text-optional': true,
        },
        'paint': {'text-color': '#1a2214', 'text-halo-color': '#ffffff', 'text-halo-width': 1.5},
      },
      {
        'id': '$_draft-fill',
        'type': 'fill',
        'source': _draft,
        'filter': geom('Polygon'),
        'paint': {
          'fill-color': ['get', 'color'],
          'fill-opacity': 0.2,
        },
      },
      {
        'id': '$_draft-line',
        'type': 'line',
        'source': _draft,
        'filter': geom('LineString'),
        'layout': {'line-join': 'round', 'line-cap': 'round'},
        'paint': {
          'line-color': ['get', 'color'],
          'line-width': 3,
          'line-dasharray': [2, 1.5],
        },
      },
      {
        'id': '$_draft-points',
        'type': 'circle',
        'source': _draft,
        'filter': geom('Point'),
        'paint': {
          'circle-radius': 6,
          'circle-color': '#ffffff',
          'circle-stroke-color': ['get', 'color'],
          'circle-stroke-width': 3,
        },
      },
    ]) {
      final id = layer['id']! as String;
      if (await map.styleLayerExists(id)) await map.removeStyleLayer(id);
      await map.addStyleLayer(jsonEncode(layer), null);
    }
    _installed = true;
  }

  Future<void> show(ClubMapState s, ClubDraw? draw) => onStyle(() async {
    if (!_installed) return;
    await map.setStyleSourceProperty(_source, 'data', s.shown ? clubMapGeoJson(s.annotations, s.selectedId) : _empty);
    await map.setStyleSourceProperty(_draft, 'data', clubDraftGeoJson(draw));
  });
}

/// While a drawing's points are tapped: what to do, its length or area, Undo / Cancel / Done
class ClubDrawingBar extends ConsumerWidget {
  const ClubDrawingBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(clubDrawProvider);
    if (d == null) return const SizedBox.shrink();
    final ctrl = ref.read(clubDrawProvider.notifier);
    final n = d.points.length;
    final hint = d.kind.isPoint
        ? (n == 0 ? 'Tap the map where it goes' : 'Tap again to move it')
        : 'Tap the map to add points · $n${n < d.kind.needed ? ' (at least ${d.kind.needed})' : ''}';
    final measure = d.kind == AnnotationKind.line && n >= 2
        ? 'Length ${formatLength(lineLengthM(d.points))}'
        : d.kind == AnnotationKind.area && n >= 3
        ? 'Area ${formatArea(ringArea(d.points))}'
        : null;
    return Material(
      key: const Key('club-drawing'),
      color: Colors.white,
      elevation: 6,
      shadowColor: const Color(0x40000000),
      borderRadius: BorderRadius.circular(L360.radius),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(color: hexToColor(d.color), shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${d.editingId == null ? 'New' : 'Edit'} ${d.kind.label.toLowerCase()}: $hint',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            if (measure != null)
              Padding(
                padding: const EdgeInsets.only(top: 2, left: 20),
                child: Text(measure, style: const TextStyle(fontSize: 12, color: L360Colors.sand600)),
              ),
            const SizedBox(height: 10),
            Row(
              children: [
                if (!d.kind.isPoint) ...[
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('club-draw-undo'),
                      style: OutlinedButton.styleFrom(minimumSize: const Size(0, 42)),
                      onPressed: n == 0 ? null : ctrl.undo,
                      icon: const Icon(Icons.undo, size: 18),
                      label: const Text('Undo'),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: OutlinedButton(
                    key: const Key('club-draw-cancel'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 42)),
                    onPressed: ctrl.cancel,
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    key: const Key('club-draw-done'),
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 42)),
                    onPressed: d.ready ? ctrl.done : null,
                    icon: const Icon(Icons.check, size: 18),
                    label: const Text('Done'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

Color hexToColor(String hex) {
  final v = int.tryParse(hex.replaceFirst('#', ''), radix: 16) ?? 0xd49b22;
  return Color(0xFF000000 | v);
}

IconData annotationIcon(AnnotationKind k) => switch (k) {
  AnnotationKind.pin => Icons.place_outlined,
  AnnotationKind.line => Icons.timeline,
  AnnotationKind.area => Icons.pentagon_outlined,
  AnnotationKind.note => Icons.sticky_note_2_outlined,
};

/// The club map on the map: club name, the selected drawing (tap to open it), fit all, close
class ClubMapCard extends ConsumerWidget {
  const ClubMapCard({super.key, required this.onOpen});

  /// Opens a drawing's page
  final void Function(Annotation a) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(clubMapProvider);
    final club = s.club;
    if (club == null) return const SizedBox.shrink();
    final ctrl = ref.read(clubMapProvider.notifier);
    final a = s.selected;
    return Material(
      key: const Key('club-map-card'),
      color: Colors.white,
      elevation: 6,
      shadowColor: const Color(0x40000000),
      borderRadius: BorderRadius.circular(L360.radius),
      child: InkWell(
        borderRadius: BorderRadius.circular(L360.radius),
        onTap: a == null ? null : () => onOpen(a),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: a == null ? L360Colors.forest700 : hexToColor(a.color),
                  shape: BoxShape.circle,
                ),
                child: Icon(a == null ? Icons.draw_outlined : annotationIcon(a.kind), size: 17, color: Colors.white),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      a?.label ?? '${club.name} map',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                    ),
                    Text(
                      a == null
                          ? '${s.annotations.length} drawing${s.annotations.length == 1 ? '' : 's'} · tap one on the map'
                          : [a.authorName, ?a.measure, 'Tap to open'].where((t) => t.isNotEmpty).join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: L360Colors.sand600),
                    ),
                  ],
                ),
              ),
              if (s.annotations.isNotEmpty)
                IconButton(
                  key: const Key('club-map-fit'),
                  tooltip: 'Show all',
                  icon: const Icon(Icons.fit_screen_outlined, size: 20),
                  onPressed: () {
                    ctrl.select(null);
                    ctrl.fit();
                  },
                ),
              IconButton(
                key: const Key('club-map-close'),
                tooltip: 'Hide the club map',
                icon: const Icon(Icons.close, size: 20),
                onPressed: ctrl.close,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
