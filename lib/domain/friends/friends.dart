import '../community/community_attachments.dart';

// Friends & Chat (docs/FRIENDS_PRD.md, 20261111000032_friends_chat.sql and
// 20261112000033_chat_groups.sql): friends added by email or by a personal link / QR
// (/?friend=<token>), requests, one-to-one chat that is not real time, groups (a club's chat
// opened by its leader, or a group a Pro account makes from its friends), and replies. A message
// is text, my location (one fix, never live), or a copy of a map item (Pro and up).

DateTime _time(Object? v) => DateTime.tryParse('${v ?? ''}') ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

DateTime? _timeOrNull(Object? v) => v == null ? null : DateTime.tryParse('$v');

int _int(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;

double? _double(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}');

String? _text(Object? v) => v is String && v.trim().isNotEmpty ? v : null;

/// Server limits
const chatBodyMax = 2000;
const groupNameMax = 60;

/// Messages can be taken back this long after sending
const chatDeleteWindow = Duration(hours: 1);

enum ChatKind {
  text,
  location,
  attachment;

  static ChatKind parse(Object? v) => values.firstWhere((k) => k.name == v, orElse: () => text);
}

/// Which chat: with a friend (their user id) or a group (its id)
typedef ChatRef = ({bool group, String id});

ChatRef chatWith(String friendId) => (group: false, id: friendId);
ChatRef chatInGroup(String groupId) => (group: true, id: groupId);

/// The last message in one line, as in a chat list ("You: Location", "Budi S.: Map data")
String? _preview({
  required ChatKind? kind,
  required String? body,
  required bool fromMe,
  required bool deleted,
  String? sender,
}) {
  if (kind == null) return null;
  final what = deleted
      ? 'Message deleted'
      : switch (kind) {
          ChatKind.text => (body ?? '').replaceAll('\n', ' '),
          ChatKind.location => 'Location',
          ChatKind.attachment => 'Map data',
        };
  if (fromMe) return 'You: $what';
  return sender == null ? what : '$sender: $what';
}

class Friend {
  const Friend({
    required this.userId,
    required this.name,
    this.organization,
    required this.since,
    this.lastAt,
    this.lastKind,
    this.lastBody,
    this.lastFromMe = false,
    this.lastDeleted = false,
    this.unread = 0,
  });

  factory Friend.fromRow(Map<String, dynamic> r) => Friend(
    userId: '${r['user_id']}',
    name: '${r['name'] ?? ''}',
    organization: _text(r['organization']),
    since: _time(r['since']),
    lastAt: _timeOrNull(r['last_at']),
    lastKind: r['last_kind'] == null ? null : ChatKind.parse(r['last_kind']),
    lastBody: r['last_body'] as String?,
    lastFromMe: r['last_from_me'] == true,
    lastDeleted: r['last_deleted'] == true,
    unread: _int(r['unread']),
  );

  final String userId;
  final String name;
  final String? organization;
  final DateTime since;
  final DateTime? lastAt;
  final ChatKind? lastKind;
  final String? lastBody;
  final bool lastFromMe;
  final bool lastDeleted;
  final int unread;

  String get initial => name.trim().isEmpty ? '?' : name.trim().characters.first.toUpperCase();

  String? get preview => _preview(kind: lastKind, body: lastBody, fromMe: lastFromMe, deleted: lastDeleted);

  Map<String, Object?> toRow() => {
    'user_id': userId,
    'name': name,
    'organization': organization,
    'since': since.toUtc().toIso8601String(),
    'last_at': lastAt?.toUtc().toIso8601String(),
    'last_kind': lastKind?.name,
    'last_body': lastBody,
    'last_from_me': lastFromMe,
    'last_deleted': lastDeleted,
    'unread': unread,
  };
}

extension on String {
  Iterable<String> get characters => runes.map(String.fromCharCode);
}

enum RequestDirection { incoming, outgoing }

class FriendRequest {
  const FriendRequest({
    required this.id,
    required this.direction,
    required this.userId,
    required this.name,
    this.organization,
    required this.createdAt,
  });

  factory FriendRequest.fromRow(Map<String, dynamic> r) => FriendRequest(
    id: '${r['id']}',
    direction: r['direction'] == 'in' ? RequestDirection.incoming : RequestDirection.outgoing,
    userId: '${r['user_id']}',
    name: '${r['name'] ?? ''}',
    organization: _text(r['organization']),
    createdAt: _time(r['created_at']),
  );

  final String id;
  final RequestDirection direction;
  final String userId;
  final String name;
  final String? organization;
  final DateTime createdAt;
}

// --- Groups --------------------------------------------------------------------------------------

/// A club's chat (its members are the club's) or a group made from friends
enum GroupKind {
  club,
  group;

  static GroupKind parse(Object? v) => v == 'club' ? club : group;
}

class ChatGroup {
  const ChatGroup({
    required this.id,
    required this.kind,
    this.clubId,
    required this.name,
    this.isManager = false,
    this.memberCount = 0,
    required this.createdAt,
    this.lastAt,
    this.lastKind,
    this.lastBody,
    this.lastFromMe = false,
    this.lastSender,
    this.lastDeleted = false,
    this.unread = 0,
  });

  factory ChatGroup.fromRow(Map<String, dynamic> r) => ChatGroup(
    id: '${r['id']}',
    kind: GroupKind.parse(r['kind']),
    clubId: r['club_id'] as String?,
    name: '${r['name'] ?? ''}',
    isManager: r['is_manager'] == true,
    memberCount: _int(r['member_count']),
    createdAt: _time(r['created_at']),
    lastAt: _timeOrNull(r['last_at']),
    lastKind: r['last_kind'] == null ? null : ChatKind.parse(r['last_kind']),
    lastBody: r['last_body'] as String?,
    lastFromMe: r['last_from_me'] == true,
    lastSender: _text(r['last_sender']),
    lastDeleted: r['last_deleted'] == true,
    unread: _int(r['unread']),
  );

  final String id;
  final GroupKind kind;
  final String? clubId;
  final String name;

  /// I made it (or lead the club): I add and remove members, rename, delete, and tidy messages
  final bool isManager;
  final int memberCount;
  final DateTime createdAt;
  final DateTime? lastAt;
  final ChatKind? lastKind;
  final String? lastBody;
  final bool lastFromMe;
  final String? lastSender;
  final bool lastDeleted;
  final int unread;

  bool get isClub => kind == GroupKind.club;

  String? get preview =>
      _preview(kind: lastKind, body: lastBody, fromMe: lastFromMe, deleted: lastDeleted, sender: lastSender);

  Map<String, Object?> toRow() => {
    'id': id,
    'kind': kind.name,
    'club_id': clubId,
    'name': name,
    'is_manager': isManager,
    'member_count': memberCount,
    'created_at': createdAt.toUtc().toIso8601String(),
    'last_at': lastAt?.toUtc().toIso8601String(),
    'last_kind': lastKind?.name,
    'last_body': lastBody,
    'last_from_me': lastFromMe,
    'last_sender': lastSender,
    'last_deleted': lastDeleted,
    'unread': unread,
  };
}

class GroupMember {
  const GroupMember({
    required this.userId,
    required this.name,
    this.organization,
    this.isManager = false,
    this.isMe = false,
    this.isFriend = false,
    required this.since,
  });

  factory GroupMember.fromRow(Map<String, dynamic> r) => GroupMember(
    userId: '${r['user_id']}',
    name: '${r['name'] ?? ''}',
    organization: _text(r['organization']),
    isManager: r['is_manager'] == true,
    isMe: r['is_me'] == true,
    isFriend: r['is_friend'] == true,
    since: _time(r['since']),
  );

  final String userId;
  final String name;
  final String? organization;
  final bool isManager;
  final bool isMe;
  final bool isFriend;
  final DateTime since;
}

/// One row of the chat list: a friend's chat or a group, whichever spoke last
class ChatEntry {
  ChatEntry.friend(Friend f) : ref = chatWith(f.userId), friend = f, group = null;

  ChatEntry.group(ChatGroup g) : ref = chatInGroup(g.id), friend = null, group = g;

  final ChatRef ref;
  final Friend? friend;
  final ChatGroup? group;

  String get name => friend?.name ?? group!.name;
  DateTime? get lastAt => friend?.lastAt ?? group?.lastAt;
  ChatKind? get lastKind => friend?.lastKind ?? group?.lastKind;
  bool get lastFromMe => friend?.lastFromMe ?? group!.lastFromMe;
  bool get lastDeleted => friend?.lastDeleted ?? group!.lastDeleted;
  int get unread => friend?.unread ?? group!.unread;
  String? get preview => friend?.preview ?? group!.preview;
}

/// Friends with a chat and groups together, the most recent first
List<ChatEntry> chatEntries(List<Friend> friends, List<ChatGroup> groups) =>
    [
      for (final f in friends)
        if (f.lastAt != null) ChatEntry.friend(f),
      for (final g in groups) ChatEntry.group(g),
    ]..sort((a, b) {
      final x = a.lastAt ?? a.group!.createdAt, y = b.lastAt ?? b.group!.createdAt;
      return y.compareTo(x);
    });

// --- Messages ------------------------------------------------------------------------------------

/// One point sent with "Send my location"
class ChatLocation {
  const ChatLocation({required this.lat, required this.lng, this.accuracy, this.elevation});

  factory ChatLocation.fromJson(Map<String, dynamic> j) => ChatLocation(
    lat: _double(j['lat']) ?? 0,
    lng: _double(j['lng']) ?? 0,
    accuracy: _double(j['accuracy']),
    elevation: _double(j['elevation']),
  );

  final double lat;
  final double lng;
  final double? accuracy;
  final double? elevation;

  Map<String, Object> toJson() => {
    'lat': (lat * 1e6).round() / 1e6,
    'lng': (lng * 1e6).round() / 1e6,
    if (accuracy != null) 'accuracy': accuracy!.roundToDouble(),
    if (elevation != null) 'elevation': elevation!.roundToDouble(),
  };
}

/// The quote a reply carries: whose message it answers and its first words
class ChatReply {
  const ChatReply({
    required this.id,
    this.fromMe = false,
    this.name,
    this.kind = ChatKind.text,
    this.body,
    this.deleted = false,
  });

  factory ChatReply.fromJson(Map<String, dynamic> j) => ChatReply(
    id: '${j['id']}',
    fromMe: j['fromMe'] == true,
    name: _text(j['name']),
    kind: ChatKind.parse(j['kind']),
    body: j['body'] as String?,
    deleted: j['deleted'] == true,
  );

  /// From a message row (reply_to, reply_from_me, …), or null when it is not a reply
  static ChatReply? fromRow(Map<String, dynamic> r) => r['reply_to'] == null
      ? null
      : ChatReply(
          id: '${r['reply_to']}',
          fromMe: r['reply_from_me'] == true,
          name: _text(r['reply_name']),
          kind: ChatKind.parse(r['reply_kind']),
          body: r['reply_body'] as String?,
          deleted: r['reply_deleted'] == true,
        );

  /// Made on the phone when replying (before the server answers)
  factory ChatReply.of(ChatMessage m, {String? myName}) => ChatReply(
    id: m.id,
    fromMe: m.fromMe,
    name: m.fromMe ? myName : m.senderName,
    kind: m.kind,
    body: m.body?.substring(0, m.body!.length > 120 ? 120 : m.body!.length),
    deleted: m.deleted,
  );

  final String id;
  final bool fromMe;
  final String? name;
  final ChatKind kind;
  final String? body;
  final bool deleted;

  String get who => fromMe ? 'You' : (name ?? 'Friend');

  String get text => deleted
      ? 'Message deleted'
      : switch (kind) {
          ChatKind.text => (body ?? '').replaceAll('\n', ' '),
          ChatKind.location => 'Location',
          ChatKind.attachment => 'Map data',
        };

  Map<String, Object?> toJson() => {
    'id': id,
    'fromMe': fromMe,
    'name': name,
    'kind': kind.name,
    'body': body,
    'deleted': deleted,
  };
}

enum SendState { queued, sent, failed }

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.clientId,
    required this.fromMe,
    this.senderId,
    this.senderName,
    required this.kind,
    this.body,
    this.data,
    this.reply,
    required this.createdAt,
    this.readAt,
    this.deleted = false,
    this.updatedAt,
    this.state = SendState.sent,
    this.error,
  });

  factory ChatMessage.fromRow(Map<String, dynamic> r) => ChatMessage(
    id: '${r['id']}',
    clientId: r['client_id'] as String?,
    fromMe: r['from_me'] == true,
    senderId: r['sender_id'] as String?,
    senderName: _text(r['sender_name']),
    kind: ChatKind.parse(r['kind']),
    body: r['body'] as String?,
    data: r['data'] is Map ? Map<String, dynamic>.from(r['data'] as Map) : null,
    reply: ChatReply.fromRow(r),
    createdAt: _time(r['created_at']),
    readAt: _timeOrNull(r['read_at']),
    deleted: r['deleted'] == true,
    updatedAt: _timeOrNull(r['updated_at']),
  );

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
    id: '${j['id']}',
    clientId: j['clientId'] as String?,
    fromMe: j['fromMe'] == true,
    senderId: j['senderId'] as String?,
    senderName: _text(j['senderName']),
    kind: ChatKind.parse(j['kind']),
    body: j['body'] as String?,
    data: j['data'] is Map ? Map<String, dynamic>.from(j['data'] as Map) : null,
    reply: j['reply'] is Map ? ChatReply.fromJson(Map<String, dynamic>.from(j['reply'] as Map)) : null,
    createdAt: _time(j['createdAt']),
    readAt: _timeOrNull(j['readAt']),
    deleted: j['deleted'] == true,
    updatedAt: _timeOrNull(j['updatedAt']),
    state: SendState.values.firstWhere((s) => s.name == j['state'], orElse: () => SendState.sent),
    error: j['error'] as String?,
  );

  /// The server's id, or the client id while it waits to be sent
  final String id;
  final String? clientId;
  final bool fromMe;

  /// Who sent it, in a group (null in a chat with a friend, and for my own)
  final String? senderId;
  final String? senderName;
  final ChatKind kind;
  final String? body;
  final Map<String, dynamic>? data;
  final ChatReply? reply;
  final DateTime createdAt;
  final DateTime? readAt;
  final bool deleted;
  final DateTime? updatedAt;
  final SendState state;
  final String? error;

  ChatLocation? get location => kind == ChatKind.location && data != null ? ChatLocation.fromJson(data!) : null;
  Attachment? get attachment => kind == ChatKind.attachment && data != null ? Attachment.fromJson(data!) : null;

  /// Still within the hour in which the sender may delete it
  bool canDelete(DateTime now) =>
      fromMe && !deleted && state == SendState.sent && now.difference(createdAt) < chatDeleteWindow;

  Map<String, Object?> toJson() => {
    'id': id,
    'clientId': clientId,
    'fromMe': fromMe,
    'senderId': senderId,
    'senderName': senderName,
    'kind': kind.name,
    'body': body,
    'data': data,
    'reply': reply?.toJson(),
    'createdAt': createdAt.toUtc().toIso8601String(),
    'readAt': readAt?.toUtc().toIso8601String(),
    'deleted': deleted,
    'updatedAt': updatedAt?.toUtc().toIso8601String(),
    'state': state.name,
    'error': error,
  };

  ChatMessage copyWith({SendState? state, String? Function()? error}) => ChatMessage(
    id: id,
    clientId: clientId,
    fromMe: fromMe,
    senderId: senderId,
    senderName: senderName,
    kind: kind,
    body: body,
    data: data,
    reply: reply,
    createdAt: createdAt,
    readAt: readAt,
    deleted: deleted,
    updatedAt: updatedAt,
    state: state ?? this.state,
    error: error == null ? this.error : error(),
  );
}

/// Newest first, the server's copy replacing a queued one (same client id) or an older version
/// of itself (read, deleted)
List<ChatMessage> mergeMessages(List<ChatMessage> current, List<ChatMessage> incoming) {
  final byId = <String, ChatMessage>{for (final m in current) m.id: m};
  for (final m in incoming) {
    final queued = m.clientId == null
        ? null
        : byId.values.where((x) => x.state != SendState.sent && x.id == m.clientId).firstOrNull;
    if (queued != null) byId.remove(queued.id);
    byId[m.id] = m;
  }
  return byId.values.toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
}

/// "28 Oct 2026", or the time today ("14:05")
String chatTime(DateTime when, DateTime now) {
  final l = when.toLocal(), n = now.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  if (l.year == n.year && l.month == n.month && l.day == n.day) return '${two(l.hour)}:${two(l.minute)}';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${l.day} ${months[l.month - 1]}${l.year == n.year ? '' : ' ${l.year}'}';
}

/// The friend token in a "?friend=" query (32 hex), or null
String? parseFriendParam(String search) {
  final m = RegExp(r'(?:^|[?&])friend=([0-9a-f]{32})(?:&|$)').firstMatch(search);
  return m?.group(1);
}

/// The link others open to ask me to be friends
String friendLinkUrl(String siteUrl, String token) => '${siteUrl.replaceAll(RegExp(r'/+$'), '')}/?friend=$token';
