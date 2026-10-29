import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mbx;
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_theme.dart';
import '../../domain/marked/marked_locations.dart';
import '../../domain/survey/survey_utils.dart';
import '../../domain/util/js_compat.dart';
import '../map/style_guard.dart';
import 'marked_icons.dart';
import 'marked_state.dart';

// Marked locations on the map (MarkedLocationLayer.tsx): a round marker in the category's
// colour with its icon, ringed white for mine, gold for shared with me and grey for other
// accounts (admin); the name above it from zoom 11; the point being picked for the form.

const markedPointsLayer = 'marked-locations-points';
const _source = 'marked-locations';
const _picked = 'marked-picked';

const _rings = {
  MarkedKind.mine: Color(0xFFFFFFFF),
  MarkedKind.shared: Color(0xFFE9B640),
  MarkedKind.other: Color(0xFF9CA3AF),
};

String markerImageId(MarkedLocationCategory c, MarkedKind k) => 'marked-${c.name}-${k.name}';

/// Marker image: the icon in white on the category colour with the ring, 30 pt
Future<Uint8List> markerPng(MarkedLocationCategory c, MarkedKind k, double scale) async {
  const size = 30.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(scale);
  const center = Offset(size / 2, size / 2);
  canvas
    ..drawCircle(
      center.translate(0, 1),
      13,
      Paint()
        ..color = const Color(0x55000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5),
    )
    ..drawCircle(center, 13, Paint()..color = _rings[k]!)
    ..drawCircle(center, k == MarkedKind.mine ? 11 : 10.5, Paint()..color = markedCategoryColor(c));
  final icon = markedCategoryIcons[c] ?? Icons.place;
  final text = TextPainter(
    text: TextSpan(
      text: String.fromCharCode(icon.codePoint),
      style: TextStyle(fontSize: 15, fontFamily: icon.fontFamily, package: icon.fontPackage, color: Colors.white),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  text.paint(canvas, center - Offset(text.width / 2, text.height / 2));
  final image = await recorder.endRecording().toImage((size * scale).ceil(), (size * scale).ceil());
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}

Map<String, Object> markedGeoJson(List<VisibleLocation> visible) => {
  'type': 'FeatureCollection',
  'features': [
    for (final v in visible)
      {
        'type': 'Feature',
        'properties': {
          'id': v.location.id,
          'name': v.location.name,
          'icon': markerImageId(v.location.category, v.kind),
        },
        'geometry': {
          'type': 'Point',
          'coordinates': [v.location.lng, v.location.lat],
        },
      },
  ],
};

class MarkedLayer {
  MarkedLayer(this.map, this.scale);

  final mbx.MapboxMap map;
  final double scale;
  bool _installed = false;

  Future<void> install() async {
    _installed = false;
    for (final c in MarkedLocationCategory.values) {
      for (final k in MarkedKind.values) {
        final id = markerImageId(c, k);
        if (await map.hasStyleImage(id)) continue;
        await map.addImage(id, scale, mbx.StyleImage.bytes(await markerPng(c, k, scale)));
      }
    }
    for (final id in [_source, _picked]) {
      if (!await map.styleSourceExists(id)) {
        await map.addStyleSource(id, jsonEncode({'type': 'geojson', 'data': markedGeoJson(const [])}));
      }
    }
    for (final layer in [
      {
        'id': markedPointsLayer,
        'type': 'symbol',
        'source': _source,
        'layout': {
          'icon-image': ['get', 'icon'],
          'icon-size': [
            'interpolate',
            ['linear'],
            ['zoom'],
            5,
            0.55,
            12,
            0.8,
            16,
            1,
          ],
          'icon-allow-overlap': true,
          'icon-ignore-placement': true,
        },
      },
      {
        'id': '$_source-labels',
        'type': 'symbol',
        'source': _source,
        'minzoom': 11,
        'layout': {
          'text-field': ['get', 'name'],
          'text-size': 12,
          'text-anchor': 'bottom',
          'text-offset': [0, -1.6],
          'text-max-width': 12,
        },
        'paint': {'text-color': '#1a2214', 'text-halo-color': '#ffffff', 'text-halo-width': 1.5},
      },
      {
        'id': '$_picked-dot',
        'type': 'circle',
        'source': _picked,
        'paint': {
          'circle-radius': 9,
          'circle-color': '#e46c24',
          'circle-stroke-color': '#ffffff',
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

  Future<void> show(MarkedState s) => onStyle(() => _show(s));

  Future<void> _show(MarkedState s) async {
    if (!_installed) return;
    await map.setStyleSourceProperty(_source, 'data', markedGeoJson(s.visible));
    // The open location shows its name in the card instead
    await map.setStyleLayerProperty('$_source-labels', 'filter', [
      '!=',
      ['get', 'id'],
      s.selectedId ?? '',
    ]);
    final p = s.picked;
    await map.setStyleSourceProperty(_picked, 'data', {
      'type': 'FeatureCollection',
      'features': [
        if (p != null)
          {
            'type': 'Feature',
            'properties': <String, Object>{},
            'geometry': {
              'type': 'Point',
              'coordinates': [p.lng, p.lat],
            },
          },
      ],
    });
  }
}

/// While picking a position: the hint above the sheet
class PickingBar extends ConsumerWidget {
  const PickingBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Material(
    key: const Key('marked-picking'),
    color: L360Colors.ink,
    borderRadius: BorderRadius.circular(L360.radius),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
      child: Row(
        children: [
          const Icon(Icons.my_location, color: Colors.white, size: 18),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Tap the map to set the position',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            onPressed: ref.read(markedProvider.notifier).stopPicking,
            child: const Text('Cancel'),
          ),
        ],
      ),
    ),
  );
}

/// Card of the location open on the map: name and buttons; details on request
class MarkedCard extends ConsumerStatefulWidget {
  const MarkedCard({super.key, required this.onOpenList});

  final VoidCallback onOpenList;

  @override
  ConsumerState<MarkedCard> createState() => _MarkedCardState();
}

class _MarkedCardState extends ConsumerState<MarkedCard> {
  bool _details = false;
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final v = ref.watch(markedProvider.select((s) => s.selected));
    if (v == null) return const SizedBox.shrink();
    final l = v.location;
    final color = markedCategoryColor(l.category);
    const small = TextStyle(fontSize: 12, color: L360Colors.sand700, height: 1.35);
    return Material(
      key: const Key('marked-card'),
      color: Colors.white,
      elevation: 6,
      shadowColor: const Color(0x40000000),
      borderRadius: BorderRadius.circular(L360.radius),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 4, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                  child: Icon(markedCategoryIcons[l.category], color: Colors.white, size: 18),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                      Text(
                        [
                          l.category.label,
                          if (l.elevationM != null) '${jsRoundStr(l.elevationM!)} mdpl',
                          if (v.owner != null) 'by ${v.owner}',
                        ].join(' · '),
                        style: const TextStyle(fontSize: 12, color: L360Colors.sand500),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: const Key('marked-details'),
                  tooltip: _details ? 'Hide details' : 'Show details',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(_details ? Icons.expand_more : Icons.expand_less, size: 22),
                  onPressed: () => setState(() => _details = !_details),
                ),
                IconButton(
                  key: const Key('marked-card-close'),
                  tooltip: 'Close',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => ref.read(markedProvider.notifier).select(null),
                ),
              ],
            ),
            if (_details)
              Padding(
                padding: const EdgeInsets.fromLTRB(44, 6, 12, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${toDMS(l.lat, isLat: true)} ${toDMS(l.lng, isLat: false)}', style: small),
                    Text(formatLatLng(l.lat, l.lng), style: small),
                    if (l.address?.isNotEmpty ?? false) Text(l.address!, style: small),
                    if (l.description?.isNotEmpty ?? false)
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 96),
                        child: SingleChildScrollView(child: Text(l.description!, style: small)),
                      ),
                    if (l.contact?.isNotEmpty ?? false) Text('Contact: ${l.contact}', style: small),
                    if (l.tags.isNotEmpty) Text(l.tags.join(' · '), style: small),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 38)),
                    onPressed: () =>
                        launchUrl(Uri.parse(directionsUrl(l.lat, l.lng)), mode: LaunchMode.externalApplication),
                    icon: const Icon(Icons.directions, size: 18),
                    label: const Text('Directions'),
                  ),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 38)),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: formatLatLng(l.lat, l.lng)));
                      setState(() => _copied = true);
                      Future<void>.delayed(const Duration(milliseconds: 1500), () {
                        if (mounted) setState(() => _copied = false);
                      });
                    },
                    icon: Icon(_copied ? Icons.check : Icons.copy, size: 16),
                    label: Text(_copied ? 'Copied' : 'Copy'),
                  ),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 38)),
                    onPressed: widget.onOpenList,
                    icon: const Icon(Icons.list, size: 18),
                    label: const Text('In list'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
