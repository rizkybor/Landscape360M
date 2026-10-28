import 'dart:math' as math;

// Spherical helpers, ported operation by operation from @turf/turf (bearing, distance,
// destination, area) as the web app uses them, so results match to the last digit.

/// [lng, lat]
typedef LngLat = (double, double);

const double turfEarthRadius = 6371008.8;

double _degToRad(double deg) => deg.remainder(360) * math.pi / 180;
double _radToDeg(double rad) => rad.remainder(2 * math.pi) * 180 / math.pi;

/// turf.bearing: -180..180 degrees from north
double turfBearing(LngLat start, LngLat end) {
  final lon1 = _degToRad(start.$1);
  final lon2 = _degToRad(end.$1);
  final lat1 = _degToRad(start.$2);
  final lat2 = _degToRad(end.$2);
  final a = math.sin(lon2 - lon1) * math.cos(lat2);
  final b = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(lon2 - lon1);
  return _radToDeg(math.atan2(a, b));
}

/// turf.bearing(start, end, { final: true })
double turfFinalBearing(LngLat start, LngLat end) => (turfBearing(end, start) + 180).remainder(360);

/// turf.distance in meters
double turfDistance(LngLat from, LngLat to) {
  final dLat = _degToRad(to.$2 - from.$2);
  final dLon = _degToRad(to.$1 - from.$1);
  final lat1 = _degToRad(from.$2);
  final lat2 = _degToRad(to.$2);
  final a = math.pow(math.sin(dLat / 2), 2) + math.pow(math.sin(dLon / 2), 2) * math.cos(lat1) * math.cos(lat2);
  return 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a)) * turfEarthRadius;
}

/// turf.destination with the distance in meters
LngLat turfDestination(LngLat origin, double meters, double bearing) {
  final longitude1 = _degToRad(origin.$1);
  final latitude1 = _degToRad(origin.$2);
  final bearingRad = _degToRad(bearing);
  final radians = meters / turfEarthRadius;
  final latitude2 = math.asin(
    math.sin(latitude1) * math.cos(radians) + math.cos(latitude1) * math.sin(radians) * math.cos(bearingRad),
  );
  final longitude2 =
      longitude1 +
      math.atan2(
        math.sin(bearingRad) * math.sin(radians) * math.cos(latitude1),
        math.cos(radians) - math.sin(latitude1) * math.sin(latitude2),
      );
  return (_radToDeg(longitude2), _radToDeg(latitude2));
}

/// Signed area of one closed ring (turf's ringArea), in m²
double _turfRingArea(List<LngLat> coords) {
  final n = coords.length - 1;
  if (n <= 2) return 0;
  const factor = turfEarthRadius * turfEarthRadius / 2;
  const piOver180 = math.pi / 180;
  var total = 0.0;
  for (var i = 0; i < n; i++) {
    final lower = coords[i];
    final middle = coords[i + 1 == n ? 0 : i + 1];
    final upper = coords[i + 2 >= n ? (i + 2) % n : i + 2];
    total += (upper.$1 * piOver180 - lower.$1 * piOver180) * math.sin(middle.$2 * piOver180);
  }
  return total * factor;
}

/// turf.area of a polygon given as closed rings (outer first, then holes), in m²
double turfPolygonArea(List<List<LngLat>> rings) {
  if (rings.isEmpty) return 0;
  var total = _turfRingArea(rings.first).abs();
  for (var i = 1; i < rings.length; i++) {
    total -= _turfRingArea(rings[i]).abs();
  }
  return total;
}
