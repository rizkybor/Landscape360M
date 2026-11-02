import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:landscape360/core/config/app_config.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/core/theme/app_theme.dart';
import 'package:landscape360/data/community/community_outbox.dart';
import 'package:landscape360/data/community/community_repository.dart' show CommunityException, feedCacheKey;
import 'package:landscape360/data/community/photo_compress.dart';
import 'package:landscape360/domain/account/profile.dart';
import 'package:landscape360/domain/community/community.dart';
import 'package:landscape360/domain/community/community_attachments.dart';
import 'package:landscape360/domain/share/share_location.dart';
import 'package:landscape360/domain/weather/villages.dart';
import 'package:landscape360/features/community/community_admin.dart';
import 'package:landscape360/features/community/community_club_page.dart';
import 'package:landscape360/features/community/community_clubs.dart';
import 'package:landscape360/features/community/community_compose.dart';
import 'package:landscape360/features/community/community_layer.dart';
import 'package:landscape360/features/community/community_post_page.dart';
import 'package:landscape360/features/community/community_sheet.dart';
import 'package:landscape360/features/community/community_state.dart';
import 'package:landscape360/features/community/community_widgets.dart';
import 'package:landscape360/features/map/map_sheet.dart';
import 'package:landscape360/features/map/map_tools_state.dart';
import 'package:landscape360/features/map/shared_links.dart';
import 'package:landscape360/features/tracks/track_recorder_state.dart' show onlineProvider;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import '../data/community_repository_test.dart' show FakeCommunity, MemoryFiles, clubId, postId;
import '../domain/community_test.dart' show feedRow;

// Community screens: the feed for guests and members, filters and paging, reading offline,
// a post (Helpful, comments, reporting, club badge without a public link), writing a report
// (validation, place name, near-me warning, audience, offline outbox), clubs, the admin queue,
// the map layer's data and the link to a post.

AccountProfile profile(Plan plan, {bool admin = false}) => AccountProfile(
  userId: 'u1',
  email: 'budi@example.com',
  displayName: 'Budi',
  plan: plan,
  role: UserRole.pengguna360,
  isAdmin: admin,
  canUseSos: false,
);

Map<String, dynamic> limitsRow({int reports = 5, bool attachments = false, bool clubs = false}) => {
  'reports_left': reports,
  'stories_left': 1,
  'photos': attachments ? 4 : 1,
  'attachments': attachments,
  'banned': false,
  'clubs_left': clubs ? 5 : 0,
  'can_create_clubs': clubs,
};

Map<String, dynamic> clubRow({String role = 'owner', String? contact = '@mapalaui'}) => {
  'id': clubId,
  'name': 'Mapala UI',
  'description': 'Pecinta alam',
  'role': role,
  'member_count': 2,
  'owner_name': 'Budi S.',
  'created_at': '2026-11-01T00:00:00Z',
  'region': 'Depok',
  'contact': contact,
  'photo_path': null,
  'new_posts': role == 'owner' ? 0 : 2,
  'can_manage': role != 'member',
};

/// A feed row without photos (no network images in widget tests)
Map<String, dynamic> row({String id = postId, String? club, String createdAt = '2026-11-01T08:00:00.123456+00:00'}) => {
  ...feedRow(id: id, clubId: club, clubName: club == null ? null : 'Mapala UI', createdAt: createdAt),
  'photos': <Object>[],
  'is_mine': false,
};

final _png = Uint8List.fromList(img.encodePng(img.Image(width: 4, height: 3)));

void main() {
  late FakeCommunity backend;
  late MemoryFiles files;
  late ProviderContainer container;
  final now = DateTime(2026, 11, 2, 10);

  setUp(() {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    files = MemoryFiles();
    backend = FakeCommunity()
      ..answers['community_feed'] = [row()]
      ..answers['community_post'] = [row()]
      ..answers['community_comments'] = <Object>[]
      ..answers['my_community_limits'] = [limitsRow()]
      ..answers['my_community_clubs'] = <Object>[]
      ..answers['create_community_post'] = postId;
  });

  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    AccountProfile? signedIn,
    bool online = true,
    (double, double)? gps,
  }) async {
    container = ProviderContainer(
      // No automatic retries of failed loads (they would leave timers behind)
      retry: (_, _) => null,
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
        authUserIdProvider.overrideWith((ref) => Stream.value(signedIn?.userId)),
        profileProvider.overrideWith((ref) async => signedIn),
        communityBackendProvider.overrideWithValue(backend),
        communityOutboxFilesProvider.overrideWithValue(files),
        communityClockProvider.overrideWithValue(() => now),
        onlineProvider.overrideWith((ref) => Stream.value(online)),
        villageIndexProvider.overrideWith(
          (ref) async => VillageIndex(const [
            Village(
              code: '32.03.01.2001',
              name: 'Cimacan',
              kecamatan: 'Cipanas',
              kabKota: 'Cianjur',
              lat: -6.75,
              lng: 106.99,
            ),
          ]),
        ),
        communityGpsProvider.overrideWithValue(({required bool ask}) async => gps),
        communityPhotoPickerProvider.overrideWithValue((_) async => Uint8List.fromList([1, 2, 3])),
        clubPhotoCompressorProvider.overrideWithValue(
          (_) async => CompressedPhoto(bytes: _png, width: 640, height: 480),
        ),
        communityCompressorProvider.overrideWithValue(
          (_) async => CompressedPhoto(bytes: _png, width: 1600, height: 1200),
        ),
      ],
    );
    addTearDown(container.dispose);
    container
      ..listen(authUserIdProvider, (_, _) {})
      ..listen(profileProvider, (_, _) {})
      ..listen(onlineProvider, (_, _) {})
      ..listen(communityOpenProvider, (_, _) {});
    container.read(mapCenterProvider.notifier).set(106.98, -6.76);
    await container.read(authUserIdProvider.future);
    await container.read(profileProvider.future);
    await container.read(onlineProvider.future);
    await tester.binding.setSurfaceSize(const Size(420, 2600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(body: child),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Widget feed() => CommunityFeed(controller: ScrollController());

  group('feed', () {
    testWidgets('guests read everything: no tabs, a gold info card, writing asks to sign in', (tester) async {
      await pump(tester, feed());
      expect(find.text('Kandang Badak'), findsOneWidget);
      expect(find.text('Water source dry'), findsWidgets);
      expect(find.byKey(const Key('community-tab-feed')), findsNothing);
      expect(find.byKey(const Key('community-reports')), findsNothing);
      expect(find.byKey(const Key('community-guest')), findsOneWidget);
      expect(find.byKey(const Key('community-write')), findsNothing, reason: 'no + Post for guests');
      await tester.tap(find.byKey(const Key('community-sign-in')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sign-in-sheet')), findsOneWidget);
    });

    testWidgets('near the map first; one kind and one condition at a time; loads more by the last time', (
      tester,
    ) async {
      backend.answers['community_feed'] = [
        for (var i = 0; i < 20; i++)
          row(
            id: '6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a${i.toString().padLeft(2, '0')}',
            createdAt: '2026-11-01T0${i % 10}:00:00Z',
          ),
      ];
      await pump(tester, feed(), signedIn: profile(Plan.free));
      expect(backend.params('community_feed')['p_west'], closeTo(106.88, 1e-9));
      Future<void> chip(String key) async {
        await tester.ensureVisible(find.byKey(Key(key)));
        await tester.tap(find.byKey(Key(key)));
        await tester.pumpAndSettle();
      }

      await chip('community-kind-story');
      expect(backend.params('community_feed')['p_kinds'], ['story']);
      await chip('community-kind-report');
      expect(backend.params('community_feed')['p_kinds'], ['report'], reason: 'one kind at a time');
      await chip('community-cond-landslide');
      expect(backend.params('community_feed')['p_conditions'], ['landslide']);
      await chip('community-cond-landslide');
      expect(backend.params('community_feed')['p_conditions'], isNull);
      await chip('community-scope-all');
      expect(backend.params('community_feed')['p_west'], isNull);
      expect(find.byKey(const Key('community-write')), findsOneWidget, reason: '+ Post over the list');
      final last = container.read(communityFeedProvider).posts.last.createdAt;
      await tester.scrollUntilVisible(
        find.byKey(const Key('community-more')),
        400,
        scrollable: find
            .descendant(of: find.byKey(const Key('community-feed')), matching: find.byType(Scrollable))
            .first,
      );
      await tester.tap(find.byKey(const Key('community-more')));
      await tester.pumpAndSettle();
      expect(backend.params('community_feed')['p_before'], last.toUtc().toIso8601String());
      expect(container.read(communityFeedProvider).posts, hasLength(40));
    });

    testWidgets('a member sees the tabs with the new club posts and chooses Everyone or a club', (tester) async {
      backend.answers['my_community_clubs'] = [clubRow(role: 'member')];
      await pump(tester, feed(), signedIn: profile(Plan.free));
      expect(find.byKey(const Key('community-tab-clubs')), findsOneWidget);
      expect(find.byKey(const Key('clubs-tab-badge')), findsOneWidget);
      await tester.tap(find.byKey(const Key('community-club-$clubId')));
      await tester.pumpAndSettle();
      expect(backend.params('community_feed')['p_club'], clubId);
      await tester.tap(find.byKey(const Key('community-everyone')));
      await tester.pumpAndSettle();
      expect(backend.params('community_feed')['p_club'], isNull);
      await tester.tap(find.byKey(const Key('community-tab-clubs')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('club-$clubId')), findsOneWidget);
      expect(find.byKey(const Key('club-new-$clubId')), findsOneWidget);
    });

    testWidgets('empty states: quiet around here, no posts match, nothing in the club', (tester) async {
      backend
        ..answers['community_feed'] = <Object>[]
        ..answers['my_community_clubs'] = [clubRow(role: 'member')];
      await pump(tester, feed(), signedIn: profile(Plan.free));
      expect(find.text('Quiet around here'), findsOneWidget);
      expect(find.byKey(const Key('empty-write')), findsOneWidget);
      await tester.tap(find.byKey(const Key('empty-everywhere')));
      await tester.pumpAndSettle();
      expect(container.read(communityFeedProvider).filter.scope, FeedScope.all);
      expect(find.text('No posts yet'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('community-cond-closed')));
      await tester.tap(find.byKey(const Key('community-cond-closed')));
      await tester.pumpAndSettle();
      expect(find.text('No posts match'), findsOneWidget);
      await tester.tap(find.byKey(const Key('empty-clear')));
      await tester.pumpAndSettle();
      expect(container.read(communityFeedProvider).filter.conditions, isEmpty);
      await tester.tap(find.byKey(const Key('community-club-$clubId')));
      await tester.pumpAndSettle();
      expect(find.text('Nothing in Mapala UI yet'), findsOneWidget);
    });

    testWidgets('Mine: stats, my posts with their status, and the empty state', (tester) async {
      backend.answers['my_community_posts'] = [
        {...row(), 'is_mine': true, 'helpful_count': 3, 'status': 'visible'},
        {...row(id: 'x2'), 'is_mine': true, 'helpful_count': 2, 'status': 'hidden'},
      ];
      await pump(tester, feed(), signedIn: profile(Plan.free));
      await tester.tap(find.byKey(const Key('community-tab-mine')));
      await tester.pumpAndSettle();
      expect(backend.params('my_community_posts'), {'p_before': null, 'p_limit': 20});
      expect(find.byKey(const Key('mine-stats')), findsOneWidget);
      expect(find.text('5'), findsOneWidget, reason: 'found helpful');
      expect(find.text(' · HIDDEN'), findsOneWidget);
      backend.answers['my_community_posts'] = <Object>[];
      await container.read(myPostsProvider.notifier).load();
      await tester.pumpAndSettle();
      expect(find.text('You have not posted yet'), findsOneWidget);
      expect(find.text('Write your first post'), findsOneWidget);
    });

    testWidgets('without signal the last page read is shown', (tester) async {
      await SharedPreferencesAsync().setString(
        feedCacheKey,
        jsonEncode({
          'savedAt': '2026-11-02T07:00:00Z',
          'userId': null,
          'posts': [row()],
        }),
      );
      backend.offline = true;
      await pump(tester, feed());
      expect(find.byKey(const Key('community-offline')), findsOneWidget);
      expect(find.text('Kandang Badak'), findsOneWidget);
    });

    testWidgets('trail reports waiting to be sent show with Send now and Discard', (tester) async {
      backend.offline = true;
      await pump(tester, feed(), signedIn: profile(Plan.free));
      await container
          .read(communityOutboxProvider.notifier)
          .queue(
            const NewPost(
              kind: PostKind.report,
              title: 'Longsor pos 2',
              body: 'b',
              conditions: ['landslide'],
              happenedOn: '2026-11-02',
              lat: 1,
              lng: 2,
            ),
            const [],
          );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('community-outbox')), findsOneWidget);
      expect(find.text('1 trail report waiting to be sent'), findsOneWidget);
      backend.offline = false;
      await tester.tap(find.text('Send now'));
      await tester.pumpAndSettle();
      expect(backend.names, contains('create_community_post'));
      expect(find.byKey(const Key('community-outbox')), findsNothing);
    });
  });

  group('post', () {
    testWidgets('Helpful, comments and the public link', (tester) async {
      backend
        ..answers['toggle_community_helpful'] = [
          {'helpful': true, 'helpful_count': 4},
        ]
        ..answers['add_community_comment'] = 'c1';
      await pump(tester, const CommunityPostPage(id: postId), signedIn: profile(Plan.free));
      expect(find.byKey(const Key('post-share')), findsOneWidget);
      expect(find.byKey(const Key('club-badge')), findsNothing);
      await tester.tap(find.byKey(const Key('post-helpful')));
      await tester.pumpAndSettle();
      expect(find.text('Helpful · 4'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('comment-field')), 'Masih kering?');
      backend.answers['community_comments'] = [
        {
          'id': 'c1',
          'body': 'Masih kering?',
          'created_at': '2026-11-02T09:00:00Z',
          'author_name': 'Budi',
          'is_mine': true,
        },
      ];
      await tester.tap(find.byKey(const Key('comment-send')));
      await tester.pumpAndSettle();
      expect(backend.params('add_community_comment'), {'p_post_id': postId, 'p_body': 'Masih kering?'});
      expect(find.text('Masih kering?'), findsOneWidget);
      expect(find.byTooltip('Delete comment'), findsOneWidget);
    });

    testWidgets('a club post shows its badge and has no public link', (tester) async {
      backend.answers['community_post'] = [row(club: clubId)];
      await pump(tester, const CommunityPostPage(id: postId), signedIn: profile(Plan.free));
      expect(find.byKey(const Key('club-badge')), findsOneWidget);
      expect(find.text('Club: Mapala UI · Members only'), findsOneWidget);
      expect(find.byKey(const Key('post-share')), findsNothing);
    });

    testWidgets('reporting a post with a reason', (tester) async {
      await pump(tester, const CommunityPostPage(id: postId), signedIn: profile(Plan.free));
      await tester.tap(find.byKey(const Key('post-menu')));
      await tester.pumpAndSettle();
      expect(find.text('Edit'), findsNothing, reason: 'not mine');
      await tester.tap(find.text('Report'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('reason-misleading')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('report-send')));
      await tester.pumpAndSettle();
      expect(backend.params('report_community'), {
        'p_kind': 'post',
        'p_id': postId,
        'p_reason': 'misleading',
        'p_note': null,
      });
    });

    testWidgets('my post: edit within 24 hours, shows edited', (tester) async {
      backend.answers['community_post'] = [
        {...row(), 'is_mine': true, 'edited_at': '2026-11-01T09:00:00Z'},
      ];
      await pump(tester, const CommunityPostPage(id: postId), signedIn: profile(Plan.free));
      expect(find.textContaining('edited'), findsOneWidget);
      await tester.tap(find.byKey(const Key('post-menu')));
      await tester.pumpAndSettle();
      expect(find.text('Edit'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('compose-body')), 'Sudah ada air lagi');
      await tester.tap(find.byKey(const Key('compose-save')));
      await tester.pumpAndSettle();
      expect(backend.params('update_community_post')['p_body'], 'Sudah ada air lagi');
    });

    testWidgets('guests read a post and are asked to sign in for Helpful', (tester) async {
      await pump(tester, const CommunityPostPage(id: postId));
      expect(find.byKey(const Key('comment-field')), findsNothing);
      await tester.tap(find.byKey(const Key('post-helpful')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sign-in-sheet')), findsOneWidget);
      expect(backend.names, isNot(contains('toggle_community_helpful')));
    });
  });

  group('compose', () {
    Widget compose() => const CommunityComposePage();

    testWidgets('a trail report needs text and a condition; the place is the nearest village', (tester) async {
      await pump(tester, compose(), signedIn: profile(Plan.free));
      expect(find.byKey(const Key('compose-limits')), findsOneWidget);
      expect(find.text('5 trail reports and 1 story left today'), findsOneWidget);
      expect(find.byKey(const Key('compose-attach-locked')), findsOneWidget, reason: 'Free');
      expect(find.byKey(const Key('compose-audience')), findsNothing, reason: 'no clubs');
      expect(tester.widget<TextField>(find.byKey(const Key('compose-place'))).controller!.text, 'Cimacan, Cipanas');
      await tester.ensureVisible(find.byKey(const Key('compose-save')));
      await tester.tap(find.byKey(const Key('compose-save')));
      await tester.pumpAndSettle();
      expect(find.text('Write something first.'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('compose-body')), 'Sumber air kering');
      await tester.ensureVisible(find.byKey(const Key('compose-save')));
      await tester.tap(find.byKey(const Key('compose-save')));
      await tester.pumpAndSettle();
      expect(find.text('Choose at least one trail condition.'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('compose-cond-water_dry')));
      await tester.tap(find.byKey(const Key('compose-cond-water_dry')));
      await tester.ensureVisible(find.byKey(const Key('compose-camera')));
      await tester.tap(find.byKey(const Key('compose-camera')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('compose-camera')), findsNothing, reason: 'Free: 1 photo');
      await tester.ensureVisible(find.byKey(const Key('compose-save')));
      await tester.tap(find.byKey(const Key('compose-save')));
      await tester.pumpAndSettle();
      final p = backend.calls.firstWhere((c) => c.$1 == 'create_community_post').$2;
      expect(p['p_kind'], 'report');
      expect(p['p_conditions'], ['water_dry']);
      expect(p['p_happened_on'], '2026-11-02');
      expect((p['p_lat'], p['p_lng']), (-6.76, 106.98));
      expect(p['p_place_name'], 'Cimacan, Cipanas');
      expect(p['p_club_id'], isNull);
      expect(backend.uploads.keys, ['u1/$postId-0.jpg']);
    });

    testWidgets('warns when the post is where you are now', (tester) async {
      await pump(tester, compose(), signedIn: profile(Plan.free), gps: (106.981, -6.761));
      expect(find.byKey(const Key('compose-near-me')), findsOneWidget);
      expect(find.text('You are sharing where you are now.'), findsOneWidget);
    });

    testWidgets('no warning far from the GPS position', (tester) async {
      await pump(tester, compose(), signedIn: profile(Plan.free), gps: (107.5, -6.9));
      expect(find.byKey(const Key('compose-near-me')), findsNothing);
    });

    testWidgets('without signal a trail report waits on the phone', (tester) async {
      await pump(tester, compose(), signedIn: profile(Plan.free), online: false);
      await tester.enterText(find.byKey(const Key('compose-body')), 'Pohon tumbang di pos 2');
      await tester.ensureVisible(find.byKey(const Key('compose-cond-fallen_tree')));
      await tester.tap(find.byKey(const Key('compose-cond-fallen_tree')));
      await tester.ensureVisible(find.byKey(const Key('compose-save')));
      await tester.tap(find.byKey(const Key('compose-save')));
      await tester.pumpAndSettle();
      expect(backend.names, isNot(contains('create_community_post')));
      expect(container.read(communityOutboxProvider).items.single.post.body, 'Pohon tumbang di pos 2');
    });

    testWidgets('at the daily limit posting is off; Pro may attach map data and post to a club', (tester) async {
      backend
        ..answers['my_community_limits'] = [limitsRow(reports: 0, attachments: true)]
        ..answers['my_community_clubs'] = [clubRow(role: 'member')];
      await pump(tester, compose(), signedIn: profile(Plan.pro));
      expect(find.textContaining("You have reached today's limit"), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('compose-save')));
      expect(tester.widget<FilledButton>(find.byKey(const Key('compose-save'))).onPressed, isNull);
      expect(find.byKey(const Key('compose-attach')), findsOneWidget);
      // A story still can go, to the club
      await tester.tap(find.text('Story'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('compose-body')), 'Tiga hari di Rinjani');
      await tester.ensureVisible(find.byKey(const Key('compose-audience')));
      await tester.tap(find.byKey(const Key('compose-audience')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Club: Mapala UI · Members only').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('compose-save')));
      await tester.tap(find.byKey(const Key('compose-save')));
      await tester.pumpAndSettle();
      final p = backend.params('create_community_post');
      expect((p['p_kind'], p['p_club_id']), ('story', clubId));
    });
  });

  group('clubs', () {
    testWidgets('only accounts that may create clubs see New club', (tester) async {
      backend.answers['my_community_clubs'] = [clubRow(role: 'member')];
      await pump(tester, const ClubsPage(), signedIn: profile(Plan.free));
      expect(find.byKey(const Key('club-create')), findsNothing);
      expect(find.text('Mapala UI'), findsOneWidget);
      expect(find.textContaining('Leader: Budi S.'), findsOneWidget);
      expect(find.byKey(const Key('club-avatar-letter')), findsOneWidget);
    });

    testWidgets('Enterprise creates a club', (tester) async {
      backend
        ..answers['my_community_limits'] = [limitsRow(clubs: true)]
        ..answers['create_community_club'] = clubId;
      await pump(tester, const ClubsPage(), signedIn: profile(Plan.enterprise));
      expect(find.text('New club (5 left)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('club-create')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('club-name')), 'Mapala UI');
      await tester.tap(find.byKey(const Key('club-save')));
      await tester.pumpAndSettle();
      expect(backend.params('create_community_club'), {'p_name': 'Mapala UI', 'p_description': null});
      expect(backend.names, isNot(contains('update_community_club')));
    });

    testWidgets('the leader sees the profile, edits it and adds members by email', (tester) async {
      backend
        ..answers['my_community_limits'] = [limitsRow(clubs: true)]
        ..answers['my_community_clubs'] = [clubRow()]
        ..answers['community_club_members'] = [
          {'user_id': 'u1', 'name': 'Budi S.', 'role': 'owner', 'added_at': '2026-11-01T00:00:00Z', 'is_me': true},
        ]
        ..answers['add_community_club_member'] = 'Rina A.';
      await pump(tester, const ClubPage(clubId: clubId), signedIn: profile(Plan.enterprise));
      expect(find.text('Depok'), findsOneWidget);
      expect(find.byKey(const Key('club-contact-link')), findsOneWidget);
      expect(find.text('Leader'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('club-member-email')), 'rina@example.com');
      await tester.tap(find.byKey(const Key('club-member-add')));
      await tester.pumpAndSettle();
      expect(backend.params('add_community_club_member'), {'p_club_id': clubId, 'p_email': 'rina@example.com'});
      expect(find.text('Rina A. was added to the club.'), findsOneWidget);

      await tester.tap(find.byKey(const Key('club-edit')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('club-region')), 'Depok, Jawa Barat');
      await tester.tap(find.byKey(const Key('club-photo-change')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('club-save')));
      await tester.pumpAndSettle();
      expect(backend.params('update_community_club'), {
        'p_id': clubId,
        'p_name': 'Mapala UI',
        'p_description': 'Pecinta alam',
        'p_region': 'Depok, Jawa Barat',
        'p_contact': '@mapalaui',
      });
      final path = backend.params('set_community_club_photo')['p_path'] as String;
      expect(path, startsWith('u1/club-$clubId-'));
      expect(backend.uploads.keys, [path]);
    });

    testWidgets('a member sees no member emails and can leave', (tester) async {
      backend
        ..answers['my_community_clubs'] = [clubRow(role: 'member', contact: null)]
        ..answers['community_club_members'] = [
          {'user_id': 'u0', 'name': 'Budi S.', 'role': 'owner', 'added_at': '2026-11-01T00:00:00Z', 'is_me': false},
          {'user_id': 'u1', 'name': 'Rina A.', 'role': 'member', 'added_at': '2026-11-01T00:00:00Z', 'is_me': true},
        ];
      await pump(tester, const ClubPage(clubId: clubId), signedIn: profile(Plan.free));
      expect(find.byKey(const Key('club-member-email')), findsNothing);
      expect(find.byKey(const Key('club-edit')), findsNothing);
      await tester.tap(find.byKey(const Key('club-leave')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-action')));
      await tester.pumpAndSettle();
      expect(backend.params('remove_community_club_member'), {'p_club_id': clubId, 'p_user_id': 'u1'});
    });
  });

  group('club roles, invites, workspace and pins', () {
    List<Map<String, dynamic>> members() => [
      {'user_id': 'u1', 'name': 'Budi S.', 'role': 'owner', 'added_at': '2026-11-01T00:00:00Z', 'is_me': true},
      {'user_id': 'u2', 'name': 'Rina A.', 'role': 'admin', 'added_at': '2026-11-01T00:00:00Z', 'is_me': false},
      {'user_id': 'u3', 'name': 'Dodi P.', 'role': 'member', 'added_at': '2026-11-01T00:00:00Z', 'is_me': false},
    ];

    testWidgets('the leader makes a member an admin and creates an invite link', (tester) async {
      backend
        ..answers['my_community_clubs'] = [clubRow()]
        ..answers['community_club_members'] = members()
        ..answers['community_club_invites'] = <Object>[]
        ..answers['create_community_club_invite'] = '0123456789abcdef0123456789abcdef';
      await pump(tester, const ClubPage(clubId: clubId), signedIn: profile(Plan.enterprise));
      expect(find.byKey(const Key('role-u1')), findsOneWidget);
      expect(find.text('Leader'), findsOneWidget);
      expect(find.text('Admin'), findsOneWidget);
      expect(find.byKey(const Key('member-menu-u1')), findsNothing, reason: 'not the leader themself');
      await tester.tap(find.byKey(const Key('member-menu-u3')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Make admin'));
      await tester.pumpAndSettle();
      expect(backend.params('set_community_club_role'), {'p_club_id': clubId, 'p_user_id': 'u3', 'p_role': 'admin'});
      await tester.tap(find.byKey(const Key('club-invite-new')));
      await tester.pumpAndSettle();
      expect(backend.params('create_community_club_invite'), {'p_club_id': clubId});
    });

    testWidgets('the leader hands the club over; a refusal from the server is shown', (tester) async {
      backend
        ..answers['my_community_clubs'] = [clubRow()]
        ..answers['community_club_members'] = members()
        ..answers['community_club_invites'] = <Object>[]
        ..fail['transfer_community_club'] = const CommunityException('The new leader needs an Enterprise account');
      await pump(tester, const ClubPage(clubId: clubId), signedIn: profile(Plan.enterprise));

      // Dodi has no Enterprise account
      await tester.tap(find.byKey(const Key('member-menu-u3')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Make club leader'));
      await tester.pumpAndSettle();
      expect(find.textContaining('needs an Enterprise account'), findsWidgets, reason: 'said before confirming');
      await tester.tap(find.byKey(const Key('confirm-action')));
      await tester.pumpAndSettle();
      expect(find.text('The new leader needs an Enterprise account'), findsOneWidget);

      // Rina has
      backend.answers['transfer_community_club'] = 'Rina A.';
      await tester.tap(find.byKey(const Key('member-menu-u2')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Make club leader'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-action')));
      await tester.pumpAndSettle();
      expect(backend.params('transfer_community_club'), {'p_club_id': clubId, 'p_user_id': 'u2'});
      expect(find.text('Rina A. now leads the club. You are an admin.'), findsOneWidget);
    });

    testWidgets('a leader no longer Enterprise can still hand the club over, not manage it', (tester) async {
      backend
        ..answers['my_community_clubs'] = [
          {...clubRow(), 'can_manage': false},
        ]
        ..answers['community_club_members'] = members()
        ..answers['community_club_invites'] = <Object>[];
      await pump(tester, const ClubPage(clubId: clubId), signedIn: profile(Plan.pro));
      await tester.tap(find.byKey(const Key('member-menu-u3')));
      await tester.pumpAndSettle();
      expect(find.text('Make admin'), findsNothing);
      expect(find.text('Make club leader'), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
    });

    testWidgets('an admin manages members but not other admins or roles', (tester) async {
      backend
        ..answers['my_community_clubs'] = [clubRow(role: 'admin')]
        ..answers['community_club_members'] = [
          ...members().map((m) => {...m, 'is_me': m['user_id'] == 'u2'}),
        ]
        ..answers['community_club_invites'] = <Object>[];
      await pump(tester, const ClubPage(clubId: clubId), signedIn: profile(Plan.free));
      expect(find.byKey(const Key('club-member-email')), findsOneWidget);
      expect(find.byKey(const Key('club-invites')), findsOneWidget);
      expect(find.byKey(const Key('club-edit')), findsNothing, reason: 'the profile is the leader\'s');
      expect(find.byKey(const Key('member-menu-u1')), findsNothing);
      await tester.tap(find.byKey(const Key('member-menu-u3')));
      await tester.pumpAndSettle();
      expect(find.text('Make admin'), findsNothing);
      await tester.tap(find.text('Remove from club'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-action')));
      await tester.pumpAndSettle();
      expect(backend.params('remove_community_club_member'), {'p_club_id': clubId, 'p_user_id': 'u3'});
    });

    testWidgets('workspace: folders, an item on the map, removing it', (tester) async {
      final area = areaAttachment(
        name: 'Blok A',
        color: '#2563eb',
        ring: const [(106.9, -6.7), (107.0, -6.7), (107.0, -6.8)],
      );
      backend
        ..answers['my_community_clubs'] = [clubRow(role: 'member')]
        ..answers['community_club_members'] = members()
        ..answers['community_club_folders'] = [
          {'id': 'f1', 'name': 'Latihan', 'item_count': 1},
        ]
        ..answers['community_club_items'] = [
          {
            'id': 'i1',
            'folder_id': 'f1',
            'kind': 'area',
            'name': 'Blok A',
            'summary': {'color': '#2563eb'},
            'added_by_name': 'Budi',
            'is_mine': true,
          },
          {
            'id': 'i2',
            'folder_id': null,
            'kind': 'track',
            'name': 'Jalur',
            'summary': {'distance_m': 1200},
          },
        ]
        ..answers['community_club_item'] = area.toJson();
      await pump(tester, const ClubPage(clubId: clubId), signedIn: profile(Plan.free));
      await tester.tap(find.byKey(const Key('club-tab-workspace')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('folder-new')), findsNothing, reason: 'members do not keep folders');
      expect(find.byKey(const Key('item-i1')), findsOneWidget);
      expect(find.byKey(const Key('item-menu-i2')), findsNothing, reason: 'not mine, not a manager');
      await tester.tap(find.byKey(const Key('folder-none')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('item-i1')), findsNothing);
      expect(find.byKey(const Key('item-i2')), findsOneWidget);
      await tester.tap(find.byKey(const Key('folder-f1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('item-menu-i1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-action')));
      await tester.pumpAndSettle();
      expect(backend.params('delete_community_club_item'), {'p_id': 'i1'});
      await tester.tap(find.byKey(const Key('item-i1')));
      await tester.pumpAndSettle();
      expect(backend.params('community_club_item'), {'p_id': 'i1'});
      final focus = container.read(communityFocusProvider)!;
      expect((focus.title, focus.post, focus.attachment!.kind), ('Blok A', null, 'area'));
      expect(container.read(fitPointsProvider), isNotNull);
    });

    testWidgets('a manager sees folder controls and creates one', (tester) async {
      backend
        ..answers['my_community_clubs'] = [clubRow()]
        ..answers['community_club_members'] = members()
        ..answers['community_club_folders'] = <Object>[]
        ..answers['community_club_items'] = <Object>[]
        ..answers['save_community_club_folder'] = 'f9';
      await pump(tester, const ClubPage(clubId: clubId), signedIn: profile(Plan.enterprise));
      await tester.tap(find.byKey(const Key('club-tab-workspace')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('folder-new')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('ask-text')), 'Survei');
      await tester.tap(find.byKey(const Key('ask-ok')));
      await tester.pumpAndSettle();
      expect(backend.params('save_community_club_folder'), {'p_club_id': clubId, 'p_id': null, 'p_name': 'Survei'});
    });

    testWidgets('club posts: new posts badge, the club feed is marked read', (tester) async {
      backend.answers['my_community_clubs'] = [clubRow(role: 'member')];
      await pump(tester, const ClubsPage(), signedIn: profile(Plan.free));
      expect(find.byKey(const Key('club-new-$clubId')), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      await container.read(communityFeedProvider.notifier).setFilter(const FeedFilter(clubId: clubId));
      await tester.pumpAndSettle();
      expect(backend.params('community_feed')['p_club'], clubId);
      expect(backend.params('mark_community_club_read'), {'p_club_id': clubId});
    });

    testWidgets('a club leader or admin pins a club post', (tester) async {
      backend.answers['community_post'] = [
        {...row(club: clubId), 'my_club_role': 'admin'},
      ];
      await pump(tester, const CommunityPostPage(id: postId), signedIn: profile(Plan.free));
      await tester.tap(find.byKey(const Key('post-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pin to the club'));
      await tester.pumpAndSettle();
      expect(backend.params('pin_community_post'), {'p_post_id': postId, 'p_pinned': true});
      expect(find.byKey(const Key('pinned-badge')), findsOneWidget);
    });

    testWidgets('a member cannot pin', (tester) async {
      backend.answers['community_post'] = [
        {...row(club: clubId), 'my_club_role': 'member', 'pinned': true},
      ];
      await pump(tester, const CommunityPostPage(id: postId), signedIn: profile(Plan.free));
      expect(find.byKey(const Key('pinned-badge')), findsOneWidget);
      await tester.tap(find.byKey(const Key('post-menu')));
      await tester.pumpAndSettle();
      expect(find.text('Unpin'), findsNothing);
      expect(find.text('Pin to the club'), findsNothing);
    });

    const token = '0123456789abcdef0123456789abcdef';
    Map<String, dynamic> info({bool valid = true, bool member = false}) => {
      'club_id': clubId,
      'name': 'Mapala UI',
      'description': 'Pecinta alam',
      'region': 'Depok',
      'photo_path': null,
      'member_count': 12,
      'leader_name': 'Budi S.',
      'valid': valid,
      'is_member': member,
    };

    testWidgets('an invite link shows the club; a guest is asked to sign in', (tester) async {
      backend.answers['community_club_invite_info'] = [info()];
      await pump(tester, const JoinClubPage(token: token));
      expect(find.text('Mapala UI'), findsOneWidget);
      expect(find.text('Sign in to join'), findsOneWidget);
      await tester.tap(find.byKey(const Key('join-club-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sign-in-sheet')), findsOneWidget);
      expect(backend.names, isNot(contains('join_community_club')));
    });

    testWidgets('signed in, Join opens the club', (tester) async {
      backend
        ..answers['community_club_invite_info'] = [info()]
        ..answers['join_community_club'] = clubId
        ..answers['my_community_clubs'] = [clubRow(role: 'member')]
        ..answers['community_club_members'] = members();
      await pump(tester, const JoinClubPage(token: token), signedIn: profile(Plan.free));
      await tester.tap(find.byKey(const Key('join-club-button')));
      await tester.pumpAndSettle();
      expect(backend.params('join_community_club'), {'p_token': token});
      expect(find.byKey(const Key('club-members')), findsOneWidget);
    });

    testWidgets('an expired link says so', (tester) async {
      backend.answers['community_club_invite_info'] = [info(valid: false)];
      await pump(tester, const JoinClubPage(token: token), signedIn: profile(Plan.free));
      expect(find.textContaining('has expired or was stopped'), findsOneWidget);
      expect(find.byKey(const Key('join-club-button')), findsNothing);
    });

    test('a ?join= link asks the map to open the invite', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c
        ..listen(sharedLinkProvider, (_, _) {})
        ..listen(communityJoinProvider, (_, _) {});
      await c.read(sharedLinkProvider.notifier).open(const JoinLink(token));
      expect(c.read(communityJoinProvider), token);
    });
  });

  testWidgets('admin: hides a reported post and blocks its author', (tester) async {
    backend.answers['community_report_queue'] = [
      {
        'target_kind': 'post',
        'target_id': postId,
        'post_id': postId,
        'status': 'hidden',
        'excerpt': 'Kandang Badak: iklan',
        'author_id': 'u9',
        'author_name': 'Spam B.',
        'reports': 3,
        'reasons': ['spam'],
        'notes': ['iklan'],
        'last_reported_at': '2026-11-02T00:00:00Z',
        'author_banned': false,
      },
    ];
    await pump(tester, const CommunityReportsPage(), signedIn: profile(Plan.enterprise, admin: true));
    expect(find.text('Kandang Badak: iklan'), findsOneWidget);
    await tester.tap(find.byKey(const Key('hide-$postId')));
    await tester.pumpAndSettle();
    expect(backend.params('moderate_community'), {'p_kind': 'post', 'p_id': postId, 'p_action': 'hide'});
    await tester.tap(find.byKey(const Key('ban-$postId')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Block author permanently'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-action')));
    await tester.pumpAndSettle();
    expect(backend.params('set_community_ban'), {'p_user_id': 'u9', 'p_reason': 'Spam', 'p_days': null});
  });

  testWidgets('the map sheet has a Community tool and layer switch', (tester) async {
    await pump(tester, MapSheet(scrollController: ScrollController()));
    expect(find.byKey(const Key('tool-Community')), findsOneWidget);
    await tester.tap(find.byKey(const Key('tool-Community')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('community-feed')), findsOneWidget);
    await tester.tap(find.byKey(const Key('community-layer')));
    await tester.pumpAndSettle();
    expect(container.read(communityLayerProvider).shown, isTrue);
  });

  group('post card', () {
    Future<void> card(WidgetTester tester, Map<String, dynamic> r, {PostStatus? status}) =>
        pump(tester, PostCard(post: CommunityPost.fromRow(r), status: status, onTap: () {}));

    testWidgets('a trail report: stripe in its first condition, kind, time, author and place, counts', (tester) async {
      await card(tester, {...row(), 'i_found_helpful': true});
      final stripe = tester.widget<Container>(find.byKey(const Key('post-stripe')));
      expect(stripe.color, hexColor('#e46c24'), reason: 'Water source dry');
      expect(tester.getSize(find.byKey(const Key('post-stripe'))).width, 4);
      expect(find.text('TRAIL REPORT'), findsOneWidget);
      expect(find.textContaining(' ago'), findsOneWidget);
      expect(find.text('Kandang Badak'), findsOneWidget);
      expect(find.textContaining('Cimacan, Cipanas', findRichText: true), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('post-helpful-count'))).style!.color, L360Colors.forest700);
      expect(find.byKey(const Key('club-badge')), findsNothing);
    });

    testWidgets('a story is gold; pinned, old, club and status show', (tester) async {
      await card(tester, {
        ...row(club: clubId),
        'kind': 'story',
        'conditions': <String>[],
        'pinned': true,
      }, status: PostStatus.removed);
      expect(tester.widget<Container>(find.byKey(const Key('post-stripe'))).color, hexColor('#d49b22'));
      expect(find.text('STORY'), findsOneWidget);
      expect(find.text('PINNED'), findsOneWidget);
      expect(find.byKey(const Key('club-badge')), findsOneWidget);
      expect(find.text(' · REMOVED'), findsOneWidget);
    });

    testWidgets('an old trail report says so', (tester) async {
      await card(tester, {...row(), 'happened_on': '2026-09-01'});
      expect(find.text(' · OLD'), findsOneWidget);
    });
  });

  test('a link to a post asks the map to open it', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c
      ..listen(sharedLinkProvider, (_, _) {})
      ..listen(communityOpenProvider, (_, _) {});
    await c.read(sharedLinkProvider.notifier).open(const CommunityLink(postId));
    expect(c.read(communityOpenProvider), postId);
    expect(c.read(sharedLinkProvider), isNull);
  });

  test('map layer data: one marker per post in its condition, the shown post with its track', () {
    final report = CommunityPost.fromRow(row());
    final story = CommunityPost.fromRow({...row(id: 'x'), 'kind': 'story', 'conditions': <String>[]});
    final geo = communityGeoJson([report, story]);
    final icons = [for (final f in geo['features']! as List) ((f as Map)['properties'] as Map)['icon']];
    expect(icons, ['community-water_dry', 'community-story']);
    final shown = CommunityPost.fromRow({
      ...row(),
      'attachment': trackAttachment(name: 'T', distanceM: 1, points: const [(106.9, -6.7), (107.0, -6.8)]).toJson(),
    });
    final focus = focusGeoJson(MapFocus.post(shown))['features']! as List;
    expect([for (final f in focus) ((f as Map)['geometry'] as Map)['type']], ['LineString', 'Point']);
    expect(focusGeoJson(null)['features'], isEmpty);
  });

  test('the outbox file store keeps photos by name', () async {
    final f = MemoryFiles();
    await f.write('a.jpg', Uint8List.fromList([1]));
    expect(await f.read('a.jpg'), [1]);
    await f.delete('a.jpg');
    expect(await f.read('a.jpg'), isNull);
    expect(communityOutboxKey, 'l360-community-outbox');
  });
}
