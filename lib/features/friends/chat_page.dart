import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/widgets.dart';
import '../../data/community/community_repository.dart' show CommunityException;
import '../../domain/account/profile.dart';
import '../../domain/community/community_attachments.dart';
import '../../domain/friends/friends.dart';
import '../../domain/marked/marked_areas.dart' show formatLength;
import '../../domain/share/share_location.dart' show PointLink;
import '../community/community_attach.dart' show pickAttachment;
import '../community/community_state.dart' show MapFocus, communityFocusProvider;
import '../map/share_location_sheet.dart' show phoneFixProvider;
import '../map/shared_links.dart' show sharedLinkProvider;
import 'friends_page.dart' show FriendAvatar;
import 'friends_state.dart';
import 'group_sheets.dart' show GroupAvatar, showGroupMembers;

// One chat, with a friend or a group: messages newest at the bottom, read again every 15 s while
// open; send text, my location (one fix), or map data (Pro and up), as a reply to an earlier
// message when wanted. Messages written without signal show a clock and go once it is back; a
// message can be taken back within an hour (in a group, its maker tidies any time). In a group
// each message shows who sent it, and the header opens the members.

String _thousands(int n) => n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

// My bubbles and the send button: the logo's orange, softened
const _peach = Color(0xFFFCE4D2);
const _peachLine = Color(0xFFF5CDAE);
const _peachSub = Color(0xFF9C6B4C);
const _sendOrange = Color(0xFFF08A4B);

String _message(Object e) => e is CommunityException ? e.message : '$e';

Future<void> openChat(BuildContext context, String friendId, String name) =>
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatPage(chat: chatWith(friendId), name: name),
      ),
    );

Future<void> openGroupChat(BuildContext context, String groupId, String name) =>
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatPage(chat: chatInGroup(groupId), name: name),
      ),
    );

void _toMap(BuildContext context) => Navigator.of(context, rootNavigator: true).popUntil((r) => r.isFirst);

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key, required this.chat, required this.name});

  final ChatRef chat;
  final String name;

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final _text = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  // Read here, not in dispose (ref is gone by then)
  late final ChatController _chat;
  late final FriendsController _friends;
  bool _locating = false;
  String? _error;
  ChatReply? _replyTo;

  bool get _group => widget.chat.group;

  @override
  void initState() {
    super.initState();
    _chat = ref.read(chatProvider(widget.chat).notifier);
    _friends = ref.read(friendsProvider.notifier);
    _scroll.addListener(() {
      // The list is reversed: the top is the end
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 200) unawaited(_chat.loadOlder());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_chat.open());
      // Opened straight from a club or a link: the friend's or group's details are not read yet
      if (!ref.read(friendsProvider).loaded) unawaited(_friends.refresh());
    });
  }

  @override
  void dispose() {
    _chat.close();
    // The chat list shows the last message (after this frame: providers cannot change while the
    // widget tree is being taken down)
    unawaited(Future(_friends.refresh));
    _text.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  ChatReply? _takeReply() {
    final r = _replyTo;
    if (r != null) setState(() => _replyTo = null);
    return r;
  }

  Future<void> _sendText() async {
    final body = _text.text.trim();
    if (body.isEmpty) return;
    _text.clear();
    setState(() => _error = null);
    await _chat.send(ChatKind.text, body: body, reply: _takeReply());
  }

  Future<void> _sendLocation() async {
    setState(() {
      _locating = true;
      _error = null;
    });
    try {
      final fix = await ref.read(phoneFixProvider)();
      await _chat.send(
        ChatKind.location,
        data: ChatLocation(lat: fix.lat, lng: fix.lng, accuracy: fix.accuracy, elevation: fix.elevation).toJson(),
        reply: _takeReply(),
      );
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _sendAttachment() async {
    final a = await pickAttachment(context);
    if (a == null || !mounted) return;
    await _chat.send(ChatKind.attachment, data: a.toJson(), reply: _takeReply());
  }

  Future<void> _more() async {
    final p = ref.read(profileProvider).value;
    final canAttach = p != null && (p.isAdmin || p.plan == Plan.pro || p.plan == Plan.enterprise);
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const Key('chat-send-location'),
              leading: const Icon(Icons.my_location, color: L360Colors.forest700),
              title: const Text('Send my location'),
              subtitle: const Text('Where you are now, once (not live)'),
              onTap: () => Navigator.pop(sheet, 'location'),
            ),
            ListTile(
              key: const Key('chat-send-map'),
              enabled: canAttach,
              leading: const Icon(Icons.timeline, color: L360Colors.forest700),
              title: const Text('Send map data'),
              subtitle: Text(canAttach ? 'A track, area, location or Field Work' : 'For Pro and Enterprise accounts'),
              onTap: () => Navigator.pop(sheet, 'map'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (choice == 'location') await _sendLocation();
    if (choice == 'map') await _sendAttachment();
  }

  void _reply(ChatMessage m) {
    setState(() => _replyTo = ChatReply.of(m, myName: ref.read(profileProvider).value?.displayName));
    _focus.requestFocus();
  }

  Future<void> _actions(ChatMessage m, {required bool canDelete}) async {
    final queued = m.state != SendState.sent;
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!queued && !m.deleted)
              ListTile(
                key: const Key('chat-reply'),
                leading: const Icon(Icons.reply, color: L360Colors.forest700),
                title: const Text('Reply'),
                onTap: () => Navigator.pop(sheet, 'reply'),
              ),
            if (m.state == SendState.failed)
              ListTile(
                key: const Key('chat-retry'),
                leading: const Icon(Icons.refresh),
                title: const Text('Try again'),
                onTap: () => Navigator.pop(sheet, 'retry'),
              ),
            if (queued || canDelete)
              ListTile(
                key: const Key('chat-delete'),
                leading: const Icon(Icons.delete_outline, color: L360Colors.brick500),
                title: Text(
                  queued
                      ? 'Do not send'
                      : _group
                      ? 'Delete for everyone'
                      : 'Delete for both',
                ),
                onTap: () => Navigator.pop(sheet, 'delete'),
              ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    try {
      if (choice == 'reply') _reply(m);
      if (choice == 'retry') await ref.read(chatOutboxProvider.notifier).retry(m.id);
      if (choice == 'delete') {
        queued ? await ref.read(chatOutboxProvider.notifier).discard(m.id) : await _chat.delete(m);
      }
    } on Object catch (e) {
      if (mounted) setState(() => _error = _message(e));
    }
  }

  void _showLocation(ChatLocation l) {
    unawaited(ref.read(sharedLinkProvider.notifier).open(PointLink((lat: l.lat, lng: l.lng))));
    _toMap(context);
  }

  void _showAttachment(ChatMessage m, Attachment a) {
    final who = m.fromMe ? 'You' : (m.senderName ?? widget.name);
    ref.read(communityFocusProvider.notifier).showFocus(MapFocus(title: '$who: ${a.name}', attachment: a));
    _toMap(context);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(chatProvider(widget.chat));
    final queued = [
      for (final q in ref.watch(chatOutboxProvider))
        if (q.chat == widget.chat) q.message,
    ];
    final messages = mergeMessages(s.messages, queued);
    final friend = _group ? null : ref.watch(friendsProvider.select((f) => f.byId(widget.chat.id)));
    final group = _group ? ref.watch(friendsProvider.select((f) => f.groupById(widget.chat.id))) : null;
    final loaded = ref.watch(friendsProvider.select((f) => f.loaded));
    // Still in it: a friend, or a member of the group
    final canWrite = !loaded || (_group ? group != null : friend != null);
    final manager = group?.isManager ?? false;
    final now = DateTime.now();
    // My newest message that was read: the double tick turns orange there
    final lastRead = messages.where((m) => m.fromMe).firstOrNull;
    final name = group?.name ?? widget.name;
    final subtitle = _group
        ? [
            group?.isClub ?? false ? 'Club chat' : 'Group',
            if (group != null) '${group.memberCount} member${group.memberCount == 1 ? '' : 's'}',
          ].join(' · ')
        : friend?.organization ?? 'Landscape 360 friend';
    return Scaffold(
      backgroundColor: L360Colors.sand50,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        titleSpacing: 0,
        shape: const Border(bottom: BorderSide(color: L360Colors.sand200)),
        title: InkWell(
          key: const Key('chat-header'),
          onTap: _group ? () => showGroupMembers(context, widget.chat.id) : null,
          child: Row(
            children: [
              if (_group) GroupAvatar(isClub: group?.isClub ?? false, size: 38) else FriendAvatar(name: name, size: 38),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: L360Colors.ink),
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: L360Colors.sand600),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (_group)
            IconButton(
              key: const Key('chat-members'),
              tooltip: 'Members',
              onPressed: () => showGroupMembers(context, widget.chat.id),
              icon: const Icon(Icons.people_outline, color: L360Colors.forest700),
            ),
        ],
      ),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            if (s.error != null || _error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(L360.gutter, 8, L360.gutter, 0),
                child: ErrorBanner(_error ?? s.error!),
              ),
            Expanded(
              child: CustomPaint(
                painter: const _Contours(),
                child: messages.isEmpty && !s.loading
                    ? _EmptyChat(name: name, group: group)
                    : ListView.builder(
                        key: const Key('chat-messages'),
                        controller: _scroll,
                        reverse: true,
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                        itemCount: messages.length + 1,
                        itemBuilder: (context, i) {
                          if (i == messages.length) {
                            if (s.loadingOlder) {
                              return const Padding(
                                padding: EdgeInsets.all(12),
                                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                              );
                            }
                            if (s.hasMore) return const SizedBox.shrink();
                            if (friend != null) return _SinceChip(since: friend.since);
                            if (group != null) return _SinceChip(since: group.createdAt, group: group);
                            return const SizedBox.shrink();
                          }
                          final m = messages[i];
                          // Reversed: i - 1 is the next (newer) message, i + 1 the previous (older)
                          final newer = i > 0 ? messages[i - 1] : null;
                          final older = i + 1 < messages.length ? messages[i + 1] : null;
                          final newDay = older == null || !_sameDay(older.createdAt, m.createdAt);
                          final groupStart = newDay || older.fromMe != m.fromMe || older.senderId != m.senderId;
                          final groupEnd =
                              newer == null ||
                              newer.fromMe != m.fromMe ||
                              newer.senderId != m.senderId ||
                              !_sameDay(newer.createdAt, m.createdAt);
                          final canDelete = m.canDelete(now) || (manager && !m.deleted && m.state == SendState.sent);
                          return Column(
                            children: [
                              if (newDay) _DayLabel(when: m.createdAt, now: now),
                              _Bubble(
                                key: Key('message-${m.id}'),
                                m: m,
                                now: now,
                                groupStart: groupStart,
                                groupEnd: groupEnd,
                                inGroup: _group,
                                showRead: !_group && m.fromMe && m.readAt != null && identical(m, lastRead),
                                onLongPress: () => _actions(m, canDelete: canDelete),
                                onShowLocation: _showLocation,
                                onShowAttachment: (a) => _showAttachment(m, a),
                              ),
                            ],
                          );
                        },
                      ),
              ),
            ),
            if (!canWrite)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  border: Border(top: BorderSide(color: L360Colors.sand200)),
                ),
                child: SafeArea(
                  top: false,
                  child: Text(
                    _group
                        ? 'You are no longer in this group, so you cannot send messages.'
                        : 'You are no longer friends, so you cannot send messages.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: L360Colors.sand600),
                  ),
                ),
              )
            else
              _Composer(
                controller: _text,
                focus: _focus,
                locating: _locating,
                replyTo: _replyTo,
                onCancelReply: () => setState(() => _replyTo = null),
                onSend: _sendText,
                onMore: _more,
              ),
          ],
        ),
      ),
    );
  }
}

/// Faint topographic lines behind the messages: a few hills drawn as wobbly rings
class _Contours extends CustomPainter {
  const _Contours();

  // Hill centre (as a share of the size), rings, and the wobble's phase
  static const _hills = [(0.12, 0.18, 7, 0.0), (0.92, 0.55, 8, 1.7), (0.3, 0.95, 6, 3.1)];

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = L360Colors.sand300.withValues(alpha: 0.35);
    final unit = math.max(size.width, size.height) / 18;
    for (final (cx, cy, rings, phase) in _hills) {
      final c = Offset(size.width * cx, size.height * cy);
      for (var k = 1; k <= rings; k++) {
        final base = unit * k * 0.9;
        final path = Path();
        for (var i = 0; i <= 96; i++) {
          final t = i / 96 * 2 * math.pi;
          final r = base * (1 + 0.12 * math.sin(3 * t + phase + k * 0.35) + 0.06 * math.sin(5 * t - phase));
          final p = c + Offset(math.cos(t) * r * 1.25, math.sin(t) * r);
          i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
        }
        canvas.drawPath(path..close(), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_Contours old) => false;
}

bool _sameDay(DateTime a, DateTime b) {
  final x = a.toLocal(), y = b.toLocal();
  return x.year == y.year && x.month == y.month && x.day == y.day;
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _dayLabel(DateTime when, DateTime now) {
  final d = when.toLocal(), n = now.toLocal();
  if (_sameDay(d, n)) return 'Today';
  if (_sameDay(d, n.subtract(const Duration(days: 1)))) return 'Yesterday';
  return '${d.day} ${_months[d.month - 1]}${d.year == n.year ? '' : ' ${d.year}'}';
}

class _DayLabel extends StatelessWidget {
  const _DayLabel({required this.when, required this.now});

  final DateTime when;
  final DateTime now;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: L360Colors.sand200),
        ),
        child: Text(
          _dayLabel(when, now),
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: L360Colors.sand600),
        ),
      ),
    ),
  );
}

class _SinceChip extends StatelessWidget {
  const _SinceChip({required this.since, this.group});

  final DateTime since;
  final ChatGroup? group;

  @override
  Widget build(BuildContext context) {
    final d = since.toLocal();
    final date = '${d.day} ${_months[d.month - 1]} ${d.year}';
    final g = group;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
      child: Column(
        children: [
          const Icon(Icons.lock_outline, size: 16, color: L360Colors.sand500),
          const SizedBox(height: 4),
          Text(
            g == null
                ? 'Friends since $date\nOnly the two of you can read this chat'
                : g.isClub
                ? 'Club chat since $date\nOnly members of the club can read it'
                : 'Group since $date\nOnly its members can read it',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, height: 1.4, color: L360Colors.sand500),
          ),
        ],
      ),
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat({required this.name, this.group});

  final String name;
  final ChatGroup? group;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (group != null) GroupAvatar(isClub: group!.isClub, size: 72) else FriendAvatar(name: name, size: 72),
          const SizedBox(height: 14),
          Text(
            name,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: L360Colors.ink),
          ),
          const SizedBox(height: 6),
          Text(
            group == null
                ? 'Say hello, or send your location.\nMessages arrive within about 15 seconds.'
                : 'Say hello to the group, or send your location.\nMessages arrive within about 15 seconds.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: L360Colors.sand600, height: 1.4),
          ),
        ],
      ),
    ),
  );
}

class _Composer extends StatefulWidget {
  const _Composer({
    required this.controller,
    required this.focus,
    required this.locating,
    required this.replyTo,
    required this.onCancelReply,
    required this.onSend,
    required this.onMore,
  });

  final TextEditingController controller;
  final FocusNode focus;
  final bool locating;
  final ChatReply? replyTo;
  final VoidCallback onCancelReply;
  final VoidCallback onSend;
  final VoidCallback onMore;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final empty = widget.controller.text.trim().isEmpty;
    final reply = widget.replyTo;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: L360Colors.sand200)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (reply != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 0, 8),
                child: Container(
                  key: const Key('chat-reply-bar'),
                  padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                  decoration: BoxDecoration(
                    color: L360Colors.sand50,
                    borderRadius: BorderRadius.circular(12),
                    border: const Border(left: BorderSide(color: L360Colors.ember500, width: 3)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.reply, size: 16, color: L360Colors.ember600),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Replying to ${reply.who}',
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                                color: L360Colors.ember600,
                              ),
                            ),
                            Text(
                              reply.text,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12.5, color: L360Colors.sand700),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        key: const Key('chat-reply-cancel'),
                        tooltip: 'Cancel reply',
                        visualDensity: VisualDensity.compact,
                        onPressed: widget.onCancelReply,
                        icon: const Icon(Icons.close, size: 18, color: L360Colors.sand600),
                      ),
                    ],
                  ),
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                SizedBox.square(
                  dimension: 44,
                  child: IconButton(
                    key: const Key('chat-more'),
                    tooltip: 'Location or map data',
                    onPressed: widget.locating ? null : widget.onMore,
                    icon: widget.locating
                        ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.add_circle_outline, size: 26, color: L360Colors.forest700),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: TextField(
                    key: const Key('chat-input'),
                    controller: widget.controller,
                    focusNode: widget.focus,
                    minLines: 1,
                    maxLines: 5,
                    maxLength: chatBodyMax,
                    textCapitalization: TextCapitalization.sentences,
                    style: const TextStyle(fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'Message',
                      counterText: '',
                      isDense: true,
                      filled: true,
                      fillColor: L360Colors.sand50,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(22),
                        borderSide: const BorderSide(color: L360Colors.sand200),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(22),
                        borderSide: const BorderSide(color: L360Colors.sand200),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(22),
                        borderSide: const BorderSide(color: L360Colors.forest500, width: 1.5),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox.square(
                  dimension: 44,
                  child: IconButton.filled(
                    key: const Key('chat-send'),
                    tooltip: 'Send',
                    style: IconButton.styleFrom(
                      backgroundColor: _sendOrange,
                      disabledBackgroundColor: L360Colors.sand200,
                      disabledForegroundColor: Colors.white,
                    ),
                    onPressed: empty ? null : widget.onSend,
                    icon: const Icon(Icons.arrow_upward_rounded, size: 22),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    super.key,
    required this.m,
    required this.now,
    required this.groupStart,
    required this.groupEnd,
    required this.inGroup,
    required this.showRead,
    required this.onLongPress,
    required this.onShowLocation,
    required this.onShowAttachment,
  });

  final ChatMessage m;
  final DateTime now;
  final bool groupStart;
  final bool groupEnd;
  final bool inGroup;
  final bool showRead;
  final VoidCallback? onLongPress;
  final void Function(ChatLocation) onShowLocation;
  final void Function(Attachment) onShowAttachment;

  @override
  Widget build(BuildContext context) {
    final mine = m.fromMe;
    const fg = L360Colors.ink;
    final sub = mine ? _peachSub : L360Colors.sand500;
    final loc = m.deleted ? null : m.location, att = m.deleted ? null : m.attachment;
    final card = loc != null || att != null;
    Widget content;
    if (m.deleted) {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.block, size: 15, color: sub),
          const SizedBox(width: 6),
          Text(
            'Message deleted',
            style: TextStyle(color: sub, fontStyle: FontStyle.italic),
          ),
        ],
      );
    } else if (loc != null) {
      content = _MapCard(
        icon: Icons.my_location,
        kind: 'Location',
        title: loc.elevation != null ? '${_thousands(loc.elevation!.round())} mdpl' : 'My location',
        detail: [
          '${loc.lat.toStringAsFixed(5)}, ${loc.lng.toStringAsFixed(5)}',
          if (loc.accuracy != null) '±${loc.accuracy!.round()} m',
        ].join(' · '),
        mine: mine,
        onTap: () => onShowLocation(loc),
      );
    } else if (att != null) {
      content = _MapCard(
        icon: switch (att) {
          TrackAttachment() => Icons.timeline,
          AreaAttachment() => Icons.pentagon_outlined,
          PlaceAttachment() => Icons.place_outlined,
          _ => Icons.architecture,
        },
        kind: att.label,
        title: att.name,
        detail: switch (att) {
          TrackAttachment(:final distanceM) => formatLength(distanceM),
          _ => 'Map data',
        },
        mine: mine,
        onTap: () => onShowAttachment(att),
      );
    } else {
      content = Text(m.body ?? '', style: const TextStyle(color: fg, fontSize: 14, height: 1.35));
    }
    final status = !mine
        ? null
        : switch (m.state) {
            SendState.queued => Icon(Icons.schedule, size: 13, color: sub),
            SendState.failed => const Icon(Icons.error_outline, size: 14, color: L360Colors.brick500),
            SendState.sent when m.readAt != null => Icon(
              Icons.done_all,
              size: 15,
              color: showRead ? L360Colors.ember500 : sub,
              key: showRead ? const Key('chat-read') : null,
            ),
            SendState.sent => Icon(Icons.done, size: 15, color: sub),
          };
    final reply = m.deleted ? null : m.reply;
    final sender = inGroup && !mine && groupStart ? m.senderName : null;
    const r = Radius.circular(18), tail = Radius.circular(5);
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * (card ? 0.8 : 0.76)),
        child: Padding(
          padding: EdgeInsets.only(top: groupStart ? 8 : 2),
          child: Column(
            crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onLongPress: onLongPress,
                child: Container(
                  padding: card ? const EdgeInsets.all(6) : const EdgeInsets.fromLTRB(12, 7, 10, 5),
                  decoration: BoxDecoration(
                    color: mine ? _peach : Colors.white,
                    borderRadius: BorderRadius.only(
                      topLeft: mine || groupStart ? r : tail,
                      topRight: !mine || groupStart ? r : tail,
                      bottomLeft: mine || groupEnd ? (mine ? r : tail) : tail,
                      bottomRight: !mine || groupEnd ? (mine ? tail : r) : tail,
                    ),
                    border: Border.all(color: mine ? _peachLine : L360Colors.sand200),
                    boxShadow: const [BoxShadow(color: Color(0x0D000000), blurRadius: 3, offset: Offset(0, 1))],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (sender != null)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(card ? 6 : 0, card ? 4 : 0, 0, 3),
                            child: Text(
                              sender,
                              key: Key('sender-${m.id}'),
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: L360Colors.forest700,
                              ),
                            ),
                          ),
                        ),
                      if (reply != null) _Quote(reply: reply, mine: mine, card: card),
                      content,
                      Padding(
                        padding: card ? const EdgeInsets.fromLTRB(0, 4, 6, 2) : const EdgeInsets.only(top: 3),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_clock(m.createdAt), style: TextStyle(fontSize: 10, color: sub)),
                            if (status != null) ...[const SizedBox(width: 4), status],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (m.state == SendState.failed)
                Padding(
                  padding: const EdgeInsets.only(top: 3, right: 4),
                  child: Text(
                    '${m.error ?? 'Not sent'} · hold to try again',
                    style: const TextStyle(fontSize: 11.5, color: L360Colors.brick500),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The message a reply answers: who wrote it and its first words
class _Quote extends StatelessWidget {
  const _Quote({required this.reply, required this.mine, required this.card});

  final ChatReply reply;
  final bool mine;
  final bool card;

  @override
  Widget build(BuildContext context) => Container(
    key: Key('quote-${reply.id}'),
    width: double.infinity,
    margin: EdgeInsets.fromLTRB(card ? 0 : 0, 2, 0, 6),
    padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
    decoration: BoxDecoration(
      color: mine ? const Color(0x66FFFFFF) : L360Colors.sand50,
      borderRadius: BorderRadius.circular(10),
      border: Border(left: BorderSide(color: mine ? L360Colors.ember500 : L360Colors.forest500, width: 3)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          reply.who,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: mine ? L360Colors.ember600 : L360Colors.forest700,
          ),
        ),
        Text(
          reply.text,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            fontStyle: reply.deleted ? FontStyle.italic : FontStyle.normal,
            color: mine ? _peachSub : L360Colors.sand700,
          ),
        ),
      ],
    ),
  );
}

String _clock(DateTime when) {
  final l = when.toLocal();
  return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

class _MapCard extends StatelessWidget {
  const _MapCard({
    required this.icon,
    required this.kind,
    required this.title,
    required this.detail,
    required this.mine,
    required this.onTap,
  });

  final IconData icon;
  final String kind;
  final String title;
  final String detail;
  final bool mine;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const fg = L360Colors.ink;
    final sub = mine ? _peachSub : L360Colors.sand600;
    final inner = mine ? const Color(0x99FFFFFF) : L360Colors.sand50;
    return Material(
      color: inner,
      borderRadius: BorderRadius.circular(13),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 12, 10),
              child: Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: mine ? _peach : L360Colors.forest100,
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Icon(icon, color: mine ? L360Colors.ember600 : L360Colors.forest700, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          kind.toUpperCase(),
                          style: TextStyle(color: sub, fontSize: 9.5, fontWeight: FontWeight.w700, letterSpacing: 0.6),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          title,
                          style: const TextStyle(color: fg, fontSize: 13.5, fontWeight: FontWeight.w700),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          detail,
                          style: TextStyle(color: sub, fontSize: 11),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Container(height: 1, color: mine ? _peachLine : L360Colors.sand200),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 9),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.map_outlined, size: 16, color: mine ? L360Colors.ember600 : L360Colors.forest700),
                  const SizedBox(width: 6),
                  Text(
                    'Show on map',
                    style: TextStyle(
                      color: mine ? L360Colors.ember600 : L360Colors.forest700,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
