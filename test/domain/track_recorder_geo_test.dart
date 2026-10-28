import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/domain/tracks/track_recorder_geo.dart';

// Same cases as src/utils/trackRecorderGeo.test.ts (web)

TrackPoint point({
  double lat = -7.6,
  double lng = 110.45,
  double? alt = 1000,
  bool noAlt = false,
  double accuracy = 5,
  int timestamp = 0,
  int segment = 0,
}) => TrackPoint(
  lat: lat,
  lng: lng,
  alt: noAlt ? null : alt,
  accuracy: accuracy,
  speed: null,
  timestamp: timestamp,
  segment: segment,
);

void main() {
  test('computes haversine distance (~111 km per degree of latitude)', () {
    final d = haversineDistance((lat: 0, lng: 0), (lat: 1, lng: 0));
    expect(d, greaterThan(111000));
    expect(d, lessThan(111400));
  });

  group('shouldRejectPoint', () {
    test('rejects inaccurate fixes, even as the first point', () {
      expect(shouldRejectPoint(null, point(accuracy: 80)), RejectReason.accuracy);
    });

    test('keeps the first point of a track or segment', () {
      expect(shouldRejectPoint(null, point()), isNull);
      expect(shouldRejectPoint(point(), point(segment: 1, timestamp: 1000)), isNull);
    });

    test('rejects jitter, out-of-order fixes and impossible jumps', () {
      final prev = point(timestamp: 10000);
      expect(shouldRejectPoint(prev, point(lat: -7.60001, timestamp: 15000)), RejectReason.tooClose);
      expect(shouldRejectPoint(prev, point(lat: -7.601, timestamp: 9000)), RejectReason.outOfOrder);
      // ~11 km in 5 seconds
      expect(shouldRejectPoint(prev, point(lat: -7.7, timestamp: 15000)), RejectReason.tooFast);
      // ~11 m in 5 seconds (walking)
      expect(shouldRejectPoint(prev, point(lat: -7.6001, timestamp: 15000)), isNull);
    });
  });

  group('accumulatePoints', () {
    test('sums distance and moving time within a segment', () {
      final acc = accumulatePoints([
        point(lat: -7.6, timestamp: 0),
        point(lat: -7.6001, timestamp: 5000),
        point(lat: -7.6002, timestamp: 10000),
      ]);
      expect(acc.stats.pointCount, 3);
      expect(acc.stats.distanceM, closeTo(22.2, 0.5));
      expect(acc.stats.movingTimeMs, 10000);
    });

    test('does not bridge distance across a pause (new segment)', () {
      final acc = accumulatePoints([
        point(lat: -7.6, timestamp: 0),
        point(lat: -7.6001, timestamp: 5000),
        point(lat: -7.7, timestamp: 600000, segment: 1),
      ]);
      expect(acc.stats.distanceM, closeTo(11.1, 0.5));
      expect(acc.stats.movingTimeMs, 5000);
    });

    test('does not count standing still as moving time', () {
      final acc = accumulatePoints([
        point(lat: -7.6, timestamp: 0),
        // ~11 m in 100 s = 0.11 m/s, below the moving threshold
        point(lat: -7.6001, timestamp: 100000),
      ]);
      expect(acc.stats.movingTimeMs, 0);
    });

    test('filters altitude noise below the threshold for gain/loss', () {
      const alts = [1000.0, 1002.0, 1001.0, 1004.0, 1010.0, 1008.0, 1003.0];
      final acc = accumulatePoints([
        for (var i = 0; i < alts.length; i++) point(alt: alts[i], timestamp: i * 5000, lat: -7.6 - i * 0.0001),
      ]);
      // 1000 -> 1004 (+4), 1004 -> 1010 (+6), 1010 -> 1003 (-7); small wiggles ignored
      expect(acc.stats.elevationGainM, 10);
      expect(acc.stats.elevationLossM, 7);
      expect(acc.stats.maxAltM, 1010);
      expect(acc.stats.minAltM, 1000);
    });

    test('handles points without altitude', () {
      final acc = accumulatePoints([point(noAlt: true), point(noAlt: true, timestamp: 5000, lat: -7.6001)]);
      expect(acc.stats.elevationGainM, 0);
      expect(acc.stats.maxAltM, isNull);
    });
  });

  test('adds the running time only while recording', () {
    expect(getElapsedMs(elapsedMs: 60000, lastResumedAt: 100000, status: TrackStatus.recording, now: 130000), 90000);
    expect(getElapsedMs(elapsedMs: 60000, lastResumedAt: null, status: TrackStatus.paused, now: 130000), 60000);
  });

  test('splits points into segments', () {
    final segments = splitSegments([point(), point(timestamp: 1), point(segment: 1, timestamp: 2)]);
    expect(segments.map((s) => s.length), [2, 1]);
  });

  test('builds GPX with one trkseg per segment and escaped names', () {
    final gpx = buildGpx(
      name: 'Merbabu <Summit> & back',
      startedAt: 0,
      points: [
        point(timestamp: 0),
        point(timestamp: 5000, lat: -7.6001),
        point(timestamp: 60000, lat: -7.61, segment: 1, noAlt: true),
      ],
    );
    expect(gpx, contains('<name>Merbabu &lt;Summit&gt; &amp; back</name>'));
    expect('<trkseg>'.allMatches(gpx), hasLength(2));
    expect('<trkpt '.allMatches(gpx), hasLength(3));
    expect(gpx, contains('<ele>1000.0</ele>'));
    expect(gpx, contains('<time>1970-01-01T00:00:05.000Z</time>'));
    expect(gpx, contains('<trkpt lat="-7.6001000" lon="110.4500000">'));
  });

  test('formats duration and distance like the web', () {
    expect(formatDuration(3723000), '01:02:03');
    expect(formatDuration(-5), '00:00:00');
    expect(formatTrackDistance(999.5), '1000 m');
    expect(formatTrackDistance(1234), '1.23 km');
  });

  test('bounds of a track', () {
    expect(getBounds(const []), isNull);
    expect(getBounds([point(lat: -7.6, lng: 110.4), point(lat: -7.5, lng: 110.5)]), ((110.4, -7.6), (110.5, -7.5)));
  });
}
