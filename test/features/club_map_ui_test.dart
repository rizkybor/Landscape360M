import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/core/theme/app_theme.dart';
import 'package:landscape360/data/geo/elevation_sampler.dart';
import 'package:landscape360/domain/community/club_map.dart';
import 'package:landscape360/domain/community/community.dart';
import 'package:landscape360/domain/geo/spherical.dart';
import 'package:landscape360/features/community/club_map_layer.dart';
import 'package:landscape360/features/community/club_map_state.dart';
import 'package:landscape360/features/community/club_map_ui.dart';
import 'package:landscape360/features/community/community_state.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import '../data/community_repository_test.dart' show FakeCommunity;
import '../domain/club_map_test.dart' show annotationRow;

// The Map tab of a club, the bar while drawing, a drawing's page (measurements, elevation
// profile, comments, delete) and the label / note / colour form

const clubId = '11111111-2222-4333-8444-555555555555';

CommunityClub club({bool manage = false}) => CommunityClub(
  id: clubId,
  name: 'Mapala UI',
  role: manage ? ClubRole.owner : ClubRole.member,
  createdAt: DateTime.utc(2026),
  canManage: manage,
);

class FakeSampler implements ElevationSampler {
  List<LngLat>? asked;

  @override
  Future<List<double>> sample(List<LngLat> points) async {
    asked = points;
    // Climbs 1 m per sample, then 5 m down at the end
    return [for (var i = 0; i < points.length; i++) i > 0 && i == points.length - 1 ? 2000.0 + i - 5 : 2000.0 + i];
  }
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  late FakeCommunity backend;
  late FakeSampler sampler;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    sampler = FakeSampler();
    backend = FakeCommunity()
      ..answers['community_club_annotations'] = [
        annotationRow(comments: 1),
        annotationRow(
          id: 'a2',
          kind: 'pin',
          mine: false,
          geometry: {
            'type': 'Point',
            'coordinates': [106.95, -6.75],
          },
        )..['label'] = 'Camp',
      ]
      ..answers['community_club_views'] = [
        {'id': 'v1', 'name': 'Summit', 'lng': 106.98, 'lat': -6.78, 'zoom': 14, 'terrain': true, 'is_mine': true},
      ]
      ..answers['community_club_annotation_comments'] = [
        {
          'id': 'c1',
          'body': 'Dry in August',
          'author_name': 'Dodi',
          'is_mine': true,
          'created_at': '2026-11-02T00:00:00Z',
        },
      ];
  });

  Future<ProviderContainer> pump(WidgetTester tester, Widget child, {bool open = true}) async {
    final c = ProviderContainer(
      overrides: [
        authUserIdProvider.overrideWith((ref) => Stream.value('u1')),
        communityBackendProvider.overrideWithValue(backend),
        communityClockProvider.overrideWithValue(() => DateTime.utc(2026, 11, 2, 2)),
        elevationSamplerProvider.overrideWithValue(sampler),
      ],
    );
    addTearDown(c.dispose);
    c
      ..listen(authUserIdProvider, (_, _) {})
      ..listen(clubMapProvider, (_, _) {});
    await c.read(authUserIdProvider.future);
    if (open) await c.read(clubMapProvider.notifier).open(club());
    await tester.binding.setSurfaceSize(const Size(420, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(body: child),
        ),
      ),
    );
    await settle(tester);
    // The 30 s refresh stops before the test ends
    addTearDown(() => c.read(clubMapProvider.notifier).close());
    return c;
  }

  /// Ends a test: the club map closed, so no refresh timer is left
  Future<void> done(WidgetTester tester, ProviderContainer c) async {
    c.read(clubMapProvider.notifier).close();
    await tester.pumpWidget(const SizedBox.shrink());
  }

  testWidgets('the Map tab: the four kinds, the list with filters and measures, saved views', (tester) async {
    final c = await pump(tester, ClubMapTab(club: club()));
    for (final k in ['pin', 'line', 'area', 'note']) {
      expect(find.byKey(Key('club-draw-$k')), findsOneWidget);
    }
    expect(find.text('All · 2'), findsOneWidget);
    expect(find.text('Rina A. · 1.10 km'), findsOneWidget);
    expect(find.byKey(const Key('club-map-filter-area')), findsNothing, reason: 'no areas yet');
    await tester.tap(find.byKey(const Key('club-map-filter-pin')));
    await settle(tester);
    expect(find.byKey(const Key('annotation-a1')), findsNothing);
    expect(find.byKey(const Key('annotation-a2')), findsOneWidget);
    expect(find.byKey(const Key('club-view-v1')), findsOneWidget);
    expect(find.byKey(const Key('club-view-delete-v1')), findsOneWidget, reason: 'mine');
    await done(tester, c);
  });

  testWidgets('drawing a line: the bar counts points and measures, Done needs two', (tester) async {
    final c = await pump(tester, const Column(children: [ClubDrawingBar()]));
    c.read(clubDrawProvider.notifier)
      ..start(AnnotationKind.line)
      ..tap((106.9, -6.7));
    await settle(tester);
    expect(find.textContaining('Tap the map to add points · 1 (at least 2)'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('club-draw-done'))).onPressed, isNull);
    c.read(clubDrawProvider.notifier).tap((106.91, -6.7));
    await settle(tester);
    expect(find.text('Length 1.10 km'), findsOneWidget);
    await tester.tap(find.byKey(const Key('club-draw-done')));
    await settle(tester);
    expect(c.read(clubDrawDoneProvider)!.points, hasLength(2));
    await done(tester, c);
  });

  testWidgets('a drawing: length, elevation profile, comments, delete', (tester) async {
    final c = await pump(tester, const AnnotationPage(annotationId: 'a1'));
    expect(find.text('Water source'), findsOneWidget);
    expect(find.text('Flows in the rainy season'), findsOneWidget);
    expect(find.byKey(const Key('annotation-length')), findsOneWidget);
    expect(find.textContaining('Dry in August', findRichText: true), findsOneWidget);

    await tester.tap(find.byKey(const Key('annotation-elevation')));
    await settle(tester);
    expect(sampler.asked, hasLength(112), reason: 'about every 10 m');
    expect(find.byKey(const Key('annotation-profile')), findsOneWidget);
    expect(find.text('+110 m'), findsOneWidget, reason: 'climb');
    expect(find.text('−4 m'), findsOneWidget, reason: 'descent: 2110 to 2106');

    await tester.enterText(find.byKey(const Key('annotation-comment')), 'Thanks');
    await tester.pump();
    await tester.tap(find.byKey(const Key('annotation-comment-send')));
    await settle(tester);
    expect(backend.params('add_community_club_annotation_comment'), {'p_id': 'a1', 'p_body': 'Thanks'});

    await tester.ensureVisible(find.byKey(const Key('annotation-delete')));
    await tester.tap(find.byKey(const Key('annotation-delete')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('confirm-action')));
    await settle(tester);
    expect(backend.params('delete_community_club_annotation'), {'p_id': 'a1'});
    await done(tester, c);
  });

  testWidgets("someone else's pin: height here, no edit or delete", (tester) async {
    final c = await pump(tester, const AnnotationPage(annotationId: 'a2'));
    expect(find.byKey(const Key('annotation-edit')), findsNothing);
    expect(find.byKey(const Key('annotation-delete')), findsNothing);
    expect(find.text('Height here'), findsOneWidget);
    await tester.tap(find.byKey(const Key('annotation-elevation')));
    await settle(tester);
    expect(find.text('2000 m above sea level'), findsOneWidget);
    await done(tester, c);
  });

  testWidgets('the form: a label is needed, then it saves with the colour picked', (tester) async {
    backend.answers['save_community_club_annotation'] = 'a3';
    final c = await pump(
      tester,
      const AnnotationFormPage(
        draw: ClubDraw(kind: AnnotationKind.area, points: [(106.9, -6.7), (106.91, -6.7), (106.91, -6.71)]),
      ),
    );
    expect(find.textContaining('Area '), findsOneWidget);
    await tester.tap(find.byKey(const Key('annotation-save')));
    await settle(tester);
    expect(find.text('Give it a label.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('annotation-label')), 'Camp area');
    await tester.tap(find.byKey(const Key('annotation-color-#7b4bb7')));
    await tester.tap(find.byKey(const Key('annotation-save')));
    await settle(tester);
    final p = backend.params('save_community_club_annotation');
    expect((p['p_kind'], p['p_label'], p['p_color']), ('area', 'Camp area', '#7b4bb7'));
    expect(((p['p_geometry'] as Map)['coordinates'] as List).single, hasLength(4), reason: 'closed ring');
    await done(tester, c);
  });
}
