// The whole app against the real server: sign in → Navigator → three points → Save → the
// survey is in the cloud with its points → clean up and sign out. Needs a test account
// (never commit it); without one the test is skipped:
//   flutter test integration_test/survey_flow_test.dart -d <device> \
//     --dart-define-from-file=config/dev.json \
//     --dart-define=L360_TEST_EMAIL=... --dart-define=L360_TEST_PASSWORD=...
// The account must have room for one more survey on its plan.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:landscape360/core/config/app_config.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/data/supabase/secure_session_storage.dart';
import 'package:landscape360/features/navigator/navigator_state.dart';
import 'package:landscape360/main.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' show MapboxOptions;
import 'package:supabase_flutter/supabase_flutter.dart';

const _email = String.fromEnvironment('L360_TEST_EMAIL');
const _password = String.fromEnvironment('L360_TEST_PASSWORD');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final config = AppConfig.fromEnvironment();

  Future<void> wait(WidgetTester tester, [int ms = 600]) async {
    for (var i = 0; i < ms ~/ 50; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> until(WidgetTester tester, bool Function() done, {int seconds = 20, required String what}) async {
    for (var i = 0; i < seconds * 10; i++) {
      if (done()) return;
      await tester.pump(const Duration(milliseconds: 100));
    }
    fail('Timed out waiting for $what');
  }

  testWidgets('sign in, make a survey, save it to the cloud', skip: _email.isEmpty || _password.isEmpty, (
    tester,
  ) async {
    MapboxOptions.setAccessToken(config.mapboxPublicToken);
    await Supabase.initialize(
      url: config.supabaseUrl,
      publishableKey: config.supabaseAnonKey,
      authOptions: FlutterAuthClientOptions(localStorage: SecureSessionStorage(), detectSessionInUri: false),
    );
    final auth = Supabase.instance.client.auth;
    if (auth.currentSession != null) await auth.signOut();

    await tester.pumpWidget(
      ProviderScope(overrides: [appConfigProvider.overrideWithValue(config)], child: const Landscape360App()),
    );
    await wait(tester, 4000);
    final container = ProviderScope.containerOf(tester.element(find.byType(Landscape360App)));

    // Sign in through the screens
    await tester.tap(find.byKey(const Key('account-button')));
    await wait(tester, 1000);
    await tester.enterText(find.byKey(const Key('login-email')), _email);
    await tester.enterText(find.byKey(const Key('login-password')), _password);
    await tester.tap(find.byKey(const Key('login-submit')));
    await until(tester, () => auth.currentSession != null, what: 'sign in');
    await until(tester, () => container.read(profileProvider).value != null, what: 'the profile');
    await wait(tester, 2000);

    // Navigator from Tools, a new survey with three points
    await tester.tap(find.byKey(const Key('tool-Navigator')));
    await wait(tester, 800);
    final nav = container.read(navigatorProvider.notifier)..newSurvey();
    Future<double> flat(double lng, double lat) async => 1200;
    await nav.addPointAt(106.9800, -6.7800, flat);
    await nav.addPointAt(106.9810, -6.7810, flat);
    await nav.addPointAt(106.9820, -6.7805, flat);
    await wait(tester, 800);

    // Save from the surveys sheet
    await tester.tap(find.byKey(const Key('navigator-surveys')));
    await wait(tester, 1000);
    await tester.tap(find.byKey(const Key('survey-save')));
    await until(
      tester,
      () => container.read(navigatorProvider).currentSurveyId != null && !container.read(navigatorProvider).dirty,
      what: 'the save',
    );
    final id = container.read(navigatorProvider).currentSurveyId!;
    expect(container.read(navigatorProvider).error, isNull);

    // In the cloud, with the same points
    final (_, groups) = await container.read(surveyBackendProvider).load(id);
    expect(groups.expand((g) => g.points).map((p) => (p.lng, p.lat)), [
      (106.9800, -6.7800),
      (106.9810, -6.7810),
      (106.9820, -6.7805),
    ]);

    // Clean up: the test survey is deleted, then sign out
    await nav.deleteSurvey(id);
    final left = await container.read(surveyBackendProvider).list(auth.currentUser!.id);
    expect(left.map((s) => s.id), isNot(contains(id)));
    await auth.signOut();
    await wait(tester, 1000);
  });
}
