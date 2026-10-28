import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/core/theme/app_theme.dart';
import 'package:landscape360/data/tracks/gps_source.dart';
import 'package:landscape360/domain/account/profile.dart';
import 'package:landscape360/domain/sos/sos_outbox.dart';
import 'package:landscape360/features/sos/sos_button.dart';
import 'package:landscape360/features/sos/sos_state.dart';
import 'package:landscape360/features/tracks/track_recorder_state.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'sos_state_test.dart' show FakeDevice, FakeSosBackend;
import 'track_recorder_state_test.dart' show FakeGps;

// The S.O.S button (hold 3 s, never a tap) and the emergency screen

void main() {
  late FakeSosBackend backend;
  late FakeGps gps;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    backend = FakeSosBackend();
    gps = FakeGps();
  });

  Future<void> pump(WidgetTester tester, {bool canUseSos = true, bool admin = false}) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(), // a fresh account each time
        overrides: [
          sosBackendProvider.overrideWithValue(backend),
          sosDeviceProvider.overrideWithValue(FakeDevice()),
          gpsSourceProvider.overrideWithValue(gps),
          onlineProvider.overrideWith((ref) => Stream.value(true)),
          authUserIdProvider.overrideWith((ref) => Stream.value('u1')),
          profileProvider.overrideWith(
            (ref) async => AccountProfile(
              userId: 'u1',
              email: 'rina@x.id',
              displayName: 'Rina',
              plan: Plan.free,
              role: UserRole.pengguna360,
              isAdmin: admin,
              canUseSos: canUseSos || admin,
            ),
          ),
        ],
        child: MaterialApp(
          theme: buildAppTheme(),
          home: const Scaffold(body: Center(child: SosButton())),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> run(WidgetTester tester, Duration d) async {
    for (var t = Duration.zero; t < d; t += const Duration(milliseconds: 100)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('only accounts allowed by the admin see the button; admins use the account page', (tester) async {
    await pump(tester, canUseSos: false);
    expect(find.byKey(const Key('sos-button')), findsNothing);
    await pump(tester, admin: true);
    expect(find.byKey(const Key('sos-button')), findsNothing);
    await pump(tester);
    expect(find.byKey(const Key('sos-button')), findsOneWidget);
  });

  testWidgets('a tap or a short hold does nothing', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('sos-button')));
    await run(tester, const Duration(seconds: 1));
    final g = await tester.startGesture(tester.getCenter(find.byKey(const Key('sos-button'))));
    await run(tester, const Duration(milliseconds: 1500));
    expect(find.textContaining('Keep holding…'), findsOneWidget);
    await g.up();
    await run(tester, const Duration(seconds: 4));
    expect(find.byKey(const Key('sos-countdown')), findsNothing);
  });

  testWidgets('hold 3 s: countdown, then the emergency screen; I am safe tells the admin', (tester) async {
    await pump(tester);
    final g = await tester.startGesture(tester.getCenter(find.byKey(const Key('sos-button'))));
    await run(tester, const Duration(milliseconds: 3200));
    await g.up();
    await tester.pump();
    expect(find.byKey(const Key('sos-countdown')), findsOneWidget);
    expect(find.text('5'), findsOneWidget);
    // Still time to cancel after 2 s, and nothing has gone to the admin yet
    await run(tester, const Duration(milliseconds: 2050));
    expect(find.text('3'), findsOneWidget);
    expect(backend.reports, isEmpty);

    gps.controller!.add(
      const GpsFix(lat: -6.7471, lng: 106.9932, alt: 2958, accuracy: 6, speed: null, timestamp: 1700000000000),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await run(tester, const Duration(milliseconds: 3300));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    expect(find.text('S.O.S ACTIVE'), findsOneWidget);
    expect(find.byKey(const Key('sos-dms')), findsOneWidget);
    expect(find.textContaining('Elev 2958 m'), findsOneWidget);
    expect(find.textContaining('UTM'), findsOneWidget);
    expect(find.text('Emergency 112'), findsOneWidget);
    expect(find.text('Basarnas 115'), findsOneWidget);
    expect(backend.reports.single.status, SosStatus.active);

    await tester.tap(find.byKey(const Key('sos-safe')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await run(tester, const Duration(milliseconds: 500));
    expect(find.text('S.O.S ACTIVE'), findsNothing);
    expect(backend.reports.last.status, SosStatus.resolved);
  });
}
