import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/domain/map/map_settings.dart';
import 'package:landscape360/features/map/map_settings_controller.dart';
import 'package:landscape360/features/map/map_sheet.dart';
import 'package:landscape360/features/map/telemetry_card.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  setUp(() => SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty());

  group('TelemetryCard', () {
    const t = Telemetry(lng: 106.983201, lat: -6.789912, pitch: 60, bearing: -90, elevation: 2958.44, slope: 12.34);

    Future<void> pump(WidgetTester tester, CoordFormat format, ValueChanged<CoordFormat> onChanged) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TelemetryCard(telemetry: t, format: format, onFormatChanged: onChanged),
            ),
          ),
        );

    testWidgets('shows decimal coordinates, elevation, slope, pitch and bearing', (tester) async {
      await pump(tester, CoordFormat.dd, (_) {});
      expect(find.text('106.98320'), findsOneWidget);
      expect(find.text('-6.78991'), findsOneWidget);
      expect(find.text('2958.4 mdpl'), findsOneWidget);
      expect(find.text('12.3°'), findsOneWidget);
      expect(find.text('60.0°'), findsOneWidget);
      expect(find.text('270.0°'), findsOneWidget);
    });

    testWidgets('shows DMS and reports the format the user picks', (tester) async {
      CoordFormat? picked;
      await pump(tester, CoordFormat.dms, (f) => picked = f);
      expect(find.text('6°47\'23.68" S'), findsOneWidget);
      expect(find.text('106°58\'59.52" E'), findsOneWidget);
      await tester.tap(find.byKey(const Key('coord-dd')));
      expect(picked, CoordFormat.dd);
    });

    testWidgets('shows a dash until the terrain answers', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TelemetryCard(
              telemetry: const Telemetry(lng: 0, lat: 0, pitch: 0, bearing: 0),
              format: CoordFormat.dd,
              onFormatChanged: (_) {},
            ),
          ),
        ),
      );
      expect(find.text('—'), findsNWidgets(2));
    });
  });

  group('MapSheet', () {
    late ProviderContainer container;

    Future<void> pump(WidgetTester tester) async {
      container = ProviderContainer(
        overrides: [
          authUserIdProvider.overrideWith((ref) => Stream.value(null)),
          profileProvider.overrideWith((ref) async => null),
        ],
      );
      addTearDown(container.dispose);
      await tester.binding.setSurfaceSize(const Size(400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(body: MapSheet(scrollController: ScrollController())),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('Map tab switches 2D / 3D and the style', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('section-map')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('view-3d')));
      await tester.tap(find.byKey(const Key('style-outdoors')));
      await tester.pumpAndSettle();
      final s = container.read(mapSettingsProvider);
      expect((s.view, s.style), (MapView.threeD, MapStyle.outdoors));
    });

    testWidgets('Terrain tab changes the exaggeration within its limits', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('section-terrain')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Switch Map View to 3D'), findsOneWidget);
      await tester.drag(find.byKey(const Key('exaggeration')), const Offset(1000, 0));
      await tester.pumpAndSettle();
      expect(container.read(mapSettingsProvider).exaggeration, maxExaggeration);
    });

    testWidgets('tool tiles are equal squares and the shorter last row is centered', (tester) async {
      await pump(tester);
      final names = ['Navigator', 'Route', 'POIs', 'Track', 'Marked', 'Areas', 'Basemaps'];
      final rects = [for (final n in names) tester.getRect(find.byKey(Key('tool-$n')))];
      for (final r in rects) {
        expect(r.width, rects.first.width);
        expect(r.height, r.width);
      }
      // Even gaps in the first row
      for (var i = 1; i < 4; i++) {
        expect(rects[i].left - rects[i - 1].right, closeTo(10, 0.01));
      }
      // Second row centered under the first: same space left and right
      final rowLeft = rects[0].left, rowRight = rects[3].right;
      expect(rects[4].left - rowLeft, closeTo(rowRight - rects[6].right, 0.5));
      expect(rects[4].top - rects[0].bottom, closeTo(10, 0.01));
    });

    testWidgets('header offers guide, sharing and signing in; tools not built yet say so', (tester) async {
      await pump(tester);
      expect(find.byKey(const Key('share-app')), findsOneWidget);
      expect(find.byTooltip('Sign in'), findsOneWidget);
      // Same tools as the web's phone layout
      for (final name in ['Navigator', 'Route', 'POIs', 'Track', 'Marked', 'Areas', 'Basemaps']) {
        expect(
          tester.widget<ToolTile>(find.ancestor(of: find.text(name), matching: find.byType(ToolTile))).enabled,
          isFalse,
        );
      }
      await tester.tap(find.byKey(const Key('tool-Navigator')));
      await tester.pump();
      expect(find.text('Navigator is coming to the app soon.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('guide')));
      await tester.pumpAndSettle();
      expect(find.text('Quick Start Guide'), findsOneWidget);
      expect(appShareText, endsWith('https://landscape360.jcdigital.co.id/'));
    });
  });
}
