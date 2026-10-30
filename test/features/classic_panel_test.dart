import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/core/theme/app_theme.dart';
import 'package:landscape360/domain/account/profile.dart';
import 'package:landscape360/domain/classic/field_work.dart';
import 'package:landscape360/features/classic/classic_panel.dart';
import 'package:landscape360/features/classic/classic_state.dart';
import 'package:landscape360/features/classic/compass_dial.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'classic_state_test.dart' show FakeClassicLinks;

// The Classic panel: typing a position in degrees, minutes and seconds, the azimuth with its
// compass, Check, the back azimuth and its hints, X with its likely circle, Field Works and
// sharing, and a shared Field Work read only

AccountProfile _profile(Plan plan) => AccountProfile(
  userId: 'u1',
  email: 'u@x.id',
  displayName: 'U',
  plan: plan,
  role: UserRole.pengguna360,
  isAdmin: false,
  canUseSos: false,
);

void main() {
  late FakeClassicLinks links;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    links = FakeClassicLinks();
  });

  Future<ProviderContainer> pump(WidgetTester tester, {Plan? plan}) async {
    final c = ProviderContainer(
      overrides: [
        classicLinksProvider.overrideWithValue(links),
        classicShareDelayProvider.overrideWithValue(const Duration(milliseconds: 20)),
        authUserIdProvider.overrideWith((ref) => Stream.value(plan == null ? null : 'u1')),
        profileProvider.overrideWith((ref) async => plan == null ? null : _profile(plan)),
      ],
    );
    addTearDown(c.dispose);
    await tester.binding.setSurfaceSize(const Size(400, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: const Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(padding: EdgeInsets.all(8), child: ClassicPanel()),
            ),
          ),
        ),
      ),
    );
    c.read(classicProvider.notifier).setPanelOpen(true);
    await tester.pumpAndSettle();
    return c;
  }

  Future<void> type(WidgetTester tester, String key, String text) async {
    await tester.ensureVisible(find.byKey(Key(key)));
    await tester.enterText(find.byKey(Key(key)), text);
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(Key(key)));
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
  }

  testWidgets('intersection: positions, azimuths, back azimuths with hints, then X', (tester) async {
    final c = await pump(tester);
    await tap(tester, 'classic-mode-intersection');

    // Position A: 7° 27' 36" S, 110° 25' 48" E
    await type(tester, 'classic-point-0-lat-d', '7');
    await type(tester, 'classic-point-0-lat-m', '27');
    await type(tester, 'classic-point-0-lat-s', '36');
    await type(tester, 'classic-point-0-lng-d', '110');
    await type(tester, 'classic-point-0-lng-m', '25');
    await type(tester, 'classic-point-0-lng-s', '48');
    expect(c.read(classicProvider).solution.sightings.first.point, isNotNull);

    // A typo is explained
    await type(tester, 'classic-az-0', '400');
    expect(find.textContaining('A compass goes from 0° to 360°'), findsOneWidget);
    await type(tester, 'classic-az-0', '45');
    expect(tester.widget<CompassDial>(find.byKey(const Key('classic-az-dial-0'))).value, 45);
    await tap(tester, 'classic-az-check-0');

    // The azimuth itself as the back azimuth, then a wrong one twice: the answer shows
    await type(tester, 'classic-back-0', '45');
    await tap(tester, 'classic-back-check-0');
    expect(find.textContaining('That is the azimuth itself'), findsOneWidget);
    await type(tester, 'classic-back-0', '200');
    await tap(tester, 'classic-back-check-0');
    expect(find.textContaining('45° is less than 180°, so add 180°.'), findsOneWidget);
    expect(find.byKey(const Key('classic-answer-0')), findsOneWidget);
    await type(tester, 'classic-back-0', '225');
    expect(c.read(classicProvider).solution.sightings.first.complete, isTrue);

    // Position B, picked on the map
    c.read(classicProvider.notifier)
      ..startPicking(1)
      ..placePicked((110.45, -7.46));
    await tester.pumpAndSettle();
    await type(tester, 'classic-az-1', '315');
    await tap(tester, 'classic-az-check-1');
    await type(tester, 'classic-back-1', '135');
    await tap(tester, 'classic-back-check-1');

    expect(find.byKey(const Key('classic-fix')), findsOneWidget);
    expect(find.textContaining('Most likely within ±'), findsOneWidget);
    expect(find.textContaining('2 lines · best cut 90°'), findsOneWidget);
  });

  testWidgets('resection: your position first, then each point opens in turn', (tester) async {
    final c = await pump(tester);
    expect(find.byKey(const Key('classic-origin')), findsOneWidget);
    final dial = find.byKey(const Key('classic-az-dial-0'));
    expect(tester.widget<CompassDial>(dial).enabled, isFalse, reason: 'needs your position');
    c.read(classicProvider.notifier)
      ..startPicking(pickOrigin)
      ..placePicked((110.4396, -7.4552));
    await tester.pumpAndSettle();
    expect(tester.widget<CompassDial>(dial).enabled, isTrue);
    expect(find.text('Add point C'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(find.byKey(const Key('classic-add-sighting'))).onPressed, isNull);
  });

  testWidgets('Field Works: one for a guest with the plan note; Pro adds, renames and deletes', (tester) async {
    await pump(tester);
    await tap(tester, 'classic-fw-new');
    expect(find.textContaining('Pro (5) and Enterprise (10)'), findsOneWidget);

    final c = await pump(tester, plan: Plan.pro);
    await tap(tester, 'classic-fw-new');
    expect(c.read(classicProvider).modeFieldWorks, hasLength(2));
    await tap(tester, 'classic-rename');
    await tester.enterText(find.byKey(const Key('classic-rename-field')), 'Latihan Gede');
    await tap(tester, 'classic-rename-save');
    expect(c.read(classicProvider).fieldWork.name, 'Latihan Gede');
    await tap(tester, 'classic-delete');
    await tap(tester, 'classic-delete-yes');
    expect(c.read(classicProvider).modeFieldWorks.single.name, 'Field Work 1');
  });

  testWidgets('sharing: a guest is asked to sign in', (tester) async {
    await pump(tester);
    await tap(tester, 'classic-share');
    expect(find.text('Sign in to share this Field Work.'), findsOneWidget);
  });

  testWidgets('sharing: signed in, Create link shows the link', (tester) async {
    await pump(tester, plan: Plan.free);
    await tap(tester, 'classic-share');
    await tap(tester, 'classic-share-create');
    expect(find.text('https://landscape360.jcdigital.co.id/?classic=${links.nextToken}'), findsOneWidget);
    expect(find.text('Saved: the link shows this version.'), findsOneWidget);
    // The link's token is remembered on the phone a moment later
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a shared Field Work is read only and closes back to my own', (tester) async {
    final c = await pump(tester);
    c
        .read(classicProvider.notifier)
        .view(
          ViewedFieldWork(
            token: 't',
            mode: ClassicMode.intersection,
            name: 'Latihan Merbabu',
            data: FieldWorkData(
              sightings: [
                Sighting(point: PointInput.of((110.43, -7.46)), azimuth: '45', back: '225', azChecks: 1, backChecks: 1),
                Sighting(
                  point: PointInput.of((110.45, -7.46)),
                  azimuth: '315',
                  back: '135',
                  azChecks: 1,
                  backChecks: 1,
                ),
              ],
            ),
            declination: '0',
            ownerName: 'Rina W.',
            updatedAt: DateTime(2026, 10, 30, 9, 41),
          ),
        );
    await tester.pumpAndSettle();
    expect(find.text('Latihan Merbabu'), findsOneWidget);
    expect(find.textContaining('shared by Rina W.'), findsOneWidget);
    expect(find.byKey(const Key('classic-reset')), findsNothing, reason: 'nothing can be changed');
    expect(find.byKey(const Key('classic-fix')), findsOneWidget);
    await tap(tester, 'classic-close-viewing');
    expect(c.read(classicProvider).viewing, isNull);
    expect(find.byKey(const Key('classic-mode-resection')), findsOneWidget);
  });

  testWidgets('minimized to one line, and picking replaces the panel with a bar', (tester) async {
    final c = await pump(tester);
    await tap(tester, 'classic-minimize');
    expect(c.read(classicProvider).minimized, isTrue);
    expect(find.byKey(const Key('classic-mode-resection')), findsNothing);
    c.read(classicProvider.notifier).startPicking(pickOrigin);
    await tester.pumpAndSettle();
    expect(find.text('Tap the map to place your position'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(c.read(classicProvider).picking, isNull);
  });
}
