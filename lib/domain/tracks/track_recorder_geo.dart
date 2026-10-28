import 'dart:math' as math;

import '../util/js_compat.dart';

// Port of src/utils/trackRecorderGeo.ts and TRACK_RECORDER_CONFIG (src/types/trackRecorder.ts)

class TrackRecorderConfig {
  const TrackRecorderConfig({
    this.maxAccuracyM = 50,
    this.minDistanceM = 5,
    this.maxSpeedMs = 70,
    this.elevationThresholdM = 3,
    this.movingSpeedMs = 0.3,
    this.maxMovingGapMs = 120000,
  });

  /// Ignore fixes worse than this (meters)
  final double maxAccuracyM;

  /// Ignore movement smaller than this, GPS jitter while standing still (meters)
  final double minDistanceM;

  /// Reject jumps faster than this between two fixes (m/s, ~250 km/h)
  final double maxSpeedMs;

  /// Altitude change needed before it counts as gain/loss (meters)
  final double elevationThresholdM;

  /// Slower than this between two points counts as standing still (m/s)
  final double movingSpeedMs;

  /// Gaps longer than this between points do not count as moving time (ms)
  final int maxMovingGapMs;
}

const trackRecorderConfig = TrackRecorderConfig();

class TrackPoint {
  const TrackPoint({
    required this.lat,
    required this.lng,
    required this.alt,
    required this.accuracy,
    required this.speed,
    required this.timestamp,
    required this.segment,
  });

  factory TrackPoint.fromJson(Map<String, dynamic> j) => TrackPoint(
    lat: (j['lat'] as num).toDouble(),
    lng: (j['lng'] as num).toDouble(),
    alt: (j['alt'] as num?)?.toDouble(),
    accuracy: (j['accuracy'] as num).toDouble(),
    speed: (j['speed'] as num?)?.toDouble(),
    timestamp: (j['timestamp'] as num).toInt(),
    segment: (j['segment'] as num).toInt(),
  );

  final double lat;
  final double lng;
  final double? alt; // meters, null when the device gives no altitude
  final double accuracy; // horizontal accuracy in meters
  final double? speed; // m/s reported by the device
  final int timestamp; // epoch ms
  final int segment; // increments on every resume after a pause

  Map<String, dynamic> toJson() => {
    'lat': lat,
    'lng': lng,
    'alt': alt,
    'accuracy': accuracy,
    'speed': speed,
    'timestamp': timestamp,
    'segment': segment,
  };
}

class TrackStats {
  const TrackStats({
    this.distanceM = 0,
    this.movingTimeMs = 0,
    this.elevationGainM = 0,
    this.elevationLossM = 0,
    this.maxAltM,
    this.minAltM,
    this.pointCount = 0,
  });

  final double distanceM;
  final int movingTimeMs;
  final double elevationGainM;
  final double elevationLossM;
  final double? maxAltM;
  final double? minAltM;
  final int pointCount;
}

const double _earthRadiusM = 6371000;
double _toRad(double deg) => (deg * math.pi) / 180;

double haversineDistance(({double lat, double lng}) a, ({double lat, double lng}) b) {
  final dLat = _toRad(b.lat - a.lat);
  final dLng = _toRad(b.lng - a.lng);
  final h =
      math.pow(math.sin(dLat / 2), 2) +
      math.cos(_toRad(a.lat)) * math.cos(_toRad(b.lat)) * math.pow(math.sin(dLng / 2), 2);
  return 2 * _earthRadiusM * math.asin(math.min(1, math.sqrt(h)));
}

({double lat, double lng}) _ll(TrackPoint p) => (lat: p.lat, lng: p.lng);

enum RejectReason { accuracy, tooClose, tooFast, outOfOrder }

/// Whether a new GPS fix should be dropped, given the last stored point; null keeps it
RejectReason? shouldRejectPoint(TrackPoint? prev, TrackPoint next, [TrackRecorderConfig config = trackRecorderConfig]) {
  if (next.accuracy > config.maxAccuracyM) return RejectReason.accuracy;
  // First point of a track or of a new segment is always kept
  if (prev == null || prev.segment != next.segment) return null;
  if (next.timestamp <= prev.timestamp) return RejectReason.outOfOrder;

  final distance = haversineDistance(_ll(prev), _ll(next));
  if (distance < config.minDistanceM) return RejectReason.tooClose;

  final seconds = (next.timestamp - prev.timestamp) / 1000;
  if (distance / seconds > config.maxSpeedMs) return RejectReason.tooFast;
  return null;
}

class StatsAccumulator {
  const StatsAccumulator({this.stats = const TrackStats(), this.lastPoint, this.elevationRef});

  final TrackStats stats;
  final TrackPoint? lastPoint;
  final double? elevationRef; // last altitude that counted toward gain/loss
}

/// Adds an accepted point to the running stats
StatsAccumulator accumulatePoint(
  StatsAccumulator acc,
  TrackPoint point, [
  TrackRecorderConfig config = trackRecorderConfig,
]) {
  final s = acc.stats;
  var distanceM = s.distanceM;
  var movingTimeMs = s.movingTimeMs;
  var gain = s.elevationGainM;
  var loss = s.elevationLossM;
  var maxAlt = s.maxAltM;
  var minAlt = s.minAltM;
  final prev = acc.lastPoint;
  var elevationRef = acc.elevationRef;

  // Distance and moving time never bridge a pause (different segments)
  if (prev != null && prev.segment == point.segment) {
    final distance = haversineDistance(_ll(prev), _ll(point));
    final dt = point.timestamp - prev.timestamp;
    distanceM += distance;
    if (dt > 0 && dt <= config.maxMovingGapMs && distance / (dt / 1000) >= config.movingSpeedMs) {
      movingTimeMs += dt;
    }
  }

  final alt = point.alt;
  if (alt != null) {
    maxAlt = maxAlt == null ? alt : math.max(maxAlt, alt);
    minAlt = minAlt == null ? alt : math.min(minAlt, alt);

    // Hysteresis: only count climbs/descents larger than the threshold
    if (elevationRef == null) {
      elevationRef = alt;
    } else if (alt - elevationRef >= config.elevationThresholdM) {
      gain += alt - elevationRef;
      elevationRef = alt;
    } else if (elevationRef - alt >= config.elevationThresholdM) {
      loss += elevationRef - alt;
      elevationRef = alt;
    }
  }

  return StatsAccumulator(
    stats: TrackStats(
      distanceM: distanceM,
      movingTimeMs: movingTimeMs,
      elevationGainM: gain,
      elevationLossM: loss,
      maxAltM: maxAlt,
      minAltM: minAlt,
      pointCount: s.pointCount + 1,
    ),
    lastPoint: point,
    elevationRef: elevationRef,
  );
}

/// Rebuilds the accumulator from stored points (recovering or viewing a track)
StatsAccumulator accumulatePoints(List<TrackPoint> points, [TrackRecorderConfig config = trackRecorderConfig]) =>
    points.fold(const StatsAccumulator(), (acc, p) => accumulatePoint(acc, p, config));

enum TrackStatus { recording, paused, completed }

int getElapsedMs({
  required int elapsedMs,
  required int? lastResumedAt,
  required TrackStatus status,
  required int now,
}) => elapsedMs + (status == TrackStatus.recording && lastResumedAt != null ? math.max(0, now - lastResumedAt) : 0);

/// Points split into continuous lines, one per segment (pauses break the line)
List<List<TrackPoint>> splitSegments(List<TrackPoint> points) {
  final segments = <List<TrackPoint>>[];
  for (final p in points) {
    if (segments.isNotEmpty && segments.last.last.segment == p.segment) {
      segments.last.add(p);
    } else {
      segments.add([p]);
    }
  }
  return segments;
}

/// ((minLng, minLat), (maxLng, maxLat)), or null without points
((double, double), (double, double))? getBounds(List<TrackPoint> points) {
  if (points.isEmpty) return null;
  var minLng = double.infinity, minLat = double.infinity;
  var maxLng = double.negativeInfinity, maxLat = double.negativeInfinity;
  for (final p in points) {
    minLng = math.min(minLng, p.lng);
    minLat = math.min(minLat, p.lat);
    maxLng = math.max(maxLng, p.lng);
    maxLat = math.max(maxLat, p.lat);
  }
  return ((minLng, minLat), (maxLng, maxLat));
}

String _escapeXml(String value) => value.replaceAllMapped(RegExp('[<>&\'"]'), (m) {
  switch (m[0]) {
    case '<':
      return '&lt;';
    case '>':
      return '&gt;';
    case '&':
      return '&amp;';
    case "'":
      return '&apos;';
    default:
      return '&quot;';
  }
});

String buildGpx({required String name, required int startedAt, required List<TrackPoint> points}) {
  final segments = splitSegments(points)
      .map((segment) {
        final pts = segment
            .map((p) {
              final ele = p.alt != null ? '<ele>${p.alt!.toStringAsFixed(1)}</ele>' : '';
              return '      <trkpt lat="${p.lat.toStringAsFixed(7)}" lon="${p.lng.toStringAsFixed(7)}">$ele<time>${isoString(p.timestamp)}</time></trkpt>';
            })
            .join('\n');
        return '    <trkseg>\n$pts\n    </trkseg>';
      })
      .join('\n');

  return '''<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="Landscape360" xmlns="http://www.topografix.com/GPX/1/1">
  <metadata>
    <name>${_escapeXml(name)}</name>
    <time>${isoString(startedAt)}</time>
  </metadata>
  <trk>
    <name>${_escapeXml(name)}</name>
$segments
  </trk>
</gpx>
''';
}

String formatTrackDistance(double meters) =>
    meters >= 1000 ? '${(meters / 1000).toStringAsFixed(2)} km' : '${jsRoundStr(meters)} m';

String formatDuration(int ms) {
  final total = math.max(0, ms ~/ 1000);
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  String p(int n) => n.toString().padLeft(2, '0');
  return '${p(h)}:${p(m)}:${p(s)}';
}
