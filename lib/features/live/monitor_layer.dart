import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mbx;

import '../../data/live/monitor_backend.dart' show PhotoFetch, fetchPhotoBytes;
import '../../domain/live/monitor.dart';
import '../map/style_guard.dart';
import 'monitor_state.dart';

// Team Monitor on the map (LiveTrackerLayer.tsx on the web): each member as a round marker in
// their colour with their initials (gray with a red dot when offline, an amber dot when idle,
// green when moving), their trail behind them, and a recalled activity as a blue path with its
// start and end.

const _markers = 'monitor-members';
const _trails = 'monitor-trails';
const _session = 'monitor-session';

/// The layer a tap on a member hits
const monitorMarkersLayer = '$_markers-body';

const _empty = {'type': 'FeatureCollection', 'features': <Object>[]};

/// A photo as a round marker with a white rim, the size of the member's circle
Future<Uint8List> photoMarkerPng(Uint8List photo, double scale, {double size = 34}) async {
  final codec = await ui.instantiateImageCodec(
    photo,
    targetWidth: (size * scale).ceil(),
    targetHeight: (size * scale).ceil(),
  );
  final frame = await codec.getNextFrame();
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder)..scale(scale);
  final center = Offset(size / 2, size / 2);
  canvas
    ..drawCircle(center, size / 2, ui.Paint()..color = const Color(0xFFFFFFFF))
    ..save()
    ..clipPath(ui.Path()..addOval(Rect.fromCircle(center: center, radius: size / 2 - 2.5)));
  paintImage(
    canvas: canvas,
    rect: Rect.fromCircle(center: center, radius: size / 2 - 2.5),
    image: frame.image,
    fit: BoxFit.cover,
  );
  canvas.restore();
  frame.image.dispose();
  final image = await recorder.endRecording().toImage((size * scale).ceil(), (size * scale).ceil());
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}

class MonitorLayer {
  MonitorLayer(this.map, {this.scale = 2, this.avatarUrl, PhotoFetch? fetch}) : _fetch = fetch ?? fetchPhotoBytes;

  final mbx.MapboxMap map;
  final double scale;

  /// The public address of a photo path (null: photos are not shown)
  final String Function(String path)? avatarUrl;
  final PhotoFetch _fetch;
  bool _installed = false;
  final _photos = <String>{}; // tracker ids whose photo is on the map
  final _loading = <String>{};
  MonitorState? _last;
  int _lastNow = 0;
  Timer? _redraw;
  int _drawnAt = 0;

  /// Positions arrive every 3 s from every member: the sources are rewritten at most this
  /// often (the newest state is what gets drawn), so the map is not re-encoded per packet
  static const redrawEvery = Duration(milliseconds: 400);

  /// For tests: the clock the throttle uses
  int Function() clock = () => DateTime.now().millisecondsSinceEpoch;

  Future<void> install() async {
    _installed = false;
    for (final id in [_markers, _trails, _session]) {
      if (!await map.styleSourceExists(id)) {
        await map.addStyleSource(id, jsonEncode({'type': 'geojson', 'data': _empty}));
      }
    }
    for (final layer in [
      {
        'id': '$_session-line',
        'type': 'line',
        'source': _session,
        'filter': [
          '==',
          ['get', 'kind'],
          'path',
        ],
        'layout': {'line-join': 'round', 'line-cap': 'round'},
        'paint': {'line-color': '#3b82f6', 'line-width': 4, 'line-opacity': 0.8},
      },
      {
        'id': '$_session-ends',
        'type': 'circle',
        'source': _session,
        'filter': [
          '!=',
          ['get', 'kind'],
          'path',
        ],
        'paint': {
          'circle-radius': 6,
          'circle-color': [
            'case',
            [
              '==',
              ['get', 'kind'],
              'start',
            ],
            '#22c55e',
            '#ef4444',
          ],
          'circle-stroke-width': 2,
          'circle-stroke-color': '#ffffff',
        },
      },
      {
        'id': '$_trails-line',
        'type': 'line',
        'source': _trails,
        'layout': {'line-join': 'round', 'line-cap': 'round'},
        'paint': {
          'line-color': ['get', 'color'],
          'line-width': ['get', 'width'],
          'line-opacity': ['get', 'opacity'],
          'line-dasharray': [2, 1],
        },
      },
      // A soft ring around a moving member (the web's pulse), a wider one around the selected
      {
        'id': '$_markers-ring',
        'type': 'circle',
        'source': _markers,
        'paint': {
          'circle-radius': [
            'case',
            ['get', 'selected'],
            26,
            22,
          ],
          'circle-color': ['get', 'color'],
          'circle-opacity': [
            'case',
            ['get', 'selected'],
            0.35,
            [
              '==',
              ['get', 'status'],
              'online',
            ],
            0.25,
            0,
          ],
        },
      },
      // A dark halo under the body: a light colour still stands out on green terrain
      {
        'id': '$_markers-halo',
        'type': 'circle',
        'source': _markers,
        'paint': {'circle-radius': 18.5, 'circle-color': '#1a2214', 'circle-opacity': 0.45},
      },
      // Idle: a dashed amber ring (drawn as a thin amber circle)
      {
        'id': '$_markers-idle',
        'type': 'circle',
        'source': _markers,
        'filter': [
          '==',
          ['get', 'status'],
          'idle',
        ],
        'paint': {
          'circle-radius': 19,
          'circle-color': '#ffffff',
          'circle-opacity': 0,
          'circle-stroke-color': '#f59e0b',
          'circle-stroke-width': 2,
          'circle-stroke-opacity': 0.8,
        },
      },
      {
        'id': monitorMarkersLayer,
        'type': 'circle',
        'source': _markers,
        'paint': {
          'circle-radius': 16,
          'circle-color': ['get', 'color'],
          'circle-stroke-color': [
            'case',
            [
              '==',
              ['get', 'status'],
              'offline',
            ],
            '#d6d3d1',
            '#ffffff',
          ],
          'circle-stroke-width': 3,
        },
      },
      // The member's photo, when they set one (over the body, under the status dot)
      {
        'id': '$_markers-photo',
        'type': 'symbol',
        'source': _markers,
        'filter': ['get', 'photo'],
        'layout': {
          'icon-image': [
            'concat',
            'monitor-photo-',
            ['get', 'id'],
          ],
          'icon-size': 1,
          'icon-allow-overlap': true,
          'icon-ignore-placement': true,
        },
        'paint': {},
      },
      {
        'id': '$_markers-initials',
        'type': 'symbol',
        'source': _markers,
        'filter': [
          '!',
          ['get', 'photo'],
        ],
        'layout': {
          'text-field': ['get', 'initials'],
          'text-size': 12,
          'text-allow-overlap': true,
          'text-ignore-placement': true,
        },
        'paint': {'text-color': '#ffffff', 'text-halo-color': 'rgba(0,0,0,0.25)', 'text-halo-width': 0.8},
      },
      // The status dot at the bottom right: green moving, amber idle, red offline
      {
        'id': '$_markers-dot',
        'type': 'circle',
        'source': _markers,
        'paint': {
          'circle-radius': 5,
          'circle-translate': [11, 11],
          'circle-color': [
            'match',
            ['get', 'status'],
            'online',
            '#22c55e',
            'idle',
            '#f59e0b',
            '#ef4444',
          ],
          'circle-stroke-color': '#ffffff',
          'circle-stroke-width': 2,
        },
      },
      {
        'id': '$_markers-name',
        'type': 'symbol',
        'source': _markers,
        'filter': ['get', 'selected'],
        'layout': {
          'text-field': ['get', 'id'],
          'text-size': 12,
          'text-anchor': 'bottom',
          'text-offset': [0, -2.2],
          'text-allow-overlap': true,
        },
        'paint': {'text-color': '#1a2214', 'text-halo-color': '#ffffff', 'text-halo-width': 1.5},
      },
    ]) {
      final id = layer['id']! as String;
      // The style's 3D light must not dim the markers: they glow on their own
      final type = layer['type']! as String;
      final paint = Map<String, Object?>.from(layer['paint']! as Map);
      paint['${type == 'symbol' ? 'text' : type}-emissive-strength'] = 1;
      // Drawn on the terrain, not floating above it: a hill in front would hide a floating circle
      if (type == 'circle') paint['circle-pitch-alignment'] = 'map';
      if (paint.containsKey('circle-translate')) paint['circle-translate-anchor'] = 'map';
      if (await map.styleLayerExists(id)) await map.removeStyleLayer(id);
      await map.addStyleLayer(jsonEncode({...layer, 'paint': paint}), null);
    }
    _installed = true;
  }

  /// Draws the state, at once when the last drawing is older than [redrawEvery], else soon
  /// after it (coalescing everything heard meanwhile)
  Future<void> show(MonitorState s, int nowMs) {
    _last = s;
    _lastNow = nowMs;
    final since = clock() - _drawnAt;
    if (since >= redrawEvery.inMilliseconds && _redraw == null) return _draw();
    _redraw ??= Timer(redrawEvery - Duration(milliseconds: since.clamp(0, redrawEvery.inMilliseconds)), () {
      _redraw = null;
      unawaited(_draw());
    });
    return Future.value();
  }

  /// How many times the sources were rewritten (tests)
  int draws = 0;

  Future<void> _draw() {
    _drawnAt = clock();
    draws++;
    final s = _last;
    return s == null ? Future.value() : onStyle(() => _show(s, _lastNow));
  }

  void dispose() {
    _redraw?.cancel();
    _redraw = null;
  }

  Future<void> _show(MonitorState s, int nowMs) async {
    if (!_installed) return;
    _last = s;
    _lastNow = nowMs;
    final members = s.on ? s.trackers.values : const <MonitorTracker>[];
    unawaited(_loadPhotos(members, s));
    await map.setStyleSourceProperty(
      _markers,
      'data',
      monitorGeoJson(members, nowMs, s.selectedId, profiles: s.profiles, photos: _photos),
    );
    await map.setStyleSourceProperty(_trails, 'data', monitorTrailsGeoJson(members, s.selectedId));
    final session = s.session;
    await map.setStyleSourceProperty(
      _session,
      'data',
      session == null || !s.sessionVisible ? _empty : sessionGeoJson(session),
    );
  }

  /// Fetches the photos of members whose account has one, once each; the markers are drawn
  /// again as each arrives
  Future<void> _loadPhotos(Iterable<MonitorTracker> members, MonitorState s) async {
    final toUrl = avatarUrl;
    if (toUrl == null) return;
    for (final t in members) {
      final path = s.profileOf(t.id)?.avatarPath;
      if (path == null || _photos.contains(t.id) || !_loading.add(t.id)) continue;
      unawaited(
        _fetch(toUrl(path))
            .then((bytes) async {
              if (bytes == null) return;
              try {
                await map.addImage(
                  'monitor-photo-${t.id}',
                  scale,
                  mbx.StyleImage.bytes(await photoMarkerPng(bytes, scale)),
                );
                _photos.add(t.id);
                final last = _last;
                if (last != null) await show(last, _lastNow);
              } on Object {
                // Without the photo the initials stay
              }
            })
            .whenComplete(() => _loading.remove(t.id)),
      );
    }
  }
}
