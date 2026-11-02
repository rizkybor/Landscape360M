import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/core/config/app_config.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/core/theme/app_theme.dart';
import 'package:landscape360/domain/account/profile.dart';
import 'package:landscape360/domain/community/community.dart';
import 'package:landscape360/features/community/community_events_ui.dart';
import 'package:landscape360/features/community/community_state.dart';
import 'package:landscape360/features/tracks/track_recorder_state.dart' show onlineProvider;
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import '../data/community_repository_test.dart' show FakeCommunity;
import '../domain/community_events_test.dart' show eventRow;

// The Events tab, the event page (joining with an emergency contact, organisers approving,
// the checklist, my summary after the event) and the event form

const eventId = 'e1e1e1e1-0000-4000-8000-000000000001';
const clubId = '11111111-2222-4333-8444-555555555555';

CommunityClub club({bool manage = false}) => CommunityClub(
  id: clubId,
  name: 'Mapala UI',
  role: manage ? ClubRole.owner : ClubRole.member,
  createdAt: DateTime.utc(2026),
  canManage: manage,
);

/// A running event's badge pulses for ever: frames enough for loads, sheets and dialogs instead
/// of waiting for it to settle
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  late FakeCommunity backend;
  final now = DateTime.utc(2026, 11, 9, 3);

  setUp(() {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    backend = FakeCommunity()
      ..answers['community_event_participants'] = <Object>[]
      ..answers['community_event_checklist'] = <Object>[]
      ..answers['community_live_latest'] = <Object>[]
      ..answers['community_club_items'] = <Object>[];
  });

  Future<ProviderContainer> pump(WidgetTester tester, Widget child) async {
    final c = ProviderContainer(
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
        authUserIdProvider.overrideWith((ref) => Stream.value('u1')),
        profileProvider.overrideWith(
          (ref) async => const AccountProfile(
            userId: 'u1',
            email: 'u@x.id',
            displayName: 'U',
            plan: Plan.enterprise,
            role: UserRole.pengguna360,
            isAdmin: false,
            canUseSos: false,
          ),
        ),
        onlineProvider.overrideWith((ref) => Stream.value(true)),
        communityBackendProvider.overrideWithValue(backend),
        communityClockProvider.overrideWithValue(() => now),
      ],
    );
    addTearDown(c.dispose);
    // Kept alive while the test runs, as in the app (they dispose when nothing listens)
    c
      ..listen(authUserIdProvider, (_, _) {})
      ..listen(profileProvider, (_, _) {})
      ..listen(onlineProvider, (_, _) {});
    await c.read(authUserIdProvider.future);
    await tester.binding.setSurfaceSize(const Size(420, 2400));
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
    return c;
  }

  testWidgets('Events tab: state, going / quota, sharing; New event for organisers only', (tester) async {
    backend.answers['community_events'] = [
      {
        'id': eventId,
        'title': 'Gede traverse',
        'starts_at': '2026-11-08T22:00:00Z',
        'ends_at': '2026-11-09T10:00:00Z',
        'state': 'planned',
        'meeting_name': 'Cibodas',
        'going_count': 5,
        'pending_count': 2,
        'quota': 12,
        'my_status': 'going',
        'sharing_count': 3,
      },
    ];
    await pump(tester, ClubEventsTab(club: club()));
    expect(find.byKey(const Key('event-state-planned')), findsOneWidget);
    expect(find.text('Upcoming'), findsWidgets);
    expect(find.text('5 / 12 going'), findsOneWidget);
    expect(find.text('3 sharing live'), findsOneWidget);
    expect(find.text('Meet at Cibodas'), findsOneWidget);
    expect(find.byKey(const Key('event-new')), findsNothing);
    expect(backend.params('community_events'), {'p_club_id': clubId, 'p_past': false});
    await tester.tap(find.byKey(const Key('events-past')));
    await settle(tester);
    expect(backend.params('community_events'), {'p_club_id': clubId, 'p_past': true});
  });

  testWidgets('organisers see New event', (tester) async {
    backend.answers['community_events'] = <Object>[];
    await pump(tester, ClubEventsTab(club: club(manage: true)));
    expect(find.byKey(const Key('event-new')), findsOneWidget);
    expect(find.text('No events planned'), findsOneWidget);
  });

  testWidgets('a member joins with an emergency contact and waits for approval', (tester) async {
    backend
      ..answers['community_event'] = [eventRow(state: 'planned', myStatus: null)]
      ..answers['join_community_event'] = 'pending';
    await pump(tester, const EventPage(eventId: eventId));
    expect(find.text('Gede–Pangrango traverse'), findsWidgets);
    expect(find.byKey(const Key('event-state-planned')), findsOneWidget);
    await tester.tap(find.byKey(const Key('event-join')));
    await settle(tester);
    expect(
      find.text('Optional. Only the organisers see it, to call someone if something happens to you.'),
      findsOneWidget,
    );
    await tester.enterText(find.byKey(const Key('emergency-name')), 'Ibu');
    await tester.enterText(find.byKey(const Key('emergency-phone')), '0812 3456');
    backend.answers['community_event'] = [eventRow(state: 'planned', myStatus: 'pending')];
    await tester.tap(find.byKey(const Key('emergency-save')));
    await settle(tester);
    expect(backend.params('join_community_event'), {
      'p_id': eventId,
      'p_emergency_name': 'Ibu',
      'p_emergency_phone': '0812 3456',
    });
    expect(find.text('Waiting for approval'), findsWidgets);
  });

  testWidgets('organisers approve, see emergency contacts and who is not seen; tick counts', (tester) async {
    backend
      ..answers['community_event'] = [eventRow(canManage: true)]
      ..answers['community_event_participants'] = [
        {
          'user_id': 'u2',
          'name': 'Rina A.',
          'status': 'pending',
          'joined_at': '2026-11-01T00:00:00Z',
          'checked_count': 0,
          'sharing': false,
        },
        {
          'user_id': 'u3',
          'name': 'Dodi P.',
          'status': 'going',
          'joined_at': '2026-11-01T00:00:00Z',
          'emergency_name': 'Ayah',
          'emergency_phone': '0812',
          'checked_count': 1,
          'sharing': true,
          'last_seen_at': '2026-11-09T01:00:00Z',
        },
      ]
      ..answers['community_event_checklist'] = [
        {'id': 'c1', 'label': 'Headlamp', 'checked': false, 'checked_count': 1},
      ]
      ..answers['add_community_event_checklist_item'] = 'c2';
    await pump(tester, const EventPage(eventId: eventId));
    expect(find.byKey(const Key('emergency-u3')), findsOneWidget);
    expect(find.text('Emergency: Ayah, 0812'), findsOneWidget);
    expect(find.byKey(const Key('stale-u3')), findsOneWidget);
    expect(find.text('Not seen for over 60 min'), findsOneWidget);
    // Per item (1 of 1 participant) and per person (Dodi: 1 of 1 item)
    expect(find.text('1/1 ticked'), findsNWidgets(2));
    await tester.tap(find.byKey(const Key('approve-u2')));
    await settle(tester);
    expect(backend.params('decide_community_event_participant'), {
      'p_id': eventId,
      'p_user_id': 'u2',
      'p_status': 'going',
    });
    await tester.enterText(find.byKey(const Key('checklist-new')), 'Raincoat');
    await tester.tap(find.byKey(const Key('checklist-add')));
    await settle(tester);
    expect(backend.params('add_community_event_checklist_item'), {'p_id': eventId, 'p_label': 'Raincoat'});
    await tester.tap(find.byKey(const Key('check-c1')));
    await settle(tester);
    expect(backend.params('toggle_community_event_check'), {'p_item_id': 'c1'});
  });

  testWidgets('a participant who may share sees Share my position', (tester) async {
    backend.answers['community_event'] = [eventRow()];
    await pump(tester, const EventPage(eventId: eventId));
    expect(find.byKey(const Key('event-share')), findsOneWidget);
    expect(find.byKey(const Key('event-live-map')), findsOneWidget);
    expect(find.text("You're going"), findsOneWidget);
  });

  testWidgets('after the event: my summary, save my track, write a story', (tester) async {
    backend
      ..answers['community_event'] = [eventRow(state: 'ended')]
      ..answers['community_live_latest'] = [
        {'user_id': 'u1', 'name': 'U', 'lat': -6.7, 'lng': 106.9, 'recorded_at': '2026-11-09T02:00:00Z', 'is_me': true},
      ]
      ..answers['community_live_trail'] = [
        for (var i = 0; i < 4; i++)
          {'lat': -6.7 + i * 0.001, 'lng': 106.9, 'altitude_m': 2000 + i * 10, 'recorded_at': '2026-11-09T0$i:00:00Z'},
      ]
      ..answers['add_community_club_item'] = 'i9';
    await pump(tester, const EventPage(eventId: eventId));
    expect(find.byKey(const Key('event-summary')), findsOneWidget);
    expect(find.text('30 m'), findsOneWidget, reason: 'climbed');
    await tester.tap(find.byKey(const Key('event-save-track')));
    await settle(tester);
    final p = backend.params('add_community_club_item');
    expect(p['p_club_id'], clubId);
    expect((p['p_data'] as Map)['kind'], 'track');
    expect(((p['p_data'] as Map)['geometry'] as Map)['coordinates'], hasLength(4));
    expect(find.byKey(const Key('event-story')), findsOneWidget);
    expect(find.byKey(const Key('event-share')), findsNothing, reason: 'ended');
  });

  testWidgets('the event form checks and saves', (tester) async {
    backend.answers['save_community_event'] = eventId;
    await pump(
      tester,
      EventFormPage(
        draft: EventDraft(
          clubId: clubId,
          startsAt: DateTime(2026, 11, 20, 5),
          endsAt: DateTime(2026, 11, 20, 4),
          meetingLat: -6.74,
          meetingLng: 106.99,
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('event-save')));
    await settle(tester);
    expect(find.text('Give the event a title.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('event-title')), 'Gede traverse');
    await tester.tap(find.byKey(const Key('event-save')));
    await settle(tester);
    expect(find.text('The end must be after the start.'), findsOneWidget);
    expect(backend.names, isNot(contains('save_community_event')));
    expect(find.byKey(const Key('event-point')), findsOneWidget);
  });
}
