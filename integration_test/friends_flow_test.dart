// Friends & Chat on a simulator, with the server in memory (nothing reaches real accounts): the
// chat list, a chat with text, a location and a track, a group chat with a reply, My QR, and a
// friend link's card. Prints "SHOT:<name>" at each scene.
//   flutter test integration_test/friends_flow_test.dart -d <simulator> --dart-define-from-file=config/dev.json
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:landscape360/core/config/app_config.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/core/theme/app_theme.dart';
import 'package:landscape360/data/community/community_repository.dart';
import 'package:landscape360/domain/account/profile.dart';
import 'package:landscape360/features/community/community_state.dart';
import 'package:landscape360/features/friends/chat_page.dart';
import 'package:landscape360/features/friends/friends_page.dart';

const _budi = 'bbbbbbbb-0000-4000-8000-00000000000b';
const _token = '0123456789abcdef0123456789abcdef';
const _group = '22222222-0000-4000-8000-000000000002';

String _ago(Duration d) => DateTime.now().toUtc().subtract(d).toIso8601String();

class _Server implements CommunityBackend {
  @override
  Future<Object?> rpc(String fn, Map<String, dynamic> p) async => switch (fn) {
    'my_friends' => [
      {
        'user_id': _budi,
        'name': 'Budi S.',
        'organization': 'Mapala Merbabu',
        'since': _ago(const Duration(days: 9)),
        'last_at': _ago(const Duration(minutes: 3)),
        'last_kind': 'location',
        'last_from_me': false,
        'unread': 2,
      },
      {
        'user_id': 'c',
        'name': 'Citra P.',
        'since': _ago(const Duration(days: 4)),
        'last_at': _ago(const Duration(days: 2)),
        'last_kind': 'text',
        'last_body': 'Track Sindoro sudah saya kirim ya',
        'last_from_me': true,
        'unread': 0,
      },
      {'user_id': 'd', 'name': 'Dodi R.', 'since': _ago(const Duration(days: 1)), 'unread': 0},
    ],
    'my_friend_requests' => [
      {
        'id': 'r1',
        'direction': 'in',
        'user_id': 'e',
        'name': 'Eka N.',
        'organization': 'SAR Magelang',
        'created_at': _ago(const Duration(hours: 5)),
      },
    ],
    'my_chat_unread' => [
      {'messages': 2, 'requests': 1},
    ],
    'chat_messages' =>
      p['p_since'] != null
          ? <Object>[]
          : [
              {
                'id': 'm4',
                'from_me': false,
                'kind': 'location',
                'data': {'lat': -7.4547, 'lng': 110.4398, 'accuracy': 6, 'elevation': 3142},
                'created_at': _ago(const Duration(minutes: 3)),
                'deleted': false,
                'updated_at': _ago(const Duration(minutes: 3)),
              },
              {
                'id': 'm3',
                'from_me': false,
                'kind': 'text',
                'body': 'Saya sudah di puncak Kenteng Songo 🙌',
                'created_at': _ago(const Duration(minutes: 4)),
                'deleted': false,
                'updated_at': _ago(const Duration(minutes: 4)),
              },
              {
                'id': 'm2',
                'from_me': true,
                'kind': 'attachment',
                'data': {
                  'kind': 'track',
                  'name': 'Merbabu via Selo',
                  'distance_m': 4020,
                  'geometry': {
                    'type': 'LineString',
                    'coordinates': [
                      [110.4399, -7.4868],
                      [110.4398, -7.4547],
                    ],
                  },
                },
                'created_at': _ago(const Duration(minutes: 40)),
                'read_at': _ago(const Duration(minutes: 30)),
                'deleted': false,
                'updated_at': _ago(const Duration(minutes: 30)),
              },
              {
                'id': 'm1',
                'from_me': true,
                'kind': 'text',
                'body': 'Kumpul di basecamp Selo jam 5 pagi ya. Ini jalurnya:',
                'created_at': _ago(const Duration(minutes: 41)),
                'read_at': _ago(const Duration(minutes: 30)),
                'deleted': false,
                'updated_at': _ago(const Duration(minutes: 30)),
              },
            ],
    'my_chat_groups' => [
      {
        'id': _group,
        'kind': 'club',
        'club_id': 'club1',
        'name': 'SAR Magelang',
        'is_manager': false,
        'member_count': 12,
        'created_at': _ago(const Duration(days: 20)),
        'last_at': _ago(const Duration(minutes: 1)),
        'last_kind': 'text',
        'last_body': 'Oke, saya bawa tali 50 m',
        'last_from_me': false,
        'last_sender': 'Eka N.',
        'last_deleted': false,
        'unread': 3,
      },
    ],
    'group_messages' =>
      p['p_since'] != null
          ? <Object>[]
          : [
              {
                'id': 'g4',
                'from_me': false,
                'sender_id': 'e',
                'sender_name': 'Eka N.',
                'kind': 'text',
                'body': 'Oke, saya bawa tali 50 m',
                'reply_to': 'g2',
                'reply_from_me': true,
                'reply_name': 'Rina W.',
                'reply_kind': 'text',
                'reply_body': 'Siapa yang bawa tali?',
                'created_at': _ago(const Duration(minutes: 1)),
                'deleted': false,
                'updated_at': _ago(const Duration(minutes: 1)),
              },
              {
                'id': 'g3',
                'from_me': false,
                'sender_id': 'c',
                'sender_name': 'Citra P.',
                'kind': 'location',
                'data': {'lat': -7.4701, 'lng': 110.2175, 'accuracy': 8, 'elevation': 1240},
                'created_at': _ago(const Duration(minutes: 6)),
                'deleted': false,
                'updated_at': _ago(const Duration(minutes: 6)),
              },
              {
                'id': 'g2',
                'from_me': true,
                'kind': 'text',
                'body': 'Siapa yang bawa tali?',
                'created_at': _ago(const Duration(minutes: 12)),
                'deleted': false,
                'updated_at': _ago(const Duration(minutes: 12)),
              },
              {
                'id': 'g1',
                'from_me': false,
                'sender_id': 'c',
                'sender_name': 'Citra P.',
                'kind': 'text',
                'body': 'Briefing jam 7 di posko, bawa perlengkapan lengkap ya',
                'created_at': _ago(const Duration(minutes: 15)),
                'deleted': false,
                'updated_at': _ago(const Duration(minutes: 15)),
              },
            ],
    'chat_group_members' => [
      {
        'user_id': 'c',
        'name': 'Citra P.',
        'organization': 'SAR Magelang',
        'is_manager': true,
        'since': _ago(const Duration(days: 20)),
      },
      {'user_id': 'a', 'name': 'Rina W.', 'is_me': true, 'since': _ago(const Duration(days: 19))},
      {'user_id': 'e', 'name': 'Eka N.', 'organization': 'SAR Magelang', 'since': _ago(const Duration(days: 18))},
    ],
    'mark_group_read' => null,
    'my_friend_link' => _token,
    'friend_link_info' => [
      {'name': 'Fajar K.', 'organization': 'Mapala UI', 'is_me': false},
    ],
    'mark_chat_read' => null,
    _ => null,
  };

  @override
  Future<void> upload(String path, Uint8List bytes) async {}

  @override
  Future<void> remove(List<String> paths) async {}
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final config = AppConfig.fromEnvironment();

  Future<void> wait(WidgetTester tester, int ms) async {
    for (var i = 0; i < ms ~/ 100; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> shot(WidgetTester tester, String name) async {
    await wait(tester, 1500);
    debugPrint('SHOT:$name');
    await wait(tester, 3000);
  }

  testWidgets('Friends & Chat pages', (tester) async {
    final nav = GlobalKey<NavigatorState>();
    final c = ProviderContainer(
      overrides: [
        appConfigProvider.overrideWithValue(config),
        communityBackendProvider.overrideWithValue(_Server()),
        authUserIdProvider.overrideWith((ref) => Stream.value('aaaaaaaa-0000-4000-8000-00000000000a')),
        profileProvider.overrideWith(
          (ref) async => const AccountProfile(
            userId: 'a',
            email: 'rina@landscape360.app',
            displayName: 'Rina Wulandari',
            plan: Plan.pro,
            role: UserRole.pengguna360,
            isAdmin: false,
            canUseSos: false,
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          navigatorKey: nav,
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(),
          home: const FriendsPage(),
        ),
      ),
    );
    await wait(tester, 1500);
    expect(find.text('Budi S.'), findsOneWidget);
    await shot(tester, 'friends1_chats');

    await tester.tap(find.byKey(const Key('friends-tab-friends')));
    await shot(tester, 'friends2_list');

    await tester.tap(find.byKey(const Key('friends-tab-chats')));
    await wait(tester, 500);
    await tester.tap(find.byKey(const Key('chat-$_budi')));
    await wait(tester, 1500);
    expect(find.byType(ChatPage), findsOneWidget);
    expect(find.text('Merbabu via Selo'), findsOneWidget);
    await shot(tester, 'friends3_chat');
    nav.currentState!.pop();
    await wait(tester, 800);

    await tester.tap(find.byKey(const Key('chat-$_group')));
    await wait(tester, 1500);
    expect(find.text('Eka N.'), findsWidgets);
    await shot(tester, 'friends6_group');
    await tester.longPress(find.byKey(const Key('message-g1')));
    await wait(tester, 600);
    await tester.tap(find.byKey(const Key('chat-reply')));
    await wait(tester, 600);
    await tester.enterText(find.byKey(const Key('chat-input')), 'Siap, saya bawa P3K');
    await wait(tester, 400);
    await shot(tester, 'friends7_reply');
    await tester.tap(find.byKey(const Key('chat-members')));
    await wait(tester, 1200);
    await shot(tester, 'friends8_members');
    nav.currentState!.pop();
    await wait(tester, 400);
    nav.currentState!.pop();
    await wait(tester, 800);

    await tester.tap(find.byKey(const Key('friends-add')));
    await wait(tester, 800);
    await tester.tap(find.byKey(const Key('add-friend-my-qr')));
    await wait(tester, 1500);
    expect(find.byKey(const Key('my-friend-qr')), findsOneWidget);
    await shot(tester, 'friends4_my_qr');
    nav.currentState!.pop();
    nav.currentState!.pop();
    await wait(tester, 800);

    await openFriendLink(nav.currentContext!, _token);
    await wait(tester, 1500);
    expect(find.text('Fajar K.'), findsOneWidget);
    await shot(tester, 'friends5_link_card');
  });
}
