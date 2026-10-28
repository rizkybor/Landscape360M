import 'dart:math' as math;

import '../account/profile.dart';
import '../geo/spherical.dart';
import 'survey_utils.dart';

// Navigator surveys, port of src/store/useSurveyStore.ts (web). The JSON is exactly what the
// web saves in surveys.data, so a survey drawn on one opens the same on the other:
// [{ id, name, color, points: [{ id, lng, lat, elevation, name?, corner?, handle? }] }]
// Optional fields are left out, never written as null.

/// Sheet colours, in the web's order
const surveyColors = ['#FFD700', '#00FF7F', '#00BFFF', '#FF69B4', '#FFA500'];

/// Angle snap of the straight mode: 0 = free angle
const angleSteps = [0, 15, 45, 90];

final _random = math.Random.secure();

/// Random UUID v4 (the web uses crypto.randomUUID)
String newUuid() {
  final b = List<int>.generate(16, (_) => _random.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

double _num(Object? v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;

/// Whole numbers written without ".0", as JavaScript does
num _out(double v) => v == v.truncateToDouble() && v.abs() < 1e15 ? v.toInt() : v;

class SurveyPoint {
  const SurveyPoint({
    required this.id,
    required this.lng,
    required this.lat,
    required this.elevation,
    this.name,
    this.corner,
    this.handle,
  });

  factory SurveyPoint.fromJson(Map<String, dynamic> j) {
    final h = j['handle'];
    return SurveyPoint(
      id: '${j['id']}',
      lng: _num(j['lng']),
      lat: _num(j['lat']),
      elevation: _num(j['elevation']),
      name: j['name'] is String && (j['name'] as String).isNotEmpty ? j['name'] as String : null,
      corner: j['corner'] == 'sharp'
          ? PointCorner.sharp
          : j['corner'] == 'smooth'
          ? PointCorner.smooth
          : null,
      handle: h is Map ? SurveyHandle(east: _num(h['east']), north: _num(h['north'])) : null,
    );
  }

  final String id;
  final double lng;
  final double lat;
  final double elevation; // meters
  final String? name;
  final PointCorner? corner; // null = smooth (surveys saved before the option)
  final SurveyHandle? handle;

  Map<String, dynamic> toJson() => {
    'id': id,
    'lng': _out(lng),
    'lat': _out(lat),
    'elevation': _out(elevation),
    if (name != null) 'name': name,
    if (corner != null) 'corner': corner!.name,
    if (handle != null) 'handle': {'east': _out(handle!.east), 'north': _out(handle!.north)},
  };

  LinePoint get line => LinePoint(lng: lng, lat: lat, corner: corner, handle: handle);

  ({double lat, double lng, double elevation}) get geo => (lat: lat, lng: lng, elevation: elevation);

  SurveyPoint copyWith({
    double? lng,
    double? lat,
    double? elevation,
    String? Function()? name,
    PointCorner? Function()? corner,
    SurveyHandle? Function()? handle,
  }) => SurveyPoint(
    id: id,
    lng: lng ?? this.lng,
    lat: lat ?? this.lat,
    elevation: elevation ?? this.elevation,
    name: name == null ? this.name : name(),
    corner: corner == null ? this.corner : corner(),
    handle: handle == null ? this.handle : handle(),
  );
}

class SurveyGroup {
  const SurveyGroup({required this.id, required this.name, required this.points, required this.color});

  factory SurveyGroup.fromJson(Map<String, dynamic> j) => SurveyGroup(
    id: '${j['id']}',
    name: '${j['name'] ?? ''}',
    color: '${j['color'] ?? surveyColors.first}',
    points: [
      for (final p in (j['points'] as List? ?? const []))
        if (p is Map) SurveyPoint.fromJson(Map<String, dynamic>.from(p)),
    ],
  );

  final String id;
  final String name;
  final List<SurveyPoint> points;
  final String color; // #RRGGBB

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'points': [for (final p in points) p.toJson()],
    'color': color,
  };

  SurveyGroup copyWith({String? name, List<SurveyPoint>? points}) =>
      SurveyGroup(id: id, name: name ?? this.name, points: points ?? this.points, color: color);

  /// Total horizontal length of the sheet (sum of the segments, WGS84)
  double get totalDistance {
    var total = 0.0;
    for (var i = 1; i < points.length; i++) {
      total += getAzimuthData(points[i - 1].geo, points[i].geo).horizontalDistance;
    }
    return total;
  }
}

List<SurveyGroup> surveyFromJson(Object? data) => [
  if (data is List)
    for (final g in data)
      if (g is Map) SurveyGroup.fromJson(Map<String, dynamic>.from(g)),
];

List<Map<String, dynamic>> surveyToJson(List<SurveyGroup> groups) => [for (final g in groups) g.toJson()];

/// The survey being edited: its sheets and which one new points go to
class SurveyDoc {
  const SurveyDoc({this.groups = const [], this.activeGroupId});

  final List<SurveyGroup> groups;
  final String? activeGroupId;

  SurveyGroup? get activeGroup {
    for (final g in groups) {
      if (g.id == activeGroupId) return g;
    }
    return groups.isEmpty ? null : groups.first;
  }

  SurveyDoc _mapGroup(String groupId, SurveyGroup Function(SurveyGroup g) f) =>
      SurveyDoc(groups: [for (final g in groups) g.id == groupId ? f(g) : g], activeGroupId: activeGroupId);

  SurveyDoc _mapPoint(String groupId, String pointId, SurveyPoint Function(SurveyPoint p) f) =>
      _mapGroup(groupId, (g) => g.copyWith(points: [for (final p in g.points) p.id == pointId ? f(p) : p]));

  /// New sheet "Survey N" with the next colour, made active
  SurveyDoc createGroup({String? id}) {
    final g = SurveyGroup(
      id: id ?? newUuid(),
      name: 'Survey ${groups.length + 1}',
      points: const [],
      color: surveyColors[groups.length % surveyColors.length],
    );
    return SurveyDoc(groups: [...groups, g], activeGroupId: g.id);
  }

  /// Removing the active sheet activates the last one left
  SurveyDoc deleteGroup(String id) {
    final rest = [
      for (final g in groups)
        if (g.id != id) g,
    ];
    return SurveyDoc(
      groups: rest,
      activeGroupId: activeGroupId == id ? (rest.isEmpty ? null : rest.last.id) : activeGroupId,
    );
  }

  SurveyDoc setActive(String id) => SurveyDoc(groups: groups, activeGroupId: id);

  SurveyDoc renameGroup(String id, String name) => _mapGroup(id, (g) => g.copyWith(name: name));

  /// Adds a point to the active sheet (creating "Survey 1" if there is none). [sharpenLast]
  /// makes the current last point a sharp corner without handle (straight mode).
  SurveyDoc addPoint({
    required double lng,
    required double lat,
    required double elevation,
    bool sharpenLast = false,
    String? id,
  }) {
    final point = SurveyPoint(id: id ?? newUuid(), lng: lng, lat: lat, elevation: elevation);
    if (activeGroupId == null && groups.isEmpty) {
      final g = SurveyGroup(id: newUuid(), name: 'Survey 1', points: [point], color: surveyColors.first);
      return SurveyDoc(groups: [g], activeGroupId: g.id);
    }
    final target = activeGroup;
    if (target == null) return this;
    return _mapGroup(target.id, (g) {
      final pts = sharpenLast && g.points.isNotEmpty
          ? [
              ...g.points.take(g.points.length - 1),
              g.points.last.copyWith(corner: () => PointCorner.sharp, handle: () => null),
            ]
          : g.points;
      return g.copyWith(points: [...pts, point]);
    });
  }

  SurveyDoc movePoint(String groupId, String pointId, {required double lat, required double lng, double? elevation}) =>
      _mapPoint(groupId, pointId, (p) => p.copyWith(lat: lat, lng: lng, elevation: elevation));

  /// Choosing a corner drops the point's handle
  SurveyDoc setCorner(String groupId, String pointId, PointCorner corner) =>
      _mapPoint(groupId, pointId, (p) => p.copyWith(corner: () => corner, handle: () => null));

  /// A handle makes the point smooth; null removes it (back to the automatic curve)
  SurveyDoc setHandle(String groupId, String pointId, SurveyHandle? handle) =>
      _mapPoint(groupId, pointId, (p) => p.copyWith(corner: () => PointCorner.smooth, handle: () => handle));

  SurveyDoc setGroupCorners(String groupId, PointCorner corner) => _mapGroup(
    groupId,
    (g) => g.copyWith(
      points: [for (final p in g.points) p.copyWith(corner: () => corner, handle: () => null)],
    ),
  );

  SurveyDoc renamePoint(String groupId, String pointId, String name) =>
      _mapPoint(groupId, pointId, (p) => p.copyWith(name: () => name.trim().isEmpty ? null : name.trim()));

  SurveyDoc removePoint(String groupId, String pointId) => _mapGroup(
    groupId,
    (g) => g.copyWith(
      points: [
        for (final p in g.points)
          if (p.id != pointId) p,
      ],
    ),
  );

  SurveyDoc clearPoints(String groupId) => _mapGroup(groupId, (g) => g.copyWith(points: const []));

  /// Bounds of every point, or null without points
  (LngLat, LngLat)? get bounds {
    final all = [for (final g in groups) ...g.points];
    if (all.isEmpty) return null;
    return (
      (all.map((p) => p.lng).reduce(math.min), all.map((p) => p.lat).reduce(math.min)),
      (all.map((p) => p.lng).reduce(math.max), all.map((p) => p.lat).reduce(math.max)),
    );
  }
}

/// Where a tapped point goes. In straight mode it joins with a straight line, at any
/// angle (step 0) or snapped to a multiple of [angleStep] degrees from the previous turn
({LngLat coords, bool straight}) placeNewPoint(
  SurveyGroup? active,
  LngLat target, {
  required bool straightMode,
  required int angleStep,
}) {
  if (!straightMode) return (coords: target, straight: false);
  final points = active?.points ?? const <SurveyPoint>[];
  if (angleStep == 0 || points.isEmpty) return (coords: target, straight: true);
  final last = points.last;
  final prev = points.length >= 2 ? points[points.length - 2] : null;
  return (
    coords: snapToAngle(prev == null ? null : (prev.lng, prev.lat), (last.lng, last.lat), target, angleStep.toDouble()),
    straight: true,
  );
}

/// How many surveys an account can keep in the cloud (the web's client-side rule; admins
/// count as Enterprise)
int surveyLimit(Plan plan) => switch (plan) {
  Plan.free => 2,
  Plan.pro => 4,
  Plan.enterprise => 10,
};

/// Name a survey is saved under: the given one, the first sheet's, or "Untitled Survey"
String surveySaveName(List<SurveyGroup> groups, [String? name]) => name != null && name.isNotEmpty
    ? name
    : groups.isNotEmpty
    ? groups.first.name
    : 'Untitled Survey';

/// A tiny drag removes the handle (shorter than half a meter)
bool isHandleTooShort(SurveyHandle h) => math.sqrt(h.east * h.east + h.north * h.north) < 0.5;
