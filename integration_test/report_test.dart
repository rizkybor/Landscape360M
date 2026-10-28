// The survey report from the real map (simulator or phone):
//   flutter test integration_test/report_test.dart -d <device> --dart-define-from-file=config/dev.json
// Builds the report from the live map with three survey points, checks the map snapshot is
// in it (not blank), and that the PDF and JPG files are made and small.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:landscape360/core/config/app_config.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/core/theme/app_theme.dart';
import 'package:landscape360/features/map/map_screen.dart';
import 'package:landscape360/features/map/map_tools_state.dart';
import 'package:landscape360/features/navigator/navigator_state.dart';
import 'package:landscape360/features/report/report_export.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide square;

import '../test/features/navigator_state_test.dart' show FakeSurveys;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final config = AppConfig.fromEnvironment();

  Future<void> wait(WidgetTester tester, int ms) async {
    for (var i = 0; i < ms ~/ 50; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('a report from the live map', (tester) async {
    MapboxOptions.setAccessToken(config.mapboxPublicToken);
    final container = ProviderContainer(
      overrides: [
        appConfigProvider.overrideWithValue(config),
        surveyBackendProvider.overrideWithValue(FakeSurveys()),
        authUserIdProvider.overrideWith((ref) => Stream.value(null)),
        profileProvider.overrideWith((ref) async => null),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: buildAppTheme(), home: const MapScreen()),
      ),
    );
    await wait(tester, 6000);
    container.read(flyToProvider.notifier).go(106.984, -6.786, zoom: 14.5);
    await wait(tester, 4000);
    final nav = container.read(navigatorProvider.notifier)..open();
    Future<double> flat(double lng, double lat) async => 2000;
    for (final (lng, lat) in [(106.980, -6.783), (106.984, -6.786), (106.988, -6.789)]) {
      await tester.runAsync(() => nav.addPointAt(lng, lat, flat));
    }
    await wait(tester, 2000);

    final size = tester.getSize(find.byType(MapWidget));
    final pages = (await tester.runAsync(() => buildReportPages(container.read, debugLiveMap!, size)))!;
    expect(pages, isNotEmpty);

    // The map area of page 1 has the map's colours, not a blank white box
    final bytes = (await tester.runAsync(() => pages.first.toByteData()))!;
    var coloured = 0;
    for (var i = 0; i < 400; i++) {
      final x = 100 + (i % 20) * 90, y = 250 + (i ~/ 20) * 60;
      final at = (y * pages.first.width + x) * 4;
      final r = bytes.getUint8(at), g = bytes.getUint8(at + 1), b = bytes.getUint8(at + 2);
      if (r < 235 || g < 235 || b < 235) coloured++;
    }
    expect(coloured, greaterThan(300), reason: 'the snapshot is in the report');

    final pdf = (await tester.runAsync(() => encodeReport(pages, ReportFormat.pdf)))!.single;
    expect(String.fromCharCodes(pdf.bytes.sublist(0, 4)), '%PDF');
    expect(pdf.bytes.lengthInBytes, lessThan(3 * 1024 * 1024 * pages.length), reason: 'small file');
    final jpg = (await tester.runAsync(() => encodeReport(pages, ReportFormat.jpg)))!;
    expect(jpg, hasLength(pages.length));
    expect(ui.ImageByteFormat.png, isNotNull);
  });
}
