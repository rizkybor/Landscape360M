// Port of the platform-independent parts of src/lib/deviceHeading.ts and the needle
// smoothing in src/components/UserLocationMarker.tsx. The heading is where the top edge of
// the phone points, in degrees clockwise from north.

double _normalize(double deg) => (deg.remainder(360) + 360).remainder(360);

class CompassReading {
  const CompassReading({required this.heading, required this.accuracy});

  /// Degrees clockwise from north; null while the compass is not calibrated
  final double? heading;

  /// Error in degrees when the platform reports one (iOS; -1 = not calibrated), else null
  final double? accuracy;
}

/// Reading from a native compass event (flutter_compass: heading and accuracy in degrees)
CompassReading? readNativeCompass({required double? heading, required double? accuracy}) {
  if (heading == null || heading.isNaN) return null;
  return CompassReading(heading: accuracy != null && accuracy < 0 ? null : _normalize(heading), accuracy: accuracy);
}

/// Reading from the flutter_compass plugin. Its accuracy is in degrees on iOS (-1 = not
/// calibrated); on Android it is 15 / 30 / 45 for the sensor's high / medium / low status and
/// -1 while the sensor has not reported one yet, which means "unknown", not "uncalibrated".
CompassReading? readPluginCompass({required double? heading, required double? accuracy, required bool android}) {
  final a = android && (accuracy == null || accuracy < 0) ? null : accuracy;
  return readNativeCompass(heading: heading, accuracy: a);
}

/// Preference set once the user closes the calibration hint (same key as the web)
const compassHintDismissedKey = 'l360-compass-hint-dismissed';

// The app cannot calibrate the sensor (the phone does, with the figure-8 motion); it can
// only notice when readings are not trustworthy. With an accuracy that is used; without
// one, a jump of 40°+ between two readings a few ms apart (impossible by hand) counts as
// noise, and three such jumps within 3 s mean the compass needs calibrating.
const _poorAccuracyDeg = 30;
const _jumpDeg = 40;
const _jumpWindowMs = 100;
const _jumpsNeeded = 3;
const _jumpsWithinMs = 3000;
const _poorHoldMs = 4000;

enum CompassQuality { ok, poor }

class CompassQualityTracker {
  double? _last;
  int _lastAt = 0;
  List<int> _jumps = [];
  int _poorUntil = 0;

  /// Feed every reading; returns whether the compass currently looks trustworthy
  CompassQuality push(CompassReading reading, int now) {
    final accuracy = reading.accuracy;
    if (accuracy != null) {
      return accuracy < 0 || accuracy > _poorAccuracyDeg ? CompassQuality.poor : CompassQuality.ok;
    }
    final heading = reading.heading;
    if (heading == null) return CompassQuality.ok;
    final last = _last;
    if (last != null && now - _lastAt < _jumpWindowMs) {
      final delta = (((heading - last).remainder(360) + 540).remainder(360) - 180).abs();
      if (delta > _jumpDeg) _jumps.add(now);
    }
    _last = heading;
    _lastAt = now;
    _jumps = _jumps.where((t) => now - t < _jumpsWithinMs).toList();
    if (_jumps.length >= _jumpsNeeded) {
      _poorUntil = now + _poorHoldMs;
      _jumps = [];
    }
    return now < _poorUntil ? CompassQuality.poor : CompassQuality.ok;
  }
}

/// Smallest needle turn that is drawn (degrees)
const minTurnDeg = 1.5;

/// Next angle to draw the needle at, turning the shortest way round from [shown]; null
/// when the change is too small to redraw. The result is not wrapped to 0..360, so the
/// needle never spins the long way when it crosses north.
double? nextNeedleAngle(double? shown, double latest) {
  if (shown == null) return latest;
  final delta = ((latest - shown).remainder(360) + 540).remainder(360) - 180;
  if (delta.abs() < minTurnDeg) return null;
  return shown + delta;
}
