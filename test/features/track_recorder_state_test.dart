import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/data/tracks/gps_source.dart';
import 'package:landscape360/data/tracks/track_cloud.dart';
import 'package:landscape360/data/tracks/track_local_store.dart';
import 'package:landscape360/domain/account/profile.dart';
import 'package:landscape360/domain/tracks/recorded_track.dart';
import 'package:landscape360/domain/tracks/track_recorder_geo.dart';
import 'package:landscape360/features/tracks/track_recorder_state.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// The Track Recorder's rules, same cases as useTrackRecorderStore.test.ts (web), on the real
// SQLite store

class FakeTrackCloud implements TrackCloud {
  final rows = <String, (RecordedTrack, List<TrackPoint>)>{};
  final calls = <String>[];
  Object? uploadError;
  Object? deleteError;
  List<RecordedTrack> remote = [];
  List<SharedTrack> sharedWithMe = [];
  Map<String, List<TrackPoint>> remotePoints = {};

  @override
  Future<void> upload(RecordedTrack track, List<TrackPoint> points) async {
    calls.add('upload:${track.status.name}:${points.length}');
    final e = uploadError;
    if (e != null) {
      uploadError = null;
      throw e;
    }
    rows[track.id] = (track, points);
  }

  @override
  Future<List<RecordedTrack>> fetchTracks(String userId) async => remote;

  @override
  Future<List<TrackPoint>> fetchPoints(String trackId) async {
    calls.add('points:$trackId');
    return remotePoints[trackId] ?? rows[trackId]?.$2 ?? const [];
  }

  @override
  Future<void> rename(String trackId, String name) async => calls.add('rename:$trackId:$name');

  @override
  Future<void> delete(String trackId) async {
    calls.add('delete:$trackId');
    final e = deleteError;
    if (e != null) {
      deleteError = null;
      throw e;
    }
    rows.remove(trackId);
  }

  @override
  Future<TrackShare> share(String trackId, String email) async {
    calls.add('share:$trackId:$email');
    return TrackShare(userId: 'r1', email: email, sharedAt: 1);
  }

  @override
  Future<List<TrackShare>> listShares(String trackId) async => const [];

  @override
  Future<void> revokeShare(String trackId, String recipientId) async => calls.add('revoke:$trackId:$recipientId');

  @override
  Future<List<SharedTrack>> fetchSharedWithMe() async => sharedWithMe;
}

class FakeGps implements GpsSource {
  // ignore: close_sinks, closed when the recorder cancels its subscription
  StreamController<GpsFix>? controller;
  int watches = 0;

  bool get watching => controller != null && !controller!.isClosed && controller!.hasListener;

  @override
  Future<GpsAccess> access() async => GpsAccess.allowed;

  @override
  Future<GpsAccess> request() async => GpsAccess.allowed;

  @override
  Future<void> openSettings() async {}

  @override
  Stream<GpsFix> watch() {
    watches++;
    controller = StreamController<GpsFix>();
    return controller!.stream;
  }
}

AccountProfile _profile(Plan plan, {bool admin = false}) => AccountProfile(
  userId: 'u1',
  email: 'u@x.id',
  displayName: 'U',
  plan: plan,
  role: UserRole.pengguna360,
  isAdmin: admin,
  canUseSos: false,
);

void main() {
  sqfliteFfiInit();
  late Directory dir;
  late SqliteTrackStore local;
  late FakeTrackCloud cloud;
  late FakeGps gps;
  late StreamController<bool> online;
  late StreamController<String?> auth;
  late int clock;
  late Plan plan; // the account's plan as the server returns it

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tracks');
    local = SqliteTrackStore(factory: databaseFactoryFfi, path: '${dir.path}/t.db');
    cloud = FakeTrackCloud();
    gps = FakeGps();
    online = StreamController<bool>.broadcast();
    auth = StreamController<String?>.broadcast();
    clock = 1700000000000;
    plan = Plan.enterprise;
    addTearDown(() async {
      await online.close();
      await auth.close();
      await dir.delete(recursive: true);
    });
  });

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));

  Future<ProviderContainer> signedIn({
    bool admin = false,
    String user = 'u1',
    Duration syncEvery = trackAutoSyncInterval,
  }) async {
    final c = ProviderContainer(
      overrides: [
        trackLocalStoreProvider.overrideWithValue(local),
        trackCloudProvider.overrideWithValue(cloud),
        gpsSourceProvider.overrideWithValue(gps),
        trackClockProvider.overrideWithValue(() => clock),
        trackSyncIntervalProvider.overrideWithValue(syncEvery),
        onlineProvider.overrideWith((ref) => online.stream),
        authUserIdProvider.overrideWith((ref) => auth.stream),
        profileProvider.overrideWith((ref) async => _profile(plan, admin: admin)),
      ],
    );
    addTearDown(c.dispose);
    c.listen(trackRecorderProvider, (_, _) {});
    c.listen(profileProvider, (_, _) {});
    c.listen(onlineProvider, (_, _) {});
    online.add(true);
    auth.add(user);
    await settle();
    return c;
  }

  TrackRecorderController rec(ProviderContainer c) => c.read(trackRecorderProvider.notifier);
  TrackRecorderState st(ProviderContainer c) => c.read(trackRecorderProvider);

  // Walk north ~11 m every 5 s (the GPS stream of the phone)
  Future<void> walk(int steps, {double alt = 1000}) async {
    for (var i = 0; i < steps; i++) {
      clock += 5000;
      gps.controller!.add(
        GpsFix(lat: -7.6 - (clock / 5000) * 0.0001, lng: 110.45, alt: alt + i, accuracy: 5, speed: 2, timestamp: clock),
      );
    }
    await settle();
  }

  test('only Enterprise and admin record; Pro also renames cloud tracks', () {
    expect([for (final p in Plan.values) _profile(p).canRecordTracks], [false, false, true]);
    expect(_profile(Plan.free, admin: true).canRecordTracks, isTrue);
    expect([for (final p in Plan.values) _profile(p).canRenameCloudTracks], [false, true, true]);
  });

  test('records an offline track on the phone without uploading it', () async {
    final c = await signedIn();
    await rec(c).start('Offline hike', TrackMode.offline);
    expect(gps.watching, isTrue, reason: 'GPS runs while recording');
    await walk(3);
    await rec(c).stop();
    expect(gps.watching, isFalse, reason: 'and stops after');

    final saved = (await local.listTracks('u1')).single;
    expect(
      (saved.name, saved.status, saved.mode, saved.syncStatus, saved.stats.pointCount),
      ('Offline hike', TrackStatus.completed, TrackMode.offline, TrackSyncStatus.local, 3),
    );
    expect(saved.stats.distanceM, greaterThan(20));
    expect(await local.getPoints(saved.id), hasLength(3));
    expect(cloud.calls.where((x) => x.startsWith('upload')), isEmpty);
    expect(st(c).active, isNull);
  });

  test('uploads an online track when it finishes', () async {
    final c = await signedIn();
    await rec(c).start('Online hike', TrackMode.online);
    await walk(2);
    await rec(c).stop();
    expect(cloud.calls, ['upload:completed:2']);
    expect((await local.listTracks('u1')).single.syncStatus, TrackSyncStatus.synced);
  });

  test('without signal an online track waits on the phone and goes when the signal returns', () async {
    final c = await signedIn();
    online.add(false);
    await settle();
    await rec(c).start('No signal', TrackMode.online);
    await walk(2);
    await rec(c).stop();
    expect(cloud.calls, isEmpty);
    expect((await local.listTracks('u1')).single.syncStatus, TrackSyncStatus.pending);

    online.add(true);
    await settle();
    expect(cloud.calls, ['upload:completed:2']);
    expect((await local.listTracks('u1')).single.syncStatus, TrackSyncStatus.synced);
  });

  test('a failed upload is marked and the points stay on the phone', () async {
    final c = await signedIn();
    cloud.uploadError = const TrackCloudException('network down');
    await rec(c).start('Flaky', TrackMode.online);
    await walk(2);
    await rec(c).stop();
    final saved = (await local.listTracks('u1')).single;
    expect((saved.syncStatus, saved.syncError), (TrackSyncStatus.error, 'network down'));
    expect(await local.getPoints(saved.id), hasLength(2));
  });

  test('resume starts a new segment, so the pause is not counted', () async {
    final c = await signedIn();
    await rec(c).start('Paused', TrackMode.offline);
    await walk(2);
    final before = st(c).active!.stats.distanceM;
    await rec(c).pause();
    expect(gps.watching, isFalse, reason: 'no GPS while paused (battery)');

    clock += 600000;
    await rec(c).resume();
    await walk(2);
    expect(st(c).activePoints.map((p) => p.segment), [0, 0, 1, 1]);
    expect(st(c).active!.stats.distanceM, closeTo(before * 2, 0.5));
    // Paused time does not count
    expect(st(c).active!.elapsedAt(clock), 2 * 5000 + 2 * 5000);
  });

  test('a recording interrupted by the app closing comes back paused', () async {
    final c = await signedIn();
    await rec(c).start('Interrupted', TrackMode.offline);
    await walk(3);
    final id = st(c).active!.id;
    c.dispose(); // the app is killed while recording

    final again = await signedIn();
    final recovered = st(again).active!;
    expect((recovered.id, recovered.status, recovered.stats.pointCount), (id, TrackStatus.paused, 3));
    expect(st(again).activePoints, hasLength(3));
    expect(st(again).panelOpen, isTrue);
    expect(recovered.elapsedMs, 3 * 5000, reason: 'up to the last stored point');
    expect(gps.watching, isFalse, reason: 'waits for Resume');
  });

  test('discarding removes the recording and its points', () async {
    final c = await signedIn();
    await rec(c).start('Discard me', TrackMode.offline);
    await walk(2);
    final id = st(c).active!.id;
    await rec(c).discard();
    expect(st(c).active, isNull);
    expect(await local.getTrack(id), isNull);
    expect(await local.getPoints(id), isEmpty);
  });

  test('deleting removes the cloud copy first and keeps the track if that fails', () async {
    final c = await signedIn();
    await rec(c).start('Synced', TrackMode.online);
    await walk(2);
    await rec(c).stop();
    final id = (await local.listTracks('u1')).single.id;

    cloud.deleteError = const TrackCloudException('offline');
    await rec(c).delete(id);
    expect(await local.getTrack(id), isNotNull);
    expect(st(c).error, contains('cloud copy'));

    await rec(c).delete(id);
    expect(cloud.calls.where((x) => x.startsWith('delete')), hasLength(2));
    expect(await local.getTrack(id), isNull);
  });

  test('cloud-only tracks are listed next to the ones on the phone', () async {
    cloud.remote = [
      const RecordedTrack(
        id: 'remote-1',
        userId: 'u1',
        name: 'From another phone',
        mode: TrackMode.online,
        status: TrackStatus.completed,
        startedAt: 1,
        syncStatus: TrackSyncStatus.remote,
        syncedAt: 2,
        updatedAt: 2,
      ),
    ];
    final c = await signedIn();
    await rec(c).start('Local', TrackMode.offline);
    await rec(c).stop();
    await rec(c).loadTracks();
    expect(
      [for (final t in st(c).tracks) (t.name, t.syncStatus)],
      [('Local', TrackSyncStatus.local), ('From another phone', TrackSyncStatus.remote)],
    );
  });

  test('GPX export of a saved track', () async {
    final c = await signedIn();
    await rec(c).start('Export me', TrackMode.offline);
    await walk(2);
    await rec(c).stop();
    final (name, gpx) = await rec(c).exportGpx(st(c).tracks.single.id);
    expect(name, 'Export_me.gpx');
    expect(RegExp('<trkpt ').allMatches(gpx), hasLength(2));
  });

  test('fixes with poor accuracy or jitter are not stored', () async {
    final c = await signedIn();
    await rec(c).start('Filter', TrackMode.offline);
    clock += 5000;
    gps.controller!
      ..add(GpsFix(lat: -7.6, lng: 110.45, alt: null, accuracy: 80, speed: null, timestamp: clock))
      ..add(GpsFix(lat: -7.6, lng: 110.45, alt: null, accuracy: 5, speed: null, timestamp: clock + 1000))
      ..add(GpsFix(lat: -7.60001, lng: 110.45, alt: null, accuracy: 5, speed: null, timestamp: clock + 2000));
    await settle();
    expect(st(c).active!.stats.pointCount, 1);
    expect(st(c).currentFix!.lat, -7.60001, reason: 'the position still follows every fix');
  });

  test('losing recording access pauses the recording, nothing is deleted', () async {
    final c = await signedIn();
    await rec(c).start('Plan change', TrackMode.offline);
    await walk(2);
    plan = Plan.pro; // the admin changed the plan
    c.invalidate(profileProvider);
    await settle();
    expect(st(c).active!.status, TrackStatus.paused);
    expect(st(c).active!.stats.pointCount, 2);
  });

  test('location permission taken away while recording: paused with the reason', () async {
    final c = await signedIn();
    await rec(c).start('Denied', TrackMode.offline);
    gps.controller!.addError(const GpsDeniedException());
    await settle();
    expect((st(c).active!.status, st(c).gpsStatus), (TrackStatus.paused, GpsStatus.denied));
  });

  test('online mode uploads while recording, only when something changed', () async {
    // Waits for the uploads by condition, not by a fixed time (the suite runs in parallel)
    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 100 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(done(), isTrue);
    }

    final c = await signedIn(syncEvery: const Duration(milliseconds: 40));
    await rec(c).start('Live', TrackMode.online);
    await walk(2);
    await until(() => cloud.calls.contains('upload:recording:2') && st(c).active!.syncStatus == TrackSyncStatus.synced);
    final uploads = cloud.calls.length;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(cloud.calls.length, uploads, reason: 'nothing new, nothing sent');
    await walk(1);
    await until(() => cloud.calls.contains('upload:recording:3'));
  });

  test('signing out stops recording work and clears the lists; the track stays on the phone', () async {
    final c = await signedIn();
    await rec(c).start('Keep', TrackMode.offline);
    await walk(2);
    auth.add(null);
    await settle();
    expect(st(c).active, isNull);
    expect(st(c).tracks, isEmpty);
    expect(gps.watching, isFalse);
    expect(await local.listTracks('u1'), hasLength(1));
  });

  group('sharing', () {
    SharedTrack shared() => const SharedTrack(
      track: RecordedTrack(
        id: 'shared-1',
        userId: 'someone-else',
        name: 'Friend hike',
        mode: TrackMode.online,
        status: TrackStatus.completed,
        startedAt: 1,
        syncStatus: TrackSyncStatus.remote,
        syncedAt: 2,
        updatedAt: 2,
      ),
      ownerEmail: 'friend@example.com',
      sharedAt: 3,
    );

    test('an offline track is uploaded before it is shared', () async {
      final c = await signedIn();
      await rec(c).start('To share', TrackMode.offline);
      await walk(2);
      await rec(c).stop();
      final id = st(c).tracks.single.id;
      final share = await rec(c).share(id, ' r1@example.com ');
      expect(cloud.calls, ['upload:completed:2', 'share:$id:r1@example.com']);
      expect(share.email, 'r1@example.com');
      expect((await local.getTrack(id))!.syncStatus, TrackSyncStatus.synced);
    });

    test('not shared when the upload fails', () async {
      final c = await signedIn();
      await rec(c).start('Will fail', TrackMode.offline);
      await walk(2);
      await rec(c).stop();
      cloud.uploadError = const TrackCloudException('network down');
      await expectLater(
        rec(c).share(st(c).tracks.single.id, 'r1@example.com'),
        throwsA(isA<TrackCloudException>().having((e) => e.message, 'message', contains('network down'))),
      );
      expect(cloud.calls.where((x) => x.startsWith('share')), isEmpty);
    });

    test('sharing needs a connection', () async {
      final c = await signedIn();
      await rec(c).start('Offline share', TrackMode.offline);
      await rec(c).stop();
      online.add(false);
      await settle();
      await expectLater(
        rec(c).share(st(c).tracks.single.id, 'r1@example.com'),
        throwsA(isA<TrackCloudException>().having((e) => e.message, 'message', contains('internet'))),
      );
    });

    test('shared tracks open from the cloud and stay read-only', () async {
      cloud
        ..sharedWithMe = [shared()]
        ..remotePoints = {
          'shared-1': const [
            TrackPoint(lat: -7.6, lng: 110.45, alt: 1000, accuracy: 5, speed: null, timestamp: 1, segment: 0),
          ],
        };
      final c = await signedIn();
      expect(st(c).shared.map((s) => s.ownerEmail), ['friend@example.com']);
      await rec(c).view('shared-1');
      expect(cloud.calls, ['points:shared-1']);
      expect(st(c).viewing!.track.id, 'shared-1');

      // Not the owner: rename, delete and upload do nothing
      await rec(c).rename('shared-1', 'Mine now');
      await rec(c).delete('shared-1');
      await rec(c).sync('shared-1');
      expect(cloud.calls, ['points:shared-1']);
      await expectLater(rec(c).share('shared-1', 'x@example.com'), throwsA(isA<TrackCloudException>()));
    });

    test('a recipient removes a shared track from their list', () async {
      cloud.sharedWithMe = [shared()];
      final c = await signedIn();
      await rec(c).leaveShared('shared-1');
      expect(cloud.calls, ['revoke:shared-1:u1']);
      expect(st(c).shared, isEmpty);
    });
  });
}
