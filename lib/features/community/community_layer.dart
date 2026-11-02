import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mbx;

import '../../core/theme/app_theme.dart';
import '../../domain/community/community.dart';
import '../../domain/community/community_attachments.dart';
import '../../domain/community/community_events.dart';
import '../map/map_tools_state.dart';
import '../map/style_guard.dart';
import 'community_events_ui.dart' show openEvent;
import 'community_live_state.dart';
import 'community_post_page.dart';
import 'community_state.dart';
import 'community_widgets.dart';

// Community on the map (COMMUNITY_PRD.md 8.2): recent posts in view as markers in the colour
// and icon of their main condition, grouped into numbered clusters when zoomed out (tap a
// marker for the post, a cluster to zoom in); the post shown with "Show on map" and its
// attached track, area or location; and the bar while a post's location is picked.

const communityPointsLayer = 'community-points';
const communityClustersLayer = 'community-clusters';
const communityLiveLayer = 'community-live-dots';
const _live = 'community-live';
const _liveTrail = 'community-live-trail';
const _source = 'community-posts';
const _focus = 'community-focus';
const _empty = <String, Object>{'type': 'FeatureCollection', 'features': <Object>[]};

String _imageId(String condition) => 'community-$condition';

const _storyImage = 'story';

/// Marker image: the condition's icon in white on its colour, ringed white, 28 pt
Future<Uint8List> communityMarkerPng(IconData icon, Color color, double scale) async {
  const size = 28.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(scale);
  const center = Offset(size / 2, size / 2);
  canvas
    ..drawCircle(
      center.translate(0, 1),
      12,
      Paint()
        ..color = const Color(0x55000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5),
    )
    ..drawCircle(center, 12, Paint()..color = Colors.white)
    ..drawCircle(center, 10, Paint()..color = color);
  final text = TextPainter(
    text: TextSpan(
      text: String.fromCharCode(icon.codePoint),
      style: TextStyle(fontSize: 13, fontFamily: icon.fontFamily, package: icon.fontPackage, color: Colors.white),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  text.paint(canvas, center - Offset(text.width / 2, text.height / 2));
  final image = await recorder.endRecording().toImage((size * scale).ceil(), (size * scale).ceil());
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}

/// The posts as points, each with its marker image
Map<String, Object> communityGeoJson(List<CommunityPost> posts) => {
  'type': 'FeatureCollection',
  'features': [
    for (final p in posts)
      {
        'type': 'Feature',
        'properties': {'id': p.id, 'icon': _imageId(mainCondition(p)?.id ?? _storyImage)},
        'geometry': {
          'type': 'Point',
          'coordinates': [p.lng, p.lat],
        },
      },
  ],
};

/// Everyone's last position on the live map: a dot and the name, faded when older than 15 min
Map<String, Object> liveGeoJson(List<LivePosition> positions, DateTime now) => {
  'type': 'FeatureCollection',
  'features': [
    for (final p in positions)
      {
        'type': 'Feature',
        'properties': {
          'id': p.userId,
          'name': p.isMe ? '${p.name} (you)' : p.name,
          'faded': p.fadedAt(now),
          'me': p.isMe,
        },
        'geometry': {
          'type': 'Point',
          'coordinates': [p.lng, p.lat],
        },
      },
  ],
};

/// One person's trail on the live map
Map<String, Object> liveTrailGeoJson(List<TrailPoint> trail) => {
  'type': 'FeatureCollection',
  'features': [
    if (trail.length >= 2)
      {
        'type': 'Feature',
        'properties': <String, Object>{},
        'geometry': {
          'type': 'LineString',
          'coordinates': [
            for (final p in trail) [p.lng, p.lat],
          ],
        },
      },
  ],
};

/// What is shown on the map: the post's point and its attachment's shape (or a workspace item)
Map<String, Object> focusGeoJson(MapFocus? focus) {
  if (focus == null) return _empty;
  final a = focus.attachment;
  final point = focus.point;
  final color = a is AreaAttachment ? a.color : '#e46c24';
  List<List<double>> line(List<(double, double)> pts) => [
    for (final p in pts) [p.$1, p.$2],
  ];
  return {
    'type': 'FeatureCollection',
    'features': [
      if (a is TrackAttachment && a.line.length >= 2)
        {
          'type': 'Feature',
          'properties': {'color': color},
          'geometry': {'type': 'LineString', 'coordinates': line(a.line)},
        },
      if (a is AreaAttachment && a.ring.length >= 4)
        {
          'type': 'Feature',
          'properties': {'color': color},
          'geometry': {
            'type': 'Polygon',
            'coordinates': [line(a.ring)],
          },
        },
      if (a is PlaceAttachment)
        {
          'type': 'Feature',
          'properties': {'color': '#2563eb'},
          'geometry': {
            'type': 'Point',
            'coordinates': [a.point.$1, a.point.$2],
          },
        },
      if (point != null)
        {
          'type': 'Feature',
          'properties': {'color': '#962620', 'post': true},
          'geometry': {
            'type': 'Point',
            'coordinates': [point.$1, point.$2],
          },
        },
    ],
  };
}

class CommunityLayer {
  CommunityLayer(this.map, this.scale);

  final mbx.MapboxMap map;
  final double scale;
  bool _installed = false;

  Future<void> install() async {
    _installed = false;
    final images = <String, (IconData, Color)>{
      for (final c in trailConditions) _imageId(c.id): (conditionIcon(c.id), hexColor(c.color)),
      _imageId(_storyImage): (Icons.auto_stories_outlined, hexColor(storyColor)),
    };
    for (final MapEntry(key: id, value: (icon, color)) in images.entries) {
      if (await map.hasStyleImage(id)) continue;
      await map.addImage(id, scale, mbx.StyleImage.bytes(await communityMarkerPng(icon, color, scale)));
    }
    if (!await map.styleSourceExists(_source)) {
      await map.addStyleSource(
        _source,
        jsonEncode({'type': 'geojson', 'data': _empty, 'cluster': true, 'clusterRadius': 40, 'clusterMaxZoom': 11}),
      );
    }
    for (final id in [_focus, _live, _liveTrail]) {
      if (!await map.styleSourceExists(id)) {
        await map.addStyleSource(id, jsonEncode({'type': 'geojson', 'data': _empty}));
      }
    }
    for (final layer in [
      {
        'id': '$_focus-fill',
        'type': 'fill',
        'source': _focus,
        'filter': [
          '==',
          ['geometry-type'],
          'Polygon',
        ],
        'paint': {
          'fill-color': ['get', 'color'],
          'fill-opacity': 0.18,
        },
      },
      {
        'id': '$_focus-line',
        'type': 'line',
        'source': _focus,
        'filter': [
          '!=',
          ['geometry-type'],
          'Point',
        ],
        'layout': {'line-join': 'round', 'line-cap': 'round'},
        'paint': {
          'line-color': ['get', 'color'],
          'line-width': 4,
        },
      },
      {
        'id': '$_focus-point',
        'type': 'circle',
        'source': _focus,
        'filter': [
          '==',
          ['geometry-type'],
          'Point',
        ],
        'paint': {
          'circle-radius': [
            'case',
            ['has', 'post'],
            14,
            8,
          ],
          'circle-color': ['get', 'color'],
          'circle-opacity': [
            'case',
            ['has', 'post'],
            0.25,
            1,
          ],
          'circle-stroke-color': '#ffffff',
          'circle-stroke-width': [
            'case',
            ['has', 'post'],
            0,
            3,
          ],
        },
      },
      {
        'id': '$_liveTrail-line',
        'type': 'line',
        'source': _liveTrail,
        'layout': {'line-join': 'round', 'line-cap': 'round'},
        'paint': {'line-color': '#2563eb', 'line-width': 3.5, 'line-opacity': 0.85},
      },
      {
        'id': communityLiveLayer,
        'type': 'circle',
        'source': _live,
        'paint': {
          'circle-radius': 8,
          'circle-color': [
            'case',
            ['get', 'me'],
            '#e46c24',
            '#2563eb',
          ],
          'circle-opacity': [
            'case',
            ['get', 'faded'],
            0.4,
            1,
          ],
          'circle-stroke-color': '#ffffff',
          'circle-stroke-width': 2.5,
          'circle-stroke-opacity': [
            'case',
            ['get', 'faded'],
            0.5,
            1,
          ],
        },
      },
      {
        'id': '$_live-names',
        'type': 'symbol',
        'source': _live,
        'layout': {
          'text-field': ['get', 'name'],
          'text-size': 12,
          'text-anchor': 'bottom',
          'text-offset': [0, -1.1],
          'text-allow-overlap': true,
        },
        'paint': {
          'text-color': '#1a2214',
          'text-halo-color': '#ffffff',
          'text-halo-width': 1.5,
          'text-opacity': [
            'case',
            ['get', 'faded'],
            0.5,
            1,
          ],
        },
      },
      {
        'id': communityClustersLayer,
        'type': 'circle',
        'source': _source,
        'filter': ['has', 'point_count'],
        'paint': {
          'circle-color': '#284a1b',
          'circle-radius': [
            'step',
            ['get', 'point_count'],
            15,
            20,
            20,
            100,
            26,
          ],
          'circle-opacity': 0.92,
          'circle-stroke-width': 2,
          'circle-stroke-color': '#ffffff',
        },
      },
      {
        'id': '$_source-count',
        'type': 'symbol',
        'source': _source,
        'filter': ['has', 'point_count'],
        'layout': {
          'text-field': ['get', 'point_count_abbreviated'],
          'text-size': 12,
          'text-allow-overlap': true,
        },
        'paint': {'text-color': '#ffffff'},
      },
      {
        'id': communityPointsLayer,
        'type': 'symbol',
        'source': _source,
        'filter': [
          '!',
          ['has', 'point_count'],
        ],
        'layout': {
          'icon-image': ['get', 'icon'],
          'icon-size': [
            'interpolate',
            ['linear'],
            ['zoom'],
            5,
            0.7,
            14,
            1,
          ],
          'icon-allow-overlap': true,
          'icon-ignore-placement': true,
        },
      },
    ]) {
      final id = layer['id']! as String;
      if (await map.styleLayerExists(id)) await map.removeStyleLayer(id);
      await map.addStyleLayer(jsonEncode(layer), null);
    }
    _installed = true;
  }

  Future<void> show(CommunityLayerState s, MapFocus? focus) => onStyle(() => _show(s, focus));

  /// The live map of an event (null: none)
  Future<void> showLive(LiveViewState? v, DateTime now) => onStyle(() async {
    if (!_installed) return;
    await map.setStyleSourceProperty(_live, 'data', v == null ? _empty : liveGeoJson(v.positions, now));
    await map.setStyleSourceProperty(_liveTrail, 'data', v == null ? _empty : liveTrailGeoJson(v.trail));
  });

  Future<void> _show(CommunityLayerState s, MapFocus? focus) async {
    if (!_installed) return;
    await map.setStyleSourceProperty(_source, 'data', s.shown ? communityGeoJson(s.posts) : _empty);
    await map.setStyleSourceProperty(_focus, 'data', focusGeoJson(focus));
  }
}

/// While picking the post's location: the hint above the sheet
class CommunityPickingBar extends ConsumerWidget {
  const CommunityPickingBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Material(
    key: const Key('community-picking'),
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
              'Tap the map where it is',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            onPressed: ref.read(communityPickProvider.notifier).cancel,
            child: const Text('Cancel'),
          ),
        ],
      ),
    ),
  );
}

/// What is shown on the map: its title, back to the post, and closing it
class CommunityFocusCard extends ConsumerWidget {
  const CommunityFocusCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final focus = ref.watch(communityFocusProvider);
    if (focus == null) return const SizedBox.shrink();
    final post = focus.post;
    final (icon, color) = post == null ? (Icons.folder_shared_outlined, L360Colors.forest700) : postMarker(post);
    return Material(
      key: const Key('community-focus'),
      color: Colors.white,
      elevation: 6,
      shadowColor: const Color(0x40000000),
      borderRadius: BorderRadius.circular(L360.radius),
      child: InkWell(
        borderRadius: BorderRadius.circular(L360.radius),
        onTap: post == null ? null : () => openCommunityPost(context, post.id, initial: post),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                child: Icon(icon, size: 17, color: Colors.white),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      post == null ? focus.title : postHeading(post),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                    ),
                    Text(
                      [
                        if (focus.attachment != null) '${focus.attachment!.label}: ${focus.attachment!.name}',
                        if (post != null) 'Tap to open the post' else 'Club workspace',
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: L360Colors.sand600),
                    ),
                  ],
                ),
              ),
              IconButton(
                key: const Key('community-focus-close'),
                tooltip: 'Close',
                icon: const Icon(Icons.close, size: 20),
                onPressed: ref.read(communityFocusProvider.notifier).clear,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// While sharing: "Sharing your position with (club) until (time)", Stop; tap for the event
class CommunityLiveBanner extends ConsumerWidget {
  const CommunityLiveBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = ref.watch(communityLiveProvider);
    final now = ref.watch(communityClockProvider)();
    final eventId = live.eventId;
    if (eventId == null) {
      final message = live.endedMessage;
      if (message == null) return const SizedBox.shrink();
      return Material(
        key: const Key('community-live-ended'),
        color: L360Colors.ink,
        borderRadius: BorderRadius.circular(L360.radius),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(message, style: const TextStyle(color: Colors.white, fontSize: 13)),
              ),
              IconButton(
                tooltip: 'Close',
                color: Colors.white,
                icon: const Icon(Icons.close, size: 18),
                onPressed: ref.read(communityLiveProvider.notifier).clearMessage,
              ),
            ],
          ),
        ),
      );
    }
    return Material(
      key: const Key('community-live-banner'),
      color: L360Colors.forest800,
      borderRadius: BorderRadius.circular(L360.radius),
      child: InkWell(
        borderRadius: BorderRadius.circular(L360.radius),
        onTap: () => openEvent(context, eventId),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
          child: Row(
            children: [
              const Icon(Icons.share_location, color: Colors.white, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Sharing your position with ${live.clubName}'
                      '${live.endsAt == null ? '' : ' until ${formatUntil(live.endsAt!, now)}'}',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13),
                    ),
                    Text(
                      [
                        live.title,
                        if (live.pending > 0) '${live.pending} waiting for signal',
                        ?live.gpsError,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Color(0xCCFFFFFF), fontSize: 11),
                    ),
                  ],
                ),
              ),
              TextButton(
                key: const Key('community-live-stop'),
                style: TextButton.styleFrom(foregroundColor: Colors.white),
                onPressed: () => ref.read(communityLiveProvider.notifier).stop(),
                child: const Text('Stop'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The live map of an event: who is on it, tap a name for their trail, close
class CommunityLiveMapCard extends ConsumerWidget {
  const CommunityLiveMapCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(communityLiveViewProvider);
    if (v == null) return const SizedBox.shrink();
    final now = ref.watch(communityClockProvider)();
    final view = ref.read(communityLiveViewProvider.notifier);
    return Material(
      key: const Key('community-live-map'),
      color: Colors.white,
      elevation: 6,
      shadowColor: const Color(0x40000000),
      borderRadius: BorderRadius.circular(L360.radius),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.share_location, size: 18, color: L360Colors.forest700),
                const SizedBox(width: 8),
                Expanded(
                  child: InkWell(
                    onTap: () => openEvent(context, v.eventId),
                    child: Text(
                      'Live: ${v.title}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                IconButton(
                  key: const Key('community-live-map-close'),
                  tooltip: 'Close',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: view.close,
                ),
              ],
            ),
            if (v.error != null) Text(v.error!, style: const TextStyle(fontSize: 12, color: L360Colors.brick500)),
            if (v.positions.isEmpty)
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child: Text(
                  'No one has shared a position yet.',
                  style: TextStyle(fontSize: 12, color: L360Colors.sand600),
                ),
              )
            else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final p in v.positions) ...[
                      PillChip(
                        key: Key('live-${p.userId}'),
                        label:
                            '${p.isMe ? 'You' : p.name} · ${timeAgo(p.recordedAt, now)}'
                            '${p.battery == null ? '' : ' · ${p.battery}%'}',
                        on: v.trailUserId == p.userId,
                        leading: Icon(
                          Icons.circle,
                          size: 10,
                          color: p.fadedAt(now) ? L360Colors.sand400 : L360Colors.forest600,
                        ),
                        onTap: () {
                          view.showTrail(p.userId);
                          ref.read(flyToProvider.notifier).go(p.lng, p.lat, zoom: 15);
                        },
                      ),
                      const SizedBox(width: 6),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
