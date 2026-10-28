import 'dart:math' as math;

// Offline maps, the web's rules (RegionDrawingOverlay.tsx, src/utils/tileUtils.ts) and the
// server's (check_offline_map_limits(), 20261023000000): the zoom levels a download takes,
// its tile count and estimated size, and how many and how big per plan.

class OfflineBounds {
  const OfflineBounds({required this.west, required this.south, required this.east, required this.north});

  factory OfflineBounds.fromJson(Map<String, dynamic> j) => OfflineBounds(
    west: (j['west'] as num).toDouble(),
    south: (j['south'] as num).toDouble(),
    east: (j['east'] as num).toDouble(),
    north: (j['north'] as num).toDouble(),
  );

  /// Around the given corners
  factory OfflineBounds.around(List<(double, double)> lngLats) => OfflineBounds(
    west: lngLats.map((p) => p.$1).reduce(math.min),
    south: lngLats.map((p) => p.$2).reduce(math.min),
    east: lngLats.map((p) => p.$1).reduce(math.max),
    north: lngLats.map((p) => p.$2).reduce(math.max),
  );

  final double west;
  final double south;
  final double east;
  final double north;

  (double, double) get center => ((west + east) / 2, (south + north) / 2);

  /// The four corners, closed (for a polygon)
  List<(double, double)> get ring => [(west, south), (east, south), (east, north), (west, north), (west, south)];

  Map<String, double> toJson() => {'north': north, 'south': south, 'east': east, 'west': west};
}

int _lng2tile(double lng, int z) => ((lng + 180) / 360 * math.pow(2, z)).floor();

int _lat2tile(double lat, int z) {
  final r = lat * math.pi / 180;
  return ((1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2 * math.pow(2, z)).floor();
}

/// Number of map tiles covering the bounds for every zoom level (getTilesInBounds)
int tileCount(OfflineBounds b, int minZoom, int maxZoom) {
  var n = 0;
  for (var z = minZoom; z <= maxZoom; z++) {
    final xs = _lng2tile(b.east, z) - _lng2tile(b.west, z) + 1;
    final ys = _lat2tile(b.south, z) - _lat2tile(b.north, z) + 1;
    n += math.max(0, xs) * math.max(0, ys);
  }
  return n;
}

/// The current zoom level and two deeper, at most 16
(int, int) offlineZoomRange(double zoom) {
  final min = zoom.floor();
  return (min, math.min(min + 2, 16));
}

/// Estimated MB like the web: satellite + elevation ≈ 50 KB a tile, map (vector) ≈ 20 KB
double estimateOfflineMb(int tiles, {required bool satellite, required bool map}) {
  final perTile = (satellite ? 0.05 : 0) + (map ? 0.02 : 0);
  return double.parse((tiles * perTile).toStringAsFixed(2));
}

/// Maps allowed and the largest download in MB per plan (admins count as Enterprise)
({int count, double sizeMb}) offlineLimits(String plan, {bool isAdmin = false}) =>
    switch (isAdmin ? 'Enterprise' : plan) {
      'Enterprise' => (count: 10, sizeMb: 25.0),
      'Pro' => (count: 3, sizeMb: 10.0),
      _ => (count: 1, sizeMb: 1.0),
    };

/// Why a download is not allowed, or null
String? offlineLimitError({
  required String plan,
  required bool isAdmin,
  required int existing,
  required double sizeMb,
}) {
  final limits = offlineLimits(plan, isAdmin: isAdmin);
  final tier = isAdmin ? 'Enterprise' : plan;
  if (existing >= limits.count) {
    return 'You have reached the maximum number of offline maps (${limits.count}) for $tier plan.';
  }
  if (sizeMb > limits.sizeMb) {
    return 'This area (${sizeMb.toStringAsFixed(2)} MB) is larger than the ${limits.sizeMb.toStringAsFixed(0)} MB '
        'limit of $tier plan. Zoom in or pick a smaller area.';
  }
  return null;
}
