import '../geo/spherical.dart' show LngLat;
import '../util/js_compat.dart' show jsNumber;
import 'classic_nav.dart';
import 'field_work.dart';

// Everything the Classic panel and map show, worked out from the typed fields (classicSolve.ts).
// Each sighting is done in order, and the next one opens when the one before is complete:
// resection, your position found on the map once, then for each point azimuth -> back
// azimuth (lines from your position); intersection, position -> azimuth -> back azimuth (the
// azimuth lines cross at the object).

class SightingState {
  const SightingState({
    required this.label,
    this.point,
    this.pointError,
    required this.azimuth,
    required this.back,
    this.backCheck,
    this.backAnswer,
    required this.azOpen,
    required this.backOpen,
    required this.complete,
    required this.open,
  });

  /// "point A" (resection) or "position A" (intersection)
  final String label;
  final LngLat? point;
  final String? pointError;
  final Parsed azimuth;
  final Parsed back;
  final Check? backCheck;
  final double? backAnswer;

  /// Steps open in order
  final bool azOpen;
  final bool backOpen;
  final bool complete;

  /// This sighting can be filled in (the one before it is complete)
  final bool open;
}

class SolvedLine extends Line {
  const SolvedLine({required this.index, required super.from, required super.bearing});
  final int index;
}

class ClassicSolution {
  const ClassicSolution({
    required this.sightings,
    required this.pointsReady,
    this.origin,
    this.originError,
    required this.declination,
    required this.lines,
    this.fix,
    this.problem,
    required this.review,
  });

  final List<SightingState> sightings;

  /// Every point has a valid position (resection: your position is set)
  final bool pointsReady;

  /// Resection: your position, the start of every line
  final LngLat? origin;
  final String? originError;
  final Parsed declination;

  /// The line drawn from each complete sighting (true bearings)
  final List<SolvedLine> lines;
  final Fix? fix;
  final String? problem;
  final List<Check> review;
}

const _minSpacingM = 50;

({LngLat? value, String? error}) parsePoint(PointInput p) {
  final lat = parseDms(p.lat, 90, 'latitude');
  final lng = parseDms(p.lng, 180, 'longitude');
  final error = lat.error ?? lng.error;
  if (error != null) return (value: null, error: error);
  if (lat.value == null && lng.value == null) return (value: null, error: null);
  if (lat.value == null || lng.value == null) return (value: null, error: 'Enter both the latitude and the longitude.');
  return (value: (p.west ? -lng.value! : lng.value!, p.south ? -lat.value! : lat.value!), error: null);
}

/// Point A, B, C… (resection reference points) or position A, B, C… (intersection)
String sightingLabel(ClassicMode mode, int i) =>
    '${mode == ClassicMode.resection ? 'point' : 'position'} ${String.fromCharCode(65 + i)}';

ClassicSolution solveClassic({
  required ClassicMode mode,
  required List<Sighting> sightings,
  required PointInput origin,
  required String declination,
}) {
  final resection = mode == ClassicMode.resection;

  final decl = declination.trim().isEmpty ? '0' : declination.trim().replaceFirst(',', '.');
  final declValue = jsNumber(decl);
  final declinationParsed = declValue.isFinite && declValue.abs() <= 30
      ? Parsed.value(declValue)
      : const Parsed.error('Declination is a small angle in degrees, e.g. 0.8 (east) or -1.2 (west).');
  final d = declinationParsed.value ?? 0;

  // Resection: your position, set once; every point's bearings start from it
  final originParsed = parsePoint(origin);
  final originPoint = resection ? originParsed.value : null;

  // Positions first. Two points on top of each other cannot be sighted apart.
  final places = <({LngLat? point, String? error})>[];
  for (final (i, s) in sightings.indexed) {
    if (resection) {
      places.add((point: originPoint, error: null));
      continue;
    }
    var (:value, :error) = parsePoint(s.point);
    var point = value;
    if (point != null) {
      for (final (k, other) in places.indexed) {
        if (other.point != null && bearingTo(point!, other.point!).distance < _minSpacingM) {
          error =
              'This is within $_minSpacingM m of ${sightingLabel(mode, k)}. Choose a point you would sight from a distance.';
          point = null;
          break;
        }
      }
    }
    places.add((point: point, error: error));
    assert(places.length == i + 1);
  }
  // Resection finds every reference point on the map first (one step), then sights them one
  // by one; intersection finds each position as you move there
  final pointsReady = places.every((p) => p.point != null);

  final states = <SightingState>[];
  for (final (i, s) in sightings.indexed) {
    final label = sightingLabel(mode, i);
    final open = (!resection || pointsReady) && (i == 0 || states[i - 1].complete);
    final (:point, error: pointError) = places[i];

    final azimuth = parseCompass(s.azimuth, 'azimuth');
    final back = parseCompass(s.back, 'back azimuth');
    final azOpen = open && point != null && declinationParsed.value != null;

    // The azimuth only has to be a valid compass reading (no real point to grade it against)
    final azDone = azOpen && azimuth.value != null && s.azChecks > 0;

    // Then the back azimuth (both modes): the opposite direction, to the tenth of a degree
    final backOpen = azDone;
    Check? backCheck;
    double? backAnswer;
    if (backOpen && back.value != null && s.backChecks > 0) {
      backCheck = checkBackAzimuth(back.value!, azimuth.value!);
      if (s.backChecks >= 2 && backCheck.verdict == Verdict.off) backAnswer = normalize360(azimuth.value! + 180);
    }
    final complete = backOpen && backCheck?.verdict == Verdict.ok;

    states.add(
      SightingState(
        label: label,
        point: point,
        pointError: pointError,
        azimuth: azimuth,
        back: back,
        backCheck: backCheck,
        backAnswer: backAnswer,
        azOpen: azOpen,
        backOpen: backOpen,
        complete: complete,
        open: open,
      ),
    );
  }

  // Intersection: a line from each position along its azimuth (true bearing), crossing at
  // the object. Resection draws its lines from your one position, so they do not cross.
  final lines = resection
      ? <SolvedLine>[]
      : [
          for (final (index, s) in states.indexed)
            if (s.complete && s.point != null)
              SolvedLine(index: index, from: s.point!, bearing: normalize360(s.azimuth.value! + d)),
        ];

  Fix? fix;
  String? problem;
  var review = <Check>[];
  if (lines.length >= 2) {
    fix = fixFromLines(lines);
    if (fix == null) {
      problem = 'The lines are parallel, so they never cross. Sight objects in clearly different directions.';
    } else {
      final behind = fix.along.indexWhere((a) => a < 0);
      if (behind >= 0) {
        final label = states[lines[behind].index].label;
        problem = resection
            ? 'The lines only meet behind $label: its back azimuth points away from you. Check the azimuth to $label.'
            : 'The lines only meet behind $label: its azimuth points away from the object. Check the sighting from $label.';
        fix = null;
      } else {
        review = reviewFix(fix, lines, mode.name, [for (final l in lines) states[l.index].label]);
      }
    }
  }

  return ClassicSolution(
    sightings: states,
    pointsReady: pointsReady,
    origin: originPoint,
    originError: resection ? originParsed.error : null,
    declination: declinationParsed,
    lines: lines,
    fix: fix,
    problem: problem,
    review: review,
  );
}
