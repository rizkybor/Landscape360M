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
class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key});

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen> {
  final _sheet = DraggableScrollableController();
  double? _contentHeight;
  double _headerHeight = mapSheetPeekHeight;
  double _bodyVisibility = 0;

  @override
  void initState() {
    super.initState();
    _sheet.addListener(_onSheetMoved);
  }

  @override
  void dispose() {
    _sheet
      ..removeListener(_onSheetMoved)
      ..dispose();
    super.dispose();
  }

  /// Closed, the sheet shows exactly its header (grabber, title row, section tabs) above the
  /// home indicator
  double _peek(BuildContext context) =>
      ((_headerHeight + MediaQuery.paddingOf(context).bottom) / MediaQuery.sizeOf(context).height).clamp(0.08, 0.4);

  /// Highest the sheet may open: as tall as its content, at most 90% of the screen
  double _maxSize(double screen, double peek) {
    final content = _contentHeight;
    if (content == null) return peek;
    return (content / screen).clamp(peek, 0.9);
  }

  void _onSheetMoved() {
    if (!_sheet.isAttached || !mounted) return;
    // The content below the tabs fades in over the first few percent of opening
    final v = ((_sheet.size - _peek(context)) / 0.05).clamp(0.0, 1.0);
    if ((v - _bodyVisibility).abs() > 0.01 || (v != _bodyVisibility && (v == 0 || v == 1))) {
      setState(() => _bodyVisibility = v);
    }
  }

  void _onHeaderHeight(double height) {
    if (!mounted || (height - _headerHeight).abs() < 0.5) return;
    final wasClosed = !_sheet.isAttached || _bodyVisibility == 0;
    setState(() => _headerHeight = height);
    if (wasClosed && _sheet.isAttached) _sheet.jumpTo(_peek(context));
  }

  void _onContentHeight(double height) {
    if (!mounted || height == _contentHeight) return;
    setState(() => _contentHeight = height);
    // A shorter section while the sheet is open: settle on the new top instead of leaving a gap
    final max = _maxSize(MediaQuery.sizeOf(context).height, _peek(context));
    if (_sheet.isAttached && _sheet.size > max + 0.001) {
      _sheet.animateTo(max, duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
    }
  }

  /// Tapping a section tab while the sheet is closed opens it, so the section shows
  void _onSectionChanged() {
    if (!_sheet.isAttached || _bodyVisibility > 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_sheet.isAttached) return;
      final max = _maxSize(MediaQuery.sizeOf(context).height, _peek(context));
      _sheet.animateTo(max, duration: const Duration(milliseconds: 260), curve: Curves.easeOutCubic);
    });
  }

  List<double> _snaps(double peek, double max) => {peek, if (max > 0.6) 0.5, max}.toList()..sort();

  /// Header dragged: the sheet follows the finger
  void _onHandleDrag(double dy) {
    if (!_sheet.isAttached) return;
    final screen = MediaQuery.sizeOf(context).height;
    final peek = _peek(context);
    _sheet.jumpTo((_sheet.size - dy / screen).clamp(peek, _maxSize(screen, peek)));
  }

  /// Header released: a flick goes to the next stop that way, otherwise to the nearest
  void _onHandleDragEnd(double velocity) {
    if (!_sheet.isAttached) return;
    final screen = MediaQuery.sizeOf(context).height;
    final peek = _peek(context);
    final snaps = _snaps(peek, _maxSize(screen, peek));
    final size = _sheet.size;
    double target;
    if (velocity < -300) {
      target = snaps.firstWhere((s) => s > size + 0.01, orElse: () => snaps.last);
    } else if (velocity > 300) {
      target = snaps.lastWhere((s) => s < size - 0.01, orElse: () => snaps.first);
    } else {
      target = snaps.reduce((a, b) => (a - size).abs() <= (b - size).abs() ? a : b);
    }
    _sheet.animateTo(target, duration: const Duration(milliseconds: 260), curve: Curves.easeOutCubic);
  }

  /// Grabber tapped: open when closed, close when open
  void _onGrabberTap() {
    if (!_sheet.isAttached) return;
    final screen = MediaQuery.sizeOf(context).height;
    final peek = _peek(context);
    final target = _bodyVisibility > 0 ? peek : _maxSize(screen, peek);
    _sheet.animateTo(target, duration: const Duration(milliseconds: 260), curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) {
    final hasToken = ref.watch(appConfigProvider).mapboxPublicToken.isNotEmpty;
    final screen = MediaQuery.sizeOf(context).height;
    final peek = _peek(context);
    final max = _maxSize(screen, peek);
    // Middle stop only when the content is tall enough for it to mean something
    final snaps = _snaps(peek, max);
    // Light status bar over satellite imagery, dark over the light Streets / Outdoors maps
    final dark = ref.watch(mapSettingsProvider.select((s) => s.style == MapStyle.satellite));
    final sheetInset = _headerHeight + MediaQuery.paddingOf(context).bottom;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
        body: Stack(
          children: [
            Positioned.fill(child: hasToken ? _LiveMap(sheetInset: sheetInset) : const _NoMapToken()),
            DraggableScrollableSheet(
              controller: _sheet,
              initialChildSize: peek,
              minChildSize: peek,
              maxChildSize: max,
              snap: true,
              snapSizes: snaps,
              builder: (context, controller) => MapSheet(
                scrollController: controller,
                onContentHeight: _onContentHeight,
                onHeaderHeight: _onHeaderHeight,
                onSectionChanged: _onSectionChanged,
                onHandleDrag: _onHandleDrag,
                onHandleDragEnd: _onHandleDragEnd,
                onGrabberTap: _onGrabberTap,
                bodyVisibility: _bodyVisibility,
              ),
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
  const _LiveMap({required this.sheetInset});

  /// Height of the closed sheet, kept clear for the Mapbox logo, attribution and messages
  final double sheetInset;

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

  double get _sheetInset => widget.sheetInset + 6;

  @override
  void didUpdateWidget(_LiveMap old) {
    super.didUpdateWidget(old);
    final map = _map;
    if (map != null && old.sheetInset != widget.sheetInset) {
      unawaited(map.logo.updateSettings(LogoSettings(marginBottom: _sheetInset)));
      unawaited(map.attribution.updateSettings(AttributionSettings(marginBottom: _sheetInset)));
    }
  }

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
