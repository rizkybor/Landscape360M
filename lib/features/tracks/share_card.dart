import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mbx;

import '../../core/theme/app_theme.dart';
import '../../domain/geo/spherical.dart';
import '../../domain/map/map_settings.dart' show MapStyle;
import '../../domain/tracks/share_card.dart';

// The four share cards of a track (domain/tracks/share_card.dart), drawn at 360 × 640 and
// saved 3× (1080 × 1920): Map (the route on the Outdoors map), Sticker (transparent, to lay on
// your own photo in an Instagram story), Photo (your photo with the route) and Elevation (the
// profile). The route, profile and numbers are drawn by the app, so three of them work with no
// signal; the map comes from a Mapbox snapshot, and without one the Map card has a plain
// background instead. The map has no labels, so they never collide with the card's text.

const _route = L360Colors.ember500;
const _start = Color(0xFF2F9E44);
const _shadow = [Shadow(color: Color(0x99000000), blurRadius: 6)];

String _thousands(int n) => n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

/// A map picture of the route: the PNG, and the camera it was taken with (to draw the route on it)
class MapShot {
  const MapShot(this.png, {required this.center, required this.zoom});

  final Uint8List png;
  final LngLat center;
  final double zoom;
}

/// Takes the Outdoors map around [line] for a card of [size]; null when it cannot (no signal and
/// no offline map there, or a test)
final trackMapShotProvider = Provider<Future<MapShot?> Function(List<LngLat> line, Size size)>(
  (ref) => (line, size) async {
    if (line.length < 2) return null;
    mbx.Snapshotter? snap;
    try {
      final loaded = Completer<void>();
      snap = await mbx.Snapshotter.create(
        options: mbx.MapSnapshotOptions(
          size: mbx.Size(width: size.width, height: size.height),
          pixelRatio: shareCardPixelRatio,
        ),
        onStyleLoadedListener: (_) {
          if (!loaded.isCompleted) loaded.complete();
        },
      );
      await snap.setStyleURI(MapStyle.outdoors.uri);
      await loaded.future.timeout(const Duration(seconds: 12));
      // No map text or icons: the card has its own title and numbers, and labels would collide
      for (final l in await snap.getStyleLayers()) {
        if (l?.type == 'symbol') await snap.setStyleLayerProperty(l!.id, 'visibility', 'none');
      }
      final camera = await snap.camera(
        coordinates: [for (final p in line) mbx.Point(coordinates: mbx.Position(p.$1, p.$2))],
        // Room for the title above and the numbers below
        padding: mbx.MbxEdgeInsets(top: 150, left: 40, bottom: 240, right: 40),
        bearing: 0,
        pitch: 0,
      );
      camera.zoom = math.min(camera.zoom ?? 14, 16);
      await snap.setCamera(camera);
      final png = await snap.start().timeout(const Duration(seconds: 20));
      final c = camera.center?.coordinates;
      if (png == null || c == null) return null;
      return MapShot(png, center: (c.lng.toDouble(), c.lat.toDouble()), zoom: camera.zoom!);
    } on Object {
      return null;
    } finally {
      unawaited(snap?.dispose());
    }
  },
);

/// One card at its real size (360 × 640); wrap it in a RepaintBoundary to save it
class ShareCard extends StatelessWidget {
  const ShareCard({
    super.key,
    required this.template,
    required this.data,
    required this.stats,
    this.mapShot,
    this.photo,
  });

  final ShareCardTemplate template;
  final ShareCardData data;
  final Set<CardStat> stats;
  final MapShot? mapShot;
  final Uint8List? photo;

  @override
  Widget build(BuildContext context) => MediaQuery.withNoTextScaling(
    child: SizedBox.fromSize(
      size: shareCardSize,
      child: DefaultTextStyle(
        style: const TextStyle(fontFamily: 'Inter', color: Colors.white, decoration: TextDecoration.none),
        child: switch (template) {
          ShareCardTemplate.map => _MapCard(data: data, stats: stats, shot: mapShot),
          ShareCardTemplate.sticker => _StickerCard(data: data, stats: stats),
          ShareCardTemplate.photo => _PhotoCard(data: data, stats: stats, photo: photo),
          ShareCardTemplate.profile => _ProfileCard(data: data, stats: stats),
        },
      ),
    ),
  );
}

// --- Pieces ----------------------------------------------------------------------------------------

class _Title extends StatelessWidget {
  const _Title(this.data, {this.dark = false});

  final ShareCardData data;
  final bool dark;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        data.name,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 24,
          height: 1.15,
          fontWeight: FontWeight.w800,
          color: dark ? L360Colors.ink : Colors.white,
          shadows: dark ? null : _shadow,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        cardDate(data.date),
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: dark ? L360Colors.sand600 : const Color(0xE6FFFFFF),
          shadows: dark ? null : _shadow,
        ),
      ),
    ],
  );
}

/// The numbers switched on, two per row
class _Stats extends StatelessWidget {
  const _Stats(this.data, this.stats, {this.dark = false, this.shadow = false});

  final ShareCardData data;
  final Set<CardStat> stats;
  final bool dark;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final shown = [
      for (final s in CardStat.values)
        if (stats.contains(s)) s,
    ];
    Widget cell(CardStat s) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          s.label.toUpperCase(),
          style: TextStyle(
            fontSize: 9,
            letterSpacing: 1.4,
            fontWeight: FontWeight.w700,
            color: dark ? L360Colors.sand600 : const Color(0xD9FFFFFF),
            shadows: shadow ? _shadow : null,
          ),
        ),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            data.value(s),
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              height: 1.1,
              color: dark ? L360Colors.ink : Colors.white,
              shadows: shadow ? _shadow : null,
            ),
          ),
        ),
      ],
    );
    return Column(
      children: [
        for (var i = 0; i < shown.length; i += 2) ...[
          if (i > 0) const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: cell(shown[i])),
              const SizedBox(width: 16),
              Expanded(child: i + 1 < shown.length ? cell(shown[i + 1]) : const SizedBox.shrink()),
            ],
          ),
        ],
      ],
    );
  }
}

/// The Landscape 360 hallmark: a small logo and wide-spaced letters in a hairline pill, centred
/// at the foot of the card
class _Brand extends StatelessWidget {
  const _Brand({this.dark = false, this.shadow = false});

  final bool dark;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final ink = dark ? L360Colors.forest800 : Colors.white;
    return Center(
      child: Container(
        padding: const EdgeInsets.fromLTRB(7, 4, 10, 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: ink.withValues(alpha: dark ? 0.35 : 0.55), width: 0.6),
          color: dark ? null : const Color(0x26000000),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset('assets/images/logo.png', width: 12, height: 12),
            const SizedBox(width: 6),
            Text(
              'LANDSCAPE 360',
              style: TextStyle(
                fontSize: 7.5,
                letterSpacing: 2.8,
                fontWeight: FontWeight.w600,
                color: ink.withValues(alpha: 0.92),
                shadows: shadow ? _shadow : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The route as a line with a white edge, a green start and a chequered-red finish
class RoutePainter extends CustomPainter {
  RoutePainter(this.points, {this.color = _route, this.casing = Colors.white, this.width = 5, this.glow = false});

  final List<Offset> points;
  final Color color;
  final Color? casing;
  final double width;
  final bool glow;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    Paint stroke(Color c, double w) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (glow) {
      canvas.drawPath(
        path,
        stroke(const Color(0x66000000), width + 4)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );
    }
    if (casing != null) canvas.drawPath(path, stroke(casing!, width + 3));
    canvas.drawPath(path, stroke(color, width));
    void dot(Offset at, Color fill) => canvas
      ..drawCircle(at, width + 3.5, Paint()..color = Colors.white)
      ..drawCircle(at, width + 1.2, Paint()..color = fill);
    dot(points.first, _start);
    dot(points.last, L360Colors.brick500);
  }

  @override
  bool shouldRepaint(RoutePainter old) => old.points != points || old.color != color;
}

// --- Map -------------------------------------------------------------------------------------------

class _MapCard extends StatelessWidget {
  const _MapCard({required this.data, required this.stats, required this.shot});

  final ShareCardData data;
  final Set<CardStat> stats;
  final MapShot? shot;

  @override
  Widget build(BuildContext context) {
    final s = shot;
    final route = s == null
        ? fitRoute(data.line, const Rect.fromLTWH(48, 160, 264, 230))
        : [for (final p in data.line) projectOnMap(p, center: s.center, zoom: s.zoom, size: shareCardSize)];
    return Stack(
      fit: StackFit.expand,
      children: [
        if (s != null)
          Image.memory(s.png, fit: BoxFit.cover, gaplessPlayback: true)
        else
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF2E5A1F), L360Colors.forest900],
              ),
            ),
            child: CustomPaint(painter: _ContourPainter()),
          ),
        // Readable title and numbers over any map
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: [0, 0.28, 0.5, 0.78, 1],
              colors: [Color(0xD9000000), Color(0x00000000), Color(0x00000000), Color(0xBF000000), Color(0xF2000000)],
            ),
          ),
        ),
        CustomPaint(painter: RoutePainter(route)),
        Padding(
          // The Mapbox logo and attribution stay readable along the bottom edge
          padding: EdgeInsets.fromLTRB(24, 30, 24, s == null ? 26 : 44),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [_Title(data), const Spacer(), _Stats(data, stats), const SizedBox(height: 22), const _Brand()],
          ),
        ),
      ],
    );
  }
}

/// Faint contour lines behind the route when there is no map
class _ContourPainter extends CustomPainter {
  const _ContourPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = const Color(0x1FFFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (var i = 0; i < 14; i++) {
      final path = Path();
      for (var x = 0.0; x <= size.width; x += 6) {
        final y = 60 + i * 42 + math.sin(x / 47 + i * 0.9) * 14 + math.sin(x / 19 + i) * 4;
        x == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }
      canvas.drawPath(path, p);
    }
  }

  @override
  bool shouldRepaint(_ContourPainter old) => false;
}

// --- Sticker ---------------------------------------------------------------------------------------

/// Transparent: white route and numbers to lay on a photo
class _StickerCard extends StatelessWidget {
  const _StickerCard({required this.data, required this.stats});

  final ShareCardData data;
  final Set<CardStat> stats;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(28, 40, 28, 40),
    child: Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, c) => CustomPaint(
              size: c.biggest,
              painter: RoutePainter(
                fitRoute(data.line, Offset.zero & c.biggest),
                color: Colors.white,
                casing: null,
                width: 5,
                glow: true,
              ),
            ),
          ),
        ),
        const SizedBox(height: 28),
        _Stats(data, stats, shadow: true),
        const SizedBox(height: 22),
        const _Brand(shadow: true),
      ],
    ),
  );
}

// --- Photo -----------------------------------------------------------------------------------------

class _PhotoCard extends StatelessWidget {
  const _PhotoCard({required this.data, required this.stats, required this.photo});

  final ShareCardData data;
  final Set<CardStat> stats;
  final Uint8List? photo;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      if (photo != null)
        Image.memory(photo!, fit: BoxFit.cover, gaplessPlayback: true)
      else
        const ColoredBox(
          color: L360Colors.sand200,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add_photo_alternate_outlined, size: 44, color: L360Colors.sand600),
                SizedBox(height: 8),
                Text(
                  'Choose a photo',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: L360Colors.sand600),
                ),
              ],
            ),
          ),
        ),
      const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: [0, 0.25, 0.5, 1],
            colors: [Color(0x99000000), Color(0x00000000), Color(0x00000000), Color(0xCC000000)],
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 30, 24, 26),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Title(data),
            const Spacer(),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(child: _Stats(data, stats, shadow: true)),
                const SizedBox(width: 12),
                SizedBox.square(
                  dimension: 92,
                  child: CustomPaint(
                    painter: RoutePainter(
                      fitRoute(data.line, const Rect.fromLTWH(6, 6, 80, 80)),
                      color: Colors.white,
                      casing: null,
                      width: 3,
                      glow: true,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 22),
            const _Brand(shadow: true),
          ],
        ),
      ),
    ],
  );
}

// --- Elevation -------------------------------------------------------------------------------------

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.data, required this.stats});

  final ShareCardData data;
  final Set<CardStat> stats;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: L360Colors.sand50,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(24, 30, 24, 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _Title(data, dark: true)),
              const SizedBox(width: 10),
              SizedBox.square(
                dimension: 70,
                child: CustomPaint(
                  painter: RoutePainter(
                    fitRoute(data.line, const Rect.fromLTWH(4, 4, 62, 62)),
                    color: L360Colors.forest700,
                    width: 2.5,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 26),
          Expanded(
            child: CustomPaint(
              size: Size.infinite,
              painter: ProfilePainter(data.profile, highest: data.highestM),
            ),
          ),
          const SizedBox(height: 22),
          _Stats(data, stats, dark: true),
          const SizedBox(height: 22),
          const _Brand(dark: true),
        ],
      ),
    ),
  );
}

/// Height against distance, filled, with the summit marked
class ProfilePainter extends CustomPainter {
  ProfilePainter(this.profile, {this.highest});

  final List<(double, double)> profile;
  final double? highest;

  @override
  void paint(Canvas canvas, Size size) {
    if (profile.length < 2) {
      final tp = TextPainter(
        text: const TextSpan(
          text: 'No elevation in this track',
          style: TextStyle(fontSize: 14, color: L360Colors.sand500),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width);
      tp.paint(canvas, Offset((size.width - tp.width) / 2, size.height / 2 - tp.height / 2));
      return;
    }
    final maxD = profile.last.$1 == 0 ? 1.0 : profile.last.$1;
    final lo = profile.map((p) => p.$2).reduce(math.min), hi = profile.map((p) => p.$2).reduce(math.max);
    final span = math.max(hi - lo, 20.0);
    const top = 34.0, bottom = 18.0;
    Offset xy((double, double) p) =>
        Offset(p.$1 / maxD * size.width, top + (1 - (p.$2 - lo) / span) * (size.height - top - bottom));
    final line = Path()..moveTo(xy(profile.first).dx, xy(profile.first).dy);
    var peak = profile.first;
    for (final p in profile.skip(1)) {
      line.lineTo(xy(p).dx, xy(p).dy);
      if (p.$2 > peak.$2) peak = p;
    }
    final fill = Path.from(line)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas
      ..drawPath(
        fill,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0x99E46C24), Color(0x14E46C24)],
          ).createShader(Offset.zero & size),
      )
      ..drawPath(
        line,
        Paint()
          ..color = _route
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeJoin = StrokeJoin.round,
      );
    final at = xy(peak);
    canvas
      ..drawCircle(at, 6.5, Paint()..color = Colors.white)
      ..drawCircle(at, 4.5, Paint()..color = L360Colors.brick500);
    final label = TextPainter(
      text: TextSpan(
        text: '▲ ${_thousands((highest ?? peak.$2).round())} m',
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: L360Colors.ink),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final lx = (at.dx - label.width / 2).clamp(0.0, size.width - label.width);
    label.paint(canvas, Offset(lx, math.max(0, at.dy - 26)));
    final base = TextPainter(
      text: TextSpan(
        text: maxD >= 1000 ? '${(maxD / 1000).toStringAsFixed(1)} km' : '${maxD.round()} m',
        style: const TextStyle(fontSize: 11, color: L360Colors.sand600),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    base.paint(canvas, Offset(size.width - base.width, size.height - base.height));
  }

  @override
  bool shouldRepaint(ProfilePainter old) => old.profile != profile || old.highest != highest;
}
