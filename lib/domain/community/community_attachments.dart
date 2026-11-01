import '../geo/spherical.dart';

// Map data attached to a post (src/lib/community.ts): a copy (snapshot) of the author's
// marked location, marked area or recorded track, so it still shows when the original is
// changed or deleted; a Classic Field Work goes by its share link. Pro, Enterprise and the
// admin only (create_community_post checks).

const maxTrackPoints = 1500;

double _r6(double v) => (v * 1e6).round() / 1e6;

List<double> _xy(LngLat p) => [_r6(p.$1), _r6(p.$2)];

LngLat _pt(Object? raw) {
  final l = raw! as List;
  return ((l[0] as num).toDouble(), (l[1] as num).toDouble());
}

List<LngLat> _line(Object? raw) => [for (final p in (raw as List? ?? const [])) _pt(p)];

sealed class Attachment {
  const Attachment(this.name);

  /// Reads the snapshot stored with a post; null when it is not one this app knows
  static Attachment? fromJson(Map<String, dynamic> j) {
    final name = '${j['name'] ?? ''}';
    final geometry = j['geometry'] is Map ? Map<String, dynamic>.from(j['geometry'] as Map) : const <String, dynamic>{};
    try {
      return switch (j['kind']) {
        'place' => PlaceAttachment(
          name: name,
          category: '${j['category'] ?? 'poi'}',
          point: _pt(geometry['coordinates']),
        ),
        'area' => AreaAttachment(
          name: name,
          color: '${j['color'] ?? '#d49b22'}',
          ring: _line((geometry['coordinates'] as List? ?? const [[]]).first),
        ),
        'track' => TrackAttachment(
          name: name,
          distanceM: (j['distance_m'] as num? ?? 0).toDouble(),
          line: _line(geometry['coordinates']),
        ),
        'classic' => ClassicAttachment(name: name, token: '${j['token'] ?? ''}'),
        _ => null,
      };
    } on Object {
      return null;
    }
  }

  final String name;

  String get kind;

  /// What kind of map data, for the post
  String get label;

  Map<String, dynamic> toJson();

  /// Where it is, to draw it and to fit the map (none for a Field Work link)
  List<LngLat> get coords;

  /// Middle of its points, for the post's location
  LngLat? get center {
    final c = coords;
    if (c.isEmpty) return null;
    var w = c.first.$1, e = w, s = c.first.$2, n = s;
    for (final (x, y) in c) {
      if (x < w) w = x;
      if (x > e) e = x;
      if (y < s) s = y;
      if (y > n) n = y;
    }
    return ((w + e) / 2, (s + n) / 2);
  }
}

class PlaceAttachment extends Attachment {
  const PlaceAttachment({required String name, required this.category, required this.point}) : super(name);

  final String category; // marked location category name
  final LngLat point;

  @override
  String get kind => 'place';

  @override
  String get label => 'Marked location';

  @override
  List<LngLat> get coords => [point];

  @override
  Map<String, dynamic> toJson() => {
    'kind': kind,
    'name': name,
    'category': category,
    'geometry': {'type': 'Point', 'coordinates': _xy(point)},
  };
}

class AreaAttachment extends Attachment {
  const AreaAttachment({required String name, required this.color, required this.ring}) : super(name);

  final String color; // #rrggbb
  final List<LngLat> ring; // closed (first point again at the end)

  @override
  String get kind => 'area';

  @override
  String get label => 'Marked area';

  @override
  List<LngLat> get coords => ring;

  @override
  Map<String, dynamic> toJson() => {
    'kind': kind,
    'name': name,
    'color': color,
    'geometry': {
      'type': 'Polygon',
      'coordinates': [
        [for (final p in ring) _xy(p)],
      ],
    },
  };
}

class TrackAttachment extends Attachment {
  const TrackAttachment({required String name, required this.distanceM, required this.line}) : super(name);

  final double distanceM;
  final List<LngLat> line;

  @override
  String get kind => 'track';

  @override
  String get label => 'Recorded track';

  @override
  List<LngLat> get coords => line;

  @override
  Map<String, dynamic> toJson() => {
    'kind': kind,
    'name': name,
    'distance_m': distanceM.round(),
    'geometry': {
      'type': 'LineString',
      'coordinates': [for (final p in line) _xy(p)],
    },
  };
}

class ClassicAttachment extends Attachment {
  const ClassicAttachment({required String name, required this.token}) : super(name);

  final String token; // share link token (32 hex)

  @override
  String get kind => 'classic';

  @override
  String get label => 'Classic Field Work';

  @override
  List<LngLat> get coords => const [];

  @override
  Map<String, dynamic> toJson() => {'kind': kind, 'name': name, 'token': token};
}

// --- Snapshots of the user's own map data --------------------------------------------------------

/// Evenly thins a line to at most [max] points, keeping the first and last (same picks as
/// thinLine on the web)
List<LngLat> thinLine(List<LngLat> coords, [int max = maxTrackPoints]) {
  if (coords.length <= max) return coords;
  final step = (coords.length - 1) / (max - 1);
  // Math.round on the web: halves go up
  return [for (var i = 0; i < max; i++) coords[(i * step + 0.5).floor()]];
}

PlaceAttachment placeAttachment({
  required String name,
  required String category,
  required double lat,
  required double lng,
}) => PlaceAttachment(name: name, category: category, point: (_r6(lng), _r6(lat)));

/// [ring] as drawn (not closed); the snapshot closes it
AreaAttachment areaAttachment({required String name, required String color, required List<LngLat> ring}) =>
    AreaAttachment(
      name: name,
      color: color,
      ring: [
        for (final p in [...ring, if (ring.isNotEmpty && ring.first != ring.last) ring.first]) (_r6(p.$1), _r6(p.$2)),
      ],
    );

/// [points] as (lng, lat), thinned to [maxPoints] (1500 on a post, 5000 in a club workspace)
TrackAttachment trackAttachment({
  required String name,
  required double distanceM,
  required List<LngLat> points,
  int maxPoints = maxTrackPoints,
}) => TrackAttachment(
  name: name,
  distanceM: distanceM.roundToDouble(),
  line: [for (final p in thinLine(points, maxPoints)) (_r6(p.$1), _r6(p.$2))],
);

final _token = RegExp(r'^[0-9a-f]{32}$');

/// A shared Field Work; null when [token] is not a share link token
ClassicAttachment? classicAttachment({required String name, required String? token}) =>
    token != null && _token.hasMatch(token) ? ClassicAttachment(name: name, token: token) : null;
