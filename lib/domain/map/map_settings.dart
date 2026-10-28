import 'dart:math' as math;

// Map settings and their defaults, the same as src/store/useMapStore.ts and
// MapBoxContainer.tsx (web).

enum MapStyle {
  outdoors('Outdoors', 'mapbox://styles/mapbox/outdoors-v12'),
  satellite('Satellite', 'mapbox://styles/mapbox/satellite-streets-v12'),
  streets('Streets', 'mapbox://styles/mapbox/streets-v12');

  const MapStyle(this.label, this.uri);

  final String label;
  final String uri;

  static MapStyle fromName(String? name) => values.firstWhere((s) => s.name == name, orElse: () => MapStyle.satellite);
}

enum MapView { twoD, threeD }

enum CoordFormat { dd, dms }

/// Terrain source of the web app (MapBoxContainer.tsx)
const terrainSourceId = 'mapbox-dem';
const terrainSourceUrl = 'mapbox://mapbox.mapbox-terrain-dem-v1';

const minZoom = 2.0;
const maxZoom = 20.0;
const maxPitch = 85.0;

/// Jakarta, where the web opens the first time
const defaultCenter = (lng: 106.8456, lat: -6.2088);
const defaultZoom = 14.0;

/// Pitch used when switching to 3D (the web keeps the last one)
const defaultPitch3D = 60.0;
const defaultExaggeration = 1.5;
const minExaggeration = 1.0;
const maxExaggeration = 3.0;

class MapSettings {
  const MapSettings({
    this.style = MapStyle.satellite,
    this.view = MapView.twoD,
    this.exaggeration = defaultExaggeration,
    this.coordFormat = CoordFormat.dd,
  });

  /// Reads saved settings; anything missing or invalid falls back to the default.
  /// The view always opens in 2D, as on the web.
  factory MapSettings.fromJson(Map<String, dynamic> j) {
    final ex = j['exaggeration'];
    return MapSettings(
      style: MapStyle.fromName(j['style'] as String?),
      exaggeration: ex is num ? ex.toDouble().clamp(minExaggeration, maxExaggeration) : defaultExaggeration,
      coordFormat: j['coordFormat'] == 'dms' ? CoordFormat.dms : CoordFormat.dd,
    );
  }

  final MapStyle style;
  final MapView view;
  final double exaggeration;
  final CoordFormat coordFormat;

  bool get is3D => view == MapView.threeD;

  /// Terrain exaggeration applied to the map: flat looking in 2D (1×, seen from straight
  /// above), the chosen factor in 3D. Terrain stays on in both so elevation can be read.
  double get appliedExaggeration => is3D ? exaggeration : 1.0;

  MapSettings copyWith({MapStyle? style, MapView? view, double? exaggeration, CoordFormat? coordFormat}) => MapSettings(
    style: style ?? this.style,
    view: view ?? this.view,
    exaggeration: exaggeration ?? this.exaggeration,
    coordFormat: coordFormat ?? this.coordFormat,
  );

  Map<String, dynamic> toJson() => {'style': style.name, 'exaggeration': exaggeration, 'coordFormat': coordFormat.name};
}

/// Terrain slope in degrees at a point, from its elevation and the elevations ~11 m east
/// ([eastM]) and ~11 m north ([northM]) of it: the steeper of the two, like the web's
/// telemetry panel (ControlPanel.tsx).
double terrainSlopeDegrees(double elevation, double eastM, double northM) {
  const dist = 11.132; // meters in 0.0001° of latitude
  final slope1 = math.atan((eastM - elevation) / dist);
  final slope2 = math.atan((northM - elevation) / dist);
  return math.max(slope1.abs(), slope2.abs()) * (180 / math.pi);
}

/// Offset in degrees used to sample the slope (same as the web)
const slopeSampleOffsetDeg = 0.0001;

/// Real elevation from the value the map reports, which includes the terrain exaggeration
double realElevation(double reported, double exaggeration) => exaggeration > 0 ? reported / exaggeration : reported;

/// Bearing shown in the telemetry: 0..360 (the map reports -180..180 on some platforms)
double normalizeBearing(double bearing) => (bearing.remainder(360) + 360).remainder(360);
