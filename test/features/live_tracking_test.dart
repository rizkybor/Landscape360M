import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/core/theme/app_theme.dart';
import 'package:landscape360/data/live/live_channel.dart';
import 'package:landscape360/data/tracks/gps_source.dart';
import 'package:landscape360/domain/account/profile.dart';
import 'package:landscape360/domain/live/live_packet.dart';
import 'package:landscape360/features/live/live_tracking_sheet.dart';
import 'package:landscape360/features/live/live_tracking_state.dart';
import 'package:landscape360/features/map/map_sheet.dart';
import 'package:landscape360/features/sos/sos_state.dart';
import 'package:landscape360/features/tracks/track_recorder_state.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'sos_state_test.dart' show FakeDevice;
import 'track_recorder_state_test.dart' show FakeGps;

// GPS Tracking: who may share, the packet the web's Team Monitor reads, one position every
// 3 s, at once when a monitor asks or the signal is back, the server refusing, and stopping
// by itself when the account may no longer share

class FakeLiveChannel implements LiveChannel {
  final sent = <Map<String, dynamic>>[];
  void Function()? ask;
  bool offline = false;
  bool refuse = false;
  int closes = 0;

  @override
  void listen(void Function() onAsk) => ask = onAsk;

  @override
  Future<void> send(Map<String, dynamic> packet) async {
    if (offline) throw Exception('SocketException: Failed host lookup');
    if (refuse) throw const LiveNotAllowedException('Unauthorized');
    sent.add(packet);
  }

  @override
  Future<void> close() async {
    closes++;
    ask = null;
  }
}

class _Account extends Notifier<AccountProfile?> {
  @override
  AccountProfile? build() => member(Plan.pro);
  void set(AccountProfile? p) => state = p;
}

final _account = NotifierProvider<_Account, AccountProfile?>(_Account.new);

AccountProfile member(Plan plan, {UserRole role = UserRole.pengguna360, bool admin = false}) => AccountProfile(
  userId: '3f2a9c1e-0000-4000-8000-000000000001',
  email: 'rina.hiker@x.id',
  displayName: 'Rina',
  plan: plan,
  role: role,
  isAdmin: admin,
  canUseSos: false,
);

GpsFix fix(double lat, {int t = 1761700000000, double? alt = 1820.5, double? speed = 1.2}) =>
    GpsFix(lat: lat, lng: 106.98, alt: alt, accuracy: 5, speed: speed, timestamp: t);

void main() {
  late FakeLiveChannel channel;
  late FakeGps gps;
  late StreamController<bool> online;
  var now = 0;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    channel = FakeLiveChannel();
    gps = FakeGps();
    online = StreamController<bool>.broadcast();
    addTearDown(online.close);
    now = 1000000;
  });

  Future<void> wait([int ms = 20]) => Future<void>.delayed(Duration(milliseconds: ms));

  Future<ProviderContainer> container() async {
    final c = ProviderContainer(
      overrides: [
        liveChannelProvider.overrideWithValue(channel),
        gpsSourceProvider.overrideWithValue(gps),
        sosDeviceProvider.overrideWithValue(FakeDevice()),
        onlineProvider.overrideWith((ref) => online.stream),
        trackClockProvider.overrideWithValue(() => now),
        profileProvider.overrideWith((ref) async => ref.watch(_account)),
      ],
    );
    addTearDown(c.dispose);
    c
      ..listen(liveTrackingProvider, (_, _) {})
      ..listen(onlineProvider, (_, _) {})
      ..listen(profileProvider, (_, _) {});
    online.add(true);
    await wait();
    return c;
  }

  group('who may share', () {
    test('members on Pro and Enterprise; not Free, monitors or admins', () {
      expect(
        [
          member(Plan.free),
          member(Plan.pro),
          member(Plan.enterprise),
          member(Plan.enterprise, role: UserRole.monitor360),
          member(Plan.enterprise, admin: true),
        ].map((p) => p.canBroadcast),
        [false, true, true, false, false],
      );
      expect(member(Plan.enterprise, role: UserRole.monitor360).isMember, isFalse);
    });

    test('a Free account cannot start', () async {
      final c = await container();
      c.read(_account.notifier).set(member(Plan.free));
      await wait();
      expect(await c.read(liveTrackingProvider.notifier).start(), isFalse);
      expect(gps.watches, 0);
    });
  });

  test('the packet the web monitor reads (TrackerPacket)', () {
    expect(liveTrackerId(email: 'rina.hiker@x.id', userId: 'abc'), 'RINA.HIKER');
    expect(liveTrackerId(email: '', userId: '3f2a9c1e-0000'), '3F2A9C1E');
    expect(const LivePacket(trackerId: 'RINA', lat: -6.78, lng: 106.98, battery: 64, time: 1761700000123).toJson(), {
      'user_id': 'RINA',
      'lat': -6.78,
      'lng': 106.98,
      'alt': 0,
      'speed': 0,
      'battery': 64,
      'timestamp': '2025-10-29T01:06:40.123Z',
      'status': 'active',
    });
  });

  test('one position every 3 s; a monitor asking gets one at once', () async {
    final c = await container();
    expect(await c.read(liveTrackingProvider.notifier).start(), isTrue);
    expect(c.read(liveTrackingProvider).status, LiveStatus.starting);

    gps.controller!.add(fix(-6.78));
    await wait();
    expect(channel.sent, hasLength(1));
    expect(channel.sent.single, containsPair('user_id', 'RINA.HIKER'));
    expect(channel.sent.single, containsPair('battery', 64));
    expect(channel.sent.single, containsPair('alt', 1820.5));
    expect(c.read(liveTrackingProvider).status, LiveStatus.live);

    now += 1500;
    gps.controller!.add(fix(-6.781));
    await wait();
    expect(channel.sent, hasLength(1), reason: 'less than 3 s');

    channel.ask!();
    await wait();
    expect(channel.sent, hasLength(2));
    expect(channel.sent.last['lat'], -6.781, reason: 'the latest position');

    now += 3001;
    gps.controller!.add(fix(-6.782));
    await wait();
    expect(channel.sent, hasLength(3));
  });

  test('no signal: waits, and sends again when the signal is back', () async {
    final c = await container();
    await c.read(liveTrackingProvider.notifier).start();
    channel.offline = true;
    gps.controller!.add(fix(-6.78));
    await wait();
    expect(c.read(liveTrackingProvider).status, LiveStatus.waiting);
    expect(c.read(liveTrackingProvider).error, isNull);

    channel.offline = false;
    online.add(false);
    await wait();
    online.add(true);
    await wait();
    expect(channel.sent, hasLength(1));
    expect(c.read(liveTrackingProvider).status, LiveStatus.live);
  });

  test('the server refuses: says so and waits 30 s before trying again', () async {
    final c = await container();
    await c.read(liveTrackingProvider.notifier).start();
    channel.refuse = true;
    gps.controller!.add(fix(-6.78));
    await wait();
    expect(c.read(liveTrackingProvider).status, LiveStatus.refused);
    expect(c.read(liveTrackingProvider).error, contains('not be set up on the server'));

    channel.refuse = false;
    now += 10000;
    gps.controller!.add(fix(-6.781));
    await wait();
    expect(channel.sent, isEmpty);
    now += 21000;
    gps.controller!.add(fix(-6.782));
    await wait();
    expect(channel.sent, hasLength(1));
  });

  test('stops by itself when the plan drops to Free or the account signs out', () async {
    final c = await container();
    await c.read(liveTrackingProvider.notifier).start();
    c.read(_account.notifier).set(member(Plan.free));
    await wait();
    expect(c.read(liveTrackingProvider).on, isFalse);
    expect(gps.watching, isFalse);
    expect(channel.closes, 1);

    c.read(_account.notifier).set(member(Plan.enterprise));
    await wait();
    await c.read(liveTrackingProvider.notifier).start();
    c.read(_account.notifier).set(null);
    await wait();
    expect(c.read(liveTrackingProvider).on, isFalse);
  });

  group('screens', () {
    Future<ProviderContainer> pump(WidgetTester tester, Widget child) async {
      final c = ProviderContainer(
        overrides: [
          liveChannelProvider.overrideWithValue(channel),
          gpsSourceProvider.overrideWithValue(gps),
          sosDeviceProvider.overrideWithValue(FakeDevice()),
          onlineProvider.overrideWith((ref) => Stream.value(true)),
          profileProvider.overrideWith((ref) async => ref.watch(_account)),
          authUserIdProvider.overrideWith((ref) => Stream.value(null)),
        ],
      );
      addTearDown(c.dispose);
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

    testWidgets('Tools shows GPS to members only', (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final c = await pump(tester, MapSheet(scrollController: ScrollController()));
      expect(find.byKey(const Key('tool-GPS')), findsOneWidget);
      c.read(_account.notifier).set(member(Plan.enterprise, role: UserRole.monitor360));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('tool-GPS')), findsNothing, reason: 'monitors watch on the web');
      await tester.pumpAndSettle();
    });

    testWidgets('the sheet starts and stops; Free sees the lock', (tester) async {
      final c = await pump(
        tester,
        Builder(
          builder: (context) => TextButton(onPressed: () => showLiveTrackingSheet(context), child: const Text('go')),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('live-start')));
      await tester.pump();
      await tester.pump();
      expect(c.read(liveTrackingProvider).on, isTrue);
      expect(find.byKey(const Key('live-stop')), findsOneWidget);
      await tester.tap(find.byKey(const Key('live-stop')));
      await tester.pump();
      expect(c.read(liveTrackingProvider).on, isFalse);

      c.read(_account.notifier).set(member(Plan.free));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('live-locked')), findsOneWidget);
      expect(find.byKey(const Key('live-start')), findsNothing);
    });
  });
}
