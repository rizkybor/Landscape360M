import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/domain/tracks/gpx_import.dart';
import 'package:landscape360/domain/tracks/track_recorder_geo.dart';

// GPX import, the same cases as the web (src/utils/trackRecorderGeo.test.ts, parseGpx)

String gpx(String body) =>
    '<?xml version="1.0"?><gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1">$body</gpx>';

int t(String iso) => DateTime.parse(iso).millisecondsSinceEpoch;

void main() {
  test('reads track segments with elevation and time', () {
    final (:name, :points) = parseGpx(
      gpx('''<trk><name>Merbabu</name>
          <trkseg><trkpt lat="-7.45" lon="110.43"><ele>1800</ele><time>2026-10-01T00:00:00Z</time></trkpt>
                  <trkpt lat="-7.46" lon="110.44"><ele>1850.5</ele><time>2026-10-01T00:10:00Z</time></trkpt></trkseg>
          <trkseg><trkpt lat="-7.47" lon="110.45"><time>2026-10-01T00:20:00Z</time></trkpt></trkseg>
        </trk>'''),
      fallbackTime: 0,
    );
    expect(name, 'Merbabu');
    expect([for (final p in points) p.segment], [0, 0, 1]);
    expect(
      (points[1].lat, points[1].lng, points[1].alt, points[1].timestamp),
      (-7.46, 110.44, 1850.5, t('2026-10-01T00:10:00Z')),
    );
    expect(points[2].alt, isNull);
  });

  test('falls back to a route, and to one time for points without <time>', () {
    final (:name, :points) = parseGpx(
      gpx('<metadata><name>Plan</name></metadata><rte><rtept lat="1" lon="2"/><rtept lat="1.01" lon="2"/></rte>'),
      fallbackTime: 5000,
    );
    expect(name, 'Plan');
    expect(points, hasLength(2));
    expect(points.every((p) => p.timestamp == 5000), isTrue);
    // No time between points means no moving time
    expect(accumulatePoints(points).stats.movingTimeMs, 0);
  });

  test('takes the metadata name and skips invalid points', () {
    final (:name, :points) = parseGpx(
      gpx('''<metadata><name>Day 1</name></metadata><trk><trkseg>
          <trkpt lat="95" lon="2"/><trkpt lat="x" lon="2"/><trkpt lon="2"/><trkpt lat="1" lon="2"/></trkseg></trk>'''),
      fallbackTime: 0,
    );
    expect(name, 'Day 1');
    expect(points, hasLength(1));
  });

  test('times out of order are kept in order; untimed points before the first take its time', () {
    final (name: _, :points) = parseGpx(
      gpx('''<trk><trkseg>
          <trkpt lat="1" lon="1"/>
          <trkpt lat="1" lon="1.001"><time>2026-10-01T01:00:00Z</time></trkpt>
          <trkpt lat="1" lon="1.002"><time>2026-10-01T00:30:00Z</time></trkpt>
          <trkpt lat="1" lon="1.003"/></trkseg></trk>'''),
      fallbackTime: 0,
    );
    expect([for (final p in points) p.timestamp], List.filled(4, t('2026-10-01T01:00:00Z')));
  });

  test('rejects files that are not GPX, have no points, or too many', () {
    Matcher fails(String why) => throwsA(isA<GpxImportException>().having((e) => e.message, 'message', contains(why)));
    expect(() => parseGpx('<kml></kml>', fallbackTime: 0), fails('not a valid GPX'));
    expect(() => parseGpx('not xml at all', fallbackTime: 0), fails('not a valid GPX'));
    expect(() => parseGpx(gpx('<wpt lat="1" lon="2"/>'), fallbackTime: 0), fails('no track or route'));
    final many = [for (var i = 0; i <= gpxImportMaxPoints; i++) '<trkpt lat="1" lon="1"/>'].join();
    expect(() => parseGpx(gpx('<trk><trkseg>$many</trkseg></trk>'), fallbackTime: 0), fails('more than 50,000 points'));
  });
}
