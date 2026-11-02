import 'dart:math' as math;

import '../geo/spherical.dart';
import '../marked/marked_areas.dart' show formatArea, formatLength, ringArea;
import '../tracks/track_recorder_geo.dart' show haversineDistance;

// The club map (20261102000030_community_club_map.sql): members draw pins, lines, areas and notes
// on the map, with a label, an optional note, one of six colours and comments; anyone in the club
// sees them (read again every 30 seconds, not real time). Lines and areas are measured, and an
// elevation profile is made along them from the open SRTM tiles. Also saved camera views (position,
// zoom, tilt, direction, 2D or 3D) for briefings. Same rules and numbers as the web.

DateTime _time(Object? v) => DateTime.tryParse('${v ?? ''}') ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

double _double(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;

enum AnnotationKind {
  pin('Pin'),
  line('Line'),
  area('Area'),
  note('Note');

  const AnnotationKind(this.label);

  final String label;

  /// Points needed before the shape can be saved
  int get needed => switch (this) {
    line => 2,
    area => 3,
    pin || note => 1,
  };

  bool get isPoint => this == pin || this == note;

  static AnnotationKind parse(Object? v) => values.firstWhere((k) => k.name == v, orElse: () => pin);
}

/// The six colours of the web (gold, red, blue, green, purple, ink); gold is the default
const annotationColors = ['#d49b22', '#b4302a', '#1f6feb', '#2f7d3b', '#7b4bb7', '#1a2214'];

/// Server limits
const annotationLabelMax = 80;
const annotationNoteMax = 1000;
const annotationCommentMax = 500;
const viewNameMax = 60;

double _r6(double v) => (v * 1e6).roundToDouble() / 1e6;

/// The GeoJSON geometry for a drawing from the points tapped on the map (null: not enough yet).
/// A pin or note is the last point tapped; an area is closed.
Map<String, Object>? annotationGeometry(AnnotationKind kind, List<LngLat> pts) {
  final r = [
    for (final p in pts) [_r6(p.$1), _r6(p.$2)],
  ];
  if (kind.isPoint) return r.isEmpty ? null : {'type': 'Point', 'coordinates': r.last};
  if (kind == AnnotationKind.line) return r.length >= 2 ? {'type': 'LineString', 'coordinates': r} : null;
  return r.length >= 3
      ? {
          'type': 'Polygon',
          'coordinates': [
            [...r, r.first],
          ],
        }
      : null;
}

LngLat _pt(Object? c) {
  final l = c is List ? c : const [];
  return (l.isNotEmpty ? _double(l[0]) : 0, l.length > 1 ? _double(l[1]) : 0);
}

/// The points of a geometry (an area without its closing point), to measure or edit it again
List<LngLat> annotationPoints(Map<String, dynamic> g) {
  final c = g['coordinates'];
  switch (g['type']) {
    case 'Point':
      return [_pt(c)];
    case 'LineString':
      return [for (final p in (c is List ? c : const [])) _pt(p)];
    case 'Polygon':
      final ring = c is List && c.isNotEmpty && c.first is List ? c.first as List : const [];
      final pts = [for (final p in ring) _pt(p)];
      return pts.length > 1 ? pts.sublist(0, pts.length - 1) : pts;
  }
  return const [];
}

double _dist(LngLat a, LngLat b) => haversineDistance((lat: a.$2, lng: a.$1), (lat: b.$2, lng: b.$1));

/// Length of a line in metres
double lineLengthM(List<LngLat> coords) {
  var m = 0.0;
  for (var i = 1; i < coords.length; i++) {
    m += _dist(coords[i - 1], coords[i]);
  }
  return m;
}

/// Evenly spaced points along a line (about every 10 m, at most [max]), each with its distance
/// from the start
List<({LngLat at, double distM})> densifyLine(List<LngLat> coords, {int max = 200}) {
  final total = lineLengthM(coords);
  if (coords.length < 2 || total == 0) return [for (final c in coords) (at: c, distM: 0.0)];
  final n = math.max(2, math.min(max, (total / 10).ceil() + 1));
  final step = total / (n - 1);
  final out = <({LngLat at, double distM})>[];
  var seg = 0;
  var segStart = 0.0;
  var segLen = _dist(coords[0], coords[1]);
  for (var i = 0; i < n; i++) {
    final d = math.min(i * step, total);
    while (seg < coords.length - 2 && d > segStart + segLen) {
      segStart += segLen;
      seg++;
      segLen = _dist(coords[seg], coords[seg + 1]);
    }
    final f = segLen > 0 ? math.min(1.0, (d - segStart) / segLen) : 0.0;
    final a = coords[seg], b = coords[seg + 1];
    out.add((at: (a.$1 + (b.$1 - a.$1) * f, a.$2 + (b.$2 - a.$2) * f), distM: d));
  }
  return out;
}

class ProfileStats {
  const ProfileStats({
    required this.min,
    required this.max,
    required this.gain,
    required this.loss,
    required this.start,
    required this.end,
  });

  final double min;
  final double max;
  final double gain;
  final double loss;
  final double start;
  final double end;
}

/// Lowest, highest, total climb and descent of a profile (points without data skipped)
ProfileStats? profileStats(List<double> heights) {
  final h = heights.where((v) => v.isFinite).toList();
  if (h.isEmpty) return null;
  var gain = 0.0, loss = 0.0;
  for (var i = 1; i < h.length; i++) {
    final d = h[i] - h[i - 1];
    if (d > 0) {
      gain += d;
    } else {
      loss -= d;
    }
  }
  return ProfileStats(
    min: h.reduce(math.min),
    max: h.reduce(math.max),
    gain: gain,
    loss: loss,
    start: h.first,
    end: h.last,
  );
}

class Annotation {
  const Annotation({
    required this.id,
    required this.kind,
    required this.label,
    this.note,
    required this.color,
    required this.geometry,
    this.authorName = '',
    this.isMine = false,
    this.commentCount = 0,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Annotation.fromRow(Map<String, dynamic> r) => Annotation(
    id: '${r['id']}',
    kind: AnnotationKind.parse(r['kind']),
    label: '${r['label'] ?? ''}',
    note: (r['note'] as String?)?.trim().isEmpty ?? true ? null : r['note'] as String,
    color: (r['color'] as String?) ?? annotationColors.first,
    geometry: r['geometry'] is Map ? Map<String, dynamic>.from(r['geometry'] as Map) : const {},
    authorName: '${r['author_name'] ?? ''}',
    isMine: r['is_mine'] == true,
    commentCount: r['comment_count'] is num ? (r['comment_count'] as num).toInt() : 0,
    createdAt: _time(r['created_at']),
    updatedAt: _time(r['updated_at']),
  );

  final String id;
  final AnnotationKind kind;
  final String label;
  final String? note;
  final String color;
  final Map<String, dynamic> geometry;
  final String authorName;
  final bool isMine;
  final int commentCount;
  final DateTime createdAt;
  final DateTime updatedAt;

  List<LngLat> get points => annotationPoints(geometry);

  /// "1.24 km" for a line, "3.5 ha" for an area, null for a pin or note
  String? get measure => switch (geometry['type']) {
    'LineString' => formatLength(lineLengthM(points)),
    'Polygon' => formatArea(ringArea(points)),
    _ => null,
  };
}

class AnnotationComment {
  const AnnotationComment({
    required this.id,
    required this.body,
    this.authorName = '',
    this.isMine = false,
    required this.createdAt,
  });

  factory AnnotationComment.fromRow(Map<String, dynamic> r) => AnnotationComment(
    id: '${r['id']}',
    body: '${r['body'] ?? ''}',
    authorName: '${r['author_name'] ?? ''}',
    isMine: r['is_mine'] == true,
    createdAt: _time(r['created_at']),
  );

  final String id;
  final String body;
  final String authorName;
  final bool isMine;
  final DateTime createdAt;
}

/// A named camera position for briefings
class SavedView {
  const SavedView({
    required this.id,
    required this.name,
    required this.lng,
    required this.lat,
    required this.zoom,
    this.pitch = 0,
    this.bearing = 0,
    this.terrain = false,
    this.authorName = '',
    this.isMine = false,
  });

  factory SavedView.fromRow(Map<String, dynamic> r) => SavedView(
    id: '${r['id']}',
    name: '${r['name'] ?? ''}',
    lng: _double(r['lng']),
    lat: _double(r['lat']),
    zoom: _double(r['zoom']),
    pitch: _double(r['pitch']),
    bearing: _double(r['bearing']),
    terrain: r['terrain'] == true,
    authorName: '${r['author_name'] ?? ''}',
    isMine: r['is_mine'] == true,
  );

  final String id;
  final String name;
  final double lng;
  final double lat;
  final double zoom;
  final double pitch;
  final double bearing;
  final bool terrain;
  final String authorName;
  final bool isMine;
}
