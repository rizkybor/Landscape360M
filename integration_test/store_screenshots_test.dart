// Store screenshots: the real app on the real map, scenes set up with sample data (no
// account needed). tool/store/screenshots.sh runs this on a simulator and saves the screen
// at every "SHOT:<name>" line; run alone it just walks through the scenes.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:landscape360/core/config/app_config.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/core/theme/app_theme.dart';
import 'package:landscape360/data/marked/marked_area_repository.dart';
import 'package:landscape360/data/offline/offline_maps.dart';
import 'package:landscape360/data/tracks/gps_source.dart';
import 'package:landscape360/domain/account/profile.dart';
import 'package:landscape360/domain/map/map_settings.dart';
import 'package:landscape360/domain/map/offline_regions.dart';
import 'package:landscape360/domain/survey/survey_utils.dart' show PointCorner;
import 'package:landscape360/domain/tracks/recorded_track.dart';
import 'package:landscape360/features/areas/area_state.dart';
import 'package:landscape360/features/live/live_tracking_state.dart';
import 'package:landscape360/features/map/map_screen.dart';
import 'package:landscape360/features/map/map_settings_controller.dart';
import 'package:landscape360/features/map/map_tools_state.dart';
import 'package:landscape360/features/marked/marked_state.dart';
import 'package:landscape360/features/navigator/navigator_state.dart';
import 'package:landscape360/features/offline/offline_state.dart';
import 'package:landscape360/features/sos/sos_screen.dart';
import 'package:landscape360/features/sos/sos_state.dart';
import 'package:landscape360/features/tracks/track_recorder_state.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' show MapboxOptions;

import '../test/features/areas_test.dart' show FakeAreas;
import '../test/features/live_tracking_test.dart' show FakeLiveChannel;
import '../test/features/marked_test.dart' show FakeMarked;
import '../test/features/navigator_state_test.dart' show FakeSurveys;
import '../test/features/offline_test.dart' show FakeEngine, FakeRecords;
import '../test/features/sos_state_test.dart' show FakeDevice, FakeSosBackend;
import '../test/features/track_recorder_panel_test.dart' show MemoryTrackStore;
import '../test/features/track_recorder_state_test.dart' show FakeGps, FakeTrackCloud;

// Mount Merbabu, Central Java: the Selo trail up to Kenteng Songo
const _trail = [
  (110.4399, -7.4868, 1840.0),
  (110.4372, -7.4790, 2120.0),
  (110.4412, -7.4712, 2395.0),
  (110.4378, -7.4640, 2680.0),
  (110.4421, -7.4581, 2910.0),
  (110.4398, -7.4547, 3142.0),
];

const _member = AccountProfile(
  userId: 'u1',
  email: 'rina@landscape360.app',
  displayName: 'Rina Wulandari',
  plan: Plan.enterprise,
  role: UserRole.pengguna360,
  isAdmin: false,
  canUseSos: true,
  organization: 'Mapala Merbabu',
);

WidgetRef? _ref;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final config = AppConfig.fromEnvironment();

  Future<void> wait(WidgetTester tester, int ms) async {
    for (var i = 0; i < ms ~/ 50; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  // Tiles load, then the screen is held still while it is saved (slower devices such as an
  // emulator get more time: --dart-define=L360_SHOT_SLOW=2)
  Future<void> shot(WidgetTester tester, String name, {int settle = 9000}) async {
    await wait(tester, settle * const int.fromEnvironment('L360_SHOT_SLOW', defaultValue: 1));
    debugPrint('SHOT:$name');
    await wait(tester, 5000);
  }

  testWidgets('store screenshots', (tester) async {
    MapboxOptions.setAccessToken(config.mapboxPublicToken);
    final gps = FakeGps();
    final areas = FakeAreas();
    final crater = [
      MarkedArea(
        id: 'crater',
        userId: 'u1',
        name: 'Zona Kawah Condrodimuko',
        color: '#E46C24',
        notes: 'Area camp darurat',
        ring: const [(110.4352, -7.4598), (110.4441, -7.4589), (110.4459, -7.4521), (110.4370, -7.4502)],
        areaM2: 742000,
        perimeterM: 3480,
      ),
    ];
    final records = FakeRecords()
      ..rows = [
        const OfflineRegionRecord(
          id: 'r1',
          name: 'Merbabu via Selo',
          bounds: OfflineBounds(west: 110.40, south: -7.50, east: 110.48, north: -7.43),
          minZoom: 10,
          maxZoom: 16,
          tileCount: 2140,
          sizeEstMb: 38,
        ),
      ];
    // The screens' running timers read the real clock: the climb started 90 minutes ago
    var now = DateTime.now().millisecondsSinceEpoch - 90 * 60 * 1000;
    final container = ProviderContainer(
      overrides: [
        appConfigProvider.overrideWithValue(config),
        authUserIdProvider.overrideWith((ref) => Stream.value('u1')),
        profileProvider.overrideWith((ref) async => _member),
        storageUsageProvider.overrideWith((ref) async => null),
        surveyBackendProvider.overrideWithValue(FakeSurveys()),
        areaBackendProvider.overrideWithValue(areas),
        markedBackendProvider.overrideWithValue(FakeMarked()),
        offlineRecordsProvider.overrideWithValue(records),
        offlineEngineProvider.overrideWithValue(FakeEngine()..stored0['r1'] = 38 * 1024 * 1024),
        trackLocalStoreProvider.overrideWithValue(MemoryTrackStore()),
        trackCloudProvider.overrideWithValue(FakeTrackCloud()),
        trackClockProvider.overrideWithValue(() => now),
        gpsSourceProvider.overrideWithValue(gps),
        sosBackendProvider.overrideWithValue(FakeSosBackend()),
        sosDeviceProvider.overrideWithValue(FakeDevice()),
        liveChannelProvider.overrideWithValue(FakeLiveChannel()),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(),
          home: Consumer(
            builder: (context, ref, _) {
              _ref = ref;
              return const MapScreen();
            },
          ),
        ),
      ),
    );
    await wait(tester, 6000);
    final settings = container.read(mapSettingsProvider.notifier);
    final fly = container.read(flyToProvider.notifier);

    // 1. 3D terrain with contours
    settings
      ..setStyle(MapStyle.satellite)
      ..setView(MapView.threeD)
      ..setShowContours(true);
    fly.go(110.4405, -7.4640, zoom: 13.4);
    await shot(tester, '1_3d_terrain', settle: 14000);

    // 2. Navigator: a survey line with curves and a sharp corner
    final nav = container.read(navigatorProvider.notifier)..open();
    for (final (lng, lat, elev) in _trail) {
      await nav.addPointAt(lng, lat, (_, _) async => elev);
    }
    final group = container.read(navigatorProvider).doc.groups.single;
    nav.setCorner(group.id, group.points[3].id, PointCorner.sharp);
    container.read(fitPointsProvider.notifier).go([for (final (lng, lat, _) in _trail) (lng, lat)]);
    await shot(tester, '2_navigator');
    nav
      ..clearPoints(group.id)
      ..close();

    // 3. Track Recorder: an hour and a half into a climb, panel open
    settings.setStyle(MapStyle.outdoors);
    final rec = container.read(trackRecorderProvider.notifier);
    await rec.start('Pendakian Merbabu', TrackMode.online);
    for (var i = 0; i < 60; i++) {
      final t = i / 59;
      final seg = (t * (_trail.length - 1)).clamp(0, _trail.length - 1.001);
      final a = _trail[seg.floor()], b = _trail[seg.floor() + 1], f = seg - seg.floor();
      now += 88 * 1000;
      gps.controller!.add(
        GpsFix(
          lat: a.$2 + (b.$2 - a.$2) * f + (i.isEven ? 0.00012 : -0.0001),
          lng: a.$1 + (b.$1 - a.$1) * f,
          alt: a.$3 + (b.$3 - a.$3) * f,
          accuracy: 4,
          speed: 0.9,
          timestamp: now,
        ),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    rec.setPanelOpen(true);
    container.read(fitPointsProvider.notifier).go([for (final (lng, lat, _) in _trail) (lng, lat)]);
    await shot(tester, '3_track_recorder');
    await rec.discard();
    rec.setPanelOpen(false);

    // 4. Marked Area in focus
    areas.rows = crater;
    final areaCtrl = container.read(areasProvider.notifier);
    await areaCtrl.load();
    areaCtrl.focus('crater');
    await shot(tester, '4_area_focus');
    areaCtrl.focus(null);

    // 5. Offline map: choosing an area to download
    settings.setStyle(MapStyle.satellite);
    fly.go(110.4405, -7.4700, zoom: 12.6);
    await wait(tester, 3000);
    container.read(offlineProvider.notifier).startFraming();
    await shot(tester, '5_offline_map');
    container.read(offlineProvider.notifier).stopFraming();
    areas.rows = [];
    await areaCtrl.load();

    // 6. Your position with the compass beam (the simulator's location is set by the script)
    settings
      ..setStyle(MapStyle.outdoors)
      ..setView(MapView.twoD);
    await tester.tap(find.byKey(const Key('locate-me')));
    await wait(tester, 3000);
    fly.go(110.4396, -7.4552, zoom: 16.5);
    await shot(tester, '6_my_location');

    // 7. S.O.S, sending
    unawaited(openSosScreen(tester.element(find.byType(MapScreen)), _ref!));
    await wait(tester, 500);
    now = DateTime.now().millisecondsSinceEpoch;
    gps.controller?.add(GpsFix(lat: -7.4547, lng: 110.4398, alt: 3142, accuracy: 6, speed: 0, timestamp: now));
    await shot(tester, '7_sos', settle: 8000);
    await container.read(sosProvider.notifier).close();
    await wait(tester, 1000);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
