import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import '../geo/spherical.dart';
import 'recorded_track.dart';
import 'track_recorder_geo.dart';

// Share cards of a track, like Strava's (mobile app only): a 9:16 picture for an Instagram story
// or a WhatsApp status with the route and the numbers that matter on a hike. Four templates;
// the numbers can be switched off one by one, and the first and last 200 m can be hidden so a
// home or basecamp is not given away (the route attached to a Community post is cut the same).

enum ShareCardTemplate {
  map('Map'),
  sticker('Sticker'),
  photo('Photo'),
  profile('Elevation');

  const ShareCardTemplate(this.label);

  final String label;
}

enum CardStat {
  distance('Distance'),
  time('Time'),
  gain('Elev. gain'),
  highest('Highest');

  const CardStat(this.label);

  final String label;
}

/// The card's size in logical pixels; rendered 3× for 1080 × 1920
const shareCardSize = Size(360, 640);
const shareCardPixelRatio = 3.0;

/// Hidden at each end with "Hide start and end"
const privacyTrimM = 200.0;

double _dist(TrackPoint a, TrackPoint b) => haversineDistance((lat: a.lat, lng: a.lng), (lat: b.lat, lng: b.lng));

/// [points] without the first and last [meters]; unchanged when the track is too short to keep
/// something in between
List<TrackPoint> trimEnds(List<TrackPoint> points, {double meters = privacyTrimM}) {
  if (points.length < 3) return points;
  var total = 0.0;
  for (var i = 1; i < points.length; i++) {
    total += _dist(points[i - 1], points[i]);
  }
  if (total < meters * 3) return points;
  var from = 0, run = 0.0;
  while (from < points.length - 1 && run < meters) {
    run += _dist(points[from], points[from + 1]);
    from++;
  }
  var to = points.length - 1;
  run = 0;
  while (to > from && run < meters) {
    run += _dist(points[to - 1], points[to]);
    to--;
  }
  return points.sublist(from, to + 1);
}

/// What a card shows
class ShareCardData {
  const ShareCardData({
    required this.name,
    required this.date,
    required this.distanceM,
    required this.durationMs,
    required this.gainM,
    required this.highestM,
    required this.line,
    required this.profile,
    required this.top,
  });

  /// From a saved track and its points; [hideEnds] cuts the first and last 200 m of the route
  /// (the numbers stay those of the whole track)
  factory ShareCardData.of(RecordedTrack t, List<TrackPoint> points, {bool hideEnds = false}) {
    final shown = hideEnds ? trimEnds(points) : points;
    final alts = [
      for (final p in points)
        if (p.alt != null) p.alt!,
    ];
    final highest = t.stats.maxAltM ?? (alts.isEmpty ? null : alts.reduce(math.max));
    TrackPoint? top;
    for (final p in shown) {
      if (p.alt != null && (top == null || p.alt! > top.alt!)) top = p;
    }
    final profile = <(double, double)>[];
    var d = 0.0;
    for (var i = 0; i < points.length; i++) {
      if (i > 0) d += _dist(points[i - 1], points[i]);
      if (points[i].alt != null) profile.add((d, points[i].alt!));
    }
    final mid = shown.isEmpty ? null : shown[shown.length ~/ 2];
    return ShareCardData(
      name: t.name,
      date: DateTime.fromMillisecondsSinceEpoch(t.startedAt),
      distanceM: t.stats.distanceM,
      durationMs: t.stats.movingTimeMs > 0 ? t.stats.movingTimeMs : t.elapsedMs,
      gainM: t.stats.elevationGainM,
      highestM: highest,
      line: [for (final p in shown) (p.lng, p.lat)],
      profile: profile,
      top: top == null ? (mid == null ? null : (mid.lng, mid.lat)) : (top.lng, top.lat),
    );
  }

  final String name;
  final DateTime date;
  final double distanceM;
  final int durationMs;
  final double gainM;
  final double? highestM;

  /// The route as (lng, lat), already cut when the ends are hidden
  final List<LngLat> line;

  /// (distance from the start in m, height) along the whole track
  final List<(double, double)> profile;

  /// The highest point shown (else the middle): where a Community post is placed
  final LngLat? top;

  /// The value of [s] as shown on the card ("12.4 km", "5h 12m", "1,290 m", "3,142 mdpl")
  String value(CardStat s) => switch (s) {
    CardStat.distance => distanceM >= 1000 ? '${(distanceM / 1000).toStringAsFixed(1)} km' : '${distanceM.round()} m',
    CardStat.time => cardDuration(durationMs),
    CardStat.gain => '${_thousands(gainM.round())} m',
    CardStat.highest => highestM == null ? '–' : '${_thousands(highestM!.round())} mdpl',
  };
}

String _thousands(int n) => n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

/// "5h 12m", "42m", "35s"
String cardDuration(int ms) {
  final s = ms ~/ 1000;
  final h = s ~/ 3600, m = (s % 3600) ~/ 60;
  if (h > 0) return '${h}h ${m}m';
  if (m > 0) return '${m}m';
  return '${s}s';
}

/// "Sun, 19 Oct 2026"
String cardDate(DateTime d) {
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${days[d.weekday - 1]}, ${d.day} ${months[d.month - 1]} ${d.year}';
}

/// "2026-10-19", the date of a Community post
String postDate(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

// --- Drawing the route ---------------------------------------------------------------------------

double _mx(double lng) => (lng + 180) / 360;

double _my(double lat) {
  final s = math.sin(lat.clamp(-85.0, 85.0) * math.pi / 180);
  return 0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi);
}

/// The route in [box] (Web Mercator, north up, the same shape as on the map), centred, keeping
/// its proportions
List<Offset> fitRoute(List<LngLat> line, Rect box) {
  if (line.isEmpty) return const [];
  final xs = [for (final p in line) _mx(p.$1)], ys = [for (final p in line) _my(p.$2)];
  final minX = xs.reduce(math.min), maxX = xs.reduce(math.max);
  final minY = ys.reduce(math.min), maxY = ys.reduce(math.max);
  final w = maxX - minX, h = maxY - minY;
  final scale = (w == 0 && h == 0)
      ? 0.0
      : math.min(w == 0 ? double.infinity : box.width / w, h == 0 ? double.infinity : box.height / h);
  final ox = box.center.dx - (minX + w / 2) * scale, oy = box.center.dy - (minY + h / 2) * scale;
  return [for (var i = 0; i < line.length; i++) Offset(xs[i] * scale + ox, ys[i] * scale + oy)];
}

/// A point of the map snapshot: Mapbox's zoom is in 512 px tiles, [size] in logical pixels
Offset projectOnMap(LngLat p, {required LngLat center, required double zoom, required Size size}) {
  final world = 512 * math.pow(2, zoom);
  return Offset(
    (_mx(p.$1) - _mx(center.$1)) * world + size.width / 2,
    (_my(p.$2) - _my(center.$2)) * world + size.height / 2,
  );
}
