import 'dart:math' as math;

// Team Monitor (LiveTrackerLayer.tsx, TrackerHistoryViewer.tsx and useTrackerStore.ts on the
// web): what a monitor account sees of the members sharing their position. A packet is the
// web's TrackerPacket (the same the app sends in live_packet.dart); each member keeps the last
// 500 points as a trail. Online, idle (slower than 1 km/h) and offline (nothing for 5 minutes)
// are judged the same way as on the web, as are the colour and initials of a member.

/// Points kept per member for the trail (TRACKER_CONFIG.MAX_HISTORY_POINTS)
const monitorTrailMax = 500;

/// Nothing heard for this long: offline (the web's 5-minute threshold)
const monitorOfflineAfter = Duration(minutes: 5);

/// Slower than this (as sent) and online: idle, standing still
const monitorIdleBelow = 1.0;

/// How often the markers' status is judged again while nothing comes in
const monitorTickEvery = Duration(seconds: 5);

double _double(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;

/// A member's position as broadcast on tracking-room (TrackerPacket)
class MonitorPacket {
  const MonitorPacket({
    required this.trackerId,
    required this.lat,
    required this.lng,
    this.alt,
    this.speed,
    this.battery,
    required this.time,
  });

  /// From the broadcast payload; null when it is not a position
  static MonitorPacket? fromJson(Map<String, dynamic> j) {
    final id = j['user_id'];
    final lat = j['lat'], lng = j['lng'];
    if (id is! String || id.isEmpty || lat is! num || lng is! num) return null;
    if (lat.abs() > 90 || lng.abs() > 180) return null;
    final t = DateTime.tryParse('${j['timestamp'] ?? ''}');
    return MonitorPacket(
      trackerId: id,
      lat: lat.toDouble(),
      lng: lng.toDouble(),
      alt: j['alt'] is num ? (j['alt'] as num).toDouble() : null,
      speed: j['speed'] is num ? (j['speed'] as num).toDouble() : null,
      battery: j['battery'] is num ? (j['battery'] as num).toInt() : null,
      time: t?.millisecondsSinceEpoch ?? DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// From a tracker_logs row (a recalled activity)
  factory MonitorPacket.fromLog(Map<String, dynamic> r, {String? trackerId}) => MonitorPacket(
    trackerId: trackerId ?? '${r['user_id']}',
    lat: _double(r['lat']),
    lng: _double(r['lng']),
    alt: r['elevation'] is num ? (r['elevation'] as num).toDouble() : null,
    speed: r['speed'] is num ? (r['speed'] as num).toDouble() : null,
    battery: r['battery'] is num ? (r['battery'] as num).toInt() : null,
    time: DateTime.tryParse('${r['timestamp'] ?? ''}')?.millisecondsSinceEpoch ?? 0,
  );

  /// The web's name for the member (the email before the @, in capitals)
  final String trackerId;
  final double lat;
  final double lng;
  final double? alt; // meters
  final double? speed; // as sent (the app sends m/s; the web shows the number as km/h)
  final int? battery; // percent
  final int time; // epoch ms of the fix
}

enum MonitorStatus { online, idle, offline }

/// One member on the monitor's map: the last packet and the trail behind it
class MonitorTracker {
  const MonitorTracker({required this.latest, required this.trail, required this.heardAt});

  final MonitorPacket latest;
  final List<(double, double)> trail; // (lng, lat), oldest first
  final int heardAt; // epoch ms the packet arrived

  String get id => latest.trackerId;

  MonitorStatus status(int nowMs) {
    if (nowMs - latest.time > monitorOfflineAfter.inMilliseconds) return MonitorStatus.offline;
    return (latest.speed ?? 0) < monitorIdleBelow ? MonitorStatus.idle : MonitorStatus.online;
  }

  /// With a newer packet: the trail grows (the oldest points drop past 500)
  MonitorTracker update(MonitorPacket p, int nowMs) {
    final next = [...trail, (p.lng, p.lat)];
    return MonitorTracker(
      latest: p,
      trail: next.length > monitorTrailMax ? next.sublist(next.length - monitorTrailMax) : next,
      heardAt: nowMs,
    );
  }
}

/// The web's stringToColor: a hue from the name, so a member keeps one colour everywhere
String trackerColor(String id) {
  var hash = 0;
  for (final c in id.codeUnits) {
    hash = (c + ((hash << 5) - hash)) & 0xFFFFFFFF;
    // JavaScript keeps a signed 32-bit int
    if (hash >= 0x80000000) hash -= 0x100000000;
  }
  final h = (hash % 360).abs();
  return _hsl(h, 0.7, 0.5);
}

String _hsl(int h, double s, double l) {
  final c = (1 - (2 * l - 1).abs()) * s;
  final x = c * (1 - ((h / 60) % 2 - 1).abs());
  final m = l - c / 2;
  final (r, g, b) = switch (h ~/ 60) {
    0 => (c, x, 0.0),
    1 => (x, c, 0.0),
    2 => (0.0, c, x),
    3 => (0.0, x, c),
    4 => (x, 0.0, c),
    _ => (c, 0.0, x),
  };
  String hex(double v) => ((v + m) * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
  return '#${hex(r)}${hex(g)}${hex(b)}';
}

/// The web's getInitials: the first letters of the parts of the name, two at most
String trackerInitials(String id) {
  final parts = id.split(RegExp(r'[\s._-]+')).where((p) => p.isNotEmpty);
  final s = parts.map((p) => p[0]).join();
  return (s.length > 2 ? s.substring(0, 2) : s).toUpperCase();
}

/// 7° 27' 16.9" S, as on the web
String toDms(double deg, {required bool isLat}) {
  final a = deg.abs();
  final d = a.floor();
  final mFull = (a - d) * 60;
  final m = mFull.floor();
  final s = ((mFull - m) * 60).toStringAsFixed(1);
  final dir = isLat ? (deg >= 0 ? 'N' : 'S') : (deg >= 0 ? 'E' : 'W');
  return '$d° $m\' $s" $dir';
}

/// Rough distance in metres between two points (for the trail's length)
double metersBetween(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  final dLat = (lat2 - lat1) * math.pi / 180, dLng = (lng2 - lng1) * math.pi / 180;
  final a =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180) * math.cos(lat2 * math.pi / 180) * math.sin(dLng / 2) * math.sin(dLng / 2);
  return 2 * r * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

// --- The account behind a tracker (monitor_tracker_profiles, 20261127000034) -------------------

String? _text(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;

/// Who a tracker id belongs to: name, contact, plan and photo (monitors and admins only)
class TrackerProfile {
  const TrackerProfile({
    required this.trackerId,
    required this.userId,
    this.name,
    this.email,
    this.organization,
    this.phone,
    this.plan,
    this.role,
    this.matches = 1,
    this.avatarPath,
  });

  factory TrackerProfile.fromRow(Map<String, dynamic> r) => TrackerProfile(
    trackerId: '${r['tracker_id'] ?? ''}'.toUpperCase(),
    userId: '${r['user_id']}',
    name: _text(r['name']),
    email: _text(r['email']),
    organization: _text(r['organization']),
    phone: _text(r['phone']),
    plan: _text(r['plan']),
    role: _text(r['role']),
    matches: r['matches'] is num ? (r['matches'] as num).toInt() : 1,
    avatarPath: _text(r['avatar_path']),
  );

  final String trackerId;
  final String userId;
  final String? name;
  final String? email;
  final String? organization;
  final String? phone;
  final String? plan;
  final String? role;

  /// Accounts whose email name is this tracker id; the one that logged last is shown
  final int matches;

  /// Profile photo in the avatars bucket
  final String? avatarPath;

  String get roleLabel => role == 'monitor360' ? 'Monitor' : 'Member';
}

/// The name to show for a tracker: the account's name, else the tracker id
String trackerLabel(String trackerId, TrackerProfile? profile) => profile?.name ?? trackerId;

/// wa.me link for an Indonesian or international number ("0812…" becomes "62812…"), or null
String? whatsappUrl(String phone) {
  var digits = phone.replaceAll(RegExp(r'\D'), '');
  if (digits.length < 8) return null;
  if (digits.startsWith('0')) digits = '62${digits.substring(1)}';
  return 'https://wa.me/$digits';
}

// --- GeoJSON for the map ---------------------------------------------------------------------------

const _gray = '#6b7280';

/// Each member as a point: initials (of the account's name when known), colour (gray when
/// offline), status, whether selected, and the id of their photo on the map when it is there
Map<String, Object> monitorGeoJson(
  Iterable<MonitorTracker> trackers,
  int nowMs,
  String? selectedId, {
  Map<String, TrackerProfile?> profiles = const {},
  Set<String> photos = const {},
}) => {
  'type': 'FeatureCollection',
  'features': [
    for (final t in trackers)
      {
        'type': 'Feature',
        'properties': {
          'id': t.id,
          'label': trackerLabel(t.id, profiles[t.id]),
          'initials': trackerInitials(trackerLabel(t.id, profiles[t.id])),
          'color': t.status(nowMs) == MonitorStatus.offline ? _gray : trackerColor(t.id),
          'status': t.status(nowMs).name,
          'selected': t.id == selectedId,
          // The photo is hidden while offline (the web shows the no-signal icon instead)
          'photo': photos.contains(t.id) && t.status(nowMs) != MonitorStatus.offline,
        },
        'geometry': {
          'type': 'Point',
          'coordinates': [t.latest.lng, t.latest.lat],
        },
      },
  ],
};

/// The trails: the selected member's in their colour, the others' gray and faint
Map<String, Object> monitorTrailsGeoJson(Iterable<MonitorTracker> trackers, String? selectedId) => {
  'type': 'FeatureCollection',
  'features': [
    for (final t in trackers)
      if (t.trail.length >= 2)
        {
          'type': 'Feature',
          'properties': {
            'id': t.id,
            'color': t.id == selectedId ? trackerColor(t.id) : '#94a3b8',
            'opacity': t.id == selectedId ? 1 : 0.4,
            'width': t.id == selectedId ? 4 : 2,
          },
          'geometry': {
            'type': 'LineString',
            'coordinates': [
              for (final (lng, lat) in t.trail) [lng, lat],
            ],
          },
        },
  ],
};

/// A recalled activity: its path, and where it started (green) and ended (red)
Map<String, Object> sessionGeoJson(List<MonitorPacket> points) => {
  'type': 'FeatureCollection',
  'features': [
    if (points.length >= 2) ...[
      {
        'type': 'Feature',
        'properties': {'kind': 'path'},
        'geometry': {
          'type': 'LineString',
          'coordinates': [
            for (final p in points) [p.lng, p.lat],
          ],
        },
      },
      {
        'type': 'Feature',
        'properties': {'kind': 'start'},
        'geometry': {
          'type': 'Point',
          'coordinates': [points.first.lng, points.first.lat],
        },
      },
      {
        'type': 'Feature',
        'properties': {'kind': 'end'},
        'geometry': {
          'type': 'Point',
          'coordinates': [points.last.lng, points.last.lat],
        },
      },
    ],
  ],
};

// --- Tracking lists (activities and logs) ---------------------------------------------------------

/// One activity (a session of Record Activity on the web), as get_tracker_activity_sessions
/// returns it
class ActivitySummary {
  const ActivitySummary({
    required this.sessionId,
    required this.userId,
    required this.startedAt,
    this.endedAt,
    this.distanceM = 0,
    this.pointCount = 0,
    this.lastPointAt,
    this.email,
  });

  factory ActivitySummary.fromRow(Map<String, dynamic> r, {String? email}) => ActivitySummary(
    sessionId: '${r['session_id']}',
    userId: '${r['user_id']}',
    startedAt: DateTime.tryParse('${r['started_at'] ?? ''}') ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    endedAt: r['ended_at'] == null ? null : DateTime.tryParse('${r['ended_at']}'),
    distanceM: _double(r['distance_m']),
    pointCount: r['point_count'] is num ? (r['point_count'] as num).toInt() : 0,
    lastPointAt: r['last_point_at'] == null ? null : DateTime.tryParse('${r['last_point_at']}'),
    email: email,
  );

  final String sessionId;
  final String userId;
  final DateTime startedAt;
  final DateTime? endedAt;
  final double distanceM;
  final int pointCount;
  final DateTime? lastPointAt;
  final String? email;

  /// The web's name for the member: the email before the @, else the id's first 8 characters
  String get memberName => memberNameOf(email, userId);
}

String memberNameOf(String? email, String userId) {
  if (email != null && email.contains('@')) return email.split('@').first;
  return userId.length > 8 ? userId.substring(0, 8) : userId;
}

/// One row of tracker_logs
class TrackerLog {
  const TrackerLog({
    required this.id,
    required this.userId,
    required this.lat,
    required this.lng,
    this.elevation,
    this.speed,
    required this.time,
    this.email,
  });

  factory TrackerLog.fromRow(Map<String, dynamic> r, {String? email}) => TrackerLog(
    id: '${r['id']}',
    userId: '${r['user_id']}',
    lat: _double(r['lat']),
    lng: _double(r['lng']),
    elevation: r['elevation'] is num ? (r['elevation'] as num).toDouble() : null,
    speed: r['speed'] is num ? (r['speed'] as num).toDouble() : null,
    time: DateTime.tryParse('${r['timestamp'] ?? ''}') ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    email: email,
  );

  final String id;
  final String userId;
  final double lat;
  final double lng;
  final double? elevation;
  final double? speed;
  final DateTime time;
  final String? email;

  String get memberName => memberNameOf(email, userId);
}

/// A GPX file of the points, as the web's exports write it
String pointsGpx(Iterable<MonitorPacket> points, {required String name}) {
  final b = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln('<gpx version="1.1" creator="Landscape 360" xmlns="http://www.topografix.com/GPX/1/1">')
    ..writeln('  <trk>')
    ..writeln('    <name>${_xml(name)}</name>')
    ..writeln('    <trkseg>');
  for (final p in points) {
    b
      ..writeln('      <trkpt lat="${p.lat}" lon="${p.lng}">')
      ..writeln('        <ele>${p.alt ?? 0}</ele>')
      ..writeln('        <time>${DateTime.fromMillisecondsSinceEpoch(p.time, isUtc: true).toIso8601String()}</time>')
      ..writeln('      </trkpt>');
  }
  b
    ..writeln('    </trkseg>')
    ..writeln('  </trk>')
    ..write('</gpx>');
  return b.toString();
}

String _xml(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
