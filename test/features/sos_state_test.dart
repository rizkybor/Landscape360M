import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/data/sos/sos_backend.dart';
import 'package:landscape360/data/sos/sos_device.dart';
import 'package:landscape360/data/tracks/gps_source.dart';
import 'package:landscape360/domain/account/profile.dart';
import 'package:landscape360/domain/sos/siren.dart';
import 'package:landscape360/domain/sos/sos_outbox.dart';
import 'package:landscape360/features/sos/sos_state.dart';
import 'package:landscape360/features/tracks/track_recorder_state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'track_recorder_state_test.dart' show FakeGps;

// S.O.S: the countdown, reports to the admin (every 30 s, with each message, kept on the
// phone without signal), "I'm safe", the phone's parts and the admin's active list

class FakeSosBackend implements SosBackend {
  final reports = <SosReport>[];
  bool offline = false;
  Object? failWith;
  List<SosAlert> active = [];
  int listCalls = 0;

  @override
  Future<void> report(SosReport report) async {
    if (offline) throw Exception('SocketException: Failed host lookup');
    final e = failWith;
    if (e != null) throw e;
    reports.add(report);
  }

  @override
  Future<List<SosAlert>> alerts({required bool onlyActive}) async {
    listCalls++;
    return active;
  }

  @override
  Future<void> resolve(String id, String note) async {}

  @override
  Future<void> delete(String id) async {}
}

class FakeDevice implements SosDevice {
  final calls = <String>[];

  @override
  Future<int?> battery() async => 64;

  @override
  Future<void> keepScreenOn(bool on) async => calls.add('screen:$on');

  @override
  Future<bool> hasTorch() async => true;

  @override
  Future<void> torch(bool on) async => calls.add('torch:$on');

  @override
  Future<void> siren(bool on) async => calls.add('siren:$on');
}

AccountProfile _profile({bool admin = false}) => AccountProfile(
  userId: 'u1',
  email: 'u@x.id',
  displayName: 'U',
  plan: Plan.free,
  role: UserRole.pengguna360,
  isAdmin: admin,
  canUseSos: true,
);

void main() {
  late FakeSosBackend backend;
  late FakeDevice device;
  late FakeGps gps;
  late StreamController<bool> online;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    backend = FakeSosBackend();
    device = FakeDevice();
    gps = FakeGps();
    online = StreamController<bool>.broadcast();
    addTearDown(online.close);
  });

  Future<void> wait([int ms = 40]) => Future<void>.delayed(Duration(milliseconds: ms));

  Future<ProviderContainer> container({bool admin = false, Duration every = sosReportEvery}) async {
    final c = ProviderContainer(
      overrides: [
        sosBackendProvider.overrideWithValue(backend),
        sosDeviceProvider.overrideWithValue(device),
        gpsSourceProvider.overrideWithValue(gps),
        onlineProvider.overrideWith((ref) => online.stream),
        authUserIdProvider.overrideWith((ref) => Stream.value('u1')),
        profileProvider.overrideWith((ref) async => _profile(admin: admin)),
        sosCountdownTickProvider.overrideWithValue(const Duration(milliseconds: 10)),
        sosReportIntervalProvider.overrideWithValue(every),
      ],
    );
    addTearDown(c.dispose);
    c
      ..listen(sosProvider, (_, _) {})
      ..listen(onlineProvider, (_, _) {})
      ..listen(profileProvider, (_, _) {});
    online.add(true);
    await wait();
    return c;
  }

  SosController sos(ProviderContainer c) => c.read(sosProvider.notifier);
  SosState st(ProviderContainer c) => c.read(sosProvider);

  void fix(double lat) =>
      gps.controller!.add(GpsFix(lat: lat, lng: 106.8, alt: 812, accuracy: 7, speed: null, timestamp: 1700000000000));

  test('cancelling during the countdown sends nothing', () async {
    final c = await container();
    await sos(c).open();
    expect(st(c).phase, SosPhase.countdown);
    await sos(c).close();
    await wait(120);
    expect(backend.reports, isEmpty);
    expect(st(c).phase, SosPhase.closed);
    expect(gps.watching, isFalse);
  });

  test('after the countdown the admin gets the position and battery; the screen stays on', () async {
    final c = await container();
    await sos(c).open();
    fix(-6.2);
    await wait(150);
    expect(st(c).phase, SosPhase.active);
    expect(st(c).delivery, SosDelivery.sent);
    final r = backend.reports.single;
    expect((r.status, r.fix!.lat, r.fix!.elevation, r.battery), (SosStatus.active, -6.2, 812, 64));
    expect(device.calls, contains('screen:true'));
  });

  test('reports again on the timer and with a message, always for the same S.O.S', () async {
    final c = await container(every: const Duration(milliseconds: 60));
    await sos(c).open();
    fix(-6.2);
    await wait(150);
    fix(-6.3);
    await wait(100);
    await sos(c).sendMessage('  sprained ankle at post 3  ');
    expect(backend.reports.length, greaterThanOrEqualTo(3));
    expect(backend.reports.map((r) => r.clientId).toSet(), hasLength(1));
    expect(backend.reports.any((r) => r.fix!.lat == -6.3), isTrue);
    expect(backend.reports.last.message, 'sprained ankle at post 3');
    expect(st(c).sentMessage, 'sprained ankle at post 3');
  });

  test('without signal the report waits on the phone and goes out when the signal is back', () async {
    final c = await container();
    online.add(false);
    backend.offline = true;
    await wait();
    await sos(c).open();
    fix(-6.2);
    await wait(150);
    expect(st(c).delivery, SosDelivery.waiting);
    expect(backend.reports, isEmpty);
    expect(await c.read(sosOutboxProvider).pending(), hasLength(1));

    backend.offline = false;
    online.add(true);
    await wait(100);
    expect(backend.reports, isNotEmpty);
    expect(st(c).delivery, SosDelivery.sent);
    expect(await c.read(sosOutboxProvider).pending(), isEmpty);
  });

  test("I'm safe sends resolved, also later when there is no signal, and stops everything", () async {
    final c = await container();
    await sos(c).open();
    fix(-6.2);
    await wait(150);
    await sos(c).toggleSiren();
    backend.offline = true;
    online.add(false);
    await wait();
    await sos(c).close();
    expect(st(c).phase, SosPhase.closed);
    expect(gps.watching, isFalse);
    expect(device.calls, containsAll(['siren:true', 'siren:false', 'screen:false']));

    // The app is reopened later with signal: the outbox still has "resolved"
    backend.offline = false;
    online.add(true);
    await wait(100);
    expect(backend.reports.last.status, SosStatus.resolved);
  });

  test('a server refusal is shown, not hidden as "waiting"', () async {
    final c = await container();
    backend.failWith = const SosException('S.O.S is not enabled for this account');
    await sos(c).open();
    await wait(150);
    expect(st(c).delivery, SosDelivery.error);
    expect(st(c).deliveryError, contains('not enabled'));
  });

  test('location permission off: the screen says so, S.O.S still reports', () async {
    final denied = _DeniedGps();
    final c = ProviderContainer(
      overrides: [
        sosBackendProvider.overrideWithValue(backend),
        sosDeviceProvider.overrideWithValue(device),
        gpsSourceProvider.overrideWithValue(denied),
        onlineProvider.overrideWith((ref) => Stream.value(true)),
        authUserIdProvider.overrideWith((ref) => Stream.value('u1')),
        sosCountdownTickProvider.overrideWithValue(const Duration(milliseconds: 10)),
      ],
    );
    addTearDown(c.dispose);
    c.listen(sosProvider, (_, _) {});
    await c.read(sosProvider.notifier).open();
    await wait(150);
    expect(c.read(sosProvider).gpsError, 'Location permission is off');
    expect(backend.reports.single.fix, isNull);
  });

  test('emergency contacts are kept per account, at most 5, no duplicates', () async {
    final c = await container();
    c.listen(emergencyContactsProvider, (_, _) {});
    await c.read(emergencyContactsProvider.future);
    final contacts = c.read(emergencyContactsProvider.notifier);
    expect(await contacts.add('Ibu', '0812 3456 7890'), isNull);
    expect(await contacts.add('Ibu 2', '081234567890'), 'This number is already in the list');
    expect(await contacts.add('', '0811111111'), 'Enter a name');
    expect(await SharedPreferencesAsync().getString('l360-sos-contacts-u1'), contains('Ibu'));
  });

  test('admins see the active alerts; others never call the admin list', () async {
    backend.active = [
      SosAlert.fromRow({
        'id': 'a1',
        'user_id': 'u2',
        'email': 'ranger@x.id',
        'status': 'active',
        'lat': -6.7,
        'lng': 106.9,
        'started_at': '2026-10-29T01:00:00Z',
        'received_at': '2026-10-29T01:00:02Z',
        'updated_at': '2026-10-29T01:00:30Z',
        'point_count': 3,
      }),
    ];
    final user = await container();
    user.listen(sosAlertsProvider, (_, _) {});
    await wait();
    expect(backend.listCalls, 0);
    expect(user.read(sosAlertsProvider).active, isEmpty);

    final admin = await container(admin: true);
    admin.listen(sosAlertsProvider, (_, _) {});
    await wait();
    final a = admin.read(sosAlertsProvider).active.single;
    expect((a.shortName, a.hasLocation, a.active, a.pointCount), ('ranger', true, true, 3));
  });

  test('the siren is a real WAV: 4.5 s, mono 16-bit, rising tones', () {
    final wav = buildSirenWav();
    final b = ByteData.sublistView(wav);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    expect(b.getUint16(22, Endian.little), 1);
    expect(b.getUint32(24, Endian.little), sirenSampleRate);
    expect(b.getUint32(40, Endian.little), (sirenLoopSeconds * sirenSampleRate).round() * 2);
    // Sound during the first tone, quiet after the third (3.15 s → 4.5 s)
    int sample(double t) => b.getInt16(44 + (t * sirenSampleRate).round() * 2, Endian.little);
    expect(sample(0.3).abs(), greaterThan(10000));
    expect(sample(4.0), 0);
  });

  test('network errors count as "no signal"', () {
    expect(isNetworkError(Exception('SocketException: Failed host lookup')), isTrue);
    expect(isNetworkError(TimeoutException('x')), isTrue);
    expect(isNetworkError(const SosException('Not allowed')), isFalse);
  });
}

class _DeniedGps extends FakeGps {
  @override
  Future<GpsAccess> access() async => GpsAccess.deniedForever;
}
