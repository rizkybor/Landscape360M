import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide Size;

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/widgets.dart';
import '../../domain/map/map_settings.dart';
import 'map_settings_controller.dart';
import 'map_sheet.dart';
import 'telemetry_card.dart';

/// Home screen: the Mapbox map (2D / 3D terrain), the user's location, the telemetry of the
/// point under the crosshair and the Tools / Map / Terrain sheet. Like the web, it works
/// without signing in.
class MapScreen extends ConsumerWidget {
  const MapScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasToken = ref.watch(appConfigProvider).mapboxPublicToken.isNotEmpty;
    final height = MediaQuery.sizeOf(context).height;
    final peek = ((mapSheetPeekHeight + MediaQuery.paddingOf(context).bottom) / height).clamp(0.1, 0.4);
    // Light status bar over satellite imagery, dark over the light Streets / Outdoors maps
    final dark = ref.watch(mapSettingsProvider.select((s) => s.style == MapStyle.satellite));
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
        body: Stack(
          children: [
            Positioned.fill(child: hasToken ? const _LiveMap() : const _NoMapToken()),
            DraggableScrollableSheet(
              initialChildSize: peek,
              minChildSize: peek,
              maxChildSize: 0.9,
              snap: true,
              snapSizes: [peek, 0.5],
              builder: (context, controller) => MapSheet(scrollController: controller),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoMapToken extends StatelessWidget {
  const _NoMapToken();

  @override
  Widget build(BuildContext context) => const ColoredBox(
    color: L360Colors.sand100,
    child: Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Text('The map needs MAPBOX_PUBLIC_TOKEN (pk.) in config/<flavor>.json.', textAlign: TextAlign.center),
      ),
    ),
  );
}

class _LiveMap extends ConsumerStatefulWidget {
  const _LiveMap();

  @override
  ConsumerState<_LiveMap> createState() => _LiveMapState();
}

class _LiveMapState extends ConsumerState<_LiveMap> {
  MapboxMap? _map;
  Telemetry _telemetry = Telemetry(lng: defaultCenter.lng, lat: defaultCenter.lat, pitch: 0, bearing: 0);
  DateTime _lastTelemetry = DateTime(0);
  bool _locating = false;
  String? _message;

  bool _telemetryOpen = false;

  // Height of the collapsed sheet: keeps the Mapbox logo and attribution visible above it
  double get _sheetInset => mapSheetPeekHeight + MediaQuery.paddingOf(context).bottom + 6;

  Future<void> _onMapCreated(MapboxMap map) async {
    _map = map;
    final s = ref.read(mapSettingsProvider);
    await map.setCamera(
      CameraOptions(
        center: Point(coordinates: Position(defaultCenter.lng, defaultCenter.lat)),
        zoom: defaultZoom,
        pitch: 0,
        bearing: 0,
      ),
    );
    await map.setBounds(CameraBoundsOptions(minZoom: minZoom, maxZoom: maxZoom, maxPitch: maxPitch));
    // Our own controls replace the built-in compass and scale bar
    await map.compass.updateSettings(CompassSettings(enabled: false));
    await map.scaleBar.updateSettings(ScaleBarSettings(enabled: false));
    await map.logo.updateSettings(LogoSettings(marginBottom: _sheetInset));
    await map.attribution.updateSettings(AttributionSettings(marginBottom: _sheetInset));
    await _applyView(s, animate: false);
    await _showPuckIfAllowed();
  }

  /// Terrain and sky are part of the style: added again after every style change
  Future<void> _onStyleLoaded(StyleLoadedEventData _) async {
    final map = _map;
    if (map == null) return;
    try {
      if (!await map.styleSourceExists(terrainSourceId)) {
        await map.addStyleSource(
          terrainSourceId,
          jsonEncode({'type': 'raster-dem', 'url': terrainSourceUrl, 'tileSize': 512, 'maxzoom': 14}),
        );
      }
      await _applyTerrain(ref.read(mapSettingsProvider));
      if (!await map.styleLayerExists('sky')) {
        await map.addStyleLayer(
          jsonEncode({
            'id': 'sky',
            'type': 'sky',
            'paint': {
              'sky-type': 'atmosphere',
              'sky-atmosphere-sun': [0.0, 0.0],
              'sky-atmosphere-sun-intensity': 15,
            },
          }),
          null,
        );
      }
    } on Object catch (e) {
      _show('Terrain could not be loaded: $e');
    }
    unawaited(_updateElevation());
  }

  Future<void> _applyTerrain(MapSettings s) =>
      _map!.setStyleTerrain(jsonEncode({'source': terrainSourceId, 'exaggeration': s.appliedExaggeration}));

  /// 2D: flat and no tilt gesture (keeps the map stable); 3D: tilted, pitch gesture on
  Future<void> _applyView(MapSettings s, {bool animate = true}) async {
    final map = _map;
    if (map == null) return;
    await map.gestures.updateSettings(GesturesSettings(pitchEnabled: s.is3D, rotateEnabled: true));
    final camera = CameraOptions(pitch: s.is3D ? defaultPitch3D : 0);
    if (animate) {
      await map.easeTo(camera, MapAnimationOptions(duration: 800));
    } else {
      await map.setCamera(camera);
    }
    if (await map.styleSourceExists(terrainSourceId)) await _applyTerrain(s);
  }

  void _onCameraChanged(CameraChangedEventData e) {
    // Throttled like the web (at most every 100 ms); elevation waits for the map to settle
    final now = DateTime.now();
    if (now.difference(_lastTelemetry).inMilliseconds < 100) return;
    _lastTelemetry = now;
    final c = e.cameraState;
    setState(() {
      _telemetry = _telemetry.withCamera(
        lng: c.center.coordinates.lng.toDouble(),
        lat: c.center.coordinates.lat.toDouble(),
        pitch: c.pitch,
        bearing: c.bearing,
      );
    });
  }

  Future<void> _updateElevation() async {
    final map = _map;
    if (map == null || !mounted) return;
    final c = await map.getCameraState();
    final lng = c.center.coordinates.lng.toDouble();
    final lat = c.center.coordinates.lat.toDouble();
    final ex = ref.read(mapSettingsProvider).appliedExaggeration;
    Future<double?> at(double x, double y) async {
      final v = await map.getElevation(Point(coordinates: Position(x, y)));
      return v == null ? null : realElevation(v, ex);
    }

    final elev = await at(lng, lat);
    final east = await at(lng + slopeSampleOffsetDeg, lat);
    final north = await at(lng, lat + slopeSampleOffsetDeg);
    if (!mounted) return;
    setState(() {
      _telemetry = Telemetry(
        lng: lng,
        lat: lat,
        pitch: c.pitch,
        bearing: c.bearing,
        elevation: elev,
        slope: elev == null ? null : terrainSlopeDegrees(elev, east ?? elev, north ?? elev),
      );
    });
  }

  Future<bool> _locationAllowed({required bool ask}) async {
    if (!await geo.Geolocator.isLocationServiceEnabled()) {
      if (ask) _show('Turn on Location Services to see where you are.');
      return false;
    }
    var permission = await geo.Geolocator.checkPermission();
    if (permission == geo.LocationPermission.denied && ask) permission = await geo.Geolocator.requestPermission();
    if (permission == geo.LocationPermission.deniedForever && ask) {
      _show('Location is off for Landscape 360. Allow it in Settings.');
    }
    return permission == geo.LocationPermission.whileInUse || permission == geo.LocationPermission.always;
  }

  Future<void> _enablePuck() => _map!.location.updateSettings(
    LocationComponentSettings(
      enabled: true,
      showAccuracyRing: true,
      pulsingEnabled: false,
      // The arrow follows the top edge of the phone (compass), like the web's needle
      puckBearingEnabled: true,
      puckBearing: PuckBearing.HEADING,
    ),
  );

  Future<void> _showPuckIfAllowed() async {
    if (await _locationAllowed(ask: false)) await _enablePuck();
  }

  /// "Go to my location": asks for permission only when tapped
  Future<void> _locateMe() async {
    final map = _map;
    if (map == null || _locating) return;
    setState(() => _locating = true);
    try {
      if (!await _locationAllowed(ask: true)) return;
      await _enablePuck();
      final p = await geo.Geolocator.getCurrentPosition(
        locationSettings: const geo.LocationSettings(
          accuracy: geo.LocationAccuracy.high,
          timeLimit: Duration(seconds: 20),
        ),
      );
      await map.flyTo(
        CameraOptions(center: Point(coordinates: Position(p.longitude, p.latitude)), zoom: 15),
        MapAnimationOptions(duration: 1200),
      );
    } on TimeoutException {
      _show('No GPS fix yet. Try again under open sky.');
    } on Object catch (e) {
      _show('Could not get your location: $e');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _zoomBy(double delta) async {
    final map = _map;
    if (map == null) return;
    final c = await map.getCameraState();
    await map.easeTo(CameraOptions(zoom: (c.zoom + delta).clamp(minZoom, maxZoom)), MapAnimationOptions(duration: 250));
  }

  Future<void> _resetNorth() async => _map?.easeTo(CameraOptions(bearing: 0), MapAnimationOptions(duration: 400));

  void _show(String text) {
    if (!mounted) return;
    setState(() => _message = text);
    Future<void>.delayed(const Duration(seconds: 4), () {
      if (mounted && _message == text) setState(() => _message = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(mapSettingsProvider);
    ref.listen<MapSettings>(mapSettingsProvider, (prev, next) {
      final map = _map;
      if (map == null || prev == null) return;
      if (prev.style != next.style) unawaited(map.loadStyleURI(next.style.uri));
      if (prev.view != next.view) unawaited(_applyView(next));
      if (prev.exaggeration != next.exaggeration && next.is3D) unawaited(_applyTerrain(next));
    });

    final top = MediaQuery.paddingOf(context).top + 8;
    final satellite = settings.style == MapStyle.satellite;
    return Stack(
      children: [
        MapWidget(
          key: const ValueKey('map'),
          styleUri: settings.style.uri,
          onMapCreated: _onMapCreated,
          onStyleLoadedListener: _onStyleLoaded,
          onCameraChangeListener: _onCameraChanged,
          onMapIdleListener: (_) => unawaited(_updateElevation()),
        ),
        // Keeps the status bar readable over satellite imagery
        if (satellite)
          IgnorePointer(
            child: Container(
              height: top + 40,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x66000000), Color(0x00000000)],
                ),
              ),
            ),
          ),
        // Crosshair: the telemetry describes this point
        const IgnorePointer(child: Center(child: _Crosshair())),
        Positioned(
          left: 12,
          top: top,
          child: TelemetryCard(
            telemetry: _telemetry,
            format: settings.coordFormat,
            onFormatChanged: ref.read(mapSettingsProvider.notifier).setCoordFormat,
            expanded: _telemetryOpen,
            onToggle: () => setState(() => _telemetryOpen = !_telemetryOpen),
          ),
        ),
        Positioned(
          right: 12,
          top: top,
          child: Column(
            children: [
              MapIconButton(
                key: const Key('reset-north'),
                tooltip: 'Reset to north',
                onPressed: _resetNorth,
                child: Transform.rotate(
                  angle: -_telemetry.bearing * math.pi / 180,
                  child: const CustomPaint(size: Size(18, 24), painter: _NeedlePainter()),
                ),
              ),
              const SizedBox(height: 10),
              GlassPanel(
                radius: L360.touch / 2,
                child: Column(
                  children: [
                    _ZoomButton(icon: Icons.add, tooltip: 'Zoom in', onPressed: () => _zoomBy(1)),
                    Container(width: 24, height: 0.8, color: L360Colors.sand300),
                    _ZoomButton(icon: Icons.remove, tooltip: 'Zoom out', onPressed: () => _zoomBy(-1)),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              MapIconButton(
                key: const Key('locate-me'),
                tooltip: 'Go to my location',
                onPressed: _locateMe,
                child: _locating
                    ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.near_me, color: L360Colors.forest700),
              ),
            ],
          ),
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: _sheetInset + 36,
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: _message == null ? 0 : 1,
              duration: const Duration(milliseconds: 200),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: L360Colors.ink.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(L360.radiusSmall),
                    boxShadow: L360.shadow,
                  ),
                  child: Text(
                    _message ?? '',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
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

class _ZoomButton extends StatelessWidget {
  const _ZoomButton({required this.icon, required this.tooltip, required this.onPressed});

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: L360.touch,
    child: IconButton(
      tooltip: tooltip,
      icon: Icon(icon, size: 22),
      color: L360Colors.ink,
      onPressed: () {
        HapticFeedback.lightImpact();
        onPressed();
      },
    ),
  );
}

/// Compass needle of the reset-north button: red half points to north
class _NeedlePainter extends CustomPainter {
  const _NeedlePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height, mid = h / 2;
    canvas.drawPath(
      Path()
        ..moveTo(w / 2, 0)
        ..lineTo(w, mid)
        ..lineTo(0, mid)
        ..close(),
      Paint()..color = L360Colors.brick500,
    );
    canvas.drawPath(
      Path()
        ..moveTo(0, mid)
        ..lineTo(w, mid)
        ..lineTo(w / 2, h)
        ..close(),
      Paint()..color = L360Colors.sand400,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Thin cross with a dark halo, readable on light and dark maps
class _Crosshair extends StatelessWidget {
  const _Crosshair();

  @override
  Widget build(BuildContext context) => const CustomPaint(size: Size(28, 28), painter: _CrosshairPainter());
}

class _CrosshairPainter extends CustomPainter {
  const _CrosshairPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    void cross(Paint p) {
      canvas
        ..drawLine(Offset(c.dx, 0), Offset(c.dx, c.dy - 4), p)
        ..drawLine(Offset(c.dx, c.dy + 4), Offset(c.dx, size.height), p)
        ..drawLine(Offset(0, c.dy), Offset(c.dx - 4, c.dy), p)
        ..drawLine(Offset(c.dx + 4, c.dy), Offset(size.width, c.dy), p);
    }

    cross(
      Paint()
        ..color = const Color(0x99000000)
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round,
    );
    cross(
      Paint()
        ..color = Colors.white
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawCircle(c, 1.6, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
