import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/core/config/app_config.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/core/router.dart';
import 'package:landscape360/core/theme/app_theme.dart';
import 'package:landscape360/domain/account/profile.dart';
import 'package:landscape360/features/live/live_tracking_sheet.dart';
import 'package:landscape360/features/map/map_sheet.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

// Every main screen fits a small phone (iPhone SE 1st gen, 320 pt wide), a common one, a
// large one and an iPad, with large text too: a layout that overflows fails the test.

const _sizes = {
  'iPhone SE (1st)': Size(320, 568),
  'iPhone SE (3rd)': Size(375, 667),
  'iPhone Pro Max': Size(430, 932),
  'iPad 11"': Size(834, 1194),
  'iPad landscape': Size(1194, 834),
};

const _profile = AccountProfile(
  userId: 'u1',
  email: 'budi.santoso.lengkap@organisasi-pecinta-alam.or.id',
  displayName: 'Budi Santoso Wicaksono',
  plan: Plan.enterprise,
  role: UserRole.pengguna360,
  isAdmin: false,
  canUseSos: true,
  organization: 'Organisasi Pecinta Alam Universitas',
  phone: '0812 3456 7890',
);

/// No layout error; on failure the message names the widget that overflowed
void expectFits(WidgetTester tester, {required String reason}) {
  final e = tester.takeException();
  expect(e, isNull, reason: e is FlutterError ? '$reason\n${e.toStringDeep()}' : reason);
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    PackageInfo.setMockInitialValues(
      appName: 'Landscape 360',
      packageName: 'id.co.jcdigital.landscape360',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  Future<void> pump(WidgetTester tester, Size size, Widget Function() app, {double textScale = 1}) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(size: size, textScaler: TextScaler.linear(textScale)),
        child: app(),
      ),
    );
    await tester.pumpAndSettle();
  }

  List<Override> overrides({required bool signedIn}) => [
    appConfigProvider.overrideWithValue(
      const AppConfig(
        flavor: 'dev',
        supabaseUrl: 'https://x.supabase.co',
        supabaseAnonKey: 'sb_publishable_x',
        mapboxPublicToken: '',
        apiBaseUrl: 'https://landscape360.jcdigital.co.id',
      ),
    ),
    authUserIdProvider.overrideWith((ref) => Stream.value(signedIn ? 'u1' : null)),
    profileProvider.overrideWith((ref) async => signedIn ? _profile : null),
    storageUsageProvider.overrideWith((ref) async => null),
  ];

  Widget routed(String start, {required bool signedIn}) => ProviderScope(
    overrides: overrides(signedIn: signedIn),
    child: MaterialApp.router(
      theme: buildAppTheme(),
      routerConfig: buildRouter(isSignedIn: () => signedIn)..go(start),
    ),
  );

  for (final MapEntry(key: name, value: size) in _sizes.entries) {
    for (final scale in [1.0, 1.3]) {
      final label = '$name, text ×$scale';

      testWidgets('$label: sign in, request account, about', (tester) async {
        for (final page in ['/login', '/request-account', '/about']) {
          await pump(tester, size, () => routed(page, signedIn: false), textScale: scale);
          expectFits(tester, reason: page);
        }
      });

      testWidgets('$label: account, edit, password, delete', (tester) async {
        for (final page in ['/account', '/account/edit', '/account/password', '/account/delete']) {
          await pump(tester, size, () => routed(page, signedIn: true), textScale: scale);
          expectFits(tester, reason: page);
        }
      });

      testWidgets('$label: map sheet sections and the GPS sheet', (tester) async {
        await pump(
          tester,
          size,
          () => ProviderScope(
            overrides: overrides(signedIn: true),
            child: MaterialApp(
              theme: buildAppTheme(),
              home: Scaffold(body: MapSheet(scrollController: ScrollController())),
            ),
          ),
          textScale: scale,
        );
        for (final section in ['map', 'terrain', 'tools']) {
          await tester.tap(find.byKey(Key('section-$section')));
          await tester.pumpAndSettle();
          expectFits(tester, reason: section);
        }
        // Not awaited: it completes when the sheet closes
        unawaited(showLiveTrackingSheet(tester.element(find.byType(MapSheet))));
        await tester.pumpAndSettle();
        expectFits(tester, reason: 'GPS sheet');
      });
    }
  }
}
