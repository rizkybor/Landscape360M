import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/domain/compass/device_heading.dart';

// Same cases as the platform-independent parts of src/lib/deviceHeading.test.ts (web)

void main() {
  group('readNativeCompass', () {
    test('uses the heading as is (clockwise from north)', () {
      expect(readNativeCompass(heading: 90, accuracy: 10)?.heading, 90);
      expect(readNativeCompass(heading: 359.5, accuracy: null)?.heading, 359.5);
      expect(readNativeCompass(heading: -90, accuracy: null)?.heading, 270);
      expect(readNativeCompass(heading: 450, accuracy: null)?.heading, 90);
    });

    test('ignores an uncalibrated compass', () {
      final r = readNativeCompass(heading: 90, accuracy: -1);
      expect(r, isNotNull);
      expect(r!.heading, isNull);
    });

    test('returns null without compass data', () {
      expect(readNativeCompass(heading: null, accuracy: null), isNull);
      expect(readNativeCompass(heading: double.nan, accuracy: 5), isNull);
    });
  });

  group('readPluginCompass', () {
    test('Android: -1 before the sensor reports means unknown, not uncalibrated', () {
      final r = readPluginCompass(heading: 120, accuracy: -1, android: true)!;
      expect((r.heading, r.accuracy), (120.0, null));
      final q = CompassQualityTracker();
      expect(q.push(r, 0), CompassQuality.ok);
    });

    test('Android: low sensor status (45) is poor, high (15) is ok', () {
      final q = CompassQualityTracker();
      expect(q.push(readPluginCompass(heading: 10, accuracy: 45, android: true)!, 0), CompassQuality.poor);
      expect(q.push(readPluginCompass(heading: 10, accuracy: 15, android: true)!, 0), CompassQuality.ok);
    });

    test('iOS: -1 means not calibrated', () {
      final r = readPluginCompass(heading: 120, accuracy: -1, android: false)!;
      expect(r.heading, isNull);
      expect(CompassQualityTracker().push(r, 0), CompassQuality.poor);
    });
  });

  group('CompassQualityTracker', () {
    test('with accuracy: poor while uncalibrated or inaccurate, ok otherwise', () {
      final q = CompassQualityTracker();
      expect(q.push(const CompassReading(heading: null, accuracy: -1), 0), CompassQuality.poor);
      expect(q.push(const CompassReading(heading: 10, accuracy: 45), 0), CompassQuality.poor);
      expect(q.push(const CompassReading(heading: 10, accuracy: 12), 0), CompassQuality.ok);
    });

    test('without accuracy: poor after three impossible jumps within a few seconds, then recovers', () {
      final q = CompassQualityTracker();
      var t = 1000;
      CompassQuality r(double heading) => q.push(CompassReading(heading: heading, accuracy: null), t);
      expect(r(10), CompassQuality.ok);
      t += 16;
      expect(r(100), CompassQuality.ok); // jump 1
      t += 16;
      expect(r(10), CompassQuality.ok); // jump 2
      t += 16;
      expect(r(200), CompassQuality.poor); // jump 3
      t += 2000;
      expect(r(201), CompassQuality.poor); // still held
      t += 3000;
      expect(r(202), CompassQuality.ok); // settled
    });

    test('turning by hand is not a jump', () {
      final q = CompassQualityTracker();
      var t = 0;
      for (var h = 0; h <= 180; h += 30) {
        t += 200;
        expect(q.push(CompassReading(heading: h.toDouble(), accuracy: null), t), CompassQuality.ok);
      }
    });
  });

  group('nextNeedleAngle', () {
    test('ignores turns under 1.5° and turns the shortest way across north', () {
      expect(nextNeedleAngle(null, 42), 42);
      expect(nextNeedleAngle(10, 11), isNull);
      expect(nextNeedleAngle(10, 12), 12);
      expect(nextNeedleAngle(359, 2), 362);
      expect(nextNeedleAngle(2, 358), -2);
    });
  });
}
