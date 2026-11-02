// GPX import end to end on the real map: Tracks → Import GPX (the file picker gives a Merbabu
// track from another app) → the track in My Tracks and on the map. Tracks stay in memory.
//   flutter test integration_test/gpx_import_flow_test.dart -d <device> --dart-define-from-file=config/dev.json
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:landscape360/core/config/app_config.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/core/theme/app_theme.dart';
import 'package:landscape360/domain/account/profile.dart';
import 'package:landscape360/domain/map/map_settings.dart';
import 'package:landscape360/features/map/map_screen.dart';
import 'package:landscape360/features/map/map_settings_controller.dart';
import 'package:landscape360/features/tracks/track_recorder_panel.dart';
import 'package:landscape360/features/tracks/track_recorder_state.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' show MapboxOptions;

import '../test/features/track_recorder_panel_test.dart' show MemoryTrackStore;
import '../test/features/track_recorder_state_test.dart' show FakeGps, FakeTrackCloud;

// The Selo trail up Merbabu, a point a minute, as another app would export it
Uint8List _seloGpx() {
  const trail = [
    (110.4399, -7.4868, 1840.0),
    (110.4372, -7.4790, 2120.0),
    (110.4412, -7.4712, 2395.0),
    (110.4378, -7.4640, 2680.0),
    (110.4421, -7.4581, 2910.0),
    (110.4398, -7.4547, 3142.0),
  ];
  final start = DateTime.utc(2026, 10, 18, 22);
  final pts = StringBuffer();
  var minute = 0;
  for (var i = 0; i < trail.length - 1; i++) {
    final a = trail[i], b = trail[i + 1];
    for (var k = 0; k < 20; k++) {
      final f = k / 20;
      final t = start.add(Duration(minutes: minute++ * 3)).toIso8601String();
      pts.write(
        '<trkpt lat="${(a.$2 + (b.$2 - a.$2) * f).toStringAsFixed(6)}" lon="${(a.$1 + (b.$1 - a.$1) * f).toStringAsFixed(6)}">'
        '<ele>${(a.$3 + (b.$3 - a.$3) * f).toStringAsFixed(1)}</ele><time>$t</time></trkpt>',
      );
    }
  }
  return Uint8List.fromList(
    utf8.encode(
      '<?xml version="1.0"?><gpx version="1.1" creator="Strava" xmlns="http://www.topografix.com/GPX/1/1">'
      '<trk><name>Merbabu via Selo</name><trkseg>$pts</trkseg></trk></gpx>',
    ),
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final config = AppConfig.fromEnvironment();

  Future<void> wait(WidgetTester tester, int ms) async {
    for (var i = 0; i < ms ~/ 50; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> shot(WidgetTester tester, String name, {int settle = 7000}) async {
    await wait(tester, settle);
    debugPrint('SHOT:$name');
    await wait(tester, 4000);
  }

  testWidgets('GPX import: into My Tracks and onto the map', (tester) async {
    MapboxOptions.setAccessToken(config.mapboxPublicToken);
    final c = ProviderContainer(
      overrides: [
        appConfigProvider.overrideWithValue(config),
        authUserIdProvider.overrideWith((ref) => Stream.value('u1')),
        profileProvider.overrideWith(
          (ref) async => const AccountProfile(
            userId: 'u1',
            email: 'rina@landscape360.app',
            displayName: 'Rina Wulandari',
            plan: Plan.pro,
            role: UserRole.pengguna360,
            isAdmin: false,
            canUseSos: false,
          ),
        ),
        storageUsageProvider.overrideWith((ref) async => null),
        trackLocalStoreProvider.overrideWithValue(MemoryTrackStore()),
        trackCloudProvider.overrideWithValue(FakeTrackCloud()),
        gpsSourceProvider.overrideWithValue(FakeGps()),
        gpxPickerProvider.overrideWithValue(() async => [(name: 'merbabu.gpx', bytes: _seloGpx())]),
      ],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(debugShowCheckedModeBanner: false, theme: buildAppTheme(), home: const MapScreen()),
      ),
    );
    await wait(tester, 6000);
    c.read(mapSettingsProvider.notifier).setStyle(MapStyle.outdoors);
    c.read(trackRecorderProvider.notifier).setPanelOpen(true);
    await wait(tester, 1500);

    await tester.tap(find.byKey(const Key('track-list')));
    await wait(tester, 1500);
    expect(find.byKey(const Key('track-import')), findsOneWidget);
    await shot(tester, 'gpx1_sheet', settle: 1500);

    await tester.tap(find.byKey(const Key('track-import')));
    await wait(tester, 2000);
    final s = c.read(trackRecorderProvider);
    expect(s.error, isNull);
    final t = s.tracks.single;
    debugPrint(
      'IMPORTED ${t.name}: ${t.stats.pointCount} points, ${(t.stats.distanceM / 1000).toStringAsFixed(2)} km, '
      '+${t.stats.elevationGainM.round()} m, ${(t.elapsedMs / 60000).round()} min, ${t.syncStatus.name}',
    );
    expect((t.name, t.stats.pointCount), ('Merbabu via Selo', 100));
    expect(s.viewing?.track.id, t.id);
    await shot(tester, 'gpx2_on_map', settle: 9000);

    await tester.tap(find.byKey(const Key('track-list')));
    await wait(tester, 1500);
    expect(find.text('Merbabu via Selo'), findsOneWidget);
    await shot(tester, 'gpx3_my_tracks', settle: 1500);
  });
}
