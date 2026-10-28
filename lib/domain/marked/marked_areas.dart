import 'dart:math' as math;

import '../geo/spherical.dart';
import '../survey/survey_utils.dart';
import '../util/js_compat.dart';

// Port of src/utils/markedAreas.ts. Plan rules are enforced server-side by
// marked_area_limit() (20261026000019_marked_areas.sql).

const areaLimits = {'Free': 5, 'Pro': 10, 'Enterprise': 20};

class MarkedAreaPolicy {
  const MarkedAreaPolicy({required this.canUse, required this.limit, required this.canShare});

  final bool canUse;
  final int? limit; // null = unlimited
  final bool canShare;

  @override
  bool operator ==(Object other) =>
      other is MarkedAreaPolicy && other.canUse == canUse && other.limit == limit && other.canShare == canShare;

  @override
  int get hashCode => Object.hash(canUse, limit, canShare);

  @override
  String toString() => 'MarkedAreaPolicy(canUse: $canUse, limit: $limit, share: $canShare)';
}

MarkedAreaPolicy getMarkedAreaPolicy({
  required bool hasUser,
  required String subscriptionStatus,
  required bool isAdmin,
}) {
  if (!hasUser) return const MarkedAreaPolicy(canUse: false, limit: 0, canShare: false);
  if (isAdmin) return const MarkedAreaPolicy(canUse: true, limit: null, canShare: true);
  return MarkedAreaPolicy(
    canUse: true,
    limit: areaLimits[subscriptionStatus] ?? areaLimits['Free'],
    canShare: subscriptionStatus == 'Pro' || subscriptionStatus == 'Enterprise',
  );
}

/// Outline colours to pick from (brand palette plus a few that stand out on satellite)
const areaColors = ['#d49b22', '#365b25', '#2563eb', '#b4302a', '#e46c24', '#7c3aed', '#0e7490', '#ffffff'];

List<LngLat> _closed(List<LngLat> ring) => [...ring, ring.first];

/// Area in m² on the sphere (same as turf.area on the web)
double ringArea(List<LngLat> ring) => ring.length < 3 ? 0 : turfPolygonArea([_closed(ring)]);

/// Perimeter in meters, each side measured on the WGS84 ellipsoid (like Navigator)
double ringPerimeter(List<LngLat> ring) {
  if (ring.length < 2) return 0;
  final pts = ring.length >= 3 ? _closed(ring) : ring;
  var total = 0.0;
  for (var i = 1; i < pts.length; i++) {
    total += geodesicInverse(pts[i - 1].$2, pts[i - 1].$1, pts[i].$2, pts[i].$1).distance;
  }
  return total;
}

String formatArea(double m2) => m2 >= 1000000
    ? '${(m2 / 1000000).toStringAsFixed(2)} km²'
    : m2 >= 10000
    ? '${(m2 / 10000).toStringAsFixed(2)} ha'
    : '${jsRoundStr(m2)} m²';

String formatLength(double m) => m >= 1000 ? '${(m / 1000).toStringAsFixed(2)} km' : '${m.toStringAsFixed(1)} m';

/// ((west, south), (east, north)) around the ring
(LngLat, LngLat) ringBounds(List<LngLat> ring) {
  final lngs = ring.map((p) => p.$1);
  final lats = ring.map((p) => p.$2);
  return ((lngs.reduce(math.min), lats.reduce(math.min)), (lngs.reduce(math.max), lats.reduce(math.max)));
}

/// Rough middle of the ring, for its name label
LngLat ringCenter(List<LngLat> ring) {
  final ((w, s), (e, n)) = ringBounds(ring);
  return ((w + e) / 2, (s + n) / 2);
}

/// GeoJSON polygon feature of the area
Map<String, dynamic> areaFeature(List<LngLat> ring, [Map<String, dynamic> properties = const {}]) => {
  'type': 'Feature',
  'properties': properties,
  'geometry': {
    'type': 'Polygon',
    'coordinates': [_toJson(_closed(ring))],
  },
};

List<List<double>> _toJson(List<LngLat> ring) => [
  for (final p in ring) [p.$1, p.$2],
];

/// Rings of the focus mask: the whole world with the area cut out as a hole, so only the
/// area stays bright. The hole runs the other way round from the outer ring.
List<List<LngLat>> focusMaskRings(List<LngLat> ring) {
  const world = <LngLat>[(-180, -85), (180, -85), (180, 85), (-180, 85), (-180, -85)];
  final hole = _closed(ring);
  // Signed area (shoelace): make the hole clockwise when the world ring is counter-clockwise
  var signed = 0.0;
  for (var i = 1; i < hole.length; i++) {
    signed += hole[i - 1].$1 * hole[i].$2 - hole[i].$1 * hole[i - 1].$2;
  }
  return [world, signed > 0 ? hole.reversed.toList() : hole];
}

/// GeoJSON feature of [focusMaskRings]
Map<String, dynamic> focusMask(List<LngLat> ring) => {
  'type': 'Feature',
  'properties': <String, dynamic>{},
  'geometry': {
    'type': 'Polygon',
    'coordinates': [for (final r in focusMaskRings(ring)) _toJson(r)],
  },
};

/// First problem with the area form, or null
String? areaInputError({required String name, required List<LngLat> ring}) {
  if (name.trim().isEmpty) return 'Give the area a name';
  if (ring.length < 3) return 'Draw at least 3 points';
  if (ring.length > 500) return 'An area can have at most 500 points';
  return null;
}
