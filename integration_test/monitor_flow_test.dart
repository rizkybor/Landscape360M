// Team Monitor on a simulator, on the real map, with the tracking room in memory: members
// moving around Merbabu with their trails, one idle and one offline, the card of a member, the
// Monitor sheet, a recalled activity, and the tracking lists. Prints "SHOT:<name>" at each scene.
//   flutter test integration_test/monitor_flow_test.dart -d <simulator> --dart-define-from-file=config/dev.json
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:landscape360/core/config/app_config.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/core/theme/app_theme.dart';
import 'package:landscape360/domain/account/profile.dart';
import 'package:landscape360/domain/live/monitor.dart';
import 'package:landscape360/domain/map/map_settings.dart';
import 'package:landscape360/features/areas/area_state.dart';
import 'package:landscape360/features/live/live_tracking_state.dart';
import 'package:landscape360/features/live/monitor_sheet.dart';
import 'package:landscape360/features/live/monitor_state.dart';
import 'package:landscape360/features/map/map_screen.dart';
import 'package:landscape360/features/map/map_settings_controller.dart';
import 'package:landscape360/features/map/map_tools_state.dart';
import 'package:landscape360/features/marked/marked_state.dart';
import 'package:landscape360/features/navigator/navigator_state.dart';
import 'package:landscape360/features/offline/offline_state.dart';
import 'package:landscape360/features/sos/sos_state.dart';
import 'package:landscape360/features/tracks/track_recorder_state.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' show MapboxOptions;

import '../test/features/areas_test.dart' show FakeAreas;
import '../test/features/live_tracking_test.dart' show FakeLiveChannel;
import '../test/features/marked_test.dart' show FakeMarked;
import '../test/features/monitor_test.dart' show FakeMonitorChannel, FakeMonitorRepository;
import '../test/features/navigator_state_test.dart' show FakeSurveys;
import '../test/features/offline_test.dart' show FakeEngine, FakeRecords;
import '../test/features/sos_state_test.dart' show FakeDevice, FakeSosBackend;
import '../test/features/track_recorder_panel_test.dart' show MemoryTrackStore;
import '../test/features/track_recorder_state_test.dart' show FakeGps, FakeTrackCloud;

// The Selo trail up Merbabu
const _trail = [
  (110.4399, -7.4868),
  (110.4372, -7.4790),
  (110.4412, -7.4712),
  (110.4378, -7.4640),
  (110.4421, -7.4581),
  (110.4398, -7.4547),
];

const _monitor = AccountProfile(
  userId: 'u-ops',
  email: 'posko.selo@landscape360.app',
  displayName: 'Posko Selo',
  plan: Plan.enterprise,
  role: UserRole.monitor360,
  isAdmin: false,
  canUseSos: true,
  organization: 'SAR Magelang',
);

(double, double) _along(double t) {
  final seg = (t * (_trail.length - 1)).clamp(0, _trail.length - 1.001);
  final a = _trail[seg.floor()], b = _trail[seg.floor() + 1], f = seg - seg.floor();
  return (a.$1 + (b.$1 - a.$1) * f, a.$2 + (b.$2 - a.$2) * f);
}

Map<String, dynamic> _packet(
  String id,
  double t, {
  double speed = 1.2,
  int battery = 80,
  Duration ago = Duration.zero,
}) {
  final (lng, lat) = _along(t);
  return {
    'user_id': id,
    'lat': lat,
    'lng': lng,
    'alt': 1840 + 1300 * t,
    'speed': speed,
    'battery': battery,
    'timestamp': DateTime.now().toUtc().subtract(ago).toIso8601String(),
    'status': 'active',
  };
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

  testWidgets('Team Monitor on the map', (tester) async {
    MapboxOptions.setAccessToken(config.mapboxPublicToken);
    final channel = FakeMonitorChannel();
    final repo = FakeMonitorRepository();
    final started = DateTime.now().subtract(const Duration(hours: 3));
    repo.sessions.addAll([
      ActivitySummary(
        sessionId: 's1',
        userId: 'u-budi',
        startedAt: started,
        endedAt: started.add(const Duration(hours: 2, minutes: 40)),
        distanceM: 4020,
        pointCount: 40,
        email: 'budi.santoso@x.id',
      ),
      ActivitySummary(
        sessionId: 's2',
        userId: 'u-citra',
        startedAt: DateTime.now().subtract(const Duration(minutes: 50)),
        distanceM: 1250,
        pointCount: 18,
        email: 'citra.p@x.id',
      ),
    ]);
    repo.points['s1'] = [
      for (var i = 0; i < 40; i++)
        MonitorPacket(
          trackerId: 'BUDI.SANTOSO',
          lat: _along(i / 39).$2 + (i.isEven ? 0.00008 : -0.00008),
          lng: _along(i / 39).$1,
          alt: 1840 + 1300 * i / 39,
          speed: 1.1,
          time: started.add(Duration(minutes: 4 * i)).millisecondsSinceEpoch,
        ),
    ];
    repo.logList.addAll([
      for (var i = 0; i < 6; i++)
        TrackerLog(
          id: 'l$i',
          userId: i.isEven ? 'u-budi' : 'u-citra',
          lat: _along(0.3 + i * 0.1).$2,
          lng: _along(0.3 + i * 0.1).$1,
          elevation: 2000 + 120.0 * i,
          speed: 1.0 + i * 0.2,
          time: DateTime.now().subtract(Duration(minutes: 3 * i)),
          email: i.isEven ? 'budi.santoso@x.id' : 'citra.p@x.id',
        ),
    ]);
    repo.profiles['RINA.HIKER'] = const TrackerProfile(
      trackerId: 'RINA.HIKER',
      userId: 'u-rina',
      name: 'Rina Wulandari',
      email: 'rina.hiker@landscape360.app',
      organization: 'Mapala Merbabu',
      phone: '0812 3456 7890',
      plan: 'Pro',
      role: 'pengguna360',
      avatarPath: 'u-rina/avatar-1.jpg',
    );
    repo.profiles['BUDI.SANTOSO'] = const TrackerProfile(
      trackerId: 'BUDI.SANTOSO',
      userId: 'u-budi',
      name: 'Budi Santoso',
      email: 'budi.santoso@x.id',
      organization: 'SAR Magelang',
      plan: 'Enterprise',
      role: 'pengguna360',
    );
    // Rina's photo, "served" from memory: a warm portrait-like square
    final portrait = img.Image(width: 256, height: 256);
    img.fill(portrait, color: img.ColorRgb8(214, 140, 96));
    img.fillCircle(portrait, x: 128, y: 100, radius: 50, color: img.ColorRgb8(90, 50, 30));
    img.fillRect(portrait, x1: 70, y1: 150, x2: 186, y2: 255, color: img.ColorRgb8(40, 90, 150));
    final photo = img.encodeJpg(portrait, quality: 80);
    var now = DateTime.now().millisecondsSinceEpoch;
    final container = ProviderContainer(
      overrides: [
        appConfigProvider.overrideWithValue(config),
        authUserIdProvider.overrideWith((ref) => Stream.value('u-ops')),
        profileProvider.overrideWith((ref) async => _monitor),
        storageUsageProvider.overrideWith((ref) async => null),
        surveyBackendProvider.overrideWithValue(FakeSurveys()),
        areaBackendProvider.overrideWithValue(FakeAreas()),
        markedBackendProvider.overrideWithValue(FakeMarked()),
        offlineRecordsProvider.overrideWithValue(FakeRecords()),
        offlineEngineProvider.overrideWithValue(FakeEngine()),
        trackLocalStoreProvider.overrideWithValue(MemoryTrackStore()),
        trackCloudProvider.overrideWithValue(FakeTrackCloud()),
        trackClockProvider.overrideWithValue(() => now),
        gpsSourceProvider.overrideWithValue(FakeGps()),
        sosBackendProvider.overrideWithValue(FakeSosBackend()),
        sosDeviceProvider.overrideWithValue(FakeDevice()),
        liveChannelProvider.overrideWithValue(FakeLiveChannel()),
        monitorChannelProvider.overrideWithValue(channel),
        monitorRepositoryProvider.overrideWithValue(repo),
        monitorPhotoFetchProvider.overrideWithValue((_) async => photo),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(debugShowCheckedModeBanner: false, theme: buildAppTheme(), home: const MapScreen()),
      ),
    );
    await wait(tester, 6000);
    container.read(mapSettingsProvider.notifier)
      ..setStyle(MapStyle.outdoors)
      ..setView(MapView.twoD);
    final fly = container.read(flyToProvider.notifier);
    fly.go(110.4395, -7.4700, zoom: 13.6);

    // 1. Monitoring: four members on the trail, one standing still, one gone quiet
    final monitor = container.read(monitorProvider.notifier);
    await monitor.start();
    for (var i = 0; i <= 30; i++) {
      now = DateTime.now().millisecondsSinceEpoch;
      channel
        ..hear(_packet('RINA.HIKER', 0.15 + i * 0.012, battery: 78))
        ..hear(_packet('BUDI.SANTOSO', 0.45 + i * 0.01, battery: 64))
        ..hear(_packet('DODI.R', 0.80, speed: 0.2, battery: 41));
      await tester.pump(const Duration(milliseconds: 40));
    }
    channel.hear(_packet('EKA.N', 0.62, speed: 0, battery: 12, ago: const Duration(minutes: 7)));
    await shot(tester, 'monitor1_map', settle: 9000);

    // 2. A member's card
    monitor.select('RINA.HIKER');
    await shot(tester, 'monitor2_card');
    monitor.select(null);

    // 3. The Monitor sheet with the members
    unawaited(showMonitorSheet(tester.element(find.byType(MapScreen))));
    await shot(tester, 'monitor3_sheet', settle: 2500);
    Navigator.of(tester.element(find.byType(MapScreen))).pop();
    await wait(tester, 800);

    // 4. The tracking lists
    unawaited(showTrackingLists(tester.element(find.byType(MapScreen))));
    await shot(tester, 'monitor4_lists', settle: 2500);
    Navigator.of(tester.element(find.byType(MapScreen))).pop();
    await wait(tester, 800);

    // 5. A recalled activity on the map
    monitor.showSession(repo.points['s1']!);
    fly.go(110.4395, -7.4700, zoom: 13.6);
    await shot(tester, 'monitor5_activity');
  });
}
