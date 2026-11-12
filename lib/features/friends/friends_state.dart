import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/community/community_repository.dart' show CommunityException;
import '../../data/friends/friends_repository.dart';
import '../../domain/friends/friends.dart';
import '../../domain/survey/survey_model.dart' show newUuid;
import '../community/community_state.dart' show communityBackendProvider, communityPrefsProvider;
import '../tracks/track_recorder_state.dart' show onlineProvider;

// Friends & Chat in the app (docs/FRIENDS_PRD.md): the friend list, requests and groups (read
// again every 30 s while Friends is open), the unread badge (when the app opens or comes back,
// and after a chat is read), and each chat, with a friend or a group: asked for changes every
// 15 s while it is open, the last 50 messages kept on the phone to read without signal, and
// messages written without signal kept on the phone and sent once it is back (each with a client
// id, so never twice).

final friendsRepositoryProvider = Provider<FriendsRepository>(
  (ref) => FriendsRepository(ref.watch(communityBackendProvider)),
);

const friendsRefreshEvery = Duration(seconds: 30);
const chatRefreshEvery = Duration(seconds: 15);
const _cacheSize = 50;

String _message(Object e) => e is CommunityException ? e.message : '$e';
bool _offline(Object e) => e is CommunityException && e.offline;

String friendsCacheKey(String userId) => 'l360-friends-$userId';
String chatCacheKey(String userId, ChatRef chat) => 'l360-chat-$userId-${chat.group ? 'g-' : ''}${chat.id}';
String chatOutboxKey(String userId) => 'l360-chat-outbox-$userId';

// --- Friends, requests and groups ----------------------------------------------------------------

class FriendsState {
  const FriendsState({
    this.friends = const [],
    this.requests = const [],
    this.groups = const [],
    this.loading = false,
    this.loaded = false,
    this.error,
  });

  final List<Friend> friends;
  final List<FriendRequest> requests;
  final List<ChatGroup> groups;
  final bool loading;
  final bool loaded;
  final String? error;

  List<FriendRequest> get incoming => [
    for (final r in requests)
      if (r.direction == RequestDirection.incoming) r,
  ];
  List<FriendRequest> get outgoing => [
    for (final r in requests)
      if (r.direction == RequestDirection.outgoing) r,
  ];

  /// Friends with a chat and groups, the most recent first
  List<ChatEntry> get chats => chatEntries(friends, groups);

  Friend? byId(String id) => friends.where((f) => f.userId == id).firstOrNull;
  ChatGroup? groupById(String id) => groups.where((g) => g.id == id).firstOrNull;

  FriendsState copyWith({
    List<Friend>? friends,
    List<FriendRequest>? requests,
    List<ChatGroup>? groups,
    bool? loading,
    bool? loaded,
    String? Function()? error,
  }) => FriendsState(
    friends: friends ?? this.friends,
    requests: requests ?? this.requests,
    groups: groups ?? this.groups,
    loading: loading ?? this.loading,
    loaded: loaded ?? this.loaded,
    error: error == null ? this.error : error(),
  );
}

final friendsProvider = NotifierProvider<FriendsController, FriendsState>(FriendsController.new);

class FriendsController extends Notifier<FriendsState> {
  Timer? _timer;
  int _watchers = 0;

  @override
  FriendsState build() {
    ref.onDispose(() => _timer?.cancel());
    ref.listen(authUserIdProvider, (prev, next) {
      if (prev?.value != next.value) {
        _timer?.cancel();
        _watchers = 0;
        state = const FriendsState();
      }
    });
    return const FriendsState();
  }

  FriendsRepository get _repo => ref.read(friendsRepositoryProvider);
  String? get _userId => ref.read(authUserIdProvider).value;

  /// Friends is open: read now and every 30 s until [unwatch]
  void watch() {
    _watchers++;
    _timer ??= Timer.periodic(friendsRefreshEvery, (_) => unawaited(refresh()));
    unawaited(_fromCache().then((_) => refresh()));
  }

  void unwatch() {
    if (--_watchers > 0) return;
    _watchers = 0;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _fromCache() async {
    final userId = _userId;
    if (userId == null || state.loaded) return;
    try {
      final raw = await ref.read(communityPrefsProvider).getString(friendsCacheKey(userId));
      if (raw == null || !ref.mounted || state.loaded) return;
      final json = jsonDecode(raw);
      // Before groups the cache was the friend list alone
      final friends = json is Map ? json['friends'] : json;
      final groups = json is Map ? json['groups'] : null;
      List<Map<String, dynamic>> rows(Object? v) => [
        for (final r in (v is List ? v : const <Object?>[])) Map<String, dynamic>.from(r as Map),
      ];
      state = state.copyWith(
        friends: rows(friends).map(Friend.fromRow).toList(),
        groups: rows(groups).map(ChatGroup.fromRow).toList(),
      );
    } on Object {
      // Unreadable cache: the server answers
    }
  }

  Future<void> refresh() async {
    final userId = _userId;
    if (userId == null) return;
    state = state.copyWith(loading: true);
    try {
      final friends = await _repo.friends();
      final requests = await _repo.requests();
      final groups = await _repo.groups();
      if (!ref.mounted || _userId != userId) return;
      state = state.copyWith(
        friends: friends,
        requests: requests,
        groups: groups,
        loading: false,
        loaded: true,
        error: () => null,
      );
      unawaited(ref.read(friendsUnreadProvider.notifier).refresh());
      unawaited(
        ref
            .read(communityPrefsProvider)
            .setString(
              friendsCacheKey(userId),
              jsonEncode({
                'friends': [for (final f in friends) f.toRow()],
                'groups': [for (final g in groups) g.toRow()],
              }),
            ),
      );
    } on Object catch (e) {
      if (!ref.mounted) return;
      state = state.copyWith(loading: false, error: () => _offline(e) ? null : _message(e));
    }
  }

  Future<void> requestByEmail(String email) async {
    await _repo.requestByEmail(email);
    await refresh();
  }

  Future<String> requestByLink(String token) async {
    final r = await _repo.requestByLink(token);
    await refresh();
    return r;
  }

  Future<void> answer(FriendRequest r, {required bool accept}) async {
    await _repo.answer(r.id, accept: accept);
    await refresh();
  }

  Future<void> remove(String userId) async {
    await _repo.remove(userId);
    await refresh();
  }

  // --- Groups ------------------------------------------------------------------------------------

  /// A new group with these friends in it; returns its id
  Future<String> createGroup(String name, List<String> friendIds) async {
    final id = await _repo.createGroup(name);
    if (friendIds.isNotEmpty) await _repo.addGroupMembers(id, friendIds);
    await refresh();
    return id;
  }

  /// The club's chat (made now by its leader when there was none); returns its id
  Future<String> openClubChat(String clubId) async {
    final id = await _repo.createClubChat(clubId);
    await refresh();
    return id;
  }

  Future<int> addMembers(String groupId, List<String> friendIds) async {
    final n = await _repo.addGroupMembers(groupId, friendIds);
    await refresh();
    return n;
  }

  Future<void> removeMember(String groupId, String userId) async {
    await _repo.removeGroupMember(groupId, userId);
    await refresh();
  }

  Future<void> renameGroup(String groupId, String name) async {
    await _repo.renameGroup(groupId, name);
    await refresh();
  }

  Future<void> deleteGroup(String groupId) async {
    await _repo.deleteGroup(groupId);
    await refresh();
  }
}

/// A group's members, read when its page opens
final groupMembersProvider = FutureProvider.autoDispose.family<List<GroupMember>, String>(
  (ref, groupId) => ref.watch(friendsRepositoryProvider).groupMembers(groupId),
);

/// The club chat's id for a club member, or null while the leader has not opened one
final clubChatProvider = FutureProvider.autoDispose.family<String?, String>((ref, clubId) {
  // Opening one (or leaving the club) changes the answer
  ref.watch(friendsProvider.select((s) => s.groups.length));
  return ref.watch(friendsRepositoryProvider).clubChatGroup(clubId);
});

// --- The badge -----------------------------------------------------------------------------------

typedef FriendsUnread = ({int messages, int requests});

final friendsUnreadProvider = NotifierProvider<FriendsUnreadController, FriendsUnread>(FriendsUnreadController.new);

class FriendsUnreadController extends Notifier<FriendsUnread> {
  @override
  FriendsUnread build() {
    ref.listen(authUserIdProvider, (prev, next) {
      if (prev?.value == next.value) return;
      state = (messages: 0, requests: 0);
      if (next.value != null) unawaited(refresh());
    }, fireImmediately: true);
    return (messages: 0, requests: 0);
  }

  /// When the app opens or comes back, and after a chat is read; quiet without signal
  Future<void> refresh() async {
    if (ref.read(authUserIdProvider).value == null) return;
    try {
      final u = await ref.read(friendsRepositoryProvider).unread();
      if (ref.mounted) state = u;
    } on Object {
      // No signal, or the server is not ready: the badge stays as it was
    }
  }
}

// --- Messages waiting for signal -----------------------------------------------------------------

class QueuedMessage {
  const QueuedMessage({required this.chat, required this.message});

  factory QueuedMessage.fromJson(Map<String, dynamic> j) => QueuedMessage(
    // 'friendId' alone: queued before groups existed
    chat: j['chat'] is Map
        ? (group: (j['chat'] as Map)['group'] == true, id: '${(j['chat'] as Map)['id']}')
        : chatWith('${j['friendId']}'),
    message: ChatMessage.fromJson(Map<String, dynamic>.from(j['message'] as Map)),
  );

  final ChatRef chat;
  final ChatMessage message;

  Map<String, Object?> toJson() => {
    'chat': {'group': chat.group, 'id': chat.id},
    'message': message.toJson(),
  };
}

final chatOutboxProvider = NotifierProvider<ChatOutboxController, List<QueuedMessage>>(ChatOutboxController.new);

class ChatOutboxController extends Notifier<List<QueuedMessage>> {
  bool _sending = false;
  String? _userId;

  @override
  List<QueuedMessage> build() {
    ref.listen(authUserIdProvider, (_, next) {
      final id = next.value;
      if (id == _userId) return;
      _userId = id;
      state = const [];
      if (id != null) unawaited(_load(id));
    }, fireImmediately: true);
    ref.listen(onlineProvider, (prev, next) {
      if (next.value == true && prev?.value != true) unawaited(flush());
    });
    return const [];
  }

  Future<void> _load(String userId) async {
    try {
      final raw = await ref.read(communityPrefsProvider).getString(chatOutboxKey(userId));
      if (raw == null || !ref.mounted || _userId != userId) return;
      state = [for (final j in jsonDecode(raw) as List) QueuedMessage.fromJson(Map<String, dynamic>.from(j as Map))];
      unawaited(flush());
    } on Object {
      // Unreadable: nothing waits
    }
  }

  Future<void> _save() async {
    final userId = _userId;
    if (userId == null) return;
    await ref
        .read(communityPrefsProvider)
        .setString(chatOutboxKey(userId), jsonEncode([for (final q in state) q.toJson()]));
  }

  List<QueuedMessage> forChat(ChatRef chat) => [
    for (final q in state)
      if (q.chat == chat) q,
  ];

  Future<void> add(ChatRef chat, ChatMessage m) async {
    state = [...state, QueuedMessage(chat: chat, message: m)];
    await _save();
    await flush();
  }

  /// Tries a failed message again
  Future<void> retry(String clientId) async {
    state = [
      for (final q in state)
        q.message.id == clientId
            ? QueuedMessage(
                chat: q.chat,
                message: q.message.copyWith(state: SendState.queued, error: () => null),
              )
            : q,
    ];
    await _save();
    await flush();
  }

  Future<void> discard(String clientId) async {
    state = [
      for (final q in state)
        if (q.message.id != clientId) q,
    ];
    await _save();
  }

  /// Sends what waits, oldest first; stops at the first one without signal
  Future<void> flush() async {
    if (_sending) return;
    _sending = true;
    try {
      for (final q in [...state]) {
        if (q.message.state == SendState.failed) continue;
        final m = q.message;
        try {
          final sent = await ref
              .read(friendsRepositoryProvider)
              .send(q.chat, kind: m.kind, body: m.body, data: m.data, clientId: m.id, replyTo: m.reply?.id);
          if (!ref.mounted) return;
          state = [
            for (final x in state)
              if (x.message.id != m.id) x,
          ];
          await _save();
          ref
              .read(chatProvider(q.chat).notifier)
              .delivered(
                ChatMessage(
                  id: sent.id,
                  clientId: m.id,
                  fromMe: true,
                  kind: m.kind,
                  body: m.body,
                  data: m.data,
                  reply: m.reply,
                  createdAt: sent.createdAt,
                  updatedAt: sent.createdAt,
                ),
              );
        } on Object catch (e) {
          if (_offline(e)) break;
          state = [
            for (final x in state)
              x.message.id == m.id
                  ? QueuedMessage(
                      chat: x.chat,
                      message: m.copyWith(state: SendState.failed, error: () => _message(e)),
                    )
                  : x,
          ];
          await _save();
        }
      }
    } finally {
      _sending = false;
    }
  }
}

// --- One chat (with a friend or a group) -----------------------------------------------------------

class ChatState {
  const ChatState({
    this.messages = const [],
    this.loading = false,
    this.loadingOlder = false,
    this.hasMore = true,
    this.error,
  });

  /// Sent and received, newest first (the queued ones come from [chatOutboxProvider])
  final List<ChatMessage> messages;
  final bool loading;
  final bool loadingOlder;
  final bool hasMore;
  final String? error;

  ChatState copyWith({
    List<ChatMessage>? messages,
    bool? loading,
    bool? loadingOlder,
    bool? hasMore,
    String? Function()? error,
  }) => ChatState(
    messages: messages ?? this.messages,
    loading: loading ?? this.loading,
    loadingOlder: loadingOlder ?? this.loadingOlder,
    hasMore: hasMore ?? this.hasMore,
    error: error == null ? this.error : error(),
  );
}

final chatProvider = NotifierProvider.family<ChatController, ChatState, ChatRef>(ChatController.new);

class ChatController extends Notifier<ChatState> {
  ChatController(this.chat);

  final ChatRef chat;
  Timer? _timer;
  DateTime? _since;

  @override
  ChatState build() {
    ref.onDispose(() => _timer?.cancel());
    return const ChatState();
  }

  FriendsRepository get _repo => ref.read(friendsRepositoryProvider);
  String? get _userId => ref.read(authUserIdProvider).value;

  /// The chat is on screen: the phone's copy, then the server's, then changes every 15 s
  Future<void> open() async {
    _timer?.cancel();
    _timer = Timer.periodic(chatRefreshEvery, (_) => unawaited(poll()));
    await _fromCache();
    await _load();
  }

  void close() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _fromCache() async {
    final userId = _userId;
    if (userId == null || state.messages.isNotEmpty) return;
    try {
      final raw = await ref.read(communityPrefsProvider).getString(chatCacheKey(userId, chat));
      if (raw == null || !ref.mounted) return;
      state = state.copyWith(
        messages: [for (final j in jsonDecode(raw) as List) ChatMessage.fromJson(Map<String, dynamic>.from(j as Map))],
      );
    } on Object {
      // Unreadable cache: the server answers
    }
  }

  void _keep(List<ChatMessage> messages) {
    final userId = _userId;
    if (userId == null) return;
    unawaited(
      ref
          .read(communityPrefsProvider)
          .setString(chatCacheKey(userId, chat), jsonEncode([for (final m in messages.take(_cacheSize)) m.toJson()])),
    );
  }

  DateTime? _newest(List<ChatMessage> ms) {
    DateTime? t;
    for (final m in ms) {
      final u = m.updatedAt ?? m.createdAt;
      if (t == null || u.isAfter(t)) t = u;
    }
    return t;
  }

  Future<void> _load() async {
    state = state.copyWith(loading: true);
    try {
      final page = await _repo.messages(chat);
      if (!ref.mounted) return;
      final merged = mergeMessages([
        for (final m in state.messages)
          if (m.state != SendState.sent) m,
      ], page);
      _since = _newest(page);
      state = state.copyWith(messages: merged, loading: false, hasMore: page.length >= 30, error: () => null);
      _keep(merged);
      await _markRead(page);
    } on Object catch (e) {
      if (!ref.mounted) return;
      state = state.copyWith(loading: false, error: () => _offline(e) ? null : _message(e));
    }
  }

  /// What changed since the last look (new, read, deleted)
  Future<void> poll() async {
    if (_since == null) return _load();
    try {
      final changed = await _repo.messages(chat, since: _since);
      if (!ref.mounted || changed.isEmpty) return;
      final merged = mergeMessages(state.messages, changed);
      final newest = _newest(changed);
      if (newest != null && (_since == null || newest.isAfter(_since!))) _since = newest;
      state = state.copyWith(messages: merged, error: () => null);
      _keep(merged);
      await _markRead(changed);
    } on Object {
      // No signal: the next look tries again
    }
  }

  Future<void> loadOlder() async {
    if (state.loadingOlder || !state.hasMore || state.messages.isEmpty) return;
    state = state.copyWith(loadingOlder: true);
    try {
      final oldest = state.messages.last.createdAt;
      final page = await _repo.messages(chat, before: oldest);
      if (!ref.mounted) return;
      state = state.copyWith(
        messages: mergeMessages(state.messages, page),
        loadingOlder: false,
        hasMore: page.length >= 30,
      );
    } on Object {
      if (ref.mounted) state = state.copyWith(loadingOlder: false);
    }
  }

  /// A friend's unread messages are marked; a group once anything new from others came in
  Future<void> _markRead(List<ChatMessage> fresh) async {
    final due = chat.group
        ? fresh.any((m) => !m.fromMe && !m.deleted)
        : state.messages.any((m) => !m.fromMe && m.readAt == null && !m.deleted);
    if (!due) return;
    try {
      await _repo.markRead(chat);
      unawaited(ref.read(friendsUnreadProvider.notifier).refresh());
    } on Object {
      // Marked next time
    }
  }

  /// Puts a message in the queue (sent at once with signal)
  Future<void> send(ChatKind kind, {String? body, Map<String, dynamic>? data, ChatReply? reply}) {
    final id = newUuid();
    return ref
        .read(chatOutboxProvider.notifier)
        .add(
          chat,
          ChatMessage(
            id: id,
            clientId: id,
            fromMe: true,
            kind: kind,
            body: body?.trim(),
            data: data,
            reply: reply,
            createdAt: DateTime.now().toUtc(),
            state: SendState.queued,
          ),
        );
  }

  /// The queue sent it: it joins the chat
  void delivered(ChatMessage m) {
    final merged = mergeMessages(state.messages, [m]);
    state = state.copyWith(messages: merged);
    _keep(merged);
  }

  Future<void> delete(ChatMessage m) async {
    await _repo.deleteMessage(m.id);
    await poll();
  }
}

// --- A friend link opened in the app (/?friend=<token>) ----------------------------------------

class FriendLinkRequest extends Notifier<String?> {
  @override
  String? build() => null;

  void open(String token) => state = token;
  void done() => state = null;
}

final friendLinkProvider = NotifierProvider<FriendLinkRequest, String?>(FriendLinkRequest.new);
