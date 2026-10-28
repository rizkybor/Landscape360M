import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/domain/marked/marked_locations.dart';
import 'package:landscape360/domain/report/survey_report.dart';
import 'package:landscape360/domain/survey/survey_model.dart';
import 'package:landscape360/features/report/report_export.dart';
import 'package:landscape360/features/report/report_pages.dart';

// The survey report: numbers like the web (distances per line, gain not across lines, the
// profile's range), pages that continue when the table is long, and the files it makes

SurveyPoint pt(String id, double lng, double lat, double elev, {String? name}) =>
    SurveyPoint(id: id, lng: lng, lat: lat, elevation: elev, name: name);

const _gede = [(106.9800, -6.7800, 1800.0), (106.9810, -6.7810, 1900.0), (106.9820, -6.7820, 1850.0)];

List<SurveyGroup> groups({int extra = 0}) => [
  SurveyGroup(
    id: 'a',
    name: 'Jalur Cibodas',
    color: '#FFD700',
    points: [for (final (i, (lng, lat, e)) in _gede.indexed) pt('a$i', lng, lat, e, name: i == 1 ? 'Pos 3' : null)],
  ),
  SurveyGroup(
    id: 'b',
    name: 'Jalur Putri',
    color: '#365B25',
    points: [
      pt('b0', 106.99, -6.79, 1700),
      pt('b1', 106.991, -6.791, 1650),
      for (var i = 0; i < extra; i++) pt('x$i', 106.992 + i * 0.0005, -6.792, 1600 + i * 3.0),
    ],
  ),
];

Future<ui.Image> blank(int w, int h) async {
  final r = ui.PictureRecorder();
  Canvas(r).drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = const Color(0xFF55704A));
  return r.endRecording().toImage(w, h);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('numbers', () {
    final report = SurveyReport.of(groups());

    test('rows are numbered across lines; distance and total restart on each line', () {
      expect(report.rows.map((r) => r.number), [1, 2, 3, 4, 5]);
      expect(report.rows.map((r) => r.first), [true, false, false, true, false]);
      expect(report.rows[3].dist, 0);
      expect(report.rows[3].totalDist, 0);
      expect(report.rows[1].dist, closeTo(156, 2), reason: '~110 m east + ~110 m south');
      expect(report.rows[2].totalDist, closeTo(report.rows[1].dist + report.rows[2].dist, 1e-9));
      // The profile puts the second line after the first, without a gap
      expect(report.rows[3].profileDist, closeTo(report.rows[2].totalDist, 1e-9));
      expect(report.totalDistance, closeTo(report.rows[2].totalDist + report.rows[4].totalDist, 1e-9));
    });

    test('gain counts climbs inside each line only', () {
      // +100 on the first line; the drop to line 2 and its descent add nothing
      expect(report.elevationGain, 100);
      expect((report.minElevation, report.maxElevation), (1650, 1900));
      expect(report.profileRange, (min: 1625.0, max: 1925.0));
      expect(report.profileSegments.map((s) => s.length), [3, 2]);
      expect(report.showLineColumn, isTrue);
    });

    test('names: the table always has one, the map label adds it to the number', () {
      expect((report.rows[0].displayName, report.rows[0].mapLabel), ('Point 1', '1'));
      expect((report.rows[1].displayName, report.rows[1].mapLabel), ('Pos 3', '2. Pos 3'));
    });

    test('a flat survey gets ±5 m on the profile; distances in m or km', () {
      final flat = SurveyReport.of([
        SurveyGroup(id: 'f', name: 'F', color: '#000000', points: [pt('1', 0, 0, 10), pt('2', 0.001, 0, 10)]),
      ]);
      expect(flat.profileRange, (min: 5.0, max: 15.0));
      expect(flat.showLineColumn, isFalse);
      expect(reportDistance(950.25), (value: '950.3', unit: 'm'));
      expect(reportDistance(12345), (value: '12.35', unit: 'km'));
    });
  });

  group('pages and files', () {
    Future<List<ui.Image>> pages({int extra = 0, int places = 0}) async {
      final report = SurveyReport.of(groups(extra: extra));
      return ReportPainter(
        ReportInput(
          map: await blank(390, 844),
          viewSize: const Size(390, 844),
          pointPositions: [for (var i = 0; i < report.rows.length; i++) Offset(80 + i * 40.0, 300 + i * 30.0)],
          centerLat: -6.785,
          centerLng: 106.985,
          centerElevation: 1880,
          bearing: -20,
          pitch: 0,
          zoom: 15.2,
          report: report,
          places: [
            for (var i = 0; i < places; i++)
              ReportPlace(
                name: 'Mata air $i',
                category: MarkedLocationCategory.water,
                lat: -6.78,
                lng: 106.98,
                elevationM: 1700,
              ),
          ],
          exportedAt: DateTime(2026, 10, 29, 14, 5),
        ),
      ).draw();
    }

    test('A4 pages like the web: map and table, then the profile; long tables continue', () async {
      final two = await pages();
      expect(two, hasLength(2), reason: 'the profile does not fit under the map and table');
      expect((two.first.width, two.first.height), (2000, 2828));
      final many = await pages(extra: 60, places: 30);
      expect(many.length, greaterThan(2));
    });

    test('PNG and JPG: one file per page; PDF: one file', () async {
      final p = await pages(extra: 60);
      final at = DateTime(2026, 10, 29);
      final png = await encodeReport(p, ReportFormat.png, at: at);
      expect(png, hasLength(p.length));
      expect(png.first.name, endsWith('_Page_1.png'));
      final jpg = await encodeReport(p.sublist(0, 1), ReportFormat.jpg, at: at);
      final jpgBytes = jpg.single.bytes;
      expect(jpgBytes.sublist(0, 2), [0xFF, 0xD8], reason: 'JPEG');
      expect(jpg.single.name, 'Landscape360_Survey_${at.millisecondsSinceEpoch}.jpg');
      final pdf = await encodeReport(p, ReportFormat.pdf, at: at);
      final pdfBytes = pdf.single.bytes;
      expect(String.fromCharCodes(pdfBytes.sublist(0, 4)), '%PDF');
      expect(pdfBytes.lengthInBytes, lessThan(2 * 1024 * 1024 * p.length), reason: 'small');
    });

    test('only places inside the part of the map on the page are listed', () {
      const view = Size(390, 844);
      expect(reportMapShows(const Offset(200, 422), view), isTrue);
      expect(reportMapShows(const Offset(200, 5), view), isFalse, reason: 'cropped off the top');
      expect(reportMapShows(const Offset(-5, 422), view), isFalse);
    });
  });
}
