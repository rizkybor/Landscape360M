// A still map draws nothing: once the controls have faded, Flutter makes no frames (the map
// itself is drawn by Mapbox, outside Flutter). Run on a simulator or phone:
//   flutter test integration_test/idle_frames_test.dart -d <device> --dart-define-from-file=config/dev.json
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:landscape360/core/config/app_config.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/core/theme/app_theme.dart';
import 'package:landscape360/features/map/map_screen.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide square;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  final config = AppConfig.fromEnvironment();

  testWidgets('a still map makes no Flutter frames; moving it stays smooth', (tester) async {
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

    final frames = <FrameTiming>[];
    void record(List<FrameTiming> t) => frames.addAll(t);
    SchedulerBinding.instance.addTimingsCallback(record);
    addTearDown(() => SchedulerBinding.instance.removeTimingsCallback(record));

    // Loaded, weather and terrain answered, controls faded
    await Future<void>.delayed(const Duration(seconds: 15));
    await tester.pump();

    frames.clear();
    await Future<void>.delayed(const Duration(seconds: 6));
    await tester.pump();
    final idle = frames.length;
    debugPrint('idle: $idle frames in 6 s');
    // A frame or two from timers that land in the window is fine; continuous drawing is ~360
    expect(idle, lessThanOrEqualTo(3), reason: 'something keeps redrawing a still map');

    // Panning: Flutter frames (card, compass) stay well inside 16 ms on the build side
    final map = find.byType(MapWidget);
    frames.clear();
    for (var i = 0; i < 6; i++) {
      await tester.timedDrag(map, const Offset(-120, 40), const Duration(milliseconds: 400));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    await tester.pump();
    final builds = [for (final f in frames) f.buildDuration.inMicroseconds / 1000]..sort();
    final p90 = builds.isEmpty ? 0.0 : builds[(builds.length * 0.9).floor().clamp(0, builds.length - 1)];
    debugPrint('panning: ${frames.length} frames, build p90 ${p90.toStringAsFixed(2)} ms');
    binding.reportData = {'idle_frames': idle, 'pan_frames': frames.length, 'pan_build_p90_ms': p90};
    expect(p90, lessThan(8), reason: 'Flutter work per frame while the map moves');
  });
}
