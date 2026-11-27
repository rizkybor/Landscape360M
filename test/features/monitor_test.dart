import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/core/theme/app_theme.dart';
import 'package:landscape360/data/live/monitor_backend.dart';
import 'package:landscape360/data/tracks/gps_source.dart';
import 'package:landscape360/domain/account/profile.dart';
import 'package:landscape360/domain/live/monitor.dart';
import 'package:landscape360/features/live/monitor_sheet.dart';
import 'package:landscape360/features/live/monitor_state.dart';
import 'package:landscape360/features/map/map_sheet.dart';
import 'package:landscape360/features/map/map_tools_state.dart';
import 'package:landscape360/features/tracks/track_recorder_state.dart'
    show gpsSourceProvider, onlineProvider, trackClockProvider;
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'track_recorder_state_test.dart' show FakeGps;

// Team Monitor: the member model as the web judges it (colour, initials, status, DMS), the
// GeoJSON on the map, joining the room and keeping each member's last position and trail, the
// echo of my own position, a recalled activity and its GPX, and the screens (the tool for
// monitors only, the sheet, the member card, the tracking lists)

class FakeMonitorChannel implements MonitorChannel {
  void Function(Map<String, dynamic>)? onPacket;
  void Function(MonitorConnection)? onStatus;
  int joins = 0, asks = 0, leaves = 0;
  bool failJoin = false;

  @override
  Future<void> join({
    required void Function(Map<String, dynamic> packet) onPacket,
    required void Function(MonitorConnection status) onStatus,
  }) async {
    joins++;
    if (failJoin) throw Exception('WebSocket closed');
    this.onPacket = onPacket;
    this.onStatus = onStatus;
    onStatus(MonitorConnection.connected);
  }

  @override
  Future<void> askNow() async => asks++;

  @override
  Future<void> leave() async {
    leaves++;
    onPacket = null;
  }

  void hear(Map<String, dynamic> packet) => onPacket?.call(packet);
}

class FakeMonitorRepository implements MonitorRepository {
  final sessions = <ActivitySummary>[];
  final points = <String, List<MonitorPacket>>{};
  final logList = <TrackerLog>[];
  final deleted = <String>[];
  final calls = <String>[];

  @override
  Future<List<ActivitySummary>> activities({String? userId, int limit = 20, int offset = 0}) async {
    calls.add('activities:${userId ?? 'all'}:$offset');
    return [
      for (final s in sessions.skip(offset).take(limit))
        if (userId == null || s.userId == userId) s,
    ];
  }

  @override
  Future<List<MonitorPacket>> activityPoints(ActivitySummary a) async => points[a.sessionId] ?? const [];

  @override
  Future<List<TrackerLog>> logs({String? userId, int limit = 20, int offset = 0}) async {
    calls.add('logs:${userId ?? 'all'}:$offset');
    return logList.skip(offset).take(limit).toList();
  }

  @override
  Future<List<MonitorMember>> members() async => const [(userId: 'u-budi', name: 'budi')];

  @override
  Future<void> deleteLog(String id) async => deleted.add(id);

  final profiles = <String, TrackerProfile>{};
  Object? profileError;

  @override
  Future<List<TrackerProfile>> trackerProfiles(List<String> trackerIds) async {
    calls.add('profiles:${trackerIds.join(',')}');
    if (profileError != null) throw profileError!;
    return [
      for (final id in trackerIds)
        if (profiles[id] != null) profiles[id]!,
    ];
  }
}

class _Account extends Notifier<AccountProfile?> {
  @override
  AccountProfile? build() => account(UserRole.monitor360);
  void set(AccountProfile? p) => state = p;
}

final _account = NotifierProvider<_Account, AccountProfile?>(_Account.new);

AccountProfile account(UserRole role, {Plan plan = Plan.enterprise, bool admin = false}) => AccountProfile(
  userId: '3f2a9c1e-0000-4000-8000-000000000001',
  email: 'ops.monitor@x.id',
  displayName: 'Ops',
  plan: plan,
  role: role,
  isAdmin: admin,
  canUseSos: false,
);

Map<String, dynamic> packet(
  String id, {
  double lat = -6.78,
  double lng = 106.98,
  double speed = 1.2,
  String at = '2025-10-29T01:06:40.123Z',
  int battery = 64,
}) => {
  'user_id': id,
  'lat': lat,
  'lng': lng,
  'alt': 1820,
  'speed': speed,
  'battery': battery,
  'timestamp': at,
  'status': 'active',
};

void main() {
  late FakeMonitorChannel channel;
  late FakeMonitorRepository repo;
  late FakeGps gps;
  late int now;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    channel = FakeMonitorChannel();
    repo = FakeMonitorRepository();
    gps = FakeGps();
    // 2025-10-29T01:06:50Z: ten seconds after the packets' time
    now = DateTime.utc(2025, 10, 29, 1, 6, 50).millisecondsSinceEpoch;
  });

  Future<void> wait([int ms = 20]) => Future<void>.delayed(Duration(milliseconds: ms));

  List<Override> overrides({Stream<String?>? auth}) => [
    monitorChannelProvider.overrideWithValue(channel),
    monitorRepositoryProvider.overrideWithValue(repo),
    gpsSourceProvider.overrideWithValue(gps),
    onlineProvider.overrideWith((ref) => Stream.value(true)),
    trackClockProvider.overrideWithValue(() => now),
    profileProvider.overrideWith((ref) async => ref.watch(_account)),
    authUserIdProvider.overrideWith((ref) => auth ?? Stream.value('3f2a9c1e-0000-4000-8000-000000000001')),
  ];

  Future<ProviderContainer> container() async {
    final c = ProviderContainer(overrides: overrides());
    addTearDown(c.dispose);
    c
      ..listen(monitorProvider, (_, _) {})
      ..listen(profileProvider, (_, _) {})
      ..listen(authUserIdProvider, (_, _) {});
    await wait();
    return c;
  }

  group('model', () {
    test('who may monitor: Enterprise monitor360 or the admin', () {
      expect(account(UserRole.monitor360).canMonitor, isTrue);
      expect(account(UserRole.monitor360, plan: Plan.pro).canMonitor, isFalse);
      expect(account(UserRole.pengguna360).canMonitor, isFalse);
      expect(account(UserRole.pengguna360, plan: Plan.free, admin: true).canMonitor, isTrue);
    });

    test('a packet from the room; junk is ignored', () {
      final p = MonitorPacket.fromJson(packet('RINA.HIKER'))!;
      expect((p.trackerId, p.lat, p.lng, p.alt, p.speed, p.battery), ('RINA.HIKER', -6.78, 106.98, 1820.0, 1.2, 64));
      expect(p.time, DateTime.utc(2025, 10, 29, 1, 6, 40, 123).millisecondsSinceEpoch);
      expect(MonitorPacket.fromJson({'user_id': 'X'}), isNull);
      // As the Dart Realtime client hands it over: the message around the payload
      final wrapped = MonitorPacket.fromJson({
        'type': 'broadcast',
        'event': 'location-update',
        'payload': packet('BUDI'),
      });
      expect((wrapped?.trackerId, wrapped?.lat), ('BUDI', -6.78));
      expect(MonitorPacket.fromJson({'user_id': 'X', 'lat': 91, 'lng': 0}), isNull);
    });

    test('colour, initials and DMS as on the web', () {
      expect(trackerColor('RINA.HIKER'), trackerColor('RINA.HIKER'), reason: 'the same every time');
      expect(trackerColor('RINA.HIKER'), isNot(trackerColor('BUDI')));
      expect(trackerColor('A'), matches(RegExp(r'^#[0-9a-f]{6}$')));
      expect(trackerInitials('RINA.HIKER'), 'RH');
      expect(trackerInitials('rescue-01'), 'R0');
      expect(trackerInitials('BUDI'), 'B');
      expect(toDms(-7.4547, isLat: true), '7° 27\' 16.9" S');
      expect(toDms(110.4398, isLat: false), '110° 26\' 23.3" E');
    });

    test('online, idle and offline', () {
      final t0 = DateTime.utc(2025, 10, 29, 1, 6, 40).millisecondsSinceEpoch;
      final moving = MonitorTracker(latest: MonitorPacket.fromJson(packet('A'))!, trail: const [], heardAt: t0);
      final still = MonitorTracker(
        latest: MonitorPacket.fromJson(packet('B', speed: 0.3))!,
        trail: const [],
        heardAt: t0,
      );
      expect(moving.status(t0 + 10000), MonitorStatus.online);
      expect(still.status(t0 + 10000), MonitorStatus.idle);
      expect(moving.status(t0 + 5 * 60000 + 200), MonitorStatus.offline, reason: 'nothing for 5 minutes');
    });

    test('the trail keeps the last 500 points', () {
      var t = MonitorTracker(latest: MonitorPacket.fromJson(packet('A'))!, trail: const [(106.98, -6.78)], heardAt: 0);
      for (var i = 0; i < 600; i++) {
        t = t.update(MonitorPacket.fromJson(packet('A', lat: -6.78 + i * 0.0001))!, i);
      }
      expect(t.trail.length, 500);
      expect(t.trail.last.$2, closeTo(-6.78 + 599 * 0.0001, 1e-9));
    });

    test('GeoJSON: members with status, trails, a recalled activity', () {
      final t0 = DateTime.utc(2025, 10, 29, 1, 6, 40).millisecondsSinceEpoch;
      final a = MonitorTracker(
        latest: MonitorPacket.fromJson(packet('A'))!,
        trail: const [(106.98, -6.78), (106.99, -6.78)],
        heardAt: t0,
      );
      final b = MonitorTracker(
        latest: MonitorPacket.fromJson(packet('B'))!,
        trail: const [(106.98, -6.78)],
        heardAt: t0 - 600000,
      );
      final points = monitorGeoJson([a, b], t0 + 6 * 60000, 'A')['features']! as List;
      final pa = (points[0] as Map)['properties'] as Map, pb = (points[1] as Map)['properties'] as Map;
      expect((pa['status'], pa['selected'], pa['initials']), ('offline', true, 'A'));
      expect(pa['color'], '#6b7280', reason: 'gray when offline');
      expect(pb['selected'], false);
      final trails = monitorTrailsGeoJson([a, b], 'A')['features']! as List;
      expect(trails.length, 1, reason: 'one point is no trail');
      expect(((trails[0] as Map)['properties'] as Map)['width'], 4);
      final session = sessionGeoJson([a.latest, b.latest])['features']! as List;
      expect([for (final f in session) ((f as Map)['properties'] as Map)['kind']], ['path', 'start', 'end']);
      expect(sessionGeoJson([a.latest])['features'], isEmpty);
    });

    test('activities, logs and the GPX of points', () {
      final a = ActivitySummary.fromRow({
        'session_id': 's1',
        'user_id': 'u-budi',
        'started_at': '2025-10-29T01:00:00Z',
        'ended_at': null,
        'distance_m': 4020.5,
        'point_count': 120,
      }, email: 'budi.s@x.id');
      expect((a.memberName, a.distanceM, a.pointCount, a.endedAt), ('budi.s', 4020.5, 120, null));
      expect(
        ActivitySummary.fromRow({'session_id': 's', 'user_id': 'abcdefghij', 'started_at': 'x'}).memberName,
        'abcdefgh',
      );
      final log = TrackerLog.fromRow({
        'id': 'l1',
        'user_id': 'u',
        'lat': -6.78,
        'lng': 106.98,
        'elevation': 1820,
        'speed': 1.2,
        'timestamp': '2025-10-29T01:06:40Z',
      });
      expect((log.elevation, log.speed), (1820.0, 1.2));
      final gpx = pointsGpx([MonitorPacket.fromJson(packet('A'))!], name: 'Activity <1>');
      expect(gpx, contains('<name>Activity &lt;1&gt;</name>'));
      expect(gpx, contains('<trkpt lat="-6.78" lon="106.98">'));
      expect(gpx, contains('<time>2025-10-29T01:06:40.123Z</time>'));
    });
  });

  group('monitoring', () {
    test('a member cannot start; a monitor joins the room and asks everyone to report', () async {
      final c = await container();
      c.read(_account.notifier).set(account(UserRole.pengguna360, plan: Plan.pro));
      await wait();
      expect(await c.read(monitorProvider.notifier).start(), isFalse);
      expect(channel.joins, 0);

      c.read(_account.notifier).set(account(UserRole.monitor360));
      await wait();
      expect(await c.read(monitorProvider.notifier).start(), isTrue);
      expect((c.read(monitorProvider).on, c.read(monitorProvider).connection), (true, MonitorConnection.connected));
      expect(channel.asks, 1, reason: 'heartbeat-request once in the room');
    });

    test('positions heard become members with a trail; my own echo is dropped', () async {
      final c = await container();
      await c.read(monitorProvider.notifier).start();
      channel
        ..hear(packet('RINA.HIKER'))
        ..hear(packet('RINA.HIKER', lat: -6.781))
        ..hear(packet('BUDI', speed: 0))
        ..hear(packet('OPS.MONITOR'))
        ..hear({'junk': true});
      final s = c.read(monitorProvider);
      expect(s.trackers.keys, unorderedEquals(['RINA.HIKER', 'BUDI']));
      expect(s.trackers['RINA.HIKER']!.trail.length, 2);
      expect(s.trackers['RINA.HIKER']!.latest.lat, -6.781);
      expect(s.trackers['BUDI']!.status(now), MonitorStatus.idle);
      expect(s.online(now), 2);

      c.read(monitorProvider.notifier).select('BUDI');
      expect(c.read(monitorProvider).selected!.id, 'BUDI');
      c.read(monitorProvider.notifier).select('BUDI');
      expect(c.read(monitorProvider).selected, isNull, reason: 'tapped again: closed');
    });

    test('the account behind a tracker is asked once, in one call for those heard together', () async {
      repo.profiles['RINA.HIKER'] = const TrackerProfile(
        trackerId: 'RINA.HIKER',
        userId: 'u-rina',
        name: 'Rina Wulandari',
        email: 'rina.hiker@x.id',
        organization: 'Mapala UI',
        phone: '0812 3456 7890',
        plan: 'Pro',
        role: 'pengguna360',
        avatarPath: 'u-rina/avatar-1.jpg',
      );
      final c = await container();
      await c.read(monitorProvider.notifier).start();
      channel
        ..hear(packet('RINA.HIKER'))
        ..hear(packet('BUDI'))
        ..hear(packet('RINA.HIKER', lat: -6.79));
      await wait();
      expect(repo.calls.where((x) => x.startsWith('profiles:')), ['profiles:RINA.HIKER,BUDI']);
      final s = c.read(monitorProvider);
      expect(s.profileOf('rina.hiker')!.name, 'Rina Wulandari');
      expect(s.profiles.containsKey('BUDI') && s.profiles['BUDI'] == null, isTrue, reason: 'asked, none found');
      expect(trackerLabel('RINA.HIKER', s.profileOf('RINA.HIKER')), 'Rina Wulandari');
      expect(trackerLabel('BUDI', s.profileOf('BUDI')), 'BUDI');
      final f =
          (monitorGeoJson(s.trackers.values, now, null, profiles: s.profiles, photos: {'RINA.HIKER'})['features']!
              as List);
      final rina =
          (f.firstWhere((x) => ((x as Map)['properties'] as Map)['id'] == 'RINA.HIKER') as Map)['properties'] as Map;
      expect((rina['initials'], rina['label'], rina['photo']), ('RW', 'Rina Wulandari', true));
      channel.hear(packet('BUDI', lat: -6.79));
      await wait();
      expect(repo.calls.where((x) => x.startsWith('profiles:')), hasLength(1), reason: 'never asked twice');
    });

    test('WhatsApp links and the profile row', () {
      expect(whatsappUrl('0812-3456-7890'), 'https://wa.me/6281234567890');
      expect(whatsappUrl('+62 812 3456 7890'), 'https://wa.me/6281234567890');
      expect(whatsappUrl('123'), isNull);
      final p = TrackerProfile.fromRow({
        'tracker_id': 'budi',
        'user_id': 'u',
        'name': ' ',
        'role': 'monitor360',
        'matches': 2,
        'avatar_path': 'u/avatar-1.jpg',
      });
      expect(
        (p.trackerId, p.name, p.roleLabel, p.matches, p.avatarPath),
        ('BUDI', null, 'Monitor', 2, 'u/avatar-1.jpg'),
      );
    });

    test('the same fix heard again changes nothing (no redraw for heartbeat echoes)', () async {
      final c = await container();
      await c.read(monitorProvider.notifier).start();
      channel.hear(packet('RINA.HIKER'));
      final before = c.read(monitorProvider);
      channel.hear(packet('RINA.HIKER'));
      expect(identical(c.read(monitorProvider), before), isTrue);
      expect(c.read(monitorProvider).trackers['RINA.HIKER']!.trail, hasLength(1));
      channel.hear(packet('RINA.HIKER', at: '2025-10-29T01:06:43.000Z'));
      expect(c.read(monitorProvider).trackers['RINA.HIKER']!.trail, hasLength(2));
    });

    test('stopping leaves the room and forgets the members; sign out stops it', () async {
      final c = await container();
      await c.read(monitorProvider.notifier).start();
      channel.hear(packet('RINA.HIKER'));
      await c.read(monitorProvider.notifier).stop();
      expect(c.read(monitorProvider).on, isFalse);
      expect(c.read(monitorProvider).trackers, isEmpty);
      expect(channel.leaves, 1);

      await c.read(monitorProvider.notifier).start();
      c.read(_account.notifier).set(account(UserRole.pengguna360));
      await wait();
      expect(c.read(monitorProvider).on, isFalse, reason: 'the account may no longer monitor');
    });

    test(
      'keeps the app awake in the background with a sparse location watch; back in front it asks again or rejoins',
      () async {
        final c = await container();
        await c.read(monitorProvider.notifier).start();
        await wait();
        expect(gps.watches, 1, reason: 'the location watch keeps the app running');
        expect(c.read(monitorProvider).keptAlive, isTrue);
        await c.read(monitorProvider.notifier).resumed();
        expect(channel.asks, 2, reason: 'connected: only asks again');
        channel.onStatus!(MonitorConnection.off);
        await c.read(monitorProvider.notifier).resumed();
        expect((channel.leaves, channel.joins), (1, 2), reason: 'dropped: joined again');
        expect(c.read(monitorProvider).connection, MonitorConnection.connected);
        await c.read(monitorProvider.notifier).stop();
        await wait();
        expect(gps.controller?.hasListener ?? false, isFalse);

        gps.accessResult = GpsAccess.deniedForever;
        await c.read(monitorProvider.notifier).start();
        await wait();
        expect(c.read(monitorProvider).keptAlive, isFalse, reason: 'no location: in front only');
        expect(c.read(monitorProvider).connection, MonitorConnection.connected);
      },
    );

    test('the room refusing shows an error, still on', () async {
      channel.failJoin = true;
      final c = await container();
      await c.read(monitorProvider.notifier).start();
      expect(c.read(monitorProvider).connection, MonitorConnection.error);
      expect(c.read(monitorProvider).error, contains('WebSocket'));
    });

    test('a recalled activity stays on the map while monitoring is off', () async {
      final c = await container();
      final pts = [MonitorPacket.fromJson(packet('BUDI'))!, MonitorPacket.fromJson(packet('BUDI', lat: -6.79))!];
      c.read(monitorProvider.notifier).showSession(pts);
      expect(c.read(monitorProvider).session, hasLength(2));
      c.read(monitorProvider.notifier).toggleSessionVisible();
      expect(c.read(monitorProvider).sessionVisible, isFalse);
      await c.read(monitorProvider.notifier).stop();
      expect(c.read(monitorProvider).session, hasLength(2));
      c.read(monitorProvider.notifier).closeSession();
      expect(c.read(monitorProvider).session, isNull);
    });
  });

  group('screens', () {
    Future<ProviderContainer> pump(WidgetTester tester, Widget child) async {
      final c = ProviderContainer(overrides: overrides());
      addTearDown(c.dispose);
      c
        ..listen(monitorProvider, (_, _) {})
        ..listen(flyToProvider, (_, _) {});
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: buildAppTheme(),
            home: Scaffold(body: child),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      return c;
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('Tools shows Monitor to monitor accounts only, and GPS to members', (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final c = await pump(tester, MapSheet(scrollController: ScrollController()));
      expect(find.byKey(const Key('tool-Monitor')), findsOneWidget);
      expect(find.byKey(const Key('tool-GPS')), findsNothing);
      c.read(_account.notifier).set(account(UserRole.pengguna360, plan: Plan.pro));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('tool-Monitor')), findsNothing);
      expect(find.byKey(const Key('tool-GPS')), findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets('the sheet: switch on, members listed, tapping one flies there', (tester) async {
      final c = await pump(
        tester,
        Builder(
          builder: (context) => TextButton(onPressed: () => showMonitorSheet(context), child: const Text('go')),
        ),
      );
      await tester.tap(find.text('go'));
      await settle(tester);
      await tester.tap(find.byKey(const Key('monitor-switch')));
      await settle(tester);
      expect(c.read(monitorProvider).on, isTrue);
      expect(find.textContaining('0 members'), findsOneWidget);
      channel
        ..hear(packet('RINA.HIKER'))
        ..hear(packet('BUDI', lat: -7.45, lng: 110.43));
      await settle(tester);
      expect(find.byKey(const Key('member-RINA.HIKER')), findsOneWidget);
      expect(find.textContaining('2 members · 2 online'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('member-RINA.HIKER')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('member-RINA.HIKER')));
      await settle(tester);
      expect(c.read(monitorProvider).selectedId, 'RINA.HIKER');
      expect(c.read(flyToProvider), (lng: 106.98, lat: -6.78, zoom: 15.0));
      await c.read(monitorProvider.notifier).stop();
    });

    testWidgets('the member card: DMS, elevation, speed, last update; close', (tester) async {
      final c = await pump(tester, const Column(children: [MonitorMemberCard(), MonitorPill()]));
      await c.read(monitorProvider.notifier).start();
      channel.hear(packet('RINA.HIKER', lat: -7.4547, lng: 110.4398));
      await settle(tester);
      expect(find.byKey(const Key('monitor-pill')), findsOneWidget);
      expect(find.byKey(const Key('monitor-card')), findsNothing);
      c.read(monitorProvider.notifier).select('RINA.HIKER');
      await settle(tester);
      expect(find.byKey(const Key('monitor-card')), findsOneWidget);
      expect(find.text('7° 27\' 16.9" S'), findsOneWidget);
      expect(find.text('1820'), findsOneWidget, reason: 'the packet\'s altitude until the terrain answers');
      c.read(monitorElevationProvider.notifier).set(1834.4);
      await settle(tester);
      expect(find.text('1834'), findsOneWidget);
      expect(find.text('1.2'), findsOneWidget);
      expect(find.byKey(const Key('monitor-profile')), findsNothing, reason: 'no account known');
      repo.profiles['RINA.HIKER'] = const TrackerProfile(
        trackerId: 'RINA.HIKER',
        userId: 'u-rina',
        name: 'Rina Wulandari',
        email: 'rina.hiker@x.id',
        organization: 'Mapala UI',
        phone: '0812 3456 7890',
        plan: 'Pro',
        role: 'pengguna360',
        matches: 2,
      );
      await c.read(monitorProvider.notifier).stop();
      await c.read(monitorProvider.notifier).start();
      channel.hear(packet('RINA.HIKER', lat: -7.4547, lng: 110.4398));
      await settle(tester);
      c.read(monitorProvider.notifier).select('RINA.HIKER');
      await settle(tester);
      expect(find.byKey(const Key('monitor-profile')), findsOneWidget);
      expect(find.text('Rina Wulandari'), findsOneWidget);
      expect(find.text('RINA.HIKER'), findsOneWidget, reason: 'the tracker id under the name');
      expect(find.text('Mapala UI'), findsOneWidget);
      expect(find.text('rina.hiker@x.id'), findsOneWidget);
      expect(find.byKey(const Key('monitor-whatsapp')), findsOneWidget);
      expect(find.textContaining('2 accounts use this email name'), findsOneWidget);
      await tester.tap(find.byKey(const Key('monitor-card-close')));
      await settle(tester);
      expect(find.byKey(const Key('monitor-card')), findsNothing);
      await c.read(monitorProvider.notifier).stop();
    });

    testWidgets('tracking lists: activities with a member filter, one shown on the map; logs deleted', (tester) async {
      repo.sessions.addAll([
        ActivitySummary.fromRow({
          'session_id': 's1',
          'user_id': 'u-budi',
          'started_at': '2025-10-29T01:00:00Z',
          'distance_m': 4020,
          'point_count': 2,
        }, email: 'budi@x.id'),
        ActivitySummary.fromRow({
          'session_id': 's2',
          'user_id': 'u-rina',
          'started_at': '2025-10-28T01:00:00Z',
          'ended_at': '2025-10-28T03:00:00Z',
        }, email: 'rina@x.id'),
      ]);
      repo.points['s1'] = [
        MonitorPacket.fromJson(packet('BUDI'))!,
        MonitorPacket.fromJson(packet('BUDI', lat: -6.79))!,
      ];
      repo.logList.add(
        TrackerLog.fromRow({
          'id': 'l1',
          'user_id': 'u-budi',
          'lat': -6.78,
          'lng': 106.98,
          'timestamp': '2025-10-29T01:06:40Z',
        }, email: 'budi@x.id'),
      );
      final c = await pump(
        tester,
        Builder(
          builder: (context) => TextButton(onPressed: () => showTrackingLists(context), child: const Text('go')),
        ),
      );
      await tester.tap(find.text('go'));
      await settle(tester);
      expect(find.byKey(const Key('activity-s1')), findsOneWidget);
      expect(find.byKey(const Key('activity-s2')), findsOneWidget);
      expect(find.text('LIVE'), findsOneWidget, reason: 's1 has not ended');

      await tester.tap(find.byKey(const Key('lists-filter')));
      await settle(tester);
      await tester.tap(find.text('budi').last);
      await settle(tester);
      expect(repo.calls.last, 'activities:u-budi:0');
      expect(find.byKey(const Key('activity-s2')), findsNothing);

      await tester.tap(find.byKey(const Key('activity-show-s1')));
      await settle(tester);
      expect(c.read(monitorProvider).session, hasLength(2));
      expect(c.read(flyToProvider)?.zoom, 13);

      await tester.tap(find.text('go'));
      await settle(tester);
      await tester.tap(find.text('Logs'));
      await settle(tester);
      expect(find.byKey(const Key('log-l1')), findsOneWidget);
      await tester.tap(find.byKey(const Key('log-delete-l1')));
      await settle(tester);
      await tester.tap(find.text('Delete'));
      await settle(tester);
      expect(repo.deleted, ['l1']);
      expect(find.byKey(const Key('log-l1')), findsNothing);
    });
  });
}
