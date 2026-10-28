import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/core/theme/app_theme.dart';
import 'package:landscape360/domain/survey/survey_utils.dart';
import 'package:landscape360/features/navigator/navigator_panel.dart';
import 'package:landscape360/features/navigator/navigator_state.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'navigator_state_test.dart' show FakeSurveys;

void main() {
  late ProviderContainer c;

  Future<void> pump(WidgetTester tester) async {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    c = ProviderContainer(
      overrides: [
        surveyBackendProvider.overrideWithValue(FakeSurveys()),
        authUserIdProvider.overrideWith((ref) => Stream.value(null)),
        profileProvider.overrideWith((ref) async => null),
      ],
    );
    addTearDown(c.dispose);
    final nav = c.read(navigatorProvider.notifier)..open();
    Future<double> elev(double lng, double lat) async => lng == 106.75 ? 1000 : 1050;
    await nav.addPointAt(106.75, -6.235, elev);
    await nav.addPointAt(106.75, -6.234, elev);
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: NavigatorPanel(onShowSurvey: (_) {}),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('panel: sheet summary, Curve / Straight with angle snap, new sheet', (tester) async {
    await pump(tester);
    expect(find.text('2 points · 110.6 m'), findsOneWidget);
    expect(find.text('Survey 1'), findsOneWidget);
    expect(find.text('Free'), findsNothing); // angle snap only in Straight
    await tester.tap(find.byKey(const Key('mode-straight')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('angle-45')));
    await tester.pumpAndSettle();
    expect((c.read(navigatorProvider).straight, c.read(navigatorProvider).angleStep), (true, 45));
    await tester.tap(find.byKey(const Key('sheet-add')));
    await tester.pumpAndSettle();
    expect(find.text('Survey 2'), findsOneWidget);
    expect(c.read(navigatorProvider).doc.activeGroup!.name, 'Survey 2');
  });

  testWidgets('points sheet: coordinates in DD, DMS, UTM, elevation and the segment data', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('navigator-points')));
    await tester.pumpAndSettle();
    expect(find.text('Point 1'), findsOneWidget);
    expect(find.text('-6.23500, 106.75000'), findsOneWidget);
    expect(find.textContaining("6°14'6.00\" S"), findsOneWidget);
    expect(find.textContaining('48S '), findsWidgets); // UTM (formula checked against the web elsewhere)
    expect(find.text('1000.0 mdpl'), findsNWidgets(2)); // both test points sit at the same longitude
    expect(find.text('Azimuth'), findsOneWidget);
    expect(find.text('Back Azimuth'), findsOneWidget);
    expect(find.text('110.6 m'), findsWidgets);
    // Sharp corner, then remove the second point
    await tester.tap(find.byTooltip('Curve (tap for a sharp corner)').first);
    await tester.pumpAndSettle();
    expect(c.read(navigatorProvider).doc.activeGroup!.points.first.corner, PointCorner.sharp);
    await tester.tap(find.byTooltip('Remove point').last);
    await tester.pumpAndSettle();
    expect(c.read(navigatorProvider).doc.activeGroup!.points, hasLength(1));
  });

  testWidgets('surveys sheet asks to sign in when signed out; the badge says the phone keeps it', (tester) async {
    await pump(tester);
    expect(find.byKey(const Key('navigator-sync')), findsOneWidget);
    await tester.tap(find.byKey(const Key('navigator-surveys')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Sign in to save surveys to the cloud'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
    unawaited(Future<void>.value());
  });
}
