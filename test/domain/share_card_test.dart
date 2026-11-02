import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/domain/tracks/recorded_track.dart';
import 'package:landscape360/domain/tracks/share_card.dart';
import 'package:landscape360/domain/tracks/track_recorder_geo.dart';

// Share cards: the numbers, hiding the first and last 200 m, and the route's shape on the card

/// North along a meridian, [n] points ~111 m apart, climbing 10 m each
List<TrackPoint> climb(int n) => [
  for (var i = 0; i < n; i++)
    TrackPoint(
      lat: -7.5 + i * 0.001,
      lng: 110.43,
      alt: 1800.0 + i * 10,
      accuracy: 5,
      speed: 1,
      timestamp: i * 60000,
      segment: 0,
    ),
];

RecordedTrack track({double distanceM = 4020, int moving = 0, double? maxAlt}) => RecordedTrack(
  id: 't1',
  userId: 'u1',
  name: 'Merbabu via Selo',
  mode: TrackMode.offline,
  status: TrackStatus.completed,
  startedAt: DateTime(2026, 10, 19, 5).millisecondsSinceEpoch,
  elapsedMs: (4 * 3600 + 57 * 60) * 1000,
  stats: TrackStats(distanceM: distanceM, movingTimeMs: moving, elevationGainM: 1290, maxAltM: maxAlt),
  syncStatus: TrackSyncStatus.local,
  updatedAt: 0,
);

void main() {
  test('the numbers as on the card', () {
    final d = ShareCardData.of(track(maxAlt: 3142), climb(20));
    expect([for (final s in CardStat.values) d.value(s)], ['4.0 km', '4h 57m', '1,290 m', '3,142 mdpl']);
    expect(cardDate(d.date), 'Mon, 19 Oct 2026');
    expect(postDate(d.date), '2026-10-19');
    // Moving time when there is one, the highest from the points when the track has none
    final e = ShareCardData.of(track(distanceM: 640, moving: 42 * 60000), climb(20));
    expect(
      (e.value(CardStat.distance), e.value(CardStat.time), e.value(CardStat.highest)),
      ('640 m', '42m', '1,990 mdpl'),
    );
    expect(cardDuration(35000), '35s');
  });

  test('hiding start and end cuts about 200 m at each end; a short track stays whole', () {
    final pts = climb(20); // ~2.1 km
    final cut = trimEnds(pts);
    expect(cut.first.lat, closeTo(-7.5 + 0.002, 1e-9), reason: '2 points of ~111 m');
    expect(cut.last.lat, closeTo(-7.5 + 0.017, 1e-9));
    expect(trimEnds(climb(5)), hasLength(5), reason: '~440 m: nothing would be left');

    final d = ShareCardData.of(track(), pts, hideEnds: true);
    expect(d.line, hasLength(cut.length));
    expect(d.value(CardStat.distance), '4.0 km', reason: 'the numbers stay those of the whole track');
    expect(d.top, (110.43, cut.last.lat), reason: 'the highest point shown');
    expect(d.profile, hasLength(20), reason: 'the profile is the whole climb');
  });

  test('the route fits the box, centred, north up', () {
    final pts = fitRoute([(110.0, -7.0), (110.0, -6.99)], const Rect.fromLTWH(0, 0, 100, 100));
    expect(pts.first, offsetMoreOrLessEquals(const Offset(50, 100), epsilon: 1e-6));
    expect(pts.last, offsetMoreOrLessEquals(const Offset(50, 0), epsilon: 1e-6));
  });

  test('a point on the map snapshot: the centre in the middle, 512 px tiles', () {
    const size = Size(360, 640);
    expect(projectOnMap((110.43, -7.47), center: (110.43, -7.47), zoom: 13, size: size), const Offset(180, 320));
    // At zoom 0 the world is 512 px wide: 90° east is a quarter of it
    expect(projectOnMap((90, 0), center: (0, 0), zoom: 0, size: size).dx, closeTo(180 + 128, 1e-9));
  });
}
