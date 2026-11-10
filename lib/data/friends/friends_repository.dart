import '../../domain/friends/friends.dart';
import '../community/community_repository.dart' show CommunityBackend;

// Friends & Chat over the functions of 20261111000032_friends_chat.sql (the same backend as
// Community: Supabase RPCs).

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

  /// Unread messages and open requests to me (the badge)
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

  /// A page of the chat before [before] (newest first), or with [since] only what changed after it
  Future<List<ChatMessage>> messages(String friendId, {DateTime? before, DateTime? since}) async => _rows(
    await backend.rpc('chat_messages', {
      'p_with': friendId,
      'p_before': before?.toUtc().toIso8601String(),
      'p_since': since?.toUtc().toIso8601String(),
    }),
  ).map(ChatMessage.fromRow).toList();

  /// Safe to send again with the same [clientId] (the queue without signal)
  Future<({String id, DateTime createdAt})> send(
    String friendId, {
    required ChatKind kind,
    String? body,
    Map<String, dynamic>? data,
    required String clientId,
  }) async {
    final r = _rows(
      await backend.rpc('send_chat_message', {
        'p_to': friendId,
        'p_kind': kind.name,
        'p_body': body,
        'p_data': data,
        'p_client_id': clientId,
      }),
    ).first;
    return (id: '${r['id']}', createdAt: DateTime.parse('${r['created_at']}'));
  }

  Future<void> markRead(String friendId) => backend.rpc('mark_chat_read', {'p_with': friendId});

  Future<void> deleteMessage(String id) => backend.rpc('delete_chat_message', {'p_id': id});
}
