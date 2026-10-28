import 'dart:async';
import 'dart:convert';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mbx;
import 'package:url_launcher/url_launcher.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../data/marked/marked_area_repository.dart';
import '../../domain/marked/marked_areas.dart';
import '../../domain/marked/marked_locations.dart';
import '../../domain/share/share_location.dart';
import '../../domain/survey/survey_utils.dart';
import '../../domain/util/js_compat.dart';
import '../areas/area_state.dart' show areaBackendProvider;
import '../marked/marked_icons.dart';
import 'map_tools_state.dart';

// Links that open the app (SharedLocationMarker.tsx, SharedPlaceLayer.tsx): /?at=lat,lng
// shows a "Shared location" pin, /?place=<token> a marked location someone shared, both
// and /?area=<token> a marked area in focus, all without signing in.

class LinkedPlace {
  const LinkedPlace({
    required this.name,
    required this.category,
    required this.lat,
    required this.lng,
    this.elevationM,
    this.description,
    this.address,
    this.contact,
    this.tags = const [],
    this.ownerName,
  });

  /// Row of open_marked_location_link
  factory LinkedPlace.fromRow(Map<String, dynamic> r) => LinkedPlace(
    name: '${r['name']}',
    category: MarkedLocationCategory.fromName('${r['category']}') ?? MarkedLocationCategory.poi,
    lat: (r['lat'] as num).toDouble(),
    lng: (r['lng'] as num).toDouble(),
    elevationM: (r['elevation_m'] as num?)?.toDouble(),
    description: r['description'] as String?,
    address: r['address'] as String?,
    contact: r['contact'] as String?,
    tags: [for (final t in (r['tags'] as List? ?? const [])) '$t'],
    ownerName: r['owner_name'] as String?,
  );

  final String name;
  final MarkedLocationCategory category;
  final double lat;
  final double lng;
  final double? elevationM;
  final String? description;
  final String? address;
  final String? contact;
  final List<String> tags;
  final String? ownerName;
}

/// Opens a shared marked location (the server checks the token; no sign-in needed)
typedef PlaceOpener = Future<LinkedPlace?> Function(String token);

final placeOpenerProvider = Provider<PlaceOpener>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return (token) async {
    final rows = await client.rpc<List<dynamic>>('open_marked_location_link', params: {'p_token': token});
    return rows.isEmpty ? null : LinkedPlace.fromRow(Map<String, dynamic>.from(rows.first as Map));
  };
});

enum LinkStatus { loading, ok, gone, error }

/// What a link put on the map
sealed class SharedView {
  const SharedView();
}

class SharedPin extends SharedView {
  const SharedPin(this.point);
  final SharedPoint point;
}

class SharedPlace extends SharedView {
  const SharedPlace(this.status, [this.place]);
  final LinkStatus status;
  final LinkedPlace? place;
}

/// A marked area from /?area=: shown in focus, the rest of the map darkened
class SharedArea extends SharedView {
  const SharedArea(this.status, [this.area]);
  final LinkStatus status;
  final LinkedArea? area;
}

class SharedLinkController extends Notifier<SharedView?> {
  @override
  SharedView? build() => null;

  /// Set once a link was opened: the map then stays there instead of moving to the GPS
  bool openedFromLink = false;

  Future<void> open(IncomingLink link) async {
    openedFromLink = true;
    switch (link) {
      case PointLink(:final point):
        state = SharedPin(point);
        ref.read(flyToProvider.notifier).go(point.lng, point.lat, zoom: 15);
      case PlaceLink(:final token):
        state = const SharedPlace(LinkStatus.loading);
        try {
          final place = await ref.read(placeOpenerProvider)(token);
          if (place == null) {
            state = const SharedPlace(LinkStatus.gone);
            return;
          }
          state = SharedPlace(LinkStatus.ok, place);
          ref.read(flyToProvider.notifier).go(place.lng, place.lat);
        } on Object {
          state = const SharedPlace(LinkStatus.error);
        }
      case AreaLink(:final token):
        state = const SharedArea(LinkStatus.loading);
        try {
          final area = await ref.read(areaBackendProvider).open(token);
          if (area == null) {
            state = const SharedArea(LinkStatus.gone);
            return;
          }
          state = SharedArea(LinkStatus.ok, area);
          ref.read(fitPointsProvider.notifier).go(area.ring);
        } on Object {
          state = const SharedArea(LinkStatus.error);
        }
    }
  }

  void close() => state = null;
}

final sharedLinkProvider = NotifierProvider<SharedLinkController, SharedView?>(SharedLinkController.new);

/// Listens for share links opening the app (at start and while it runs)
class IncomingLinks {
  IncomingLinks(this.ref, {AppLinks? links}) : _links = links ?? AppLinks();

  final WidgetRef ref;
  final AppLinks _links;
  StreamSubscription<Uri>? _sub;

  void start() {
    _sub = _links.uriLinkStream.listen(_handle, onError: (_) {});
  }

  void _handle(Uri uri) {
    final link = IncomingLink.parse(uri);
    if (link != null) unawaited(ref.read(sharedLinkProvider.notifier).open(link));
  }

  void dispose() => unawaited(_sub?.cancel());
}

// --- On the map --------------------------------------------------------------------------------

const _source = 'shared-link';

class SharedLinkLayer {
  SharedLinkLayer(this.map);

  final mbx.MapboxMap map;
  bool _installed = false;

  Future<void> install() async {
    _installed = false;
    if (!await map.styleSourceExists(_source)) {
      await map.addStyleSource(_source, jsonEncode({'type': 'geojson', 'data': _geo(null)}));
    }
    for (final layer in [
      {
        'id': '$_source-halo',
        'type': 'circle',
        'source': _source,
        'paint': {
          'circle-radius': 16,
          'circle-color': ['get', 'color'],
          'circle-opacity': 0.25,
        },
      },
      {
        'id': '$_source-dot',
        'type': 'circle',
        'source': _source,
        'paint': {
          'circle-radius': 8,
          'circle-color': ['get', 'color'],
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

  static Map<String, Object> _geo(SharedView? v) {
    final (double, double, String)? at = switch (v) {
      SharedPin(:final point) => (point.lng, point.lat, '#962620'),
      SharedPlace(:final place?) => (place.lng, place.lat, _hex(markedCategoryColor(place.category))),
      _ => null,
    };
    return {
      'type': 'FeatureCollection',
      'features': [
        if (at != null)
          {
            'type': 'Feature',
            'properties': {'color': at.$3},
            'geometry': {
              'type': 'Point',
              'coordinates': [at.$1, at.$2],
            },
          },
      ],
    };
  }

  static String _hex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

  Future<void> show(SharedView? v) async {
    if (_installed) await map.setStyleSourceProperty(_source, 'data', _geo(v));
  }
}

/// Card for the opened link, above the sheet
class SharedLinkCard extends ConsumerStatefulWidget {
  const SharedLinkCard({super.key});

  @override
  ConsumerState<SharedLinkCard> createState() => _SharedLinkCardState();
}

class _SharedLinkCardState extends ConsumerState<SharedLinkCard> {
  bool _open = true;

  @override
  Widget build(BuildContext context) {
    final v = ref.watch(sharedLinkProvider);
    if (v == null) return const SizedBox.shrink();
    final close = ref.read(sharedLinkProvider.notifier).close;
    final Widget body = switch (v) {
      SharedPin(:final point) => _header(
        icon: Icons.location_on,
        color: const Color(0xFF962620),
        title: 'Shared location',
        subtitle: '${toDMS(point.lat, isLat: true)} ${toDMS(point.lng, isLat: false)}',
        onClose: close,
      ),
      SharedPlace(status: LinkStatus.loading) => _note('Opening the shared location…', close, busy: true),
      SharedPlace(status: LinkStatus.gone) => _note(
        'This shared link is no longer available. The owner may have turned it off.',
        close,
      ),
      SharedPlace(status: LinkStatus.error) => _note(
        'Could not open the shared link. Check your connection, or update the app.',
        close,
      ),
      SharedPlace(:final place?) => _place(place, close),
      SharedPlace() => const SizedBox.shrink(),
      SharedArea(status: LinkStatus.loading) => _note('Opening the shared area…', close, busy: true),
      SharedArea(status: LinkStatus.gone) => _note(
        'This shared area is no longer available. The owner may have turned the link off.',
        close,
      ),
      SharedArea(status: LinkStatus.error) => _note(
        'Could not open the shared area. Check your connection and try again.',
        close,
      ),
      SharedArea(:final area?) => _area(area, close),
      SharedArea() => const SizedBox.shrink(),
    };
    return Material(
      key: const Key('shared-link-card'),
      color: Colors.white,
      elevation: 6,
      shadowColor: const Color(0x40000000),
      borderRadius: BorderRadius.circular(L360.radius),
      child: Padding(padding: const EdgeInsets.fromLTRB(14, 10, 4, 12), child: body),
    );
  }

  Widget _header({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback onClose,
    Widget? extra,
  }) => Row(
    children: [
      Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: Icon(icon, size: 18, color: Colors.white),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            Text(subtitle, style: const TextStyle(fontSize: 12, color: L360Colors.sand600)),
          ],
        ),
      ),
      ?extra,
      IconButton(
        key: const Key('shared-link-close'),
        tooltip: 'Remove',
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.close, size: 20),
        onPressed: onClose,
      ),
    ],
  );

  Widget _note(String text, VoidCallback onClose, {bool busy = false}) => Row(
    children: [
      if (busy)
        const Padding(
          padding: EdgeInsets.only(right: 10),
          child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
      IconButton(tooltip: 'Close', icon: const Icon(Icons.close, size: 20), onPressed: onClose),
    ],
  );

  Widget _area(LinkedArea a, VoidCallback onClose) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      _header(
        icon: Icons.hexagon_outlined,
        color: Color(int.parse('FF${a.color.replaceFirst('#', '')}', radix: 16)),
        title: a.name,
        subtitle: [
          formatArea(a.areaM2),
          'perimeter ${formatLength(a.perimeterM)}',
          if (a.ownerName != null) 'shared by ${a.ownerName}',
        ].join(' · '),
        onClose: onClose,
        extra: a.notes?.isNotEmpty ?? false
            ? IconButton(
                tooltip: _open ? 'Hide notes' : 'Show notes',
                visualDensity: VisualDensity.compact,
                icon: Icon(_open ? Icons.expand_more : Icons.expand_less, size: 22),
                onPressed: () => setState(() => _open = !_open),
              )
            : null,
      ),
      if (_open && (a.notes?.isNotEmpty ?? false))
        Padding(
          padding: const EdgeInsets.fromLTRB(44, 6, 12, 0),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 110),
            child: SingleChildScrollView(
              child: Text(a.notes!, style: const TextStyle(fontSize: 12, color: L360Colors.sand700, height: 1.35)),
            ),
          ),
        ),
    ],
  );

  Widget _place(LinkedPlace p, VoidCallback onClose) {
    const small = TextStyle(fontSize: 12, color: L360Colors.sand700, height: 1.35);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _header(
          icon: markedCategoryIcons[p.category] ?? Icons.place,
          color: markedCategoryColor(p.category),
          title: p.name,
          subtitle: [p.category.label, if (p.ownerName != null) 'shared by ${p.ownerName}'].join(' · '),
          onClose: onClose,
          extra: IconButton(
            tooltip: _open ? 'Hide details' : 'Show details',
            visualDensity: VisualDensity.compact,
            icon: Icon(_open ? Icons.expand_more : Icons.expand_less, size: 22),
            onPressed: () => setState(() => _open = !_open),
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.fromLTRB(44, 6, 12, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${toDMS(p.lat, isLat: true)} ${toDMS(p.lng, isLat: false)}', style: small),
                Text(
                  '${p.lat.toStringAsFixed(5)}, ${p.lng.toStringAsFixed(5)}'
                  '${p.elevationM == null ? '' : ' · ${jsRoundStr(p.elevationM!)} mdpl'}',
                  style: small,
                ),
                if (p.address?.isNotEmpty ?? false) Text(p.address!, style: small),
                if (p.description?.isNotEmpty ?? false)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 96),
                    child: SingleChildScrollView(child: Text(p.description!, style: small)),
                  ),
                if (p.contact?.isNotEmpty ?? false) Text('Contact: ${p.contact}', style: small),
                if (p.tags.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        for (final t in p.tags)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: L360Colors.sand100,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(t, style: const TextStyle(fontSize: 10)),
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 38)),
                  onPressed: () =>
                      launchUrl(Uri.parse(directionsUrl(p.lat, p.lng)), mode: LaunchMode.externalApplication),
                  icon: const Icon(Icons.directions, size: 18),
                  label: const Text('Directions'),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
