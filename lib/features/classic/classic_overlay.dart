import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide Size;

import '../../domain/classic/classic_drawing.dart';
import '../../domain/classic/classic_nav.dart';
import '../../domain/classic/field_work.dart';
import '../../domain/geo/spherical.dart';
import 'classic_layer.dart';
import 'classic_panel.dart' show classicBodyHeight;
import 'classic_state.dart';

// Classic's map drawing while its panel is open: the style layers (ClassicLayer), plus in
// Flutter the pulsing circle where the object most likely is and a dot at the end of every
// line, dragged along the line to make it longer or shorter. The map follows the points
// a moment after the last change, beside the panel.

class ClassicOverlay extends ConsumerStatefulWidget {
  const ClassicOverlay({
    super.key,
    required this.map,
    required this.cameraTick,
    required this.styleTick,
    required this.bottomInset,
  });

  final MapboxMap map;
  final Listenable cameraTick;
  final Listenable styleTick;

  /// Height of the map sheet at the bottom (the panel sits above it)
  final double bottomInset;

  @override
  ConsumerState<ClassicOverlay> createState() => _ClassicOverlayState();
}

class _ClassicOverlayState extends ConsumerState<ClassicOverlay> {
  late final ClassicLayer _layer = ClassicLayer(
    widget.map,
    WidgetsBinding.instance.platformDispatcher.implicitView!.devicePixelRatio,
  );
  final _ends = <String, Offset>{};
  Offset? _x;
  double _xRadius = 0;
  bool _projecting = false;
  bool _again = false;
  Timer? _fit;
  String? _fitKey;

  ClassicDrawing? _drawing;

  @override
  void initState() {
    super.initState();
    widget.cameraTick.addListener(_reproject);
    widget.styleTick.addListener(_reinstall);
    unawaited(_install());
  }

  @override
  void dispose() {
    widget.cameraTick.removeListener(_reproject);
    widget.styleTick.removeListener(_reinstall);
    _fit?.cancel();
    unawaited(_layer.show(null, ClassicMode.resection, null));
    super.dispose();
  }

  void _reinstall() => unawaited(_install());

  Future<void> _install() async {
    try {
      await _layer.install();
      _redraw(ref.read(classicProvider));
    } on Object {
      // Style still loading: the style tick tries again
    }
  }

  void _redraw(ClassicState s) {
    final sol = s.solution;
    final mode = s.viewing?.mode ?? s.mode;
    final lengths = s.viewing?.data.lineLengths ?? s.data.lineLengths;
    final drawing = s.panelOpen ? ClassicDrawing.of(sol, mode, lengths) : null;
    _drawing = drawing;
    unawaited(_layer.show(s.panelOpen ? sol : null, mode, drawing));
    _reproject();
    if (s.panelOpen) _scheduleFit(s, drawing!);
  }

  // --- Following the points

  void _scheduleFit(ClassicState s, ClassicDrawing d) {
    final sol = s.solution;
    final resection = (s.viewing?.mode ?? s.mode) == ClassicMode.resection;
    final all = <LngLat>[
      for (final x in sol.sightings)
        if (x.point != null) x.point!,
      ?d.crossing?.point,
      if (resection)
        for (final l in d.lines) l.end,
    ];
    // Only when a point or the crossing moves (resection: also a new line), or the panel
    // is lowered or raised
    final key = [
      for (final p in all) '${p.$1.toStringAsFixed(5)},${p.$2.toStringAsFixed(5)}',
      if (resection) '${d.lines.length}',
      '${s.minimized}',
    ].join('|');
    if (key == _fitKey || all.isEmpty) return;
    _fitKey = key;
    _fit?.cancel();
    // Waits a moment, so typing a coordinate digit by digit does not throw the map around
    _fit = Timer(const Duration(milliseconds: 900), () => unawaited(_fitTo(all, s.minimized)));
  }

  Future<void> _fitTo(List<LngLat> all, bool minimized) async {
    if (!mounted) return;
    final height = MediaQuery.sizeOf(context).height;
    // The panel's header and body above the map sheet
    final bottom = widget.bottomInset + (minimized ? 90 : classicBodyHeight(height) + 120);
    try {
      final camera = await widget.map.cameraForCoordinates(
        [for (final (lng, lat) in all) Point(coordinates: Position(lng, lat))],
        MbxEdgeInsets(top: 110, left: 60, bottom: math.min(bottom, height - 220), right: 80),
        null,
        null,
      );
      final maxZoom = all.length > 1 ? 16.0 : 14.0;
      if ((camera.zoom ?? 0) > maxZoom) camera.zoom = maxZoom;
      await widget.map.flyTo(camera, MapAnimationOptions(duration: 900));
    } on Object {
      // The map was busy: the next change fits again
    }
  }

  // --- Screen positions of the line ends and X

  void _reproject() {
    final d = _drawing;
    if (d == null) {
      if (_ends.isNotEmpty || _x != null) {
        setState(() {
          _ends.clear();
          _x = null;
        });
      }
      return;
    }
    if (_projecting) {
      _again = true;
      return;
    }
    _projecting = true;
    final fix = d.crossing;
    final radiusEdge = fix == null ? null : turfDestination(fix.point, fixRadius(fix), 90);
    final coords = [
      for (final l in d.lines) Point(coordinates: Position(l.end.$1, l.end.$2)),
      if (fix != null) ...[
        Point(coordinates: Position(fix.point.$1, fix.point.$2)),
        Point(coordinates: Position(radiusEdge!.$1, radiusEdge.$2)),
      ],
    ];
    widget.map
        .pixelsForCoordinates(coords)
        .then((px) {
          if (!mounted || px.length != coords.length) return;
          setState(() {
            _ends
              ..clear()
              ..addAll({for (final (i, l) in d.lines.indexed) l.key: Offset(px[i].x, px[i].y)});
            if (fix != null) {
              final c = Offset(px[d.lines.length].x, px[d.lines.length].y);
              final e = Offset(px[d.lines.length + 1].x, px[d.lines.length + 1].y);
              _x = c;
              _xRadius = (e - c).distance;
            } else {
              _x = null;
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

  // --- Dragging a line end

  Future<void> _dragEnd(CompassLine l, Offset local) async {
    try {
      final p = await widget.map.coordinateForPixel(ScreenCoordinate(x: local.dx, y: local.dy));
      if (!mounted) return;
      final to = (p.coordinates.lng.toDouble(), p.coordinates.lat.toDouble());
      ref.read(classicProvider.notifier).setLineLength(l.key, draggedLength(l, to));
    } on Object {
      // Off the map: keep the last length
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<ClassicState>(classicProvider, (_, next) => _redraw(next));
    final s = ref.watch(classicProvider);
    final d = _drawing;
    if (!s.panelOpen || d == null) return const SizedBox.shrink();
    final readOnly = s.viewing != null;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        // Where the object most likely is: a circle around X with a ring pulsing outward
        if (_x != null)
          Positioned(
            left: _x!.dx - math.max(12, _xRadius),
            top: _x!.dy - math.max(12, _xRadius),
            child: IgnorePointer(child: _Estimate(radius: math.max(12, math.min(_xRadius, 1500)))),
          ),
        if (!readOnly)
          for (final l in d.lines)
            if (_ends[l.key] case final at?)
              Positioned(
                left: at.dx - 22,
                top: at.dy - 22,
                child: GestureDetector(
                  key: Key('classic-end-${l.key}'),
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (_) => HapticFeedback.selectionClick(),
                  onPanUpdate: (u) {
                    final box = context.findRenderObject() as RenderBox?;
                    if (box == null) return;
                    unawaited(_dragEnd(l, box.globalToLocal(u.globalPosition)));
                  },
                  child: SizedBox.square(
                    dimension: 44,
                    child: Center(
                      child: Container(
                        width: 16,
                        height: 16,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: l.back ? const Color(0xFFD49B22) : const Color(0xFF962620),
                            width: 3,
                          ),
                          boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 4)],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
      ],
    );
  }
}

class _Estimate extends StatefulWidget {
  const _Estimate({required this.radius});
  final double radius;

  @override
  State<_Estimate> createState() => _EstimateState();
}

class _EstimateState extends State<_Estimate> with SingleTickerProviderStateMixin {
  late final _ping = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..repeat();

  @override
  void dispose() {
    _ping.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.radius * 2;
    return SizedBox.square(
      dimension: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(size: Size.square(size), painter: _DashedCircle()),
          AnimatedBuilder(
            animation: _ping,
            builder: (_, _) => Opacity(
              opacity: 1 - _ping.value,
              child: Transform.scale(
                scale: 1 + _ping.value * 0.6,
                child: Container(
                  width: size,
                  height: size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0xFFB4302A), width: 2),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DashedCircle extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    final c = Offset(r, r);
    canvas.drawCircle(c, r, Paint()..color = const Color(0x26B4302A));
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = const Color(0xCCB4302A);
    final dashes = math.max(12, (2 * math.pi * r / 10).floor());
    for (var i = 0; i < dashes; i += 2) {
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: r),
        2 * math.pi * i / dashes,
        2 * math.pi / dashes,
        false,
        stroke,
      );
    }
  }

  @override
  bool shouldRepaint(_DashedCircle old) => false;
}
