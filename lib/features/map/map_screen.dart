import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide Size;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/widgets.dart';
import '../../domain/compass/device_heading.dart';
import '../../domain/map/map_settings.dart';
import '../../domain/route/route_planner.dart';
import '../../domain/survey/survey_model.dart';
import '../../domain/tracks/track_recorder_geo.dart';
import '../../domain/util/js_compat.dart';
import '../areas/area_layer.dart';
import '../areas/area_panel.dart';
import '../areas/area_state.dart';
import '../basemaps/basemap_state.dart';
import '../classic/classic_overlay.dart';
import '../classic/classic_panel.dart';
import '../classic/classic_state.dart';
import '../live/live_tracking_sheet.dart';
import '../live/live_tracking_state.dart';
import '../marked/marked_layer.dart';
import '../marked/marked_sheet.dart';
import '../marked/marked_state.dart';
import '../navigator/navigator_overlay.dart';
import '../navigator/navigator_panel.dart';
import '../navigator/navigator_state.dart';
import '../offline/offline_state.dart';
import '../offline/offline_ui.dart';
import '../report/report_export.dart';
import '../sos/sos_alerts.dart';
import '../sos/sos_button.dart';
import '../sos/sos_state.dart';
import '../tracks/track_layer.dart';
import '../tracks/track_recorder_panel.dart';
import '../tracks/track_recorder_state.dart';
import 'location_puck.dart';
import 'map_settings_controller.dart';
import 'map_sheet.dart';
import 'map_tools_state.dart';
import 'poi_layer.dart';
import 'route_layer.dart';
import 'route_panel.dart';
import 'share_location_sheet.dart';
import 'shared_links.dart';
import 'telemetry_card.dart';
import 'terrain_layers.dart';
import 'weather_card.dart';

/// Home screen: the Mapbox map (2D / 3D terrain), the user's location, the telemetry of the
/// point under the crosshair and the Tools / Map / Terrain sheet. Like the web, it works
/// without signing in.
class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key});

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen> {
  // Offline maps asked for from User Account: opened once the map is on screen
  void _openRequestedOfflineSheet() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !ref.read(offlineSheetRequestProvider)) return;
      ref.read(offlineSheetRequestProvider.notifier).done();
      unawaited(showOfflineSheet(context));
    });
  }

  final _sheet = DraggableScrollableController();
  double? _contentHeight;
  double _headerHeight = mapSheetPeekHeight;
  double _bodyVisibility = 0;

  /// A section was chosen: until its height is known, the sheet moves to fit it
  bool _opening = false;
  Timer? _openingTimer;

  /// While moving to a shorter section, the old height stays allowed, so the sheet slides
  /// down instead of being cut to the new height at once
  double? _heldSize;

  @override
  void initState() {
    super.initState();
    _sheet.addListener(_onSheetMoved);
    // Asked for before the map was on screen (User Account opened on its own)
    if (ref.read(offlineSheetRequestProvider)) _openRequestedOfflineSheet();
  }

  @override
  void dispose() {
    _openingTimer?.cancel();
    _sheet
      ..removeListener(_onSheetMoved)
      ..dispose();
    super.dispose();
  }

  /// Closed, the sheet shows exactly its header (grabber, title row, section tabs) above the
  /// home indicator
  double _peek(BuildContext context) =>
      ((_headerHeight + MediaQuery.paddingOf(context).bottom) / MediaQuery.sizeOf(context).height).clamp(0.08, 0.4);

  /// Height that fits the current section: as tall as its content, at most 90% of the screen
  double _fitSize(double screen, double peek) {
    final content = _contentHeight;
    return content == null ? peek : (content / screen).clamp(peek, 0.9);
  }

  /// Highest the sheet may open: the fitting height (the old one too while sliding down)
  double _maxSize(double screen, double peek) {
    final fit = _fitSize(screen, peek);
    final held = _heldSize;
    return held != null && held > fit ? held : fit;
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
    // Open and the section itself changed (e.g. Contours switched off): it keeps fitting,
    // sliding from the current height like a section switch
    if (!_opening && _sheet.isAttached && _bodyVisibility > 0) {
      // Only when it was showing the whole section; a sheet pulled half down stays there
      final screen = MediaQuery.sizeOf(context).height;
      if (_sheet.size >= _fitSize(screen, _peek(context)) - 0.01) _holdWhileFitting();
    }
    setState(() => _contentHeight = height);
    // Slide to the new height once known (after the rebuild)
    if (!_opening) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _sheet.isAttached && _opening) _fitSection();
    });
  }

  /// Keeps the current height allowed and aims for the fitting one for a moment
  void _holdWhileFitting() {
    setState(() => _heldSize = _sheet.size);
    _opening = true;
    _openingTimer?.cancel();
    _openingTimer = Timer(const Duration(milliseconds: 1500), () {
      _opening = false;
      if (mounted) setState(() => _heldSize = null);
    });
  }

  /// Every section shows at its own height: choosing one (sheet open or closed) slides the
  /// sheet to fit it, the same way each time
  void _onSectionChanged() {
    if (!_sheet.isAttached) return;
    // The new section's height arrives a frame or more later; the sheet retargets each time.
    // Meanwhile the current height stays allowed so a shorter section is reached by sliding.
    _holdWhileFitting();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _sheet.isAttached) _fitSection();
    });
  }

  void _fitSection() {
    final fit = _fitSize(MediaQuery.sizeOf(context).height, _peek(context));
    _sheet.animateTo(fit, duration: const Duration(milliseconds: 260), curve: Curves.easeOutCubic);
  }

  List<double> _snaps(double peek, double max) => {peek, if (max > 0.6) 0.5, max}.toList()..sort();

  /// Header dragged: the sheet follows the finger
  void _onHandleDrag(double dy) {
    if (!_sheet.isAttached) return;
    _opening = false; // the user moves the sheet now
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
    _opening = false;
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
    // Opening a tool lowers the sheet so the map is free (like the web)
    void lowerSheet(bool? prev, bool enabled) {
      if (enabled && _sheet.isAttached) {
        _sheet.animateTo(peek, duration: const Duration(milliseconds: 260), curve: Curves.easeOutCubic);
      }
    }

    // Offline maps asked for from User Account (which has closed): the sheet opens over the map
    ref.listen(offlineSheetRequestProvider, (_, asked) {
      if (asked) _openRequestedOfflineSheet();
    });
    ref
      ..listen(routePlannerProvider.select((s) => s.enabled), lowerSheet)
      ..listen(navigatorProvider.select((s) => s.enabled), lowerSheet)
      ..listen(trackRecorderProvider.select((s) => s.panelOpen), lowerSheet)
      ..listen(mapSettingsProvider.select((s) => s.showPois), lowerSheet)
      ..listen(areasProvider.select((s) => s.panelOpen || s.drawing), lowerSheet)
      ..listen(offlineProvider.select((s) => s.framing), lowerSheet)
      ..listen(classicProvider.select((s) => s.panelOpen), lowerSheet);
    final routeOpen = ref.watch(routePlannerProvider.select((s) => s.enabled));
    final navigatorOpen = ref.watch(navigatorProvider.select((s) => s.enabled));
    final trackOpen = ref.watch(trackRecorderProvider.select((s) => s.panelOpen));
    final classicOpen = ref.watch(classicProvider.select((s) => s.panelOpen));
    final recordingHidden = !trackOpen && ref.watch(trackRecorderProvider.select((s) => s.active != null));
    final liveOn = ref.watch(liveTrackingProvider.select((s) => s.on));
    final sosAlerts = ref.watch(sosAlertsProvider.select((s) => s.active.isNotEmpty));
    final sharedLink = ref.watch(sharedLinkProvider) != null;
    final poiOpen = ref.watch(selectedPoiProvider) != null;
    final picking = ref.watch(markedProvider.select((s) => s.picking));
    final areaDrawing = ref.watch(areasProvider.select((s) => s.drawing));
    final areaPanel = ref.watch(areasProvider.select((s) => s.panelOpen));
    final areaFocus = ref.watch(areasProvider.select((s) => s.focusId != null));
    // Downloads keep going while the list is closed
    final framing = ref.watch(offlineProvider.select((s) => s.framing));
    final size = MediaQuery.sizeOf(context);
    final top = MediaQuery.paddingOf(context).top;
    // The part of the map that a new offline area covers, above the download bar
    final frame = Rect.fromLTRB(20, top + 64, size.width - 20, math.max(top + 160, size.height - sheetInset - 300));
    final markedOpen = ref.watch(markedProvider.select((s) => s.selectedId != null));
    // A position picked on the map goes back into the form that asked for it
    ref.listen<PickedPoint?>(markedProvider.select((s) => s.picked), (_, p) {
      final draft = ref.read(markedDraftProvider);
      if (p == null || draft == null) return;
      unawaited(
        openMarkedForm(
          context,
          markedHost(ref),
          MarkedDraft(
            editingId: draft.editingId,
            name: draft.name,
            category: draft.category,
            lat: roundCoord(p.lat),
            lng: roundCoord(p.lng),
            elevation: p.elevationM == null ? draft.elevation : jsNum((p.elevationM! * 10).round() / 10),
            address: draft.address,
            contact: draft.contact,
            description: draft.description,
            tags: draft.tags,
          ),
        ),
      );
    });
    // Sends S.O.S reports left on the phone as soon as the app opens or the signal returns
    ref.listen(sosProvider, (_, _) {});
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
        body: Stack(
          children: [
            Positioned.fill(child: hasToken ? _LiveMap(sheetInset: sheetInset) : const _NoMapToken()),
            if (framing) Positioned.fill(child: OfflineFrame(frame: frame)),
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
            // The open tool's panel above the sheet; the REC pill sits on top while a
            // recording runs with its panel closed
            if (_bodyVisibility == 0)
              Positioned(
                left: 12,
                right: 12,
                bottom: sheetInset + 10,
                // Tablets: panels keep a phone's width instead of stretching across the map
                child: Align(
                  alignment: Alignment.bottomCenter,
                  heightFactor: 1,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: L360.panelMaxWidth),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (sosAlerts) ...[const SosBanner(), const SizedBox(height: 10)],
                        if (sharedLink) ...[const SharedLinkCard(), const SizedBox(height: 10)],
                        if (poiOpen) ...[const PoiCard(), const SizedBox(height: 10)],
                        if (picking) ...[const PickingBar(), const SizedBox(height: 10)],
                        if (areaFocus && !areaPanel && !areaDrawing) ...[
                          const AreaFocusPill(),
                          const SizedBox(height: 10),
                        ],
                        if (framing)
                          OfflineBar(frame: frame)
                        else if (areaDrawing)
                          const AreaDrawingBar()
                        else if (areaPanel)
                          const AreaPanel(),
                        if (markedOpen && !picking) ...[
                          MarkedCard(
                            onOpenList: () =>
                                showMarkedSheet(context, markedHost(ref), focusId: ref.read(markedProvider).selectedId),
                          ),
                          const SizedBox(height: 10),
                        ],
                        if (recordingHidden) ...[const RecPill(), const SizedBox(height: 10)],
                        if (liveOn) ...[const LivePill(), const SizedBox(height: 10)],
                        if (routeOpen) const RoutePanel(),
                        if (navigatorOpen)
                          NavigatorPanel(onShowSurvey: (doc) => ref.read(showSurveyProvider.notifier).show(doc)),
                        if (trackOpen) const TrackRecorderPanel(),
                        if (classicOpen) const ClassicPanel(),
                      ],
                    ),
                  ),
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

/// The live map, for integration tests that check what the map engine drew
@visibleForTesting
MapboxMap? debugLiveMap;

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

  TerrainLayers? _layers;
  RouteLayer? _route;
  TrackLayer? _tracks;
  SosAlertsLayer? _sosLayer;
  PoiLayer? _poiLayer;
  MarkedLayer? _markedLayer;
  AreaLayer? _areaLayer;
  BasemapLayer? _basemapLayer;
  SharedLinkLayer? _linkLayer;
  late final IncomingLinks _links = IncomingLinks(ref);
  Timer? _trackRedraw;
  final _cameraTick = ValueNotifier<int>(0);
  final _styleTick = ValueNotifier<int>(0);

  /// Terrain height without the 3D exaggeration (0 where the terrain has not loaded)
  /// Terrain height where the map has it loaded, else null
  Future<double?> _terrainAt(double lng, double lat) async {
    final v = await _map?.getElevation(Point(coordinates: Position(lng, lat)));
    return v == null ? null : realElevation(v, ref.read(mapSettingsProvider).appliedExaggeration);
  }

  Future<double> _elevationAt(double lng, double lat) async {
    try {
      final v = await _map?.getElevation(Point(coordinates: Position(lng, lat)));
      return v == null ? 0 : realElevation(v, ref.read(mapSettingsProvider).appliedExaggeration);
    } on Object {
      return 0;
    }
  }

  // Compass: the needle follows the phone when it has a compass, else the GPS course
  StreamSubscription<CompassEvent>? _compassSub;
  final _quality = CompassQualityTracker();
  bool? _hasCompass;
  bool _showCalibrateHint = false;
  bool _hintUsed = true; // until the saved choice is read
  Timer? _hintTimer;
  final _prefs = SharedPreferencesAsync();

  @override
  void initState() {
    super.initState();
    _links.start();
    _wakeChrome();
    unawaited(
      _prefs.getBool(compassHintDismissedKey).then((v) => _hintUsed = v ?? false, onError: (_) => _hintUsed = false),
    );
    final events = FlutterCompass.events;
    _compassSub = events?.listen(_onCompass, onError: (_) {});
    // No compass readings (no sensor): point the beam along the GPS course instead
    Timer(Duration(seconds: events == null ? 0 : 3), () {
      if (!mounted || _hasCompass != null) return;
      _hasCompass = false;
      if (_puckOn) unawaited(_enablePuck());
    });
  }

  @override
  void dispose() {
    _compassSub?.cancel();
    _links.dispose();
    _chromeTimer?.cancel();
    _hintTimer?.cancel();
    _layers?.dispose();
    _settle?.cancel();
    _trackRedraw?.cancel();
    _cameraTick.dispose();
    _styleTick.dispose();
    super.dispose();
  }

  void _onCompass(CompassEvent e) {
    final reading = readPluginCompass(heading: e.heading, accuracy: e.accuracy, android: Platform.isAndroid);
    if (reading == null) return;
    final q = _quality.push(reading, DateTime.now().millisecondsSinceEpoch);
    // A small one-time hint while the compass looks off; gone once it settles
    if (q == CompassQuality.poor && !_hintUsed) {
      _hintUsed = true;
      setState(() => _showCalibrateHint = true);
      _hintTimer = Timer(const Duration(seconds: 12), () {
        if (mounted) setState(() => _showCalibrateHint = false);
      });
    } else if (q == CompassQuality.ok && _showCalibrateHint) {
      setState(() => _showCalibrateHint = false);
    }
    if (reading.heading != null && _hasCompass != true) {
      _hasCompass = true;
      if (_puckOn) unawaited(_enablePuck());
    }
  }

  void _dismissHint() {
    setState(() => _showCalibrateHint = false);
    _hintUsed = true;
    unawaited(_prefs.setBool(compassHintDismissedKey, true).catchError((Object _) {}));
  }

  double get _sheetInset => widget.sheetInset + 6;

  // The Mapbox logo and (i) sit just above the closed sheet. iOS measures their margin from
  // the safe area, which already leaves out the home indicator.
  double get _ornamentMargin => widget.sheetInset - (Platform.isIOS ? MediaQuery.paddingOf(context).bottom : 0) + 6;

  @override
  void didUpdateWidget(_LiveMap old) {
    super.didUpdateWidget(old);
    final map = _map;
    if (map != null && old.sheetInset != widget.sheetInset) {
      unawaited(map.logo.updateSettings(LogoSettings(marginBottom: _ornamentMargin)));
      unawaited(map.attribution.updateSettings(AttributionSettings(marginBottom: _ornamentMargin)));
    }
  }

  /// My areas, the shape being drawn, and an area opened from a link (in focus)
  Future<void> _showAreas() async {
    final link = ref.read(sharedLinkProvider);
    final linked = link is SharedArea && link.area != null ? (ring: link.area!.ring, color: link.area!.color) : null;
    await _areaLayer?.show(
      ref.read(areasProvider),
      linked: linked,
      linkedContours: link is SharedArea ? link.contours : null,
    );
  }

  /// Points in view above the panels (fitBounds, max zoom 17)
  Future<void> _fitPoints(List<(double, double)> points) async {
    final map = _map;
    if (map == null) return;
    final camera = await map.cameraForCoordinates(
      [for (final (lng, lat) in points) Point(coordinates: Position(lng, lat))],
      MbxEdgeInsets(top: 120, left: 40, bottom: _sheetInset + 260, right: 80),
      null,
      null,
    );
    if ((camera.zoom ?? 0) > 17) camera.zoom = 17;
    await map.flyTo(camera, MapAnimationOptions(duration: 1200));
  }

  /// A tap for the open drawing tool; false when none is open
  bool _toolTap(double lng, double lat) {
    // Classic, Pick on map: this tap places the position
    if (ref.read(classicProvider).picking != null) {
      HapticFeedback.lightImpact();
      ref.read(classicProvider.notifier).placePicked((lng, lat));
      return true;
    }
    // Drawing a marked area: each tap adds a corner
    if (ref.read(areasProvider).drawing) {
      HapticFeedback.lightImpact();
      ref.read(areasProvider.notifier).addPoint((lng, lat));
      return true;
    }
    // Picking a position for the Marked Locations form: this tap sets it (with the terrain height)
    if (ref.read(markedProvider).picking) {
      HapticFeedback.lightImpact();
      unawaited(
        _terrainAt(lng, lat).then(
          (h) => ref.read(markedProvider.notifier).setPicked((lng: lng, lat: lat, elevationM: h)),
          onError: (Object _) => ref.read(markedProvider.notifier).setPicked((lng: lng, lat: lat, elevationM: null)),
        ),
      );
      return true;
    }
    if (ref.read(navigatorProvider).enabled) {
      HapticFeedback.lightImpact();
      // Like the web, a tap always adds a point (and drops the point selection)
      final nav = ref.read(navigatorProvider.notifier)..select(null);
      unawaited(nav.addPointAt(lng, lat, _elevationAt));
      return true;
    }
    if (ref.read(routePlannerProvider).enabled) {
      HapticFeedback.lightImpact();
      unawaited(ref.read(routePlannerProvider.notifier).tap((lng: lng, lat: lat)));
      return true;
    }
    return false;
  }

  Future<void> _onMapCreated(MapboxMap map) async {
    setState(() => _map = map); // the survey overlay needs the map
    debugLiveMap = map;
    ref.read(mapProjectionProvider.notifier).set((x, y) async {
      try {
        final p = await map.coordinateForPixel(ScreenCoordinate(x: x, y: y));
        return (p.coordinates.lng.toDouble(), p.coordinates.lat.toDouble());
      } on Object {
        return null;
      }
    });
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
    // Taps on the map add survey points (Navigator) or route points (Route Planner);
    // otherwise they close an open point-of-interest card
    map.addInteraction(
      TapInteraction.onMap((context) {
        final c = context.point.coordinates;
        if (_toolTap(c.lng.toDouble(), c.lat.toDouble())) return;
        ref.read(selectedPoiProvider.notifier).select(null);
        ref.read(markedProvider.notifier).select(null);
      }, stopPropagation: false),
      interactionID: 'map-tap',
    );
    // A point of interest opens its card; a cluster zooms in. With a drawing tool open the
    // tap still adds a point there.
    map.addInteraction(
      TapInteraction(FeaturesetDescriptor(layerId: poiPointsLayer), (feature, context) {
        final c = context.point.coordinates;
        if (_toolTap(c.lng.toDouble(), c.lat.toDouble())) return;
        final id = '${feature.properties['id']}';
        final poi = (ref.read(poisProvider).value ?? const []).where((p) => p.id == id).firstOrNull;
        if (poi == null) return;
        HapticFeedback.selectionClick();
        ref.read(selectedPoiProvider.notifier).select(poi);
      }),
      interactionID: 'poi-tap',
    );
    map.addInteraction(
      TapInteraction(FeaturesetDescriptor(layerId: areaFillLayer), (feature, context) {
        final c = context.point.coordinates;
        if (_toolTap(c.lng.toDouble(), c.lat.toDouble())) return;
        HapticFeedback.selectionClick();
        // Opens the area in its panel (in the spot the other tools' panels use)
        ref.read(routePlannerProvider.notifier).disable();
        ref.read(navigatorProvider.notifier).close();
        ref.read(trackRecorderProvider.notifier).setPanelOpen(false);
        ref.read(areasProvider.notifier)
          ..select('${feature.properties['id']}')
          ..setPanelOpen(true);
      }),
      interactionID: 'area-tap',
    );
    map.addInteraction(
      TapInteraction(FeaturesetDescriptor(layerId: markedPointsLayer), (feature, context) {
        final c = context.point.coordinates;
        if (_toolTap(c.lng.toDouble(), c.lat.toDouble())) return;
        HapticFeedback.selectionClick();
        ref.read(markedProvider.notifier).toggle('${feature.properties['id']}');
      }),
      interactionID: 'marked-tap',
    );
    map.addInteraction(
      TapInteraction(FeaturesetDescriptor(layerId: poiClustersLayer), (feature, context) async {
        final c = context.point.coordinates;
        if (_toolTap(c.lng.toDouble(), c.lat.toDouble())) return;
        final zoom = (await map.getCameraState()).zoom;
        await map.easeTo(
          CameraOptions(center: context.point, zoom: math.min(zoom + 2, maxZoom)),
          MapAnimationOptions(duration: 500),
        );
      }),
      interactionID: 'poi-cluster-tap',
    );
    // Our own controls replace the built-in compass and scale bar
    await map.compass.updateSettings(CompassSettings(enabled: false));
    await map.scaleBar.updateSettings(ScaleBarSettings(enabled: false));
    await map.logo.updateSettings(LogoSettings(marginBottom: _ornamentMargin));
    await map.attribution.updateSettings(AttributionSettings(marginBottom: _ornamentMargin));
    await _applyView(s, animate: false);
    await _showPuckIfAllowed();
  }

  /// Terrain and sky are part of the style: added again after every style change
  Future<void> _onStyleLoaded(StyleLoadedEventData _) async {
    final map = _map;
    if (map == null) return;
    // Marker images are drawn at the screen's density
    final scale = MediaQuery.devicePixelRatioOf(context);
    try {
      if (!await map.styleSourceExists(terrainSourceId)) {
        await map.addStyleSource(
          terrainSourceId,
          jsonEncode({'type': 'raster-dem', 'url': terrainSourceUrl, 'tileSize': 512, 'maxzoom': 14}),
        );
      }
      await _applyTerrain(ref.read(mapSettingsProvider));
      final route = _route ??= RouteLayer(map);
      await route.install();
      await route.show(ref.read(routePlannerProvider));
      final layers = _layers ??= TerrainLayers(map);
      await layers.install(ref.read(mapSettingsProvider));
      final pois = _poiLayer ??= PoiLayer(map);
      await pois.install(ref.read(poisProvider).value ?? const [], visible: ref.read(mapSettingsProvider).showPois);
      final areas = _areaLayer ??= AreaLayer(map);
      await areas.install();
      await _showAreas();
      // Custom basemaps under the areas, markers and lines
      final basemaps = _basemapLayer ??= BasemapLayer(map);
      basemaps.reset();
      await basemaps.show(ref.read(basemapsProvider), below: areaFillLayer);
      final marked = _markedLayer ??= MarkedLayer(map, scale);
      await marked.install();
      await marked.show(ref.read(markedProvider));
      final link = _linkLayer ??= SharedLinkLayer(map);
      await link.install();
      await link.show(ref.read(sharedLinkProvider));
      final sos = _sosLayer ??= SosAlertsLayer(map);
      await sos.install();
      await sos.show(ref.read(sosAlertsProvider).active);
      final tracks = _tracks ??= TrackLayer(map);
      await tracks.install();
      await tracks.show(ref.read(trackRecorderProvider));
      // Survey lines come back after a style change, above the contours and grid
      _styleTick.value++;
      _scheduleSettled();
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

  // The map's own "idle" event does not reach Flutter on iOS (mapbox_maps_flutter 3.33), so
  // "settled" is 400 ms without a camera change
  Timer? _settle;

  void _scheduleSettled() {
    _settle?.cancel();
    _settle = Timer(const Duration(milliseconds: 400), _onSettled);
  }

  void _onSettled() {
    if (!mounted) return;
    unawaited(_updateElevation());
    _layers?.onMapIdle(ref.read(mapSettingsProvider));
  }

  // The coordinate card and the right-hand buttons fade while the map is still and come back
  // as soon as it moves or one of them is touched (S.O.S always stays)
  static const _chromeIdle = Duration(milliseconds: 2500);
  static const _chromeFaded = 0.3;
  bool _chromeAwake = true;
  Timer? _chromeTimer;

  void _wakeChrome() {
    if (!_chromeAwake) setState(() => _chromeAwake = true);
    _chromeTimer?.cancel();
    _chromeTimer = Timer(_chromeIdle, () {
      if (mounted) setState(() => _chromeAwake = false);
    });
  }

  /// [child] faded while the map is still; a touch on it wakes it (and still taps through)
  Widget _chrome({required Widget child, bool keepAwake = false}) {
    final awake = _chromeAwake || keepAwake;
    return Listener(
      onPointerDown: (_) => _wakeChrome(),
      child: AnimatedOpacity(
        opacity: awake ? 1 : _chromeFaded,
        duration: const Duration(milliseconds: 300),
        // No frosted blur while faded, so the map behind is really seen
        child: GlassBlur(enabled: awake, child: child),
      ),
    );
  }

  void _onCameraChanged(CameraChangedEventData e) {
    _wakeChrome();
    _cameraTick.value++;
    _scheduleSettled();
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
    ref.read(mapCenterProvider.notifier).set(lng, lat);
    ref.read(mapZoomProvider.notifier).set(c.zoom);
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
      _show('Location is off for Landscape 360 app. Allow it in Settings.');
    }
    return permission == geo.LocationPermission.whileInUse || permission == geo.LocationPermission.always;
  }

  bool _puckOn = false;
  LocationPuck? _puck;

  Future<LocationPuck> _webStylePuck() async {
    final scale = MediaQuery.devicePixelRatioOf(context);
    return _puck ??= LocationPuck(
      locationPuck2D: LocationPuck2D(
        topImage: await puckDot(scale),
        bearingImage: await puckBeam(scale),
        shadowImage: await puckRing(scale),
        // Drawn at the screen's scale; the map already shows them at that density, so no
        // scale expression (one made them a third of the size on iPhone)
      ),
    );
  }

  Future<void> _enablePuck() async {
    final map = _map;
    if (map == null) return;
    final puck = await _webStylePuck();
    _puckOn = true;
    await map.location.updateSettings(
      LocationComponentSettings(
        // Hidden while Classic is open: in a resection your position is the answer
        enabled: !ref.read(classicProvider).panelOpen,
        locationPuck: puck,
        showAccuracyRing: true,
        accuracyRingColor: 0x1AE46C24,
        accuracyRingBorderColor: 0x40E46C24,
        pulsingEnabled: true,
        pulsingColor: 0xFFE46C24,
        // The beam follows the top edge of the phone (compass); without a compass, the
        // direction of travel from the GPS, like the web
        puckBearingEnabled: true,
        puckBearing: _hasCompass == false ? PuckBearing.COURSE : PuckBearing.HEADING,
      ),
    );
  }

  /// With location already allowed: show the puck and open the map where the user is
  /// (not at the default Jakarta view), so "map centre" means their area too
  Future<void> _showPuckIfAllowed() async {
    if (!await _locationAllowed(ask: false)) return;
    await _enablePuck();
    try {
      final p =
          await geo.Geolocator.getLastKnownPosition() ??
          await geo.Geolocator.getCurrentPosition(
            locationSettings: const geo.LocationSettings(
              accuracy: geo.LocationAccuracy.medium,
              timeLimit: Duration(seconds: 6),
            ),
          );
      // Only if the user has not moved the map away from the start yet, and not when the
      // app was opened from a share link (the map shows the link's place)
      if (ref.read(sharedLinkProvider.notifier).openedFromLink) return;
      final c = (await _map?.getCameraState())?.center.coordinates;
      if (c == null || (c.lng - defaultCenter.lng).abs() > 1e-4 || (c.lat - defaultCenter.lat).abs() > 1e-4) return;
      await _map?.setCamera(CameraOptions(center: Point(coordinates: Position(p.longitude, p.latitude))));
    } on Object {
      // No fix yet: stay at the default view
    }
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

  /// Whole route in view, clear of the controls and the route panel (like fitBounds on the web)
  Future<void> _fitRoute(RouteResult r) async {
    final map = _map;
    if (map == null) return;
    final camera = await map.cameraForCoordinates(
      [for (final p in r.coordinates) Point(coordinates: Position(p.lng, p.lat))],
      MbxEdgeInsets(top: 140, left: 40, bottom: _sheetInset + 300, right: 80),
      null,
      null,
    );
    await map.flyTo(camera, MapAnimationOptions(duration: 800));
  }

  /// A saved track in view, clear of the controls and the panel (fitBounds, max zoom 16)
  Future<void> _fitTrack(List<TrackPoint> points) async {
    final map = _map;
    if (map == null || points.isEmpty) return;
    final camera = await map.cameraForCoordinates(
      [for (final p in points) Point(coordinates: Position(p.lng, p.lat))],
      MbxEdgeInsets(top: 140, left: 40, bottom: _sheetInset + 320, right: 80),
      null,
      null,
    );
    if ((camera.zoom ?? 0) > 16) camera.zoom = 16;
    await map.flyTo(camera, MapAnimationOptions(duration: 1200));
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
    ref.listen<RoutePlannerState>(routePlannerProvider, (prev, next) {
      unawaited(_route?.show(next));
      if (next.result != null && prev?.result != next.result) unawaited(_fitRoute(next.result!));
    });
    // The recording redraws at most once a second; a saved track at once, then the map fits it
    ref.listen<TrackRecorderState>(trackRecorderProvider, (prev, next) {
      if (prev?.viewing != next.viewing) {
        _trackRedraw?.cancel();
        _trackRedraw = null;
        unawaited(_tracks?.show(next));
        if (next.viewing != null) unawaited(_fitTrack(next.viewing!.points));
      } else if (prev?.activePoints != next.activePoints) {
        _trackRedraw ??= Timer(const Duration(seconds: 1), () {
          _trackRedraw = null;
          unawaited(_tracks?.show(ref.read(trackRecorderProvider)));
        });
      }
      // Recording shows where you are
      if (next.recording && !(prev?.recording ?? false) && !_puckOn) unawaited(_enablePuck());
    });
    ref.listen<SosAlertsState>(sosAlertsProvider, (_, next) => unawaited(_sosLayer?.show(next.active)));
    ref.listen(poisProvider, (_, next) {
      final list = next.value;
      if (list != null) unawaited(_poiLayer?.show(list));
    });
    ref.listen<SharedView?>(sharedLinkProvider, (_, next) => unawaited(_linkLayer?.show(next)));
    ref.listen<MarkedState>(markedProvider, (_, next) => unawaited(_markedLayer?.show(next)));
    ref.listen<AreasState>(areasProvider, (_, _) => unawaited(_showAreas()));
    ref.listen<BasemapsState>(
      basemapsProvider,
      (_, next) => unawaited(_basemapLayer?.show(next, below: areaFillLayer)),
    );
    ref.listen<SharedView?>(sharedLinkProvider, (_, _) => unawaited(_showAreas()));
    ref.listen<List<(double, double)>?>(fitPointsProvider, (_, points) {
      if (points == null || points.isEmpty || _map == null) return;
      ref.read(fitPointsProvider.notifier).done();
      unawaited(_fitPoints(points));
    });
    ref.listen<SurveyDoc?>(showSurveyProvider, (_, doc) {
      final b = doc?.bounds;
      if (b == null || _map == null) return;
      ref.read(showSurveyProvider.notifier).done();
      // Centre of the survey, close up (like the web)
      unawaited(
        _map!.flyTo(
          CameraOptions(
            center: Point(coordinates: Position((b.$1.$1 + b.$2.$1) / 2, (b.$1.$2 + b.$2.$2) / 2)),
            zoom: 16,
          ),
          MapAnimationOptions(duration: 2000),
        ),
      );
    });
    ref.listen<FlyTarget?>(flyToProvider, (_, target) {
      final map = _map;
      if (target == null || map == null) return;
      ref.read(flyToProvider.notifier).done();
      unawaited(
        map.flyTo(
          CameraOptions(
            center: Point(coordinates: Position(target.lng, target.lat)),
            zoom: target.zoom,
          ),
          MapAnimationOptions(duration: 1200),
        ),
      );
    });
    // The GPS dot hides while Classic is open (it would give a resection away) and comes back
    ref.listen<bool>(classicProvider.select((s) => s.panelOpen), (_, open) {
      final map = _map;
      if (map == null || !_puckOn) return;
      unawaited(map.location.updateSettings(LocationComponentSettings(enabled: !open)).catchError((Object _) {}));
    });
    ref.listen<MapSettings>(mapSettingsProvider, (prev, next) {
      final map = _map;
      if (map == null || prev == null) return;
      if (prev.style != next.style) unawaited(map.loadStyleURI(next.style.uri));
      if (prev.view != next.view) unawaited(_applyView(next));
      if (prev.exaggeration != next.exaggeration && next.is3D) unawaited(_applyTerrain(next));
      if (prev.showPois != next.showPois) {
        unawaited(_poiLayer?.setVisible(next.showPois));
        if (!next.showPois) ref.read(selectedPoiProvider.notifier).select(null);
      }
      final layers = _layers;
      if (layers != null &&
          (prev.showContours != next.showContours ||
              prev.contourInterval != next.contourInterval ||
              prev.contourOpacity != next.contourOpacity ||
              prev.showGrid != next.showGrid ||
              prev.gridOpacity != next.gridOpacity ||
              prev.gridStep != next.gridStep ||
              prev.appliedExaggeration != next.appliedExaggeration)) {
        unawaited(layers.apply(next).then((_) => layers.refresh(next)));
      }
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
        if (_map != null)
          Positioned.fill(
            child: NavigatorOverlay(
              map: _map!,
              cameraTick: _cameraTick,
              styleTick: _styleTick,
              elevationAt: _elevationAt,
            ),
          ),
        if (_map != null)
          Positioned.fill(
            child: ClassicOverlay(
              map: _map!,
              cameraTick: _cameraTick,
              styleTick: _styleTick,
              bottomInset: widget.sheetInset,
            ),
          ),
        Positioned(
          left: 12,
          top: top,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _chrome(
                // Opened for its details, it stays
                keepAwake: _telemetryOpen,
                child: TelemetryCard(
                  key: const Key('telemetry-card'),
                  telemetry: _telemetry,
                  format: settings.coordFormat,
                  onFormatChanged: ref.read(mapSettingsProvider.notifier).setCoordFormat,
                  expanded: _telemetryOpen,
                  onToggle: () => setState(() => _telemetryOpen = !_telemetryOpen),
                ),
              ),
              if (ref.watch(weatherShownProvider)) ...[
                const SizedBox(height: 10),
                WeatherCard(mapCenter: () => (lat: _telemetry.lat, lng: _telemetry.lng)),
              ],
            ],
          ),
        ),
        Positioned(
          right: 12,
          top: top,
          child: Column(
            children: [
              _chrome(
                child: Column(
                  key: const Key('map-buttons'),
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
                    const SizedBox(height: 10),
                    MapIconButton(
                      key: const Key('share-location'),
                      tooltip: 'Share Location',
                      onPressed: () => showShareLocationSheet(context, terrainAt: _terrainAt),
                      child: const Icon(Icons.share_location, color: L360Colors.forest700),
                    ),
                    const SizedBox(height: 10),
                    MapIconButton(
                      key: const Key('export-report'),
                      tooltip: 'Export report',
                      onPressed: () {
                        final map = _map;
                        if (map != null) unawaited(showReportExport(context, ref, map, MediaQuery.sizeOf(context)));
                      },
                      child: const Icon(Icons.photo_camera_outlined, color: L360Colors.forest700),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              const SosButton(),
            ],
          ),
        ),
        if (_showCalibrateHint)
          Positioned(
            left: 16,
            right: 16,
            bottom: _sheetInset + 12,
            child: Center(child: _CalibrateHint(onDismiss: _dismissHint)),
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

/// Small one-time hint while the compass looks off (same text as the web)
class _CalibrateHint extends StatelessWidget {
  const _CalibrateHint({required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => GlassPanel(
    key: const Key('calibrate-hint'),
    radius: 20,
    padding: const EdgeInsets.only(left: 12),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.explore_outlined, size: 16, color: L360Colors.ember600),
        const SizedBox(width: 6),
        const Text(
          'Compass off: move the phone in a figure 8',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: L360Colors.sand700),
        ),
        IconButton(
          tooltip: "Don't show this hint again",
          visualDensity: VisualDensity.compact,
          iconSize: 16,
          icon: const Icon(Icons.close, color: L360Colors.sand500),
          onPressed: onDismiss,
        ),
      ],
    ),
  );
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
