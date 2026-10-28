import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/core/ui/widgets.dart';
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

    testWidgets('Terrain tab: contours and height work in 3D, the grid in both views', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('section-terrain')));
      await tester.pumpAndSettle();

      // 2D: the hint shows, contour controls are off, the grid still works
      expect(find.textContaining('Switch Map View to 3D'), findsOneWidget);
      await tester.tap(find.byKey(const Key('contours-toggle')));
      await tester.drag(
        find.descendant(of: find.byKey(const Key('exaggeration')), matching: find.byType(Slider)),
        const Offset(1000, 0),
      );
      await tester.pumpAndSettle();
      expect(container.read(mapSettingsProvider).showContours, isTrue);
      expect(container.read(mapSettingsProvider).exaggeration, defaultExaggeration);
      await tester.tap(find.byKey(const Key('grid-toggle')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('30" (~900m)'));
      await tester.tap(find.text('30" (~900m)'));
      await tester.pumpAndSettle();
      expect(
        (container.read(mapSettingsProvider).showGrid, container.read(mapSettingsProvider).gridStep),
        (true, 30 / 3600),
      );
      await tester.tap(find.text('Auto (Dynamic)'));
      expect(container.read(mapSettingsProvider).gridStep, isNull);

      // 3D from the hint: interval presets and the height slider (0.1 to 10x) respond
      await tester.ensureVisible(find.byKey(const Key('terrain-hint')));
      await tester.tap(find.descendant(of: find.byKey(const Key('terrain-hint')), matching: find.text('3D Terrain')));
      await tester.pumpAndSettle();
      expect(container.read(mapSettingsProvider).view, MapView.threeD);
      await tester.ensureVisible(find.text('12.5m'));
      await tester.tap(find.text('12.5m'));
      await tester.pumpAndSettle();
      expect(container.read(mapSettingsProvider).contourInterval, 12.5);
      await tester.ensureVisible(find.byKey(const Key('exaggeration')));
      await tester.drag(
        find.descendant(of: find.byKey(const Key('exaggeration')), matching: find.byType(Slider)),
        const Offset(1000, 0),
      );
      await tester.pumpAndSettle();
      expect(container.read(mapSettingsProvider).exaggeration, maxExaggeration);
      // Contours off: their settings hide (like the grid's); the height slider stays
      expect(find.text('Opacity Contours'), findsOneWidget);
      await tester.tap(find.byKey(const Key('contours-toggle')));
      await tester.pumpAndSettle();
      expect(container.read(mapSettingsProvider).showContours, isFalse);
      expect(find.text('Opacity Contours'), findsNothing);
      expect(find.byKey(const Key('contour-interval')), findsNothing);
      expect(find.text('12.5m'), findsNothing);
      expect(find.byKey(const Key('exaggeration')), findsOneWidget);
      await tester.tap(find.byKey(const Key('contours-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('Opacity Contours'), findsOneWidget);
    });

    testWidgets('tool tiles are equal squares in two full rows', (tester) async {
      await pump(tester);
      final names = ['Navigator', 'Route', 'POIs', 'Track', 'Marked', 'Areas', 'Basemaps', 'GPS'];
      final rects = [for (final n in names) tester.getRect(find.byKey(Key('tool-$n')))];
      for (final r in rects) {
        expect(r.width, rects.first.width);
        expect(r.height, r.width);
      }
      // Even gaps in the first row
      for (var i = 1; i < 4; i++) {
        expect(rects[i].left - rects[i - 1].right, closeTo(10, 0.01));
      }
      // Second row right under the first, edge to edge
      expect(rects[4].left, closeTo(rects[0].left, 0.01));
      expect(rects[7].right, closeTo(rects[3].right, 0.01));
      expect(rects[4].top - rects[0].bottom, closeTo(10, 0.01));
    });

    testWidgets('header offers guide, weather, search and signing in; every tool is there', (tester) async {
      await pump(tester);
      // No app sharing in the native app
      expect(find.byKey(const Key('share-app')), findsNothing);
      expect(find.byKey(const Key('weather')), findsOneWidget);
      expect(find.byKey(const Key('search')), findsOneWidget);
      expect(find.byType(BrandName), findsOneWidget);
      expect(find.byTooltip('Sign in'), findsOneWidget);
      // Same tools as the web's phone layout
      for (final name in ['Navigator', 'Route', 'Track', 'POIs', 'Marked', 'Areas', 'Basemaps', 'GPS']) {
        expect(
          tester.widget<ToolTile>(find.ancestor(of: find.text(name), matching: find.byType(ToolTile))).enabled,
          isTrue,
        );
      }
      // Signed out, the tools that keep data in the account look disabled and all open the
      // same Sign in sheet; the others stay as they are
      double opacityOf(String name) => tester
          .widget<Opacity>(find.descendant(of: find.byKey(Key('tool-$name')), matching: find.byType(Opacity)))
          .opacity;
      for (final name in ['Track', 'Marked', 'Areas', 'Basemaps', 'GPS']) {
        expect(opacityOf(name), 0.5, reason: name);
      }
      for (final name in ['Navigator', 'Route', 'POIs']) {
        expect(opacityOf(name), 1, reason: name);
      }
      for (final (name, title) in [
        ('Basemaps', 'Custom Basemaps'),
        ('GPS', 'GPS Tracking'),
        ('Track', 'Track Recorder'),
      ]) {
        await tester.tap(find.byKey(Key('tool-$name')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('sign-in-sheet')), findsOneWidget);
        expect(find.text(title), findsOneWidget);
        expect(find.byKey(const Key('sign-in-sheet-login')), findsOneWidget);
        await tester.tapAt(const Offset(200, 40));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const Key('guide')));
      await tester.pumpAndSettle();
      expect(find.text('Quick Start Guide'), findsOneWidget);
    });
  });
}
