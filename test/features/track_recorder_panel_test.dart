import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/core/theme/app_theme.dart';
import 'package:landscape360/data/tracks/gps_source.dart';
import 'package:landscape360/data/tracks/track_local_store.dart';
import 'package:landscape360/domain/account/profile.dart';
import 'package:landscape360/domain/tracks/recorded_track.dart';
import 'package:landscape360/domain/tracks/track_recorder_geo.dart';
import 'package:landscape360/features/tracks/track_recorder_panel.dart';
import 'package:landscape360/features/tracks/track_recorder_state.dart';

import 'track_recorder_state_test.dart' show FakeGps, FakeTrackCloud;

// The Track Recorder panel: who may record, the permission explanation, live stats and
// controls, the REC pill and the tracks sheet

class MemoryTrackStore implements TrackLocalStore {
  final tracks = <String, RecordedTrack>{};
  final points = <String, Map<int, TrackPoint>>{};

  @override
  Future<void> saveTrack(RecordedTrack track) async => tracks[track.id] = track;

  @override
  Future<RecordedTrack?> getTrack(String id) async => tracks[id];

  @override
  Future<List<RecordedTrack>> listTracks(String userId) async =>
      tracks.values.where((t) => t.userId == userId).toList()..sort((a, b) => b.startedAt.compareTo(a.startedAt));

  @override
  Future<void> addPoint(String trackId, int seq, TrackPoint point) async => (points[trackId] ??= {})[seq] = point;

  @override
  Future<List<TrackPoint>> getPoints(String trackId) async {
    final m = points[trackId] ?? const {};
    return [for (final k in m.keys.toList()..sort()) m[k]!];
  }

  @override
  Future<void> deleteTrack(String trackId) async {
    tracks.remove(trackId);
    points.remove(trackId);
  }
}

class AskingGps extends FakeGps {
  GpsAccess state = GpsAccess.denied;
  int requests = 0;

  @override
  Future<GpsAccess> access() async => state;

  @override
  Future<GpsAccess> request() async {
    requests++;
    return state = GpsAccess.allowed;
  }
}

AccountProfile _profile(Plan plan) => AccountProfile(
  userId: 'u1',
  email: 'u@x.id',
  displayName: 'U',
  plan: plan,
  role: UserRole.pengguna360,
  isAdmin: false,
  canUseSos: false,
);

void main() {
  late MemoryTrackStore local;
  late FakeTrackCloud cloud;
  late AskingGps gps;

  setUp(() {
    local = MemoryTrackStore();
    cloud = FakeTrackCloud();
    gps = AskingGps();
  });

  // The REC dot pulses for ever, so time is moved on by hand instead of pumpAndSettle
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<ProviderContainer> pump(WidgetTester tester, {Plan plan = Plan.enterprise}) async {
    final c = ProviderContainer(
      overrides: [
        trackLocalStoreProvider.overrideWithValue(local),
        trackCloudProvider.overrideWithValue(cloud),
        gpsSourceProvider.overrideWithValue(gps),
        onlineProvider.overrideWith((ref) => Stream.value(true)),
        authUserIdProvider.overrideWith((ref) => Stream.value('u1')),
        profileProvider.overrideWith((ref) async => _profile(plan)),
      ],
    );
    addTearDown(c.dispose);
    c.listen(profileProvider, (_, _) {});
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: const Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: EdgeInsets.all(12),
                child: Column(mainAxisSize: MainAxisSize.min, children: [RecPill(), TrackRecorderPanel()]),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return c;
  }

  testWidgets('Free and Pro see the lock and can still open their tracks', (tester) async {
    await pump(tester, plan: Plan.pro);
    expect(find.textContaining('available for Enterprise accounts'), findsOneWidget);
    expect(find.byKey(const Key('track-start')), findsNothing);
    expect(find.byKey(const Key('track-list')), findsOneWidget);
  });

  testWidgets('starting explains location first, then records with live stats', (tester) async {
    final c = await pump(tester);
    await tester.enterText(find.byKey(const Key('track-name')), 'Gede');
    await tester.tap(find.byKey(const Key('track-mode-offline')));
    await tester.tap(find.byKey(const Key('track-start')));
    await settle(tester);
    expect(find.text('Allow location to record'), findsOneWidget);
    expect(gps.requests, 0, reason: 'nothing asked before the explanation');
    await tester.tap(find.text('Continue'));
    await settle(tester);
    expect(gps.requests, 1);

    final s = c.read(trackRecorderProvider);
    expect((s.active!.name, s.active!.mode, s.gpsStatus), ('Gede', TrackMode.offline, GpsStatus.searching));
    gps.controller!.add(
      GpsFix(
        lat: -6.2,
        lng: 106.8,
        alt: 2958.4,
        accuracy: 4,
        speed: 1,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    await tester.pump();
    expect(find.text('Recording'), findsOneWidget);
    expect(find.text('2958 m'), findsOneWidget);
    expect(find.textContaining('GPS locked · ±4 m · 1 points'), findsOneWidget);
    expect(find.text('Saved on this phone'), findsOneWidget);
  });

  testWidgets('already allowed: no explanation; Finish asks first and saves', (tester) async {
    gps.state = GpsAccess.allowed;
    final c = await pump(tester);
    await tester.tap(find.byKey(const Key('track-start')));
    await settle(tester);
    expect(find.text('Allow location to record'), findsNothing);
    expect(c.read(trackRecorderProvider).recording, isTrue);

    await tester.tap(find.byKey(const Key('track-pause')));
    await settle(tester);
    expect(find.text('Paused'), findsOneWidget);
    expect(find.text('Resume'), findsOneWidget);

    await tester.tap(find.byKey(const Key('track-finish')));
    await settle(tester);
    await tester.tap(find.text('Save Track'));
    await settle(tester);
    expect(c.read(trackRecorderProvider).active, isNull);
    expect(local.tracks.values.single.status, TrackStatus.completed);
  });

  testWidgets('closing the panel while recording leaves the REC pill, which opens it again', (tester) async {
    gps.state = GpsAccess.allowed;
    final c = await pump(tester);
    await tester.tap(find.byKey(const Key('track-start')));
    await settle(tester);
    c.read(trackRecorderProvider.notifier).setPanelOpen(false);
    await tester.pump();
    // The panel is still in this test's tree; the map screen hides it when closed
    expect(find.byKey(const Key('rec-pill')), findsOneWidget);
    expect(find.text('REC'), findsOneWidget);
    await tester.tap(find.byKey(const Key('rec-pill')));
    await tester.pump();
    expect(c.read(trackRecorderProvider).panelOpen, isTrue);
    unawaited(c.read(trackRecorderProvider.notifier).discard());
    await settle(tester);
  });

  testWidgets('the tracks sheet lists mine and the shared ones', (tester) async {
    local.tracks['t1'] = const RecordedTrack(
      id: 't1',
      userId: 'u1',
      name: 'Merbabu',
      mode: TrackMode.offline,
      status: TrackStatus.completed,
      startedAt: 1761600000000,
      elapsedMs: 3723000,
      stats: TrackStats(distanceM: 5230, elevationGainM: 812),
      syncStatus: TrackSyncStatus.local,
      updatedAt: 1761600000000,
    );
    cloud.sharedWithMe = [
      const SharedTrack(
        track: RecordedTrack(
          id: 's1',
          userId: 'other',
          name: 'Friend hike',
          mode: TrackMode.online,
          status: TrackStatus.recording,
          startedAt: 1,
          syncStatus: TrackSyncStatus.remote,
          syncedAt: 2,
          updatedAt: 2,
        ),
        ownerEmail: 'friend@example.com',
        sharedAt: 3,
      ),
    ];
    await pump(tester);
    await tester.tap(find.byKey(const Key('track-list')));
    await settle(tester);
    expect(find.text('Merbabu'), findsOneWidget);
    expect(find.textContaining('5.23 km · 01:02:03 · ↑ 812 m'), findsOneWidget);
    expect(find.text('PHONE ONLY'), findsOneWidget);

    await tester.tap(find.byKey(const Key('more-t1')));
    await settle(tester);
    expect(find.byKey(const Key('action-share')), findsOneWidget, reason: 'Enterprise can share');
    expect(find.byKey(const Key('action-upload')), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await settle(tester);

    await tester.tap(find.byKey(const Key('tab-shared')));
    await settle(tester);
    expect(find.text('by friend@example.com'), findsOneWidget);
    expect(find.textContaining('IN PROGRESS'), findsOneWidget);
  });
}
