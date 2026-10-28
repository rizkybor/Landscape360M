// The map's coordinate card and buttons fade while the map is still (simulator or phone):
//   flutter test integration_test/map_chrome_test.dart -d <device> --dart-define-from-file=config/dev.json
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:landscape360/core/config/app_config.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/core/theme/app_theme.dart';
import 'package:landscape360/features/map/map_screen.dart';
import 'package:landscape360/features/map/map_tools_state.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide square;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final config = AppConfig.fromEnvironment();

  Future<void> wait(WidgetTester tester, int ms) async {
    for (var i = 0; i < ms ~/ 50; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('still map: card and buttons fade; moving or touching brings them back', (tester) async {
    MapboxOptions.setAccessToken(config.mapboxPublicToken);
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
    double opacity(Key key) =>
        tester.widget<AnimatedOpacity>(find.ancestor(of: find.byKey(key), matching: find.byType(AnimatedOpacity)).first).opacity;

    await wait(tester, 3500);
    expect(opacity(const Key('telemetry-card')), 0.3, reason: 'still map: faded');
    expect(opacity(const Key('map-buttons')), 0.3);
    int blurs(Key key) => find.descendant(of: find.byKey(key), matching: find.byType(BackdropFilter)).evaluate().length;
    expect(blurs(const Key('map-buttons')), 0, reason: 'no frosted blur while faded: the map shows through');
    expect(blurs(const Key('telemetry-card')), 0);
    // Time to look at it (a screenshot is taken from outside the test)
    await wait(tester, 6000);

    container.read(flyToProvider.notifier).go(106.85, -6.21, zoom: 14);
    await wait(tester, 400);
    expect(opacity(const Key('telemetry-card')), 1, reason: 'moving: back');
    expect(opacity(const Key('map-buttons')), 1);
    expect(blurs(const Key('map-buttons')), greaterThan(0), reason: 'frosted again when shown');

    await wait(tester, 5000);
    expect(opacity(const Key('map-buttons')), 0.3, reason: 'still again');
    // A touch on a faded button brings them back (and the button still works)
    await tester.tap(find.byKey(const Key('reset-north')));
    await tester.pump();
    expect(opacity(const Key('map-buttons')), 1);
  });
}
