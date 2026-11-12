import '../../domain/friends/friends.dart';
import '../community/community_repository.dart' show CommunityBackend;

// Friends & Chat over the functions of 20261111000032_friends_chat.sql and
// 20261112000033_chat_groups.sql (the same backend as Community: Supabase RPCs).

List<Map<String, dynamic>> _rows(Object? data) => [
  for (final r in (data is List ? data : const <Object?>[]))
    if (r is Map) Map<String, dynamic>.from(r),
];

typedef FriendLinkCard = ({String name, String? organization, bool isMe});

class FriendsRepository {
  FriendsRepository(this.backend);

  final CommunityBackend backend;

  Future<List<Friend>> friends() async => _rows(await backend.rpc('my_friends', {})).map(Friend.fromRow).toList();

  Future<List<FriendRequest>> requests() async =>
      _rows(await backend.rpc('my_friend_requests', {})).map(FriendRequest.fromRow).toList();

  /// Unread messages (chats and groups) and open requests to me (the badge)
  Future<({int messages, int requests})> unread() async {
    final r = _rows(await backend.rpc('my_chat_unread', {})).firstOrNull ?? const {};
    int n(Object? v) => v is num ? v.toInt() : 0;
    return (messages: n(r['messages']), requests: n(r['requests']));
  }

  /// The same answer whether or not an account uses the email
  Future<void> requestByEmail(String email) => backend.rpc('send_friend_request', {'p_email': email.trim()});

  /// 'sent', or 'friends' when that made (or had made) you friends
  Future<String> requestByLink(String token) async =>
      '${await backend.rpc('request_friend_by_link', {'p_token': token})}';

  Future<FriendLinkCard?> linkCard(String token) async {
    final r = _rows(await backend.rpc('friend_link_info', {'p_token': token})).firstOrNull;
    if (r == null) return null;
    return (name: '${r['name'] ?? ''}', organization: r['organization'] as String?, isMe: r['is_me'] == true);
  }

  Future<void> answer(String requestId, {required bool accept}) =>
      backend.rpc('answer_friend_request', {'p_id': requestId, 'p_accept': accept});

  Future<void> remove(String userId) => backend.rpc('remove_friend', {'p_user_id': userId});

  Future<String> myLink() async => '${await backend.rpc('my_friend_link', {})}';

  Future<String> renewLink() async => '${await backend.rpc('renew_friend_link', {})}';

  // --- Groups ------------------------------------------------------------------------------------

  Future<List<ChatGroup>> groups() async =>
      _rows(await backend.rpc('my_chat_groups', {})).map(ChatGroup.fromRow).toList();

  Future<List<GroupMember>> groupMembers(String groupId) async =>
      _rows(await backend.rpc('chat_group_members', {'p_group': groupId})).map(GroupMember.fromRow).toList();

  /// A new group (Pro and up); returns its id
  Future<String> createGroup(String name) async => '${await backend.rpc('create_chat_group', {'p_name': name.trim()})}';

  /// The club's chat, opened by its leader (the same one when it exists already)
  Future<String> createClubChat(String clubId) async =>
      '${await backend.rpc('create_club_chat', {'p_club_id': clubId})}';

  /// The club chat's id for a member, or null while the leader has not opened one
  Future<String?> clubChatGroup(String clubId) async {
    final id = await backend.rpc('club_chat_group', {'p_club_id': clubId});
    return id == null ? null : '$id';
  }

  /// How many joined (friends of mine who were not in it yet)
  Future<int> addGroupMembers(String groupId, List<String> userIds) async {
    final n = await backend.rpc('add_chat_group_members', {'p_group': groupId, 'p_user_ids': userIds});
    return n is num ? n.toInt() : 0;
  }

  /// Removes a member (the maker), or leaves (any member but the maker)
  Future<void> removeGroupMember(String groupId, String userId) =>
      backend.rpc('remove_chat_group_member', {'p_group': groupId, 'p_user_id': userId});

  Future<void> renameGroup(String groupId, String name) =>
      backend.rpc('rename_chat_group', {'p_group': groupId, 'p_name': name.trim()});

  Future<void> deleteGroup(String groupId) => backend.rpc('delete_chat_group', {'p_group': groupId});

  // --- Messages ----------------------------------------------------------------------------------

  /// A page of the chat before [before] (newest first), or with [since] only what changed after it
  Future<List<ChatMessage>> messages(ChatRef chat, {DateTime? before, DateTime? since}) async => _rows(
    await backend.rpc(chat.group ? 'group_messages' : 'chat_messages', {
      chat.group ? 'p_group' : 'p_with': chat.id,
      'p_before': before?.toUtc().toIso8601String(),
      'p_since': since?.toUtc().toIso8601String(),
    }),
  ).map(ChatMessage.fromRow).toList();

  /// Safe to send again with the same [clientId] (the queue without signal)
  Future<({String id, DateTime createdAt})> send(
    ChatRef chat, {
    required ChatKind kind,
    String? body,
    Map<String, dynamic>? data,
    required String clientId,
    String? replyTo,
  }) async {
    final r = _rows(
      await backend.rpc(chat.group ? 'send_group_message' : 'send_chat_message', {
        chat.group ? 'p_group' : 'p_to': chat.id,
        'p_kind': kind.name,
        'p_body': body,
        'p_data': data,
        'p_client_id': clientId,
        'p_reply_to': replyTo,
      }),
    ).first;
    return (id: '${r['id']}', createdAt: DateTime.parse('${r['created_at']}'));
  }

  Future<void> markRead(ChatRef chat) => chat.group
      ? backend.rpc('mark_group_read', {'p_group': chat.id})
      : backend.rpc('mark_chat_read', {'p_with': chat.id});

  Future<void> deleteMessage(String id) => backend.rpc('delete_chat_message', {'p_id': id});
}
