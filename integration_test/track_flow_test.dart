// The Track Recorder end to end on a simulator: the real GPS (the simulator walks a route, see
// tool/track_test.sh), the real SQLite store and the real map; the cloud is a recording fake and
// the signal is switched off and on by the test, so no test track reaches a real account.
//   Online: starts, uploads while recording, keeps recording with no signal (nothing sent,
//   "pending"), sends again when the signal is back, Finish → "Track saved", the last upload.
//   Offline: records on the phone only (nothing sent), Finish, then Upload to cloud by hand.
// Prints "SHOT:<name>" at each scene and "TRACK ..." lines with what happened.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:landscape360/core/config/app_config.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/core/theme/app_theme.dart';
import 'package:landscape360/data/tracks/track_local_store.dart';
import 'package:landscape360/domain/account/profile.dart';
import 'package:landscape360/domain/map/map_settings.dart';
import 'package:landscape360/domain/tracks/recorded_track.dart';
import 'package:landscape360/domain/tracks/track_recorder_geo.dart' show TrackStatus;
import 'package:landscape360/features/map/map_screen.dart';
import 'package:landscape360/features/map/map_settings_controller.dart';
import 'package:landscape360/features/tracks/track_recorder_state.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' show MapboxOptions;
import 'package:path_provider/path_provider.dart';

import '../test/features/track_recorder_state_test.dart' show FakeTrackCloud;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final config = AppConfig.fromEnvironment();

  Future<void> wait(WidgetTester tester, int ms) async {
    for (var i = 0; i < ms ~/ 100; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> shot(WidgetTester tester, String name, {int settle = 2500}) async {
    await wait(tester, settle);
    debugPrint('SHOT:$name');
    await wait(tester, 3000);
  }

  testWidgets('Track Recorder online and offline', (tester) async {
    MapboxOptions.setAccessToken(config.mapboxPublicToken);
    final dir = await getTemporaryDirectory();
    final local = SqliteTrackStore(path: '${dir.path}/track_flow_${DateTime.now().millisecondsSinceEpoch}.db');
    final cloud = FakeTrackCloud();
    final signal = StreamController<bool>.broadcast();
    var online = true;
    final c = ProviderContainer(
      overrides: [
        appConfigProvider.overrideWithValue(config),
        authUserIdProvider.overrideWith((ref) => Stream.value('u1')),
        profileProvider.overrideWith(
          (ref) async => const AccountProfile(
            userId: 'u1',
            email: 'rina@landscape360.app',
            displayName: 'Rina Wulandari',
            plan: Plan.enterprise,
            role: UserRole.pengguna360,
            isAdmin: false,
            canUseSos: false,
          ),
        ),
        storageUsageProvider.overrideWith((ref) async => null),
        trackLocalStoreProvider.overrideWithValue(local),
        trackCloudProvider.overrideWithValue(cloud),
        onlineProvider.overrideWith((ref) async* {
          yield online;
          yield* signal.stream;
        }),
        // Uploads while recording every 8 s instead of every minute
        trackSyncIntervalProvider.overrideWithValue(const Duration(seconds: 8)),
      ],
    );
    addTearDown(c.dispose);
    void setOnline(bool v) {
      online = v;
      signal.add(v);
    }

    TrackRecorderState st() => c.read(trackRecorderProvider);
    int uploads() => cloud.calls.where((x) => x.startsWith('upload')).length;
    void log(String what) {
      final s = st(), t = s.active;
      debugPrint(
        'TRACK $what: points ${s.activePoints.length}, ${t?.stats.distanceM.round() ?? '-'} m, '
        'sync ${t?.syncStatus.name ?? '-'}, gps ${s.gpsStatus.name}, uploads ${uploads()}',
      );
    }

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(debugShowCheckedModeBanner: false, theme: buildAppTheme(), home: const MapScreen()),
      ),
    );
    await wait(tester, 6000);
    c.read(mapSettingsProvider.notifier).setStyle(MapStyle.outdoors);
    final rec = c.read(trackRecorderProvider.notifier)..setPanelOpen(true);
    await wait(tester, 1500);

    // --- Online -----------------------------------------------------------------------------------
    await tester.enterText(find.byKey(const Key('track-name')), 'Merbabu online');
    await tester.tap(find.byKey(const Key('track-mode-online')));
    await wait(tester, 300);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.tap(find.byKey(const Key('track-start')));
    await wait(tester, 20000);
    log('online, recording');
    expect(st().recording, isTrue);
    expect(st().active!.mode, TrackMode.online);
    expect(st().activePoints.length, greaterThan(3), reason: 'fixes from the simulated walk');
    expect(uploads(), greaterThan(0), reason: 'uploaded while recording');
    await shot(tester, 'track1_online_recording', settle: 500);

    // The signal goes: recording carries on, nothing is sent
    setOnline(false);
    final before = uploads();
    final pointsBefore = st().activePoints.length;
    await wait(tester, 20000);
    log('online, no signal');
    expect(uploads(), before, reason: 'nothing sent without signal');
    expect(st().activePoints.length, greaterThan(pointsBefore), reason: 'still recording');
    await shot(tester, 'track2_no_signal', settle: 500);

    // The signal is back: what was recorded meanwhile goes up
    setOnline(true);
    await wait(tester, 12000);
    log('online, signal back');
    expect(uploads(), greaterThan(before));

    await tester.tap(find.byKey(const Key('track-pause')));
    await wait(tester, 800);
    expect(st().active!.status, TrackStatus.paused);
    await tester.tap(find.byKey(const Key('track-finish')));
    await wait(tester, 800);
    await tester.tap(find.text('Save Track'));
    await wait(tester, 2500);
    expect(find.text('Track saved'), findsOneWidget);
    await shot(tester, 'track3_saved', settle: 500);
    await tester.tap(find.text('Done'));
    await wait(tester, 800);
    final onlineTrack = (await local.listTracks('u1')).single;
    debugPrint(
      'TRACK online saved: ${onlineTrack.stats.pointCount} points, ${onlineTrack.stats.distanceM.round()} m, '
      '${onlineTrack.syncStatus.name}, last upload ${cloud.calls.lastWhere((x) => x.startsWith('upload'))}',
    );
    expect(onlineTrack.status, TrackStatus.completed);
    expect(onlineTrack.syncStatus, TrackSyncStatus.synced);
    expect(cloud.calls.last, startsWith('upload:completed:'));

    // --- Offline ----------------------------------------------------------------------------------
    final uploadsBeforeOffline = uploads();
    await tester.enterText(find.byKey(const Key('track-name')), 'Merbabu offline');
    await tester.tap(find.byKey(const Key('track-mode-offline')));
    await wait(tester, 300);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.tap(find.byKey(const Key('track-start')));
    await wait(tester, 20000);
    log('offline, recording');
    expect(st().active!.mode, TrackMode.offline);
    expect(st().activePoints.length, greaterThan(3));
    expect(uploads(), uploadsBeforeOffline, reason: 'an offline track stays on the phone');
    await shot(tester, 'track4_offline_recording', settle: 500);
    await tester.tap(find.byKey(const Key('track-finish')));
    await wait(tester, 800);
    await tester.tap(find.text('Save Track'));
    await wait(tester, 2500);
    await tester.tap(find.text('Done'));
    await wait(tester, 800);
    var offlineTrack = (await local.listTracks('u1')).firstWhere((t) => t.name == 'Merbabu offline');
    expect(offlineTrack.syncStatus, TrackSyncStatus.local);
    expect(uploads(), uploadsBeforeOffline);

    // Both in My Tracks; then the offline one goes up by hand
    await tester.tap(find.byKey(const Key('track-list')));
    await wait(tester, 2000);
    await shot(tester, 'track5_my_tracks', settle: 500);
    await tester.tap(find.byKey(Key('more-${offlineTrack.id}')));
    await wait(tester, 1000);
    await tester.tap(find.byKey(const Key('action-upload')));
    await wait(tester, 3000);
    offlineTrack = (await local.listTracks('u1')).firstWhere((t) => t.name == 'Merbabu offline');
    debugPrint(
      'TRACK offline saved: ${offlineTrack.stats.pointCount} points, ${offlineTrack.stats.distanceM.round()} m, '
      'after Upload to cloud: ${offlineTrack.syncStatus.name}',
    );
    expect(offlineTrack.syncStatus, TrackSyncStatus.synced);
    expect(uploads(), uploadsBeforeOffline + 1);

    // Shown on the map
    await rec.view(offlineTrack.id);
    if (find.byKey(const Key('track-import')).evaluate().isNotEmpty) {
      await tester.tapAt(const Offset(20, 80));
    }
    await shot(tester, 'track6_on_map', settle: 5000);
    await signal.close();
  });
}
