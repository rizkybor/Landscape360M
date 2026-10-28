import 'dart:async';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:image/image.dart' as img;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mbx;
import 'package:pdf/pdf.dart' as pdf;
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import '../../core/theme/app_theme.dart';
import '../../domain/map/map_settings.dart' show realElevation;
import '../../domain/report/survey_report.dart';
import '../map/map_settings_controller.dart';
import '../marked/marked_state.dart';
import '../navigator/navigator_state.dart';
import 'report_pages.dart';

// Export the survey report (the web's Export As: PNG / JPG / PDF): the map as it is on
// screen, its survey points and the marked locations in view, the tables and the elevation
// profile, shared through the phone's share sheet. Small files: JPEG pages, PDF from JPEG.

enum ReportFormat {
  png('Save as PNG', 'Best for digital use'),
  jpg('Save as JPG', 'Smaller file size'),
  pdf('Export to PDF', 'For documentation');

  const ReportFormat(this.title, this.hint);
  final String title;
  final String hint;
}

/// Reads a provider (WidgetRef.read or ProviderContainer.read)
typedef ProviderReader = T Function<T>(ProviderListenable<T> provider);

/// Reads the map and draws the pages
Future<List<ui.Image>> buildReportPages(ProviderReader read, mbx.MapboxMap map, Size viewSize) async {
  final groups = read(navigatorProvider).doc.groups;
  final report = SurveyReport.of(groups);
  final camera = await map.getCameraState();
  final center = camera.center.coordinates;

  final snapshot = await map.snapshot();
  final mapImage = await _decode(snapshot);

  final rowPoints = [for (final r in report.rows) mbx.Point(coordinates: mbx.Position(r.lng, r.lat))];
  final pixels = rowPoints.isEmpty ? const <mbx.ScreenCoordinate>[] : await map.pixelsForCoordinates(rowPoints);
  final positions = [for (final p in pixels) Offset(p.x, p.y)];

  double? centerElevation;
  try {
    final raw = await map.getElevation(camera.center);
    if (raw != null) centerElevation = realElevation(raw, read(mapSettingsProvider).appliedExaggeration);
  } on Object {
    centerElevation = null;
  }

  // Marked locations within the part of the map on the page
  final visible = read(markedProvider).visible;
  final places = <ReportPlace>[];
  if (visible.isNotEmpty) {
    final at = await map.pixelsForCoordinates([
      for (final v in visible) mbx.Point(coordinates: mbx.Position(v.location.lng, v.location.lat)),
    ]);
    for (final (i, v) in visible.indexed) {
      if (!reportMapShows(Offset(at[i].x, at[i].y), viewSize)) continue;
      final l = v.location;
      places.add(ReportPlace(name: l.name, category: l.category, lat: l.lat, lng: l.lng, elevationM: l.elevationM));
    }
  }

  ui.Image? logo;
  try {
    logo = await _decode((await rootBundle.load('assets/images/logo.png')).buffer.asUint8List());
  } on Object {
    logo = null;
  }

  return ReportPainter(
    ReportInput(
      map: mapImage,
      viewSize: viewSize,
      pointPositions: positions,
      centerLat: center.lat.toDouble(),
      centerLng: center.lng.toDouble(),
      centerElevation: centerElevation,
      bearing: camera.bearing,
      pitch: camera.pitch,
      zoom: camera.zoom,
      report: report,
      places: places,
      exportedAt: DateTime.now(),
      logo: logo,
    ),
  ).draw();
}

Future<ui.Image> _decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  return (await codec.getNextFrame()).image;
}

/// JPEG of a page, made off the main thread
Future<Uint8List> _jpeg(ui.Image page, int quality) async {
  final rgba = (await page.toByteData())!.buffer.asUint8List();
  final w = page.width, h = page.height;
  return Isolate.run(
    () => img.encodeJpg(
      img.Image.fromBytes(width: w, height: h, bytes: rgba.buffer, numChannels: 4),
      quality: quality,
    ),
  );
}

/// A file of the report
class ReportFile {
  const ReportFile(this.name, this.bytes, this.mimeType);
  final String name;
  final Uint8List bytes;
  final String mimeType;

  XFile get xFile => XFile.fromData(bytes, mimeType: mimeType, name: name);
}

/// The files to share for [format]: one per page for images, one PDF
Future<List<ReportFile>> encodeReport(List<ui.Image> pages, ReportFormat format, {DateTime? at}) async {
  final stamp = (at ?? DateTime.now()).millisecondsSinceEpoch;
  switch (format) {
    case ReportFormat.pdf:
      final doc = pw.Document(compress: true);
      for (final page in pages) {
        final jpg = await _jpeg(page, 82);
        doc.addPage(
          pw.Page(
            pageFormat: pdf.PdfPageFormat.a4,
            margin: pw.EdgeInsets.zero,
            build: (_) => pw.Image(pw.MemoryImage(jpg), fit: pw.BoxFit.fill),
          ),
        );
      }
      return [ReportFile('Landscape360_Report_$stamp.pdf', await doc.save(), 'application/pdf')];
    case ReportFormat.png:
    case ReportFormat.jpg:
      final files = <ReportFile>[];
      for (final (i, page) in pages.indexed) {
        final suffix = pages.length == 1 ? '' : '_Page_${i + 1}';
        if (format == ReportFormat.png) {
          final png = (await page.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
          files.add(ReportFile('Landscape360_Survey_$stamp$suffix.png', png, 'image/png'));
        } else {
          files.add(ReportFile('Landscape360_Survey_$stamp$suffix.jpg', await _jpeg(page, 85), 'image/jpeg'));
        }
      }
      return files;
  }
}

/// The "Export As" sheet; the chosen format is exported and shared
Future<void> showReportExport(BuildContext context, WidgetRef ref, mbx.MapboxMap map, Size viewSize) async {
  final format = await showModalBottomSheet<ReportFormat>(
    context: context,
    useSafeArea: true,
    builder: (context) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(L360.gutter, 4, L360.gutter, 4),
          child: Text('Export survey report', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(L360.gutter, 0, L360.gutter, 8),
          child: Text(
            'The map as it is now, the survey points, distances, elevation profile and the marked locations in view.',
            style: TextStyle(fontSize: 13, color: L360Colors.sand600),
          ),
        ),
        for (final f in ReportFormat.values)
          ListTile(
            key: Key('export-${f.name}'),
            leading: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: f == ReportFormat.pdf ? L360Colors.brick50 : L360Colors.forest50,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                f == ReportFormat.pdf ? Icons.picture_as_pdf_outlined : Icons.image_outlined,
                color: f == ReportFormat.pdf ? L360Colors.brick500 : L360Colors.forest700,
              ),
            ),
            title: Text(f.title, style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(f.hint),
            onTap: () => Navigator.pop(context, f),
          ),
        const SizedBox(height: 8),
      ],
    ),
  );
  if (format == null || !context.mounted) return;

  final messenger = ScaffoldMessenger.of(context);
  final box = context.findRenderObject() as RenderBox?;
  final origin = box == null ? null : box.localToGlobal(Offset.zero) & box.size;
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
              SizedBox(width: 16),
              Expanded(child: Text('Preparing the report…')),
            ],
          ),
        ),
      ),
    ),
  );
  List<ReportFile>? files;
  Object? failure;
  try {
    final pages = await buildReportPages(ref.read, map, viewSize);
    files = await encodeReport(pages, format);
  } on Object catch (e) {
    failure = e;
  }
  if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  if (files == null) {
    messenger.showSnackBar(SnackBar(content: Text('Could not export the report: $failure')));
    return;
  }
  await SharePlus.instance.share(
    ShareParams(
      files: [for (final f in files) f.xFile],
      fileNameOverrides: [for (final f in files) f.name],
      sharePositionOrigin: origin,
    ),
  );
}
