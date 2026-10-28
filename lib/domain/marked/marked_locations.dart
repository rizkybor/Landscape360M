import '../util/js_compat.dart';

// Port of src/utils/markedLocations.ts. Plan rules are enforced server-side by
// marked_location_limit() and can_share_marked_locations()
// (20261024000003_create_marked_locations.sql); these only shape the UI.

const markedLocationLimits = {'Free': 10, 'Pro': 100, 'Enterprise': 1000};
const maxTags = 10;
const maxTagLength = 30;

class MarkedLocationPolicy {
  const MarkedLocationPolicy({required this.canUse, required this.maxLocations, required this.canShare});

  final bool canUse;
  final int? maxLocations; // null = unlimited
  final bool canShare;

  @override
  bool operator ==(Object other) =>
      other is MarkedLocationPolicy &&
      other.canUse == canUse &&
      other.maxLocations == maxLocations &&
      other.canShare == canShare;

  @override
  int get hashCode => Object.hash(canUse, maxLocations, canShare);

  @override
  String toString() => 'MarkedLocationPolicy(canUse: $canUse, max: $maxLocations, share: $canShare)';
}

MarkedLocationPolicy getMarkedLocationPolicy({
  required bool hasUser,
  required String subscriptionStatus,
  required bool isAdmin,
}) {
  if (!hasUser) return const MarkedLocationPolicy(canUse: false, maxLocations: 0, canShare: false);
  if (isAdmin) return const MarkedLocationPolicy(canUse: true, maxLocations: null, canShare: true);
  return MarkedLocationPolicy(
    canUse: true,
    maxLocations: markedLocationLimits[subscriptionStatus] ?? markedLocationLimits['Free'],
    canShare: subscriptionStatus == 'Pro' || subscriptionStatus == 'Enterprise',
  );
}

enum MarkedLocationCategory {
  poi('Point of Interest', 0xFFD49B22),
  camp('Camp / Basecamp', 0xFF365B25),
  summit('Summit', 0xFF7C4A1E),
  water('Water Source', 0xFF2563EB),
  shelter('Shelter / Pos', 0xFF6B7280),
  viewpoint('Viewpoint', 0xFF0E7490),
  trailhead('Trailhead', 0xFFE46C24),
  hazard('Hazard', 0xFFB4302A),
  cave('Cave', 0xFF57534E),
  parking('Parking', 0xFF4338CA);

  const MarkedLocationCategory(this.label, this.color);

  final String label;
  final int color; // ARGB

  /// The category stored in the database (its name), or null when unknown
  static MarkedLocationCategory? fromName(String name) {
    for (final c in values) {
      if (c.name == name) return c;
    }
    return null;
  }
}

/// "basecamp, water,  Basecamp" -> ["basecamp", "water"]
List<String> parseTags(String value) {
  final seen = <String>{};
  final tags = <String>[];
  for (final raw in value.split(',')) {
    final trimmed = raw.trim();
    final tag = _sliceUtf16(trimmed, maxTagLength);
    final key = tag.toLowerCase();
    if (tag.isEmpty || seen.contains(key)) continue;
    seen.add(key);
    tags.add(tag);
    if (tags.length == maxTags) break;
  }
  return tags;
}

// String.prototype.slice counts UTF-16 code units, as Dart strings do
String _sliceUtf16(String s, int n) => s.length <= n ? s : s.substring(0, n);

bool isValidCoordinate(double lng, double lat) =>
    lng.isFinite && lat.isFinite && lng >= -180 && lng <= 180 && lat >= -90 && lat <= 90;

String formatLatLng(double lat, double lng) => '${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}';

String directionsUrl(double lat, double lng) =>
    'https://www.google.com/maps/dir/?api=1&destination=${jsNum(lat)},${jsNum(lng)}';

class MarkedLocationGpx {
  const MarkedLocationGpx({
    required this.name,
    required this.category,
    required this.lat,
    required this.lng,
    this.elevationM,
    this.description,
    this.address,
    this.contact,
    this.tags = const [],
  });

  final String name;
  final String category; // database value; unknown values are written as is
  final double lat;
  final double lng;
  final double? elevationM;
  final String? description;
  final String? address;
  final String? contact;
  final List<String> tags;
}

String _escapeXml(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

bool _present(String? s) => s != null && s.isNotEmpty;

/// GPX 1.1 waypoints, readable by Garmin, OsmAnd, Avenza and most GPS apps
String markedLocationsToGpx(List<MarkedLocationGpx> locations) {
  final waypoints = locations
      .map((l) {
        final desc = [
          if (_present(l.description)) l.description!,
          if (_present(l.address)) l.address!,
          if (_present(l.contact)) 'Contact: ${l.contact}',
          if (l.tags.isNotEmpty) 'Tags: ${l.tags.join(', ')}',
        ].join('\n');
        final type = MarkedLocationCategory.fromName(l.category)?.label ?? l.category;
        return [
          '  <wpt lat="${jsNum(l.lat)}" lon="${jsNum(l.lng)}">',
          if (l.elevationM != null) '    <ele>${l.elevationM!.toStringAsFixed(1)}</ele>',
          '    <name>${_escapeXml(l.name)}</name>',
          if (desc.isNotEmpty) '    <desc>${_escapeXml(desc)}</desc>',
          '    <type>${_escapeXml(type)}</type>',
          '  </wpt>',
        ].join('\n');
      })
      .join('\n');

  return '''<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="Landscape360" xmlns="http://www.topografix.com/GPX/1/1">
$waypoints
</gpx>
''';
}
