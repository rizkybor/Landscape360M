// Offline maps for real (simulator or phone, needs internet to start):
//   flutter test integration_test/offline_map_test.dart -d <device> --dart-define-from-file=config/dev.json
// Downloads a small area near Gede with the app's own engine, cuts the map off from the
// network (like airplane mode), and checks the downloaded area still draws, with its
// elevation, while an area that was never downloaded stays empty.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:landscape360/core/config/app_config.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/core/theme/app_theme.dart';
import 'package:landscape360/data/offline/offline_maps.dart';
import 'package:landscape360/domain/map/map_settings.dart';
import 'package:landscape360/domain/map/offline_regions.dart';
import 'package:landscape360/features/map/map_screen.dart';
import 'package:landscape360/features/map/map_tools_state.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide square;

const _id = 'integration-test-gede';
// ~2.2 km × 2.2 km around the Gede summit
const _gede = OfflineBounds(west: 106.975, south: -6.80, east: 106.995, north: -6.78);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final config = AppConfig.fromEnvironment();

  Future<void> wait(WidgetTester tester, int ms) async {
    for (var i = 0; i < ms ~/ 50; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('a downloaded area shows without network, others do not', (tester) async {
    MapboxOptions.setAccessToken(config.mapboxPublicToken);
    final engine = MapboxOfflineEngine();
    await engine.remove(_id).catchError((Object _) {});

    // 1. Download zoom 12–14 of the area (satellite style and elevation)
    var last = 0.0;
    await tester.runAsync(
      () => engine.download(
        id: _id,
        name: 'Gede (test)',
        bounds: _gede,
        minZoom: 12,
        maxZoom: 14,
        styles: const [MapStyle.satellite],
        onProgress: (p) => last = p,
      ),
    );
    expect(last, 1);
    final stored = await tester.runAsync(engine.stored);
    expect(stored![_id], greaterThan(50 * 1024), reason: 'tiles are on the phone');

    // 2. No network for the map from here on
    await tester.runAsync(() => OfflineSwitch.shared.setMapboxStackConnected(false));
    addTearDown(() => OfflineSwitch.shared.setMapboxStackConnected(true));

    final container = ProviderContainer(
      overrides: [
        appConfigProvider.overrideWithValue(config),
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
    final map = debugLiveMap!;
    final size = tester.getSize(find.byType(MapWidget));
    Future<int> features() async => (await map.queryRenderedFeatures(
      RenderedQueryGeometry.fromScreenBox(
        ScreenBox(min: ScreenCoordinate(x: 0, y: 0), max: ScreenCoordinate(x: size.width, y: size.height)),
      ),
      RenderedQueryOptions(),
    )).length;

    // 3. The downloaded area draws (road / label features of the style) and has elevation
    final (lng, lat) = _gede.center;
    container.read(flyToProvider.notifier).go(lng, lat, zoom: 13.5);
    await wait(tester, 5000);
    expect(await features(), greaterThan(0), reason: 'the offline area draws without network');
    final elevation = await map.getElevation(Point(coordinates: Position(lng, lat)));
    expect(elevation, isNotNull, reason: 'elevation (3D, contours) works offline');
    expect(elevation!, greaterThan(1500), reason: 'Gede is ~2,900 m');

    // 4. An area never downloaded (Wamena, Papua) stays empty
    container.read(flyToProvider.notifier).go(138.94, -4.10, zoom: 13.5);
    await wait(tester, 5000);
    expect(await features(), 0, reason: 'nothing to draw without network or download');

    await tester.runAsync(() => engine.remove(_id));
  });
}
