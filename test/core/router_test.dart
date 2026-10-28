import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/core/config/app_config.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/core/router.dart';
import 'package:landscape360/core/theme/app_theme.dart';
import 'package:landscape360/domain/account/profile.dart';

void main() {
  Future<void> pump(WidgetTester tester, {required bool signedIn, required String start}) async {
    final router = buildRouter(isSignedIn: () => signedIn);
    router.go(start);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(
            const AppConfig(
              flavor: 'dev',
              supabaseUrl: 'https://x.supabase.co',
              supabaseAnonKey: 'sb_publishable_x',
              mapboxPublicToken: 'pk.x',
              apiBaseUrl: 'https://landscape360.jcdigital.co.id',
            ),
          ),
          authUserIdProvider.overrideWith((ref) => Stream.value(signedIn ? 'u1' : null)),
          profileProvider.overrideWith(
            (ref) async => signedIn
                ? const AccountProfile(
                    userId: 'u1',
                    email: 'budi@example.com',
                    displayName: 'Budi',
                    plan: Plan.pro,
                    role: UserRole.pengguna360,
                    isAdmin: false,
                    canUseSos: false,
                  )
                : null,
          ),
        ],
        child: MaterialApp.router(theme: buildAppTheme(), routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('signed out: account pages send you to sign in', (tester) async {
    await pump(tester, signedIn: false, start: '/account/password');
    expect(find.byKey(const Key('login-submit')), findsOneWidget);
  });

  testWidgets('signed out: the map opens without signing in', (tester) async {
    await pump(tester, signedIn: false, start: '/');
    expect(find.text('Explore without Limits'), findsOneWidget);
    expect(find.byTooltip('Sign in'), findsOneWidget);
  });

  testWidgets('signed in: the account page shows the profile, sign-in redirects there', (tester) async {
    await pump(tester, signedIn: true, start: '/login');
    expect(find.text('User Account'), findsOneWidget);
    expect(find.text('Budi'), findsOneWidget);
    expect(find.text('Pro'), findsOneWidget);
    expect(find.text('Open the admin panel on the web'), findsNothing);
  });
}
