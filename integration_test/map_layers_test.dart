// Map layers on the real Mapbox map (simulator or phone):
//   flutter test integration_test/map_layers_test.dart -d <device> --dart-define-from-file=config/dev.json
// Checks that the style accepts the points-of-interest and shared-link layers (a wrong
// expression only shows up in the map engine) and that the points are drawn.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:landscape360/core/config/app_config.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/core/theme/app_theme.dart';
import 'package:landscape360/data/marked/marked_area_repository.dart';
import 'package:landscape360/domain/search/place_search.dart';
import 'package:landscape360/domain/share/share_location.dart';
import 'package:landscape360/features/areas/area_layer.dart';
import 'package:landscape360/features/areas/area_state.dart';
import 'package:landscape360/features/map/map_screen.dart';
import 'package:landscape360/features/map/map_tools_state.dart';
import 'package:landscape360/features/map/poi_layer.dart';
import 'package:landscape360/features/map/shared_links.dart';
import 'package:landscape360/features/marked/marked_layer.dart';
import 'package:landscape360/features/marked/marked_state.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide square;

import '../test/features/areas_test.dart' show FakeAreas, square;
import '../test/features/marked_test.dart' show FakeMarked, loc;

class _Pois extends PoisController {
  @override
  Future<List<PointOfInterest>> build() async => const [
    PointOfInterest(id: 'gede', name: 'Gunung Gede', category: 'mountain', lng: 106.9842, lat: -6.7867),
    PointOfInterest(id: 'water', name: 'Mata air', category: 'water', lng: 106.9600, lat: -6.7700),
  ];
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final config = AppConfig.fromEnvironment();

  Future<void> wait(WidgetTester tester, int ms) async {
    for (var i = 0; i < ms ~/ 50; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('points of interest, a shared pin and marked locations are drawn', (tester) async {
    MapboxOptions.setAccessToken(config.mapboxPublicToken);
    final container = ProviderContainer(
      overrides: [
        appConfigProvider.overrideWithValue(config),
        authUserIdProvider.overrideWith((ref) => Stream.value('u1')),
        profileProvider.overrideWith((ref) async => null),
        poisProvider.overrideWith(_Pois.new),
        markedBackendProvider.overrideWithValue(FakeMarked()..rows = [loc('pos3')]),
        areaBackendProvider.overrideWithValue(
          FakeAreas()
            ..rows = [
              const MarkedArea(
                id: 'camp',
                userId: 'u1',
                name: 'Camp',
                color: '#2563eb',
                ring: square,
                areaM2: 12200,
                perimeterM: 440,
              ),
            ],
        ),
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
    // Both points on screen (~200 px apart at zoom 13, so not grouped into a cluster)
    container.read(flyToProvider.notifier).go(106.972, -6.778, zoom: 13);
    await wait(tester, 4000);
    final mapbox = debugLiveMap!;
    for (final id in [poiPointsLayer, poiClustersLayer, 'shared-link-dot']) {
      expect(await mapbox.styleLayerExists(id), isTrue, reason: '$id in the style');
    }
    final size = tester.getSize(find.byType(MapWidget));
    final shown = await mapbox.queryRenderedFeatures(
      RenderedQueryGeometry.fromScreenBox(
        ScreenBox(
          min: ScreenCoordinate(x: 0, y: 0),
          max: ScreenCoordinate(x: size.width, y: size.height),
        ),
      ),
      RenderedQueryOptions(layerIds: [poiPointsLayer]),
    );
    expect(shown.length, 2, reason: 'both points drawn');

    // A shared location link puts its pin there
    await container.read(sharedLinkProvider.notifier).open(const PointLink((lat: -6.7867, lng: 106.9842)));
    await wait(tester, 3000);
    final pin = await mapbox.queryRenderedFeatures(
      RenderedQueryGeometry.fromScreenBox(
        ScreenBox(
          min: ScreenCoordinate(x: 0, y: 0),
          max: ScreenCoordinate(x: size.width, y: size.height),
        ),
      ),
      RenderedQueryOptions(layerIds: ['shared-link-dot']),
    );
    expect(pin, hasLength(1));

    // A marked location: its category marker image and the marker itself
    expect(await mapbox.hasStyleImage(markerImageId(loc('x').category, MarkedKind.mine)), isTrue);
    final marked = await mapbox.queryRenderedFeatures(
      RenderedQueryGeometry.fromScreenBox(
        ScreenBox(
          min: ScreenCoordinate(x: 0, y: 0),
          max: ScreenCoordinate(x: size.width, y: size.height),
        ),
      ),
      RenderedQueryOptions(layerIds: [markedPointsLayer]),
    );
    expect(marked, hasLength(1), reason: 'Pos 3 (-6.78, 106.98) is on screen');

    // A marked area, then the focus view: the map fits the area and darkens the rest
    Future<int> drawn(String layer) async => (await mapbox.queryRenderedFeatures(
      RenderedQueryGeometry.fromScreenBox(
        ScreenBox(
          min: ScreenCoordinate(x: 0, y: 0),
          max: ScreenCoordinate(x: size.width, y: size.height),
        ),
      ),
      RenderedQueryOptions(layerIds: [layer]),
    )).length;
    expect(await drawn(areaFillLayer), 1, reason: 'the area is drawn');
    container.read(areasProvider.notifier).focus('camp');
    await wait(tester, 2500);
    expect(await drawn('marked-area-mask-fill'), greaterThan(0), reason: 'outside the area is darkened');
    final zoom = (await mapbox.getCameraState()).zoom;
    expect(zoom, greaterThan(15), reason: 'the map fitted the ~110 m area');
    expect(find.text('Shared location'), findsOneWidget);
  });
}
