import 'dart:math' as math;

import '../survey/survey_model.dart';
import '../survey/survey_utils.dart';

// The numbers of the survey report (handleCapture in NavigationControls.tsx): one row per
// point, numbered across all lines, with the distance from the previous point of the same
// line (WGS84, like the map) and the running total that starts again at 0 on every line;
// the elevation profile puts the lines one after another without joining them.

class ReportRow {
  const ReportRow({
    required this.number,
    required this.lineName,
    required this.lineColor,
    required this.name,
    required this.lat,
    required this.lng,
    required this.elevation,
    required this.dist,
    required this.totalDist,
    required this.profileDist,
    required this.first,
  });

  final int number; // 1-based, across all lines
  final String lineName;
  final String lineColor; // #rrggbb
  final String? name;
  final double lat;
  final double lng;
  final double elevation;
  final double dist; // from the previous point of the line; 0 for the first
  final double totalDist; // along the line
  final double profileDist; // along all lines, for the profile's x axis
  final bool first; // first point of its line

  /// "Point 3" when the point has no name (the table always shows one)
  String get displayName => (name?.trim().isNotEmpty ?? false) ? name! : 'Point $number';

  /// The map label: the number, plus the name when there is one
  String get mapLabel => (name?.trim().isNotEmpty ?? false) ? '$number. ${name!}' : '$number';
}

class SurveyReport {
  const SurveyReport({required this.rows, required this.totalDistance, required this.lineCount});

  factory SurveyReport.of(List<SurveyGroup> groups) {
    final rows = <ReportRow>[];
    var offset = 0.0;
    for (final g in groups) {
      var total = 0.0;
      for (var i = 0; i < g.points.length; i++) {
        final p = g.points[i];
        final dist = i > 0 ? getAzimuthData(g.points[i - 1].geo, p.geo).horizontalDistance : 0.0;
        total += dist;
        rows.add(
          ReportRow(
            number: rows.length + 1,
            lineName: g.name,
            lineColor: g.color,
            name: p.name,
            lat: p.lat,
            lng: p.lng,
            elevation: p.elevation,
            dist: dist,
            totalDist: total,
            profileDist: offset + total,
            first: i == 0,
          ),
        );
      }
      offset += total;
    }
    return SurveyReport(rows: rows, totalDistance: offset, lineCount: groups.where((g) => g.points.isNotEmpty).length);
  }

  final List<ReportRow> rows;
  final double totalDistance; // all lines together
  final int lineCount; // lines with points

  bool get hasData => rows.isNotEmpty;

  /// The table gets a Line column when there is more than one line
  bool get showLineColumn => lineCount > 1;

  double get minElevation => rows.map((r) => r.elevation).reduce(math.min);
  double get maxElevation => rows.map((r) => r.elevation).reduce(math.max);

  /// Climb along each line; nothing counted between two lines
  double get elevationGain {
    var gain = 0.0;
    for (var i = 1; i < rows.length; i++) {
      if (rows[i].first) continue;
      final diff = rows[i].elevation - rows[i - 1].elevation;
      if (diff > 0) gain += diff;
    }
    return gain;
  }

  /// The profile's elevation axis: 10% beyond the range, or ±5 m when flat
  ({double min, double max}) get profileRange {
    final lo = minElevation, hi = maxElevation;
    final buffer = (hi - lo) * 0.1 == 0 ? 5.0 : (hi - lo) * 0.1;
    return (min: lo - buffer, max: hi + buffer);
  }

  /// The profile as separate runs, one per line (lines are not joined)
  List<List<ReportRow>> get profileSegments {
    final out = <List<ReportRow>>[];
    for (final r in rows) {
      if (r.first || out.isEmpty) out.add([]);
      out.last.add(r);
    }
    return out;
  }
}

/// "1.23" km for 1 km or more, else metres with one decimal (the report's Total Distance)
({String value, String unit}) reportDistance(double m) =>
    m >= 1000 ? (value: (m / 1000).toStringAsFixed(2), unit: 'km') : (value: m.toStringAsFixed(1), unit: 'm');
