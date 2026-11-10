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

// Friends & Chat in the app (docs/FRIENDS_PRD.md): the friend list and requests (read again
// every 30 s while Friends is open), the unread badge (when the app opens or comes back, and
// after a chat is read), and each chat: asked for changes every 15 s while it is open, the last
// 50 messages kept on the phone to read without signal, and messages written without signal
// kept on the phone and sent once it is back (each with a client id, so never twice).

final friendsRepositoryProvider = Provider<FriendsRepository>(
  (ref) => FriendsRepository(ref.watch(communityBackendProvider)),
);

const friendsRefreshEvery = Duration(seconds: 30);
const chatRefreshEvery = Duration(seconds: 15);
const _cacheSize = 50;

String _message(Object e) => e is CommunityException ? e.message : '$e';
bool _offline(Object e) => e is CommunityException && e.offline;

String friendsCacheKey(String userId) => 'l360-friends-$userId';
String chatCacheKey(String userId, String friendId) => 'l360-chat-$userId-$friendId';
String chatOutboxKey(String userId) => 'l360-chat-outbox-$userId';

// --- Friends and requests ------------------------------------------------------------------------

class FriendsState {
  const FriendsState({
    this.friends = const [],
    this.requests = const [],
    this.loading = false,
    this.loaded = false,
    this.error,
  });

  final List<Friend> friends;
  final List<FriendRequest> requests;
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

  /// Friends with a chat, the most recent first
  List<Friend> get chats => [
    for (final f in friends)
      if (f.lastAt != null) f,
  ];

  Friend? byId(String id) => friends.where((f) => f.userId == id).firstOrNull;

  FriendsState copyWith({
    List<Friend>? friends,
    List<FriendRequest>? requests,
    bool? loading,
    bool? loaded,
    String? Function()? error,
  }) => FriendsState(
    friends: friends ?? this.friends,
    requests: requests ?? this.requests,
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
      final rows = [for (final r in jsonDecode(raw) as List) Map<String, dynamic>.from(r as Map)];
      state = state.copyWith(friends: rows.map(Friend.fromRow).toList());
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
      if (!ref.mounted || _userId != userId) return;
      state = state.copyWith(friends: friends, requests: requests, loading: false, loaded: true, error: () => null);
      unawaited(ref.read(friendsUnreadProvider.notifier).refresh());
      unawaited(
        ref
            .read(communityPrefsProvider)
            .setString(friendsCacheKey(userId), jsonEncode([for (final f in friends) _friendRow(f)])),
      );
    } on Object catch (e) {
      if (!ref.mounted) return;
      state = state.copyWith(loading: false, error: () => _offline(e) ? null : _message(e));
    }
  }

  static Map<String, Object?> _friendRow(Friend f) => {
    'user_id': f.userId,
    'name': f.name,
    'organization': f.organization,
    'since': f.since.toUtc().toIso8601String(),
    'last_at': f.lastAt?.toUtc().toIso8601String(),
    'last_kind': f.lastKind?.name,
    'last_body': f.lastBody,
    'last_from_me': f.lastFromMe,
    'last_deleted': f.lastDeleted,
    'unread': f.unread,
  };

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
}

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
  const QueuedMessage({required this.friendId, required this.message});

  factory QueuedMessage.fromJson(Map<String, dynamic> j) => QueuedMessage(
    friendId: '${j['friendId']}',
    message: ChatMessage.fromJson(Map<String, dynamic>.from(j['message'] as Map)),
  );

  final String friendId;
  final ChatMessage message;

  Map<String, Object?> toJson() => {'friendId': friendId, 'message': message.toJson()};
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

  List<QueuedMessage> forFriend(String friendId) => [
    for (final q in state)
      if (q.friendId == friendId) q,
  ];

  Future<void> add(String friendId, ChatMessage m) async {
    state = [...state, QueuedMessage(friendId: friendId, message: m)];
    await _save();
    await flush();
  }

  /// Tries a failed message again
  Future<void> retry(String clientId) async {
    state = [
      for (final q in state)
        q.message.id == clientId
            ? QueuedMessage(
                friendId: q.friendId,
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
              .send(q.friendId, kind: m.kind, body: m.body, data: m.data, clientId: m.id);
          if (!ref.mounted) return;
          state = [
            for (final x in state)
              if (x.message.id != m.id) x,
          ];
          await _save();
          ref
              .read(chatProvider(q.friendId).notifier)
              .delivered(
                ChatMessage(
                  id: sent.id,
                  clientId: m.id,
                  fromMe: true,
                  kind: m.kind,
                  body: m.body,
                  data: m.data,
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
                      friendId: x.friendId,
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

// --- One chat ------------------------------------------------------------------------------------

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

final chatProvider = NotifierProvider.family<ChatController, ChatState, String>(ChatController.new);

class ChatController extends Notifier<ChatState> {
  ChatController(this.friendId);

  final String friendId;
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
      final raw = await ref.read(communityPrefsProvider).getString(chatCacheKey(userId, friendId));
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
          .setString(
            chatCacheKey(userId, friendId),
            jsonEncode([for (final m in messages.take(_cacheSize)) m.toJson()]),
          ),
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
      final page = await _repo.messages(friendId);
      if (!ref.mounted) return;
      final merged = mergeMessages([
        for (final m in state.messages)
          if (m.state != SendState.sent) m,
      ], page);
      _since = _newest(page);
      state = state.copyWith(messages: merged, loading: false, hasMore: page.length >= 30, error: () => null);
      _keep(merged);
      await _markRead();
    } on Object catch (e) {
      if (!ref.mounted) return;
      state = state.copyWith(loading: false, error: () => _offline(e) ? null : _message(e));
    }
  }

  /// What changed since the last look (new, read, deleted)
  Future<void> poll() async {
    if (_since == null) return _load();
    try {
      final changed = await _repo.messages(friendId, since: _since);
      if (!ref.mounted || changed.isEmpty) return;
      final merged = mergeMessages(state.messages, changed);
      final newest = _newest(changed);
      if (newest != null && (_since == null || newest.isAfter(_since!))) _since = newest;
      state = state.copyWith(messages: merged, error: () => null);
      _keep(merged);
      if (changed.any((m) => !m.fromMe && m.readAt == null)) await _markRead();
    } on Object {
      // No signal: the next look tries again
    }
  }

  Future<void> loadOlder() async {
    if (state.loadingOlder || !state.hasMore || state.messages.isEmpty) return;
    state = state.copyWith(loadingOlder: true);
    try {
      final oldest = state.messages.last.createdAt;
      final page = await _repo.messages(friendId, before: oldest);
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

  Future<void> _markRead() async {
    if (!state.messages.any((m) => !m.fromMe && m.readAt == null && !m.deleted)) return;
    try {
      await _repo.markRead(friendId);
      unawaited(ref.read(friendsUnreadProvider.notifier).refresh());
    } on Object {
      // Marked next time
    }
  }

  /// Puts a message in the queue (sent at once with signal)
  Future<void> send(ChatKind kind, {String? body, Map<String, dynamic>? data}) {
    final id = newUuid();
    return ref
        .read(chatOutboxProvider.notifier)
        .add(
          friendId,
          ChatMessage(
            id: id,
            clientId: id,
            fromMe: true,
            kind: kind,
            body: body?.trim(),
            data: data,
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
