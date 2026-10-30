import '../geo/spherical.dart' show LngLat;
import 'classic_nav.dart';

// Classic's data (useClassicStore.ts on the web). Everything is typed by hand, so the raw
// fields are the state and positions and bearings are worked out from them (solveClassic).
// The JSON is the web's own, so a Field Work shared from the app opens on the website and
// the other way round.

enum ClassicMode {
  resection,
  intersection;

  static ClassicMode parse(Object? v) => v == 'intersection' ? intersection : resection;
}

const minSightings = 2;
const maxSightings = 6;

class PointInput {
  const PointInput({this.lat = const DmsInput(), this.lng = const DmsInput(), this.south = true, this.west = false});

  factory PointInput.fromJson(Map<String, dynamic>? j) => PointInput(
    lat: DmsInput.fromJson(_map(j?['lat'])),
    lng: DmsInput.fromJson(_map(j?['lng'])),
    south: j?['south'] as bool? ?? true,
    west: j?['west'] as bool? ?? false,
  );

  /// A point picked on the map
  factory PointInput.of(LngLat p) =>
      PointInput(lat: toDmsInput(p.$2), lng: toDmsInput(p.$1), south: p.$2 < 0, west: p.$1 < 0);

  final DmsInput lat;
  final DmsInput lng;
  final bool south;
  final bool west;

  PointInput copyWith({DmsInput? lat, DmsInput? lng, bool? south, bool? west}) =>
      PointInput(lat: lat ?? this.lat, lng: lng ?? this.lng, south: south ?? this.south, west: west ?? this.west);

  Map<String, Object> toJson() => {'lat': lat.toJson(), 'lng': lng.toJson(), 'south': south, 'west': west};
}

class Sighting {
  const Sighting({
    this.point = const PointInput(),
    this.azimuth = '',
    this.back = '',
    this.azChecks = 0,
    this.backChecks = 0,
  });

  factory Sighting.fromJson(Map<String, dynamic> j) => Sighting(
    point: PointInput.fromJson(_map(j['point'])),
    azimuth: '${j['azimuth'] ?? ''}',
    back: '${j['back'] ?? ''}',
    azChecks: (j['azChecks'] as num? ?? 0).toInt(),
    backChecks: (j['backChecks'] as num? ?? 0).toInt(),
  );

  final PointInput point;
  final String azimuth; // compass degrees 0–360, as typed
  final String back;

  /// Times "Check" was pressed: hints show from the first, the answer from the second
  final int azChecks;
  final int backChecks;

  Sighting copyWith({PointInput? point, String? azimuth, String? back, int? azChecks, int? backChecks}) => Sighting(
    point: point ?? this.point,
    azimuth: azimuth ?? this.azimuth,
    back: back ?? this.back,
    azChecks: azChecks ?? this.azChecks,
    backChecks: backChecks ?? this.backChecks,
  );

  Map<String, Object> toJson() => {
    'point': point.toJson(),
    'azimuth': azimuth,
    'back': back,
    'azChecks': azChecks,
    'backChecks': backChecks,
  };
}

Map<String, dynamic>? _map(Object? v) => v is Map ? Map<String, dynamic>.from(v) : null;

/// What one Field Work holds
class FieldWorkData {
  const FieldWorkData({
    this.sightings = const [Sighting(), Sighting()],
    this.origin = const PointInput(),
    this.lineLengths = const {},
  });

  factory FieldWorkData.fromJson(Map<String, dynamic> j) => FieldWorkData(
    sightings: [
      for (final s in (j['sightings'] as List? ?? const []).whereType<Map<dynamic, dynamic>>())
        Sighting.fromJson(Map<String, dynamic>.from(s)),
    ],
    origin: PointInput.fromJson(_map(j['origin'])),
    lineLengths: {
      for (final MapEntry(:key, :value) in (_map(j['lineLengths']) ?? const {}).entries)
        if (value is num) key: value.toDouble(),
    },
  );

  final List<Sighting> sightings;

  /// Resection: your position on the map, set once; every point's bearings start from it
  final PointInput origin;

  /// Line lengths set by hand on the map (metres), by `sighting:main` or `sighting:back`
  final Map<String, double> lineLengths;

  Map<String, Object> toJson() => {
    'sightings': [for (final s in sightings) s.toJson()],
    'origin': origin.toJson(),
    'lineLengths': lineLengths,
  };
}

class FieldWork {
  const FieldWork({required this.id, required this.name, this.data = const FieldWorkData(), this.shareToken});

  factory FieldWork.fromJson(Map<String, dynamic> j) => FieldWork(
    id: '${j['id']}',
    name: '${j['name'] ?? 'Field Work'}',
    data: FieldWorkData.fromJson(j),
    shareToken: j['shareToken'] as String?,
  );

  final String id;
  final String name;
  final FieldWorkData data;

  /// Set while the Field Work is shared as a link (the link always shows the latest version)
  final String? shareToken;

  FieldWork copyWith({String? name, FieldWorkData? data, String? Function()? shareToken}) => FieldWork(
    id: id,
    name: name ?? this.name,
    data: data ?? this.data,
    shareToken: shareToken == null ? this.shareToken : shareToken(),
  );

  Map<String, Object?> toJson() => {'id': id, 'name': name, ...data.toJson(), 'shareToken': shareToken};
}

/// A Field Work someone shared, opened from its link to look at (read only)
class ViewedFieldWork {
  const ViewedFieldWork({
    required this.token,
    required this.mode,
    required this.name,
    required this.data,
    required this.declination,
    this.ownerName,
    required this.updatedAt,
  });

  final String token;
  final ClassicMode mode;
  final String name;
  final FieldWorkData data;
  final String declination;
  final String? ownerName;
  final DateTime updatedAt;
}

/// Field Works per mode: Free and guests 1, Pro 5, Enterprise 10, admin unlimited (null)
int? fieldWorkLimit({required bool hasUser, required String subscriptionStatus, required bool isAdmin}) {
  if (!hasUser) return 1;
  if (isAdmin) return null;
  return switch (subscriptionStatus) {
    'Pro' => 5,
    'Enterprise' => 10,
    _ => 1,
  };
}

/// "Field Work 1, 2, 3…": one past the highest number used
String nextFieldWorkName(Iterable<FieldWork> list) {
  var n = 0;
  for (final f in list) {
    final m = RegExp(r'^Field Work (\d+)$').firstMatch(f.name);
    if (m != null) n = n > int.parse(m.group(1)!) ? n : int.parse(m.group(1)!);
  }
  return 'Field Work ${n + 1}';
}
