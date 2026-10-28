// Route planner, port of src/store/useRouteStore.ts and RoutePlannerLayer.tsx (web): tap a
// start and a destination on the map, the route comes from the Mapbox Directions API.

typedef RoutePoint = ({double lng, double lat});

enum RouteMode {
  drivingToll('driving_toll', 'Vehicle', 'Via toll', 0xFFE46C24),
  drivingNoToll('driving_no_toll', 'Vehicle', 'No toll', 0xFFD49B22),
  walking('walking', 'Walk', 'Footpath', 0xFF22C55E);

  const RouteMode(this.id, this.label, this.hint, this.color);

  final String id; // as the web names it
  final String label;
  final String hint;
  final int color; // route line (ARGB), vivid enough for satellite imagery

  String get profile => this == walking ? 'walking' : 'driving';
}

/// Directions API request, same parameters as the web
Uri directionsUrl({
  required String token,
  required RouteMode mode,
  required RoutePoint start,
  required RoutePoint end,
}) {
  String coord(RoutePoint p) => '${p.lng},${p.lat}';
  return Uri.https('api.mapbox.com', '/directions/v5/mapbox/${mode.profile}/${coord(start)};${coord(end)}', {
    'geometries': 'geojson',
    'overview': 'full',
    'alternatives': 'false',
    'steps': 'false',
    if (mode == RouteMode.drivingNoToll) 'exclude': 'toll',
    'access_token': token,
  });
}

class RouteResult {
  const RouteResult({required this.coordinates, required this.distanceM, required this.durationS});

  final List<RoutePoint> coordinates;
  final double distanceM;
  final double durationS;
}

class RouteException implements Exception {
  const RouteException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// First route of a Directions response; throws when there is none (web: "Rute tidak ditemukan.")
RouteResult parseDirections(Object? json) {
  final routes = json is Map ? json['routes'] : null;
  final route = routes is List && routes.isNotEmpty ? routes.first : null;
  final geometry = route is Map ? route['geometry'] : null;
  final coords = geometry is Map ? geometry['coordinates'] : null;
  if (coords is! List || coords.length < 2) throw const RouteException('Rute tidak ditemukan.');
  final points = [
    for (final c in coords)
      if (c is List && c.length >= 2 && c[0] is num && c[1] is num)
        (lng: (c[0] as num).toDouble(), lat: (c[1] as num).toDouble()),
  ];
  if (points.length < 2) throw const RouteException('Rute tidak ditemukan.');
  final distance = (route as Map)['distance'];
  final duration = route['duration'];
  return RouteResult(
    coordinates: points,
    distanceM: distance is num ? distance.toDouble() : 0,
    durationS: duration is num ? duration.toDouble() : 0,
  );
}

/// "12.34" (km, 2 decimals)
String formatRouteKm(double meters) => (meters / 1000).toStringAsFixed(2);

/// "1 h 5 min" or "25 min" (at least 1 min)
String formatRouteDuration(double seconds) {
  final totalMin = (seconds / 60).round() < 1 ? 1 : (seconds / 60).round();
  final h = totalMin ~/ 60;
  final m = totalMin % 60;
  return h > 0 ? '$h h $m min' : '$m min';
}

/// "6.2088° S, 106.8456° E"
String formatRoutePoint(RoutePoint p) =>
    '${p.lat.abs().toStringAsFixed(4)}° ${p.lat < 0 ? 'S' : 'N'}, ${p.lng.abs().toStringAsFixed(4)}° ${p.lng < 0 ? 'W' : 'E'}';

/// Where the planner is: which point the next map tap sets
class RouteDraft {
  const RouteDraft({this.start, this.end});

  final RoutePoint? start;
  final RoutePoint? end;

  /// Tap on the map: start, then destination, then a new route from the tapped point
  RouteDraft tap(RoutePoint p) => start == null
      ? RouteDraft(start: p)
      : end == null
      ? RouteDraft(start: start, end: p)
      : RouteDraft(start: p);

  RouteDraft swapped() => RouteDraft(start: end, end: start);

  bool get complete => start != null && end != null;
}
