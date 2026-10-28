import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../../core/theme/app_theme.dart';
import '../../domain/marked/marked_locations.dart';
import '../../domain/report/survey_report.dart';
import '../../domain/survey/survey_utils.dart';

// The survey report pages, drawn like the web's (NavigationControls.tsx): A4 at 1600 px wide
// (rendered at 1.25× for sharp text), a header with the logo and date, the map with the
// numbered survey points and a box of map facts, the table of points (continued on more
// pages when needed), the elevation profile with its figures, the marked locations in view,
// and a footer with the page number on every page.

const reportPageWidth = 1600.0;
final reportPageHeight = (reportPageWidth * 1.414).floorToDouble();
const reportRenderScale = 1.25;

const _margin = 40.0;
const _footerHeight = 60.0;
const _rowHeight = 45.0;
const _headerBottom = 120.0; // under the header's divider
const _chartHeight = 350.0;

/// A marked location shown on the exported map
class ReportPlace {
  const ReportPlace({
    required this.name,
    required this.category,
    required this.lat,
    required this.lng,
    this.elevationM,
  });

  final String name;
  final MarkedLocationCategory category;
  final double lat;
  final double lng;
  final double? elevationM;
}

/// Everything a report shows, read from the map before drawing
class ReportInput {
  const ReportInput({
    required this.map,
    required this.viewSize,
    required this.pointPositions,
    required this.centerLat,
    required this.centerLng,
    required this.centerElevation,
    required this.bearing,
    required this.pitch,
    required this.zoom,
    required this.report,
    required this.places,
    required this.exportedAt,
    this.logo,
  });

  final ui.Image map; // the map's snapshot
  final Size viewSize; // the map on screen (logical px)
  final List<Offset?> pointPositions; // each report row on screen, or null when off it
  final double centerLat;
  final double centerLng;
  final double? centerElevation;
  final double bearing;
  final double pitch;
  final double zoom;
  final SurveyReport report;
  final List<ReportPlace> places; // marked locations in the exported map
  final DateTime exportedAt;
  final ui.Image? logo;
}

Color _hex(String hex) => Color(int.parse('FF${hex.replaceFirst('#', '')}', radix: 16));

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
String _two(int n) => n.toString().padLeft(2, '0');

/// Height of the map on the first page: full width, at most 55% of the page (cropped
/// around the middle, as a phone screen is much taller than wide)
double reportMapBoxHeight(Size view) {
  final displayHeight = (reportPageWidth - 2 * _margin) * view.height / view.width;
  return math.min(displayHeight, reportPageHeight * 0.55);
}

/// The places within the part of the map that fits on the page
bool reportMapShows(Offset p, Size view) {
  final displayHeight = (reportPageWidth - 2 * _margin) * view.height / view.width;
  final box = reportMapBoxHeight(view);
  final cropTop = (displayHeight - box) / 2 * (view.height / displayHeight);
  return p.dx >= 0 && p.dx <= view.width && p.dy >= cropTop && p.dy <= view.height - cropTop;
}

class _Page {
  _Page(this.number, {required this.first}) : recorder = ui.PictureRecorder() {
    canvas = Canvas(recorder)..scale(reportRenderScale);
    canvas.drawRect(Rect.fromLTWH(0, 0, reportPageWidth, reportPageHeight), Paint()..color = const Color(0xFFFFFFFF));
  }

  final int number;
  final bool first;
  final ui.PictureRecorder recorder;
  late final Canvas canvas;
  double y = _headerBottom + 20;

  double get room => reportPageHeight - _footerHeight - 20 - y;
}

class ReportPainter {
  ReportPainter(this.input);

  final ReportInput input;
  final _pages = <_Page>[];

  /// The finished pages, as images of 2000 × 2827 px
  Future<List<ui.Image>> draw() async {
    var page = _newPage();
    _map(page);
    page.y = _headerBottom + 20 + reportMapBoxHeight(input.viewSize) + 40;
    page = _pointsTable(page);
    if (input.report.hasData) page = _profile(page);
    if (input.places.isNotEmpty) page = _placesTable(page);
    final images = <ui.Image>[];
    for (final p in _pages) {
      final picture = p.recorder.endRecording();
      images.add(
        await picture.toImage(
          (reportPageWidth * reportRenderScale).round(),
          (reportPageHeight * reportRenderScale).round(),
        ),
      );
    }
    return images;
  }

  _Page _newPage() {
    final p = _Page(_pages.length + 1, first: _pages.isEmpty);
    _pages.add(p);
    _header(p);
    _footer(p);
    return p;
  }

  // --- Text ------------------------------------------------------------------------------

  TextPainter _layout(
    String text, {
    double size = 12,
    FontWeight weight = FontWeight.w400,
    Color color = L360Colors.ink,
    double spacing = 0,
    double? maxWidth,
    bool tabular = false,
    List<Shadow>? shadows,
  }) => TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontFamily: 'Inter',
        fontSize: size,
        fontWeight: weight,
        color: color,
        letterSpacing: spacing,
        height: 1.15,
        shadows: shadows,
        fontFeatures: tabular ? const [FontFeature.tabularFigures()] : null,
      ),
    ),
    textDirection: TextDirection.ltr,
    maxLines: maxWidth == null ? null : 1,
    ellipsis: maxWidth == null ? null : '…',
  )..layout(maxWidth: maxWidth ?? double.infinity);

  /// Draws text at (x, y) (top left; or top right when [right])
  double _text(
    Canvas c,
    String text,
    double x,
    double y, {
    double size = 12,
    FontWeight weight = FontWeight.w400,
    Color color = L360Colors.ink,
    double spacing = 0,
    double? maxWidth,
    bool right = false,
    bool center = false,
    bool tabular = false,
    List<Shadow>? shadows,
  }) {
    final tp = _layout(
      text,
      size: size,
      weight: weight,
      color: color,
      spacing: spacing,
      maxWidth: maxWidth,
      tabular: tabular,
      shadows: shadows,
    );
    final dx = right ? x - tp.width : (center ? x - tp.width / 2 : x);
    tp.paint(c, Offset(dx, y));
    return tp.width;
  }

  RRect _rr(Rect r, double radius) => RRect.fromRectAndRadius(r, Radius.circular(radius));

  // --- Header and footer -------------------------------------------------------------------

  void _header(_Page p) {
    final c = p.canvas;
    final logo = input.logo;
    if (logo != null) {
      paintImage(
        canvas: c,
        rect: const Rect.fromLTWH(_margin, _margin, 40, 40),
        image: logo,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
      );
    }
    _text(c, 'Landscape 360', _margin + 56, _margin + 2, size: 20, weight: FontWeight.w800, spacing: -0.4);
    _text(
      c,
      (p.first ? 'Professional Survey Report' : 'Survey Report Continuation').toUpperCase(),
      _margin + 56,
      _margin + 28,
      size: 10,
      color: L360Colors.forest600,
      spacing: 1,
    );
    final t = input.exportedAt;
    _text(
      c,
      '${_two(t.day)} ${_months[t.month - 1]} ${t.year}',
      reportPageWidth - _margin,
      _margin,
      size: 12,
      weight: FontWeight.w700,
      right: true,
    );
    _text(
      c,
      '${_two(t.hour)}:${_two(t.minute)}',
      reportPageWidth - _margin,
      _margin + 18,
      size: 10,
      color: L360Colors.sand500,
      right: true,
    );
    c.drawRect(
      Rect.fromLTWH(_margin, _headerBottom - 1, reportPageWidth - 2 * _margin, 1),
      Paint()..color = L360Colors.sand200,
    );
  }

  void _footer(_Page p) {
    final c = p.canvas;
    final top = reportPageHeight - _footerHeight;
    c.drawRect(Rect.fromLTWH(0, top, reportPageWidth, 1), Paint()..color = L360Colors.sand200);
    final mid = top + _footerHeight / 2 - 6;
    var x = _margin;
    x += _text(c, '© ${input.exportedAt.year} Landscape 360', x, mid, size: 10, color: L360Colors.sand500) + 16;
    x += _text(c, '|', x, mid, size: 10, color: L360Colors.sand400) + 16;
    _text(c, 'Professional Survey Report', x, mid, size: 10, color: L360Colors.sand500);
    _text(c, 'Page ${p.number}', reportPageWidth - _margin, mid, size: 10, weight: FontWeight.w500, right: true);
  }

  // --- Map -----------------------------------------------------------------------------------

  void _map(_Page p) {
    final c = p.canvas;
    final view = input.viewSize;
    final width = reportPageWidth - 2 * _margin;
    final displayHeight = width * view.height / view.width;
    final boxHeight = reportMapBoxHeight(view);
    final box = Rect.fromLTWH(_margin, _headerBottom + 20, width, boxHeight);
    final innerTop = box.top - (displayHeight - boxHeight) / 2;

    c
      ..save()
      ..clipRRect(_rr(box, 16));
    paintImage(
      canvas: c,
      rect: Rect.fromLTWH(box.left, innerTop, width, displayHeight),
      image: input.map,
      fit: BoxFit.fill,
      filterQuality: FilterQuality.high,
    );

    // Survey points: a diamond in the line's colour and a pill with the number and height
    for (final (i, row) in input.report.rows.indexed) {
      final pos = input.pointPositions.length > i ? input.pointPositions[i] : null;
      if (pos == null) continue;
      if (pos.dx < -100 || pos.dx > view.width + 100 || pos.dy < -100 || pos.dy > view.height + 100) continue;
      final at = Offset(box.left + pos.dx / view.width * width, innerTop + pos.dy / view.height * displayHeight);
      c
        ..save()
        ..translate(at.dx, at.dy)
        ..rotate(math.pi / 4)
        ..drawRect(const Rect.fromLTWH(-8, -8, 16, 16), Paint()..color = const Color(0xFFFFFFFF))
        ..drawRect(const Rect.fromLTWH(-6, -6, 12, 12), Paint()..color = _hex(row.lineColor))
        ..restore();
      final name = _layout(row.mapLabel.toUpperCase(), size: 14, weight: FontWeight.w700, spacing: 0.3);
      final elev = _layout(
        '${row.elevation.toStringAsFixed(1)} mdpl',
        size: 14,
        weight: FontWeight.w500,
        color: L360Colors.forest600,
        spacing: 0.3,
      );
      final pillW = name.width + 12 + elev.width + 28;
      final pillH = math.max(name.height, elev.height) + 12;
      final pill = Rect.fromLTWH(at.dx - pillW / 2, at.dy - 12 - 8 - pillH, pillW, pillH);
      c
        ..drawRRect(
          _rr(pill.shift(const Offset(0, 3)), 24),
          Paint()
            ..color = const Color(0x22000000)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
        )
        ..drawRRect(_rr(pill, 24), Paint()..color = const Color(0xEBFFFFFF))
        ..drawRRect(
          _rr(pill, 24),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = L360Colors.forest600,
        );
      name.paint(c, Offset(pill.left + 14, pill.top + 6));
      elev.paint(c, Offset(pill.left + 14 + name.width + 12, pill.top + 6));
    }

    // Facts about the map, bottom left; credit bottom right
    final facts = [
      (
        'Map Center',
        '${toDMS(input.centerLat, isLat: true)}, ${toDMS(input.centerLng, isLat: false)}',
        '${input.centerLat.toStringAsFixed(6)}, ${input.centerLng.toStringAsFixed(6)}',
      ),
      (
        'Center Elevation',
        input.centerElevation == null ? '—' : '${input.centerElevation!.toStringAsFixed(0)} mdpl',
        null,
      ),
      (
        'Heading / Tilt',
        '${(((input.bearing % 360) + 360) % 360).toStringAsFixed(1)}° / ${input.pitch.toStringAsFixed(1)}°',
        null,
      ),
      ('Zoom', input.zoom.toStringAsFixed(1), null),
    ];
    const labelW = 120.0, gap = 16.0;
    final valueW = facts
        .map((f) => math.max(_layout(f.$2, weight: FontWeight.w700).width, f.$3 == null ? 0.0 : _layout(f.$3!).width))
        .reduce(math.max);
    final factsH = facts.fold<double>(0, (h, f) => h + (f.$3 == null ? 16 : 32) + 8) - 8 + 32;
    final factsBox = Rect.fromLTWH(box.left + 40, box.bottom - 40 - factsH, labelW + gap + valueW + 32, factsH);
    c
      ..drawRRect(_rr(factsBox, 16), Paint()..color = const Color(0xEBFFFFFF))
      ..drawRRect(
        _rr(factsBox, 16),
        Paint()
          ..style = PaintingStyle.stroke
          ..color = L360Colors.sand200,
      );
    var fy = factsBox.top + 16;
    for (final (label, value, sub) in facts) {
      _text(c, label, factsBox.left + 16, fy, color: L360Colors.sand500);
      _text(
        c,
        value,
        factsBox.left + 16 + labelW + gap,
        fy,
        weight: FontWeight.w700,
        color: label == 'Center Elevation' ? L360Colors.gold700 : L360Colors.ink,
      );
      if (sub != null) _text(c, sub, factsBox.left + 16 + labelW + gap, fy + 16, color: L360Colors.sand500);
      fy += (sub == null ? 16 : 32) + 8;
    }
    const shadow = [Shadow(color: Color(0x80000000), blurRadius: 4, offset: Offset(0, 2))];
    _text(
      c,
      'Generated by Landscape 360',
      box.right - 40,
      box.bottom - 40 - 26,
      size: 10,
      weight: FontWeight.w600,
      color: const Color(0xCCFFFFFF),
      right: true,
      shadows: shadow,
    );
    _text(
      c,
      'Powered by Jendela Cakra Digital & Makopala UBL',
      box.right - 40,
      box.bottom - 40 - 11,
      size: 9,
      color: const Color(0x99FFFFFF),
      right: true,
      shadows: shadow,
    );
    c
      ..restore()
      ..drawRRect(
        _rr(box, 16),
        Paint()
          ..style = PaintingStyle.stroke
          ..color = L360Colors.sand200,
      );
  }

  // --- Tables --------------------------------------------------------------------------------

  /// A section title with its coloured bar; returns the y under it
  double _title(Canvas c, String text, double y, Color bar) {
    c.drawRRect(_rr(Rect.fromLTWH(_margin, y, 4, 24), 4), Paint()..color = bar);
    _text(c, text, _margin + 16, y + 2, size: 18, weight: FontWeight.w700);
    return y + 24 + 16;
  }

  /// Column header row; [columns] are (title, x)
  double _tableHead(Canvas c, List<(String, double)> columns, double y) {
    const h = 36.0;
    c
      ..drawRect(Rect.fromLTWH(_margin, y, reportPageWidth - 2 * _margin, h), Paint()..color = L360Colors.sand100)
      ..drawRect(
        Rect.fromLTWH(_margin, y + h - 2, reportPageWidth - 2 * _margin, 2),
        Paint()..color = L360Colors.sand300,
      );
    for (final (title, x) in columns) {
      _text(
        c,
        title.toUpperCase(),
        x,
        y + 12,
        size: 10,
        weight: FontWeight.w600,
        color: L360Colors.sand600,
        spacing: 0.5,
      );
    }
    return y + h;
  }

  void _rowLine(Canvas c, double y) => c.drawRect(
    Rect.fromLTWH(_margin, y + _rowHeight - 1, reportPageWidth - 2 * _margin, 1),
    Paint()..color = L360Colors.sand200,
  );

  List<(String, double)> get _pointColumns {
    final line = input.report.showLineColumn;
    const x0 = _margin + 10;
    return [
      ('#', x0),
      if (line) ('Line', x0 + 60),
      ('Point Name', x0 + (line ? 240 : 60)),
      ('Coordinates', x0 + (line ? 560 : 420)),
      ('Elevation', x0 + 1000),
      ('Dist.', x0 + 1170),
      ('Total', x0 + 1340),
    ];
  }

  _Page _startPointsTable(_Page p) {
    p.y = _title(p.canvas, 'Survey Data Points', p.y, L360Colors.gold400);
    p.y = _tableHead(p.canvas, _pointColumns, p.y);
    return p;
  }

  _Page _pointsTable(_Page page) {
    var p = _startPointsTable(page);
    final rows = input.report.rows;
    if (rows.isEmpty) {
      _text(
        p.canvas,
        'No Survey Data Available',
        reportPageWidth / 2,
        p.y + 60,
        size: 16,
        weight: FontWeight.w600,
        center: true,
      );
      _text(
        p.canvas,
        'Start adding points to generate a professional report',
        reportPageWidth / 2,
        p.y + 86,
        size: 13,
        color: L360Colors.sand500,
        center: true,
      );
      p.y += 200;
      return p;
    }
    final cols = {for (final (t, x) in _pointColumns) t: x};
    for (final r in rows) {
      if (p.room < _rowHeight) {
        p = _startPointsTable(_newPage());
      }
      final c = p.canvas;
      final ty = p.y + 15;
      _text(c, '${r.number}', cols['#']!, ty, weight: FontWeight.w700, color: L360Colors.gold700, tabular: true);
      if (cols.containsKey('Line')) {
        c.drawCircle(Offset(cols['Line']! + 4, ty + 7), 4, Paint()..color = _hex(r.lineColor));
        _text(c, r.lineName, cols['Line']! + 14, ty, color: L360Colors.sand700, maxWidth: 160);
      }
      _text(c, r.displayName, cols['Point Name']!, ty, weight: FontWeight.w500, maxWidth: 300);
      _text(
        c,
        '${toDMS(r.lat, isLat: true)}, ${toDMS(r.lng, isLat: false)}',
        cols['Coordinates']!,
        ty,
        color: L360Colors.sand700,
        tabular: true,
      );
      _text(c, '${r.elevation.toStringAsFixed(1)} m', cols['Elevation']!, ty, color: L360Colors.gold700, tabular: true);
      _text(
        c,
        r.first ? '-' : '${r.dist.toStringAsFixed(1)} m',
        cols['Dist.']!,
        ty,
        color: L360Colors.sand700,
        tabular: true,
      );
      _text(c, '${r.totalDist.toStringAsFixed(1)} m', cols['Total']!, ty, color: L360Colors.sand500, tabular: true);
      _rowLine(c, p.y);
      p.y += _rowHeight;
    }
    return p;
  }

  _Page _placesTable(_Page page) {
    var p = page;
    const headRoom = 40.0 + 36 + 32;
    if (p.room < headRoom + _rowHeight) p = _newPage();
    List<(String, double)> columns() => const [
      ('#', _margin + 10),
      ('Name', _margin + 70),
      ('Category', _margin + 560),
      ('Coordinates', _margin + 860),
      ('Elevation', _margin + 1300),
    ];
    void start(bool cont) {
      p.y += 32;
      p.y = _title(p.canvas, 'Marked Locations in View${cont ? ' (continued)' : ''}', p.y, L360Colors.gold500);
      p.y = _tableHead(p.canvas, columns(), p.y);
    }

    start(false);
    final cols = {for (final (t, x) in columns()) t: x};
    for (final (i, l) in input.places.indexed) {
      if (p.room < _rowHeight) {
        p = _newPage();
        start(true);
      }
      final c = p.canvas;
      final ty = p.y + 15;
      _text(c, '${i + 1}', cols['#']!, ty, weight: FontWeight.w700, color: L360Colors.gold700);
      _text(c, l.name, cols['Name']!, ty, weight: FontWeight.w500, maxWidth: 470);
      c.drawCircle(Offset(cols['Category']! + 4, ty + 7), 4, Paint()..color = Color(l.category.color));
      _text(c, l.category.label, cols['Category']! + 14, ty, color: L360Colors.sand700, maxWidth: 270);
      _text(
        c,
        '${toDMS(l.lat, isLat: true)}, ${toDMS(l.lng, isLat: false)}',
        cols['Coordinates']!,
        ty,
        color: L360Colors.sand700,
        tabular: true,
      );
      _text(
        c,
        l.elevationM == null ? '—' : '${l.elevationM!.round()} m',
        cols['Elevation']!,
        ty,
        color: L360Colors.gold700,
        tabular: true,
      );
      _rowLine(c, p.y);
      p.y += _rowHeight;
    }
    return p;
  }

  // --- Elevation profile -------------------------------------------------------------------

  _Page _profile(_Page page) {
    var p = page;
    const blockHeight = _chartHeight + 330;
    if (p.room < blockHeight) p = _newPage();
    final c = p.canvas;
    final report = input.report;
    final card = Rect.fromLTWH(_margin, p.y + 40, reportPageWidth - 2 * _margin, blockHeight - 40);
    c
      ..drawRRect(
        _rr(card.shift(const Offset(0, 8)), 24),
        Paint()
          ..color = const Color(0x14000000)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
      )
      ..drawRRect(_rr(card, 24), Paint()..color = const Color(0xFFFFFFFF))
      ..drawRRect(
        _rr(card, 24),
        Paint()
          ..style = PaintingStyle.stroke
          ..color = L360Colors.sand200,
      );
    var y = card.top + 40;
    final x0 = card.left + 40;
    c.drawRRect(_rr(Rect.fromLTWH(x0, y, 6, 32), 4), Paint()..color = L360Colors.forest600);
    _text(c, 'Elevation Profile Analysis', x0 + 22, y - 2, size: 24, weight: FontWeight.w800, spacing: -0.4);
    _text(
      c,
      'Terrain cross-section and gradient analysis',
      x0 + 22,
      y + 26,
      size: 12,
      weight: FontWeight.w500,
      color: L360Colors.sand500,
    );
    y += 32 + 32;

    // Four figures
    final total = reportDistance(report.totalDistance);
    final stats = [
      ('Min Elevation', report.minElevation.toStringAsFixed(1), 'm', L360Colors.ink),
      ('Max Elevation', report.maxElevation.toStringAsFixed(1), 'm', L360Colors.ink),
      ('Total Distance', total.value, total.unit, L360Colors.ink),
      ('Elev. Gain', '+${report.elevationGain.toStringAsFixed(1)}', 'm', L360Colors.forest600),
    ];
    final innerW = card.width - 80;
    final statW = (innerW - 3 * 16) / 4;
    for (final (i, (label, value, unit, color)) in stats.indexed) {
      final r = Rect.fromLTWH(x0 + i * (statW + 16), y, statW, 96);
      c
        ..drawRRect(_rr(r, 12), Paint()..color = L360Colors.sand50)
        ..drawRRect(
          _rr(r, 12),
          Paint()
            ..style = PaintingStyle.stroke
            ..color = L360Colors.sand200,
        );
      _text(
        c,
        label.toUpperCase(),
        r.left + 20,
        r.top + 20,
        weight: FontWeight.w600,
        color: L360Colors.sand500,
        spacing: 0.6,
      );
      final w = _text(
        c,
        value,
        r.left + 20,
        r.top + 44,
        size: 24,
        weight: FontWeight.w800,
        color: color,
        tabular: true,
      );
      _text(c, unit, r.left + 20 + w + 6, r.top + 54, size: 14, weight: FontWeight.w600, color: L360Colors.sand400);
    }
    y += 96 + 32;

    // The plot
    final plotBox = Rect.fromLTWH(x0, y, innerW, _chartHeight);
    c
      ..drawRRect(_rr(plotBox, 16), Paint()..color = L360Colors.sand50)
      ..drawRRect(
        _rr(plotBox, 16),
        Paint()
          ..style = PaintingStyle.stroke
          ..color = L360Colors.sand200,
      );
    final g = Rect.fromLTRB(plotBox.left + 100, plotBox.top + 60, plotBox.right - 60, plotBox.bottom - 80);
    final range = report.profileRange;
    final span = (range.max - range.min) == 0 ? 1 : range.max - range.min;
    double px(ReportRow r) => g.left + r.profileDist / (report.totalDistance == 0 ? 1 : report.totalDistance) * g.width;
    double py(double elev) => g.bottom - (elev - range.min) / span * g.height;
    final dash = Paint()
      ..color = L360Colors.sand300
      ..strokeWidth = 1;
    for (final t in [0.0, 0.25, 0.5, 0.75, 1.0]) {
      final ly = g.top + g.height * t;
      for (var x = g.left; x < g.right; x += 8) {
        c.drawLine(Offset(x, ly), Offset(math.min(x + 4, g.right), ly), dash);
      }
      _text(
        c,
        (range.max - span * t).toStringAsFixed(0),
        g.left - 16,
        ly - 7,
        size: 11,
        weight: FontWeight.w500,
        color: L360Colors.sand500,
        right: true,
        tabular: true,
      );
    }
    c
      ..save()
      ..translate(plotBox.left + 30, plotBox.center.dy)
      ..rotate(-math.pi / 2);
    _text(c, 'Elevation (m)', 0, -8, weight: FontWeight.w700, color: L360Colors.sand500, center: true);
    c.restore();

    for (final seg in report.profileSegments) {
      final pts = [for (final r in seg) Offset(px(r), py(r.elevation))];
      if (pts.length > 1) {
        final area = Path()..moveTo(pts.first.dx, g.bottom);
        for (final o in pts) {
          area.lineTo(o.dx, o.dy);
        }
        area
          ..lineTo(pts.last.dx, g.bottom)
          ..close();
        c.drawPath(
          area,
          Paint()
            ..shader = ui.Gradient.linear(Offset(0, g.top), Offset(0, g.bottom), [
              L360Colors.forest600.withValues(alpha: 0.22),
              L360Colors.forest600.withValues(alpha: 0),
            ]),
        );
      }
      final line = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (final o in pts.skip(1)) {
        line.lineTo(o.dx, o.dy);
      }
      c.drawPath(
        line,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round
          ..color = L360Colors.forest700,
      );
    }
    // Numbers under the axis: where two points share a spot (the end of one line and the
    // start of the next) the second goes a row lower instead of on top
    double? lastLabelX;
    var lastLabelRow = 0;
    for (final r in report.rows) {
      final o = Offset(px(r), py(r.elevation));
      final labelRow = lastLabelX != null && (o.dx - lastLabelX).abs() < 24 ? lastLabelRow + 1 : 0;
      lastLabelX = o.dx;
      lastLabelRow = labelRow;
      for (var yy = o.dy; yy < g.bottom; yy += 4) {
        c.drawLine(Offset(o.dx, yy), Offset(o.dx, math.min(yy + 2, g.bottom)), dash);
      }
      c
        ..drawCircle(o, 4, Paint()..color = const Color(0xFFFFFFFF))
        ..drawCircle(
          o,
          4,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = L360Colors.forest700,
        );
      final tag = Rect.fromCenter(center: o.translate(0, -12 - 13), width: 36, height: 18);
      c.drawRRect(_rr(tag, 4), Paint()..color = const Color(0xFFF2CC6C));
      _text(
        c,
        r.elevation.toStringAsFixed(0),
        tag.center.dx,
        tag.top + 3,
        size: 10,
        weight: FontWeight.w700,
        center: true,
        tabular: true,
      );
      _text(
        c,
        '${r.number}',
        o.dx,
        g.bottom + 12 + labelRow * 15,
        size: 11,
        weight: FontWeight.w600,
        color: L360Colors.sand500,
        center: true,
      );
    }
    final axis = Paint()
      ..color = L360Colors.sand400
      ..strokeWidth = 2;
    c
      ..drawLine(Offset(g.left, g.bottom), Offset(g.right, g.bottom), axis)
      ..drawLine(Offset(g.left, g.top), Offset(g.left, g.bottom), axis);
    p.y += blockHeight;
    return p;
  }
}
