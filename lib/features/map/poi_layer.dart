import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mbx;

import '../../core/theme/app_theme.dart';
import '../../domain/search/place_search.dart';
import '../../domain/survey/survey_utils.dart';

// Points of interest on the map (MapBoxContainer.tsx): a dot per point coloured by its
// category, grouped into numbered clusters, from zoom 10. Tapping a dot opens its card,
// tapping a cluster zooms into it.

const poiSource = 'poi-locations';
const poiPointsLayer = 'poi-points';
const poiClustersLayer = 'poi-clusters';
const _minZoom = 10.0;

/// Label, colour (as on the web map) and icon of each category
const poiCategoryMeta = <String, (String, Color, IconData)>{
  'mountain': ('Summit', Color(0xFF365B25), Icons.landscape),
  'basecamp': ('Basecamp / trailhead', Color(0xFFD49B22), Icons.cabin),
  'water': ('Water source', Color(0xFF2563EB), Icons.water_drop),
  'river': ('River', Color(0xFF0EA5E9), Icons.waves),
  'cliff': ('Cliff', Color(0xFFE46C24), Icons.terrain),
  'cave': ('Cave', Color(0xFFB4302A), Icons.dark_mode_outlined),
  'poi': ('Place', Color(0xFFD49B22), Icons.place),
};

(String, Color, IconData) poiMeta(String category) => poiCategoryMeta[category] ?? poiCategoryMeta['poi']!;

Map<String, Object> poiGeoJson(List<PointOfInterest> pois) => {
  'type': 'FeatureCollection',
  'features': [
    for (final p in pois)
      {
        'type': 'Feature',
        'properties': {'id': p.id, 'kind': p.category},
        'geometry': {
          'type': 'Point',
          'coordinates': [p.lng, p.lat],
        },
      },
  ],
};

String _hex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

class PoiLayer {
  PoiLayer(this.map);

  final mbx.MapboxMap map;
  bool _installed = false;

  Future<void> install(List<PointOfInterest> pois, {required bool visible}) async {
    _installed = false;
    if (await map.styleSourceExists(poiSource)) {
      for (final id in [poiPointsLayer, poiClustersLayer, '$poiSource-count']) {
        if (await map.styleLayerExists(id)) await map.removeStyleLayer(id);
      }
      await map.removeStyleSource(poiSource);
    }
    await map.addStyleSource(
      poiSource,
      jsonEncode({
        'type': 'geojson',
        'data': poiGeoJson(pois),
        'cluster': true,
        'clusterRadius': 50,
        'clusterMaxZoom': 14,
      }),
    );
    final visibility = visible ? 'visible' : 'none';
    final colors = <Object>[
      'match',
      ['get', 'kind'],
      for (final e in poiCategoryMeta.entries)
        if (e.key != 'poi') ...[e.key, _hex(e.value.$2)],
      _hex(poiCategoryMeta['poi']!.$2),
    ];
    for (final layer in [
      {
        'id': poiPointsLayer,
        'type': 'circle',
        'source': poiSource,
        'minzoom': _minZoom,
        'filter': [
          '!',
          ['has', 'point_count'],
        ],
        'layout': {'visibility': visibility},
        'paint': {
          'circle-color': colors,
          'circle-radius': 7,
          'circle-stroke-width': 2,
          'circle-stroke-color': '#ffffff',
          'circle-opacity': 0.95,
        },
      },
      {
        'id': poiClustersLayer,
        'type': 'circle',
        'source': poiSource,
        'minzoom': _minZoom,
        'filter': ['has', 'point_count'],
        'layout': {'visibility': visibility},
        'paint': {
          'circle-color': [
            'step',
            ['get', 'point_count'],
            '#ec7f3d',
            50,
            '#e46c24',
            200,
            '#c8551a',
          ],
          'circle-radius': [
            'step',
            ['get', 'point_count'],
            16,
            50,
            22,
            200,
            28,
          ],
          'circle-opacity': 0.95,
          'circle-stroke-width': 2,
          'circle-stroke-color': '#ffffff',
        },
      },
      {
        'id': '$poiSource-count',
        'type': 'symbol',
        'source': poiSource,
        'minzoom': _minZoom,
        'filter': ['has', 'point_count'],
        'layout': {
          'visibility': visibility,
          'text-field': ['get', 'point_count_abbreviated'],
          'text-size': 12,
          'text-allow-overlap': true,
        },
        'paint': {'text-color': '#ffffff'},
      },
    ]) {
      await map.addStyleLayer(jsonEncode(layer), null);
    }
    _installed = true;
  }

  Future<void> show(List<PointOfInterest> pois) async {
    if (_installed) await map.setStyleSourceProperty(poiSource, 'data', poiGeoJson(pois));
  }

  Future<void> setVisible(bool visible) async {
    if (!_installed) return;
    for (final id in [poiPointsLayer, poiClustersLayer, '$poiSource-count']) {
      await map.setStyleLayerProperty(id, 'visibility', visible ? 'visible' : 'none');
    }
  }
}

/// The point whose card is open
class SelectedPoi extends Notifier<PointOfInterest?> {
  @override
  PointOfInterest? build() => null;

  void select(PointOfInterest? p) => state = p;
}

final selectedPoiProvider = NotifierProvider<SelectedPoi, PointOfInterest?>(SelectedPoi.new);

/// Card of a point of interest above the sheet: name, category, height, description
class PoiCard extends ConsumerWidget {
  const PoiCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(selectedPoiProvider);
    if (p == null) return const SizedBox.shrink();
    final (label, color, icon) = poiMeta(p.category);
    return Material(
      key: const Key('poi-card'),
      color: Colors.white,
      elevation: 6,
      shadowColor: const Color(0x40000000),
      borderRadius: BorderRadius.circular(L360.radius),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 4, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(color: color.withValues(alpha: 0.14), shape: BoxShape.circle),
                  child: Icon(icon, size: 20, color: color),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(p.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                      Text(
                        [label, if (p.subtitle?.isNotEmpty ?? false) p.subtitle!].join(' · ').toUpperCase(),
                        style: const TextStyle(fontSize: 11, color: L360Colors.sand500, letterSpacing: 0.4),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${toDMS(p.lat, isLat: true)} ${toDMS(p.lng, isLat: false)}',
                        style: const TextStyle(fontSize: 12, color: L360Colors.sand600),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: const Key('poi-close'),
                  tooltip: 'Close',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => ref.read(selectedPoiProvider.notifier).select(null),
                ),
              ],
            ),
            if (p.description?.isNotEmpty ?? false) ...[
              const Divider(height: 18),
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 120),
                  child: SingleChildScrollView(
                    child: Text(
                      p.description!,
                      style: const TextStyle(fontSize: 13, color: L360Colors.sand700, height: 1.35),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              const Text('Data source: Wikipedia', style: TextStyle(fontSize: 11, color: L360Colors.sand500)),
            ],
          ],
        ),
      ),
    );
  }
}
