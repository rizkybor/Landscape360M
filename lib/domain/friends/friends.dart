import '../community/community_attachments.dart';

// Friends & Chat (docs/FRIENDS_PRD.md, 20261111000032_friends_chat.sql): friends added by email
// or by a personal link / QR (/?friend=<token>), requests, and one-to-one chat that is not real
// time. A message is text, my location (one fix, never live), or a copy of a map item (Pro and up).

DateTime _time(Object? v) => DateTime.tryParse('${v ?? ''}') ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

DateTime? _timeOrNull(Object? v) => v == null ? null : DateTime.tryParse('$v');

int _int(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;

double? _double(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}');

/// Server limits
const chatBodyMax = 2000;

/// Messages can be taken back this long after sending
const chatDeleteWindow = Duration(hours: 1);

enum ChatKind {
  text,
  location,
  attachment;

  static ChatKind parse(Object? v) => values.firstWhere((k) => k.name == v, orElse: () => text);
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
    organization: (r['organization'] as String?)?.trim().isEmpty ?? true ? null : r['organization'] as String,
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

  /// The last message in one line, as in a chat list ("You: Location")
  String? get preview {
    final kind = lastKind;
    if (kind == null) return null;
    final what = lastDeleted
        ? 'Message deleted'
        : switch (kind) {
            ChatKind.text => (lastBody ?? '').replaceAll('\n', ' '),
            ChatKind.location => 'Location',
            ChatKind.attachment => 'Map data',
          };
    return lastFromMe ? 'You: $what' : what;
  }
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
    organization: (r['organization'] as String?)?.trim().isEmpty ?? true ? null : r['organization'] as String,
    createdAt: _time(r['created_at']),
  );

  final String id;
  final RequestDirection direction;
  final String userId;
  final String name;
  final String? organization;
  final DateTime createdAt;
}

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

enum SendState { queued, sent, failed }

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.clientId,
    required this.fromMe,
    required this.kind,
    this.body,
    this.data,
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
    kind: ChatKind.parse(r['kind']),
    body: r['body'] as String?,
    data: r['data'] is Map ? Map<String, dynamic>.from(r['data'] as Map) : null,
    createdAt: _time(r['created_at']),
    readAt: _timeOrNull(r['read_at']),
    deleted: r['deleted'] == true,
    updatedAt: _timeOrNull(r['updated_at']),
  );

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
    id: '${j['id']}',
    clientId: j['clientId'] as String?,
    fromMe: j['fromMe'] == true,
    kind: ChatKind.parse(j['kind']),
    body: j['body'] as String?,
    data: j['data'] is Map ? Map<String, dynamic>.from(j['data'] as Map) : null,
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
  final ChatKind kind;
  final String? body;
  final Map<String, dynamic>? data;
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
    'kind': kind.name,
    'body': body,
    'data': data,
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
    kind: kind,
    body: body,
    data: data,
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
