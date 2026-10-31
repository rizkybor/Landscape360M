import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/core/config/app_config.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/core/router.dart';
import 'package:landscape360/core/theme/app_theme.dart';
import 'package:landscape360/data/account/account_repository.dart';
import 'package:landscape360/data/account/biometric_login.dart';
import 'package:landscape360/data/api/api_client.dart';
import 'package:landscape360/domain/account/profile.dart';
import 'package:landscape360/features/account/biometric_state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show User;

import '../data/account_repository_test.dart' show FakeBackend, TokenSession;

// Sign in with Face ID: offered once after a password sign-in, the button on Sign in, the
// switch in User Account, and the saved login dropped when the password no longer works

class FakeGate implements BiometricGate {
  BiometricKind? kind = BiometricKind.face;
  bool passes = true;
  final reasons = <String>[];

  @override
  Future<BiometricKind?> available() async => kind;

  @override
  Future<bool> check(String reason) async {
    reasons.add(reason);
    return passes;
  }
}

class MemoryLogins implements SavedLogins {
  SavedLogin? login;

  @override
  Future<SavedLogin?> read() async => login;

  @override
  Future<void> write(SavedLogin l) async => login = l;

  @override
  Future<void> clear() async => login = null;
}

User _user(String email) => User(
  id: 'u1',
  appMetadata: const {},
  userMetadata: const {},
  aud: 'authenticated',
  email: email,
  createdAt: '2026-01-01T00:00:00Z',
);

void main() {
  late FakeGate gate;
  late MemoryLogins logins;
  late FakeBackend backend;
  late AccountRepository repo;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    gate = FakeGate();
    logins = MemoryLogins();
    backend = FakeBackend();
    repo = AccountRepository(
      backend: backend,
      api: ApiClient(baseUrl: 'https://landscape360.jcdigital.co.id', session: TokenSession()),
      prefs: SharedPreferencesAsync(),
      userAgent: 'test',
    );
  });

  List<Override> overrides() => [
    biometricGateProvider.overrideWithValue(gate),
    savedLoginsProvider.overrideWithValue(logins),
    accountRepositoryProvider.overrideWithValue(repo),
  ];

  ProviderContainer container() {
    final c = ProviderContainer(overrides: overrides());
    addTearDown(c.dispose);
    return c;
  }

  group('controller', () {
    // Face ID and its wording, as on an iPhone
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('nothing is offered on a phone without Face ID', () async {
      gate.kind = null;
      final c = container();
      await c.read(biometricProvider.notifier).refresh();
      expect(c.read(biometricProvider).available, isFalse);
      expect(await c.read(biometricProvider.notifier).shouldOffer('budi@example.com'), isFalse);
      expect(await c.read(biometricProvider.notifier).enable('budi@example.com', 'pw'), isFalse);
      expect(logins.login, isNull);
    });

    test('offered once per account', () async {
      final c = container();
      final ctrl = c.read(biometricProvider.notifier);
      expect(await ctrl.shouldOffer('Budi@Example.com'), isTrue);
      await ctrl.markOffered('Budi@Example.com');
      expect(await ctrl.shouldOffer('budi@example.com'), isFalse);
      expect(await ctrl.shouldOffer('sari@example.com'), isTrue);
    });

    test('switched on only after the face is checked', () async {
      final c = container();
      final ctrl = c.read(biometricProvider.notifier);
      await ctrl.refresh();
      gate.passes = false;
      expect(await ctrl.enable('budi@example.com', 'pw'), isFalse);
      expect(logins.login, isNull);
      gate.passes = true;
      expect(await ctrl.enable(' Budi@Example.com ', 'pw'), isTrue);
      expect(logins.login, (email: 'budi@example.com', password: 'pw'));
      expect(c.read(biometricProvider).enabled, isTrue);
      expect(c.read(biometricProvider).label, 'Face ID');
    });

    test('signs in with the saved login after the face is checked', () async {
      logins.login = (email: 'budi@example.com', password: 'pw');
      final c = container();
      final ctrl = c.read(biometricProvider.notifier);
      await ctrl.refresh();
      gate.passes = false;
      expect(await ctrl.signIn(), isFalse);
      expect(backend.calls, isEmpty);
      gate.passes = true;
      expect(await ctrl.signIn(), isTrue);
      expect(backend.calls, contains('signIn:budi@example.com'));
    });

    test('a password changed elsewhere drops the saved login', () async {
      logins.login = (email: 'budi@example.com', password: 'old');
      backend.wrongPasswordFor = 'old';
      final c = container();
      final ctrl = c.read(biometricProvider.notifier);
      await ctrl.refresh();
      await expectLater(
        ctrl.signIn(),
        throwsA(isA<AccountException>().having((e) => e.message, 'message', contains('password has changed'))),
      );
      expect(logins.login, isNull);
      expect(c.read(biometricProvider).enabled, isFalse);
    });

    test('a password changed here follows; another account is left alone', () async {
      logins.login = (email: 'budi@example.com', password: 'old');
      final c = container();
      final ctrl = c.read(biometricProvider.notifier);
      await ctrl.refresh();
      await ctrl.passwordChanged('sari@example.com', 'x');
      expect(logins.login?.password, 'old');
      await ctrl.passwordChanged('Budi@example.com', 'new');
      expect(logins.login, (email: 'budi@example.com', password: 'new'));
    });
  });

  group('screens', () {
    const config = AppConfig(
      flavor: 'dev',
      supabaseUrl: 'https://x.supabase.co',
      supabaseAnonKey: 'sb_publishable_x',
      mapboxPublicToken: '',
      apiBaseUrl: 'https://landscape360.jcdigital.co.id',
    );

    Future<void> pump(WidgetTester tester, String start, {bool signedIn = false}) async {
      // Haptics answer at once
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final router = buildRouter(isSignedIn: () => signedIn)..go(start);
      await tester.binding.setSurfaceSize(const Size(400, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...overrides(),
            appConfigProvider.overrideWithValue(config),
            if (signedIn) ...[
              authUserIdProvider.overrideWith((ref) => Stream.value('u1')),
              profileProvider.overrideWith(
                (ref) async => const AccountProfile(
                  userId: 'u1',
                  email: 'budi@example.com',
                  displayName: 'Budi',
                  plan: Plan.pro,
                  role: UserRole.pengguna360,
                  isAdmin: false,
                  canUseSos: false,
                ),
              ),
              storageUsageProvider.overrideWith((ref) async => null),
            ],
          ],
          child: MaterialApp.router(theme: buildAppTheme(), routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('Sign in shows the Face ID button only when it is on', (tester) async {
      await pump(tester, '/login');
      expect(find.byKey(const Key('login-biometric')), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('Sign in with Face ID signs in with the saved login', (tester) async {
      logins.login = (email: 'budi@example.com', password: 'pw');
      await pump(tester, '/login');
      expect(find.text('Sign in with Face ID'), findsOneWidget);
      await tester.tap(find.byKey(const Key('login-biometric')));
      // On to the map, which keeps animating: a few frames, not settle
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(gate.reasons.single, contains('budi@example.com'));
      expect(backend.calls, contains('signIn:budi@example.com'));
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('after a password sign-in Face ID is offered once', (tester) async {
      await pump(tester, '/login');
      await tester.enterText(find.byKey(const Key('login-email')), 'budi@example.com');
      await tester.enterText(find.byKey(const Key('login-password')), 'pw');
      await tester.tap(find.byKey(const Key('login-submit')));
      // The Sign in button keeps spinning behind the question
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Use Face ID to sign in?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('biometric-offer-yes')));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(logins.login, (email: 'budi@example.com', password: 'pw'));
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('User Account switch asks for the password, then turns it off again', (tester) async {
      backend
        ..user = _user('budi@example.com')
        ..wrongPasswordFor = 'bad';
      await pump(tester, '/account', signedIn: true);
      final tile = find.byKey(const Key('account-biometric'));
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('biometric-password')), 'bad');
      await tester.tap(find.byKey(const Key('biometric-password-ok')));
      await tester.pumpAndSettle();
      expect(find.text('Your password is not correct'), findsOneWidget);
      expect(logins.login, isNull);

      await tester.enterText(find.byKey(const Key('biometric-password')), 'pw');
      await tester.tap(find.byKey(const Key('biometric-password-ok')));
      await tester.pumpAndSettle();
      expect(logins.login, (email: 'budi@example.com', password: 'pw'));
      expect(find.text('On for this account'), findsOneWidget);

      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(logins.login, isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  });
}
