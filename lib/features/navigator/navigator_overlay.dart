import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide Size;

import '../../core/theme/app_theme.dart';
import '../../domain/survey/survey_model.dart';
import '../../domain/survey/survey_utils.dart';
import 'navigator_layer.dart';
import 'navigator_state.dart';

// Survey points and labels over the map, with the web's pen-tool gestures (PlottingLayer):
// drag a point to move it; press and hold (350 ms), then drag, to pull out a Bezier handle
// and bend the line; tap a point to select it and show its handles. Distance labels sit in
// the middle of every segment; tapping one shows its azimuth, slope and running total.

const _longPress = Duration(milliseconds: 350);

Color _hex(String hex) => Color(int.parse('FF${hex.replaceFirst('#', '')}', radix: 16));

class NavigatorOverlay extends ConsumerStatefulWidget {
  const NavigatorOverlay({
    super.key,
    required this.map,
    required this.cameraTick,
    required this.styleTick,
    required this.elevationAt,
  });

  final MapboxMap map;

  /// Changes whenever the camera moves, so the overlay follows the map
  final Listenable cameraTick;

  /// Changes after the map style (re)loads: the survey layers are added again
  final Listenable styleTick;

  /// Terrain height (m) at a spot, without the 3D exaggeration
  final Future<double> Function(double lng, double lat) elevationAt;

  @override
  ConsumerState<NavigatorOverlay> createState() => _NavigatorOverlayState();
}

class _NavigatorOverlayState extends ConsumerState<NavigatorOverlay> {
  late final NavigatorLayer _layer = NavigatorLayer(widget.map);
  final _screen = <String, Offset>{};
  bool _projecting = false;
  bool _again = false;

  // Edit being dragged, drawn live and saved when the finger lifts
  SurveyDoc? _draft;
  String? _openLabel; // segment label showing its details

  @override
  void initState() {
    super.initState();
    widget.cameraTick.addListener(_reproject);
    widget.styleTick.addListener(reinstall);
    unawaited(_install());
  }

  @override
  void dispose() {
    widget.cameraTick.removeListener(_reproject);
    widget.styleTick.removeListener(reinstall);
    super.dispose();
  }

  /// Called again after every style change (the map drops custom layers then)
  Future<void> _install() async {
    try {
      await _layer.install();
      await _redraw();
    } on Object {
      // Style still loading: the next camera change tries again
    }
  }

  void reinstall() => unawaited(_install());

  SurveyDoc get _doc => _draft ?? ref.read(navigatorProvider).doc;

  Future<void> _redraw() async {
    final s = ref.read(navigatorProvider);
    await _layer.show(_doc, s.enabled ? s.selectedPointId : null);
    _reproject();
  }

  /// Screen positions of every point, handle end and segment middle (one batch call)
  void _reproject() {
    if (_projecting) {
      _again = true;
      return;
    }
    _projecting = true;
    final doc = _doc;
    final keys = <String>[];
    final coords = <Point>[];
    void add(String key, double lng, double lat) {
      keys.add(key);
      coords.add(Point(coordinates: Position(lng, lat)));
    }

    final selected = ref.read(navigatorProvider).selectedPointId;
    for (final g in doc.groups) {
      for (final p in g.points) {
        add('p:${p.id}', p.lng, p.lat);
        if (p.id == selected && p.handle != null) {
          final ends = handleEnds((lng: p.lng, lat: p.lat), p.handle!);
          add('h:out', ends.out.$1, ends.out.$2);
          add('h:in', ends.inEnd.$1, ends.inEnd.$2);
        }
      }
      final mids = segmentMidpoints([for (final p in g.points) p.line]);
      for (var i = 0; i < mids.length; i++) {
        add('m:${g.id}:$i', mids[i].$1, mids[i].$2);
      }
    }
    widget.map
        .pixelsForCoordinates(coords)
        .then((pixels) {
          if (!mounted) return;
          setState(() {
            _screen.clear();
            for (var i = 0; i < keys.length && i < pixels.length; i++) {
              _screen[keys[i]] = Offset(pixels[i].x, pixels[i].y);
            }
          });
        })
        .catchError((Object _) {})
        .whenComplete(() {
          _projecting = false;
          if (_again) {
            _again = false;
            _reproject();
          }
        });
  }

  Future<(double, double)?> _toMap(Offset local) async {
    try {
      final p = await widget.map.coordinateForPixel(ScreenCoordinate(x: local.dx, y: local.dy));
      return (p.coordinates.lng.toDouble(), p.coordinates.lat.toDouble());
    } on Object {
      return null;
    }
  }

  void _setDraft(SurveyDoc? doc) {
    _draft = doc;
    unawaited(_redraw());
  }

  // --- Point gestures -------------------------------------------------------------------
  // Finger positions are turned into map coordinates asynchronously. A gesture keeps the
  // last conversion in flight, waits for it when the finger lifts, and ignores answers that
  // arrive after it ended, so the drawing never sticks at a stale position.

  bool _gesturing = false;
  Future<void> _pending = Future.value();

  void _track(Future<void> Function() update) {
    _gesturing = true;
    _pending = _pending.then((_) => update()).catchError((Object _) {});
  }

  /// Ends the gesture; returns the draft it produced (null when nothing moved)
  Future<SurveyDoc?> _finish() async {
    await _pending;
    _gesturing = false;
    final draft = _draft;
    _draft = null;
    unawaited(_redraw());
    return draft;
  }

  void _move(SurveyGroup g, SurveyPoint p, Offset local) => _track(() async {
    final c = await _toMap(local);
    if (c == null || !mounted || !_gesturing) return;
    _setDraft(ref.read(navigatorProvider).doc.movePoint(g.id, p.id, lng: c.$1, lat: c.$2));
  });

  Future<void> _moveEnd(SurveyGroup g, SurveyPoint p) async {
    final draft = await _finish();
    final moved = _pointIn(draft, g.id, p.id);
    if (moved == null) return;
    final elevation = await widget.elevationAt(moved.lng, moved.lat);
    ref.read(navigatorProvider.notifier).movePoint(g.id, p.id, lat: moved.lat, lng: moved.lng, elevation: elevation);
  }

  void _curve(SurveyGroup g, SurveyPoint p, Offset local, {bool opposite = false}) => _track(() async {
    final c = await _toMap(local);
    if (c == null || !mounted || !_gesturing) return;
    final h = handleFromDrag((lng: p.lng, lat: p.lat), c);
    // The two handles stay opposite each other, like a smooth pen-tool point
    final handle = opposite ? SurveyHandle(east: -h.east, north: -h.north) : h;
    _setDraft(ref.read(navigatorProvider).doc.setHandle(g.id, p.id, handle));
  });

  Future<void> _curveEnd(SurveyGroup g, SurveyPoint p) async {
    final draft = await _finish();
    // Held without dragging: the curve stays as it was (like the web)
    if (draft == null) return;
    ref.read(navigatorProvider.notifier).setHandle(g.id, p.id, _pointIn(draft, g.id, p.id)?.handle);
  }

  static SurveyPoint? _pointIn(SurveyDoc? doc, String groupId, String pointId) {
    for (final g in doc?.groups ?? const <SurveyGroup>[]) {
      if (g.id != groupId) continue;
      for (final p in g.points) {
        if (p.id == pointId) return p;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(navigatorProvider);
    ref.listen(navigatorProvider, (prev, next) {
      if (prev?.doc != next.doc || prev?.selectedPointId != next.selectedPointId || prev?.enabled != next.enabled) {
        unawaited(_redraw());
      }
    });
    final doc = _doc;
    if (doc.groups.isEmpty) return const SizedBox.shrink();
    final active = doc.activeGroup?.id;
    final children = <Widget>[];

    // Segment labels
    for (final g in doc.groups) {
      var total = 0.0;
      for (var i = 0; i + 1 < g.points.length; i++) {
        final pos = _screen['m:${g.id}:$i'];
        final data = getAzimuthData(g.points[i].geo, g.points[i + 1].geo);
        total += data.horizontalDistance;
        if (pos == null || (!s.enabled && g.id != active)) continue;
        final key = '${g.id}:$i';
        final open = _openLabel == key;
        children.add(
          _At(
            pos,
            child: GestureDetector(
              onTap: () => setState(() => _openLabel = open ? null : key),
              child: _SegmentLabel(
                distance: formatDistance(data.horizontalDistance),
                detail: open ? '${formatDegrees(data.forwardAzimuth)} • ${data.slope.toStringAsFixed(1)}%' : null,
                total: open ? 'Total: ${formatDistance(total)}' : null,
              ),
            ),
          ),
        );
      }
    }

    // Points (active sheet on top)
    final ordered = [...doc.groups.where((g) => g.id != active), ...doc.groups.where((g) => g.id == active)];
    for (final g in ordered) {
      for (var i = 0; i < g.points.length; i++) {
        final p = g.points[i];
        final pos = _screen['p:${p.id}'];
        if (pos == null) continue;
        final isActive = g.id == active;
        final selected = s.selectedPointId == p.id && s.enabled;
        final dot = _PointDot(
          color: p.name != null ? L360Colors.ember500 : _hex(g.color),
          named: p.name != null,
          // Named points: an orange circle (the logo colour), a little bigger than the others
          size: (isActive ? 14 : 10) + (p.name != null ? 4 : 0),
          selected: selected,
          label: isActive || selected ? (p.name ?? 'Point ${i + 1}') : null,
          detail: selected ? '${p.elevation.toStringAsFixed(1)} mdpl' : null,
        );
        // The drawing (label + dot) never takes touches; only a 44 pt target on the dot does,
        // so the map still pans right next to a point
        children.add(_At(pos, child: IgnorePointer(child: dot)));
        if (s.enabled) {
          children.add(
            _At(
              pos,
              child: _PointGestures(
                key: ValueKey('nav-point-${p.id}'),
                onTap: () {
                  HapticFeedback.selectionClick();
                  final nav = ref.read(navigatorProvider.notifier);
                  if (g.id != active) nav.setActiveGroup(g.id);
                  nav.select(selected ? null : p.id);
                },
                onMove: (local) => _move(g, p, local),
                onMoveEnd: () => _moveEnd(g, p),
                onCurveStart: () {
                  HapticFeedback.mediumImpact();
                  ref.read(navigatorProvider.notifier).select(p.id);
                },
                onCurve: (local) => _curve(g, p, local),
                onCurveEnd: () => _curveEnd(g, p),
                toLocal: _localOf,
                child: const SizedBox.square(dimension: 44),
              ),
            ),
          );
        }
      }
    }

    // Handle knobs of the selected point
    if (s.enabled) {
      for (final g in doc.groups) {
        for (final p in g.points) {
          if (p.id != s.selectedPointId || p.handle == null) continue;
          for (final side in ['out', 'in']) {
            final pos = _screen['h:$side'];
            if (pos == null) continue;
            children.add(
              _At(
                pos,
                child: GestureDetector(
                  key: ValueKey('nav-handle-$side'),
                  behavior: HitTestBehavior.opaque,
                  onPanUpdate: (d) => _curve(g, p, _localOf(d.globalPosition), opposite: side == 'in'),
                  onPanEnd: (_) => _curveEnd(g, p),
                  child: SizedBox.square(
                    dimension: 40,
                    child: Center(
                      child: Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          border: Border.all(color: _hex(g.color), width: 2.5),
                          boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 3)],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          }
        }
      }
    }

    return Stack(clipBehavior: Clip.none, children: children);
  }

  Offset _localOf(Offset global) {
    final box = context.findRenderObject() as RenderBox?;
    return box == null ? global : box.globalToLocal(global);
  }
}

/// Centres its child on a screen position
class _At extends StatelessWidget {
  const _At(this.pos, {required this.child});

  final Offset pos;
  final Widget child;

  @override
  Widget build(BuildContext context) => Positioned(
    left: pos.dx,
    top: pos.dy,
    child: FractionalTranslation(translation: const Offset(-0.5, -0.5), child: child),
  );
}

/// Tap / drag / press-and-hold-then-drag on a point, reported in overlay coordinates
class _PointGestures extends StatelessWidget {
  const _PointGestures({
    super.key,
    required this.onTap,
    required this.onMove,
    required this.onMoveEnd,
    required this.onCurveStart,
    required this.onCurve,
    required this.onCurveEnd,
    required this.toLocal,
    required this.child,
  });

  /// Global screen position to overlay (map) coordinates
  final Offset Function(Offset global) toLocal;
  final VoidCallback onTap;
  final ValueChanged<Offset> onMove;
  final VoidCallback onMoveEnd;
  final VoidCallback onCurveStart;
  final ValueChanged<Offset> onCurve;
  final VoidCallback onCurveEnd;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final local = toLocal;
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: {
        TapGestureRecognizer: GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
          TapGestureRecognizer.new,
          (r) => r.onTap = onTap,
        ),
        // Moving before the long press: move the point
        PanGestureRecognizer: GestureRecognizerFactoryWithHandlers<PanGestureRecognizer>(
          PanGestureRecognizer.new,
          (r) => r
            ..onUpdate = ((d) => onMove(local(d.globalPosition)))
            ..onEnd = ((_) => onMoveEnd()),
        ),
        // Held still 350 ms: drag to bend the line
        LongPressGestureRecognizer: GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
          () => LongPressGestureRecognizer(duration: _longPress),
          (r) => r
            ..onLongPressStart = ((_) => onCurveStart())
            ..onLongPressMoveUpdate = ((d) => onCurve(local(d.globalPosition)))
            ..onLongPressEnd = ((_) => onCurveEnd()),
        ),
      },
      child: child,
    );
  }
}

class _PointDot extends StatelessWidget {
  const _PointDot({
    required this.color,
    required this.named,
    required this.size,
    required this.selected,
    this.label,
    this.detail,
  });

  final Color color;
  final bool named;
  final double size;
  final bool selected;
  final String? label;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final s = selected ? size * 1.25 : size;
    final shape = Container(
      width: s,
      height: s,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.black, width: 1.5),
        boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 2)],
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The label sits above the dot; an empty box of the same height keeps the dot centred
        SizedBox(
          height: 34,
          child: label == null
              ? null
              : Align(
                  alignment: Alignment.bottomCenter,
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 3),
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.95),
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(color: named ? L360Colors.ember500 : L360Colors.gold100),
                      boxShadow: const [BoxShadow(color: Color(0x26000000), blurRadius: 3)],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(label!, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, height: 1.2)),
                        if (detail != null)
                          Text(detail!, style: const TextStyle(fontSize: 9, color: L360Colors.gold700, height: 1.2)),
                      ],
                    ),
                  ),
                ),
        ),
        shape,
        const SizedBox(height: 34),
      ],
    );
  }
}

class _SegmentLabel extends StatelessWidget {
  const _SegmentLabel({required this.distance, this.detail, this.total});

  final String distance;
  final String? detail;
  final String? total;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.symmetric(horizontal: detail == null ? 5 : 8, vertical: detail == null ? 1 : 4),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.88),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: L360Colors.sand200),
      boxShadow: const [BoxShadow(color: Color(0x1F000000), blurRadius: 2)],
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          distance,
          style: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        if (detail != null) Text(detail!, style: const TextStyle(fontSize: 9, color: L360Colors.sand600)),
        // Running total in the logo orange: a yellow sheet colour was hard to read on white
        if (total != null)
          Text(
            total!,
            style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: L360Colors.ember600),
          ),
      ],
    ),
  );
}
