import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/core/config/app_config.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/core/theme/app_theme.dart';
import 'package:landscape360/domain/account/profile.dart';
import 'package:landscape360/domain/community/community.dart' show PostKind;
import 'package:landscape360/domain/community/community_attachments.dart';
import 'package:landscape360/domain/tracks/share_card.dart';
import 'package:landscape360/features/community/community_compose.dart';
import 'package:landscape360/features/community/community_state.dart';
import 'package:landscape360/features/tracks/share_card.dart';
import 'package:landscape360/features/tracks/share_card_page.dart';
import 'package:landscape360/features/tracks/track_recorder_state.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import '../data/community_repository_test.dart' show FakeCommunity;
import '../domain/share_card_test.dart' show climb, track;
import 'track_recorder_panel_test.dart' show MemoryTrackStore;
import 'track_recorder_state_test.dart' show FakeGps, FakeTrackCloud;

// "Share as image": the cards side by side, the numbers to show, the picture saved at 1080 × 1920,
// and Post to Community (a Story with the card and the route, cut when the ends are hidden)

void main() {
  late MemoryTrackStore local;
  late List<(Uint8List, String)> shared;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    local = MemoryTrackStore();
    final t = track(maxAlt: 3142);
    local.tracks[t.id] = t;
    local.points[t.id] = {for (final (i, p) in climb(20).indexed) i: p};
    shared = [];
  });

  Future<ProviderContainer> pump(WidgetTester tester) async {
    final c = ProviderContainer(
      overrides: [
        appConfigProvider.overrideWithValue(
          const AppConfig(
            flavor: 'dev',
            supabaseUrl: 'https://x.supabase.co',
            supabaseAnonKey: 'sb_publishable_x',
            mapboxPublicToken: '',
            apiBaseUrl: 'https://landscape360.jcdigital.co.id',
          ),
        ),
        trackLocalStoreProvider.overrideWithValue(local),
        trackCloudProvider.overrideWithValue(FakeTrackCloud()),
        gpsSourceProvider.overrideWithValue(FakeGps()),
        onlineProvider.overrideWith((ref) => Stream.value(true)),
        authUserIdProvider.overrideWith((ref) => Stream.value('u1')),
        profileProvider.overrideWith(
          (ref) async => const AccountProfile(
            userId: 'u1',
            email: 'u@x.id',
            displayName: 'U',
            plan: Plan.pro,
            role: UserRole.pengguna360,
            isAdmin: false,
            canUseSos: false,
          ),
        ),
        communityBackendProvider.overrideWithValue(FakeCommunity()),
        // No map in tests: the Map card has its plain background
        trackMapShotProvider.overrideWithValue((_, _) async => null),
        cardShareProvider.overrideWithValue((png, name) async => shared.add((png, name))),
      ],
    );
    addTearDown(c.dispose);
    c
      ..listen(trackRecorderProvider, (_, _) {})
      ..listen(authUserIdProvider, (_, _) {})
      ..listen(profileProvider, (_, _) {});
    await c.read(authUserIdProvider.future);
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: const ShareCardPage(trackId: 't1'),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    await tester.pump();
    return c;
  }

  /// Rendering a picture needs the engine (real time) between frames
  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 60 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  testWidgets('the Map card: title, date and the four numbers; then Share saves 1080 × 1920', (tester) async {
    await pump(tester);
    expect(find.text('Merbabu via Selo'), findsWidgets);
    expect(find.text('Mon, 19 Oct 2026'), findsWidgets);
    expect(find.text('3,142 mdpl'), findsWidgets);
    for (final t in ShareCardTemplate.values) {
      expect(find.byKey(Key('share-template-${t.name}')), findsOneWidget);
    }

    await tester.tap(find.byKey(const Key('share-send')));
    await until(tester, () => shared.isNotEmpty);
    final (png, name) = shared.single;
    expect(name, 'Merbabu_via_Selo_map.png');
    final image = await tester.runAsync(() async => (await (await ui.instantiateImageCodec(png)).getNextFrame()).image);
    expect((image!.width, image.height), (1080, 1920));
  });

  testWidgets('a number switched off leaves the card', (tester) async {
    await pump(tester);
    expect(find.text('ELEV. GAIN'), findsWidgets);
    await tester.ensureVisible(find.byKey(const Key('share-stat-gain')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('share-stat-gain')), warnIfMissed: true);
    await tester.pump();
    expect(find.text('ELEV. GAIN'), findsNothing);
    await tester.pump(const Duration(seconds: 1)); // the chip's animation
  });

  testWidgets('Post to Community: a Story with the card and the route, cut when the ends are hidden', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('share-hide-ends')));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('share-post')));
    await tester.tap(find.byKey(const Key('share-post')));
    await until(tester, () => find.byType(CommunityComposePage).evaluate().isNotEmpty);
    final page = tester.widget<CommunityComposePage>(find.byType(CommunityComposePage));
    final d = page.draft!;
    expect((d.kind, d.title, d.happenedOn), (PostKind.story, 'Merbabu via Selo', '2026-10-19'));
    expect(d.photos, hasLength(1));
    final a = d.attachment! as TrackAttachment;
    expect(a.line, hasLength(trimEnds(climb(20)).length), reason: 'the first and last 200 m left out');
    expect(d.lat, closeTo(-7.5 + 0.017, 1e-9), reason: 'placed at the highest point shown');
  });
}
