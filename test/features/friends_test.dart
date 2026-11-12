import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:landscape360/core/config/app_config.dart';
import 'package:landscape360/core/providers.dart';
import 'package:landscape360/core/theme/app_theme.dart';
import 'package:landscape360/data/community/community_repository.dart' show CommunityException;
import 'package:landscape360/domain/account/profile.dart';
import 'package:landscape360/domain/friends/friends.dart';
import 'package:landscape360/domain/share/share_location.dart';
import 'package:landscape360/features/community/community_state.dart';
import 'package:landscape360/features/friends/chat_page.dart';
import 'package:landscape360/features/friends/friends_page.dart';
import 'package:landscape360/features/friends/friends_state.dart';
import 'package:landscape360/features/tracks/track_recorder_state.dart' show onlineProvider;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import '../data/community_repository_test.dart' show FakeCommunity;

// Friends & Chat (docs/FRIENDS_PRD.md): the chat model, the friend list and requests, sending
// with and without signal (never twice), changes while a chat is open, the badge, and the pages

const rina = 'aaaaaaaa-0000-4000-8000-00000000000a';
const budi = 'bbbbbbbb-0000-4000-8000-00000000000b';
const token = '0123456789abcdef0123456789abcdef';

Map<String, dynamic> friendRow({String id = budi, String name = 'Budi S.', int unread = 0, String? last}) => {
  'user_id': id,
  'name': name,
  'organization': 'Mapala UI',
  'since': '2026-11-01T00:00:00Z',
  'last_at': last == null ? null : '2026-11-10T08:00:00Z',
  'last_kind': last == null ? null : 'text',
  'last_body': last,
  'last_from_me': false,
  'last_deleted': false,
  'unread': unread,
};

Map<String, dynamic> messageRow(
  String id, {
  bool fromMe = false,
  String kind = 'text',
  String? body = 'halo',
  Map<String, Object>? data,
  String at = '2026-11-10T08:00:00Z',
  String? readAt,
  String? clientId,
  bool deleted = false,
}) => {
  'id': id,
  'from_me': fromMe,
  'kind': kind,
  'body': body,
  'data': data,
  'client_id': clientId,
  'created_at': at,
  'read_at': readAt,
  'deleted': deleted,
  'updated_at': readAt ?? at,
};

Map<String, dynamic> groupRow({
  String id = 'g1',
  String kind = 'group',
  String name = 'Tim Merbabu',
  bool manager = false,
  int members = 3,
  String? last,
  String? sender = 'Budi S.',
  int unread = 0,
}) => {
  'id': id,
  'kind': kind,
  'club_id': kind == 'club' ? 'club1' : null,
  'name': name,
  'is_manager': manager,
  'member_count': members,
  'created_at': '2026-11-05T00:00:00Z',
  'last_at': last == null ? null : '2026-11-10T09:00:00Z',
  'last_kind': last == null ? null : 'text',
  'last_body': last,
  'last_from_me': false,
  'last_sender': sender,
  'last_deleted': false,
  'unread': unread,
};

void main() {
  late FakeCommunity backend;
  late StreamController<bool> online;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    online = StreamController<bool>.broadcast();
    backend = FakeCommunity()
      ..answers['my_friends'] = [friendRow(last: 'Kumpul jam 5', unread: 2)]
      ..answers['my_friend_requests'] = <Object>[]
      ..answers['my_chat_unread'] = [
        {'messages': 2, 'requests': 0},
      ]
      ..answers['chat_messages'] = <Object>[]
      ..answers['my_chat_groups'] = <Object>[]
      ..answers['group_messages'] = <Object>[];
  });
  tearDown(() => online.close());

  List<Override> overrides() => [
    communityBackendProvider.overrideWithValue(backend),
    authUserIdProvider.overrideWith((ref) => Stream.value(rina)),
    onlineProvider.overrideWith((ref) => online.stream),
    profileProvider.overrideWith(
      (ref) async => const AccountProfile(
        userId: rina,
        email: 'rina@x.id',
        displayName: 'Rina W.',
        plan: Plan.free,
        role: UserRole.pengguna360,
        isAdmin: false,
        canUseSos: false,
      ),
    ),
    appConfigProvider.overrideWithValue(
      const AppConfig(
        flavor: 'dev',
        supabaseUrl: 'https://x.supabase.co',
        supabaseAnonKey: 'sb_publishable_x',
        mapboxPublicToken: '',
        apiBaseUrl: 'https://landscape360.jcdigital.co.id',
      ),
    ),
  ];

  Future<ProviderContainer> container() async {
    final c = ProviderContainer(overrides: overrides());
    addTearDown(c.dispose);
    c
      ..listen(authUserIdProvider, (_, _) {})
      ..listen(chatOutboxProvider, (_, _) {})
      ..listen(friendsUnreadProvider, (_, _) {})
      ..listen(onlineProvider, (_, _) {});
    await c.read(authUserIdProvider.future);
    await Future<void>.delayed(Duration.zero);
    return c;
  }

  group('model', () {
    test('a friend row, its preview and initial', () {
      final f = Friend.fromRow(friendRow(last: 'Kumpul\njam 5', unread: 2));
      expect((f.name, f.organization, f.unread, f.preview), ('Budi S.', 'Mapala UI', 2, 'Kumpul jam 5'));
      final mine = Friend.fromRow({...friendRow(last: 'x'), 'last_kind': 'location', 'last_from_me': true});
      expect(mine.preview, 'You: Location');
      expect(Friend.fromRow({...friendRow(last: 'x'), 'last_deleted': true}).preview, 'Message deleted');
      expect(Friend.fromRow(friendRow()).preview, isNull, reason: 'no chat yet');
    });

    test('the server copy replaces a queued one and an older version of itself', () {
      final queued = ChatMessage(
        id: 'c1',
        clientId: 'c1',
        fromMe: true,
        kind: ChatKind.text,
        body: 'halo',
        createdAt: DateTime.utc(2026, 11, 10, 8),
        state: SendState.queued,
      );
      final sent = ChatMessage.fromRow(messageRow('m1', fromMe: true, clientId: 'c1'));
      final merged = mergeMessages([queued], [sent]);
      expect([for (final m in merged) m.id], ['m1']);
      final read = ChatMessage.fromRow(messageRow('m1', fromMe: true, readAt: '2026-11-10T08:05:00Z'));
      expect(mergeMessages(merged, [read]).single.readAt, isNotNull);
      final older = ChatMessage.fromRow(messageRow('m0', at: '2026-11-09T08:00:00Z'));
      expect(
        [
          for (final m in mergeMessages(merged, [older])) m.id,
        ],
        ['m1', 'm0'],
        reason: 'newest first',
      );
    });

    test('a location and map data in a message; delete within the hour', () {
      final loc = ChatMessage.fromRow(
        messageRow('m', kind: 'location', body: null, data: {'lat': -7.45, 'lng': 110.43, 'accuracy': 5}),
      );
      expect((loc.location!.lat, loc.location!.accuracy), (-7.45, 5.0));
      final mine = ChatMessage.fromRow(messageRow('m', fromMe: true));
      expect(mine.canDelete(DateTime.utc(2026, 11, 10, 8, 59)), isTrue);
      expect(mine.canDelete(DateTime.utc(2026, 11, 10, 9, 1)), isFalse);
      expect(
        ChatMessage.fromRow(messageRow('m')).canDelete(DateTime.utc(2026, 11, 10, 8, 1)),
        isFalse,
        reason: 'theirs',
      );
    });

    test('friend links: made and read, also as an incoming link', () {
      final url = friendLinkUrl('https://landscape360.jcdigital.co.id/', token);
      expect(url, 'https://landscape360.jcdigital.co.id/?friend=$token');
      expect(parseFriendParam(Uri.parse(url).query), token);
      expect(parseFriendParam('friend=xyz'), isNull);
      expect(IncomingLink.parse(Uri.parse(url)), isA<FriendLink>().having((l) => l.token, 'token', token));
    });

    test('chat times: today the time, else the date', () {
      final now = DateTime(2026, 11, 10, 18);
      expect(chatTime(DateTime(2026, 11, 10, 8, 5), now), '08:05');
      expect(chatTime(DateTime(2026, 11, 2, 8), now), '2 Nov');
      expect(chatTime(DateTime(2025, 12, 31), now), '31 Dec 2025');
    });

    test('a group row, its preview with the sender, and the chat list with groups in it', () {
      final g = ChatGroup.fromRow(groupRow(last: 'Kumpul\njam 5', unread: 3));
      expect(
        (g.name, g.isClub, g.memberCount, g.unread, g.preview),
        ('Tim Merbabu', false, 3, 3, 'Budi S.: Kumpul jam 5'),
      );
      expect(ChatGroup.fromRow(groupRow(kind: 'club')).isClub, isTrue);
      expect(ChatGroup.fromRow(groupRow()).preview, isNull, reason: 'nothing said yet');
      final friend = Friend.fromRow(friendRow(last: 'halo'));
      final list = chatEntries(
        [friend, Friend.fromRow(friendRow(id: 'x'))],
        [g, ChatGroup.fromRow(groupRow(id: 'g0'))],
      );
      expect(
        [for (final e in list) e.name],
        ['Tim Merbabu', 'Budi S.', 'Tim Merbabu'],
        reason: 'newest first; no chat yet is left out',
      );
      expect(list.first.ref, chatInGroup('g1'));
      expect(list[1].ref, chatWith(budi));
    });

    test('a reply carries a quote, kept in the outbox and the cache', () {
      final row = {
        ...messageRow('m2', fromMe: true, body: 'Siap'),
        'reply_to': 'm1',
        'reply_name': 'Budi S.',
        'reply_kind': 'text',
        'reply_body': 'Kumpul jam 5',
      };
      final m = ChatMessage.fromRow(row);
      expect((m.reply!.id, m.reply!.who, m.reply!.text), ('m1', 'Budi S.', 'Kumpul jam 5'));
      final again = ChatMessage.fromJson(m.toJson());
      expect(again.reply!.id, 'm1');
      expect(ChatMessage.fromRow(messageRow('m3')).reply, isNull);
      final long = ChatMessage.fromRow(messageRow('m4', body: 'x' * 300));
      expect(ChatReply.of(long).body!.length, 120);
      final deleted = ChatReply.fromRow({'reply_to': 'm1', 'reply_deleted': true, 'reply_from_me': true});
      expect((deleted!.who, deleted.text), ('You', 'Message deleted'));
      final inGroup = ChatMessage.fromRow({...messageRow('m5'), 'sender_id': budi, 'sender_name': 'Budi S.'});
      expect(inGroup.senderName, 'Budi S.');
    });
  });

  group('state', () {
    test('the badge reads unread messages and requests', () async {
      final c = await container();
      await c.read(friendsUnreadProvider.notifier).refresh();
      expect(c.read(friendsUnreadProvider), (messages: 2, requests: 0));
    });

    test('friends and requests; accepting reads them again', () async {
      backend.answers['my_friend_requests'] = [
        {'id': 'r1', 'direction': 'in', 'user_id': 'u3', 'name': 'Citra P.', 'created_at': '2026-11-10T00:00:00Z'},
        {'id': 'r2', 'direction': 'out', 'user_id': 'u4', 'name': 'Dodi', 'created_at': '2026-11-10T00:00:00Z'},
      ];
      final c = await container();
      final f = c.read(friendsProvider.notifier);
      await f.refresh();
      expect(c.read(friendsProvider).friends.single.name, 'Budi S.');
      expect([for (final r in c.read(friendsProvider).incoming) r.name], ['Citra P.']);
      expect([for (final r in c.read(friendsProvider).outgoing) r.name], ['Dodi']);
      await f.answer(c.read(friendsProvider).incoming.single, accept: true);
      expect(backend.params('answer_friend_request'), {'p_id': 'r1', 'p_accept': true});
      await f.requestByEmail(' citra@x.id ');
      expect(backend.params('send_friend_request'), {'p_email': 'citra@x.id'});
    });

    test('with signal a message goes at once and joins the chat', () async {
      backend.answers['send_chat_message'] = [
        {'id': 'm9', 'created_at': '2026-11-10T09:00:00Z'},
      ];
      final c = await container();
      await c.read(chatProvider(chatWith(budi)).notifier).send(ChatKind.text, body: '  Kumpul jam 5 ');
      expect(c.read(chatOutboxProvider), isEmpty);
      final p = backend.params('send_chat_message');
      expect((p['p_to'], p['p_kind'], p['p_body']), (budi, 'text', 'Kumpul jam 5'));
      expect(c.read(chatProvider(chatWith(budi))).messages.single.id, 'm9');
    });

    test('without signal it waits on the phone, then goes once, with the same client id', () async {
      backend
        ..offline = true
        ..answers['send_chat_message'] = [
          {'id': 'm9', 'created_at': '2026-11-10T09:00:00Z'},
        ];
      final c = await container();
      await c
          .read(chatProvider(chatWith(budi)).notifier)
          .send(ChatKind.location, data: const ChatLocation(lat: -7.45, lng: 110.43).toJson());
      final waiting = c.read(chatOutboxProvider).single;
      expect(waiting.message.state, SendState.queued);
      final stored = await SharedPreferencesAsync().getString(chatOutboxKey(rina));
      expect(stored, contains(waiting.message.id), reason: 'kept across app restarts');

      backend.offline = false;
      online.add(true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(c.read(chatOutboxProvider), isEmpty);
      expect(backend.params('send_chat_message')['p_client_id'], waiting.message.id);
      expect(backend.names.where((n) => n == 'send_chat_message'), hasLength(1));
    });

    test('a refusal is kept with its reason; try again or do not send', () async {
      backend.fail['send_chat_message'] = const CommunityException('You can only message your friends');
      final c = await container();
      await c.read(chatProvider(chatWith(budi)).notifier).send(ChatKind.text, body: 'halo');
      final failed = c.read(chatOutboxProvider).single.message;
      expect((failed.state, failed.error), (SendState.failed, 'You can only message your friends'));
      await c.read(chatOutboxProvider.notifier).discard(failed.id);
      expect(c.read(chatOutboxProvider), isEmpty);
    });

    test('an open chat reads the page, marks it read, then asks only for changes', () async {
      backend.answers['chat_messages'] = [messageRow('m2', at: '2026-11-10T08:01:00Z'), messageRow('m1')];
      final c = await container();
      final chat = c.read(chatProvider(chatWith(budi)).notifier);
      await chat.open();
      addTearDown(chat.close);
      expect([for (final m in c.read(chatProvider(chatWith(budi))).messages) m.id], ['m2', 'm1']);
      expect(backend.params('mark_chat_read'), {'p_with': budi});

      backend.answers['chat_messages'] = [messageRow('m3', at: '2026-11-10T08:02:00Z')];
      await chat.poll();
      expect(backend.params('chat_messages')['p_since'], '2026-11-10T08:01:00.000Z');
      expect([for (final m in c.read(chatProvider(chatWith(budi))).messages) m.id], ['m3', 'm2', 'm1']);
    });

    test('a group: made with friends, read with its own functions, a reply sent along', () async {
      backend
        ..answers['create_chat_group'] = 'g1'
        ..answers['add_chat_group_members'] = 2
        ..answers['my_chat_groups'] = [groupRow(manager: true)]
        ..answers['group_messages'] = [
          {...messageRow('m1'), 'sender_id': budi, 'sender_name': 'Budi S.'},
        ]
        ..answers['send_group_message'] = [
          {'id': 'm2', 'created_at': '2026-11-10T09:00:00Z'},
        ];
      final c = await container();
      final id = await c.read(friendsProvider.notifier).createGroup(' Tim Merbabu ', [budi, 'u3']);
      expect(id, 'g1');
      expect(backend.params('create_chat_group'), {'p_name': 'Tim Merbabu'});
      expect(backend.params('add_chat_group_members'), {
        'p_group': 'g1',
        'p_user_ids': [budi, 'u3'],
      });
      expect(c.read(friendsProvider).groups.single.isManager, isTrue);
      expect(
        [for (final e in c.read(friendsProvider).chats) e.name],
        ['Budi S.', 'Tim Merbabu'],
        reason: 'listed without a message',
      );

      final chat = c.read(chatProvider(chatInGroup('g1')).notifier);
      await chat.open();
      addTearDown(chat.close);
      final got = c.read(chatProvider(chatInGroup('g1'))).messages.single;
      expect((got.senderName, got.fromMe), ('Budi S.', false));
      expect(backend.params('group_messages')['p_group'], 'g1');
      expect(backend.params('mark_group_read'), {'p_group': 'g1'});

      await chat.send(ChatKind.text, body: 'Siap', reply: ChatReply.of(got));
      final p = backend.params('send_group_message');
      expect((p['p_group'], p['p_body'], p['p_reply_to']), ('g1', 'Siap', 'm1'));
      expect(c.read(chatProvider(chatInGroup('g1'))).messages.first.reply!.who, 'Budi S.');
      expect(backend.names, isNot(contains('send_chat_message')));
    });
  });

  group('pages', () {
    Future<ProviderContainer> pump(WidgetTester tester, Widget page) async {
      final c = ProviderContainer(overrides: overrides());
      addTearDown(c.dispose);
      c
        ..listen(authUserIdProvider, (_, _) {})
        ..listen(profileProvider, (_, _) {})
        ..listen(chatOutboxProvider, (_, _) {});
      await c.read(authUserIdProvider.future);
      await tester.binding.setSurfaceSize(const Size(420, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: buildAppTheme(), home: page),
        ),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      return c;
    }

    Future<void> done(WidgetTester tester, ProviderContainer c) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('Friends: chats with unread counts, a request to accept', (tester) async {
      backend.answers['my_friend_requests'] = [
        {'id': 'r1', 'direction': 'in', 'user_id': 'u3', 'name': 'Citra P.', 'created_at': '2026-11-10T00:00:00Z'},
      ];
      final c = await pump(tester, const FriendsPage());
      expect(find.text('Budi S.'), findsOneWidget);
      expect(find.text('Kumpul jam 5'), findsOneWidget);
      expect(find.text('2'), findsOneWidget, reason: 'unread');
      expect(find.byKey(const Key('friends-request-dot')), findsOneWidget, reason: 'one request');

      await tester.tap(find.byKey(const Key('friends-tab-friends')));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.tap(find.byKey(const Key('request-accept-r1')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(backend.params('answer_friend_request'), {'p_id': 'r1', 'p_accept': true});
      await done(tester, c);
    });

    testWidgets('Add friend by email says the same whether or not the account exists', (tester) async {
      final c = await pump(tester, const FriendsPage());
      await tester.tap(find.byKey(const Key('friends-add')));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.enterText(find.byKey(const Key('add-friend-email')), 'someone@x.id');
      await tester.tap(find.byKey(const Key('add-friend-send')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Request sent if a Landscape 360 account uses someone@x.id.'), findsOneWidget);
      await done(tester, c);
    });

    testWidgets('a chat: messages, Read under mine, sending, map data locked on Free', (tester) async {
      backend
        ..answers['chat_messages'] = [
          messageRow(
            'm2',
            fromMe: true,
            body: 'Kumpul jam 5',
            at: '2026-11-10T08:01:00Z',
            readAt: '2026-11-10T08:02:00Z',
          ),
          messageRow('m1', kind: 'location', body: null, data: {'lat': -7.45, 'lng': 110.43}),
        ]
        ..answers['send_chat_message'] = [
          {'id': 'm3', 'created_at': '2026-11-10T09:00:00Z'},
        ];
      final c = await pump(tester, ChatPage(chat: chatWith(budi), name: 'Budi S.'));
      expect(find.text('Kumpul jam 5'), findsOneWidget);
      expect(find.text('LOCATION'), findsOneWidget);
      expect(find.text('Show on map'), findsOneWidget);
      expect(find.byKey(const Key('chat-read')), findsOneWidget);

      await tester.enterText(find.byKey(const Key('chat-input')), 'Siap');
      await tester.pump();
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(backend.params('send_chat_message')['p_body'], 'Siap');
      expect(find.text('Siap'), findsOneWidget);

      await tester.tap(find.byKey(const Key('chat-more')));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('For Pro and Enterprise accounts'), findsOneWidget);
      expect(tester.widget<ListTile>(find.byKey(const Key('chat-send-map'))).enabled, isFalse);
      await done(tester, c);
    });

    testWidgets('a group chat: who sent what, a quoted reply, replying from the menu, the members', (tester) async {
      backend
        ..answers['my_chat_groups'] = [groupRow(last: 'Siap', unread: 1)]
        ..answers['group_messages'] = [
          {
            ...messageRow('m2', body: 'Siap, jam 5 di basecamp', at: '2026-11-10T08:01:00Z'),
            'sender_id': 'u3',
            'sender_name': 'Citra P.',
            'reply_to': 'm1',
            'reply_name': 'Budi S.',
            'reply_kind': 'text',
            'reply_body': 'Kumpul jam 5',
          },
          {...messageRow('m1', body: 'Kumpul jam 5'), 'sender_id': budi, 'sender_name': 'Budi S.'},
        ]
        ..answers['chat_group_members'] = [
          {'user_id': rina, 'name': 'Rina W.', 'is_me': true, 'since': '2026-11-05T00:00:00Z'},
          {
            'user_id': budi,
            'name': 'Budi S.',
            'is_manager': true,
            'organization': 'Mapala UI',
            'since': '2026-11-05T00:00:00Z',
          },
        ]
        ..answers['send_group_message'] = [
          {'id': 'm3', 'created_at': '2026-11-10T09:00:00Z'},
        ];
      final c = await pump(tester, ChatPage(chat: chatInGroup('g1'), name: 'Tim Merbabu'));
      expect(find.byKey(const Key('sender-m1')), findsOneWidget, reason: "Budi's name above his message");
      expect(find.byKey(const Key('sender-m2')), findsOneWidget);
      expect(find.byKey(const Key('quote-m1')), findsOneWidget, reason: 'the reply quotes Budi');
      expect(find.text('Kumpul jam 5'), findsNWidgets(2), reason: 'the message and its quote');
      expect(find.textContaining('3 members'), findsOneWidget);

      await tester.longPress(find.byKey(const Key('message-m2')));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byKey(const Key('chat-delete')), findsNothing, reason: 'not mine, not the maker');
      await tester.tap(find.byKey(const Key('chat-reply')));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byKey(const Key('chat-reply-bar')), findsOneWidget);
      expect(find.text('Replying to Citra P.'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('chat-input')), 'Oke');
      await tester.pump();
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(backend.params('send_group_message')['p_reply_to'], 'm2');
      expect(find.byKey(const Key('chat-reply-bar')), findsNothing, reason: 'sent: the bar goes');
      expect(find.byKey(const Key('quote-m2')), findsOneWidget, reason: 'my reply shows its quote at once');

      await tester.tap(find.byKey(const Key('chat-members')));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byKey(const Key('member-$budi')), findsOneWidget);
      expect(find.text('Maker'), findsOneWidget);
      expect(find.byKey(const Key('group-add-members')), findsNothing, reason: 'only the maker adds');
      await done(tester, c);
    });

    testWidgets('Friends: my groups are listed; making one is for Pro and up', (tester) async {
      backend.answers['my_chat_groups'] = [groupRow(kind: 'club', name: 'SAR Magelang', members: 12)];
      final c = await pump(tester, const FriendsPage());
      expect(find.text('SAR Magelang'), findsOneWidget, reason: 'in Chats too');
      await tester.tap(find.byKey(const Key('friends-tab-friends')));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byKey(const Key('group-g1')), findsOneWidget);
      expect(find.textContaining('Club chat · 12 members'), findsOneWidget);
      await tester.tap(find.byKey(const Key('group-create')));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byKey(const Key('group-pro-note')), findsOneWidget, reason: 'Free account');
      expect(find.byKey(const Key('group-save')), findsNothing);
      await done(tester, c);
    });
  });
}
