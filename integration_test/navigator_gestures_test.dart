// Navigator gestures on the real Mapbox map (simulator or phone):
//   flutter test integration_test/navigator_gestures_test.dart -d <device> --dart-define-from-file=config/dev.json
// Survey points are added through the Navigator (what a tap on the map calls); the point
// gestures (drag, hold-and-drag, hold-and-release, tap, handle knobs) are real touches on
// the overlay, converted with the map's own screen <-> coordinate projection.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:landscape360/core/config/app_config.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/core/theme/app_theme.dart';
import 'package:landscape360/domain/survey/survey_model.dart';
import 'package:landscape360/features/map/map_screen.dart';
import 'package:landscape360/features/navigator/navigator_state.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' show MapboxOptions;

import '../test/features/navigator_state_test.dart' show FakeSurveys;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final config = AppConfig.fromEnvironment();

  Future<void> wait(WidgetTester tester, [int ms = 600]) async {
    for (var i = 0; i < ms ~/ 50; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('point gestures on the real map', (tester) async {
    expect(config.mapboxPublicToken, startsWith('pk.'), reason: 'run with --dart-define-from-file=config/dev.json');
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
    await wait(tester, 6000); // map and style load

    final nav = container.read(navigatorProvider.notifier)..open();
    Future<double> flat(double lng, double lat) async => 10;
    // Three points around the map centre (Jakarta, zoom 14, ~9.5 m per pixel): 0.006° (~70 px)
    // apart, so their 44 pt touch targets do not overlap
    await nav.addPointAt(106.8396, -6.2088, flat);
    await nav.addPointAt(106.8456, -6.2088, flat);
    await nav.addPointAt(106.8516, -6.2088, flat);
    await wait(tester, 1500);

    SurveyGroup group() => container.read(navigatorProvider).doc.groups.single;
    Finder point(int i) => find.byKey(ValueKey('nav-point-${group().points[i].id}'));
    for (var i = 0; i < 3; i++) {
      expect(point(i), findsOneWidget, reason: 'point $i is drawn over the map');
    }

    // 1. Drag the middle point to the right: it moves east, the latitude stays
    final before = group().points[1];
    await tester.drag(point(1), const Offset(25, 0));
    await wait(tester, 1500);
    final moved = group().points[1];
    expect(moved.lng, greaterThan(before.lng + 0.0001), reason: 'moved east');
    expect(moved.lat, closeTo(before.lat, 0.0002));

    // 2. After the drag the overlay follows the survey again: a new point shows up
    await nav.addPointAt(106.8576, -6.2088, flat);
    await wait(tester, 1500);
    expect(point(3), findsOneWidget, reason: 'drawing is not stuck on the drag');

    // 3. Hold, then drag: a Bezier handle pointing the way of the drag
    final hold = await tester.startGesture(tester.getCenter(point(1)));
    await tester.pump(const Duration(milliseconds: 500));
    await hold.moveBy(const Offset(0, -20));
    await tester.pump(const Duration(milliseconds: 50));
    await hold.moveBy(const Offset(0, -60));
    await wait(tester, 400);
    await hold.up();
    await wait(tester, 1200);
    final handle = group().points[1].handle;
    expect(handle, isNotNull, reason: 'hold-and-drag bends the line');
    expect(handle!.north, greaterThan(20), reason: 'dragged up = north');

    // 4. Hold and release without dragging: the curve stays as it was
    final still = await tester.startGesture(tester.getCenter(point(1)));
    await tester.pump(const Duration(milliseconds: 600));
    await still.up();
    await wait(tester, 1200);
    expect(group().points[1].handle?.north, closeTo(handle.north, 1e-6), reason: 'holding alone keeps the handle');

    // 5. Tap selects and shows the two knobs; dragging a knob reshapes the curve
    container.read(navigatorProvider.notifier).select(null);
    await wait(tester, 500);
    await tester.tap(point(1));
    await wait(tester, 1200);
    expect(container.read(navigatorProvider).selectedPointId, group().points[1].id);
    expect(find.byKey(const ValueKey('nav-handle-out')), findsOneWidget);
    expect(find.byKey(const ValueKey('nav-handle-in')), findsOneWidget);
    await tester.drag(find.byKey(const ValueKey('nav-handle-out')), const Offset(60, 0));
    await wait(tester, 1500);
    final reshaped = group().points[1].handle!;
    expect(reshaped.east, greaterThan(handle.east + 10), reason: 'knob dragged east');

    // 6. Tap again: deselected, knobs gone
    await tester.tap(point(1));
    await wait(tester, 1000);
    expect(container.read(navigatorProvider).selectedPointId, isNull);
    expect(find.byKey(const ValueKey('nav-handle-out')), findsNothing);
  });
}
